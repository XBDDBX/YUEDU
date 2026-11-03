import Foundation

/// 书源静态体检结果（导入前就能看出这个源大概能不能用）
struct SourceHealth: Hashable {
    enum Level: Int, Comparable {
        case broken = 0     // 缺核心规则，导入也没法读
        case partial = 1    // 能读能搜，但用到了引擎不支持的写法
        case usable = 2     // 规则齐全

        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .broken: return "不可用"
            case .partial: return "部分"
            case .usable: return "可用"
            }
        }
    }

    var canSearch = false
    var canExplore = false
    var canToc = false
    var canContent = false
    var isJSONSource = false
    var usesJS = false
    /// 引擎不支持的写法（XPath 等）
    var unsupported: [String] = []
    /// 提示信息
    var notes: [String] = []

    var level: Level {
        if !canToc || !canContent { return .broken }
        if !unsupported.isEmpty { return .partial }
        if !canSearch && !canExplore { return .partial }
        return .usable
    }

    /// 0–100，导入列表里按这个排序/筛选
    var score: Int {
        var s = 0
        if canSearch { s += 35 }
        if canToc { s += 25 }
        if canContent { s += 30 }
        if canExplore { s += 10 }
        s -= min(unsupported.count * 8, 30)
        return max(0, min(100, s))
    }

    var shortTags: [String] {
        var t: [String] = []
        if canSearch { t.append("搜索") }
        if canExplore { t.append("发现") }
        if canToc { t.append("目录") }
        if canContent { t.append("正文") }
        if isJSONSource { t.append("JSON") }
        if usesJS { t.append("JS") }
        if !unsupported.isEmpty { t.append("写法受限") }
        return t
    }
}

/// 书源静态体检：不联网，只看规则本身
enum SourceDoctor {

    static func check(_ source: BookSource) -> SourceHealth {
        var h = SourceHealth()

        h.canSearch = !trim(source.searchUrl).isEmpty && !trim(source.ruleSearch.bookList).isEmpty
        h.canExplore = !trim(source.exploreUrl).isEmpty && !trim(source.ruleExplore.bookList).isEmpty
        h.canToc = !trim(source.ruleToc.chapterList).isEmpty
        h.canContent = !trim(source.ruleContent.content).isEmpty

        let allRules = everyRule(source)
        h.isJSONSource = allRules.contains { r in
            let t = trim(r).lowercased()
            return t.hasPrefix("$") || t.hasPrefix("@json:") || t.contains("@json:")
        }
        h.usesJS = allRules.contains { trim($0).contains("<js>") }

        if allRules.contains(where: isXPath) {
            h.unsupported.append("XPath")
        }
        if allRules.contains(where: { trim($0).contains("</js>") && !trim($0).contains("<js>") }) {
            h.unsupported.append("JS 片段不完整")
        }

        if trim(source.url).isEmpty {
            h.notes.append("没有书源地址")
        } else if URL(string: trim(source.url)) == nil {
            h.notes.append("书源地址格式不对")
        }
        if !h.canToc { h.notes.append("缺目录规则 chapterList") }
        if !h.canContent { h.notes.append("缺正文规则 content") }
        if !h.canSearch && !h.canExplore { h.notes.append("既不能搜索也没有发现页") }
        if trim(source.searchUrl).isEmpty && !trim(source.exploreUrl).isEmpty {
            h.notes.append("没有搜索地址，只能从发现页进")
        }
        if h.isJSONSource && !h.usesJS {
            h.notes.append("JSON 接口源")
        }
        return h
    }

    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func everyRule(_ s: BookSource) -> [String] {
        var out: [String] = [s.searchUrl, s.exploreUrl, s.loginUrl]
        out.append(contentsOf: [s.ruleSearch.bookList, s.ruleSearch.name, s.ruleSearch.author,
                                s.ruleSearch.intro, s.ruleSearch.coverUrl, s.ruleSearch.bookUrl,
                                s.ruleSearch.kind, s.ruleSearch.lastChapter, s.ruleSearch.wordCount])
        out.append(contentsOf: [s.ruleDetail.initRule, s.ruleDetail.name, s.ruleDetail.author,
                                s.ruleDetail.intro, s.ruleDetail.coverUrl, s.ruleDetail.tocUrl,
                                s.ruleDetail.kind, s.ruleDetail.lastChapter])
        out.append(contentsOf: [s.ruleToc.chapterList, s.ruleToc.chapterName, s.ruleToc.chapterUrl,
                                s.ruleToc.nextTocUrl])
        out.append(contentsOf: [s.ruleContent.content, s.ruleContent.nextContentUrl, s.ruleContent.title])
        out.append(contentsOf: [s.ruleExplore.bookList, s.ruleExplore.name, s.ruleExplore.bookUrl])
        return out.filter { !trim($0).isEmpty }
    }

    /// legado 的 XPath 写法：`//div`、`@xpath:`、`id.xx@//` 之类
    private static func isXPath(_ rule: String) -> Bool {
        let t = trim(rule)
        if t.hasPrefix("@xpath:") || t.hasPrefix("@XPath:") { return true }
        // 纯 XPath 开头（不在 `||` 后、也不是 http://）
        for branch in t.components(separatedBy: "||") {
            let b = trim(branch)
            if b.hasPrefix("//") && !b.hasPrefix("///") { return true }
            if b.contains("@xpath:") { return true }
        }
        return false
    }
}
