import Foundation

/// Where Perch's model runs. Every provider here speaks the OpenAI chat-completions format
/// (Anthropic through its OpenAI-compatible endpoint), so requests differ only in URL, key and a few fields.
///
/// The standard build offers Anthropic, OpenAI and xAI with the user's own key. A build made with
/// `PERCH_OPENROUTER` (see build.sh) uses OpenRouter instead.
enum AIProvider: String, CaseIterable, Identifiable {
    case openrouter, anthropic, openai, xai

    var id: String { rawValue }

    /// The providers this build offers, in the order Settings lists them.
    static var available: [AIProvider] {
        #if PERCH_OPENROUTER
        return [.openrouter]
        #else
        return [.anthropic, .openai, .xai]
        #endif
    }

    static var current: AIProvider {
        let saved = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "")
        return saved.flatMap { available.contains($0) ? $0 : nil } ?? available[0]
    }

    var title: String {
        switch self {
        case .openrouter: return "OpenRouter"
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .xai: return "xAI (Grok)"
        }
    }

    /// Keychain account holding this provider's key.
    var keyAccount: String { rawValue }

    var keyPlaceholder: String {
        switch self {
        case .openrouter: return "sk-or-…"
        case .anthropic: return "sk-ant-…"
        case .openai: return "sk-…"
        case .xai: return "xai-…"
        }
    }

    var keysPage: URL {
        switch self {
        case .openrouter: return URL(string: "https://openrouter.ai/keys")!
        case .anthropic: return URL(string: "https://platform.claude.com/settings/keys")!
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .xai: return URL(string: "https://console.x.ai")!
        }
    }

    var chatURL: URL {
        switch self {
        case .openrouter: return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/chat/completions")!
        case .openai: return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .xai: return URL(string: "https://api.x.ai/v1/chat/completions")!
        }
    }

    /// Fast models that can see screenshots and use tools. Users can also type any model id.
    var choices: [PerchModel.Choice] {
        switch self {
        case .openrouter: return [
            .init(id: "z-ai/glm-5.3-flash", name: "GLM 5.3 Flash", note: "Fastest and cheapest (about 2.5s to speak)."),
            .init(id: "google/gemini-3.5-flash-lite", name: "Gemini 3.5 Flash Lite", note: "Light, but often slow to start (5s+)."),
            .init(id: "google/gemini-3.8-flash", name: "Gemini 3.8 Flash", note: "Smart, steady (about 4.5s)."),
            .init(id: "anthropic/claude-haiku-5.5", name: "Claude Haiku 5.5", note: "Good at pointing (about 4s)."),
            .init(id: "openai/gpt-5.6-luna", name: "GPT-5.6 Luna", note: "Affordable (about 4.5s)."),
        ]
        case .anthropic: return [
            .init(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", note: "Fastest Claude. Good at pointing."),
            .init(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", note: "Smarter helpers, a little slower."),
        ]
        case .openai: return [
            .init(id: "gpt-6-luna", name: "GPT-6 Luna", note: "Fast and affordable."),
            .init(id: "gpt-6.1-sol", name: "GPT-6.1 Sol", note: "Smarter helpers, a little slower."),
        ]
        case .xai: return [
            .init(id: "grok-4.3", name: "Grok 4.3", note: "Fast and affordable."),
            .init(id: "grok-4.7", name: "Grok 4.7", note: "Newest and smartest."),
        ]
        }
    }

    var defaultModel: String { choices[0].id }

    /// UserDefaults key for the chosen model. OpenRouter keeps the original key so existing choices survive.
    var modelDefaultsKey: String { self == .openrouter ? "perchModel" : "perchModel.\(rawValue)" }

    /// Builds a streaming chat request. `usage` asks OpenRouter to report cost (helpers show it).
    func chatRequest(key: String, model: String, messages: [[String: Any]], tools: [[String: Any]] = [],
                     maxTokens: Int, quick: Bool, usage: Bool = false) throws -> URLRequest {
        var body: [String: Any] = ["model": model, "messages": messages, "stream": true]
        if !tools.isEmpty { body["tools"] = tools }
        switch self {
        case .openrouter:
            body["max_tokens"] = maxTokens
            // Route to whichever provider answers first.
            body["provider"] = ["sort": "latency"]
            if usage { body["usage"] = ["include": true] }
            // GLM 5.3 Flash can't switch reasoning off ("minimal" is refused with a 400), so "low" is the fastest it allows.
            if quick, let r = PerchModel.reasoningParam(model) { body["reasoning"] = r }
        case .anthropic:
            body["max_tokens"] = maxTokens
            // Claude 5 thinks by default; replies on screen and helper steps are faster without it.
            if quick { body["thinking"] = ["type": "disabled"] }
        case .openai:
            // Newer OpenAI models only take max_completion_tokens.
            body["max_completion_tokens"] = maxTokens
            if quick, model.hasPrefix("gpt-5") || model.hasPrefix("gpt-6") || model.hasPrefix("o") {
                body["reasoning_effort"] = "low"
            }
        case .xai:
            body["max_tokens"] = maxTokens
        }
        var req = URLRequest(url: chatURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if self == .openrouter { req.setValue("Perch", forHTTPHeaderField: "X-Title") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120
        return req
    }

    /// A cheap authenticated request that only succeeds with a working key.
    func keyCheckRequest(key: String) -> URLRequest {
        let url: URL
        switch self {
        case .openrouter: url = URL(string: "https://openrouter.ai/api/v1/key")!
        case .anthropic: url = URL(string: "https://api.anthropic.com/v1/models?limit=1")!
        case .openai: url = URL(string: "https://api.openai.com/v1/models")!
        case .xai: url = URL(string: "https://api.x.ai/v1/models")!
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        if self == .anthropic {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return req
    }
}

/// Who made Perch, shown in Home, Settings and the menu bar menu.
enum Credits {
    static let developer = "Nadim Sheikh"
    static let twitter = URL(string: "https://x.com/Nadim_404")!
    static let handle = "@Nadim_404"
}

/// ElevenLabs with the user's own key: Scribe speech-to-text and natural cloud voices.
enum ElevenLabs {
    static let voices: [(id: String, name: String)] = [
        ("21m00Tcm4TlvDq8ikWAM", "Rachel (calm)"), ("EXAVITQu4vr4xnSDxMaL", "Sarah (soft)"),
        ("XrExE9yKIg1WjnnlVkGX", "Matilda (warm)"), ("nPczCjzI2devNBz1zQrb", "Brian (deep)"),
    ]
    static let ttsModel = "eleven_flash_v2_5"

    /// Speech for one phrase as MP3, or nil on any failure.
    static func speech(_ text: String, voice: String, speed: Double) async -> Data? {
        let key = AppSettings.shared.elevenlabsKey
        guard !key.isEmpty, let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice)?output_format=mp3_44100_128") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["text": text, "model_id": ttsModel,
                                   "voice_settings": ["stability": 0.5, "similarity_boost": 0.75, "speed": min(1.2, max(0.7, speed))]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            DebugLog.write("elevenlabs tts: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
            return nil
        }
        return data
    }

    /// Scribe v2 transcription of a WAV recording, or nil on any failure.
    static func transcribe(wav: Data) async -> String? {
        let key = AppSettings.shared.elevenlabsKey
        guard !key.isEmpty else { return nil }
        let boundary = "perch-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model_id", "scribe_v2")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            DebugLog.write("elevenlabs stt: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
