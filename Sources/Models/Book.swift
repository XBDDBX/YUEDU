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
    // 自定义朗读引擎（"" = 用系统 TTS）
    var ttsEngineID: String = ""
    var customTTS: [CustomTTSEngine] = []

    var theme: ReaderTheme { ReaderTheme.all[min(max(themeIndex, 0), ReaderTheme.all.count - 1)] }
}

/// 自定义朗读引擎：请求一个返回音频（mp3/wav）的 TTS 服务
struct CustomTTSEngine: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var name: String = ""
    var url: String = ""          // 支持 {text} / {voice} 占位
    var voice: String = ""
    var method: String = "GET"    // GET（URL 占位）或 POST（JSON body）
}

// MARK: - 兼容解码：新字段缺省时用默认值，避免旧存档解码失败

extension ReaderSettings {
    private enum CodingKeys: String, CodingKey {
        case fontSize, lineSpacing, paragraphSpacing, fontFamily, themeIndex,
             marginH, marginV, pageAnimate,
             ttsRate, ttsPitch, ttsVoiceID, ttsAutoNextChapter,
             ttsEngineID, customTTS
    }

    /// 有自定义 init(from:) 后默认构造会被抑制，这里显式恢复（AppStore 依赖它）
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 19
        lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 8
        paragraphSpacing = try c.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? 12
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? "system"
        themeIndex = try c.decodeIfPresent(Int.self, forKey: .themeIndex) ?? 0
        marginH = try c.decodeIfPresent(Double.self, forKey: .marginH) ?? 20
        marginV = try c.decodeIfPresent(Double.self, forKey: .marginV) ?? 16
        pageAnimate = try c.decodeIfPresent(Bool.self, forKey: .pageAnimate) ?? true
        ttsRate = try c.decodeIfPresent(Double.self, forKey: .ttsRate) ?? 0.5
        ttsPitch = try c.decodeIfPresent(Double.self, forKey: .ttsPitch) ?? 1.0
        ttsVoiceID = try c.decodeIfPresent(String.self, forKey: .ttsVoiceID) ?? ""
        ttsAutoNextChapter = try c.decodeIfPresent(Bool.self, forKey: .ttsAutoNextChapter) ?? true
        ttsEngineID = try c.decodeIfPresent(String.self, forKey: .ttsEngineID) ?? ""
        customTTS = try c.decodeIfPresent([CustomTTSEngine].self, forKey: .customTTS) ?? []
    }
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
