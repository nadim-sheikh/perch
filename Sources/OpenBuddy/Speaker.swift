import AVFoundation

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
        case .openai where !settings.openaiKey.isEmpty:
            if await speakOpenAI(clean, key: settings.openaiKey, voice: settings.openaiVoice) { return }
            await speakSystem(clean)
        default:
            await speakSystem(clean)
        }
    }

    func stop() {
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
