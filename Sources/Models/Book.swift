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

    /// 翻页方式：0 覆盖 1 滑动 2 仿真 3 上下滚动 4 无动画
    var pageTurnMode: Int = 1
    /// 双栏排版（横屏 / iPad 有效）
    var dualColumn: Bool = false
    /// 首行缩进（单位：字符）
    var firstLineIndent: Double = 2
    /// 字距
    var letterSpacing: Double = 0.2
    /// 章节预缓存章数（0 关闭）
    var chapterPreload: Int = 1
    var showChapterTitle: Bool = true
    var statsEnabled: Bool = false

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

/// 自定义朗读引擎：请求一个返回音频（mp3/wav/JSON）的 TTS 服务
struct CustomTTSEngine: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var name: String = ""
    /// 请求地址，支持 {text} {voice} {rate} {pitch} 占位
    var url: String = ""
    var voice: String = ""
    /// GET（URL 占位）或 POST（JSON body / bodyTemplate）
    var method: String = "GET"
    /// 额外请求头，JSON 字符串，如 {"Authorization":"Bearer xxx"}
    var headers: String = ""
    /// POST 时的自定义 body；留空则用内置 {"text":…,"voice":…,"rate":…}
    var bodyTemplate: String = ""
    /// 返回内容类型：audio（直接音频）/ url（JSON 里是音频地址）/ base64（JSON 里是 base64）
    var responseType: String = "audio"
    /// responseType 为 url/base64 时，音频在 JSON 里的路径，如 data.audio
    var responsePath: String = ""
}

extension CustomTTSEngine {
    private enum CodingKeys: String, CodingKey {
        case id, name, url, voice, method, headers, bodyTemplate, responseType, responsePath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ""
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? "GET"
        headers = try c.decodeIfPresent(String.self, forKey: .headers) ?? ""
        bodyTemplate = try c.decodeIfPresent(String.self, forKey: .bodyTemplate) ?? ""
        responseType = try c.decodeIfPresent(String.self, forKey: .responseType) ?? "audio"
        responsePath = try c.decodeIfPresent(String.self, forKey: .responsePath) ?? ""
    }
}

// MARK: - 兼容解码：新字段缺省时用默认值，避免旧存档解码失败

extension ReaderSettings {
    private enum CodingKeys: String, CodingKey {
        case fontSize, lineSpacing, paragraphSpacing, fontFamily, themeIndex,
             marginH, marginV, pageAnimate,
             pageTurnMode, dualColumn, firstLineIndent, letterSpacing,
             chapterPreload, showChapterTitle, statsEnabled,
             ttsRate, ttsPitch, ttsVoiceID, ttsAutoNextChapter,
             ttsEngineID, customTTS
    }

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
        pageTurnMode = try c.decodeIfPresent(Int.self, forKey: .pageTurnMode) ?? 1
        dualColumn = try c.decodeIfPresent(Bool.self, forKey: .dualColumn) ?? false
        firstLineIndent = try c.decodeIfPresent(Double.self, forKey: .firstLineIndent) ?? 2
        letterSpacing = try c.decodeIfPresent(Double.self, forKey: .letterSpacing) ?? 0.2
        chapterPreload = try c.decodeIfPresent(Int.self, forKey: .chapterPreload) ?? 1
        showChapterTitle = try c.decodeIfPresent(Bool.self, forKey: .showChapterTitle) ?? true
        statsEnabled = try c.decodeIfPresent(Bool.self, forKey: .statsEnabled) ?? false
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
