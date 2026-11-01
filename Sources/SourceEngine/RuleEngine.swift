import Foundation
import SwiftSoup

/// legado / 阅读 3.0 规则解析引擎（兼容子集）
/// 支持：`||` 多规则兜底、`&&` 多段拼接、`@` 链式步骤、
///       `##正则##替换###`、`class.` / `id.` / `tag.` / `text.` 前缀、
///       `[n]` 索引、`-` 排除、`@json:` + JSONPath、常见取值动作。
enum RuleEngine {

    // MARK: - 对外

    static func values(_ rule: String?, doc: Document, baseURL: URL? = nil) -> [String] {
        values(rule, root: doc as Element, baseURL: baseURL)
    }

    static func values(_ rule: String?, root: Element, baseURL: URL? = nil) -> [String] {
        guard let raw = rule?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [] }
        for branch in raw.components(separatedBy: "||") {
            let b = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            if b.isEmpty { continue }
            let out = evalAndGroup(b, root: root, baseURL: baseURL)
            if !out.isEmpty { return out }
        }
        return []
    }

    static func value(_ rule: String?, doc: Document, baseURL: URL? = nil) -> String {
        values(rule, root: doc as Element, baseURL: baseURL).first ?? ""
    }

    static func value(_ rule: String?, root: Element, baseURL: URL? = nil) -> String {
        values(rule, root: root, baseURL: baseURL).first ?? ""
    }

    /// 取元素列表（用于 bookList / chapterList）
    static func elements(_ rule: String?, doc: Document) -> [Element] {
        elements(rule, root: doc as Element)
    }

    static func elements(_ rule: String?, root: Element) -> [Element] {
        guard let raw = rule?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [] }
        for branch in raw.components(separatedBy: "||") {
            var s = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            if let hash = s.range(of: "##") { s = String(s[s.startIndex..<hash.lowerBound]) }
            var out: [Element] = []
            for sub in s.components(separatedBy: "&&") {
                out.append(contentsOf: selectElements(sub.trimmingCharacters(in: .whitespaces), from: root))
            }
            if !out.isEmpty { return out }
        }
        return []
    }

    // MARK: - 分支求值

    private static func evalAndGroup(_ branch: String, root: Element, baseURL: URL?) -> [String] {
        var all: [String] = []
        for sub in branch.components(separatedBy: "&&") {
            let s = sub.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            all.append(contentsOf: evalSingle(s, root: root, baseURL: baseURL))
        }
        return all
    }

    private static func evalSingle(_ rule: String, root: Element, baseURL: URL?) -> [String] {
        // 1. 拆正则替换段
        var body = rule
        var pattern: String? = nil
        var replacement: String = ""

        if rule.contains("##") {
            let parts = rule.components(separatedBy: "##")
            body = parts[0]
            if parts.count > 1 { pattern = parts[1] }
            if parts.count > 2 { replacement = parts[2] }
        }

        // 2. JSON 规则
        if body.hasPrefix("@json:") || body.hasPrefix("@Json:") || body.hasPrefix("$.") || body == "$" {
            let path = body.replacingOccurrences(of: "@json:", with: "")
                            .replacingOccurrences(of: "@Json:", with: "")
            var results = JSONQuery.eval(path: path, element: root)
            if let p = pattern { results = results.map { RegexTool.replace($0, pattern: p, template: replacement) } }
            return results
        }

        // 3. 链式步骤
        let steps = splitSteps(body)
        var currentElements: [Element]? = nil
        var currentStrings: [String]? = nil

        for step in steps {
            let s = step.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }

            if let strs = currentStrings {
                // 字符串之后只允许再走一次正则/拼接，这里直接终止
                currentStrings = strs
                break
            }

            if isValueAction(s) {
                let els: [Element] = currentElements ?? ((try? root.getAllElements().array()) ?? [])
                currentStrings = els.compactMap { applyValue(s, to: $0, baseURL: baseURL) }
            } else {
                let roots: [Element] = currentElements ?? [root]
                var next: [Element] = []
                for r in roots {
                    next.append(contentsOf: selectElements(s, from: r))
                }
                currentElements = next
            }
        }

        var results: [String]
        if let strs = currentStrings {
            results = strs
        } else if let els = currentElements {
            results = els.compactMap { try? $0.text().trimmingCharacters(in: .whitespacesAndNewlines) }
        } else {
            results = []
        }

        results = results.filter { !$0.isEmpty }

        if let p = pattern {
            results = results.map { RegexTool.replace($0, pattern: p, template: replacement) }
            results = results.filter { !$0.isEmpty }
        }
        return results
    }

    private static func splitSteps(_ body: String) -> [String] {
        // 以 @ 分隔，但不拆 "@json:" 这类
        var steps: [String] = []
        var buf = ""
        var i = body.startIndex
        while i < body.endIndex {
            let c = body[i]
            if c == "@" {
                let rest = body[i...]
                if rest.hasPrefix("@json:") || rest.hasPrefix("@Json:") {
                    buf.append(c)
                } else {
                    steps.append(buf)
                    buf = ""
                }
            } else {
                buf.append(c)
            }
            i = body.index(after: i)
        }
        steps.append(buf)
        return steps.filter { !$0.isEmpty }
    }

    // MARK: - 选择器

    private static func selectElements(_ raw: String, from root: Element) -> [Element] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return [] }

        // 排除项：-class.xxx
        if s.hasPrefix("-") { return [] }

        // 索引 [n] / :eq(n)
        var index: Int? = nil
        if let r = s.range(of: #"\[-?\d+\]\s*$"#, options: .regularExpression) {
            let token = s[r].trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            index = Int(token)
            s = String(s[s.startIndex..<r.lowerBound])
        }

        var selected: [Element] = []

        if s == "children" || s == ">children" {
            selected = root.children().array()
        } else if s.hasPrefix("children.") {
            let cls = String(s.dropFirst(9))
            selected = root.children().array().filter { $0.hasClass(cls) }
        } else if s.hasPrefix("children") {
            selected = root.children().array()
        } else if s.hasPrefix("class.") {
            selected = (try? root.select("." + String(s.dropFirst(6))).array()) ?? []
        } else if s.hasPrefix("id.") {
            selected = (try? root.select("#" + String(s.dropFirst(3))).array()) ?? []
        } else if s.hasPrefix("tag.") {
            selected = (try? root.select(String(s.dropFirst(4))).array()) ?? []
        } else if s.hasPrefix("text.") {
            let kw = String(s.dropFirst(5))
            selected = (try? root.select(":contains(\(kw))").array()) ?? []
        } else {
            selected = (try? root.select(s).array()) ?? []
        }

        if let idx = index {
            if idx >= 0 {
                selected = idx < selected.count ? [selected[idx]] : []
            } else {
                let real = selected.count + idx
                selected = (real >= 0 && real < selected.count) ? [selected[real]] : []
            }
        }
        return selected
    }

    // MARK: - 取值动作

    private static let valueActions: Set<String> = [
        "text", "ownText", "all", "html", "outerHtml", "innerHtml",
        "href", "src", "content", "value", "title", "alt", "data-src"
    ]

    private static func isValueAction(_ s: String) -> Bool {
        if valueActions.contains(s) { return true }
        if s.hasPrefix("@") { return true }
        return false
    }

    private static func applyValue(_ action: String, to el: Element, baseURL: URL?) -> String? {
        let a = action.hasPrefix("@") ? String(action.dropFirst()) : action
        var raw: String = ""
        switch a {
        case "text": raw = (try? el.text()) ?? ""
        case "ownText": raw = el.ownText()
        case "all", "outerHtml": raw = (try? el.outerHtml()) ?? ""
        case "html", "innerHtml": raw = (try? el.html()) ?? ""
        case "href": raw = (try? el.attr("href")) ?? ""
        case "src": raw = (try? el.attr("src")) ?? (try? el.attr("data-src")) ?? ""
        case "content": raw = (try? el.attr("content")) ?? ""
        case "title": raw = (try? el.attr("title")) ?? ""
        case "alt": raw = (try? el.attr("alt")) ?? ""
        case "value": raw = (try? el.attr("value")) ?? ""
        default: raw = (try? el.attr(a)) ?? (try? el.text()) ?? ""
        }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }
        if ["href", "src", "data-src"].contains(a) {
            return URLResolver.absolute(raw, base: baseURL)
        }
        return raw
    }
}

// MARK: - 正则

enum RegexTool {    static func replace(_ input: String, pattern: String, template: String) -> String {
        guard !pattern.isEmpty else { return input }
        if pattern.hasPrefix(":") || pattern.hasPrefix("##") { return input }
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return re.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)
    }

    static func firstMatch(_ input: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let m = re.firstMatch(in: input, options: [], range: range) else { return nil }
        if m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: input) {
            return String(input[r])
        }
        if let r = Range(m.range, in: input) { return String(input[r]) }
        return nil
    }
}

// MARK: - URL 归一

enum URLResolver {
    static func absolute(_ raw: String, base: URL?) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return s }
        if s.hasPrefix("//") {
            return (base?.scheme ?? "https") + ":" + s
        }
        guard let b = base else { return s }
        if let u = URL(string: s, relativeTo: b)?.absoluteURL { return u.absoluteString }
        return s
    }
}

// MARK: - JSONPath（简化版）

enum JSONQuery {
    static func eval(path: String, element: Element) -> [String] {
        // 从元素文本里取出原始 JSON
        let raw = (try? element.text()) ?? ""
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return eval(path: path, json: obj)
    }

    static func eval(path: String, json: Any) -> [String] {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("@json:") { p = String(p.dropFirst(6)) }
        if p.hasPrefix("$") { p = String(p.dropFirst()) }
        p = p.replacingOccurrences(of: "..", with: ".")

        var current: [Any] = [json]
        var i = p.startIndex

        while i < p.endIndex {
            let c = p[i]
            if c == "." {
                i = p.index(after: i)
                var key = ""
                while i < p.endIndex && p[i] != "." && p[i] != "[" {
                    key.append(p[i]); i = p.index(after: i)
                }
                if !key.isEmpty {
                    current = current.flatMap { obj -> [Any] in
                        if let d = obj as? [String: Any], let v = d[key] { return [v] }
                        return []
                    }
                }
            } else if c == "[" {
                i = p.index(after: i)
                var inner = ""
                while i < p.endIndex && p[i] != "]" { inner.append(p[i]); i = p.index(after: i) }
                if i < p.endIndex { i = p.index(after: i) }
                if inner == "*" {
                    current = current.flatMap { obj -> [Any] in
                        if let a = obj as? [Any] { return a }
                        if let d = obj as? [String: Any] { return Array(d.values) }
                        return []
                    }
                } else if let n = Int(inner) {
                    current = current.compactMap { obj -> Any? in
                        if let a = obj as? [Any], n >= 0, n < a.count { return a[n] }
                        return nil
                    }
                }
            } else {
                i = p.index(after: i)
            }
        }

        return current.flatMap { scalar -> [String] in
            switch scalar {
            case let s as String: return [s]
            case let n as NSNumber: return [n.stringValue]
            case let d as [String: Any]:
                if let t = d["text"] as? String { return [t] }
                return []
            default: return []
            }
        }
    }
}

// MARK: - JSON 便捷工具（JS 书源 / JSON 响应场景）

extension JSONQuery {
    /// 从 JSON 文本直接按路径取值
    static func evalString(path: String, jsonText: String) -> [String] {
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return eval(path: path, json: obj)
    }

    /// 从字典/数组取值（单个元素的规则）
    static func value(path: String, json: Any) -> String {
        eval(path: path, json: json).first ?? ""
    }
}

/// `{{$.field}}` 模板展开：把文本里的 {{path}} 依次用 JSONPath 取值拼接
enum TemplateTool {
    static func expand(_ text: String, json: Any) -> String {
        var out = text
        let pattern = #"\{\{([^}]+)\}\}"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = NSRange(out.startIndex..<out.endIndex, in: out)
        var results: [(NSRange, String)] = []
        for m in re.matches(in: out, range: ns) {
            if m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: out) {
                let path = String(out[r]).trimmingCharacters(in: .whitespaces)
                let v = JSONQuery.value(path: path, json: json)
                results.append((m.range, v))
            }
        }
        for (range, value) in results.reversed() {
            if let r = Range(range, in: out) { out.replaceSubrange(r, with: value) }
        }
        return out
    }
}

// MARK: - 正文清洗

enum ContentCleaner {
    /// 把章节 HTML 洗成带段落的纯文本
    static func clean(_ html: String) -> String {
        var s = html
        // 常见噪音
        let noisePatterns = [
            #"<script[\s\S]*?</script>"#,
            #"<style[\s\S]*?</style>"#,
            #"<iframe[\s\S]*?</iframe>"#,
            #"&nbsp;"#,
            #"&ldquo;|&rdquo;|&hellip;|&mdash;"#
        ]
        for p in noisePatterns {
            s = s.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</p\s*>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<div[^>]*>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)

        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#39;", with: "'")
        s = s.replacingOccurrences(of: "&ldquo;", with: "“")
        s = s.replacingOccurrences(of: "&rdquo;", with: "”")
        s = s.replacingOccurrences(of: "&hellip;", with: "…")
        s = s.replacingOccurrences(of: "&mdash;", with: "—")

        let lines = s.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { line in
                // 过滤掉整行的站点广告
                let junk = ["请记住本站", "最新章节", "手机版阅读", "加入书签", "投推荐票", "本章未完", "点击下一页", "章节错误", "求收藏"]
                return !junk.contains { line.contains($0) && line.count < 60 }
            }
        return lines.joined(separator: "\n")
    }
}
