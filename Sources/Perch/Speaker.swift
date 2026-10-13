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

/// Speaks replies with the local Kokoro voice, either all at once or live while a reply streams.
@MainActor
final class Speaker: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var done: CheckedContinuation<Void, Never>?

    func speak(_ text: String) async {
        stop()
        let settings = AppSettings.shared
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        switch settings.voiceEngine {
        case .off:
            return
        case .kokoro:
            await speakKokoro(clean, voice: settings.kokoroVoice)
        }
    }

    func stop() {
        generation += 1
        liveTask?.cancel()
        liveTask = nil
        liveQueue = []
        player?.stop()
        player = nil
        resume()
    }

    /// Speaks sentence by sentence: the next one renders while the current one plays.
    private func speakKokoro(_ text: String, voice: String) async {
        let sentences = Self.phrases(Self.speakable(text))
        guard !sentences.isEmpty else { return }
        generation += 1
        let gen = generation
        let speed = Float(UserDefaults.standard.object(forKey: "voiceSpeed") as? Double ?? 1.0)
        var next: Task<Data?, Never>? = Task { try? await Kokoro.shared.synthesize(sentences[0], voice: voice, speed: speed) }
        for i in sentences.indices {
            guard let data = await next?.value, gen == generation else { return }
            next = i + 1 < sentences.count
                ? Task { [s = sentences[i + 1]] in try? await Kokoro.shared.synthesize(s, voice: voice, speed: speed) } : nil
            guard let player = try? AVAudioPlayer(data: data) else { return }
            self.player = player
            player.delegate = self
            await withCheckedContinuation { cont in
                done = cont
                player.play()
            }
            if gen != generation { return }
            if i + 1 < sentences.count {
                try? await Task.sleep(nanoseconds: 140_000_000)
                if gen != generation { return }
            }
        }
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
        let speed = Float(UserDefaults.standard.object(forKey: "voiceSpeed") as? Double ?? 1.0)
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
                try? await Task.sleep(nanoseconds: 140_000_000)
            }
        }
    }

    func enqueueLive(_ text: String) {
        guard AppSettings.shared.voiceEngine == .kokoro else { return }
        // Each flush is already a smooth-sized chunk of whole sentences.
        let clean = Self.speakable(text)
        if !clean.isEmpty { liveQueue.append(clean) }
    }

    /// Waits until everything queued has been spoken.
    func finishLive() async {
        liveFinished = true
        await liveTask?.value
        liveTask = nil
    }

    /// Groups whole sentences into chunks of roughly 16+ words. The voice model renders
    /// longer clips with its higher-quality path (short clips sound slurred), and whole
    /// sentences keep natural intonation.
    static func phrases(_ text: String, minWords: Int = 16) -> [String] {
        var out: [String] = []
        var current = ""
        for sentence in sentences(text) {
            current = current.isEmpty ? sentence : current + " " + sentence
            if current.split(separator: " ").count >= minWords {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            if let last = out.last, current.split(separator: " ").count < 6 { out[out.count - 1] = last + " " + current } else { out.append(current) }
        }
        return out
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { out.append(s) }
        }
        return out
    }

    static func warmUp() {
        guard AppSettings.shared.voiceEngine == .kokoro else { return }
        Task.detached(priority: .utility) { try? await Kokoro.shared.prepare() }
    }

    private func resume() {
        let c = done
        done = nil
        c?.resume()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.resume() }
    }
}
