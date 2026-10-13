import AVFoundation
import Speech

/// Push-to-talk transcription using Apple's speech recognizer (on-device when
/// available). Call `start()` when the hotkey goes down and `stop()` when it
/// is released; `stop()` returns the final transcript.
@MainActor
final class SpeechRecognizer {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var latestTranscript = ""
    private var finished: CheckedContinuation<String, Never>?

    var onLevel: ((Float) -> Void)?
    var onPartial: ((String) -> Void)?

    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        return speech && mic
    }

    func start() throws {
        cancel()
        latestTranscript = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        request.addsPunctuation = true
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.rms(buffer)
            Task { @MainActor in self?.onLevel?(level) }
        }

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.latestTranscript = result.bestTranscription.formattedString
                    self.onPartial?(self.latestTranscript)
                    if result.isFinal { self.finish() }
                }
                if error != nil { self.finish() }
            }
        }

        engine.prepare()
        try engine.start()
    }

    /// Stops recording and waits (briefly) for the final transcript.
    func stop() async -> String {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        onLevel?(0)
        return await withCheckedContinuation { cont in
            finished = cont
            // Don't wait forever if the recognizer never sends a final result.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.finish()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        request = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
    }

    private func finish() {
        guard let cont = finished else { return }
        finished = nil
        task = nil
        request = nil
        cont.resume(returning: latestTranscript)
    }

    private nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return min(1, sqrt(sum / Float(n)) * 8)
    }
}
