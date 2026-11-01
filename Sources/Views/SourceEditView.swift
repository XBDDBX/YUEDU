import SwiftUI

struct SourceEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State var source: BookSource
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("基础") {
                    TextField("名称", text: $source.name)
                    TextField("分组", text: $source.group)
                    TextField("站点地址", text: $source.url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Toggle("启用", isOn: $source.enabled)
                }

                Section {
                    TextField("搜索地址（含 {{key}}）", text: $source.searchUrl, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...4)
                } header: {
                    Text("搜索")
                } footer: {
                    Text("例如：https://站点/search?q={{key}}")
                }

                Section("搜索规则") {
                    ruleField("书单", $source.ruleSearch.bookList)
                    ruleField("书名", $source.ruleSearch.name)
                    ruleField("作者", $source.ruleSearch.author)
                    ruleField("封面", $source.ruleSearch.coverUrl)
                    ruleField("详情链接", $source.ruleSearch.bookUrl)
                    ruleField("简介", $source.ruleSearch.intro)
                    ruleField("最新章", $source.ruleSearch.lastChapter)
                }

                Section("目录规则") {
                    ruleField("章节列表", $source.ruleToc.chapterList)
                    ruleField("章节名", $source.ruleToc.chapterName)
                    ruleField("章节链接", $source.ruleToc.chapterUrl)
                }

                Section("正文规则") {
                    ruleField("正文", $source.ruleContent.content)
                    ruleField("下一页", $source.ruleContent.nextContentUrl)
                }

                Section {
                    Button {
                        test()
                    } label: {
                        HStack {
                            if testing { ProgressView().scaleEffect(0.8) }
                            Text(testing ? "测试中…" : "测试这个书源")
                        }
                    }
                    .disabled(testing || source.searchUrl.isEmpty)
                } footer: {
                    if let r = testResult {
                        Text(r).font(.footnote)
                    }
                }

                Section {
                    Button("删除这个书源", role: .destructive) {
                        store.deleteSource(source)
                        dismiss()
                    }
                }
            }
            .navigationTitle(source.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.updateSource(source)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func ruleField(_ label: String, _ binding: Binding<String>) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            TextField("规则", text: binding, axis: .vertical)
                .font(.system(size: 12, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1...3)
        }
    }

    private func test() {
        testing = true
        testResult = nil
        let s = source
        Task {
            do {
                let books = try await SourceService(source: s).search("测试")
                if books.isEmpty {
                    testResult = "请求成功，但没解析出书。搜索规则可能不对，或者这个站需要特定关键词。"
                } else {
                    testResult = "成功，解析到 \(books.count) 本，例如《\(books[0].title)》"
                }
            } catch {
                testResult = "失败：\(error.localizedDescription)"
            }
            testing = false
        }
    }
}
