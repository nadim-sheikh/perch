import Foundation
import Security
import SwiftUI

/// The model Perch uses for everything: talking, showing on screen, helpers and fixing text.
/// It runs on the current provider (see AIProvider) and is switchable in Settings → AI Models.
enum PerchModel {
    struct Choice: Identifiable, Hashable {
        let id: String
        let name: String
        let note: String
    }

    static var choices: [Choice] { AIProvider.current.choices }
    static var defaultID: String { AIProvider.current.defaultModel }

    static var id: String {
        let saved = UserDefaults.standard.string(forKey: AIProvider.current.modelDefaultsKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return saved.isEmpty ? defaultID : saved
    }

    static var name: String { choices.first { $0.id == id }?.name ?? id }

    /// Models that always think before answering. For these we ask for the shortest thinking;
    /// for everything else we send nothing, since asking would switch thinking *on* and slow it down.
    static func mandatoryReasoning(_ model: String) -> Bool {
        model.hasPrefix("z-ai/glm")
    }

    /// Gemini also always thinks, but accepts "minimal", which is the quickest setting it allows.
    static func thinksByDefault(_ model: String) -> Bool {
        model.hasPrefix("google/gemini")
    }

    /// The reasoning setting to send for a model, or nil to leave it alone.
    static func reasoningParam(_ model: String, effort: String = "low") -> [String: Any]? {
        if mandatoryReasoning(model) { return ["effort": effort] }
        if thinksByDefault(model) { return ["effort": "minimal"] }
        return nil
    }
}

enum VoiceEngine: String, CaseIterable, Identifiable {
    case kokoro
    case elevenlabs
    case off
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .kokoro: return "Natural voice (on-device)"
        case .elevenlabs: return "ElevenLabs (your key)"
        case .off: return "Don't speak"
        }
    }

    /// The voices this build offers. ElevenLabs uses its own key, so it's only in the standard build.
    static var available: [VoiceEngine] {
        #if PERCH_OPENROUTER
        return [.kokoro, .off]
        #else
        return [.kokoro, .elevenlabs, .off]
        #endif
    }
}

/// Stores secrets in the macOS Keychain, scoped to this app.
enum Keychain {
    static let service = "dev.perch.keys"
    static let legacyService = "dev.openbuddy.keys"

    static func get(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// User preferences. Non-secret values live in UserDefaults; API keys in Keychain.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("voiceEngine") var voiceEngineRaw: String = VoiceEngine.kokoro.rawValue
    @AppStorage("kokoroVoice") var kokoroVoice: String = "af_heart"
    @AppStorage("elevenlabsVoice") var elevenlabsVoice: String = ElevenLabs.voices[0].id
    @AppStorage("cursorColorHex") var cursorColorHex: String = "#3B82F6"
    @AppStorage("buddyName") var buddyName: String = "Perch"
    @AppStorage("followCursor") var followCursor: Bool = true

    /// Pasted keys often carry a trailing space or newline, which makes every request fail with 401.
    @Published var openrouterKey: String = Keychain.get("openrouter").trimmingCharacters(in: .whitespacesAndNewlines) {
        didSet {
            let trimmed = openrouterKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != openrouterKey { openrouterKey = trimmed }
            Keychain.set(openrouterKey, for: "openrouter")
            if openrouterKey != oldValue { Task { @MainActor in KeyCheck.shared.reset() } }
        }
    }

    @Published var anthropicKey: String = Keychain.get("anthropic") { didSet { store(&anthropicKey, oldValue, "anthropic") } }
    @Published var openaiKey: String = Keychain.get("openai") { didSet { store(&openaiKey, oldValue, "openai") } }
    @Published var xaiKey: String = Keychain.get("xai") { didSet { store(&xaiKey, oldValue, "xai") } }
    @Published var elevenlabsKey: String = Keychain.get("elevenlabs") { didSet { store(&elevenlabsKey, oldValue, "elevenlabs") } }

    /// Trims a pasted key, saves it, and re-checks it if it changed.
    private func store(_ value: inout String, _ old: String, _ account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != value { value = trimmed }
        Keychain.set(trimmed, for: account)
        if trimmed != old { Task { @MainActor in KeyCheck.shared.reset() } }
    }

    func key(for provider: AIProvider) -> String {
        switch provider {
        case .openrouter: return openrouterKey
        case .anthropic: return anthropicKey
        case .openai: return openaiKey
        case .xai: return xaiKey
        }
    }

    /// The key for the provider Perch uses now.
    var activeKey: String { key(for: AIProvider.current) }

    var voiceEngine: VoiceEngine {
        get { VoiceEngine(rawValue: voiceEngineRaw).flatMap { VoiceEngine.available.contains($0) ? $0 : nil } ?? .kokoro }
        set { voiceEngineRaw = newValue.rawValue }
    }

    var cursorColor: Color { Color(hex: cursorColorHex) ?? .blue }

    var hasKey: Bool { !activeKey.isEmpty }
}

/// Asks the current provider whether the saved key works, so Settings can say so honestly.
@MainActor
final class KeyCheck: ObservableObject {
    static let shared = KeyCheck()

    enum State: Equatable { case unchecked, checking, valid, invalid, unreachable(String) }

    @Published private(set) var state: State = .unchecked
    private var generation = 0

    func reset() {
        generation += 1
        state = .unchecked
    }

    func check() {
        let provider = AIProvider.current
        let key = AppSettings.shared.key(for: provider)
        generation += 1
        let gen = generation
        guard !key.isEmpty else { state = .unchecked; return }
        state = .checking
        let req = provider.keyCheckRequest(key: key)
        Task {
            let result: State
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch code {
                case 200..<300: result = .valid
                case 401, 403: result = .invalid
                default: result = .unreachable("\(provider.title) answered HTTP \(code).")
                }
            } catch {
                result = .unreachable(error.localizedDescription)
            }
            // A newer key or check replaced this one.
            guard gen == generation else { return }
            state = result
        }
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}
