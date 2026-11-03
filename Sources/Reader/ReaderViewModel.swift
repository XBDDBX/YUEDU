import SwiftUI
import Combine

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published var book: Book?
    @Published var chapterIndex: Int = 0
    @Published var content: String = ""
    @Published var attributed: NSAttributedString = NSAttributedString()
    @Published var pages: [NSRange] = []
    @Published var pageIndex: Int = 0
    @Published var loading: Bool = false
    @Published var errorText: String?

    @Published var showMenu: Bool = false
    @Published var showCatalog: Bool = false
    @Published var showSettings: Bool = false
    @Published var ttsHighlight: NSRange?

    private let store = AppStore.shared
    private var viewSize: CGSize = .zero
    private var pendingOffset: Int?
    private var lastSize: CGSize = .zero

    var pageInsets: UIEdgeInsets {
        let s = store.settings
        return UIEdgeInsets(top: CGFloat(s.marginV) + 10, left: CGFloat(s.marginH),
                            bottom: CGFloat(s.marginV) + 10, right: CGFloat(s.marginH))
    }

    /// 双栏只在屏宽足够时生效，窄屏自动退回单栏
    var columns: Int {
        guard store.settings.dualColumn, viewSize.width > 500 else { return 1 }
        return 2
    }

    var chapterTitle: String {
        guard let book, book.chapters.indices.contains(chapterIndex) else { return "" }
        return PurifyStore.shared.cleanTitle(book.chapters[chapterIndex].title)
    }

    var progressText: String {
        guard !pages.isEmpty else { return "" }
        return "\(pageIndex + 1)/\(pages.count)"
    }

    var overallProgress: Double {
        guard let book, !book.chapters.isEmpty else { return 0 }
        let cPart = Double(chapterIndex) / Double(book.chapters.count)
        let pPart = pages.isEmpty ? 0 : Double(pageIndex) / Double(pages.count) / Double(book.chapters.count)
        return min(max(cPart + pPart, 0), 1)
    }

    // MARK: - 打开

    func open(bookID: UUID) async {
        guard let b = store.book(id: bookID) else { return }
        book = b
        chapterIndex = b.currentChapterIndex
        pendingOffset = b.currentOffset
        await loadChapter(chapterIndex, offset: b.currentOffset)
    }

    func loadChapter(_ index: Int, offset: Int? = nil) async {
        guard let book, book.chapters.indices.contains(index) else { return }
        loading = true
        errorText = nil
        do {
            let text = try await store.loadContent(for: book, chapter: book.chapters[index])
            chapterIndex = index
            let rawTitle = book.chapters[index].title
            let title = PurifyStore.shared.cleanTitle(rawTitle)
            content = store.settings.showChapterTitle ? (title + "\n\n" + text) : text
            pendingOffset = offset
            pageIndex = 0
            rebuildPages()
            saveProgress()
            // 后台预取后面几章
            store.preload(book: book, from: index)
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    // MARK: - 排版

    func layout(size: CGSize, force: Bool = false) {
        guard size.width > 1, size.height > 1 else { return }
        if !force, abs(lastSize.width - size.width) < 1, abs(lastSize.height - size.height) < 1, !pages.isEmpty { return }
        lastSize = size
        viewSize = size
        rebuildPages()
    }

    func relayout() {
        guard viewSize.width > 1 else { return }
        rebuildPages()
    }

    private func rebuildPages() {
        guard viewSize.width > 1, content.isEmpty == false else {
            pages = []
            return
        }
        let settings = store.settings
        let attr = Paginator.attributed(content, settings: settings)
        attributed = attr
        let newPages = Paginator.paginate(attr, size: viewSize, insets: pageInsets, columns: columns)
        pages = newPages

        if let off = pendingOffset {
            let idx = newPages.firstIndex { NSLocationInRange(off, $0) } ?? 0
            pageIndex = min(idx, max(newPages.count - 1, 0))
            pendingOffset = nil
        } else {
            pageIndex = min(pageIndex, max(newPages.count - 1, 0))
        }
    }

    // MARK: - 翻页

    func nextPage() {
        if pageIndex + 1 < pages.count {
            pageIndex += 1
            saveProgressLight()
        } else {
            nextChapter()
        }
    }

    func prevPage() {
        if pageIndex > 0 {
            pageIndex -= 1
            saveProgressLight()
        } else {
            prevChapter()
        }
    }

    func nextChapter() {
        guard let book, chapterIndex + 1 < book.chapters.count else { return }
        Task { await loadChapter(chapterIndex + 1, offset: 0) }
    }

    func prevChapter() {
        guard chapterIndex > 0 else { return }
        Task {
            await loadChapter(chapterIndex - 1, offset: 0)
            if !pages.isEmpty { pageIndex = pages.count - 1 }
        }
    }

    func jump(to index: Int) {
        Task { await loadChapter(index, offset: 0) }
    }

    // MARK: - 进度

    func currentOffset() -> Int {
        guard pages.indices.contains(pageIndex) else { return 0 }
        return pages[pageIndex].location
    }

    private func saveProgressLight() {
        guard var b = book else { return }
        b.currentChapterIndex = chapterIndex
        b.currentOffset = currentOffset()
        b.progress = overallProgress
        b.lastReadAt = Date()
        book = b
        store.updateBook(b)
    }

    func saveProgress() {
        saveProgressLight()
    }

    // MARK: - 朗读

    func speakCurrentPage() {
        let full = attributed.string
        TTSEngine.shared.setContext(title: book?.title ?? "", subtitle: chapterTitle)
        if pages.indices.contains(pageIndex) {
            let ns = full as NSString
            let r = pages[pageIndex]
            if r.location + r.length <= ns.length {
                TTSEngine.shared.speak(ns.substring(with: r), settings: store.settings)
                return
            }
        }
        // 滚动模式 / 分页未就绪：整章朗读
        TTSEngine.shared.speak(full, settings: store.settings)
    }
}
