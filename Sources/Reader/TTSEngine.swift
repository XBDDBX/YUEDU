import Foundation
import AVFoundation
import MediaPlayer
import Combine

/// 朗读引擎
///
/// - 长文本按句切段，逐段合成播放，段间无缝衔接
/// - 自定义 HTTP 引擎：下一段提前预取，播放不停顿
/// - 支持 POST / 自定义 header / JSON 返回（url、base64、直出音频）
/// - 后台播放 + 锁屏 / 耳机控制
/// - 定时停止（听书助眠）
@MainActor
final class TTSEngine: NSObject, ObservableObject {
    static let shared = TTSEngine()

    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    /// 当前朗读位置（相对传入文本的 UTF-16 区间）
    @Published private(set) var spokenRange: NSRange?
    @Published private(set) var currentVoiceName: String = ""

    /// 当前段 / 总段数
    @Published private(set) var chunkIndex: Int = 0
    @Published private(set) var chunkTotal: Int = 0
    /// 定时停止剩余秒数（0 = 未开启）
    @Published private(set) var sleepRemaining: Int = 0
    /// 朗读上下文（锁屏显示用）
    @Published private(set) var contextTitle: String = ""
    @Published private(set) var contextSubtitle: String = ""
    /// 当前朗读的纯文本（用于界面预览）
    @Published private(set) var currentChunkText: String = ""

    /// 一段（整页）读完后回调（用于自动翻页 / 下一章）
    var onSegmentFinished: (@MainActor () -> Void)?

    private lazy var synth: AVSpeechSynthesizer = {
        let s = AVSpeechSynthesizer()
        s.delegate = self
        return s
    }()

    private var player: AVAudioPlayer?
    private var chunks: [TTSChunk] = []
    private var settingsSnapshot: ReaderSettings = ReaderSettings()
    private var customEngine: CustomTTSEngine?
    private var prefetched: [Int: Data] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    /// 递增令牌：旧的异步回调据此丢弃
    private var session: Int = 0
    private var remoteConfigured = false
    /// utterance → 发起时的会话令牌，用于丢弃已作废的回调
    private var utteranceTokens: [ObjectIdentifier: Int] = [:]
    /// 上一次朗读的文本，用于区分「继续」还是「换一页」
    private var lastText: String = ""

    // MARK: - 音色

    var availableVoices: [(id: String, name: String, lang: String)] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") || $0.language.hasPrefix("en") }
            .map { (id: $0.identifier, name: "\($0.name) (\($0.language))", lang: $0.language) }
    }

    var progress: Double {
        guard chunkTotal > 0 else { return 0 }
        return min(1, Double(chunkIndex) / Double(chunkTotal))
    }

    // MARK: - 开始朗读

    func setContext(title: String, subtitle: String) {
        contextTitle = title
        contextSubtitle = subtitle
        if isSpeaking { refreshNowPlaying() }
    }

    func speak(_ text: String, settings: ReaderSettings) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        // 同一段文本暂停后再点朗读 = 继续；换页了就当新内容
        if isPaused, !chunks.isEmpty, lastText == clean {
            resume()
            return
        }

        stopPlayback(keepSession: false)
        session += 1
        let token = session

        settingsSnapshot = settings
        lastText = clean
        customEngine = settings.customTTS.first(where: { $0.id == settings.ttsEngineID })
        chunks = TTSSplitter.chunks(for: text, limit: customEngine == nil ? 400 : 140)
        chunkIndex = 0
        chunkTotal = chunks.count
        prefetched.removeAll()
        guard !chunks.isEmpty else { return }

        isSpeaking = true
        isPaused = false
        spokenRange = nil
        activateSession()
        setupRemoteIfNeeded()

        if let engine = customEngine {
            currentVoiceName = engine.name.isEmpty ? "自定义引擎" : engine.name
            currentChunkText = chunks[0].text
            playCustom(at: 0, token: token)
        } else {
            currentVoiceName = voiceDisplayName(settings)
            playSystem(at: 0)
        }
        refreshNowPlaying()
    }

    /// 音色试听（设置页用）
    func preview(_ text: String, settings: ReaderSettings) {
        let sample = text.isEmpty ? "这是一段试听。清阅，把书读给你听。" : text
        speak(sample, settings: settings)
    }

    // MARK: - 系统 TTS

    private func playSystem(at index: Int) {
        guard chunks.indices.contains(index) else { finishAll(); return }
        chunkIndex = index
        let chunk = chunks[index]
        currentChunkText = chunk.text

        let utt = AVSpeechUtterance(string: chunk.text)
        if let v = AVSpeechSynthesisVoice(identifier: settingsSnapshot.ttsVoiceID) {
            utt.voice = v
        } else {
            utt.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }
        utt.rate = Float(settingsSnapshot.ttsRate)
        utt.pitchMultiplier = Float(settingsSnapshot.ttsPitch)
        utt.preUtteranceDelay = 0.02
        utt.postUtteranceDelay = 0.02
        // 只保留最近几条，防止字典无限增长
        if utteranceTokens.count > 12 { utteranceTokens.removeAll() }
        utteranceTokens[ObjectIdentifier(utt)] = session
        synth.speak(utt)
    }

    private func voiceDisplayName(_ settings: ReaderSettings) -> String {
        if let v = AVSpeechSynthesisVoice(identifier: settings.ttsVoiceID) {
            return v.name
        }
        return "系统语音"
    }

    // MARK: - 自定义引擎

    private func playCustom(at index: Int, token: Int) {
        guard chunks.indices.contains(index) else { finishAll(); return }
        chunkIndex = index
        let chunk = chunks[index]
        currentChunkText = chunk.text

        let engine = customEngine
        let settings = settingsSnapshot

        var cached: Data?
        if let d = prefetched[index] {
            cached = d
            prefetched[index] = nil
        }
        prefetch(index: index + 1, token: token)

        if let data = cached {
            startAudio(data, token: token)
            return
        }
        guard let engine else { finishAll(); return }
        playTask?.cancel()
        playTask = Task { [weak self] in
            let data = try? await Self.fetchAudio(engine: engine, text: chunk.text, settings: settings)
            guard let self else { return }
            guard !Task.isCancelled, self.session == token else { return }
            if let data {
                self.startAudio(data, token: token)
            } else {
                // 这一段失败就跳下一段，别整页卡死
                self.advanceCustom(token: token)
            }
        }
    }

    private func prefetch(index: Int, token: Int) {
        guard let engine = customEngine, chunks.indices.contains(index), prefetched[index] == nil else { return }
        let chunk = chunks[index]
        let settings = settingsSnapshot
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            let data = try? await Self.fetchAudio(engine: engine, text: chunk.text, settings: settings)
            guard let self, let data else { return }
            guard !Task.isCancelled, self.session == token else { return }
            self.prefetched[index] = data
        }
    }

    private func advanceCustom(token: Int) {
        guard session == token else { return }
        let next = chunkIndex + 1
        if next < chunks.count {
            playCustom(at: next, token: token)
        } else {
            finishAll()
        }
    }

    private func startAudio(_ data: Data, token: Int) {
        guard session == token else { return }
        player?.stop()
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.enableRate = true
            player = p
            p.play()
            isSpeaking = true
            isPaused = false
            refreshNowPlaying()
        } catch {
            advanceCustom(token: token)
        }
    }

    /// 请求一段音频：支持 GET / POST、自定义 header、直接音频 / JSON url / base64
    nonisolated static func fetchAudio(engine: CustomTTSEngine,
                                       text: String,
                                       settings: ReaderSettings) async throws -> Data {
        let encodedText = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        let encodedVoice = engine.voice.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? engine.voice
        let rate = String(format: "%.2f", settings.ttsRate)
        let pitch = String(format: "%.2f", settings.ttsPitch)

        let urlString = engine.url
            .replacingOccurrences(of: "{text}", with: encodedText)
            .replacingOccurrences(of: "{voice}", with: encodedVoice)
            .replacingOccurrences(of: "{rate}", with: rate)
            .replacingOccurrences(of: "{pitch}", with: pitch)
            .replacingOccurrences(of: "{format}", with: "mp3")

        guard var url = URL(string: urlString) else { throw FetchError.badURL }
        // GET 且还有未替换的占位：把文本塞进 query
        if engine.method.uppercased() == "GET", !engine.url.contains("{text}") {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var items = comps?.queryItems ?? []
            items.append(URLQueryItem(name: "text", value: text))
            if !engine.voice.isEmpty { items.append(URLQueryItem(name: "voice", value: engine.voice)) }
            comps?.queryItems = items
            if let u = comps?.url { url = u }
        }

        var req = URLRequest(url: url)
        req.httpMethod = engine.method.uppercased() == "POST" ? "POST" : "GET"
        req.timeoutInterval = 45
        req.setValue(SourceFetcher.userAgent, forHTTPHeaderField: "User-Agent")

        if let hd = engine.headers.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: hd) as? [String: Any] {
            for (k, v) in obj { req.setValue(Flex.str(v), forHTTPHeaderField: k) }
        }

        if req.httpMethod == "POST" {
            if engine.bodyTemplate.isEmpty {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let body: [String: Any] = ["text": text,
                                           "voice": engine.voice,
                                           "rate": settings.ttsRate,
                                           "pitch": settings.ttsPitch,
                                           "format": "mp3"]
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            } else {
                if req.value(forHTTPHeaderField: "Content-Type") == nil {
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
                var tpl = engine.bodyTemplate
                tpl = tpl.replacingOccurrences(of: "{text}", with: Self.jsonEscape(text))
                tpl = tpl.replacingOccurrences(of: "{voice}", with: Self.jsonEscape(engine.voice))
                tpl = tpl.replacingOccurrences(of: "{rate}", with: rate)
                tpl = tpl.replacingOccurrences(of: "{pitch}", with: pitch)
                req.httpBody = tpl.data(using: .utf8)
            }
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...399).contains(http.statusCode) {
            throw FetchError.http(http.statusCode)
        }
        guard !data.isEmpty else { throw FetchError.empty }
        return try await decodeAudioResponse(data, engine: engine)
    }

    nonisolated private static func decodeAudioResponse(_ data: Data, engine: CustomTTSEngine) async throws -> Data {
        let type = engine.responseType.lowercased()
        if type == "audio" || type.isEmpty { return data }

        guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            return data
        }
        let path = engine.responsePath.trimmingCharacters(in: .whitespaces)
        let raw: String
        if path.isEmpty {
            raw = JSONQuery.evalString(path: "$..audio", jsonText: String(data: data, encoding: .utf8) ?? "").first ?? ""
        } else {
            raw = JSONQuery.evalString(path: path, jsonText: String(data: data, encoding: .utf8) ?? "").first ?? ""
        }

        if type == "base64" {
            var b64 = raw
            if let comma = b64.range(of: "base64,") {
                b64 = String(b64[comma.upperBound...])
            }
            if let d = Data(base64Encoded: b64) { return d }
            return data
        }

        // type == url
        guard !raw.isEmpty, let u = URL(string: raw) else { return data }
        if u.scheme == "data" {
            if let comma = raw.range(of: "base64,"), let d = Data(base64Encoded: String(raw[comma.upperBound...])) {
                return d
            }
            return data
        }
        let (d, _) = try await URLSession.shared.data(from: u)
        guard !d.isEmpty else { throw FetchError.empty }
        return d
    }

    nonisolated private static func jsonEscape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - 控制

    func pause() {
        if let p = player, p.isPlaying {
            p.pause()
            isPaused = true
            isSpeaking = false
            refreshNowPlaying()
            return
        }
        guard synth.isSpeaking, !synth.isPaused else { return }
        synth.pauseSpeaking(at: .word)
        isPaused = true
        isSpeaking = false
        refreshNowPlaying()
    }

    func resume() {
        if let p = player, !p.isPlaying {
            p.play()
            isPaused = false
            isSpeaking = true
            refreshNowPlaying()
            return
        }
        guard synth.isPaused else { return }
        synth.continueSpeaking()
        isPaused = false
        isSpeaking = true
        refreshNowPlaying()
    }

    /// 下一段 / 上一段（听书界面用）
    func skipChunk(_ delta: Int) {
        guard !chunks.isEmpty else { return }
        let target = min(max(chunkIndex + delta, 0), chunks.count - 1)
        guard target != chunkIndex else { return }
        session += 1
        let token = session
        stopPlayback(keepSession: true)
        isSpeaking = true
        isPaused = false
        if customEngine != nil {
            playCustom(at: target, token: token)
        } else {
            playSystem(at: target)
        }
    }

    func stop() {
        session += 1
        stopPlayback(keepSession: false)
        chunks = []
        chunkIndex = 0
        chunkTotal = 0
        spokenRange = nil
        currentChunkText = ""
        cancelSleepTimer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func stopPlayback(keepSession: Bool) {
        playTask?.cancel()
        playTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetched.removeAll()
        player?.stop()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        isSpeaking = false
        isPaused = false
        if !keepSession { spokenRange = nil }
    }

    private func finishAll() {
        isSpeaking = false
        isPaused = false
        spokenRange = nil
        chunkIndex = chunkTotal
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        onSegmentFinished?()
    }

    // MARK: - 定时停止

    func startSleepTimer(minutes: Int) {
        sleepTask?.cancel()
        sleepTask = nil
        guard minutes > 0 else {
            sleepRemaining = 0
            return
        }
        let total = minutes * 60
        sleepRemaining = total
        sleepTask = Task { [weak self] in
            var left = total
            while left > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                left -= 1
                await MainActor.run { self?.sleepRemaining = left }
            }
            await MainActor.run { self?.stop() }
        }
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepRemaining = 0
    }

    // MARK: - 音频会话 / 锁屏

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio,
                                 options: [.duckOthers, .allowBluetooth, .allowBluetoothA2DP])
        try? session.setActive(true)
    }

    private func refreshNowPlaying() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = currentChunkText.isEmpty ? "清阅朗读" : String(currentChunkText.prefix(40))
        info[MPMediaItemPropertyArtist] = contextSubtitle.isEmpty ? contextTitle : "\(contextTitle) · \(contextSubtitle)"
        info[MPMediaItemPropertyAlbumTitle] = "清阅"
        info[MPNowPlayingInfoPropertyPlaybackRate] = isSpeaking ? 1.0 : 0.0
        if chunkTotal > 0 {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(chunkIndex)
            info[MPMediaItemPropertyPlaybackDuration] = Double(chunkTotal)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteIfNeeded() {
        guard !remoteConfigured else { return }
        remoteConfigured = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.removeTarget(nil)
        c.pauseCommand.removeTarget(nil)
        c.togglePlayPauseCommand.removeTarget(nil)
        c.nextTrackCommand.removeTarget(nil)
        c.previousTrackCommand.removeTarget(nil)

        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isSpeaking { self.pause() } else { self.resume() }
            }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipChunk(1) }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipChunk(-1) }
            return .success
        }
    }
}

// MARK: - 系统 TTS 回调

extension TTSEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = true
            self.isPaused = false
            self.refreshNowPlaying()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPaused = true
            self.isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isPaused = false
            self.isSpeaking = true
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.isPaused = false
            self.spokenRange = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.customEngine == nil else { return }
            if let t = self.utteranceTokens[key], t != self.session { return }
            self.utteranceTokens.removeValue(forKey: key)
            let next = self.chunkIndex + 1
            if next < self.chunks.count {
                self.playSystem(at: next)
            } else {
                self.finishAll()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.chunks.indices.contains(self.chunkIndex) else { return }
            let base = self.chunks[self.chunkIndex].location
            self.spokenRange = NSRange(location: base + characterRange.location,
                                       length: characterRange.length)
        }
    }
}

// MARK: - 自定义引擎播放回调

extension TTSEngine: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.player = nil
            self.spokenRange = nil
            let token = self.session
            self.advanceCustom(token: token)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.player = nil
            self.advanceCustom(token: self.session)
        }
    }
}
