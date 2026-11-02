import SwiftUI
import UniformTypeIdentifiers

struct SourceListView: View {
    @EnvironmentObject var store: AppStore

    @State private var showImportURL = false
    @State private var showImporter = false
    @State private var showImportSheet = false
    @State private var editing: BookSource?
    @State private var urlText = ""
    @State private var busy = false
    @State private var alertText: String?
    @State private var loginSource: BookSource?
    @State private var confirmDelete: BookSource?

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
                                    Image(systemName: store.sourceHasAccount(s) ? "person.fill.checkmark" : "person.badge.key")
                                        .font(.system(size: 15))
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
                                    alertText = "已清除「\(s.name)」的账号信息"
                                } label: {
                                    Label("清除账号", systemImage: "person.crop.circle.badge.xmark")
                                }
                            }
                            Button(role: .destructive) {
                                confirmDelete = s
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { idx in
                        for i in idx { store.deleteSource(store.sources[i]) }
                    }
                } header: {
                    Text("已导入 \(store.sources.count) 个 · 启用 \(store.enabledSources.count) 个")
                } footer: {
                    Text("点击书源打开规则编辑；左滑可清除账号 / 删除书源。")
                }

                Section {
                    Button {
                        showImportSheet = true
                    } label: {
                        HStack {
                            Label("导入书源", systemImage: "plus.circle.fill")
                            Spacer()
                            Text("链接 / 剪贴板 / 文件")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("导入")
                } footer: {
                    Text("书源格式与「阅读」App 通用。导入后点击书源即可打开规则编辑，启用后到「找书 / 发现」页使用。")
                }
            }
            .navigationTitle("书源")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImportSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showImportSheet) {
                SourceImportSheet().environmentObject(store)
            }
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
            .confirmationDialog("删除书源「\(confirmDelete?.name ?? "")」？", isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ), titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let s = confirmDelete {
                        store.deleteSource(s)
                        alertText = "已删除「\(s.name)」"
                    }
                    confirmDelete = nil
                }
                Button("取消", role: .cancel) { confirmDelete = nil }
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

    private var hasAccount: Bool { store.sourceHasAccount(source) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(source.name).font(.system(size: 14, weight: .medium))
                    HStack(spacing: 6) {
                        Image(systemName: hasAccount ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(hasAccount ? .green : .secondary)
                        Text(hasAccount ? "已登录（cookie 已保存）" : "未登录")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Section {
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
                } header: {
                    Text("账号")
                } footer: {
                    Text("与「阅读」App 书源登录一致：填邮箱 / 密码 / 密钥后点登录，成功会自动保存 cookie。")
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
                    if hasAccount {
                        Button(role: .destructive) {
                            store.clearSourceAccount(source)
                            resultText = "已清除「\(source.name)」的账号信息"
                        } label: {
                            Label("清除账号信息", systemImage: "person.crop.circle.badge.xmark")
                        }
                    }
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
        .presentationDetents([.medium, .large])
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
        if svc.cookieHasToken() {
            resultText = "登录成功：\(msg)"
        } else {
            resultText = "未成功：\(msg)。请确认账号正确，或到「设置 → 书源」左滑清除账号后重试。"
        }
    }
}
