import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var cacheText = "—"
    @State private var showReset = false
    // 书源导入 / 登录
    @State private var showImportURL = false
    @State private var showImporter = false
    @State private var urlText = ""
    @State private var alertText: String?
    @State private var loginSource: BookSource?
    @State private var editing: BookSource?

    var body: some View {
        NavigationStack {
            Form {
                Section("书源") {
                    if store.sources.isEmpty {
                        Text("还没有书源，用下方按钮导入").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(store.sources) { s in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                                Text(s.url).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if !s.loginUrl.isEmpty {
                                Button {
                                    loginSource = s
                                } label: {
                                    Image(systemName: store.sourceHasAccount(s) ? "person.fill.checkmark" : "person.badge.key")
                                        .font(.system(size: 14))
                                        .foregroundStyle(store.sourceHasAccount(s) ? .green : .secondary)
                                }
                            }
                            Toggle("", isOn: Binding(
                                get: { s.enabled },
                                set: { _ in store.toggleSource(s) }
                            ))
                            .labelsHidden()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editing = s }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if store.sourceHasAccount(s) {
                                Button(role: .destructive) {
                                    store.clearSourceAccount(s)
                                    store.show("已清除「\(s.name)」账号信息")
                                } label: {
                                    Label("清除账号", systemImage: "person.crop.circle.badge.xmark")
                                }
                            }
                            Button(role: .destructive) {
                                store.deleteSource(s)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                    NavigationLink("书源管理（编辑 / 测试 / 批量导入）") {
                        SourceListView()
                            .environmentObject(store)
                    }
                } header: {
                    Text("书源 · \(store.sources.count) 个 · 启用 \(store.enabledSources.count) 个")
                } footer: {
                    Text("点击书源可编辑规则；支持 legado / 阅读 3.0 书源 JSON 导入。")
                }

                Section("导入") {
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
                        Label("从文件导入（可多选）", systemImage: "folder")
                    }
                } footer: {
                    Text("网上搜到的书源合集 JSON 可直接导入。")
                }

                Section("外观") {
                    Picker("主题", selection: Binding(
                        get: { store.settings.themeIndex },
                        set: { store.settings.themeIndex = $0; store.saveSettings() }
                    )) {
                        ForEach(Array(ReaderTheme.all.enumerated()), id: \.offset) { i, t in
                            HStack {
                                Circle().fill(Color(uiColor: UIColor(hex: t.bg))).frame(width: 16, height: 16)
                                    .overlay(Circle().stroke(.gray.opacity(0.4), lineWidth: 0.6))
                                Text(t.name)
                            }.tag(i)
                        }
                    }

                    Picker("字体", selection: Binding(
                        get: { store.settings.fontFamily },
                        set: { store.settings.fontFamily = $0; store.saveSettings() }
                    )) {
                        Text("系统").tag("system")
                        Text("宋体").tag("serif")
                        Text("圆体").tag("rounded")
                        Text("等宽").tag("mono")
                    }

                    HStack {
                        Text("字号")
                        Slider(value: Binding(
                            get: { store.settings.fontSize },
                            set: { store.settings.fontSize = $0; store.saveSettings() }
                        ), in: 13...34, step: 1)
                        Text("\(Int(store.settings.fontSize))").font(.system(size: 12, design: .monospaced))
                            .frame(width: 26)
                    }

                    HStack {
                        Text("行距")
                        Slider(value: Binding(
                            get: { store.settings.lineSpacing },
                            set: { store.settings.lineSpacing = $0; store.saveSettings() }
                        ), in: 0...22, step: 1)
                        Text("\(Int(store.settings.lineSpacing))").font(.system(size: 12, design: .monospaced))
                            .frame(width: 26)
                    }
                }

                Section("朗读") {
                    Picker("朗读引擎", selection: Binding(
                        get: { store.settings.ttsEngineID },
                        set: { store.settings.ttsEngineID = $0; store.saveSettings() }
                    )) {
                        Text("系统 TTS").tag("")
                        ForEach(store.settings.customTTS) { e in
                            Text(e.name).tag(e.id)
                        }
                    }
                    if store.settings.ttsEngineID.isEmpty {
                        Picker("音色", selection: Binding(
                            get: { store.settings.ttsVoiceID },
                            set: { store.settings.ttsVoiceID = $0; store.saveSettings() }
                        )) {
                            Text("系统默认").tag("")
                            ForEach(TTSEngine.shared.availableVoices, id: \.id) { v in
                                Text(v.name).tag(v.id)
                            }
                        }
                    }
                    HStack {
                        Text("语速")
                        Slider(value: Binding(
                            get: { store.settings.ttsRate },
                            set: { store.settings.ttsRate = $0; store.saveSettings() }
                        ), in: 0.3...0.7, step: 0.05)
                    }
                    Toggle("读完自动下一章", isOn: Binding(
                        get: { store.settings.ttsAutoNextChapter },
                        set: { store.settings.ttsAutoNextChapter = $0; store.saveSettings() }
                    ))
                    NavigationLink("自定义朗读引擎") { CustomTTSView() }
                        .environmentObject(store)
                }

                Section("存储") {
                    HStack {
                        Text("章节缓存")
                        Spacer()
                        Text(cacheText).foregroundStyle(.secondary)
                    }
                    Button("清理缓存") {
                        store.clearCache()
                        refreshCache()
                        store.show("已清理")
                    }
                    Button("清空书架", role: .destructive) {
                        showReset = true
                    }
                }

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0.0").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("书源")
                        Spacer()
                        Text("\(store.sources.count) 个").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("书架")
                        Spacer()
                        Text("\(store.books.count) 本").foregroundStyle(.secondary)
                    }
                    NavigationLink("书源规则说明") { HelpView() }
                }
            }
            .navigationTitle("设置")
            .onAppear(perform: refreshCache)
            .confirmationDialog("确定清空书架？", isPresented: $showReset, titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    for b in store.books { store.removeBook(b) }
                    store.clearCache()
                    refreshCache()
                }
                Button("取消", role: .cancel) {}
            }
            .sheet(item: $editing) { s in
                SourceEditView(source: s)
                    .environmentObject(store)
            }
            .sheet(item: $loginSource) { s in
                SourceLoginSheet(source: s)
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
                          allowedContentTypes: [.json, .plainText, .data, .text],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    var total = 0
                    for u in urls {
                        let scoped = u.startAccessingSecurityScopedResource()
                        defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                        if let d = try? Data(contentsOf: u) {
                            total += store.importSources(from: d)
                        }
                    }
                    if total > 0 {
                        alertText = "导入了 \(total) 个书源"
                        checkCapabilityHints()
                    } else {
                        alertText = "没有识别到有效书源，请确认文件是 bookSource JSON 合集"
                    }
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
        }
    }

    private func importFromClipboard() async {
        guard let text = UIPasteboard.general.string, let d = text.data(using: .utf8) else {
            alertText = "剪贴板里没有内容"
            return
        }
        let n = store.importSources(from: d)
        alertText = n > 0 ? "导入了 \(n) 个书源" : "没识别到有效书源，确认是 bookSource JSON"
        if n > 0 { checkCapabilityHints() }
    }

    private func importFromURL(_ url: String) async {
        do {
            let n = try await store.importSources(from: url)
            alertText = n > 0 ? "导入了 \(n) 个书源" : "没识别到有效书源"
            if n > 0 { checkCapabilityHints() }
        } catch {
            alertText = "拉取失败：\(error.localizedDescription)"
        }
    }

    /// 导入包含 JS / 登录 / 发现页能力的书源时给出提示
    private func checkCapabilityHints() {
        let jsCount = store.sources.filter { !$0.jsLib.isEmpty || $0.searchUrl.hasPrefix("<js>") }.count
        let loginCount = store.sources.filter { !$0.loginUrl.isEmpty }.count
        let exploreCount = store.sources.filter { !$0.exploreUrl.isEmpty }.count
        var hints: [String] = []
        if jsCount > 0 { hints.append("\(jsCount) 个为 JS 引擎书源（需真机验证）") }
        if loginCount > 0 { hints.append("\(loginCount) 个支持登录，点击行内钥匙图标登录") }
        if exploreCount > 0 { hints.append("\(exploreCount) 个支持发现页，已加入「发现」页") }
        if !hints.isEmpty {
            alertText = "导入完成。" + hints.joined(separator: "；")
        }
    }

    private func refreshCache() {
        let bytes = store.cacheSize()
        let f = ByteCountFormatter()
        f.countStyle = .file
        cacheText = f.string(fromByteCount: bytes)
    }
}

struct CustomTTSView: View {
    @EnvironmentObject var store: AppStore
    @State private var showAdd = false
    @State private var editing: CustomTTSEngine?
    @State private var showImporter = false
    @State private var alertText: String?

    var body: some View {
        List {
            Section {
                if store.settings.customTTS.isEmpty {
                    Text("还没有自定义引擎。可以手填一个返回音频（mp3 / wav）的 TTS 服务地址，或像导入书源一样从文件 / 剪贴板导入。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(store.settings.customTTS) { e in
                    Button {
                        editing = e
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.name).font(.system(size: 15, weight: .medium))
                            Text(e.url.isEmpty ? "（未配置请求地址）" : e.url).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { idx in
                    store.settings.customTTS.remove(atOffsets: idx)
                    store.saveSettings()
                }
            } header: {
                Text("已添加 \(store.settings.customTTS.count) 个")
            } footer: {
                Text("请求地址用 {text} 放朗读文本、{voice} 放音色。GET 模式直接替换进 URL；POST 模式会发送 JSON {text, voice, rate}。")
            }

            Section {
                Button {
                    showAdd = true
                } label: {
                    Label("手动添加引擎", systemImage: "plus")
                }
            }

            Section("导入") {
                Button {
                    showImporter = true
                } label: {
                    Label("从文件导入（JSON）", systemImage: "folder")
                }
                Button {
                    importFromClipboard()
                } label: {
                    Label("从剪贴板导入", systemImage: "doc.on.clipboard")
                }
            } footer: {
                Text("支持导入 TTS 引擎 JSON：数组 [{name,url,voice,method}]，或含 ttsEngines / tts_engines 字段的对象，缺 url 的条目会跳过。")
            }
        }
        .navigationTitle("自定义朗读引擎")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd) {
            CustomTTSEditSheet(engine: nil) { engine in
                store.settings.customTTS.append(engine)
                store.saveSettings()
            }
        }
        .sheet(item: $editing) { e in
            CustomTTSEditSheet(engine: e) { updated in
                if let i = store.settings.customTTS.firstIndex(where: { $0.id == updated.id }) {
                    store.settings.customTTS[i] = updated
                    store.saveSettings()
                }
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json, .plainText, .data, .text],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let u = urls.first {
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                if let d = try? Data(contentsOf: u) {
                    importFromData(d)
                }
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
    }

    private func importFromClipboard() {
        guard let text = UIPasteboard.general.string, let d = text.data(using: .utf8) else {
            alertText = "剪贴板里没有内容"
            return
        }
        importFromData(d)
    }

    /// 解析 TTS 引擎 JSON 并追加到设置（数组 / ttsEngines 字段 / 单对象）
    private func importFromData(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            alertText = "不是有效 JSON"
            return
        }
        var list: [[String: Any]] = []
        if let arr = obj as? [[String: Any]] {
            list = arr
        } else if let dict = obj as? [String: Any] {
            if let arr = dict["ttsEngines"] as? [[String: Any]] {
                list = arr
            } else if let arr = dict["tts_engines"] as? [[String: Any]] {
                list = arr
            } else {
                list = [dict]
            }
        }
        var added = 0
        for item in list {
            let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let url = (item["url"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let voice = (item["voice"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let method = (item["method"] as? String) == "POST" ? "POST" : "GET"
            guard !name.isEmpty else { continue }
            store.settings.customTTS.append(CustomTTSEngine(
                id: UUID().uuidString,
                name: name,
                url: url,
                voice: voice,
                method: method
            ))
            added += 1
        }
        if added > 0 {
            store.saveSettings()
            let noURL = list.count - added
            alertText = noURL > 0 ? "导入 \(added) 个引擎（\(noURL) 个缺 name/url 已跳过），请点开补齐请求地址" : "导入了 \(added) 个引擎"
        } else {
            alertText = "没识别到有效引擎条目（需要 name 字段）"
        }
    }
}

struct CustomTTSEditSheet: View {
    let engine: CustomTTSEngine?
    let onSave: (CustomTTSEngine) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var voice = ""
    @State private var isPOST = false

    var body: some View {
        NavigationStack {
            Form {
                Section("引擎") {
                    TextField("名称（如：Edge TTS）", text: $name)
                    TextField("请求地址", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("音色（可选）", text: $voice)
                        .textInputAutocapitalization(.never)
                    Picker("请求方式", selection: $isPOST) {
                        Text("GET（URL 占位）").tag(false)
                        Text("POST（JSON body）").tag(true)
                    }
                }
                Section {
                    Text("示例：https://tts.example.com/api?text={text}&voice={voice}")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(engine == nil ? "添加引擎" : "编辑引擎")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let e = engine {
                    name = e.name
                    url = e.url
                    voice = e.voice
                    isPOST = e.method == "POST"
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(CustomTTSEngine(
                            id: engine?.id ?? UUID().uuidString,
                            name: name.trimmingCharacters(in: .whitespaces),
                            url: url.trimmingCharacters(in: .whitespaces),
                            voice: voice.trimmingCharacters(in: .whitespaces),
                            method: isPOST ? "POST" : "GET"
                        ))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("书源规则速查").font(.headline)

                Group {
                    Text("选择器").font(.subheadline).bold()
                    Text("""
                    class.xxx      按 class 取
                    id.xxx         按 id 取
                    tag.a          按标签取
                    text.关键词    按包含的文本取
                    children       取全部子元素
                    任意 CSS        .article > p
                    """)
                    .font(.system(size: 12, design: .monospaced))
                }

                Group {
                    Text("取值动作").font(.subheadline).bold()
                    Text("""
                    在规则后用 @ 接动作：
                    @text      取文本
                    @html      取 HTML（正文推荐）
                    @href      取链接（自动补全域名）
                    @src       取图片
                    @attr.xxx  取任意属性
                    """)
                    .font(.system(size: 12, design: .monospaced))
                }

                Group {
                    Text("组合").font(.subheadline).bold()
                    Text("""
                    规则1 || 规则2     前一个取不到就用后一个
                    规则1 && 规则2     两段结果合并
                    规则##正则##替换##  先取值再正则替换
                    规则[n]            取第 n 个
                    """)
                    .font(.system(size: 12, design: .monospaced))
                }

                Group {
                    Text("示例").font(.subheadline).bold()
                    Text("""
                    书单：class.book-item
                    书名：class.title@text
                    详情：class.title@href
                    目录：id.list@tag.a
                    正文：id.content@html
                    """)
                    .font(.system(size: 12, design: .monospaced))
                }

                Text("导入的 legado 书源如果用了 JS（@js:、{{ }}）或 XPath，目前不会执行，只走 CSS + 正则这条路。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("书源规则说明")
        .navigationBarTitleDisplayMode(.inline)
    }
}
