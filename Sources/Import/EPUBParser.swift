import Foundation
import ZIPFoundation
import SwiftSoup

enum EPUBParser {
    struct Item {
        var title: String
        var text: String
    }

    struct Result {
        var title: String = ""
        var author: String = ""
        var description: String = ""
        var spine: [Item] = []
    }

    enum ParseError: LocalizedError {
        case badArchive
        case noContainer
        case noOPF
        var errorDescription: String? {
            switch self {
            case .badArchive: return "EPUB 压缩包打不开"
            case .noContainer: return "不是有效的 EPUB"
            case .noOPF: return "找不到书籍描述文件"
            }
        }
    }

    static func parse(url: URL) throws -> Result {
        guard let archive = Archive(url: url, accessMode: .read) else { throw ParseError.badArchive }

        func read(_ path: String) -> Data? {
            guard let entry = archive[path] else { return nil }
            var data = Data()
            do {
                _ = try archive.extract(entry) { chunk in data.append(chunk) }
            } catch { return nil }
            return data
        }

        // 1. container.xml
        guard let containerData = read("META-INF/container.xml") else { throw ParseError.noContainer }
        let containerXML = String(decoding: containerData, as: UTF8.self)
        guard let opfPath = firstAttribute(named: "full-path", in: containerXML) else { throw ParseError.noContainer }

        // 2. OPF
        guard let opfData = read(opfPath) else { throw ParseError.noOPF }
        let opf = String(decoding: opfData, as: UTF8.self)
        let opfDir = (opfPath as NSString).deletingLastPathComponent

        var result = Result()
        result.title = tagText("dc:title", in: opf)
        result.author = tagText("dc:creator", in: opf)
        result.description = tagText("dc:description", in: opf)

        // manifest: id -> href
        var manifest: [String: String] = [:]
        var properties: [String: String] = [:]
        let itemPattern = #"<item\b[^>]*>"#
        if let re = try? NSRegularExpression(pattern: itemPattern, options: []) {
            let ns = opf as NSString
            for m in re.matches(in: opf, options: [], range: NSRange(location: 0, length: ns.length)) {
                let tag = ns.substring(with: m.range)
                guard let id = firstAttribute(named: "id", in: tag),
                      let href = firstAttribute(named: "href", in: tag) else { continue }
                manifest[id] = href
                properties[id] = firstAttribute(named: "properties", in: tag) ?? ""
            }
        }

        // spine 顺序
        var spineIDs: [String] = []
        let refPattern = #"<itemref\b[^>]*>"#
        if let re = try? NSRegularExpression(pattern: refPattern, options: []) {
            let ns = opf as NSString
            for m in re.matches(in: opf, options: [], range: NSRange(location: 0, length: ns.length)) {
                let tag = ns.substring(with: m.range)
                if let idref = firstAttribute(named: "idref", in: tag) {
                    spineIDs.append(idref)
                }
            }
        }

        // 导航标题（toc.ncx 或 nav.xhtml）
        var tocTitles: [String: String] = [:]
        if let navID = properties.first(where: { $0.value.contains("nav") })?.key,
           let href = manifest[navID],
           let navData = read(join(opfDir, href)) {
            tocTitles = parseNavTitles(String(decoding: navData, as: UTF8.self))
        }

        for (index, id) in spineIDs.enumerated() {
            guard let href = manifest[id] else { continue }
            let path = join(opfDir, href)
            guard let data = read(path) else { continue }
            let html = SourceFetcher.decode(data, contentType: nil)
            let text = extractText(html)
            if text.count < 20 { continue }

            var title = tocTitles[href] ?? tocTitles[(href as NSString).lastPathComponent] ?? ""
            if title.isEmpty { title = headingTitle(html) }
            if title.isEmpty { title = "第 \(index + 1) 章" }
            result.spine.append(Item(title: title, text: text))
        }

        return result
    }

    // MARK: - 工具

    private static func join(_ dir: String, _ path: String) -> String {
        if path.hasPrefix("/") { return String(path.dropFirst()) }
        if dir.isEmpty { return path }
        return (dir as NSString).appendingPathComponent(path)
    }

    private static func firstAttribute(named name: String, in tag: String) -> String? {
        let patterns = ["\(name)=\"([^\"]*)\"", "\(name)='([^']*)'"]
        for p in patterns {
            if let r = tag.range(of: p, options: .regularExpression) {
                let sub = String(tag[r])
                if let eq = sub.firstIndex(of: "=") {
                    var v = String(sub[sub.index(after: eq)...])
                    v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    return v.isEmpty ? nil : v
                }
            }
        }
        return nil
    }

    private static func tagText(_ tag: String, in xml: String) -> String {
        let pattern = "<\(tag)[^>]*>([\\s\\S]*?)</\(tag)>"
        guard let r = xml.range(of: pattern, options: .regularExpression) else { return "" }
        var s = String(xml[r])
        if let gt = s.range(of: ">") { s = String(s[gt.upperBound...]) }
        if let lt = s.range(of: "</") { s = String(s[s.startIndex..<lt.lowerBound]) }
        return unescape(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unescape(_ s: String) -> String {
        var t = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (k, v) in map { t = t.replacingOccurrences(of: k, with: v) }
        return t
    }

    private static func parseNavTitles(_ xml: String) -> [String: String] {
        var out: [String: String] = [:]
        let pattern = #"<a\b[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return out }
        let ns = xml as NSString
        for m in re.matches(in: xml, options: [], range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges >= 3 else { continue }
            let href = ns.substring(with: m.range(at: 1)).components(separatedBy: "#").first ?? ""
            let raw = ns.substring(with: m.range(at: 2))
            let title = unescape(raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !href.isEmpty && !title.isEmpty {
                out[href] = title
                out[(href as NSString).lastPathComponent] = title
            }
        }
        return out
    }

    private static func headingTitle(_ html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html) else { return "" }
        if let h = try? doc.select("h1, h2, h3").first(), let t = try? h.text(), !t.isEmpty {
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let t = try? doc.title(), !t.isEmpty { return t }
        return ""
    }

    private static func extractText(_ html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html) else {
            return ContentCleaner.clean(html)
        }
        try? doc.select("script, style, nav, svg").remove()
        guard let body = doc.body() else { return ContentCleaner.clean(html) }
        var blocks: [String] = []
        let allElements = (try? body.getAllElements().array()) ?? []
        for el in allElements {
            let tagName = el.tagName().lowercased()
            guard ["p", "div", "h1", "h2", "h3", "h4", "li", "blockquote", "br"].contains(tagName) else { continue }
            if let t = try? el.ownText() {
                let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { blocks.append(s) }
            }
        }
        if blocks.isEmpty, let whole = try? body.text() {
            return whole.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return blocks.joined(separator: "\n")
    }
}
