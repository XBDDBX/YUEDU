import SwiftUI

/// 发现页：按书源展示探索分类，进入分类拉书单，点书进详情
struct DiscoverView: View {
    @EnvironmentObject var store: AppStore

    @State private var sourceID: UUID?
    @State private var sections: [ExploreSection] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var loadedOnce = false

    var body: some View {
        NavigationStack {
            Group {
                if store.explorableSources.isEmpty {
                    ContentUnavailableView(
                        "没有支持发现页的书源",
                        systemImage: "square.grid.2x2",
                        description: Text("导入带发现页（exploreUrl）的书源后，这里会出现分类。\n例如「大灰狼」这类聚合书源。")
                    )
                } else {
                    List {
                        if store.explorableSources.count > 1 {
                            Section {
                                Picker("书源", selection: Binding(
                                    get: { sourceID ?? store.explorableSources.first?.id },
                                    set: { sourceID = $0; Task { await load() } }
                                )) {
                                    ForEach(store.explorableSources) { s in
                                        Text(s.name).tag(s.id as UUID?)
                                    }
                                }
                            }
                        }
                        Section("分类") {
                            if sections.isEmpty {
                                if loading {
                                    HStack { Spacer(); ProgressView(); Spacer() }
                                } else {
                                    Text("拉不到分类，点右上角刷新重试")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            ForEach(sections) { sec in
                                NavigationLink(value: sec) {
                                    HStack {
                                        Image(systemName: "folder")
                                            .font(.system(size: 15))
                                            .foregroundStyle(.tint)
                                        Text(sec.title)
                                    }
                                }
                            }
                        }
                        if let errorText {
                            Section {
                                Text(errorText).font(.footnote).foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("发现")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.explorableSources.isEmpty)
                }
            }
            .navigationDestination(for: ExploreSection.self) { sec in
                ExploreBookListView(section: sec)
            }
            .task {
                if sourceID == nil { sourceID = store.explorableSources.first?.id }
                if !loadedOnce {
                    loadedOnce = true
                    await load()
                }
            }
        }
    }

    private func load() async {
        guard let sid = sourceID ?? store.explorableSources.first?.id,
              let src = store.source(for: sid) else { return }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            sections = try await SourceService(source: src).exploreSections()
        } catch {
            errorText = "加载失败：\(error.localizedDescription)"
        }
    }
}

/// 分类内的书单
struct ExploreBookListView: View {
    let section: ExploreSection
    @EnvironmentObject var store: AppStore

    @State private var books: [Book] = []
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        Group {
            if books.isEmpty && !loading {
                if let errorText {
                    ContentUnavailableView("加载失败", systemImage: "wifi.exclamationmark",
                                           description: Text(errorText))
                } else {
                    ProgressView()
                }
            } else {
                List {
                    ForEach(books) { book in
                        NavigationLink {
                            BookDetailView(book: book)
                                .environmentObject(store)
                        } label: {
                            ResultRow(book: book)
                        }
                    }
                    if loading { HStack { Spacer(); ProgressView(); Spacer() } }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
    }

    private func load() async {
        guard let src = store.source(for: section.sourceID) else { return }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            books = try await SourceService(source: src).exploreBooks(section.url)
        } catch {
            errorText = "拉书单失败：\(error.localizedDescription)"
        }
    }
}
