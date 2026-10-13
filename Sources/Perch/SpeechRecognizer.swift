import AVFoundation
import CoreAudio
import FluidAudio
import Speech

enum SpeechEngine: String, CaseIterable, Identifiable {
    case parakeet, scribe
    var id: String { rawValue }
    var title: String { self == .parakeet ? "Parakeet (on-device)" : "ElevenLabs Scribe" }
}

/// ElevenLabs Scribe v2. The standard build calls ElevenLabs with the user's ElevenLabs key; an
/// OpenRouter build goes through OpenRouter's transcription endpoint with the OpenRouter key.
enum CloudTranscriber {
    static let model = "elevenlabs/scribe-v2"

    static var hasKey: Bool {
        #if PERCH_OPENROUTER
        return !AppSettings.shared.openrouterKey.isEmpty
        #else
        return !AppSettings.shared.elevenlabsKey.isEmpty
        #endif
    }

    static var host: URL {
        #if PERCH_OPENROUTER
        return AIProvider.openrouter.chatURL
        #else
        return URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
        #endif
    }

    static var settingsNote: String {
        #if PERCH_OPENROUTER
        return "ElevenLabs Scribe v2 through your OpenRouter key. Most accurate, about $0.11 per hour of talking."
        #else
        return hasKey ? "ElevenLabs Scribe v2 with your ElevenLabs key. Most accurate."
                      : "ElevenLabs Scribe v2. Add your ElevenLabs key in Settings → Voice first."
        #endif
    }

    /// Returns nil on any failure so the caller can fall back to on-device speech.
    static func transcribe(_ samples: [Float]) async -> String? {
        let samples = trimSilence(samples)
        guard samples.count > 8_000 else { return nil }
        let started = Date()
        let text = await send(samples)
        if text != nil {
            DebugLog.write(String(format: "scribe: %.1fs of speech, text back in %.2fs",
                                  Double(samples.count) / 16_000, Date().timeIntervalSince(started)))
        }
        return text
    }

    #if !PERCH_OPENROUTER
    private static func send(_ samples: [Float]) async -> String? {
        await ElevenLabs.transcribe(wav: wav(samples))
    }
    #else
    private static func send(_ samples: [Float]) async -> String? {
        let key = await AppSettings.shared.openrouterKey
        guard !key.isEmpty else { return nil }
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "input_audio": ["data": wav(samples).base64EncodedString(), "format": "wav"],
            "provider": ["sort": "latency"],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                DebugLog.write("scribe: HTTP \(status) \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
                return nil
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            DebugLog.write("scribe: \(error.localizedDescription)")
            return nil
        }
    }
    #endif

    /// Drops the quiet before and after speaking (keeping a short pad): less to upload and transcribe.
    private static func trimSilence(_ samples: [Float]) -> [Float] {
        let frame = 320, pad = 4_000  // 20 ms frames, 0.25 s pad at 16 kHz
        let loud: (Int) -> Bool = { start in
            let end = min(start + frame, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            return sqrt(sum / Float(max(1, end - start))) > 0.006
        }
        let frames = stride(from: 0, to: samples.count, by: frame)
        guard let first = frames.first(where: loud), let last = frames.reversed().first(where: loud) else { return samples }
        return Array(samples[max(0, first - pad)..<min(samples.count, last + frame + pad)])
    }

    /// 16 kHz mono 16-bit PCM WAV.
    private static func wav(_ samples: [Float]) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            var v = Int16(max(-1, min(1, s)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        var d = Data()
        func u32(_ x: UInt32) { var v = x.littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        func u16(_ x: UInt16) { var v = x.littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(16_000); u32(32_000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}

/// The microphone Perch listens with: the one picked in Settings → Microphone, or the system default.
enum MicrophoneChoice {
    static let defaultsKey = "micDeviceUID"

    struct Device: Identifiable, Hashable { let id: String; let name: String }

    static var devices: [Device] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    static var systemDefaultName: String { AVCaptureDevice.default(for: .audio)?.localizedName ?? "None" }

    /// Points the engine's input at the chosen microphone, or back at the system default when none is
    /// chosen or the chosen one is unplugged. Call while the engine is stopped.
    static func apply(to engine: AVAudioEngine) {
        let uid = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        guard var device = (uid.isEmpty ? nil : deviceID(uid: uid)) ?? defaultInput(),
              let unit = engine.inputNode.audioUnit else { return }
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &device, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    private static func deviceID(uid: String) -> AudioDeviceID? {
        var cfUID: CFString = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return status == noErr && id != 0 ? id : nil
    }

    private static func defaultInput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }
}

/// Loads and runs NVIDIA Parakeet locally on the Neural Engine.
actor Parakeet {
    static let shared = Parakeet()
    enum State: Equatable { case notLoaded, downloading(Double), ready, failed(String) }

    private var manager: AsrManager?
    private(set) var state: State = .notLoaded
    private var loading: Task<Void, Never>?

    var isReady: Bool { manager != nil }

    func load(onProgress: @escaping @Sendable (State) -> Void) async {
        if manager != nil { onProgress(.ready); return }
        if let loading { await loading.value; onProgress(state); return }
        let task = Task {
            do {
                state = .downloading(0)
                onProgress(state)
                let models = try await AsrModels.downloadAndLoad(version: .redux) { p in
                    onProgress(.downloading(p.fractionCompleted))
                }
                let m = AsrManager(config: .default)
                try await m.loadModels(models)
                manager = m
                state = .ready
            } catch {
                state = .failed(error.localizedDescription)
            }
            onProgress(state)
        }
        loading = task
        await task.value
        loading = nil
    }

    func transcribe(_ samples: [Float]) async -> String {
        guard let manager, samples.count > 8_000 else { return "" }
        var decoder = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return (try? await manager.transcribe(samples, decoderState: &decoder))?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Push-to-talk speech input. `start()` on key down, `stop()` on release returns the text.
/// Uses Scribe or Parakeet as chosen; Apple's recognizer only while Parakeet's model is still loading.
@MainActor
final class SpeechRecognizer {
    private let engine = AVAudioEngine()
    private var usingParakeet = false
    private var usingScribe = false

    // Parakeet path: 16 kHz mono samples
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var partialTask: Task<Void, Never>?

    // Apple path
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var latestTranscript = ""
    private var finished: CheckedContinuation<String, Never>?
    /// Bumped by `cancel()`, so a start that was waiting when it was cancelled never turns the mic on.
    private var generation = 0
    private var tapInstalled = false

    var onLevel: ((Float) -> Void)?
    var onPartial: ((String) -> Void)?

    static var preferredEngine: SpeechEngine {
        SpeechEngine(rawValue: UserDefaults.standard.string(forKey: "speechEngine") ?? "") ?? .parakeet
    }

    static func requestPermissions() async -> Bool {
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        return mic
    }

    /// Warm up Parakeet in the background so the first question is fast.
    static func preloadParakeet(onProgress: @escaping @Sendable (Parakeet.State) -> Void = { _ in }) {
        guard preferredEngine == .parakeet else { return }
        Task.detached(priority: .utility) { await Parakeet.shared.load(onProgress: onProgress) }
    }

    func start() async throws {
        cancel()
        let gen = generation
        let parakeetReady = await Parakeet.shared.isReady
        usingScribe = Self.preferredEngine == .scribe && CloudTranscriber.hasKey
        usingParakeet = usingScribe || (Self.preferredEngine == .parakeet && parakeetReady)
        if usingScribe { Warmup.connection(CloudTranscriber.host) }  // the upload then reuses an open connection
        guard gen == generation else { throw CancellationError() }
        MicrophoneChoice.apply(to: engine)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        tapInstalled = true

        if usingParakeet {
            samples.removeAll(keepingCapacity: true)
            let conv = AVAudioConverter(from: format, to: targetFormat)
            converter = conv
            let target = targetFormat
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                let level = Self.rms(buffer)
                let converted = conv.map { Self.convert(buffer, with: $0, to: target) } ?? []
                Task { @MainActor in
                    self?.samples.append(contentsOf: converted)
                    self?.onLevel?(level)
                }
            }
            // Scribe has no live words; show Parakeet's while talking if it is already loaded.
            if !usingScribe || parakeetReady { startPartials() }
        } else {
            latestTranscript = ""
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer?.supportsOnDeviceRecognition == true { request.requiresOnDeviceRecognition = true }
            request.addsPunctuation = true
            self.request = request
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
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            cancel()
            throw error
        }
    }

    func stop() async -> String {
        engine.stop()
        removeTap()
        onLevel?(0)
        if usingParakeet {
            partialTask?.cancel()
            let audio = samples
            samples.removeAll()
            if usingScribe, let text = await CloudTranscriber.transcribe(audio) { return text }
            return await Parakeet.shared.transcribe(audio)
        }
        request?.endAudio()
        return await withCheckedContinuation { cont in
            finished = cont
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.finish() }
        }
    }

    func cancel() {
        generation += 1
        partialTask?.cancel()
        task?.cancel()
        // A `stop()` still waiting for the final words gets what was heard so far.
        finish()
        task = nil
        request = nil
        if engine.isRunning { engine.stop() }
        removeTap()
    }

    private func removeTap() {
        guard tapInstalled else { return }
        tapInstalled = false
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Live words while talking: re-transcribe the growing clip about once a second.
    private func startPartials() {
        partialTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(900))
                guard let self, !Task.isCancelled else { return }
                let audio = self.samples
                guard audio.count > 12_000 else { continue }
                let text = await Parakeet.shared.transcribe(audio)
                if !Task.isCancelled, !text.isEmpty { self.onPartial?(text) }
            }
        }
    }

    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to targetFormat: AVAudioFormat) -> [Float] {
        let ratio = 16_000 / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard let ch = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
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
