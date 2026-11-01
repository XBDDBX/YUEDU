import Foundation
import JavaScriptCore

/// legado / 阅读 3.0 的 `<js>` 运行时桥。
///
/// 用一个 JavaScriptCore 上下文按 legado 语义执行书源里的 JS 块：
/// - 先注入书源 `jsLib`（host / getArguments 等公共代码）
/// - 再注入兼容垫片（cookie / java / source / getArgument 等）
/// - 最后执行书源代码，取**顶层最后一个表达式的值**（与 Rhino 一致）
///
/// java.ajax 等网络调用同步完成（信号量等待 URLSession）。
/// 整个桥运行在 MainActor：legado 书源代码里对 AppStore 变量/登录/cookie
/// 的读写必须发生在主线程（AppStore 是 @MainActor），因此 evaluate 不再
/// 派发到后台队列，直接在主线程同步执行。
@MainActor
enum JSBridge {

    // MARK: - 对外

    /// 执行一段 JS（可带书源 jsLib 前置），返回顶层表达式值。
    /// - Parameters:
    ///   - source: 书源（提供 jsLib 与运行时状态）
    ///   - code: `<js> ... </js>` 之间的代码
    ///   - result: 注入到 JS 的 `result` 变量（页面内容 / hex 编码等）
    ///   - baseUrl: 注入到 JS 的 `baseUrl` 变量
    ///   - vars: 额外注入变量（key / page / book / chapter 等）
    /// - Returns: 顶层表达式的值；对象/数组会被序列化为 JSON 字符串
    @discardableResult
    static func evaluate(source: BookSource?,
                         code: String,
                         result: String? = nil,
                         baseUrl: String? = nil,
                         vars: [String: Any] = [:]) -> Any? {
        guard code.hasPrefix("<js>") else { return nil }
        let js = code
            .replacingOccurrences(of: #"^\s*<js>\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*</js>\s*$"#, with: "", options: .regularExpression)

        // @MainActor 保证在主线程同步执行（AppStore 访问合法），
        // 网络同步等待由 syncRequest 的信号量完成，不依赖主线程回调
        return Self.run(source: source, js: js, result: result, baseUrl: baseUrl, vars: vars)
    }

    /// 判断一段规则是否以 `<js>` 开头
    static func isJS(_ rule: String?) -> Bool {
        (rule ?? "").hasPrefix("<js>")
    }

    /// 从 `<js>…</js>后缀` 中拆出 JS 段与后缀
    static func splitJS(_ rule: String) -> (js: String, rest: String)? {
        guard let open = rule.range(of: "<js>"),
              let close = rule.range(of: "</js>") else { return nil }
        let js = String(rule[open.upperBound..<close.lowerBound])
        let rest = String(rule[close.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (js, rest)
    }

    /// 解码 `data:;base64,<b64>,…` 协议 URL，返回 base64 解出的文本
    static func decodeDataURL(_ urlString: String) -> String? {
        guard urlString.hasPrefix("data:") else { return nil }
        guard let b64 = urlString.range(of: "base64,")?.upperBound else { return nil }
        var payload = String(urlString[b64...])
        if let comma = payload.range(of: ",") { payload = String(payload[..<comma.lowerBound]) }
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 执行

    private static func run(source: BookSource?,
                            js: String,
                            result: String?,
                            baseUrl: String?,
                            vars: [String: Any]) -> Any? {
        guard let context = JSContext() else { return nil }
        context.exceptionHandler = { _, e in
            if let e { print("[JSBridge] exception: \(e)") }
        }

        // 1) 兼容垫片（Rhino/Java 环境模拟）——必须先于书源代码，避免 jsLib 里的
        //    JavaImporter / URL 等引用崩溃
        context.evaluateScript(shimJS)

        // 2) 书源公共代码（jsLib）
        if let lib = source?.jsLib, !lib.isEmpty {
            context.evaluateScript(lib)
        }

        // 3) 注入变量
        let store = AppStore.shared
        let bridgeStore = source
        context.setObject(store.variable(for: source?.id ?? UUID()), forKeyedSubscript: "__swift_sourceVar" as NSString)
        context.setObject(store.loginInfo(for: source?.id ?? UUID()), forKeyedSubscript: "__swift_loginInfo" as NSString)
        context.setObject("", forKeyedSubscript: "__swift_bookVar" as NSString)
        context.setObject(result ?? "", forKeyedSubscript: "result" as NSString)
        if let b = baseUrl { context.setObject(b, forKeyedSubscript: "baseUrl" as NSString) }
        for (k, v) in vars {
            switch v {
            case let s as String: context.setObject(s, forKeyedSubscript: k as NSString)
            case let i as Int: context.setObject(i, forKeyedSubscript: k as NSString)
            case let d as Double: context.setObject(d, forKeyedSubscript: k as NSString)
            case let b as Bool: context.setObject(b, forKeyedSubscript: k as NSString)
            case let dict as [String: Any]:
                // 字典直接注入为 JS 原生对象（书源代码可直接访问其属性）
                context.setObject(dict, forKeyedSubscript: k as NSString)
            default: break
            }
        }

        // 4) 桥接对象
        injectBridges(context: context, source: bridgeStore)

        // 5) 执行，取顶层表达式值
        guard let value = context.evaluateScript(js) else { return nil }

        // 6) 写回书源代码对变量 / 登录信息的修改（setVariable / putLoginInfo 等）
        let sid = source?.id ?? UUID()
        if let v = context.objectForKeyedSubscript("__swift_sourceVar" as NSString)?.toString(),
           v != store.variable(for: sid) {
            store.setVariable(v, for: sid)
        }
        if let li = context.objectForKeyedSubscript("__swift_loginInfo" as NSString)?.toString(),
           li != store.loginInfo(for: sid) {
            store.setLoginInfo(li, for: sid)
        }

        return convert(value)
    }

    private static func injectBridges(context: JSContext, source: BookSource?) {
        guard let source else { return }
        let store = AppStore.shared

        // cookie —— 注入全局函数（shim 里的 cookie 对象引用它们）
        let cookieGet: @convention(block) (String) -> String = { host in
            store.cookie(for: host)
        }
        let cookieSet: @convention(block) (String, String) -> Void = { host, value in
            store.setCookie(value, for: host)
        }
        let cookieRemove: @convention(block) (String) -> Void = { host in
            store.removeCookie(for: host)
        }
        context.setObject(cookieGet, forKeyedSubscript: "__swift_cookie_get" as NSString)
        context.setObject(cookieSet, forKeyedSubscript: "__swift_cookie_set" as NSString)
        context.setObject(cookieRemove, forKeyedSubscript: "__swift_cookie_remove" as NSString)

        // source（变量 / 登录信息）—— 通过 __swift_sourceVar / __swift_loginInfo 全局变量
        // java
        let ajax: @convention(block) (String) -> String = { spec in
            SourceFetcher.syncRequest(spec) ?? ""
        }
        let base64Encode: @convention(block) (String) -> String = { s in
            Data(s.utf8).base64EncodedString()
        }
        let base64Decode: @convention(block) (String) -> String = { s in
            guard let d = Data(base64Encoded: s, options: .ignoreUnknownCharacters) else { return "" }
            return String(data: d, encoding: .utf8) ?? ""
        }
        let hexDecode: @convention(block) (String) -> String = { s in
            var hex = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if hex.hasPrefix("0x") { hex = String(hex.dropFirst(2)) }
            guard hex.count % 2 == 0 else { return "" }
            var bytes = [UInt8]()
            var i = hex.startIndex
            while i < hex.endIndex {
                let next = hex.index(i, offsetBy: 2)
                if let b = UInt8(hex[i..<next], radix: 16) { bytes.append(b) }
                i = next
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        let hexEncode: @convention(block) (String) -> String = { s in
            Data(s.utf8).map { String(format: "%02x", $0) }.joined()
        }
        let deviceID: @convention(block) () -> String = { store.sourceState.deviceID }
        let androidId: @convention(block) () -> String = { store.sourceState.deviceID }
        let log: @convention(block) (Any) -> Void = { v in print("[JSBridge] \(v)") }
        let noop: @convention(block) () -> Void = {}
        let browser: @convention(block) (String, String) -> Void = { _, _ in }
        if let obj = context.objectForKeyedSubscript("java") {
            obj.setObject(ajax, forKeyedSubscript: "ajax" as NSString)
            obj.setObject(base64Encode, forKeyedSubscript: "base64Encode" as NSString)
            obj.setObject(base64Decode, forKeyedSubscript: "base64Decode" as NSString)
            obj.setObject(hexDecode, forKeyedSubscript: "hexDecodeToString" as NSString)
            obj.setObject(hexEncode, forKeyedSubscript: "hexEncodeToString" as NSString)
            obj.setObject(deviceID, forKeyedSubscript: "deviceID" as NSString)
            obj.setObject(androidId, forKeyedSubscript: "androidId" as NSString)
            obj.setObject(log, forKeyedSubscript: "log" as NSString)
            obj.setObject(log, forKeyedSubscript: "toast" as NSString)
            obj.setObject(log, forKeyedSubscript: "longToast" as NSString)
            obj.setObject(noop, forKeyedSubscript: "qread" as NSString)
            obj.setObject(noop, forKeyedSubscript: "reLoginView" as NSString)
            obj.setObject(noop, forKeyedSubscript: "refreshExplore" as NSString)
            obj.setObject(noop, forKeyedSubscript: "showBrowser" as NSString)
            obj.setObject(noop, forKeyedSubscript: "showReadingBrowser" as NSString)
            obj.setObject(noop, forKeyedSubscript: "startBrowserDp" as NSString)
            obj.setObject(browser, forKeyedSubscript: "startBrowser" as NSString)
            obj.setObject(browser, forKeyedSubscript: "startBrowserAwait" as NSString)
            let ua: @convention(block) () -> String = { SourceFetcher.userAgent }
            obj.setObject(ua, forKeyedSubscript: "getWebViewUA" as NSString)
            let put: @convention(block) (String, Any) -> Void = { key, val in
                store.jsScratch["\(source.id.uuidString).\(key)"] = "\(val)"
            }
            obj.setObject(put, forKeyedSubscript: "put" as NSString)
            let get: @convention(block) (String) -> String = { key in
                store.jsScratch["\(source.id.uuidString).\(key)"] ?? ""
            }
            obj.setObject(get, forKeyedSubscript: "get" as NSString)
        }
    }

    // MARK: - JSValue -> Any

    private static func convert(_ value: JSValue) -> Any? {
        if value.isUndefined || value.isNull { return nil }
        if value.isString { return value.toString() }
        if value.isNumber { return value.toNumber() }
        if value.isBoolean { return value.toBool() }
        if let obj = value.toObject() {
            if JSONSerialization.isValidJSONObject(obj),
               let data = try? JSONSerialization.data(withJSONObject: obj),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return String(describing: obj)
        }
        return value.toString()
    }

    // MARK: - 垫片 JS

    private static var shimJS: String {
        """
        // ---- legado Rhino 环境模拟（先于书源代码执行）----
        // JavaImporter / importClass：legado jsLib 惯用的类导入，iOS 无 Java，全部打桩
        if (typeof JavaImporter === 'undefined') {
            function JavaImporter() {
                return { importClass: function(cls) {}, importPackage: function() {} };
            }
        }
        if (typeof importPackage === 'undefined') { function importPackage() {} }
        if (typeof importClass === 'undefined') { function importClass() {} }
        var Packages = { io: { legato: { kazusa: { utils: { TimeoutCancellationException: function(){} } } } } };

        // URL / HttpUrl polyfill（JavaScriptCore 无全局 URL）
        if (typeof URL === 'undefined') {
            function URL(u) {
                var m = /^(?:https?:)?\\/\\/([^\\/?#]+)/.exec(String(u));
                this.host = m ? m[1] : String(u);
                this.hostname = this.host.split(':')[0];
                this.protocol = /^([a-z]+:)/i.test(String(u)) ? RegExp.$1 : '';
            }
        }
        if (typeof HttpUrl === 'undefined') {
            var HttpUrl = { parse: function(u) {
                return { topPrivateDomain: function() {
                    try { var m = /^(?:https?:)?\\/\\/([^\\/?#]+)/.exec(String(u)); return m ? m[1].split(':')[0] : String(u); }
                    catch (e) { return String(u); }
                } };
            } };
        }
        if (typeof okhttp3 === 'undefined') { var okhttp3 = { HttpUrl: HttpUrl }; }

        // ---- legado 运行时桥 ----
        var __source = { getVariable: function(){ return __swift_sourceVar || ''; },
                         setVariable: function(v){ __swift_sourceVar = String(v); },
                         getLoginInfo: function(){ return __swift_loginInfo || '{}'; },
                         setLoginInfo: function(v){ __swift_loginInfo = String(v); } };
        var source = __source;
        function getArgument(key){ return getArguments(__swift_sourceVar || '{}', key); }
        function setArgument(k, v){ var o = JSON.parse(__swift_sourceVar || '{}'); o[k] = String(v); __swift_sourceVar = JSON.stringify(o); }
        function setArguments(o){ var cur = JSON.parse(__swift_sourceVar || '{}'); for (var k in o) { cur[k] = o[k]; } __swift_sourceVar = JSON.stringify(cur); }
        function getKey(str){ try { str = String(str); var parts = str.split(';'); for (var i=0;i<parts.length;i++){ var kv = parts[i].split('='); if (kv[0] === 'qttoken') return kv[1] || ''; } } catch(e){} return ''; }
        var cookie = { getCookie: function(host){ return __swift_cookie_get(String(host)); },
                       setCookie: function(host, v){ __swift_cookie_set(String(host), String(v)); },
                       removeCookie: function(host){ __swift_cookie_remove(String(host)); } };
        var java = { log: function(){}, toast: function(){}, longToast: function(){} };
        function putLoginInfo(v){ __swift_loginInfo = String(v); }
        function getFanqieCookie(){ return ''; }
        var sdtoken = '';
        // 书籍 / 章节对象（书源代码会读写这些字段）
        var book = { getVariable: function(k){ return __swift_bookVar || ''; }, setVariable: function(k,v){}, type: 0, imageStyle: '', durChapterIndex: 0, durChapterTitle: '' };
        var chapter = { index: 0, title: '', url: '' };
        if (typeof host === 'undefined') { var host = []; }
        """
    }
}

// MARK: - SourceFetcher 同步请求扩展

extension SourceFetcher {
    /// 解析 legado 的 `url,{json options}` 请求描述并同步执行（JSBridge java.ajax 用）
    static func syncRequest(_ spec: String) -> String? {
        var url = spec
        var method = "GET"
        var headers: [String: String] = [:]
        var body: Data? = nil

        if let comma = spec.range(of: ",{") {
            let optsJSON = String(spec[comma.upperBound...])
            url = String(spec[..<comma.lowerBound])
            if let d = optsJSON.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                method = (Flex.str(obj["method"]).isEmpty ? "GET" : Flex.str(obj["method"]).uppercased())
                if let h = obj["headers"] as? [String: Any] {
                    for (k, v) in h { headers[k] = Flex.str(v) }
                }
                if let b = obj["body"] {
                    if let s = b as? String {
                        body = s.data(using: .utf8)
                    } else if JSONSerialization.isValidJSONObject(b),
                              let d2 = try? JSONSerialization.data(withJSONObject: b) {
                        body = d2
                    }
                }
            }
        }

        guard let parsed = URL(string: url), parsed.scheme != nil else { return nil }
        var req = URLRequest(url: parsed)
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = 25
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        let sem = DispatchSemaphore(value: 0)
        var outData: Data? = nil
        let task = session.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, !(200...399).contains(http.statusCode) {
                outData = nil
            } else {
                outData = data
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 35)
        task.cancel()
        guard let d = outData else { return nil }
        return decode(d, contentType: nil)
    }
}
