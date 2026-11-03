import SwiftUI
import UniformTypeIdentifiers

/// 书源导入面板
///
/// 流程：链接 / 剪贴板 / 文件 → 解析 → 预览勾选（带体检结果）→ 选分组 → 导入
struct SourceImportSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private enum Stage { case entry, preview }

    struct PreviewRow: Identifiable {
        var source: BookSource
        var health: SourceHealth
        var duplicate: Bool
        var id: UUID { source.id }
        var host: String {
            URL(string: source.url)?.host ?? source.url
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case fresh = "新增"
        case usable = "可用"
        case trouble = "有问题"
        var id: String { rawValue }
    }

    @State private var stage: Stage = .entry
    @State private var urlText = ""
    @State private var showFile = false
    @State private var loading = false
    @State private var loadingNote = ""
    @State private var errorText: String?
    @State private var noteText: String?

    @State private var rows: [PreviewRow] = []
    @State private var selected: Set<UUID> = []
    @State private var filter: Filter = .all
    @State private var keyword = ""
    @State private var expanded: Set<UUID> = []
    @State private var existingKeys: Set<String> = []

    @State private var groupName = ""
    @State private var newGroup = ""
    @State private var showGroupEditor = false

    // MARK: - 派生数据

    private var existingGroups: [String] {
        Array(Set(store.sources.map { $0.group }.filter { !$0.isEmpty })).sorted()
    }

    private var filtered: [PreviewRow] {
        rows.filter { row in
            switch filter {
            case .all: break
            case .fresh: if row.duplicate { return false }
            case .usable: if row.health.level == .broken { return false }
            case .trouble: if row.health.level != .broken && row.health.unsupported.isEmpty { return false }
            }
            let k = keyword.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty {
                let hay = "\(row.source.name) \(row.source.group) \(row.source.url)"
                if !hay.localizedCaseInsensitiveContains(k) { return false }
            }
            return true
        }
    }

    private var brokenCount: Int { rows.filter { $0.health.level == .broken }.count }
    private var usableCount: Int { rows.filter { $0.health.level != .broken }.count }
    private var dupCount: Int { rows.filter { $0.duplicate }.count }
    private var selectedFresh: Int {
        rows.filter { selected.contains($0.id) && !$0.duplicate }.count
    }

    // MARK: - Body

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
                        Button("重选") { reset() }
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

    // MARK: - 入口页

    private var entryView: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(settingsAccent)
                    Text("导入书源")
                        .font(.system(size: 17, weight: .semibold))
                    Text("支持「阅读 3.0 / legado」bookSource JSON：\n单个书源、数组、合集、带注释的 JSON 都能认。\n也可以直接贴一行一个订阅链接。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 20)

                VStack(spacing: 10) {
                    Button {
                        Task { await importFromClipboard() }
                    } label: {
                        entryRow(icon: "doc.on.clipboard", title: "从剪贴板导入",
                                 subtitle: "书源 JSON 或订阅链接都行")
                    }
                    .buttonStyle(.plain)

                    Button {
                        showFile = true
                    } label: {
                        entryRow(icon: "folder", title: "从文件导入",
                                 subtitle: "支持多选，一次导入多个 JSON / TXT")
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 8) {
                        entryRow(icon: "link", title: "从链接导入",
                                 subtitle: "订阅地址或 JSON 直链，一行一个")
                        TextEditor(text: $urlText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 66)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(alignment: .topLeading) {
                                if urlText.isEmpty {
                                    Text("https://…/booksource.json")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color(.tertiaryLabel))
                                        .padding(.horizontal, 12).padding(.vertical, 12)
                                        .allowsHitTesting(false)
                                }
                            }
                        HStack {
                            Spacer()
                            Button {
                                Task { await importFromURLs() }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.down.circle")
                                    Text("拉取")
                                }
                                .font(.system(size: 13, weight: .medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(settingsAccent)
                            .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
                        }
                    }
                    .padding(14)
                    .background(Color(.systemBackground),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if loading {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text(loadingNote.isEmpty ? "正在解析…" : loadingNote)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
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
        .background(Color(.systemBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 预览页

    private var previewView: some View {
        VStack(spacing: 0) {
            statBar
            filterBar

            if filtered.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 30))
                        .foregroundStyle(Color(.tertiaryLabel))
                    Text("这个筛选条件下没有书源")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    Section {
                        ForEach(filtered) { row in
                            rowView(row)
                        }
                    } header: {
                        Text("书源 · \(filtered.count) 个")
                    } footer: {
                        if let note = noteText {
                            Text(note).font(.system(size: 11))
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }

            bottomBar
        }
        .background(settingsBG.ignoresSafeArea())
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

    private var statBar: some View {
        HStack(spacing: 0) {
            statItem("\(rows.count)", "共解析", color: .primary)
            Divider().frame(height: 24)
            statItem("\(usableCount)", "可读", color: settingsAccent)
            Divider().frame(height: 24)
            statItem("\(dupCount)", "已存在", color: .orange)
            Divider().frame(height: 24)
            statItem("\(brokenCount)", "不完整", color: .red)
        }
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func statItem(_ value: String, _ title: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { f in
                    Button {
                        filter = f
                    } label: {
                        Text(f.rawValue)
                            .font(.system(size: 12, weight: filter == f ? .semibold : .regular))
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(filter == f ? settingsAccent : Color(.secondarySystemBackground),
                                        in: Capsule())
                            .foregroundStyle(filter == f ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("搜索书源名 / 网址", text: $keyword)
                        .font(.system(size: 12))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Color(.secondarySystemBackground), in: Capsule())

                Button {
                    toggleAll()
                } label: {
                    Text(selected.count == filtered.count && !filtered.isEmpty ? "反选" : "全选")
                        .font(.system(size: 12))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)

                Button {
                    selected = Set(rows.filter { !$0.duplicate && $0.health.level != .broken }.map { $0.id })
                } label: {
                    Text("选可用")
                        .font(.system(size: 12))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func rowView(_ row: PreviewRow) -> some View {
        let isOn = selected.contains(row.id)
        let isOpen = expanded.contains(row.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if isOn { selected.remove(row.id) } else { selected.insert(row.id) }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isOn ? settingsAccent : Color(.tertiaryLabel))
                        .font(.system(size: 19))
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(row.source.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            healthBadge(row.health)
                            if row.duplicate {
                                tag("已存在", color: .orange)
                            }
                            Spacer(minLength: 0)
                        }
                        if !row.host.isEmpty {
                            Text(row.host)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 4) {
                            ForEach(row.health.shortTags, id: \.self) { t in
                                tag(t, color: tagColor(t))
                            }
                            if !row.source.group.isEmpty {
                                tag(row.source.group, color: .purple)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 5) {
                    if let u = URL(string: row.source.url) {
                        detailLine("地址", "\(u.scheme ?? "")://\(u.host ?? "")")
                    }
                    detailLine("搜索", row.source.searchUrl.isEmpty ? "无" : "有")
                    detailLine("目录", row.source.ruleToc.chapterList.isEmpty ? "缺" : "有")
                    detailLine("正文", row.source.ruleContent.content.isEmpty ? "缺" : "有")
                    if !row.health.unsupported.isEmpty {
                        detailLine("受限", row.health.unsupported.joined(separator: "、"))
                    }
                    ForEach(row.health.notes, id: \.self) { n in
                        Text("· \(n)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 29)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                if isOpen { expanded.remove(row.id) } else { expanded.insert(row.id) }
            } label: {
                Image(systemName: isOpen ? "chevron.up.circle" : "info.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .padding(.top, 2)
            }
            .buttonStyle(.plain)
        }
    }

    private func detailLine(_ key: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(key).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
            Text(value).font(.system(size: 10)).foregroundStyle(.primary).lineLimit(1)
        }
    }

    private func healthBadge(_ h: SourceHealth) -> some View {
        Text(h.level.label)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(badgeColor(h.level).opacity(0.14), in: Capsule())
            .foregroundStyle(badgeColor(h.level))
    }

    private func badgeColor(_ l: SourceHealth.Level) -> Color {
        switch l {
        case .usable: return .green
        case .partial: return .orange
        case .broken: return .red
        }
    }

    private func tagColor(_ t: String) -> Color {
        switch t {
        case "搜索": return .blue
        case "发现": return .teal
        case "目录": return .indigo
        case "正文": return .green
        case "JSON": return .purple
        case "JS": return .pink
        default: return .secondary
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 13))
                    .foregroundStyle(settingsAccent)
                Picker("分组", selection: $groupName) {
                    Text("不分组").tag("")
                    ForEach(existingGroups, id: \.self) { g in
                        Text(g).tag(g)
                    }
                }
                .pickerStyle(.menu)
                .tint(.primary)
                Button {
                    showGroupEditor = true
                } label: {
                    Image(systemName: "plus.circle").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(settingsAccent)
                Spacer()
                Text("已选 \(selected.count)/\(rows.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            Button {
                doImport()
            } label: {
                Text(selected.isEmpty ? "请选择要导入的书源" : "导入 \(selected.count) 个书源")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(selected.isEmpty ? Color.gray.opacity(0.25) : settingsAccent,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white)
            }
            .disabled(selected.isEmpty)
            .padding(.horizontal, 16)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }

    // MARK: - 选择

    private func toggleAll() {
        let ids = filtered.map { $0.id }
        let allOn = ids.allSatisfy { selected.contains($0) }
        if allOn {
            for i in ids { selected.remove(i) }
        } else {
            for i in ids { selected.insert(i) }
        }
    }

    // MARK: - 解析入口

    private func handle(_ result: SourceParseResult) {
        guard !result.sources.isEmpty else {
            let msg = result.note.isEmpty ? "没有识别到书源" : result.note
            errorText = msg
            return
        }
        present(sources: result.sources, failed: result.failed, note: result.note)
    }

    private func present(sources: [BookSource], failed: Int, note: String) {
        existingKeys = Set(store.sources.map { "\($0.name)|\($0.url)" })

        var seen = Set<String>()
        var built: [PreviewRow] = []
        for s in sources {
            let k = "\(s.name)|\(s.url)"
            guard !seen.contains(k) else { continue }
            seen.insert(k)
            built.append(PreviewRow(source: s,
                                    health: SourceDoctor.check(s),
                                    duplicate: existingKeys.contains(k)))
        }
        guard !built.isEmpty else {
            errorText = "没有可导入的书源"
            return
        }

        rows = built
        // 默认勾选：新增且不是残缺源
        let fresh = built.filter { !$0.duplicate && $0.health.level != .broken }.map { $0.id }
        selected = Set(fresh.isEmpty ? built.map { $0.id } : fresh)
        filter = .all
        keyword = ""
        expanded = []
        noteText = buildNote(note: note, failed: failed, total: built.count)
        stage = .preview
    }

    private func buildNote(note: String, failed: Int, total: Int) -> String? {
        var parts: [String] = []
        if !note.isEmpty { parts.append(note) }
        if failed > 0 { parts.append("\(failed) 条内容无法识别已跳过") }
        parts.append("「可用」= 搜索/目录/正文规则齐全；「部分」= 能读但用到了受限写法；「不完整」= 缺目录或正文规则，导入后大概率读不了。")
        _ = total
        return parts.joined(separator: "\n")
    }

    private func reset() {
        stage = .entry
        rows = []
        selected = []
        expanded = []
        noteText = nil
        urlText = ""
    }

    // MARK: - 文件 / 剪贴板 / 链接

    private func loadFiles(_ urls: [URL]) {
        var all: [BookSource] = []
        var failed = 0
        var notes: [String] = []
        for u in urls {
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            guard let d = try? Data(contentsOf: u) else {
                notes.append("\(u.lastPathComponent) 读不出来")
                continue
            }
            let r = SourceImportParser.parse(data: d, label: u.lastPathComponent)
            all.append(contentsOf: r.sources)
            failed += r.failed
            if r.sources.isEmpty { notes.append(r.note) }
        }
        guard !all.isEmpty else {
            errorText = notes.first ?? "文件里没有识别到书源"
            return
        }
        present(sources: all, failed: failed, note: notes.joined(separator: "；"))
    }

    private func importFromClipboard() async {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorText = "剪贴板里没有内容"
            return
        }
        loading = true
        loadingNote = "正在解析剪贴板…"
        defer { loading = false }

        let result = SourceImportParser.parse(text: text, label: "剪贴板")
        if !result.sources.isEmpty {
            handle(result)
            return
        }
        guard !result.urls.isEmpty else {
            errorText = result.note.isEmpty ? "剪贴板里没有识别到书源" : result.note
            return
        }
        await fetchURLs(result.urls)
    }

    private func importFromURLs() async {
        loading = true
        defer { loading = false }
        let text = urlText
        let result = SourceImportParser.parse(text: text, label: "输入内容")
        if !result.sources.isEmpty {
            handle(result)
            return
        }
        var list = result.urls
        if list.isEmpty {
            // 用户可能只贴了不带协议的域名
            let lines = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            list = lines.map { $0.hasPrefix("http") ? $0 : "https://\($0)" }
        }
        guard !list.isEmpty else {
            errorText = "没有识别到链接"
            return
        }
        await fetchURLs(list)
    }

    private func fetchURLs(_ urls: [String]) async {
        var all: [BookSource] = []
        var failed = 0
        var notes: [String] = []
        for (i, u) in urls.enumerated() {
            loading = true
            loadingNote = "正在拉取 \(i + 1)/\(urls.count) …"
            do {
                let data = try await SourceFetcher.data(u)
                let r = SourceImportParser.parse(data: data, label: "链接")
                if r.sources.isEmpty { notes.append("\(shortURL(u)) 里没有书源") }
                all.append(contentsOf: r.sources)
                failed += r.failed
            } catch {
                notes.append("\(shortURL(u)) 拉取失败：\(error.localizedDescription)")
            }
        }
        loading = false
        guard !all.isEmpty else {
            errorText = notes.isEmpty ? "链接里没有书源" : notes.joined(separator: "\n")
            return
        }
        present(sources: all, failed: failed, note: notes.joined(separator: "；"))
    }

    private func shortURL(_ u: String) -> String {
        guard let url = URL(string: u) else { return u }
        return url.host ?? u
    }

    // MARK: - 导入

    private func doImport() {
        let picked = rows.filter { selected.contains($0.id) }.map { $0.source }
        guard !picked.isEmpty else { return }
        let result = store.addSources(picked, group: groupName)
        var msg = "导入 \(result.added) 个"
        if result.updated > 0 { msg += "，更新 \(result.updated) 个" }
        store.show(msg)
        dismiss()
    }
}
