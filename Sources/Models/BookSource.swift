import Foundation

/// 阅读 3.0 / legado 兼容书源
struct BookSource: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var url: String
    var group: String = ""
    var type: Int = 0
    var enabled: Bool = true
    var comment: String = ""

    var searchUrl: String = ""
    var header: String = ""

    // legado 高级字段：发现页 / JS 运行时 / 登录
    var exploreUrl: String = ""
    var jsLib: String = ""
    var loginUrl: String = ""
    var loginUi: String = ""

    var ruleSearch: SearchRule = SearchRule()
    var ruleDetail: DetailRule = DetailRule()
    var ruleToc: TocRule = TocRule()
    var ruleContent: ContentRule = ContentRule()
    var ruleExplore: ExploreRule = ExploreRule()

    /// 排序用
    var order: Int = 0

    struct SearchRule: Codable, Hashable, Sendable {
        var bookList: String = ""
        var name: String = ""
        var author: String = ""
        var kind: String = ""
        var wordCount: String = ""
        var lastChapter: String = ""
        var intro: String = ""
        var coverUrl: String = ""
        var bookUrl: String = ""
    }

    struct DetailRule: Codable, Hashable, Sendable {
        var initRule: String = ""
        var name: String = ""
        var author: String = ""
        var intro: String = ""
        var kind: String = ""
        var lastChapter: String = ""
        var updateTime: String = ""
        var coverUrl: String = ""
        var tocUrl: String = ""
        var wordCount: String = ""
    }

    struct TocRule: Codable, Hashable, Sendable {
        var chapterList: String = ""
        var chapterName: String = ""
        var chapterUrl: String = ""
        var isVip: String = ""
        var updateTime: String = ""
        var nextTocUrl: String = ""
    }

    struct ContentRule: Codable, Hashable, Sendable {
        var content: String = ""
        var nextContentUrl: String = ""
        var title: String = ""
    }

    /// legado 发现页（explore）规则
    struct ExploreRule: Codable, Hashable, Sendable {
        var bookList: String = ""
        var name: String = ""
        var author: String = ""
        var kind: String = ""
        var wordCount: String = ""
        var lastChapter: String = ""
        var intro: String = ""
        var coverUrl: String = ""
        var bookUrl: String = ""
    }
}

// MARK: - 宽松 JSON 解析（书源里同一个字段可能是字符串 / 数字 / 布尔）

enum Flex {
    static func str(_ any: Any?) -> String {
        switch any {
        case let s as String: return s
        case let i as Int: return String(i)
        case let d as Double: return d == d.rounded() ? String(Int(d)) : String(d)
        case let b as Bool: return b ? "true" : "false"
        case let n as NSNumber: return n.stringValue
        case .none: return ""
        default: return ""
        }
    }

    static func bool(_ any: Any?, default def: Bool = true) -> Bool {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        let s = str(any).lowercased()
        if ["true", "1", "yes"].contains(s) { return true }
        if ["false", "0", "no"].contains(s) { return false }
        return def
    }

    static func int(_ any: Any?, default def: Int = 0) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String, let v = Int(s.trimmingCharacters(in: .whitespaces)) { return v }
        return def
    }

    static func dict(_ any: Any?) -> [String: Any] {
        (any as? [String: Any]) ?? [:]
    }
}

extension BookSource {
    init?(json: [String: Any]) {
        let name = Flex.str(json["bookSourceName"])
        guard !name.isEmpty else { return nil }
        self.name = name
        self.url = Flex.str(json["bookSourceUrl"])
        self.group = Flex.str(json["bookSourceGroup"])
        self.type = Flex.int(json["bookSourceType"])
        self.enabled = Flex.bool(json["enabled"], default: true)
        self.comment = Flex.str(json["bookSourceComment"])
        self.searchUrl = Flex.str(json["searchUrl"])
        self.header = Flex.str(json["header"])
        self.exploreUrl = Flex.str(json["exploreUrl"])
        self.jsLib = Flex.str(json["jsLib"])
        self.loginUrl = Flex.str(json["loginUrl"])
        self.loginUi = Flex.str(json["loginUi"])

        let rs = Flex.dict(json["ruleSearch"])
        self.ruleSearch = SearchRule(
            bookList: Flex.str(rs["bookList"]),
            name: Flex.str(rs["name"]),
            author: Flex.str(rs["author"]),
            kind: Flex.str(rs["kind"]),
            wordCount: Flex.str(rs["wordCount"]),
            lastChapter: Flex.str(rs["lastChapter"]),
            intro: Flex.str(rs["intro"]),
            coverUrl: Flex.str(rs["coverUrl"]),
            bookUrl: Flex.str(rs["bookUrl"])
        )

        let rd = Flex.dict(json["ruleBookInfo"])
        self.ruleDetail = DetailRule(
            initRule: Flex.str(rd["init"]),
            name: Flex.str(rd["name"]),
            author: Flex.str(rd["author"]),
            intro: Flex.str(rd["intro"]),
            kind: Flex.str(rd["kind"]),
            lastChapter: Flex.str(rd["lastChapter"]),
            updateTime: Flex.str(rd["updateTime"]),
            coverUrl: Flex.str(rd["coverUrl"]),
            tocUrl: Flex.str(rd["tocUrl"]),
            wordCount: Flex.str(rd["wordCount"])
        )

        let rt = Flex.dict(json["ruleToc"])
        self.ruleToc = TocRule(
            chapterList: Flex.str(rt["chapterList"]),
            chapterName: Flex.str(rt["chapterName"]),
            chapterUrl: Flex.str(rt["chapterUrl"]),
            isVip: Flex.str(rt["isVip"]),
            updateTime: Flex.str(rt["updateTime"]),
            nextTocUrl: Flex.str(rt["nextTocUrl"])
        )

        let rc = Flex.dict(json["ruleContent"])
        self.ruleContent = ContentRule(
            content: Flex.str(rc["content"]),
            nextContentUrl: Flex.str(rc["nextContentUrl"]),
            title: Flex.str(rc["title"])
        )

        let re = Flex.dict(json["ruleExplore"])
        self.ruleExplore = ExploreRule(
            bookList: Flex.str(re["bookList"]),
            name: Flex.str(re["name"]),
            author: Flex.str(re["author"]),
            kind: Flex.str(re["kind"]),
            wordCount: Flex.str(re["wordCount"]),
            lastChapter: Flex.str(re["lastChapter"]),
            intro: Flex.str(re["intro"]),
            coverUrl: Flex.str(re["coverUrl"]),
            bookUrl: Flex.str(re["bookUrl"])
        )
    }

    static func decodeList(from data: Data) -> [BookSource] {
        var out: [BookSource] = []
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            out = arr.compactMap { BookSource(json: $0) }
        } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let arr = obj["bookSources"] as? [[String: Any]] {
                out = arr.compactMap { BookSource(json: $0) }
            } else if let single = BookSource(json: obj) {
                out = [single]
            }
        }
        for i in out.indices { out[i].order = i }
        return out
    }
}
