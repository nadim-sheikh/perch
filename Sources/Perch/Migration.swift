import Foundation
import Security

/// One-time move of data from the app's old name (OpenBuddy) to Perch.
enum Migration {
    static func run() {
        let d = UserDefaults.standard
        if !d.bool(forKey: "migratedDefaultsFromOpenBuddy"), let old = UserDefaults(suiteName: "dev.openbuddy.app") {
            let keys = ["provider", "anthropicModel", "openaiModel", "openrouterModel", "voiceEngine", "openaiVoice",
                        "systemVoiceID", "cursorColorHex", "buddyName", "followCursor", "showInDock", "showInRecordings",
                        "notchPeek", "agentAuthMode", "agentModel", "agentSounds", "speakAgentUpdates"]
            for k in keys { if let v = old.object(forKey: k), d.object(forKey: k) == nil { d.set(v, forKey: k) } }
            d.set(true, forKey: "migratedDefaultsFromOpenBuddy")
        }
        guard !d.bool(forKey: "migratedFromOpenBuddy") else { return }
        defer { d.set(true, forKey: "migratedFromOpenBuddy") }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // ~/OpenBuddy → ~/Perch (helpers, connectors)
        let oldRoot = home.appendingPathComponent("OpenBuddy"), newRoot = home.appendingPathComponent("Perch")
        if fm.fileExists(atPath: oldRoot.path) && !fm.fileExists(atPath: newRoot.path) {
            try? fm.moveItem(at: oldRoot, to: newRoot)
        }
        // helper metadata folders .openbuddy → .perch
        let agents = newRoot.appendingPathComponent("Agents")
        for dir in (try? fm.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil)) ?? [] {
            let old = dir.appendingPathComponent(".openbuddy"), new = dir.appendingPathComponent(".perch")
            if fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) { try? fm.moveItem(at: old, to: new) }
        }
        // Application Support chats
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldSupport = support.appendingPathComponent("OpenBuddy"), newSupport = support.appendingPathComponent("Perch")
        if fm.fileExists(atPath: oldSupport.path) && !fm.fileExists(atPath: newSupport.path) {
            try? fm.moveItem(at: oldSupport, to: newSupport)
        }
        // Keychain items
        for account in ["anthropic", "openai", "openrouter"] {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Keychain.legacyService,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var item: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
               Keychain.get(account).isEmpty {
                Keychain.set(String(decoding: data, as: UTF8.self), for: account)
            }
        }
    }
}
