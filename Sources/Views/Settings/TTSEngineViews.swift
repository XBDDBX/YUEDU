import SwiftUI
import UniformTypeIdentifiers

// MARK: - 朗读引擎管理

/// 自定义朗读引擎管理：导入 / 编辑 / 测试 / 试听
struct CustomTTSView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var tts = TTSEngine.shared

    @State private var showAdd = false
    @State private var editing: CustomTTSEngine?
    @State private var showFile = false
    @State private var showLinkEditor = false
    @State private var urlText = ""
    @State private var alertText: String?
    @State private var testingID: String?


    private var currentEngine: CustomTTSEngine? {
        let id = store.settings.ttsEngineID
        guard !id.isEmpty else { return nil }
        return store.settings.customTTS.first(where: { $0.id == id })
    }

    var body: some View {
        List {
            Section {
                if store.settings.customTTS.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("还没有自定义引擎")
                            .font(.system(size: 14, weight: .medium))
                        Text("可以导入一个返回音频的 TTS 服务（mp3 / wav / JSON），也可以用内置的系统语音。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                ForEach(store.settings.customTTS) { e in
                    engineRow(e)
                }
                .onDelete { idx in
                    store.settings.customTTS.remove(atOffsets: idx)
                    store.saveSettings()
                }
            } header: {
                Text("已添加 \(store.settings.customTTS.count) 个")
            } footer: {
                Text("请求地址里用 {text} 放正文、{voice} 放音色、{rate} 放语速。若地址里没有 {text}，会自动作为 query 参数拼在后面。")
            }

            Section {
                Button {
                    showFile = true
                } label: {
                    Label("从文件导入（JSON）", systemImage: "folder")
                }
                Button {
                    importFromClipboard()
                } label: {
                    Label("从剪贴板导入", systemImage: "doc.on.clipboard")
                }
                Button {
                    urlText = ""
                    showLinkEditor = true
                } label: {
                    Label("从链接导入", systemImage: "link")
                }
                Button {
                    showAdd = true
                } label: {
                    Label("手动添加", systemImage: "plus")
                }
            } header: {
                Text("添加引擎")
            } footer: {
                Text("支持这几种 JSON：数组 [{name,url,voice,method}]、{ttsEngines:[…]}、{tts_engines:[…]}、单个引擎对象。也认 url/endpoint、voice/speaker 这些别名。")
            }

            if let e = currentEngine {
                Section("当前使用") {
                    HStack {
                        SettingIcon(name: "waveform")
                        Text(e.name).font(.system(size: 14))
                        Spacer()
                        Text("使用中").font(.system(size: 11)).foregroundStyle(.green)
                    }
                }
            }
        }
        .navigationTitle("朗读引擎")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd) {
            CustomTTSEditSheet(engine: nil) { engine in
                store.settings.customTTS.append(engine)
                store.settings.ttsEngineID = engine.id
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
        .sheet(isPresented: $showLinkEditor) {
            NavigationStack {
                Form {
                    Section("订阅 / 直链地址") {
                        TextField("https://…/tts.json", text: $urlText, axis: .vertical)
                            .lineLimit(2...4)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .navigationTitle("从链接导入")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showLinkEditor = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("拉取") {
                            let u = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                            showLinkEditor = false
                            if !u.isEmpty { importFromURL(u) }
                        }
                        .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.height(220)])
        }
        .fileImporter(isPresented: $showFile,
                      allowedContentTypes: [.json, .plainText, .data, .text],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let u = urls.first {
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                if let d = try? Data(contentsOf: u) {
                    importFromData(d)
                } else {
                    alertText = "文件读不出来"
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

    // MARK: - 行

    private func engineRow(_ e: CustomTTSEngine) -> some View {
        let isCurrent = store.settings.ttsEngineID == e.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isCurrent ? settingsAccent : Color(.tertiaryLabel))
                Text(e.name).font(.system(size: 15, weight: .medium))
                Spacer()
                if testingID == e.id {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Button {
                        test(e)
                    } label: {
                        Text("测试").font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                }
            }
            Text(e.url.isEmpty ? "（未填请求地址）" : e.url)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                chip(e.method.uppercased())
                if !e.voice.isEmpty { chip("音色 \(e.voice)") }
                if e.responseType != "audio" { chip(e.responseType.uppercased()) }
                Spacer()
                Button {
                    store.settings.ttsEngineID = isCurrent ? "" : e.id
                    store.saveSettings()
                } label: {
                    Text(isCurrent ? "取消使用" : "使用")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                Button {
                    editing = e
                } label: {
                    Text("编辑").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 3)
    }

    private func chip(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 9))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .foregroundStyle(.secondary)
    }

    // MARK: - 测试

    private func test(_ e: CustomTTSEngine) {
        testingID = e.id
        let settings = store.settings
        Task {
            do {
                let data = try await TTSEngine.fetchAudio(engine: e,
                                                          text: "这是一段测试朗读，用来确认引擎能不能正常返回音频。",
                                                          settings: settings)
                await MainActor.run {
                    testingID = nil
                    alertText = "引擎可用，返回 \(data.count) 字节音频。\n可以点「使用」把它设为默认朗读引擎。"
                }
            } catch {
                await MainActor.run {
                    testingID = nil
                    alertText = "测试没通过：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - 导入

    private func importFromClipboard() {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alertText = "剪贴板里没有内容"
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            importFromURL(trimmed)
            return
        }
        guard let d = trimmed.data(using: .utf8) else {
            alertText = "剪贴板内容不是文本"
            return
        }
        importFromData(d)
    }

    private func importFromURL(_ urlString: String) {
        Task {
            do {
                let data = try await SourceFetcher.data(urlString)
                await MainActor.run { importFromData(data) }
            } catch {
                await MainActor.run { alertText = "拉取失败：\(error.localizedDescription)" }
            }
        }
    }

    private func importFromData(_ data: Data) {
        let list = CustomTTSEngine.decodeList(from: data)
        guard !list.isEmpty else {
            alertText = "没识别到引擎条目（至少要有 name 和 url）"
            return
        }
        var added = 0
        for var e in list {
            if store.settings.customTTS.contains(where: { $0.name == e.name && $0.url == e.url }) {
                continue
            }
            e.id = UUID().uuidString
            store.settings.customTTS.append(e)
            added += 1
        }
        store.saveSettings()
        let skipped = list.count - added
        alertText = skipped > 0
            ? "导入 \(added) 个引擎，\(skipped) 个重复已跳过"
            : "导入了 \(added) 个引擎"
    }
}

// MARK: - 引擎 JSON 解析

extension CustomTTSEngine {
    /// 兼容多种 TTS 引擎导出格式
    static func decodeList(from data: Data) -> [CustomTTSEngine] {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return []
        }
        var raw: [[String: Any]] = []
        if let arr = obj as? [[String: Any]] {
            raw = arr
        } else if let dict = obj as? [String: Any] {
            if let arr = dict["ttsEngines"] as? [[String: Any]] {
                raw = arr
            } else if let arr = dict["tts_engines"] as? [[String: Any]] {
                raw = arr
            } else if let arr = dict["engines"] as? [[String: Any]] {
                raw = arr
            } else if let arr = dict["data"] as? [[String: Any]] {
                raw = arr
            } else {
                raw = [dict]
            }
        }
        return raw.compactMap { item -> CustomTTSEngine? in
            let name = firstString(item, ["name", "engineName", "label", "title"])
            let url = firstString(item, ["url", "endpoint", "api", "address"])
            guard !name.isEmpty, !url.isEmpty else { return nil }
            let voice = firstString(item, ["voice", "speaker", "voiceId", "voice_id"])
            let method = firstString(item, ["method", "type"]).uppercased() == "POST" ? "POST" : "GET"
            let headers = dictString(item["headers"])
            let body = firstString(item, ["body", "bodyTemplate", "payload"])
            let respType = firstString(item, ["responseType", "response_type", "response"]).lowercased()
            let respPath = firstString(item, ["responsePath", "response_path", "audioPath", "audio_path"])
            var e = CustomTTSEngine()
            e.id = UUID().uuidString
            e.name = name
            e.url = url
            e.voice = voice
            e.method = method
            e.headers = headers
            e.bodyTemplate = body
            if ["audio", "url", "base64"].contains(respType) { e.responseType = respType }
            e.responsePath = respPath
            return e
        }
    }

    private static func firstString(_ dict: [String: Any], _ keys: [String]) -> String {
        for k in keys {
            if let s = dict[k] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                return s.trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private static func dictString(_ any: Any?) -> String {
        guard let d = any as? [String: Any], !d.isEmpty else {
            if let s = any as? String { return s }
            return ""
        }
        guard let data = try? JSONSerialization.data(withJSONObject: d),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}

// MARK: - 引擎编辑

struct CustomTTSEditSheet: View {
    let engine: CustomTTSEngine?
    let onSave: (CustomTTSEngine) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var voice = ""
    @State private var isPOST = false
    @State private var headers = ""
    @State private var bodyTemplate = ""
    @State private var responseType = "audio"
    @State private var responsePath = ""
    @State private var alertText: String?
    @State private var testing = false

    private let types = ["audio", "url", "base64"]

    var body: some View {
        NavigationStack {
            Form {
                Section("引擎") {
                    TextField("名称（如：Edge TTS）", text: $name)
                    TextField("请求地址", text: $url, axis: .vertical)
                        .lineLimit(1...3)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("音色（可选）", text: $voice)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("请求方式", selection: $isPOST) {
                        Text("GET").tag(false)
                        Text("POST").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Text("示例：https://tts.example.com/api?text={text}&voice={voice}&rate={rate}")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } header: {
                    Text("占位符")
                }

                Section {
                    TextField("{\"Authorization\":\"Bearer …\"}", text: $headers, axis: .vertical)
                        .lineLimit(1...3)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("请求头（JSON，可选）")
                }

                if isPOST {
                    Section {
                        TextField("{\"text\":\"{text}\",\"voice\":\"{voice}\"}", text: $bodyTemplate, axis: .vertical)
                            .lineLimit(2...5)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("请求体模板（留空用默认 JSON）")
                    }
                }

                Section {
                    Picker("返回类型", selection: $responseType) {
                        Text("直接音频").tag("audio")
                        Text("JSON 里的地址").tag("url")
                        Text("JSON 里的 Base64").tag("base64")
                    }
                    if responseType != "audio" {
                        TextField("音频路径，如 data.audio", text: $responsePath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("返回内容")
                } footer: {
                    Text("有些服务返回 JSON 包一层，这时选「地址」或「Base64」并填路径。")
                }

                Section {
                    Button {
                        test()
                    } label: {
                        HStack {
                            if testing { ProgressView().scaleEffect(0.7) }
                            Text(testing ? "测试中…" : "测试这个引擎")
                        }
                    }
                    .disabled(testing || url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle(engine == nil ? "添加引擎" : "编辑引擎")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard let e = engine else { return }
                name = e.name
                url = e.url
                voice = e.voice
                isPOST = e.method.uppercased() == "POST"
                headers = e.headers
                bodyTemplate = e.bodyTemplate
                responseType = e.responseType.isEmpty ? "audio" : e.responseType
                responsePath = e.responsePath
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var e = CustomTTSEngine()
                        e.id = engine?.id ?? UUID().uuidString
                        e.name = name.trimmingCharacters(in: .whitespaces)
                        e.url = url.trimmingCharacters(in: .whitespaces)
                        e.voice = voice.trimmingCharacters(in: .whitespaces)
                        e.method = isPOST ? "POST" : "GET"
                        e.headers = headers.trimmingCharacters(in: .whitespacesAndNewlines)
                        e.bodyTemplate = bodyTemplate
                        e.responseType = responseType
                        e.responsePath = responsePath.trimmingCharacters(in: .whitespaces)
                        onSave(e)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || url.trimmingCharacters(in: .whitespaces).isEmpty)
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
        .presentationDetents([.large])
    }

    private func test() {
        testing = true
        var e = CustomTTSEngine()
        e.id = engine?.id ?? UUID().uuidString
        e.name = name
        e.url = url.trimmingCharacters(in: .whitespaces)
        e.voice = voice
        e.method = isPOST ? "POST" : "GET"
        e.headers = headers.trimmingCharacters(in: .whitespacesAndNewlines)
        e.bodyTemplate = bodyTemplate
        e.responseType = responseType
        e.responsePath = responsePath.trimmingCharacters(in: .whitespaces)

        var settings = ReaderSettings()
        settings.ttsRate = 0.5
        Task {
            do {
                let data = try await TTSEngine.fetchAudio(engine: e, text: "这是一段测试朗读。", settings: settings)
                await MainActor.run {
                    testing = false
                    alertText = "测试通过，返回 \(data.count) 字节音频。"
                }
            } catch {
                await MainActor.run {
                    testing = false
                    alertText = "测试没通过：\(error.localizedDescription)"
                }
            }
        }
    }
}
