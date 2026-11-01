import Foundation

/// 本地书库：TXT / EPUB 导入与正文读取
final class LocalLibrary: @unchecked Sendable {
    static let shared = LocalLibrary()

    private let fm = FileManager.default
    private let bookDir: URL

    private init() {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        bookDir = docs.appendingPathComponent("LocalBooks", isDirectory: true)
        try? fm.createDirectory(at: bookDir, withIntermediateDirectories: true)
    }

    // MARK: - 导入

    struct ImportResult {
        var book: Book
        var chapters: [Chapter]
    }

    func importBook(url: URL) throws -> ImportResult {
        let ext = url.pathExtension.lowercased()
        let bookID = UUID()

        switch ext {
        case "epub":
            return try importEPUB(url: url, bookID: bookID)
        default:
            return try importTXT(url: url, bookID: bookID)
        }
    }

    private func importTXT(url: URL, bookID: UUID) throws -> ImportResult {
        let raw = try Data(contentsOf: url)
        let text = SourceFetcher.decode(raw, contentType: nil)
        guard !text.isEmpty else { throw FetchError.empty }

        let dest = bookDir.appendingPathComponent("\(bookID.uuidString).txt")
        try text.write(to: dest, atomically: true, encoding: .utf8)

        let ns = text as NSString
        let marks = ChapterSplitter.marks(in: text)
        var chapters: [Chapter] = []

        if marks.count >= 3 {
            for (i, m) in marks.enumerated() {
                let start = m.range.location
                let end = i + 1 < marks.count ? marks[i + 1].range.location : ns.length
                let len = max(end - start, 0)
                chapters.append(Chapter(title: m.title,
                                        url: "offset:\(start):\(len)",
                                        index: i))
            }
        } else {
            let chunk = 12_000
            var start = 0
            var idx = 0
            while start < ns.length {
                let len = min(chunk, ns.length - start)
                chapters.append(Chapter(title: "第 \(idx + 1) 节", url: "offset:\(start):\(len)", index: idx))
                start += len
                idx += 1
            }
        }

        var book = Book(title: url.deletingPathExtension().lastPathComponent)
        book.isLocal = true
        book.localPath = dest.path
        book.chapters = chapters
        book.sourceName = "本地"
        return ImportResult(book: book, chapters: chapters)
    }

    private func importEPUB(url: URL, bookID: UUID) throws -> ImportResult {
        let parsed = try EPUBParser.parse(url: url)
        guard !parsed.spine.isEmpty else { throw FetchError.empty }

        var chapters: [Chapter] = []
        let folder = bookDir.appendingPathComponent(bookID.uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        for (i, item) in parsed.spine.enumerated() {
            let fileName = "\(i).txt"
            let dest = folder.appendingPathComponent(fileName)
            try item.text.write(to: dest, atomically: true, encoding: .utf8)
            chapters.append(Chapter(title: item.title.isEmpty ? "第 \(i + 1) 章" : item.title,
                                    url: "\(bookID.uuidString)/\(fileName)",
                                    index: i))
        }

        var book = Book(title: parsed.title.isEmpty ? url.deletingPathExtension().lastPathComponent : parsed.title)
        book.author = parsed.author
        book.isLocal = true
        book.localPath = folder.path
        book.chapters = chapters
        book.sourceName = "本地"
        book.intro = parsed.description
        return ImportResult(book: book, chapters: chapters)
    }

    // MARK: - 读取

    func content(book: Book, chapter: Chapter) -> String {
        if book.localPath.hasSuffix(".txt"), chapter.url.hasPrefix("offset:") {
            let parts = chapter.url.components(separatedBy: ":")
            guard parts.count >= 3,
                  let off = Int(parts[1]), let len = Int(parts[2]),
                  let text = try? String(contentsOfFile: book.localPath, encoding: .utf8) else { return "" }
            let ns = text as NSString
            let safeOff = max(0, min(off, ns.length))
            let safeLen = max(0, min(len, ns.length - safeOff))
            return ns.substring(with: NSRange(location: safeOff, length: safeLen))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let path = bookDir.appendingPathComponent(chapter.url)
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }
}

// MARK: - TXT 章节切分

enum ChapterSplitter {
    struct Mark {
        let title: String
        let range: NSRange
    }

    static func marks(in text: String) -> [Mark] {
        let pattern = #"(?m)^[\s　]{0,6}(第[0-9零一二三四五六七八九十百千万两]{1,10}[章节回卷集部篇][^\n]{0,40}|Chapter\s+\d+[^\n]{0,40}|卷[0-9零一二三四五六七八九十百千]{1,10}[^\n]{0,40})$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = text as NSString
        let all = re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        return all.map { m in
            let title = ns.substring(with: m.range).trimmingCharacters(in: .whitespacesAndNewlines)
            return Mark(title: title, range: m.range)
        }
    }
}
