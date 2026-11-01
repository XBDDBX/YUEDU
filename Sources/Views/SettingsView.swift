import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var cacheText = "—"
    @State private var showReset = false

    var body: some View {
        NavigationStack {
            Form {
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

    var body: some View {
        List {
            Section {
                if store.settings.customTTS.isEmpty {
                    Text("还没有自定义引擎。添加一个返回音频（mp3 / wav）的 TTS 服务地址即可。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(store.settings.customTTS) { e in
                    Button {
                        editing = e
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.name).font(.system(size: 15, weight: .medium))
                            Text(e.url).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
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
                    Label("添加自定义引擎", systemImage: "plus")
                }
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
