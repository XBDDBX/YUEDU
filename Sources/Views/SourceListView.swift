import SwiftUI
import UniformTypeIdentifiers

struct SourceListView: View {
    @EnvironmentObject var store: AppStore

    @State private var showImportURL = false
    @State private var showImporter = false
    @State private var editing: BookSource?
    @State private var urlText = ""
    @State private var busy = false
    @State private var alertText: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.sources.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("还没有书源").font(.system(size: 14, weight: .medium))
                            Text("支持导入 legado / 阅读 3.0 的 bookSource JSON。\n导入后就能直接搜书、追更。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                    ForEach(store.sources) { s in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                                Text(s.url).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                HStack(spacing: 6) {
                                    if !s.group.isEmpty {
                                        Text(s.group).font(.system(size: 10))
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Color(.tertiarySystemFill), in: Capsule())
                                    }
                                    Text(s.searchUrl.isEmpty ? "无搜索" : "可搜索")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { s.enabled },
                                set: { _ in store.toggleSource(s) }
                            ))
                            .labelsHidden()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editing = s }
                    }
                    .onDelete { idx in
                        for i in idx { store.deleteSource(store.sources[i]) }
                    }
                } header: {
                    Text("已导入 \(store.sources.count) 个 · 启用 \(store.enabledSources.count) 个")
                }

                Section {
                    Button {
                        Task { await importFromClipboard() }
                    } label: {
                        Label("从剪贴板导入", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        showImportURL = true
                    } label: {
                        Label("从链接导入", systemImage: "link")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("从文件导入", systemImage: "folder")
                    }
                } header: {
                    Text("导入")
                } footer: {
                    Text("书源格式与「阅读」App 通用，网上搜到的书源合集 JSON 可以直接粘进来。")
                }
            }
            .navigationTitle("书源")
            .overlay {
                if busy {
                    ProgressView().padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("提示", isPresented: Binding(
                get: { alertText != nil },
                set: { if !$0 { alertText = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alertText ?? "")
            }
            .sheet(item: $editing) { s in
                SourceEditView(source: s)
                    .environmentObject(store)
            }
            .sheet(isPresented: $showImportURL) {
                NavigationStack {
                    Form {
                        Section("书源链接") {
                            TextField("https://…/booksource.json", text: $urlText)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                        }
                    }
                    .navigationTitle("从链接导入")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showImportURL = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("导入") {
                                let u = urlText
                                showImportURL = false
                                Task { await importFromURL(u) }
                            }
                            .disabled(urlText.isEmpty)
                        }
                    }
                }
                .presentationDetents([.height(220)])
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.json, .plainText, .data],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let u = urls.first {
                    let scoped = u.startAccessingSecurityScopedResource()
                    defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                    if let d = try? Data(contentsOf: u) {
                        let n = store.importSources(from: d)
                        alertText = n > 0 ? "导入了 \(n) 个书源" : "没有识别到有效书源"
                    } else {
                        alertText = "文件读不出来"
                    }
                }
            }
        }
    }

    private func importFromClipboard() async {
        guard let text = UIPasteboard.general.string, let d = text.data(using: .utf8) else {
            alertText = "剪贴板里没有内容"
            return
        }
        busy = true
        let n = store.importSources(from: d)
        busy = false
        alertText = n > 0 ? "导入了 \(n) 个书源" : "没识别到有效书源，确认是 bookSource JSON"
    }

    private func importFromURL(_ url: String) async {
        busy = true
        do {
            let n = try await store.importSources(from: url)
            alertText = n > 0 ? "导入了 \(n) 个书源" : "没识别到有效书源"
        } catch {
            alertText = "拉取失败：\(error.localizedDescription)"
        }
        busy = false
    }
}
