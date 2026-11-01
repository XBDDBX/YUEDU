import Foundation
import SwiftSoup

/// 一次书源请求的上下文
struct SourceService {
    let source: BookSource

    var baseHeaders: [String: String] {
        SourceFetcher.parseHeaders(source.header)
    }

    var baseURL: URL? {
        URL(string: source.url.hasSuffix("/") ? source.url : source.url + "/")
    }

    // MARK: - 搜索

    func search(_ keyword: String, page: Int = 1) async throws -> [Book] {
        guard !source.searchUrl.isEmpty else { throw FetchError.badURL }
        let req = buildSearchRequest(keyword: keyword, page: page)
        let doc = try await fetch(req)

        var books: [Book] = []
        let items = RuleEngine.elements(source.ruleSearch.bookList, doc: doc)
        let pageURL = URL(string: req.url)

        for el in items {
            let title = RuleEngine.value(source.ruleSearch.name, root: el, baseURL: pageURL)
            guard !title.isEmpty else { continue }

            var b = Book(title: title)
            b.author = RuleEngine.value(source.ruleSearch.author, root: el, baseURL: pageURL)
            b.kind = RuleEngine.value(source.ruleSearch.kind, root: el, baseURL: pageURL)
            b.intro = RuleEngine.value(source.ruleSearch.intro, root: el, baseURL: pageURL)
            b.lastChapter = RuleEngine.value(source.ruleSearch.lastChapter, root: el, baseURL: pageURL)
            b.coverURL = RuleEngine.value(source.ruleSearch.coverUrl, root: el, baseURL: pageURL)
            var bookURL = RuleEngine.value(source.ruleSearch.bookUrl, root: el, baseURL: pageURL)
            if bookURL.isEmpty { bookURL = RuleEngine.value("tag.a@href", root: el, baseURL: pageURL) }
            b.bookURL = bookURL
            b.tocURL = bookURL
            b.sourceID = source.id
            b.sourceName = source.name
            guard !bookURL.isEmpty else { continue }
            books.append(b)
        }
        return books
    }

    private struct Request {
        var url: String
        var method: String = "GET"
        var body: Data? = nil
    }

    private func buildSearchRequest(keyword: String, page: Int) -> Request {
        var raw = source.searchUrl
        var method = "GET"
        var bodyTemplate: String? = nil

        // legado 的 POST 写法: url,{"method":"POST","body":"..."}
        if let comma = raw.range(of: ",{") {
            let spec = String(raw[comma.upperBound...])
            raw = String(raw[raw.startIndex..<comma.lowerBound])
            if let d = spec.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                method = Flex.str(obj["method"]).isEmpty ? "GET" : Flex.str(obj["method"]).uppercased()
                bodyTemplate = Flex.str(obj["body"])
                raw = Flex.str(obj["url"]).isEmpty ? raw : Flex.str(obj["url"])
            }
        }

        func fill(_ s: String) -> String {
            var t = s
            let enc = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
            t = t.replacingOccurrences(of: "{{key}}", with: enc)
            t = t.replacingOccurrences(of: "{{page}}", with: String(page))
            t = t.replacingOccurrences(of: "{key}", with: enc)
            t = t.replacingOccurrences(of: "{page}", with: String(page))
            return t
        }

        var finalURL = fill(raw)
        if !finalURL.hasPrefix("http") {
            finalURL = URLResolver.absolute(finalURL, base: URL(string: source.url.hasSuffix("/") ? source.url : source.url + "/"))
        }
        var body: Data? = nil
        if let bt = bodyTemplate, method != "GET" {
            body = fill(bt).data(using: .utf8)
        }
        return Request(url: finalURL, method: method, body: body)
    }

    private func fetch(_ req: Request) async throws -> Document {
        try await SourceFetcher.html(req.url, headers: baseHeaders, method: req.method, body: req.body)
    }

    // MARK: - 详情

    func loadDetail(_ book: Book) async throws -> Book {
        var b = book
        let pageURL = URL(string: book.bookURL)
        let doc = try await SourceFetcher.html(book.bookURL, headers: baseHeaders)

        let d = source.ruleDetail
        let name = RuleEngine.value(d.name, doc: doc, baseURL: pageURL)
        if !name.isEmpty { b.title = name }
        let author = RuleEngine.value(d.author, doc: doc, baseURL: pageURL)
        if !author.isEmpty { b.author = author }
        let intro = RuleEngine.value(d.intro, doc: doc, baseURL: pageURL)
        if !intro.isEmpty { b.intro = intro }
        let kind = RuleEngine.value(d.kind, doc: doc, baseURL: pageURL)
        if !kind.isEmpty { b.kind = kind }
        let last = RuleEngine.value(d.lastChapter, doc: doc, baseURL: pageURL)
        if !last.isEmpty { b.lastChapter = last }
        let cover = RuleEngine.value(d.coverUrl, doc: doc, baseURL: pageURL)
        if !cover.isEmpty { b.coverURL = cover }
        let toc = RuleEngine.value(d.tocUrl, doc: doc, baseURL: pageURL)
        b.tocURL = toc.isEmpty ? book.bookURL : toc
        if b.tocURL.isEmpty { b.tocURL = book.bookURL }
        return b
    }

    // MARK: - 目录

    func loadChapters(_ book: Book) async throws -> [Chapter] {
        let url = book.tocURL.isEmpty ? book.bookURL : book.tocURL
        let doc = try await SourceFetcher.html(url, headers: baseHeaders)
        let pageURL = URL(string: url)
        let t = source.ruleToc

        let items = RuleEngine.elements(t.chapterList, doc: doc)
        var chapters: [Chapter] = []
        for el in items {
            let name = RuleEngine.value(t.chapterName, root: el, baseURL: pageURL)
            var link = RuleEngine.value(t.chapterUrl, root: el, baseURL: pageURL)
            if link.isEmpty { link = RuleEngine.value("tag.a@href", root: el, baseURL: pageURL) }
            guard !name.isEmpty, !link.isEmpty else { continue }
            let vip = RuleEngine.value(t.isVip, root: el, baseURL: pageURL)
            chapters.append(Chapter(title: name, url: link, index: chapters.count,
                                    isVip: vip.contains("订阅") || vip.contains("VIP") || vip.contains("vip")))
        }
        return chapters
    }

    // MARK: - 正文

    func loadContent(_ chapterURL: String) async throws -> String {
        var url = chapterURL
        var collected: [String] = []
        var guardCount = 0

        while !url.isEmpty && guardCount < 4 {
            guardCount += 1
            let doc = try await SourceFetcher.html(url, headers: baseHeaders)
            let pageURL = URL(string: url)

            let raw = ruleWithHTMLSuffix(source.ruleContent.content)
            let html = RuleEngine.value(raw, doc: doc, baseURL: pageURL)
            let text = ContentCleaner.clean(html)
            if !text.isEmpty { collected.append(text) }

            let next = RuleEngine.value(source.ruleContent.nextContentUrl, doc: doc, baseURL: pageURL)
            if next.isEmpty || next == url { break }
            url = next
        }
        return collected.joined(separator: "\n\n")
    }

    /// 正文规则若没有显式取值动作，补上 @html，保住段落
    private func ruleWithHTMLSuffix(_ rule: String) -> String {
        guard !rule.isEmpty else { return rule }
        var branches: [String] = []
        for branch in rule.components(separatedBy: "||") {
            var parts = branch.components(separatedBy: "##")
            var body = parts[0]
            let actions = ["@text", "@html", "@all", "@outerHtml", "@ownText", "@href", "@src"]
            if !actions.contains(where: { body.hasSuffix($0) || body.contains($0 + "@") }) {
                body += "@html"
            }
            parts[0] = body
            branches.append(parts.joined(separator: "##"))
        }
        return branches.joined(separator: "||")
    }
}
