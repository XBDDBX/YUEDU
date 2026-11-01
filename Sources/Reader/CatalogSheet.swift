import SwiftUI

struct CatalogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let book: Book?
    let current: Int
    var onSelect: (Int) -> Void

    @State private var keyword: String = ""

    private var chapters: [Chapter] {
        guard let book else { return [] }
        if keyword.isEmpty { return book.chapters }
        return book.chapters.filter { $0.title.localizedCaseInsensitiveContains(keyword) }
    }

    var body: some View {
        NavigationStack {
            List {
                if book == nil || (book?.chapters.isEmpty ?? true) {
                    ContentUnavailableView("还没有目录", systemImage: "list.bullet",
                                           description: Text("在书籍详情页点「刷新目录」"))
                } else {
                    ForEach(chapters) { ch in
                        Button {
                            onSelect(ch.index)
                            dismiss()
                        } label: {
                            HStack {
                                Text(ch.title)
                                    .font(.system(size: 14))
                                    .foregroundStyle(ch.index == current ? Color.accentColor : Color.primary)
                                    .lineLimit(1)
                                Spacer()
                                if ch.index == current {
                                    Image(systemName: "smallcircle.filled.circle").font(.system(size: 12))
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $keyword, prompt: "搜索章节")
            .navigationTitle("目录 · \(book?.chapters.count ?? 0) 章")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
