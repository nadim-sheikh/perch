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

    func synthesize(_ text: String, voice: String, speed: Float) async throws -> Data {
        try await prepare()
        guard let manager else { throw CancellationError() }
        return try await manager.synthesize(text: text, voice: voice, speed: speed)
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
        liveTask?.cancel()
        liveTask = nil
        liveQueue = []
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
        let sentences = Self.phrases(Self.speakable(text))
        guard !sentences.isEmpty else { return true }
        generation += 1
        let gen = generation
        let speed = Float(UserDefaults.standard.object(forKey: "voiceSpeed") as? Double ?? 0.97)
        var next: Task<Data?, Never>? = Task { try? await Kokoro.shared.synthesize(sentences[0], voice: voice, speed: speed) }
        for i in sentences.indices {
            guard let data = await next?.value, gen == generation else { return i > 0 }
            next = i + 1 < sentences.count
                ? Task { [s = sentences[i + 1]] in try? await Kokoro.shared.synthesize(s, voice: voice, speed: speed) } : nil
            guard let player = try? AVAudioPlayer(data: data) else { return false }
            self.player = player
            player.delegate = self
            await withCheckedContinuation { cont in
                done = cont
                player.play()
            }
            if gen != generation { return true }
            // A natural breath between sentences: a touch longer after questions and exclamations.
            if i + 1 < sentences.count {
                let end = sentences[i].last
                let pause: UInt64 = end == "?" || end == "!" ? 420 : end == "," ? 180 : 320
                try? await Task.sleep(nanoseconds: pause * 1_000_000)
                if gen != generation { return true }
            }
        }
        return true
    }

    /// Cleans text so it sounds natural when read aloud.
    static func speakable(_ text: String) -> String {
        var t = text
        let swaps: [(String, String)] = [
            ("—", ", "), ("–", ", "), (" - ", ", "), ("…", "..."), ("&", " and "), ("e.g.", "for example"),
            ("i.e.", "that is"), ("etc.", "and so on"), ("**", ""), ("__", ""), ("`", ""), ("#", ""), ("•", ""),
        ]
        for (a, b) in swaps { t = t.replacingOccurrences(of: a, with: b) }
        // Drop emoji and other symbols the voice would stumble on.
        t = String(t.unicodeScalars.filter { !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000)) }.map(Character.init))
        return t.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var generation = 0

    // MARK: Live streaming speech

    private var liveQueue: [String] = []
    private var liveFinished = false
    private var liveTask: Task<Void, Never>?

    /// Starts a live session: phrases are spoken as soon as they're enqueued.
    func beginLive() {
        stop()
        liveQueue = []
        liveFinished = false
        let gen = generation
        let voice = AppSettings.shared.kokoroVoice
        let speed = Float(UserDefaults.standard.object(forKey: "voiceSpeed") as? Double ?? 0.97)
        liveTask = Task { [weak self] in
            var prefetched: (String, Task<Data?, Never>)?
            while let self, gen == self.generation {
                if self.liveQueue.isEmpty && prefetched == nil {
                    if self.liveFinished { break }
                    try? await Task.sleep(nanoseconds: 25_000_000)
                    continue
                }
                let current: (String, Task<Data?, Never>)
                if let p = prefetched { current = p; prefetched = nil } else {
                    let phrase = self.liveQueue.removeFirst()
                    current = (phrase, Task { try? await Kokoro.shared.synthesize(phrase, voice: voice, speed: speed) })
                }
                // Render the next phrase while this one plays.
                if !self.liveQueue.isEmpty {
                    let next = self.liveQueue.removeFirst()
                    prefetched = (next, Task { try? await Kokoro.shared.synthesize(next, voice: voice, speed: speed) })
                }
                guard let data = await current.1.value, gen == self.generation, let player = try? AVAudioPlayer(data: data) else { continue }
                self.player = player
                player.delegate = self
                await withCheckedContinuation { cont in
                    self.done = cont
                    player.play()
                }
                guard gen == self.generation else { break }
                let end = current.0.last
                let pause: UInt64 = end == "?" || end == "!" ? 300 : end == "." ? 220 : 90
                try? await Task.sleep(nanoseconds: pause * 1_000_000)
            }
        }
    }

    func enqueueLive(_ text: String) {
        guard AppSettings.shared.voiceEngine == .kokoro else { return }
        liveQueue.append(contentsOf: Self.phrases(Self.speakable(text)))
    }

    /// Waits until everything queued has been spoken.
    func finishLive() async {
        liveFinished = true
        await liveTask?.value
        liveTask = nil
    }

    /// Splits text into short phrases: sentences, and long sentences at commas.
    /// Short phrases keep the voice clear (no slurred words) and start sooner.
    static func phrases(_ text: String) -> [String] {
        var out: [String] = []
        for sentence in sentences(text) {
            let words = sentence.split(separator: " ")
            if words.count <= 14 { out.append(sentence); continue }
            var current = ""
            for part in sentence.split(separator: ",", omittingEmptySubsequences: false) {
                let piece = part.trimmingCharacters(in: .whitespaces)
                if piece.isEmpty { continue }
                if current.isEmpty { current = piece } else if current.split(separator: " ").count < 6 { current += ", " + piece } else {
                    out.append(current + ",")
                    current = piece
                }
            }
            if !current.isEmpty { out.append(current) }
        }
        return out
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { out.append(s) }
        }
        // Merge tiny fragments ("Oh!") into the next sentence so they don't sound clipped.
        var merged: [String] = []
        for s in out {
            if let last = merged.last, last.count < 12 { merged[merged.count - 1] = last + " " + s } else { merged.append(s) }
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
