import Foundation

struct Chapter: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var url: String
    var index: Int
    var isVip: Bool = false
}

struct Book: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var author: String = ""
    var coverURL: String = ""
    var intro: String = ""
    var kind: String = ""
    var lastChapter: String = ""

    /// 来源书源 id；nil 表示本地导入的书
    var sourceID: UUID? = nil
    var sourceName: String = ""
    /// 书源里这本书的详情页地址
    var bookURL: String = ""
    /// 目录页地址（可能和 bookURL 不同）
    var tocURL: String = ""

    var chapters: [Chapter] = []
    var folder: String = "默认"

    // 阅读进度
    var currentChapterIndex: Int = 0
    /// 当前章内的字符偏移
    var currentOffset: Int = 0
    var progress: Double = 0

    var addedAt: Date = Date()
    var lastReadAt: Date = Date()

    // 本地书
    var isLocal: Bool = false
    var localPath: String = ""

    var totalChapters: Int { chapters.count }

    var displayCover: URL? {
        guard !coverURL.isEmpty else { return nil }
        return URL(string: coverURL)
    }
}

struct ReaderSettings: Codable, Hashable, Sendable {
    var fontSize: Double = 19
    var lineSpacing: Double = 8
    var paragraphSpacing: Double = 12
    var fontFamily: String = "system"   // system / serif / rounded / mono
    var themeIndex: Int = 0
    var marginH: Double = 20
    var marginV: Double = 16
    var pageAnimate: Bool = true

    // TTS
    var ttsRate: Double = 0.5
    var ttsPitch: Double = 1.0
    var ttsVoiceID: String = ""
    var ttsAutoNextChapter: Bool = true

    var theme: ReaderTheme { ReaderTheme.all[min(max(themeIndex, 0), ReaderTheme.all.count - 1)] }
}

struct ReaderTheme: Hashable {
    let name: String
    let bg: UInt
    let text: UInt
    let secondary: UInt

    static let all: [ReaderTheme] = [
        ReaderTheme(name: "纸白", bg: 0xF7F4EC, text: 0x2B2B2B, secondary: 0x8A8578),
        ReaderTheme(name: "米黄", bg: 0xEDE3CC, text: 0x3A3226, secondary: 0x8C8069),
        ReaderTheme(name: "护眼绿", bg: 0xD6E3D0, text: 0x2A3529, secondary: 0x6E7C6A),
        ReaderTheme(name: "夜间", bg: 0x15171A, text: 0xB9BEC6, secondary: 0x6C727C),
        ReaderTheme(name: "纯黑", bg: 0x000000, text: 0x9AA0A8, secondary: 0x585E66),
        ReaderTheme(name: "蓝灰", bg: 0x1B2430, text: 0xC3CCD8, secondary: 0x6B7889)
    ]
}
