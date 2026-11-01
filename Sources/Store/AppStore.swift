import Foundation
import Combine

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published var sources: [BookSource] = []
    @Published var books: [Book] = []
    @Published var settings = ReaderSettings()
    @Published var toast: String? = nil

    /// 书源运行时状态：变量 / 登录信息 / cookie（供 JSBridge 使用）
    struct SourceState: Codable {
        var variables: [String: String] = [:]     // sourceID -> 变量 JSON
        var loginInfo: [String: String] = [:]     // sourceID -> 登录信息 JSON
        var cookies: [String: String] = [:]       // host -> cookie 串
        var deviceID: String = ""
    }

    @Published private(set) var sourceState = SourceState()

    /// JS 运行时跨上下文暂存（java.put / java.get），内存级即可
    @Published var jsScratch: [String: String] = [:]

    private let root: URL
    private let cacheDir: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = base.appendingPathComponent("AuraRead", isDirectory: true)
        cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - 持久化

    private var sourcesFile: URL { root.appendingPathComponent("sources.json") }
    private var booksFile: URL { root.appendingPathComponent("books.json") }
    private var settingsFile: URL { root.appendingPathComponent("settings.json") }
    private var stateFile: URL { root.appendingPathComponent("state.json") }

    func load() {
        let dec = JSONDecoder()
        if let d = try? Data(contentsOf: sourcesFile),
           let v = try? dec.decode([BookSource].self, from: d) {
            sources = v.sorted { $0.order < $1.order }
        }
        if let d = try? Data(contentsOf: booksFile),
           let v = try? dec.decode([Book].self, from: d) {
            books = v
        }
        if let d = try? Data(contentsOf: settingsFile),
           let v = try? dec.decode(ReaderSettings.self, from: d) {
            settings = v
        }
        if let d = try? Data(contentsOf: stateFile),
           let v = try? dec.decode(SourceState.self, from: d) {
            sourceState = v
        }
        if sourceState.deviceID.isEmpty {
            sourceState.deviceID = Self.makeDeviceID()
            saveState()
        }
    }

    static func makeDeviceID() -> String {
        let chars = "0123456789abcdef"
        return String((0..<16).map { _ in chars.randomElement()! })
    }

    func saveState() {
        if let d = try? JSONEncoder().encode(sourceState) { try? d.write(to: stateFile) }
    }

    func saveSources() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(sources) { try? d.write(to: sourcesFile) }
    }

    func saveBooks() {
        let enc = JSONEncoder()
        if let d = try? enc.encode(books) { try? d.write(to: booksFile) }
    }

    func saveSettings() {
        if let d = try? JSONEncoder().encode(settings) { try? d.write(to: settingsFile) }
    }

    // MARK: - 书源

    var enabledSources: [BookSource] { sources.filter { $0.enabled } }

    @discardableResult
    func importSources(from data: Data) -> Int {
        let incoming = BookSource.decodeList(from: data)
        guard !incoming.isEmpty else { return 0 }
        var added = 0
        for var s in incoming {
            if let i = sources.firstIndex(where: { $0.name == s.name && $0.url == s.url }) {
                s.id = sources[i].id
                sources[i] = s
            } else {
                s.order = sources.count
                sources.append(s)
                added += 1
            }
        }
        saveSources()
        return added
    }

    func importSources(from urlString: String) async throws -> Int {
        let data = try await SourceFetcher.data(urlString)
        return importSources(from: data)
    }

    func deleteSource(_ source: BookSource) {
        sources.removeAll { $0.id == source.id }
        saveSources()
    }

    func toggleSource(_ source: BookSource) {
        if let i = sources.firstIndex(where: { $0.id == source.id }) {
            sources[i].enabled.toggle()
            saveSources()
        }
    }

    func updateSource(_ source: BookSource) {
        if let i = sources.firstIndex(where: { $0.id == source.id }) {
            sources[i] = source
            saveSources()
        }
    }

    func source(for id: UUID?) -> BookSource? {
        guard let id else { return nil }
        return sources.first { $0.id == id }
    }

    /// 支持发现页且启用的书源
    var explorableSources: [BookSource] {
        sources.filter { $0.enabled && !$0.exploreUrl.isEmpty }
    }

    // MARK: - 书源运行时状态（JSBridge 回调）

    func variable(for sourceID: UUID) -> String {
        sourceState.variables[sourceID.uuidString] ?? ""
    }

    func setVariable(_ value: String, for sourceID: UUID) {
        sourceState.variables[sourceID.uuidString] = value
        saveState()
    }

    func loginInfo(for sourceID: UUID) -> String {
        sourceState.loginInfo[sourceID.uuidString] ?? "{}"
    }

    func setLoginInfo(_ value: String, for sourceID: UUID) {
        sourceState.loginInfo[sourceID.uuidString] = value
        saveState()
    }

    func cookie(for host: String) -> String {
        sourceState.cookies[Self.cookieKey(host)] ?? ""
    }

    func setCookie(_ value: String, for host: String) {
        sourceState.cookies[Self.cookieKey(host)] = value
        saveState()
    }

    func removeCookie(for host: String) {
        sourceState.cookies.removeValue(forKey: Self.cookieKey(host))
        saveState()
    }

    /// cookie 以 host 主域为键，忽略协议与路径差异
    static func cookieKey(_ host: String) -> String {
        var h = host
        if let u = URL(string: h), let hostPart = u.host { h = hostPart }
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        return h
    }

    // MARK: - 书架

    func addBook(_ book: Book) -> Book {
        if let i = books.firstIndex(where: { $0.bookURL == book.bookURL && $0.sourceID == book.sourceID && !book.bookURL.isEmpty }) {
            books[i].lastReadAt = Date()
            saveBooks()
            return books[i]
        }
        var b = book
        b.addedAt = Date()
        b.lastReadAt = Date()
        books.insert(b, at: 0)
        saveBooks()
        return b
    }

    func updateBook(_ book: Book) {
        if let i = books.firstIndex(where: { $0.id == book.id }) {
            books[i] = book
            saveBooks()
        }
    }

    func removeBook(_ book: Book) {
        books.removeAll { $0.id == book.id }
        saveBooks()
    }

    func book(id: UUID) -> Book? { books.first { $0.id == id } }

    // MARK: - 章节缓存

    private func cacheURL(for chapter: Chapter) -> URL {
        cacheDir.appendingPathComponent("ch_\(chapter.id.uuidString).txt")
    }

    func cachedContent(for chapter: Chapter) -> String? {
        guard let s = try? String(contentsOf: cacheURL(for: chapter), encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    func storeContent(_ text: String, for chapter: Chapter) {
        try? text.write(to: cacheURL(for: chapter), atomically: true, encoding: .utf8)
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func cacheSize() -> Int64 {
        (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]))?
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(0) { $0 + Int64($1) } ?? 0
    }

    // MARK: - 内容加载

    func loadContent(for book: Book, chapter: Chapter) async throws -> String {
        if let c = cachedContent(for: chapter), !c.isEmpty { return c }

        if book.isLocal {
            let c = LocalLibrary.shared.content(book: book, chapter: chapter)
            if !c.isEmpty { storeContent(c, for: chapter) }
            return c
        }

        guard let source = source(for: book.sourceID) else { throw FetchError.badURL }
        let service = SourceService(source: source)
        let text = try await service.loadContent(chapter.url)
        if text.isEmpty { throw FetchError.empty }
        storeContent(text, for: chapter)
        return text
    }

    // MARK: - 提示

    func show(_ msg: String) {
        toast = msg
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toast == msg { toast = nil }
        }
    }
}
