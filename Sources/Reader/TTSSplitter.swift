import Foundation

/// 一段待朗读的文本碎片（按句切分，避免一次合成太长卡住）
struct TTSChunk: Hashable {
    let text: String
    /// 在整页文本中的 UTF-16 起点
    let location: Int
    /// UTF-16 长度
    let length: Int

    var range: NSRange { NSRange(location: location, length: length) }
}

/// 把整页正文切成适合朗读的短句
///
/// 系统 TTS 一次读太多会卡、自定义 HTTP 引擎一次合成太长容易超时，
/// 所以按句子边界切，每段尽量接近 `limit` 个字符。
enum TTSSplitter {

    private static let terminators: Set<Character> = [
        "。", "！", "？", "；", "…", "\n",
        ".", "!", "?", ";"
    ]

    /// 太短的句子（如「对。」）不单独成段，等攒够再切
    private static let minLength = 18

    static func chunks(for text: String, limit: Int = 160) -> [TTSChunk] {
        var out: [TTSChunk] = []
        guard !text.isEmpty else { return out }

        var buf = ""
        var bufStart = 0
        var utf16Pos = 0

        func flush() {
            let trimmed = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { buf = ""; return }
            let leading = buf.prefix { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }.count
            let start = bufStart + leading
            out.append(TTSChunk(text: trimmed, location: start, length: trimmed.utf16.count))
            buf = ""
        }

        for ch in text {
            if buf.isEmpty { bufStart = utf16Pos }
            buf.append(ch)
            utf16Pos += String(ch).utf16.count

            let longEnough = buf.count >= limit
            let sentenceEnd = terminators.contains(ch) && buf.count >= minLength
            if longEnough || sentenceEnd {
                flush()
            }
        }
        flush()

        if out.isEmpty {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                out.append(TTSChunk(text: t, location: 0, length: t.utf16.count))
            }
        }
        return out
    }
}
