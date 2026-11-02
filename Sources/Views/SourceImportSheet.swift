import SwiftUI
import UniformTypeIdentifiers

/// 书源导入面板：链接 / 剪贴板 / 文件 → 预览勾选 → 分组 → 导入
struct SourceImportSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private enum Stage { case entry, preview }

    @State private var stage: Stage = .entry
    @State private var urlText = ""
    @State private var showFile = false
    @State private var loading = false
    @State private var errorText: String?

    @State private var parsed: [BookSource] = []
    @State private var selected: Set<UUID> = []
    @State private var existingKeys: Set<String> = []
    @State private var groupName: String = ""
    @State private var newGroup: String = ""
    @State private var showGroupEditor = false

    private var existingGroups: [String] {
        Array(Set(store.sources.map { $0.group }.filter { !$0.isEmpty })).sorted()
    }

    private func key(_ s: BookSource) -> String { "\(s.name)|\(s.url)" }

    private var selectedCount: Int { selected.count }
    private var dupCount: Int {
        parsed.filter { selected.contains($0.id) && existingKeys.contains(key($0)) }.count
    }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .entry: entryView
                case .preview: previewView
                }
            }
            .navigationTitle(stage == .entry ? "导入书源" : "选择书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                if stage == .preview {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("重新选择") {
                            stage = .entry
                            parsed = []
                            selected = []
                        }
                    }
                }
            }
            .fileImporter(isPresented: $showFile,
                          allowedContentTypes: [.json, .plainText, .data, .text],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): loadFiles(urls)
                case .failure(let err): errorText = err.localizedDescription
                }
            }
            .alert("提示", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    // MARK: - 入口

    private var entryView: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 16) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(settingsAccent)
                    Text("导入书源")
                        .font(.system(size: 17, weight: .semibold))
                    Text("支持「阅读 3.0 / legado」的 bookSource JSON，\n支持单个书源、数组合集、带 bookSources 字段的合集。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 24)

                VStack(spacing: 10) {
                    Button {
                        Task { await importFromClipboard() }
                    } label: {
                        entryRow(icon: "doc.on.clipboard", title: "从剪贴板导入",
                                 subtitle: "复制了书源 JSON 或链接就能直接粘")
                    }
                    .buttonStyle(.plain)

                    Button {
                        showFile = true
                    } label: {
                        entryRow(icon: "folder", title: "从文件导入",
                                 subtitle: "支持多选，一次导入多个 JSON")
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 8) {
                        entryRow(icon: "link", title: "从链接导入",
                                 subtitle: "填写订阅地址或 JSON 直链")
                        HStack(spacing: 8) {
                            TextField("https://…/booksource.json", text: $urlText)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .font(.system(size: 13))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            Button("拉取") {
                                Task { await importFromURL() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(settingsAccent)
                            .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || loading)
                        }
                        .padding(.leading, 40)
                    }
                    .padding(14)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if loading {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("正在拉取书源…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(16)
        }
        .background(settingsBG.ignoresSafeArea())
    }

    private func entryRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            SettingIcon(name: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(.primary)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(.tertiaryLabel))
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 预览

    private var previewView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    let all = Set(parsed.map { $0.id })
                    selected = (selected.count == parsed.count) ? [] : all
                } label: {
                    Text(selected.count == parsed.count ? "反选" : "全选")
                        .font(.system(size: 13))
                }
                .buttonStyle(.bordered)

                Text("已选 \(selectedCount)/\(parsed.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if dupCount > 0 {
                    Text("\(dupCount) 个已存在")
                        .font(.system(size: 11))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            List {
                Section("导入到分组") {
                    HStack {
                        Picker("分组", selection: $groupName) {
                            Text("未分组").tag("")
                            ForEach(existingGroups, id: \.self) { g in
                                Text(g).tag(g)
                            }
                        }
                        Button {
                            showGroupEditor = true
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(settingsAccent)
                    }
                }

                Section("书源 · \(parsed.count) 个") {
                    ForEach(parsed) { s in
                        Button {
                            if selected.contains(s.id) { selected.remove(s.id) } else { selected.insert(s.id) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selected.contains(s.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(s.id) ? settingsAccent : Color(.tertiaryLabel))
                                    .font(.system(size: 19))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(s.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    HStack(spacing: 5) {
                                        if !s.searchUrl.isEmpty { tag("搜索") }
                                        if !s.exploreUrl.isEmpty { tag("发现") }
                                        if !s.loginUrl.isEmpty { tag("登录") }
                                        if existingKeys.contains(key(s)) { tag("已存在", color: .orange) }
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)

            VStack(spacing: 8) {
                Button {
                    doImport()
                } label: {
                    Text(selectedCount == 0 ? "请选择要导入的书源" : "导入 \(selectedCount) 个书源")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(selectedCount == 0 ? Color.gray.opacity(0.25) : settingsAccent,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.white)
                }
                .disabled(selectedCount == 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(.bar)
        }
        .alert("新建分组", isPresented: $showGroupEditor) {
            TextField("分组名", text: $newGroup)
            Button("确定") {
                let g = newGroup.trimmingCharacters(in: .whitespaces)
                if !g.isEmpty { groupName = g }
                newGroup = ""
            }
            Button("取消", role: .cancel) { newGroup = "" }
        }
    }

    private func tag(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.system(size: 10))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - 解析

    private func handle(_ data: Data, sourceLabel: String) {
        let list = BookSource.decodeList(from: data)
        guard !list.isEmpty else {
            errorText = "没有从\(sourceLabel)里识别到书源，确认是 bookSource JSON"
            return
        }
        parsed = list
        existingKeys = Set(store.sources.map { key($0) })
        selected = Set(list.filter { !existingKeys.contains(key($0)) }.map { $0.id })
        if selected.isEmpty { selected = Set(list.map { $0.id }) }
        stage = .preview
    }

    private func loadFiles(_ urls: [URL]) {
        var merged: [BookSource] = []
        for u in urls {
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            if let d = try? Data(contentsOf: u) {
                merged.append(contentsOf: BookSource.decodeList(from: d))
            }
        }
        guard !merged.isEmpty else {
            errorText = "文件里没有识别到书源"
            return
        }
        parsed = merged
        existingKeys = Set(store.sources.map { key($0) })
        selected = Set(merged.filter { !existingKeys.contains(key($0)) }.map { $0.id })
        if selected.isEmpty { selected = Set(merged.map { $0.id }) }
        stage = .preview
    }

    private func importFromClipboard() async {
        guard let text = UIPasteboard.general.string, let d = text.data(using: .utf8) else {
            errorText = "剪贴板里没有内容"
            return
        }
        // 剪贴板里可能是链接
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            loading = true
            do {
                let data = try await SourceFetcher.data(trimmed)
                loading = false
                handle(data, sourceLabel: "链接")
            } catch {
                loading = false
                errorText = "拉取失败：\(error.localizedDescription)"
            }
            return
        }
        handle(d, sourceLabel: "剪贴板")
    }

    private func importFromURL() async {
        loading = true
        do {
            let data = try await SourceFetcher.data(urlText.trimmingCharacters(in: .whitespaces))
            loading = false
            handle(data, sourceLabel: "链接")
        } catch {
            loading = false
            errorText = "拉取失败：\(error.localizedDescription)"
        }
    }

    private func doImport() {
        let picked = parsed.filter { selected.contains($0.id) }
        let result = store.addSources(picked, group: groupName)
        store.show("导入 \(result.added) 个，更新 \(result.updated) 个")
        dismiss()
    }
}
