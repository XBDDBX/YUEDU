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
    @State private var loginSource: BookSource?

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
                            if !s.loginUrl.isEmpty {
                                Button {
                                    loginSource = s
                                } label: {
                                    Image(systemName: SourceService(source: s).cookieHasToken() ? "person.fill.checkmark" : "person.badge.key")
                                        .font(.system(size: 15))
                                        .foregroundStyle(SourceService(source: s).cookieHasToken() ? .green : .secondary)
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
                        alertText = "没有识别到有效书源"
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
            if n > 0 { checkCapabilityHints() }
        } catch {
            alertText = "拉取失败：\(error.localizedDescription)"
        }
        busy = false
    }

    /// 导入包含 JS / 登录 / 发现页能力的书源时给出提示
    private func checkCapabilityHints() {
        let jsCount = store.sources.filter { !$0.jsLib.isEmpty || $0.searchUrl.hasPrefix("<js>") }.count
        let loginCount = store.sources.filter { !$0.loginUrl.isEmpty }.count
        let exploreCount = store.sources.filter { !$0.exploreUrl.isEmpty }.count
        var hints: [String] = []
        if jsCount > 0 { hints.append("\(jsCount) 个为 JS 引擎书源（需真机验证）") }
        if loginCount > 0 { hints.append("\(loginCount) 个支持登录，导入后点击行内钥匙图标登录") }
        if exploreCount > 0 { hints.append("\(exploreCount) 个支持发现页，已加入底部「发现」页") }
        if !hints.isEmpty {
            alertText = "导入完成。" + hints.joined(separator: "；")
        }
    }
}

// MARK: - 书源登录

struct SourceLoginSheet: View {
    let source: BookSource
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var key = ""
    @State private var busy = false
    @State private var resultText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(source.name).font(.system(size: 14, weight: .medium))
                    Text("登录后该书源会记住状态，搜索 / 发现页直接可用。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section("账号") {
                    TextField("邮箱", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                    if source.loginUi.contains("密钥") || keyUsed {
                        TextField("密钥", text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                Section {
                    Button {
                        Task { await doLogin() }
                    } label: {
                        if busy {
                            ProgressView()
                        } else {
                            Text("登录")
                        }
                    }
                    .disabled(busy || (email.isEmpty && key.isEmpty))
                }
                if let resultText {
                    Section {
                        Text(resultText).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("登录书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var keyUsed: Bool { !key.isEmpty }

    private func doLogin() async {
        busy = true
        defer { busy = false }
        var info: [String: String] = [:]
        if !email.isEmpty { info["邮箱"] = email }
        if !password.isEmpty { info["密码"] = password }
        if !key.isEmpty { info["密钥"] = key }
        store.setLoginInfo(try! String(data: JSONSerialization.data(withJSONObject: info), encoding: .utf8)!,
                           for: source.id)
        let svc = SourceService(source: source)
        let msg = await svc.login(flag: true)
        resultText = msg + (svc.cookieHasToken() ? "（已写入 cookie）" : "")
    }
}
