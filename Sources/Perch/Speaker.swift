import AVFoundation
import FluidAudio

/// Local Kokoro text-to-speech: natural voices on the Neural Engine.
actor Kokoro {
    static let shared = Kokoro()
    private var manager: KokoroAneManager?
    private var loading: Task<Void, Error>?

    static let voices: [(id: String, name: String)] = [
        ("af_heart", "Heart (warm)"), ("af_bella", "Bella (bright)"), ("af_nicole", "Nicole (soft)"),
        ("af_sarah", "Sarah (calm)"), ("bf_emma", "Emma (British)"), ("am_michael", "Michael"),
    ]

    func prepare() async throws {
        if manager != nil { return }
        if let loading { try await loading.value; return }
        let t = Task {
            let m = KokoroAneManager(version: .v3)
            try await m.initialize()
            manager = m
        }
        loading = t
        defer { loading = nil }
        try await t.value
    }

    func synthesize(_ text: String, voice: String) async throws -> Data {
        try await prepare()
        guard let manager else { throw CancellationError() }
        return try await manager.synthesize(text: text, voice: voice)
    }
}

/// Speaks replies with either a built-in macOS voice or OpenAI's TTS.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var done: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synth.delegate = self
    }

    static let openAIVoices = ["alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse"]

    func speak(_ text: String) async {
        stop()
        let settings = AppSettings.shared
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        switch settings.voiceEngine {
        case .off:
            return
        case .kokoro:
            _ = await speakKokoro(clean, voice: settings.kokoroVoice)
        }
    }

    func stop() {
        generation += 1
        synth.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        resume()
    }

    private func speakSystem(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        let id = AppSettings.shared.systemVoiceID
        utterance.voice = id.isEmpty ? AVSpeechSynthesisVoice(language: Locale.current.identifier) : AVSpeechSynthesisVoice(identifier: id)
        utterance.rate = 0.52
        await withCheckedContinuation { cont in
            done = cont
            synth.speak(utterance)
        }
    }

    /// Speaks sentence by sentence: the next one renders while the current one plays.
    private func speakKokoro(_ text: String, voice: String) async -> Bool {
        let sentences = Self.sentences(text)
        guard !sentences.isEmpty else { return true }
        generation += 1
        let gen = generation
        var next: Task<Data?, Never>? = Task { try? await Kokoro.shared.synthesize(sentences[0], voice: voice) }
        for i in sentences.indices {
            guard let data = await next?.value, gen == generation else { return i > 0 }
            next = i + 1 < sentences.count
                ? Task { [s = sentences[i + 1]] in try? await Kokoro.shared.synthesize(s, voice: voice) } : nil
            guard let player = try? AVAudioPlayer(data: data) else { return false }
            self.player = player
            player.delegate = self
            await withCheckedContinuation { cont in
                done = cont
                player.play()
            }
            if gen != generation { return true }
        }
        return true
    }

    private var generation = 0

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { out.append(s) }
        }
        // Merge very short bits so the voice doesn't sound choppy.
        var merged: [String] = []
        for s in out {
            if let last = merged.last, last.count < 40 { merged[merged.count - 1] = last + " " + s } else { merged.append(s) }
        }
        return merged
    }

    static func warmUp() {
        guard AppSettings.shared.voiceEngine == .kokoro else { return }
        Task.detached(priority: .utility) { try? await Kokoro.shared.prepare() }
    }

    private func speakOpenAI(_ text: String, key: String, voice: String) async -> Bool {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "gpt-4o-mini-tts",
            "voice": voice,
            "input": text,
            "response_format": "mp3",
            "instructions": "Speak like a warm, upbeat friend sitting next to the user. Natural pace.",
        ])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let player = try? AVAudioPlayer(data: data) else { return false }
        self.player = player
        player.delegate = self
        await withCheckedContinuation { cont in
            done = cont
            player.play()
        }
        return true
    }

    private func resume() {
        let c = done
        done = nil
        c?.resume()
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.resume() }
    }
}
