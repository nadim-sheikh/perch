import AVFoundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @AppStorage("provider") private var provider = LLMProvider.anthropic.rawValue
    @AppStorage("anthropicModel") private var anthropicModel = LLMProvider.anthropic.defaultModel
    @AppStorage("openaiModel") private var openaiModel = LLMProvider.openai.defaultModel
    @AppStorage("voiceEngine") private var voiceEngine = VoiceEngine.system.rawValue
    @AppStorage("openaiVoice") private var openaiVoice = "alloy"
    @AppStorage("systemVoiceID") private var systemVoiceID = ""
    @AppStorage("cursorColorHex") private var cursorColorHex = "#3B82F6"
    @AppStorage("buddyName") private var buddyName = "Buddy"
    @AppStorage("followCursor") private var followCursor = true

    @State private var permissions = PermissionSnapshot.current()

    private let colors = ["#3B82F6", "#8B5CF6", "#EC4899", "#F97316", "#22C55E", "#14B8A6", "#EAB308", "#64748B"]

    var body: some View {
        TabView {
            Form {
                Section("AI model") {
                    Picker("Provider", selection: $provider) {
                        ForEach(LLMProvider.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    if provider == LLMProvider.anthropic.rawValue {
                        TextField("Claude model", text: $anthropicModel)
                    } else {
                        TextField("OpenAI model", text: $openaiModel)
                    }
                }
                Section("API keys (stored in your Keychain)") {
                    SecureField("Anthropic API key", text: $settings.anthropicKey)
                    SecureField("OpenAI API key", text: $settings.openaiKey)
                    Text("Keys never leave your Mac except to call the provider you chose.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("AI", systemImage: "sparkles") }

            Form {
                Section("Speaking") {
                    Picker("Voice", selection: $voiceEngine) {
                        ForEach(VoiceEngine.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    if voiceEngine == VoiceEngine.openai.rawValue {
                        Picker("OpenAI voice", selection: $openaiVoice) {
                            ForEach(Speaker.openAIVoices, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                    }
                    if voiceEngine == VoiceEngine.system.rawValue {
                        Picker("macOS voice", selection: $systemVoiceID) {
                            Text("Default").tag("")
                            ForEach(AVSpeechSynthesisVoice.speechVoices()
                                .filter { $0.language.hasPrefix(String(Locale.current.identifier.prefix(2))) }, id: \.identifier) {
                                Text("\($0.name) (\($0.language))").tag($0.identifier)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Voice", systemImage: "waveform") }

            Form {
                Section("Buddy") {
                    TextField("Name", text: $buddyName)
                    Toggle("Follow my cursor", isOn: $followCursor)
                    HStack {
                        Text("Colour")
                        Spacer()
                        ForEach(colors, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex) ?? .blue)
                                .frame(width: 20, height: 20)
                                .overlay(Circle().stroke(.primary, lineWidth: cursorColorHex == hex ? 2 : 0))
                                .onTapGesture { cursorColorHex = hex }
                        }
                    }
                }
                Section("How to use") {
                    Text("Hold **Control + Option** and talk. Let go to send.")
                    Text("Or choose **Ask by typing…** from the menu bar icon.")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Buddy", systemImage: "cursorarrow.rays") }

            Form {
                Section("Permissions") {
                    PermissionRow(title: "Microphone & Speech", granted: permissions.speech) {
                        Task { _ = await SpeechRecognizer.requestPermissions(); permissions = .current() }
                    }
                    PermissionRow(title: "Screen Recording", granted: permissions.screen) {
                        ScreenCapture.requestPermission()
                        openPrivacyPane("Privacy_ScreenCapture")
                    }
                    PermissionRow(title: "Accessibility (for the hotkey)", granted: permissions.accessibility) {
                        _ = PushToTalkMonitor.hasAccessibility(prompt: true)
                        openPrivacyPane("Privacy_Accessibility")
                    }
                    Button("Refresh") { permissions = .current() }
                    Text("After granting Screen Recording or Accessibility, quit and reopen OpenBuddy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 520, height: 420)
        .onAppear { permissions = .current() }
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct PermissionSnapshot {
    var speech: Bool
    var screen: Bool
    var accessibility: Bool

    static func current() -> PermissionSnapshot {
        PermissionSnapshot(
            speech: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            screen: ScreenCapture.hasPermission(),
            accessibility: PushToTalkMonitor.hasAccessibility(prompt: false)
        )
    }
}

struct PermissionRow: View {
    let title: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
            Spacer()
            if !granted { Button("Grant", action: action) }
        }
    }
}
