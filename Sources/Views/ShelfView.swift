import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var epubBook: UTType { UTType(filenameExtension: "epub") ?? .data }
    static var mobiBook: UTType { UTType(filenameExtension: "mobi") ?? .data }
}

struct ShelfView: View {
    @EnvironmentObject var store: AppStore
    @State private var showImporter = false
    @State private var importing = false
    @State private var importError: String?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 16)]

    var body: some View {
        NavigationStack {
            ZStack {
                if store.books.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(store.books) { book in
                                NavigationLink {
                                    ReaderView(bookID: book.id)
                                } label: {
                                    BookCell(book: book)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        store.removeBook(book)
                                    } label: { Label("从书架移除", systemImage: "trash") }
                                }
                            }
                        }
                        .padding(16)
                    }
                }

                if importing {
                    ProgressView("正在导入…")
                        .padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .navigationTitle("书架")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: { Image(systemName: "square.and.arrow.down") }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.plainText, .epubBook, .data],
                          allowsMultipleSelection: true) { result in
                handleImport(result)
            }
            .alert("导入失败", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical").font(.system(size: 52)).foregroundStyle(.secondary)
            Text("书架还是空的").font(.headline)
            Text("去「找书」搜一本，或者从本地导入 TXT / EPUB")
                .font(.footnote).foregroundStyle(.secondary)
            Button {
                showImporter = true
            } label: {
                Label("导入本地书", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let e):
            importError = e.localizedDescription
        case .success(let urls):
            importing = true
            Task {
                let parsed: [(book: Book, error: String?)] = await Task.detached(priority: .userInitiated) {
                    var out: [(Book, String?)] = []
                    for url in urls {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        do {
                            let tmp = FileManager.default.temporaryDirectory
                                .appendingPathComponent(UUID().uuidString + "_" + url.lastPathComponent)
                            try? FileManager.default.removeItem(at: tmp)
                            try FileManager.default.copyItem(at: url, to: tmp)
                            let res = try LocalLibrary.shared.importBook(url: tmp)
                            try? FileManager.default.removeItem(at: tmp)
                            out.append((res.book, nil))
                        } catch {
                            out.append((Book(title: url.lastPathComponent), error.localizedDescription))
                        }
                    }
                    return out
                }.value

                var errs: [String] = []
                for item in parsed {
                    if let e = item.error {
                        errs.append("\(item.book.title): \(e)")
                    } else {
                        _ = store.addBook(item.book)
                    }
                }
                importing = false
                if errs.isEmpty { store.show("导入完成") } else { importError = errs.joined(separator: "\n") }
            }
        }
    }
}

struct BookCell: View {
    let book: Book

    private var palette: [Color] {
        let colors: [Color] = [.blue, .teal, .indigo, .orange, .pink, .green, .purple, .brown]
        let idx = abs(book.title.hashValue) % colors.count
        return [colors[idx].opacity(0.85), colors[(idx + 3) % colors.count].opacity(0.65)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 132)
                    .overlay(alignment: .center) {
                        Text(book.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                            .padding(8)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if book.progress > 0.01 {
                            Text("\(Int(book.progress * 100))%")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.black.opacity(0.45), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(5)
                        }
                    }

                if !book.coverURL.isEmpty, let u = URL(string: book.coverURL) {
                    AsyncImage(url: u) { phase in
                        if let img = phase.image {
                            img.resizable().aspectRatio(contentMode: .fill)
                                .frame(height: 132).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            Text(book.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(book.author.isEmpty ? (book.isLocal ? "本地书" : book.sourceName) : book.author)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
