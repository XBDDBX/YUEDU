import Foundation
import CoreFoundation

/// 一次导入解析的产物
struct SourceParseResult {
    /// 解析成功的书源
    var sources: [BookSource] = []
    /// 文本里识别到的订阅 / JSON 链接（每行一个）
    var urls: [String] = []
    /// 解析失败（识别到条目但缺 bookSourceName 等）的条数
    var failed: Int = 0
    /// 附加说明，用于给用户看
    var note: String = ""

    var isEmpty: Bool { sources.isEmpty && urls.isEmpty }

    var summary: String {
        var parts: [String] = []
        if !sources.isEmpty { parts.append("\(sources.count) 个书源") }
        if !urls.isEmpty { parts.append("\(urls.count) 个链接") }
        if failed > 0 { parts.append("\(failed) 条无法识别") }
        if parts.isEmpty { return "没有识别到内容" }
        return parts.joined(separator: "、")
    }
}

/// 书源导入解析：兼容 legado / 阅读 3.0 的各种导出形态
///
/// 支持的输入：
/// - 单个书源对象 `{ "bookSourceName": ... }`
/// - 书源数组 `[ {...}, {...} ]`
/// - 带壳合集 `{ "bookSources": [...] }` / `sources` / `data` / `list` / `items`
/// - 嵌套数组、文本里夹带说明文字（自动截取 JSON 段）
/// - 带 BOM、带 `//` `/* */` 注释、带尾逗号（JSON5 风格）
/// - 纯链接列表（一行一个订阅地址）
/// - GB18030 / UTF-8 编码文件
enum SourceImportParser {

    // MARK: - 对外

    static func parse(data: Data, label: String) -> SourceParseResult {
        guard let text = decode(data) else {
            var r = SourceParseResult()
            r.note = "\(label)不是可识别的文本编码"
            return r
        }
        return parse(text: text, label: label)
    }

    static func parse(text rawText: String, label: String) -> SourceParseResult {
        var result = SourceParseResult()
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            result.note = "\(label)是空的"
            return result
        }

        // 1) 先按 JSON 处理
        if let json = jsonObject(from: text) {
            collect(json, into: &result)
        }

        // 2) JSON 没解出书源时，再从文本里捞链接（纯链接列表的场景）
        if result.sources.isEmpty {
            result.urls = extractURLs(from: text)
        }

        if result.sources.isEmpty && result.urls.isEmpty {
            result.note = "\(label)里没有识别到书源 JSON，也没有链接"
        } else if result.sources.isEmpty {
            result.note = "\(label)里只有链接，将逐个拉取"
        }
        return result
    }

    // MARK: - 编码

    private static func decode(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return stripBOM(s) }
        // GB18030
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) {
            return stripBOM(s)
        }
        if let s = String(data: data, encoding: .nonLossyASCII) { return stripBOM(s) }
        return String(data: data, encoding: .isoLatin1).map(stripBOM)
    }

    private static func stripBOM(_ s: String) -> String {
        var out = s
        while let f = out.unicodeScalars.first, f.value == 0xFEFF {
            out.removeFirst()
        }
        return out
    }

    // MARK: - JSON 解析（含容错）

    private static func jsonObject(from text: String) -> Any? {
        // 原始
        if let obj = tryParse(text) { return obj }

        // 去掉注释与尾逗号
        let cleaned = removeComments(text)
        if let obj = tryParse(cleaned) { return obj }
        if let obj = tryParse(removeTrailingCommas(cleaned)) { return obj }

        // 文本里夹着说明：截取第一段 `[`…`]` 或 `{`…`}`
        if let slice = extractJSONSlice(cleaned) {
            if let obj = tryParse(slice) { return obj }
            if let obj = tryParse(removeTrailingCommas(slice)) { return obj }
        }
        return nil
    }

    private static func tryParse(_ s: String) -> Any? {
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    /// 状态机去注释：字符串内的 `//`、`/*` 不动
    static func removeComments(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var inString = false
        var escaped = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if inString {
                out.append(c)
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                i = s.index(after: i)
                continue
            }
            if c == "\"" {
                inString = true
                out.append(c)
                i = s.index(after: i)
                continue
            }
            if c == "/", s.index(after: i) < s.endIndex {
                let n = s[s.index(after: i)]
                if n == "/" {
                    // 行注释
                    var j = s.index(after: i)
                    while j < s.endIndex, s[j] != "\n" { j = s.index(after: j) }
                    i = j
                    continue
                } else if n == "*" {
                    var j = s.index(s.index(after: i), offsetBy: 1, limitedBy: s.endIndex) ?? s.endIndex
                    while j < s.endIndex {
                        if s[j] == "*", s.index(after: j) < s.endIndex, s[s.index(after: j)] == "/" {
                            j = s.index(after: s.index(after: j))
                            break
                        }
                        j = s.index(after: j)
                    }
                    i = j
                    continue
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    /// `,]` / `,}` → `]` / `}`
    static func removeTrailingCommas(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var inString = false
        var escaped = false
        let chars = Array(s)
        var idx = 0
        while idx < chars.count {
            let c = chars[idx]
            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                idx += 1
                continue
            }
            if c == "\"" {
                inString = true
                out.append(c)
                idx += 1
                continue
            }
            if c == "," {
                var j = idx + 1
                while j < chars.count, chars[j] == " " || chars[j] == "\n" || chars[j] == "\r" || chars[j] == "\t" {
                    j += 1
                }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" {
                    idx += 1
                    continue
                }
            }
            out.append(c)
            idx += 1
        }
        return out
    }

    /// 从混杂文本里截出最外层 JSON 段
    private static func extractJSONSlice(_ s: String) -> String? {
        guard let start = s.firstIndex(where: { $0 == "[" || $0 == "{" }) else { return nil }
        let open: Character = s[start] == "[" ? "[" : "{"
        let close: Character = open == "[" ? "]" : "}"
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < s.endIndex {
            let c = s[idx]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == open { depth += 1 }
                else if c == close {
                    depth -= 1
                    if depth == 0 {
                        return String(s[start...idx])
                    }
                }
            }
            idx = s.index(after: idx)
        }
        return depth > 0 ? String(s[start...]) : nil
    }

    // MARK: - 结构收集

    private static let wrapperKeys = ["bookSources", "bookSource", "sources", "source", "data", "list", "items", "result"]

    private static func collect(_ any: Any, into result: inout SourceParseResult) {
        if let dict = any as? [String: Any] {
            if dict["bookSourceName"] != nil || dict["bookSourceUrl"] != nil {
                if let src = BookSource(json: dict) {
                    result.sources.append(src)
                } else {
                    result.failed += 1
                }
                // 单对象本身也可能带 bookSources（极少见），继续往下探一层
            }
            for key in wrapperKeys {
                if let inner = dict[key] {
                    collect(inner, into: &result)
                }
            }
            // 未命名的合集：只要有一层是数组就继续挖
            if result.sources.isEmpty && result.failed == 0 {
                for (_, v) in dict {
                    if v is [Any] || v is [String: Any] {
                        collect(v, into: &result)
                    }
                }
            }
            return
        }
        if let arr = any as? [Any] {
            for item in arr { collect(item, into: &result) }
            return
        }
        if any is String {
            result.failed += 0
        }
    }

    // MARK: - 链接提取

    static func extractURLs(from text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let separators = CharacterSet(charactersIn: " \t\r\n\"'，,；;<>()（）[]【】")
        let pieces = text.components(separatedBy: separators)
        for piece in pieces {
            var s = piece
            while s.hasSuffix(".") || s.hasSuffix("。") || s.hasSuffix(",") || s.hasSuffix(")") {
                s.removeLast()
            }
            guard s.hasPrefix("http://") || s.hasPrefix("https://") else { continue }
            // 明显不是订阅地址的资源
            let lower = s.lowercased()
            let banned = [".jpg", ".jpeg", ".png", ".gif", ".webp", ".mp4", ".mp3", ".css", ".woff"]
            if banned.contains(where: { lower.hasSuffix($0) }) { continue }
            guard URL(string: s) != nil else { continue }
            if seen.insert(s).inserted { out.append(s) }
        }
        return out
    }
}
