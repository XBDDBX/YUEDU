import SwiftUI
import UniformTypeIdentifiers

// MARK: - 配置（书源）

struct SourceConfigPage: View {
    @EnvironmentObject var store: AppStore
    @State private var showManage = false

    private var groups: [(String, Int)] {
        var dict: [String: Int] = [:]
        for s in store.sources {
            let k = s.group.isEmpty ? "未分组" : s.group
            dict[k, default: 0] += 1
        }
        return dict.sorted { $0.key < $1.key }
    }

    var body: some View {
        Form {
            Section("书源") {
                LabeledContent("已导入", value: "\(store.sources.count)")
                LabeledContent("已启用", value: "\(store.enabledSources.count)")
                LabeledContent("支持发现", value: "\(store.explorableSources.count)")
                LabeledContent("支持登录", value: "\(store.sources.filter { !$0.loginUrl.isEmpty }.count)")
            }

            if !groups.isEmpty {
                Section("分组") {
                    ForEach(groups, id: \.0) { g in
                        LabeledContent(g.0, value: "\(g.1) 个")
                    }
                }
            }

            Section {
                Button("打开书源管理") { showManage = true }
            } footer: {
                Text("导入、编辑规则、测试搜索、登录书源、按分组整理，都在书源管理里。")
            }
        }
        .navigationTitle("配置")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showManage) {
            SourceListView().environmentObject(store)
        }
    }
}

// MARK: - 朗读

struct TTSConfigPage: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var tts = TTSEngine.shared

    var body: some View {
        Form {
            Section("引擎") {
                Picker("朗读引擎", selection: Binding(
                    get: { store.settings.ttsEngineID },
                    set: { store.settings.ttsEngineID = $0; store.saveSettings() }
                )) {
                    Text("系统 TTS").tag("")
                    ForEach(store.settings.customTTS) { e in
                        Text(e.name).tag(e.id)
                    }
                }
                NavigationLink("管理自定义引擎（\(store.settings.customTTS.count) 个）") {
                    CustomTTSView().environmentObject(store)
                }
            }

            if store.settings.ttsEngineID.isEmpty {
                Section("系统音色") {
                    Picker("音色", selection: Binding(
                        get: { store.settings.ttsVoiceID },
                        set: { store.settings.ttsVoiceID = $0; store.saveSettings() }
                    )) {
                        Text("系统默认").tag("")
                        ForEach(tts.availableVoices, id: \.id) { v in
                            Text(v.name).tag(v.id)
                        }
                    }
                }
            }

            Section("播放") {
                HStack {
                    Text("语速")
                    Slider(value: Binding(
                        get: { store.settings.ttsRate },
                        set: { store.settings.ttsRate = $0; store.saveSettings() }
                    ), in: 0.3...0.7, step: 0.05)
                    Text(String(format: "%.2f", store.settings.ttsRate))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 38)
                }
                Toggle("读完自动下一章", isOn: Binding(
                    get: { store.settings.ttsAutoNextChapter },
                    set: { store.settings.ttsAutoNextChapter = $0; store.saveSettings() }
                ))
            }

            Section {
                Text("朗读时正文会跟着高亮；切到后台会继续读。使用自定义引擎时，需要该引擎返回 mp3 / wav 音频。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("朗读")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 替换净化 / 目录规则

struct PurifyListPage: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var purify = PurifyStore.shared

    let scope: PurifyScope

    @State private var editing: PurifyRule?
    @State private var showNew = false
    @State private var showImporter = false
    @State private var exportURL: URL?
    @State private var alert: String?

    private var list: [PurifyRule] { purify.rules(for: scope) }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { purify.enabled },
                    set: { purify.enabled = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用净化")
                        Text("关闭后所有规则暂停，正文原样显示")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if list.isEmpty {
                    Text(scope == .catalog ? "还没有目录规则" : "还没有净化规则")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                ForEach(list) { rule in
                    ruleRow(rule)
                }
                .onDelete { idx in
                    for i in idx { purify.delete(list[i]) }
                }
            } header: {
                Text("\(scope.rawValue)规则 · \(list.count) 条")
            } footer: {
                Text(scope == .content
                     ? "正文加载时自动按顺序执行，支持正则；左滑删除，点开编辑。"
                     : "目录作用域只清洗章节标题，不动正文。")
            }

            Section {
                Button {
                    showNew = true
                } label: {
                    Label("新增规则", systemImage: "plus.circle")
                }
                Button {
                    exportRules()
                } label: {
                    Label("导出规则", systemImage: "square.and.arrow.up")
                }
                Button {
                    showImporter = true
                } label: {
                    Label("导入规则（JSON）", systemImage: "square.and.arrow.down")
                }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("保存导出的文件", systemImage: "doc.badge.arrow.up")
                    }
                }
            }
        }
        .navigationTitle(scope == .catalog ? "目录规则" : "替换净化")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showNew) {
            PurifyEditPage(scope: scope, rule: nil) { newRule in
                purify.add(newRule)
            }
        }
        .sheet(item: $editing) { rule in
            PurifyEditPage(scope: scope, rule: rule) { updated in
                purify.update(updated)
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json, .plainText, .data, .text],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let u = urls.first {
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                if let d = try? Data(contentsOf: u) {
                    let n = purify.importData(d)
                    alert = n > 0 ? "导入了 \(n) 条规则" : "没有识别到有效规则（需要 JSON 数组）"
                }
            }
        }
        .alert("提示", isPresented: Binding(
            get: { alert != nil },
            set: { if !$0 { alert = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
    }

    private func ruleRow(_ rule: PurifyRule) -> some View {
        HStack(spacing: 10) {
            Button {
                editing = rule
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(rule.name).font(.system(size: 14, weight: .medium)).foregroundStyle(.primary)
                    Text(rule.pattern)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { _ in purify.toggle(rule) }
            ))
            .labelsHidden()
        }
    }

    private func exportRules() {
        guard let d = try? JSONEncoder().encode(list) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("purify-\(scope.rawValue).json")
        try? d.write(to: url)
        exportURL = url
    }
}

struct PurifyEditPage: View {
    @Environment(\.dismiss) private var dismiss

    let scope: PurifyScope
    let rule: PurifyRule?
    let onSave: (PurifyRule) -> Void

    @State private var name = ""
    @State private var pattern = ""
    @State private var replacement = ""
    @State private var isRegex = true
    @State private var enabled = true
    @State private var sample = "第1章 开端(1/2)\n\n这是正文内容，本章未完，请收藏本站，更多精彩内容尽在某某小说网。\n\n\n\n接下来是正常的段落。"

    private var currentRule: PurifyRule {
        var r = rule ?? PurifyRule()
        r.name = name
        r.pattern = pattern
        r.replacement = replacement
        r.isRegex = isRegex
        r.enabled = enabled
        r.scopeRaw = scope.rawValue
        return r
    }

    private var previewResult: (String, Int) {
        PurifyStore.preview(sample, rule: currentRule)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("规则") {
                    TextField("名称（如：去广告）", text: $name)
                    LabeledContent("作用域", value: scope.rawValue)
                    Toggle("正则表达式", isOn: $isRegex)
                    Toggle("启用", isOn: $enabled)
                }

                Section {
                    TextField("查找", text: $pattern, axis: .vertical)
                        .lineLimit(2...6)
                        .font(.system(size: 13, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("替换为（留空 = 删除）", text: $replacement, axis: .vertical)
                        .lineLimit(1...4)
                        .font(.system(size: 13, design: .monospaced))
                } header: {
                    Text("查找与替换")
                } footer: {
                    Text(isRegex
                         ? "支持正则捕获组，替换里用 $1、$2 引用。"
                         : "纯文本精确替换，不解析正则。")
                }

                Section("测试文本") {
                    TextEditor(text: $sample)
                        .font(.system(size: 12))
                        .frame(minHeight: 90)
                }

                Section {
                    Text("命中 \(previewResult.1) 处")
                        .font(.system(size: 12))
                        .foregroundStyle(previewResult.1 > 0 ? .green : .secondary)
                    ScrollView {
                        Text(previewResult.0)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                } header: {
                    Text("预览")
                }
            }
            .navigationTitle(rule == nil ? "新增规则" : "编辑规则")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let rule {
                    name = rule.name
                    pattern = rule.pattern
                    replacement = rule.replacement
                    isRegex = rule.isRegex
                    enabled = rule.enabled
                } else if scope == .catalog {
                    sample = "第1章 开端(1/2) 最新章节"
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(currentRule)
                        dismiss()
                    }
                    .disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - 阅读设置

struct ReadingSettingsPage: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            Section("主题") {
                NavigationLink {
                    ThemePage()
                } label: {
                    LabeledContent("外观主题", value: store.settings.theme.name)
                }
            }

            Section("显示") {
                NavigationLink {
                    FontManagePage()
                } label: {
                    LabeledContent("字体与排版", value: "\(Int(store.settings.fontSize))号")
                }
                Picker("翻页方式", selection: Binding(
                    get: { store.settings.pageTurnMode },
                    set: { store.settings.pageTurnMode = $0; store.saveSettings() }
                )) {
                    Text("覆盖").tag(0)
                    Text("滑动").tag(1)
                    Text("仿真").tag(2)
                    Text("上下滚动").tag(3)
                    Text("无动画").tag(4)
                }
                Toggle("双栏排版", isOn: Binding(
                    get: { store.settings.dualColumn },
                    set: { store.settings.dualColumn = $0; store.saveSettings() }
                ))
                Toggle("显示章节名", isOn: Binding(
                    get: { store.settings.showChapterTitle },
                    set: { store.settings.showChapterTitle = $0; store.saveSettings() }
                ))
            }

            Section("朗读") {
                NavigationLink {
                    TTSConfigPage()
                } label: {
                    LabeledContent("朗读设置", value: store.settings.ttsEngineID.isEmpty ? "系统 TTS" : "自定义")
                }
            }
        }
        .navigationTitle("阅读设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 字体管理

struct FontManagePage: View {
    @EnvironmentObject var store: AppStore

    private let fonts: [(id: String, name: String, desc: String)] = [
        ("system", "系统", "苹方 / SF，默认"),
        ("serif", "宋体", "Songti SC，适合长时间阅读"),
        ("rounded", "圆体", "圆润柔和"),
        ("mono", "等宽", "等宽字形")
    ]

    var body: some View {
        Form {
            Section("字体") {
                ForEach(fonts, id: \.id) { f in
                    Button {
                        store.settings.fontFamily = f.id
                        store.saveSettings()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name).foregroundStyle(.primary)
                                Text(f.desc).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.settings.fontFamily == f.id {
                                Image(systemName: "checkmark").foregroundStyle(settingsAccent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("字号与间距") {
                sliderRow("字号", value: Binding(
                    get: { store.settings.fontSize },
                    set: { store.settings.fontSize = $0; store.saveSettings() }
                ), range: 13...34, step: 1, unit: "号")

                sliderRow("行距", value: Binding(
                    get: { store.settings.lineSpacing },
                    set: { store.settings.lineSpacing = $0; store.saveSettings() }
                ), range: 0...24, step: 1, unit: "")

                sliderRow("段距", value: Binding(
                    get: { store.settings.paragraphSpacing },
                    set: { store.settings.paragraphSpacing = $0; store.saveSettings() }
                ), range: 0...30, step: 1, unit: "")

                sliderRow("首行缩进", value: Binding(
                    get: { store.settings.firstLineIndent },
                    set: { store.settings.firstLineIndent = $0; store.saveSettings() }
                ), range: 0...4, step: 1, unit: "字")

                sliderRow("字距", value: Binding(
                    get: { store.settings.letterSpacing },
                    set: { store.settings.letterSpacing = $0; store.saveSettings() }
                ), range: 0...3, step: 0.1, unit: "")

                sliderRow("左右边距", value: Binding(
                    get: { store.settings.marginH },
                    set: { store.settings.marginH = $0; store.saveSettings() }
                ), range: 8...48, step: 2, unit: "")
            }

            Section("预览") {
                Text("　　夜色沉下来的时候，书页上的字也慢了下来。\n　　翻过这一页，故事才刚开始。")
                    .font(fontPreview)
                    .lineSpacing(CGFloat(store.settings.lineSpacing))
                    .padding(.vertical, 6)
            }
        }
        .navigationTitle("字体管理")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var fontPreview: Font {
        let size = CGFloat(store.settings.fontSize)
        switch store.settings.fontFamily {
        case "serif": return .system(size: size, design: .serif)
        case "rounded": return .system(size: size, design: .rounded)
        case "mono": return .system(size: size, design: .monospaced)
        default: return .system(size: size)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(String(format: step < 1 ? "%.1f" : "%.0f", value.wrappedValue))\(unit)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .tint(settingsAccent)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 外观主题

struct ThemePage: View {
    @EnvironmentObject var store: AppStore

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(ReaderTheme.all.enumerated()), id: \.offset) { idx, t in
                    Button {
                        store.settings.themeIndex = idx
                        store.saveSettings()
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack(alignment: .topLeading) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(uiColor: UIColor(hex: t.bg)))
                                    .frame(height: 84)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Aa").font(.system(size: 18, weight: .semibold))
                                    Text("正文示例文字")
                                        .font(.system(size: 10))
                                }
                                .foregroundStyle(Color(uiColor: UIColor(hex: t.text)))
                                .padding(10)
                            }
                            HStack {
                                Text(t.name).font(.system(size: 13))
                                Spacer()
                                if store.settings.themeIndex == idx {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(settingsAccent)
                                        .font(.system(size: 13))
                                }
                            }
                        }
                        .padding(8)
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
        .background(settingsBG.ignoresSafeArea())
        .navigationTitle("外观主题")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 统计

struct StatsPage: View {
    @EnvironmentObject var store: AppStore

    private var localCount: Int { store.books.filter { $0.isLocal }.count }
    private var readChapters: Int { store.books.reduce(0) { $0 + $1.currentChapterIndex } }
    private var totalChapters: Int { store.books.reduce(0) { $0 + $1.chapters.count } }

    var body: some View {
        Form {
            Section {
                Toggle("开启阅读统计", isOn: Binding(
                    get: { store.settings.statsEnabled },
                    set: { store.settings.statsEnabled = $0; store.saveSettings() }
                ))
            } footer: {
                Text("统计只在本机计算，不上传任何数据。")
            }

            Section("概览") {
                LabeledContent("书架", value: "\(store.books.count) 本")
                LabeledContent("本地书", value: "\(localCount) 本")
                LabeledContent("已读章节", value: "\(readChapters) 章")
                LabeledContent("目录章节", value: "\(totalChapters) 章")
                LabeledContent("书源", value: "\(store.sources.count) 个")
                LabeledContent("净化规则", value: "\(PurifyStore.shared.enabledCount) 条")
            }

            Section("最近阅读") {
                if store.books.isEmpty {
                    Text("还没有阅读记录").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                ForEach(store.books.sorted { $0.lastReadAt > $1.lastReadAt }.prefix(5)) { b in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.title).font(.system(size: 14)).lineLimit(1)
                            Text(b.lastReadAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int(b.progress * 100))%")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("统计")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 文件管理

struct FileManagePage: View {
    @EnvironmentObject var store: AppStore
    @State private var exportURL: URL?
    @State private var alert: String?

    private var localBooks: [Book] { store.books.filter { $0.isLocal } }

    var body: some View {
        Form {
            Section("本地书 · \(localBooks.count) 本") {
                if localBooks.isEmpty {
                    Text("还没有本地书。在书架右上角「+」导入 TXT / EPUB。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                ForEach(localBooks) { b in
                    NavigationLink {
                        BookDetailView(book: b)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.title).font(.system(size: 14)).lineLimit(1)
                            Text("\(b.chapters.count) 章 · \(b.author.isEmpty ? "未知作者" : b.author)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("书源") {
                Button("导出全部书源（JSON）") { exportSources() }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("保存到文件 / 分享", systemImage: "square.and.arrow.up")
                    }
                }
            }

            Section("缓存") {
                LabeledContent("章节缓存", value: cacheText())
                Button("清理缓存") {
                    store.clearCache()
                    alert = "已清理章节缓存"
                }
            }
        }
        .navigationTitle("文件管理")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: Binding(
            get: { alert != nil },
            set: { if !$0 { alert = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
    }

    private func cacheText() -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: store.cacheSize())
    }

    private func exportSources() {
        guard let d = try? JSONEncoder().encode(store.sources) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("booksources.json")
        try? d.write(to: url)
        exportURL = url
    }
}

// MARK: - 备份与同步

struct BackupPage: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var purify = PurifyStore.shared

    @State private var exportURL: URL?
    @State private var showImporter = false
    @State private var alert: String?

    private struct Backup: Codable {
        var sources: [BookSource]
        var settings: ReaderSettings
        var purifyRules: [PurifyRule]
    }

    var body: some View {
        Form {
            Section {
                Button("导出备份包（书源 / 设置 / 净化规则）") { exportBackup() }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("保存 / 分享备份文件", systemImage: "square.and.arrow.up")
                    }
                }
                Button("从备份文件恢复") { showImporter = true }
            } header: {
                Text("本地备份")
            } footer: {
                Text("备份文件是一个 JSON，包含书源、阅读设置和净化规则；书架内容和阅读进度不包含在内。")
            }

            Section("文件共享") {
                Text("已开启「文件」App 共享，可以直接用隔空投送把 TXT / EPUB 传进来。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("备份与同步")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json, .data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let u = urls.first {
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                if let d = try? Data(contentsOf: u) {
                    restore(d)
                }
            }
        }
        .alert("提示", isPresented: Binding(
            get: { alert != nil },
            set: { if !$0 { alert = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
    }

    private func exportBackup() {
        let b = Backup(sources: store.sources, settings: store.settings, purifyRules: purify.rules)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        guard let d = try? enc.encode(b) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qingyue-backup.json")
        try? d.write(to: url)
        exportURL = url
    }

    private func restore(_ data: Data) {
        guard let b = try? JSONDecoder().decode(Backup.self, from: data) else {
            alert = "不是有效的备份文件"
            return
        }
        store.sources = b.sources
        store.saveSources()
        store.settings = b.settings
        store.saveSettings()
        purify.rules = b.purifyRules
        alert = "已恢复 \(b.sources.count) 个书源、\(b.purifyRules.count) 条规则"
    }
}

// MARK: - 缓存管理

struct CachePage: View {
    @EnvironmentObject var store: AppStore
    @Binding var cacheText: String
    var onRefresh: () -> Void

    @State private var showClear = false

    var body: some View {
        Form {
            Section("章节缓存") {
                LabeledContent("占用空间", value: cacheText)
                Button("清理全部缓存", role: .destructive) { showClear = true }
            }

            Section {
                VStack(spacing: 4) {
                    HStack {
                        Text("预缓存章数")
                        Spacer()
                        Text(store.settings.chapterPreload == 0 ? "关闭" : "\(store.settings.chapterPreload) 章")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(store.settings.chapterPreload) },
                        set: { store.settings.chapterPreload = Int($0); store.saveSettings() }
                    ), in: 0...5, step: 1)
                    .tint(settingsAccent)
                }
            } header: {
                Text("预缓存")
            } footer: {
                Text("读到某章时，自动往后多抓几章存下来，翻页更顺、断网也能接着看。")
            }
        }
        .navigationTitle("缓存管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: onRefresh)
        .confirmationDialog("确定清理全部章节缓存？", isPresented: $showClear, titleVisibility: .visible) {
            Button("清理", role: .destructive) {
                store.clearCache()
                onRefresh()
            }
            Button("取消", role: .cancel) {}
        }
    }
}
