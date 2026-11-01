import Foundation
import SwiftSoup

/// 发现页分类
struct ExploreSection: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let url: String
    let sourceID: UUID
}

/// 一次书源请求的上下文
struct SourceService {
    let source: BookSource

    var baseHeaders: [String: String] {
        SourceFetcher.parseHeaders(source.header)
    }

    var baseURL: URL? {
        URL(string: source.url.hasSuffix("/") ? source.url : source.url + "/")
    }

    // MARK: - JS 规则求值

    /// 页面 URL → JS 的 result：`data:;base64,…` 解码成 JSON 再转 hex；普通 URL 原样
    private func pageResult(for urlString: String) -> String {
        if let json = JSBridge.decodeDataURL(urlString) {
            return Data(json.utf8).map { String(format: "%02x", $0) }.joined()
        }
        return urlString
    }

    /// 求值 `<js>…</js>rest` 规则；rest 为 JSONPath 时作用在 JS 结果上
    private func evalJS(_ rule: String, result: String?, baseUrl: String?, vars: [String: Any] = [:]) -> String? {
        guard let parts = JSBridge.splitJS(rule) else { return nil }
        let code = "<js>\(parts.js)</js>"
        guard let raw = JSBridge.evaluate(source: source, code: code,
                                          result: result, baseUrl: baseUrl, vars: vars) as? String,
              !raw.isEmpty else { return nil }
        let rest = parts.rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.isEmpty { return raw }
        if rest.hasPrefix("$") || rest.hasPrefix("@json:") {
            let path = rest.replacingOccurrences(of: "@json:", with: "")
            return JSONQuery.evalString(path: path, jsonText: raw).first
        }
        return raw
    }

    /// 对单个 JSON 元素按规则取值（支持 `$.path` / `{{模板}}` / `<js>` / 正则替换后缀）
    private func value(_ rule: String, json: Any) -> String {
        let r = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return "" }

        if JSBridge.isJS(r) {
            guard let data = try? JSONSerialization.data(withJSONObject: json),
                  let itemText = String(data: data, encoding: .utf8) else { return "" }
            return evalJS(r, result: itemText, baseUrl: nil) ?? ""
        }

        var pattern: String? = nil
        var replacement = ""
        var body = r
        if r.contains("##") {
            let parts = r.components(separatedBy: "##")
            body = parts[0]
            if parts.count > 1 { pattern = parts[1] }
            if parts.count > 2 { replacement = parts[2] }
        }

        var v: String
        if body.contains("{{") {
            v = TemplateTool.expand(body, json: json)
        } else if body.hasPrefix("$") || body.hasPrefix("@json:") {
            v = JSONQuery.value(path: body.replacingOccurrences(of: "@json:", with: ""), json: json)
        } else {
            v = body
        }

        if let p = pattern {
            v = RegexTool.replace(v, pattern: p, template: replacement)
        }
        return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 解析 `url,{json}` 请求描述
    private func parseSpec(_ raw: String) -> (url: String, method: String, bodyTemplate: String?) {
        var r = raw
        var method = "GET"
        var body: String? = nil
        if let comma = r.range(of: ",{") {
            let spec = String(r[comma.upperBound...])
            r = String(r[r.startIndex..<comma.lowerBound])
            if let d = spec.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                method = Flex.str(obj["method"]).isEmpty ? "GET" : Flex.str(obj["method"]).uppercased()
                body = Flex.str(obj["body"])
                let u = Flex.str(obj["url"])
                if !u.isEmpty { r = u }
            }
        }
        return (r, method, body)
    }

    /// 构建请求（绝对 URL + 参数填充）
    private func buildRequest(_ raw: String, vars: [String: String]) -> (url: String, method: String, body: Data?) {
        var (url, method, bodyTemplate) = parseSpec(raw)
        func fill(_ s: String) -> String {
            var t = s
            for (k, v) in vars {
                let enc = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
                t = t.replacingOccurrences(of: "{{\(k)}}", with: enc)
                t = t.replacingOccurrences(of: "{\(k)}", with: enc)
            }
            return t
        }
        url = fill(url)
        if !url.hasPrefix("http") {
            // 相对 URL 用 source.url 补全；JS 书源的 source.url 常不是合法 URL，
            // 兜底用 jsLib 的 host[0]
            var base = baseURL
            if base == nil || base?.scheme == nil {
                if let h = Self.hosts(from: source).first, let u = URL(string: h) { base = u }
            }
            url = URLResolver.absolute(url, base: base)
        }
        var body: Data? = nil
        if let bt = bodyTemplate, method != "GET" {
            body = fill(bt).data(using: .utf8)
        }
        return (url, method, body)
    }

    private func requestText(_ req: (url: String, method: String, body: Data?)) async throws -> String {
        let d = try await SourceFetcher.data(req.url, headers: baseHeaders, method: req.method, body: req.body)
        return SourceFetcher.decode(d, contentType: nil)
    }

    // MARK: - 列表解析（JSON / CSS 双路径）

    private func usesJSONList(_ rule: String) -> Bool {
        let r = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.hasPrefix("$") || r.hasPrefix("@json:") || JSBridge.isJS(r)
    }

    private func parseBookList<Rule: BookListRuleLike>(text: String, rule: Rule, sourceURL: String) throws -> [Book] {
        let bl = rule.bookList.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bl.isEmpty else { throw FetchError.empty }

        if usesJSONList(bl) {
            var listText = text
            if JSBridge.isJS(bl) {
                guard let out = evalJS(bl, result: text, baseUrl: sourceURL) else { throw FetchError.empty }
                listText = out
            } else {
                let path = bl.replacingOccurrences(of: "@json:", with: "")
                listText = JSONQuery.evalString(path: path, jsonText: text).first ?? ""
            }
            guard let data = listText.data(using: .utf8),
                  let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { throw FetchError.empty }

            var books: [Book] = []
            for item in arr {
                let title = value(rule.name, json: item)
                guard !title.isEmpty else { continue }
                var b = Book(title: title)
                b.author = value(rule.author, json: item)
                b.kind = value(rule.kind, json: item)
                b.intro = value(rule.intro, json: item)
                b.lastChapter = value(rule.lastChapter, json: item)
                b.coverURL = value(rule.coverUrl, json: item)
                var bookURL = value(rule.bookUrl, json: item)
                if bookURL.isEmpty {
                    bookURL = value("$.book_url", json: item)
                }
                b.bookURL = bookURL
                b.tocURL = bookURL
                b.sourceID = source.id
                b.sourceName = source.name
                guard !bookURL.isEmpty else { continue }
                books.append(b)
            }
            return books
        }

        // CSS 路径
        let doc = try SwiftSoup.parse(text, sourceURL)
        let items = RuleEngine.elements(bl, doc: doc)
        let pageURL = URL(string: sourceURL)
        var books: [Book] = []
        for el in items {
            let title = RuleEngine.value(rule.name, root: el, baseURL: pageURL)
            guard !title.isEmpty else { continue }
            var b = Book(title: title)
            b.author = RuleEngine.value(rule.author, root: el, baseURL: pageURL)
            b.kind = RuleEngine.value(rule.kind, root: el, baseURL: pageURL)
            b.intro = RuleEngine.value(rule.intro, root: el, baseURL: pageURL)
            b.lastChapter = RuleEngine.value(rule.lastChapter, root: el, baseURL: pageURL)
            b.coverURL = RuleEngine.value(rule.coverUrl, root: el, baseURL: pageURL)
            var bookURL = RuleEngine.value(rule.bookUrl, root: el, baseURL: pageURL)
            if bookURL.isEmpty { bookURL = RuleEngine.value("tag.a@href", root: el, baseURL: pageURL) }
            b.bookURL = bookURL
            b.tocURL = bookURL
            b.sourceID = source.id
            b.sourceName = source.name
            guard !bookURL.isEmpty else { continue }
            books.append(b)
        }
        return books
    }

    // MARK: - 搜索

    func search(_ keyword: String, page: Int = 1) async throws -> [Book] {
        guard !source.searchUrl.isEmpty else { throw FetchError.badURL }
        var raw = source.searchUrl
        if JSBridge.isJS(raw) {
            guard let u = evalJS(raw, result: nil, baseUrl: nil, vars: ["key": keyword, "page": page]) else {
                throw FetchError.badURL
            }
            raw = u
        }
        let req = buildRequest(raw, vars: ["key": keyword, "page": String(page)])
        let text = try await requestText(req)
        return try parseBookList(text: text, rule: source.ruleSearch, sourceURL: req.url)
    }

    // MARK: - 详情

    func loadDetail(_ book: Book) async throws -> Book {
        var b = book
        let d = source.ruleDetail

        if JSBridge.isJS(d.initRule) {
            let res = pageResult(for: book.bookURL)
            guard let out = evalJS(d.initRule, result: res, baseUrl: book.bookURL) else {
                b.tocURL = book.bookURL
                return b
            }
            if let data = try? JSONSerialization.jsonObject(with: Data(out.utf8)) {
                let detail: Any
                if let arr = data as? [Any], let first = arr.first {
                    detail = first
                } else {
                    detail = data
                }
                let name = value(d.name, json: detail)
                if !name.isEmpty { b.title = name }
                let author = value(d.author, json: detail)
                if !author.isEmpty { b.author = author }
                let intro = value(d.intro, json: detail)
                if !intro.isEmpty { b.intro = intro }
                let kind = value(d.kind, json: detail)
                if !kind.isEmpty { b.kind = kind }
                let last = value(d.lastChapter, json: detail)
                if !last.isEmpty { b.lastChapter = last }
                let cover = value(d.coverUrl, json: detail)
                if !cover.isEmpty { b.coverURL = cover }
            }
            b.tocURL = book.bookURL
            // ruleBookInfo.tocUrl：result 注入为解码后的 JSON 对象（大灰狼语义，非 hex）
            if JSBridge.isJS(d.tocUrl),
               let jsonText = JSBridge.decodeDataURL(book.bookURL),
               let obj = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any],
               let parts = JSBridge.splitJS(d.tocUrl),
               let out = JSBridge.evaluate(source: source,
                                           code: "<js>\(parts.js)</js>",
                                           baseUrl: book.bookURL,
                                           vars: ["result": obj]) as? String,
               !out.isEmpty {
                b.tocURL = out
            }
            return b
        }

        // CSS 原路径
        let pageURL = URL(string: book.bookURL)
        let doc = try await SourceFetcher.html(book.bookURL, headers: baseHeaders)
        let name = RuleEngine.value(d.name, doc: doc, baseURL: pageURL)
        if !name.isEmpty { b.title = name }
        let author = RuleEngine.value(d.author, doc: doc, baseURL: pageURL)
        if !author.isEmpty { b.author = author }
        let intro = RuleEngine.value(d.intro, doc: doc, baseURL: pageURL)
        if !intro.isEmpty { b.intro = intro }
        let kind = RuleEngine.value(d.kind, doc: doc, baseURL: pageURL)
        if !kind.isEmpty { b.kind = kind }
        let last = RuleEngine.value(d.lastChapter, doc: doc, baseURL: pageURL)
        if !last.isEmpty { b.lastChapter = last }
        let cover = RuleEngine.value(d.coverUrl, doc: doc, baseURL: pageURL)
        if !cover.isEmpty { b.coverURL = cover }
        let toc = RuleEngine.value(d.tocUrl, doc: doc, baseURL: pageURL)
        b.tocURL = toc.isEmpty ? book.bookURL : toc
        if b.tocURL.isEmpty { b.tocURL = book.bookURL }
        return b
    }

    // MARK: - 目录

    func loadChapters(_ book: Book) async throws -> [Chapter] {
        let t = source.ruleToc
        let url = book.tocURL.isEmpty ? book.bookURL : book.tocURL

        if JSBridge.isJS(t.chapterList) {
            let res = pageResult(for: url)
            guard let out = evalJS(t.chapterList, result: res, baseUrl: url) else { throw FetchError.empty }
            guard let data = out.data(using: .utf8),
                  let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { throw FetchError.empty }

            var chapters: [Chapter] = []
            for (i, item) in arr.enumerated() {
                let name = value(t.chapterName, json: item)
                var link = value(t.chapterUrl, json: item)
                if link.isEmpty { link = value("$.toc_url", json: item) }
                guard !name.isEmpty, !link.isEmpty else { continue }
                let vip = value(t.isVip, json: item)
                chapters.append(Chapter(title: name, url: link, index: i,
                                        isVip: vip.contains("订阅") || vip.contains("VIP") || vip.contains("vip")))
            }
            return chapters
        }

        // CSS 原路径
        let doc = try await SourceFetcher.html(url, headers: baseHeaders)
        let pageURL = URL(string: url)
        let items = RuleEngine.elements(t.chapterList, doc: doc)
        var chapters: [Chapter] = []
        for el in items {
            let name = RuleEngine.value(t.chapterName, root: el, baseURL: pageURL)
            var link = RuleEngine.value(t.chapterUrl, root: el, baseURL: pageURL)
            if link.isEmpty { link = RuleEngine.value("tag.a@href", root: el, baseURL: pageURL) }
            guard !name.isEmpty, !link.isEmpty else { continue }
            let vip = RuleEngine.value(t.isVip, root: el, baseURL: pageURL)
            chapters.append(Chapter(title: name, url: link, index: chapters.count,
                                    isVip: vip.contains("订阅") || vip.contains("VIP") || vip.contains("vip")))
        }
        return chapters
    }

    // MARK: - 正文

    func loadContent(_ chapterURL: String) async throws -> String {
        if JSBridge.isJS(source.ruleContent.content) {
            let res = pageResult(for: chapterURL)
            guard let out = evalJS(source.ruleContent.content, result: res, baseUrl: chapterURL) else {
                throw FetchError.empty
            }
            return out
        }

        // CSS 原路径
        var url = chapterURL
        var collected: [String] = []
        var guardCount = 0

        while !url.isEmpty && guardCount < 4 {
            guardCount += 1
            let doc = try await SourceFetcher.html(url, headers: baseHeaders)
            let pageURL = URL(string: url)

            let raw = ruleWithHTMLSuffix(source.ruleContent.content)
            let html = RuleEngine.value(raw, doc: doc, baseURL: pageURL)
            let text = ContentCleaner.clean(html)
            if !text.isEmpty { collected.append(text) }

            let next = RuleEngine.value(source.ruleContent.nextContentUrl, doc: doc, baseURL: pageURL)
            if next.isEmpty || next == url { break }
            url = next
        }
        return collected.joined(separator: "\n\n")
    }

    /// 正文规则若没有显式取值动作，补上 @html，保住段落
    private func ruleWithHTMLSuffix(_ rule: String) -> String {
        guard !rule.isEmpty else { return rule }
        var branches: [String] = []
        for branch in rule.components(separatedBy: "||") {
            var parts = branch.components(separatedBy: "##")
            var body = parts[0]
            let actions = ["@text", "@html", "@all", "@outerHtml", "@ownText", "@href", "@src"]
            if !actions.contains(where: { body.hasSuffix($0) || body.contains($0 + "@") }) {
                body += "@html"
            }
            parts[0] = body
            branches.append(parts.joined(separator: "##"))
        }
        return branches.joined(separator: "||")
    }

    // MARK: - 发现页（explore）

    func exploreSections() async throws -> [ExploreSection] {
        guard !source.exploreUrl.isEmpty else { return [] }
        var raw = source.exploreUrl
        if JSBridge.isJS(raw) {
            guard let out = evalJS(raw, result: nil, baseUrl: nil) else { return [] }
            raw = out
        }
        guard let data = raw.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }

        var sections: [ExploreSection] = []
        for item in arr {
            guard let dict = item as? [String: Any] else { continue }
            let title = Flex.str(dict["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let url = Flex.str(dict["url"]).trimmingCharacters(in: .whitespacesAndNewlines)
            // 过滤 {{js}} 模板类（登录卡片等，页面里用登录按钮处理）
            if title.isEmpty || url.isEmpty || url.hasPrefix("{{") { continue }
            sections.append(ExploreSection(title: title, url: url, sourceID: source.id))
        }
        return sections
    }

    func exploreBooks(_ sectionURL: String) async throws -> [Book] {
        let req = buildRequest(sectionURL, vars: [:])
        let text = try await requestText(req)
        return try parseBookList(text: text, rule: source.ruleExplore, sourceURL: req.url)
    }

    // MARK: - 登录

    /// 执行书源 loginUrl 登录脚本（flag=主动登录时校验邮箱密码）
    func login(flag: Bool = true) async -> String {
        guard !source.loginUrl.isEmpty else { return "此书源没有登录脚本" }
        let js = source.loginUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrapped = JSBridge.isJS(js) ? js : "<js>\n\(js)\nlogin(\(flag ? "true" : "false"));\n</js>"
        JSBridge.evaluate(source: source, code: wrapped)
        // 判断是否已拿到 qttoken
        if cookieHasToken() {
            return "登录成功"
        }
        return "登录未完成，请检查邮箱 / 密码 / 密钥"
    }

    /// 是否已登录（cookie 含 qttoken）
    func cookieHasToken() -> Bool {
        let hosts = Self.hosts(from: source)
        for h in hosts {
            let c = AppStore.shared.cookie(for: h)
            if c.contains("qttoken=") && !c.contains("qttoken=;") { return true }
        }
        return false
    }

    /// 从 jsLib 提取 host 数组；无则用 bookSourceUrl
    static func hosts(from source: BookSource) -> [String] {
        var out: [String] = []
        if !source.jsLib.isEmpty {
            let pattern = #"host\s*=\s*\[(.*?)\]"#
            if let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
               let m = re.firstMatch(in: source.jsLib, range: NSRange(source.jsLib.startIndex..., in: source.jsLib)),
               let r = Range(m.range(at: 1), in: source.jsLib) {
                let body = String(source.jsLib[r])
                let urls = body.components(separatedBy: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "'\"[] "))
                }
                out = urls.filter { $0.hasPrefix("http") }
            }
        }
        if out.isEmpty && source.url.hasPrefix("http") { out.append(source.url) }
        return out
    }
}

// MARK: - 列表规则协议（SearchRule / ExploreRule 共用）

protocol BookListRuleLike {
    var bookList: String { get }
    var name: String { get }
    var author: String { get }
    var kind: String { get }
    var wordCount: String { get }
    var lastChapter: String { get }
    var intro: String { get }
    var coverUrl: String { get }
    var bookUrl: String { get }
}

extension BookSource.SearchRule: BookListRuleLike {}
extension BookSource.ExploreRule: BookListRuleLike {}
