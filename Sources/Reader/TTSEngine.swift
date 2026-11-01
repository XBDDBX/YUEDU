import Foundation
import AVFoundation
import Combine

@MainActor
final class TTSEngine: NSObject, ObservableObject {
    static let shared = TTSEngine()

    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var spokenRange: NSRange?
    @Published private(set) var currentVoiceName: String = ""

    private lazy var synth: AVSpeechSynthesizer = {
        let s = AVSpeechSynthesizer()
        s.delegate = self
        return s
    }()
    private var pendingText: String = ""

    /// 自定义引擎播放器
    private var player: AVAudioPlayer?

    /// 一段播完后回调（用于自动翻页）
    var onSegmentFinished: (@MainActor () -> Void)?

    var availableVoices: [(id: String, name: String, lang: String)] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") || $0.language.hasPrefix("en") }
            .map { (id: $0.identifier, name: "\($0.name) (\($0.language))", lang: $0.language) }
    }

    func speak(_ text: String, settings: ReaderSettings) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        // 自定义朗读引擎
        if let engine = settings.customTTS.first(where: { $0.id == settings.ttsEngineID }) {
            playCustom(engine, text: clean, settings: settings)
            return
        }

        if synth.isPaused {
            synth.continueSpeaking()
            isPaused = false
            isSpeaking = true
            return
        }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .allowBluetooth])
        try? session.setActive(true)

        pendingText = clean
        let utt = AVSpeechUtterance(string: clean)
        if let v = AVSpeechSynthesisVoice(identifier: settings.ttsVoiceID) {
            utt.voice = v
        } else {
            utt.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }
        utt.rate = Float(settings.ttsRate)
        utt.pitchMultiplier = Float(settings.ttsPitch)
        utt.preUtteranceDelay = 0.05

        currentVoiceName = utt.voice?.name ?? "系统语音"
        isSpeaking = true
        isPaused = false
        spokenRange = nil
        synth.speak(utt)
    }

    // MARK: - 自定义引擎

    private func playCustom(_ engine: CustomTTSEngine, text: String, settings: ReaderSettings) {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        player?.stop()
        player = nil

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .allowBluetooth])
        try? session.setActive(true)

        currentVoiceName = engine.name
        isSpeaking = true
        isPaused = false
        spokenRange = nil

        let encodedText = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        let encodedVoice = engine.voice.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? engine.voice
        let urlString = engine.url
            .replacingOccurrences(of: "{text}", with: encodedText)
            .replacingOccurrences(of: "{voice}", with: encodedVoice)
        guard let url = URL(string: urlString) else {
            isSpeaking = false
            return
        }

        var req = URLRequest(url: url)
        if engine.method == "POST" {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["text": text, "voice": engine.voice, "rate": Float(settings.ttsRate)]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        req.timeoutInterval = 30

        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self else { return }
            guard let data, err == nil, !data.isEmpty else {
                Task { @MainActor in self.isSpeaking = false }
                return
            }
            DispatchQueue.main.async {
                self.player = try? AVAudioPlayer(data: data)
                guard let player = self.player else {
                    self.isSpeaking = false
                    return
                }
                player.delegate = self
                player.play()
            }
        }.resume()
    }

    /// 自定义引擎是否在播
    var isPlayingCustom: Bool { player?.isPlaying ?? false }

    func pause() {
        if let p = player, p.isPlaying {
            p.pause()
            isPaused = true
            isSpeaking = false
            return
        }
        guard synth.isSpeaking, !synth.isPaused else { return }
        synth.pauseSpeaking(at: .word)
        isPaused = true
        isSpeaking = false
    }

    func resume() {
        if player?.isPlaying == false, isPaused {
            player?.play()
            isPaused = false
            isSpeaking = true
            return
        }
        guard synth.isPaused else { return }
        synth.continueSpeaking()
        isPaused = false
        isSpeaking = true
    }

    func stop() {
        player?.stop()
        player = nil
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
        isPaused = false
        spokenRange = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension TTSEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = true
            self.isPaused = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isPaused = true; self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isPaused = false; self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false; self.isPaused = false; self.spokenRange = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.isPaused = false
            self.spokenRange = nil
            self.onSegmentFinished?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.spokenRange = characterRange
        }
    }
}

extension TTSEngine: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === player {
                self.player = nil
                self.isSpeaking = false
                self.isPaused = false
                self.spokenRange = nil
                self.onSegmentFinished?()
            }
        }
    }
}
