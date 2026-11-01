import SwiftUI

struct BookDetailView: View {
    @EnvironmentObject var store: AppStore
    @State var book: Book

    @State private var busy = false
    @State private var status = ""
    @State private var readBookID: UUID?

    private var inShelf: Bool {
        store.books.contains { $0.bookURL == book.bookURL && $0.sourceID == book.sourceID && !book.bookURL.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.15))
                        Text(String(book.title.prefix(2)))
                            .font(.system(size: 26, weight: .bold)).foregroundStyle(.tint)
                    }
                    .frame(width: 92, height: 126)
                    .overlay {
                        if !book.coverURL.isEmpty, let u = URL(string: book.coverURL) {
                            AsyncImage(url: u) { p in
                                if let img = p.image {
                                    img.resizable().aspectRatio(contentMode: .fill)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                            .frame(width: 92, height: 126)
                            .clipped()
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(book.title).font(.system(size: 18, weight: .semibold)).lineLimit(3)
                        if !book.author.isEmpty {
                            Text(book.author).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        if !book.kind.isEmpty {
                            Text(book.kind).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Text("来源：\(book.sourceName)").font(.system(size: 11)).foregroundStyle(.secondary)
                        if !book.lastChapter.isEmpty {
                            Text("最新：\(book.lastChapter)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                }

                HStack(spacing: 12) {
                    Button {
                        prepare(read: true)
                    } label: {
                        HStack(spacing: 6) {
                            if busy { ProgressView().tint(.white).scaleEffect(0.8) }
                            Text(busy ? (status.isEmpty ? "准备中…" : status) : "开始阅读")
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)

                    if !inShelf {
                        Button {
                            prepare(read: false)
                        } label: {
                            Text("加入书架").frame(maxWidth: .infinity).padding(.vertical, 11)
                        }
                        .buttonStyle(.bordered)
                        .disabled(busy)
                    }
                }

                if !book.intro.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("简介").font(.system(size: 13, weight: .semibold))
                        Text(book.intro)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineSpacing(4)
                    }
                    .padding(.top, 4)
                }

                if !book.chapters.isEmpty {
                    HStack {
                        Text("目录").font(.system(size: 13, weight: .semibold))
                        Text("\(book.chapters.count) 章").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(book.chapters.prefix(8)) { ch in
                            Text(ch.title).font(.system(size: 13))
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $readBookID) { id in
            ReaderView(bookID: id)
        }
    }

    private func prepare(read: Bool) {
        guard let source = store.source(for: book.sourceID) else {
            store.show("这本书的书源已被删除")
            return
        }
        busy = true
        status = "读取详情"
        Task {
            let svc = SourceService(source: source)
            var b = book
            if let d = try? await svc.loadDetail(book) { b = d }

            status = "读取目录"
            if let chs = try? await svc.loadChapters(b), !chs.isEmpty {
                b.chapters = chs
            }

            let saved = store.addBook(b)
            book = saved
            busy = false
            status = ""
            if read {
                readBookID = saved.id
            } else {
                store.show("已加入书架")
            }
        }
    }
}
