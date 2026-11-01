import SwiftUI

private struct SearchOutcome: Sendable {
    let name: String
    let books: [Book]
    let error: String?
}

struct SearchView: View {
    @EnvironmentObject var store: AppStore

    @State private var keyword = ""
    @State private var results: [Book] = []
    @State private var searching = false
    @State private var errors: [String] = []
    @State private var finished = 0
    @State private var total = 0
    @State private var showErrors = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar

                if searching {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("正在搜 \(finished)/\(total) 个书源…")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.bottom, 6)
                }

                if results.isEmpty && !searching {
                    ContentUnavailableView {
                        Label("搜书", systemImage: "magnifyingglass")
                    } description: {
                        Text(store.enabledSources.isEmpty
                             ? "先去「书源」导入 legado 书源，再回来搜"
                             : "输入书名或作者，会同时在 \(store.enabledSources.count) 个书源里搜")
                    }
                } else {
                    List {
                        ForEach(results) { book in
                            NavigationLink {
                                BookDetailView(book: book)
                            } label: {
                                ResultRow(book: book)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("找书")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showErrors = true
                    } label: {
                        Image(systemName: errors.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                    }
                    .disabled(errors.isEmpty)
                }
            }
            .sheet(isPresented: $showErrors) {
                NavigationStack {
                    List(errors, id: \.self) { Text($0).font(.footnote) }
                        .navigationTitle("失败的源")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { showErrors = false } } }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("书名 / 作者", text: $keyword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { startSearch() }
                if !keyword.isEmpty {
                    Button { keyword = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

            Button("搜索") { startSearch() }
                .buttonStyle(.borderedProminent)
                .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty || searching)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func startSearch() {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }
        let sources = store.enabledSources
        guard !sources.isEmpty else {
            store.show("还没有启用的书源")
            return
        }

        results = []
        errors = []
        finished = 0
        total = sources.count
        searching = true

        Task {
            await withTaskGroup(of: SearchOutcome.self) { group in
                for s in sources {
                    group.addTask {
                        do {
                            let books = try await SourceService(source: s).search(kw)
                            return SearchOutcome(name: s.name, books: books, error: nil)
                        } catch {
                            return SearchOutcome(name: s.name, books: [], error: error.localizedDescription)
                        }
                    }
                }
                for await outcome in group {
                    if !outcome.books.isEmpty {
                        let existing = Set(results.map { "\($0.title)|\($0.author)" })
                        let fresh = outcome.books.filter { !existing.contains("\($0.title)|\($0.author)") }
                        results.append(contentsOf: fresh)
                    }
                    if let err = outcome.error { errors.append("\(outcome.name): \(err)") }
                    finished += 1
                }
            }
            searching = false
            if results.isEmpty && !errors.isEmpty {
                store.show("全部书源都失败了，点右上角看原因")
            }
        }
    }
}

struct ResultRow: View {
    let book: Book

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12))
                Text(String(book.title.prefix(2)))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .frame(width: 46, height: 62)

            VStack(alignment: .leading, spacing: 3) {
                Text(book.title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                if !book.author.isEmpty {
                    Text(book.author).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                if !book.lastChapter.isEmpty {
                    Text("最新：\(book.lastChapter)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(book.sourceName).font(.system(size: 10))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
