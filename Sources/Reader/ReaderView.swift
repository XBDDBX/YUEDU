import SwiftUI

@MainActor
struct ReaderView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let bookID: UUID
    @StateObject private var vm = ReaderViewModel()
    @ObservedObject private var tts = TTSEngine.shared
    @State private var appeared = false

    private var theme: ReaderTheme { store.settings.theme }
    private var bg: Color { Color(uiColor: UIColor(hex: theme.bg)) }
    private var fg: Color { Color(uiColor: UIColor(hex: theme.text)) }
    private var sub: Color { Color(uiColor: UIColor(hex: theme.secondary)) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                bg.ignoresSafeArea()

                // 正文
                Group {
                    if vm.pages.indices.contains(vm.pageIndex) {
                        PageTextView(attributed: vm.attributed,
                                     range: vm.pages[vm.pageIndex],
                                     insets: vm.pageInsets,
                                     highlight: vm.ttsHighlight)
                            .id(vm.pageIndex)
                            .transition(.opacity)
                    } else if vm.loading {
                        ProgressView().tint(fg)
                    } else if let err = vm.errorText {
                        VStack(spacing: 14) {
                            Text("这一章没加载出来").font(.headline).foregroundStyle(fg)
                            Text(err).font(.footnote).foregroundStyle(sub)
                                .multilineTextAlignment(.center).padding(.horizontal, 40)
                            Button("重试") {
                                Task { await vm.loadChapter(vm.chapterIndex, offset: vm.currentOffset()) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        Text("空章节").foregroundStyle(sub)
                    }
                }
                .padding(0)

                // 点击区
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { vm.prevPage() } }
                        .frame(width: geo.size.width * 0.28)
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { vm.showMenu.toggle() } }
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { vm.nextPage() } }
                        .frame(width: geo.size.width * 0.28)
                }

                // 页脚
                VStack {
                    Spacer()
                    HStack {
                        Text(vm.chapterTitle)
                            .font(.system(size: 11)).foregroundStyle(sub).lineLimit(1)
                        Spacer()
                        Text(vm.progressText)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(sub)
                    }
                    .padding(.horizontal, CGFloat(store.settings.marginH))
                    .padding(.bottom, 6)
                }
                .opacity(vm.showMenu ? 0 : 1)

                // 菜单
                if vm.showMenu {
                    menuOverlay
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if let t = store.toast {
                    VStack {
                        Spacer()
                        Text(t)
                            .font(.footnote)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 90)
                    }
                    .transition(.opacity)
                }
            }
            .onAppear {
                vm.layout(size: geo.size)
                if !appeared {
                    appeared = true
                    Task { await vm.open(bookID: bookID) }
                }
                TTSEngine.shared.onSegmentFinished = {
                    guard store.settings.ttsAutoNextChapter else { return }
                    Task { @MainActor in
                        if vm.pageIndex + 1 < vm.pages.count {
                            vm.pageIndex += 1
                        } else {
                            vm.nextChapter()
                            try? await Task.sleep(nanoseconds: 600_000_000)
                        }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        vm.speakCurrentPage()
                    }
                }
            }
            .onDisappear {
                vm.saveProgress()
                TTSEngine.shared.onSegmentFinished = nil
                TTSEngine.shared.stop()
            }
            .onChange(of: geo.size) { _, newValue in
                vm.layout(size: newValue, force: true)
            }
            .onChange(of: vm.content) { _, _ in
                vm.layout(size: geo.size, force: true)
            }
            .onReceive(tts.$spokenRange) { r in
                guard tts.isSpeaking || tts.isPaused else { vm.ttsHighlight = nil; return }
                guard let r, vm.pages.indices.contains(vm.pageIndex) else { return }
                let base = vm.pages[vm.pageIndex].location
                vm.ttsHighlight = NSRange(location: base + r.location, length: r.length)
            }
            .sheet(isPresented: $vm.showCatalog) {
                CatalogSheet(book: vm.book, current: vm.chapterIndex) { idx in
                    vm.jump(to: idx)
                }
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: - 菜单

    private var menuOverlay: some View {
        VStack(spacing: 0) {
            // 顶部
            HStack {
                Button {
                    vm.saveProgress()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                }
                Spacer()
                Text(vm.chapterTitle).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Spacer()
                Button {
                    store.settings.themeIndex = (store.settings.themeIndex + 1) % ReaderTheme.all.count
                    store.saveSettings()
                    vm.relayout()
                } label: {
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: 18))
                }
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(.ultraThinMaterial)

            Spacer()

            // 底部工具
            VStack(spacing: 0) {
                if tts.isSpeaking || tts.isPaused {
                    ttsBar
                }
                if vm.showSettings {
                    settingsPanel
                }
                HStack(spacing: 0) {
                    toolButton("list.bullet", "目录") { vm.showCatalog = true; vm.showMenu = false }
                    toolButton("textformat.size", "字号") {
                        withAnimation { vm.showSettings.toggle() }
                    }
                    toolButton(tts.isSpeaking ? "pause.circle" : "play.circle", tts.isSpeaking ? "暂停" : "朗读") {
                        if tts.isSpeaking { tts.pause() }
                        else if tts.isPaused { tts.resume() }
                        else { vm.speakCurrentPage() }
                    }
                    toolButton("slider.horizontal.3", "设置") {
                        withAnimation { vm.showSettings.toggle() }
                    }
                }
                .padding(.vertical, 10)
            }
            .foregroundStyle(fg)
            .background(.ultraThinMaterial)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func toolButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 19))
                Text(title).font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var ttsBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform").foregroundStyle(.blue)
            Text(tts.isPaused ? "已暂停" : "正在朗读 · \(tts.currentVoiceName)")
                .font(.system(size: 12)).lineLimit(1)
            Spacer()
            Button {
                tts.stop()
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 18))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }

    private var settingsPanel: some View {
        VStack(spacing: 14) {
            HStack {
                Text("字号").font(.system(size: 12)).frame(width: 44, alignment: .leading)
                Button { adjustFont(-1) } label: { Image(systemName: "minus.circle") }
                Text("\(Int(store.settings.fontSize))").font(.system(size: 13, design: .monospaced)).frame(width: 34)
                Button { adjustFont(1) } label: { Image(systemName: "plus.circle") }
                Spacer()
                Text("行距").font(.system(size: 12)).frame(width: 34, alignment: .leading)
                Slider(value: Binding(
                    get: { store.settings.lineSpacing },
                    set: { store.settings.lineSpacing = $0; store.saveSettings() }
                ), in: 0...22, step: 1)
                .frame(width: 110)
            }
            .font(.system(size: 17))

            HStack {
                Text("字体").font(.system(size: 12)).frame(width: 44, alignment: .leading)
                Picker("", selection: Binding(
                    get: { store.settings.fontFamily },
                    set: { store.settings.fontFamily = $0; store.saveSettings() }
                )) {
                    Text("系统").tag("system")
                    Text("宋体").tag("serif")
                    Text("圆体").tag("rounded")
                    Text("等宽").tag("mono")
                }
                .pickerStyle(.segmented)
            }

            HStack {
                Text("语速").font(.system(size: 12)).frame(width: 44, alignment: .leading)
                Slider(value: Binding(
                    get: { store.settings.ttsRate },
                    set: { store.settings.ttsRate = $0; store.saveSettings() }
                ), in: 0.3...0.7, step: 0.05)
                Toggle("自动续读", isOn: Binding(
                    get: { store.settings.ttsAutoNextChapter },
                    set: { store.settings.ttsAutoNextChapter = $0; store.saveSettings() }
                ))
                .labelsHidden()
                .font(.system(size: 12))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(ReaderTheme.all.enumerated()), id: \.offset) { idx, t in
                        Button {
                            store.settings.themeIndex = idx
                            store.saveSettings()
                            vm.relayout()
                        } label: {
                            ZStack {
                                Circle().fill(Color(uiColor: UIColor(hex: t.bg))).frame(width: 30, height: 30)
                                Circle().stroke(Color.gray.opacity(0.4), lineWidth: 0.8).frame(width: 30, height: 30)
                                if idx == store.settings.themeIndex {
                                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Color(uiColor: UIColor(hex: t.text)))
                                }
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Divider() }
    }

    private func adjustFont(_ delta: Double) {
        let v = min(max(store.settings.fontSize + delta, 13), 34)
        store.settings.fontSize = v
        store.saveSettings()
        vm.relayout()
    }
}
