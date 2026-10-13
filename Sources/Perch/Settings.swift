import Foundation
import Security
import SwiftUI

/// The one model Perch uses for everything: talking, acting on the screen, helpers, squads and
/// fixing text. It runs on the user's OpenRouter key and can see screenshots and call tools.
enum PerchModel {
    static let id = "z-ai/glm-5.3-flash"
    static let name = "GLM 5.3 Flash"
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

    @AppStorage("voiceEngine") var voiceEngineRaw: String = VoiceEngine.kokoro.rawValue
    @AppStorage("kokoroVoice") var kokoroVoice: String = "af_heart"
    @AppStorage("cursorColorHex") var cursorColorHex: String = "#3B82F6"
    @AppStorage("buddyName") var buddyName: String = "Perch"
    @AppStorage("followCursor") var followCursor: Bool = true

    /// Pasted keys often carry a trailing space or newline, which makes every request fail with 401.
    @Published var openrouterKey: String = Keychain.get("openrouter").trimmingCharacters(in: .whitespacesAndNewlines) {
        didSet {
            let trimmed = openrouterKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != openrouterKey { openrouterKey = trimmed }
            Keychain.set(openrouterKey, for: "openrouter")
            if openrouterKey != oldValue { Task { @MainActor in OpenRouterKeyCheck.shared.reset() } }
        }
    }

    var voiceEngine: VoiceEngine {
        get { VoiceEngine(rawValue: voiceEngineRaw) ?? .kokoro }
        set { voiceEngineRaw = newValue.rawValue }
    }

    var cursorColor: Color { Color(hex: cursorColorHex) ?? .blue }

    var hasKey: Bool { !openrouterKey.isEmpty }
}

/// Asks OpenRouter whether the saved key works, so Settings can say so honestly.
@MainActor
final class OpenRouterKeyCheck: ObservableObject {
    static let shared = OpenRouterKeyCheck()

    enum State: Equatable { case unchecked, checking, valid, invalid, unreachable(String) }

    @Published private(set) var state: State = .unchecked
    private var generation = 0

    func reset() {
        generation += 1
        state = .unchecked
    }

    func check() {
        let key = AppSettings.shared.openrouterKey
        generation += 1
        let gen = generation
        guard !key.isEmpty, let url = URL(string: "https://openrouter.ai/api/v1/key") else { state = .unchecked; return }
        state = .checking
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        Task {
            let result: State
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch code {
                case 200..<300: result = .valid
                case 401, 403: result = .invalid
                default: result = .unreachable("OpenRouter answered HTTP \(code).")
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
