import SwiftUI

// MARK: - 通用卡片组件

let settingsAccent = Color(red: 0.95, green: 0.45, blue: 0.24)
let settingsBG = Color(red: 0.99, green: 0.97, blue: 0.95)

struct SettingsCardGroup<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 7, y: 2)
    }
}

struct SettingIcon: View {
    let name: String
    var color: Color = settingsAccent

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 30, height: 30)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SettingsRow: View {
    let icon: String
    let title: String
    var detail: String? = nil
    var showsChevron: Bool = true
    var color: Color = settingsAccent

    var body: some View {
        HStack(spacing: 12) {
            SettingIcon(name: icon, color: color)
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 56)
    }
}

// MARK: - 设置主页

struct SettingsHomeView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var purify = PurifyStore.shared

    @State private var cacheText = "—"
    @State private var showReset = false

    private var engineCount: Int { store.settings.customTTS.count + 1 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // 1. 配置 / 朗读
                    SettingsCardGroup {
                        NavigationLink { SourceConfigPage() } label: {
                            SettingsRow(icon: "square.stack.3d.up", title: "配置", detail: "\(store.sources.count)个")
                        }
                        .buttonStyle(.plain)

                        RowDivider()

                        NavigationLink { TTSConfigPage() } label: {
                            SettingsRow(icon: "waveform", title: "朗读", detail: "\(engineCount)个")
                        }
                        .buttonStyle(.plain)
                    }

                    // 2. 替换净化 / 目录规则
                    SettingsCardGroup {
                        NavigationLink { PurifyListPage(scope: .content) } label: {
                            SettingsRow(icon: "shield.lefthalf.filled", title: "替换净化", detail: "\(purify.contentCount)条")
                        }
                        .buttonStyle(.plain)

                        RowDivider()

                        NavigationLink { PurifyListPage(scope: .catalog) } label: {
                            SettingsRow(icon: "list.bullet.indent", title: "目录规则", detail: "\(purify.catalogCount)条")
                        }
                        .buttonStyle(.plain)
                    }

                    // 3. 阅读设置 / 字体 / 预缓存
                    SettingsCardGroup {
                        NavigationLink { ReadingSettingsPage() } label: {
                            SettingsRow(icon: "book", title: "阅读设置", detail: "主题 / 显示 / 朗读")
                        }
                        .buttonStyle(.plain)

                        RowDivider()

                        NavigationLink { FontManagePage() } label: {
                            SettingsRow(icon: "textformat.size", title: "字体管理", detail: "内置 4 个")
                        }
                        .buttonStyle(.plain)

                        RowDivider()

                        chapterPreloadRow
                    }

                    // 4. 外观 / 统计 / 文件
                    SettingsCardGroup {
                        NavigationLink { ThemePage() } label: {
                            SettingsRow(icon: "paintpalette", title: "外观主题")
                        }
                        .buttonStyle(.plain)

                        RowDivider()

                        NavigationLink { StatsPage() } label: {
                            SettingsRow(icon: "chart.bar", title: "统计",
                                        detail: store.settings.statsEnabled ? "已开启" : "已关闭")
                        }
                        .buttonStyle(.plain)

                        RowDivider()

                        NavigationLink { FileManagePage() } label: {
                            SettingsRow(icon: "folder", title: "文件管理")
                        }
                        .buttonStyle(.plain)
                    }

                    // 5. 备份 / 缓存
                    SettingsCardGroup {
                        NavigationLink { BackupPage() } label: {
                            SettingsRow(icon: "arrow.triangle.2.circlepath.icloud", title: "备份与同步")
                        }
                        .buttonStyle(.plain)

                        RowDivider()

                        NavigationLink { CachePage(cacheText: $cacheText, onRefresh: refreshCache) } label: {
                            SettingsRow(icon: "internaldrive", title: "缓存管理", detail: cacheText)
                        }
                        .buttonStyle(.plain)
                    }

                    // 关于
                    SettingsCardGroup {
                        NavigationLink { AboutPage() } label: {
                            SettingsRow(icon: "info.circle", title: "关于清阅", detail: "1.1.0")
                        }
                        .buttonStyle(.plain)
                    }

                    Text("清阅 · 本地优先的阅读器")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(settingsBG.ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: refreshCache)
        }
    }

    private var chapterPreloadRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                SettingIcon(name: "arrow.down.doc")
                Text("章节预缓存").font(.system(size: 15))
                Spacer()
                Text(store.settings.chapterPreload == 0 ? "已关闭" : "\(store.settings.chapterPreload)章")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { Double(store.settings.chapterPreload) },
                set: { store.settings.chapterPreload = Int($0); store.saveSettings() }
            ), in: 0...5, step: 1)
            .tint(settingsAccent)
            .padding(.leading, 42)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func refreshCache() {
        let bytes = store.cacheSize()
        let f = ByteCountFormatter()
        f.countStyle = .file
        cacheText = f.string(fromByteCount: bytes)
    }
}

// MARK: - 关于

struct AboutPage: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(settingsAccent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("清阅").font(.system(size: 17, weight: .semibold))
                        Text("版本 1.1.0").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }

            Section("概况") {
                LabeledContent("书源", value: "\(store.sources.count) 个")
                LabeledContent("书架", value: "\(store.books.count) 本")
                LabeledContent("净化规则", value: "\(PurifyStore.shared.enabledCount) 条启用")
            }

            Section {
                NavigationLink("书源规则说明") { HelpView() }
            }

            Section {
                Text("完全本地运行：书源、书架、进度、净化规则都存在你自己的设备上，不经过任何服务器。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
