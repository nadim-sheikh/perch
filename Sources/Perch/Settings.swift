import Foundation
import Security
import SwiftUI

enum LLMProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openai
    case openrouter
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .anthropic: return "Claude (Anthropic)"
        case .openai: return "OpenAI"
        case .openrouter: return "OpenRouter (any model)"
        }
    }
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-5-5"
        case .openai: return "gpt-4o"
        case .openrouter: return "anthropic/claude-sonnet-5.5"
        }
    }
}

enum VoiceEngine: String, CaseIterable, Identifiable {
    case kokoro
    case off
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .kokoro: return "Natural voice (on-device)"
        case .off: return "Don't speak"
        }
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

    @AppStorage("provider") var providerRaw: String = LLMProvider.anthropic.rawValue
    @AppStorage("anthropicModel") var anthropicModel: String = LLMProvider.anthropic.defaultModel
    @AppStorage("openaiModel") var openaiModel: String = LLMProvider.openai.defaultModel
    @AppStorage("openrouterModel") var openrouterModel: String = LLMProvider.openrouter.defaultModel
    @AppStorage("voiceEngine") var voiceEngineRaw: String = VoiceEngine.kokoro.rawValue
    @AppStorage("kokoroVoice") var kokoroVoice: String = "af_heart"
    @AppStorage("openaiVoice") var openaiVoice: String = "alloy"
    @AppStorage("systemVoiceID") var systemVoiceID: String = ""
    @AppStorage("cursorColorHex") var cursorColorHex: String = "#3B82F6"
    @AppStorage("buddyName") var buddyName: String = "Perch"
    @AppStorage("followCursor") var followCursor: Bool = true

    @Published var anthropicKey: String = Keychain.get("anthropic") {
        didSet { Keychain.set(anthropicKey, for: "anthropic") }
    }
    @Published var openaiKey: String = Keychain.get("openai") {
        didSet { Keychain.set(openaiKey, for: "openai") }
    }
    @Published var openrouterKey: String = Keychain.get("openrouter") {
        didSet { Keychain.set(openrouterKey, for: "openrouter") }
    }

    var provider: LLMProvider {
        get { LLMProvider(rawValue: providerRaw) ?? .anthropic }
        set { providerRaw = newValue.rawValue }
    }

    var voiceEngine: VoiceEngine {
        get { VoiceEngine(rawValue: voiceEngineRaw) ?? .kokoro }
        set { voiceEngineRaw = newValue.rawValue }
    }

    var cursorColor: Color { Color(hex: cursorColorHex) ?? .blue }

    /// "Quick replies" uses a faster model for the buddy's spoken answers.
    var replyModel: String {
        guard UserDefaults.standard.object(forKey: "quickReplies") as? Bool ?? true else { return activeModel }
        switch provider {
        case .anthropic: return "claude-haiku-5-5"
        case .openrouter: return "anthropic/claude-haiku-5.5"
        case .openai: return "gpt-4o-mini"
        }
    }

    var activeModel: String {
        switch provider {
        case .anthropic: return anthropicModel
        case .openai: return openaiModel
        case .openrouter: return openrouterModel
        }
    }

    var hasAnyKey: Bool { !anthropicKey.isEmpty || !openaiKey.isEmpty || !openrouterKey.isEmpty }

    var activeKey: String {
        switch provider {
        case .anthropic: return anthropicKey
        case .openai: return openaiKey
        case .openrouter: return openrouterKey
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
