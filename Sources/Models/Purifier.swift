import Foundation
import Combine

/// 净化作用域，和「阅读」的替换规则一致：书名 / 正文 / 目录
enum PurifyScope: String, CaseIterable, Identifiable, Codable, Sendable {
    case bookName = "书名"
    case content = "正文"
    case catalog = "目录"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .bookName: return "textformat"
        case .content: return "doc.plaintext"
        case .catalog: return "list.bullet.indent"
        }
    }
}

/// 一条替换净化规则
struct PurifyRule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    var pattern: String = ""
    var replacement: String = ""
    var isRegex: Bool = true
    var enabled: Bool = true
    var scopeRaw: String = PurifyScope.content.rawValue
    /// 命中次数（运行时统计，不持久化）
    var hits: Int = 0

    var scope: PurifyScope {
        get { PurifyScope(rawValue: scopeRaw) ?? .content }
        set { scopeRaw = newValue.rawValue }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, pattern, replacement, isRegex, enabled, scopeRaw
    }
}

/// 净化引擎：规则持久化 + 文本清洗
@MainActor
final class PurifyStore: ObservableObject {
    static let shared = PurifyStore()

    @Published var enabled: Bool = true {
        didSet { save() }
    }

    @Published var rules: [PurifyRule] = [] {
        didSet { save() }
    }

    private var loaded = false
    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("AuraRead", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("purify.json")
    }

    private struct Payload: Codable {
        var enabled: Bool = true
        var rules: [PurifyRule] = []
    }

    private init() {
        load()
    }

    // MARK: - 持久化

    func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else {
            rules = Self.defaultRules()
            enabled = true
            save()
            return
        }
        enabled = p.enabled
        rules = p.rules
    }

    func save() {
        guard loaded else { return }
        var list = rules
        for i in list.indices { list[i].hits = 0 }
        let p = Payload(enabled: enabled, rules: list)
        if let d = try? JSONEncoder().encode(p) {
            try? d.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - 作用域

    func rules(for scope: PurifyScope) -> [PurifyRule] {
        rules.filter { $0.scope == scope }
    }

    var contentCount: Int { rules.filter { $0.scope == .content }.count }
    var catalogCount: Int { rules.filter { $0.scope == .catalog }.count }
    var enabledCount: Int { rules.filter { $0.enabled }.count }

    // MARK: - 应用

    /// 按作用域清洗文本。enabled 为假时原样返回。
    func apply(_ text: String, scope: PurifyScope) -> String {
        guard enabled, !text.isEmpty else { return text }
        var out = text
        for rule in rules where rule.enabled && rule.scope == scope {
            out = Self.applyOne(rule, to: out)
        }
        return out
    }

    /// 清洗章节标题（目录作用域）
    func cleanTitle(_ title: String) -> String {
        let t = apply(title, scope: .catalog)
        return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? title : t
    }

    nonisolated static func applyOne(_ rule: PurifyRule, to text: String) -> String {
        guard !rule.pattern.isEmpty else { return text }
        if rule.isRegex {
            guard let re = try? NSRegularExpression(
                pattern: rule.pattern,
                options: [.dotMatchesLineSeparators, .caseInsensitive]
            ) else { return text }
            let range = NSRange(location: 0, length: (text as NSString).length)
            return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: rule.replacement)
        }
        return text.replacingOccurrences(of: rule.pattern, with: rule.replacement)
    }

    /// 规则编辑器里的命中预览
    nonisolated static func preview(_ text: String, rule: PurifyRule) -> (String, Int) {
        guard !rule.pattern.isEmpty else { return (text, 0) }
        if rule.isRegex {
            guard let re = try? NSRegularExpression(
                pattern: rule.pattern,
                options: [.dotMatchesLineSeparators, .caseInsensitive]
            ) else { return (text, 0) }
            let range = NSRange(location: 0, length: (text as NSString).length)
            let n = re.numberOfMatches(in: text, options: [], range: range)
            let out = re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: rule.replacement)
            return (out, n)
        }
        let parts = text.components(separatedBy: rule.pattern)
        return (text.replacingOccurrences(of: rule.pattern, with: rule.replacement), max(parts.count - 1, 0))
    }

    // MARK: - 编辑

    func add(_ rule: PurifyRule) {
        var r = rule
        if r.name.trimmingCharacters(in: .whitespaces).isEmpty {
            r.name = "未命名规则"
        }
        rules.append(r)
    }

    func update(_ rule: PurifyRule) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[i] = rule
    }

    func delete(_ rule: PurifyRule) {
        rules.removeAll { $0.id == rule.id }
    }

    func toggle(_ rule: PurifyRule) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[i].enabled.toggle()
    }

    func move(from: IndexSet, to: Int) {
        rules.move(fromOffsets: from, toOffset: to)
    }

    // MARK: - 导入导出

    func exportData() -> Data? {
        var list = rules
        for i in list.indices { list[i].hits = 0 }
        return try? JSONEncoder().encode(list)
    }

    @discardableResult
    func importData(_ data: Data) -> Int {
        guard let incoming = try? JSONDecoder().decode([PurifyRule].self, from: data) else { return 0 }
        var added = 0
        for var r in incoming {
            r.id = UUID()
            if r.name.isEmpty { r.name = r.pattern }
            rules.append(r)
            added += 1
        }
        return added
    }

    // MARK: - 内置规则

    static func defaultRules() -> [PurifyRule] {
        [
            PurifyRule(
                name: "去除站点广告尾巴",
                pattern: "(?m)^.*(本章未完|请收藏本站|最新网址|手机版阅读网址|加入书签|本章完[，,].*).*$",
                replacement: "",
                isRegex: true,
                enabled: true,
                scopeRaw: PurifyScope.content.rawValue
            ),
            PurifyRule(
                name: "合并多余空行",
                pattern: "\\n{3,}",
                replacement: "\n\n",
                isRegex: true,
                enabled: true,
                scopeRaw: PurifyScope.content.rawValue
            ),
            PurifyRule(
                name: "去掉章节名后的页码",
                pattern: "\\s*[\\(（]\\s*\\d+\\s*/\\s*\\d+\\s*[\\)）]\\s*$",
                replacement: "",
                isRegex: true,
                enabled: true,
                scopeRaw: PurifyScope.catalog.rawValue
            ),
            PurifyRule(
                name: "去掉目录里的站名后缀",
                pattern: "(?i)\\s*[-_—]?\\s*(最新章节|全文阅读|无弹窗|笔趣阁|顶点小说).*$",
                replacement: "",
                isRegex: true,
                enabled: true,
                scopeRaw: PurifyScope.catalog.rawValue
            )
        ]
    }
}
