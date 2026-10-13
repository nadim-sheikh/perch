import AVFoundation
import SwiftUI

// MARK: Sidebar

struct SettingsSidebar: View {
    let selection: SettingsSection
    @ObservedObject var router = HomeRouter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { router.settings = nil } label: {
                    Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon)
                }
                .buttonStyle(ChipStyle())
                Text("Settings").font(.system(size: 14, weight: .semibold))
            }
            .padding(.top, 30).padding(.horizontal, 14).padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.0) { group, sections in
                        if !group.isEmpty {
                            Text(group).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
                        }
                        ForEach(sections) { s in
                            SidebarItem(section: s, selected: s == selection)
                                .onTapGesture { router.settings = s }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            Text("OpenBuddy \(Bundle.main.shortVersion)")
                .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                .padding(14)
        }
    }

    private var groups: [(String, [SettingsSection])] {
        var out: [(String, [SettingsSection])] = []
        for s in SettingsSection.allCases {
            if let i = out.firstIndex(where: { $0.0 == s.group }) { out[i].1.append(s) } else { out.append((s.group, [s])) }
        }
        return out
    }
}

private struct SidebarItem: View {
    let section: SettingsSection
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.icon).font(.system(size: 12)).frame(width: 18)
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            Text(section.rawValue).font(.system(size: 12.5, weight: selected ? .semibold : .regular))
            Spacer()
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.white.opacity(0.1) : hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: Building blocks

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardStroke))
        }
    }
}

struct SettingsRow<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var last = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.5, weight: .medium))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                accessory
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            if !last { Divider().overlay(Theme.cardStroke).padding(.leading, 12) }
        }
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(.system(size: 12))
            .padding(.horizontal, 10).frame(width: 240, height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.cardStroke))
    }
}

extension View {
    func settingsField() -> some View { modifier(FieldStyle()) }
}

extension Bundle {
    var shortVersion: String { (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev" }
}

// MARK: Pages

struct SettingsPage: View {
    let section: SettingsSection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.rawValue).font(.system(size: 18, weight: .bold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                content
            }
            .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var subtitle: String {
        switch section {
        case .general: return "How OpenBuddy behaves on your Mac."
        case .ai: return "Pick the brain behind your buddy. Your keys stay in your Keychain."
        case .voice: return "How your buddy sounds when it talks back."
        case .microphone: return "The mic your buddy listens with."
        case .dictation: return "Type with your voice in any app."
        case .shortcuts: return "Keys that summon your buddy."
        case .cursor: return "How your buddy looks next to your pointer."
        case .permissions: return "What macOS lets OpenBuddy do."
        case .agents: return "Helpers that work in the background for you."
        case .integrations: return "Connect the apps your buddy can use."
        }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .general: GeneralPage()
        case .ai: AIPage()
        case .voice: VoicePage()
        case .microphone: MicrophonePage()
        case .dictation: ComingSoon(text: "System-wide dictation with AI clean-up is on the roadmap (Phase 6).")
        case .shortcuts: ShortcutsPage()
        case .cursor: CursorPage()
        case .permissions: PermissionsPage()
        case .agents: AgentsSettingsPage()
        case .integrations: IntegrationsSettingsPage()
        }
    }
}

private struct ComingSoon: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MascotView(size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("Coming soon").font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
    }
}

private struct GeneralPage: View {
    @AppStorage("showInDock") private var showInDock = false
    @AppStorage("showInRecordings") private var showInRecordings = true
    @AppStorage("notchPeek") private var notchPeek = true

    var body: some View {
        SettingsGroup(title: "Behavior") {
            SettingsRow(title: "Show in Dock", subtitle: "Turn off to keep OpenBuddy in the notch and menu bar only.") {
                Toggle("", isOn: $showInDock).toggleStyle(GlassToggleStyle())
            }
            SettingsRow(title: "Show in screen recordings", subtitle: "Let screen sharing and recording tools capture OpenBuddy.") {
                Toggle("", isOn: $showInRecordings).toggleStyle(GlassToggleStyle())
            }
            SettingsRow(title: "Quick peek on notch hover", subtitle: "Hovering the notch shows your recent chats. Turn off to open Home straight away.", last: true) {
                Toggle("", isOn: $notchPeek).toggleStyle(GlassToggleStyle())
            }
        }
        .onChange(of: showInDock) { _, _ in AppAppearance.apply() }
        .onChange(of: showInRecordings) { _, _ in AppAppearance.apply() }

        SettingsGroup(title: "Updates") {
            SettingsRow(title: "App version", subtitle: "You're on version \(Bundle.main.shortVersion).") {
                Button("Check on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/openbuddy/openbuddy/releases")!) }
                    .buttonStyle(ChipStyle(light: true))
            }
            SettingsRow(title: "Roadmap", subtitle: "Everything planned for OpenBuddy.", last: true) {
                Image(systemName: "arrow.up.right").foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

private struct AIPage: View {
    @ObservedObject var settings = AppSettings.shared
    @AppStorage("provider") private var provider = LLMProvider.anthropic.rawValue
    @AppStorage("anthropicModel") private var anthropicModel = LLMProvider.anthropic.defaultModel
    @AppStorage("openaiModel") private var openaiModel = LLMProvider.openai.defaultModel
    @AppStorage("openrouterModel") private var openrouterModel = LLMProvider.openrouter.defaultModel
    @State private var openrouterModels: [String] = []
    @State private var loading = false

    var body: some View {
        SettingsGroup(title: "Provider") {
            ForEach(LLMProvider.allCases) { p in
                SettingsRow(title: p.displayName, subtitle: blurb(p), last: p == LLMProvider.allCases.last) {
                    Image(systemName: provider == p.rawValue ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(provider == p.rawValue ? Theme.accent : Theme.textTertiary)
                }
                .contentShape(Rectangle())
                .onTapGesture { provider = p.rawValue }
            }
        }

        SettingsGroup(title: "Model") {
            switch LLMProvider(rawValue: provider) ?? .anthropic {
            case .anthropic:
                SettingsRow(title: "Claude model", last: true) { TextField("", text: $anthropicModel).settingsField() }
            case .openai:
                SettingsRow(title: "OpenAI model", last: true) { TextField("", text: $openaiModel).settingsField() }
            case .openrouter:
                SettingsRow(title: "OpenRouter model", subtitle: "Must accept images so it can see your screen.") {
                    TextField("", text: $openrouterModel).settingsField()
                }
                SettingsRow(title: "Browse models", subtitle: openrouterModels.isEmpty ? "Load the list of vision models from OpenRouter." : "\(openrouterModels.count) models can see images.", last: true) {
                    if openrouterModels.isEmpty {
                        Button(loading ? "Loading…" : "Load models") {
                            loading = true
                            Task { openrouterModels = await OpenRouterCatalog.visionModels(); loading = false }
                        }
                        .buttonStyle(ChipStyle(light: true))
                    } else {
                        Picker("", selection: $openrouterModel) {
                            if !openrouterModels.contains(openrouterModel) { Text(openrouterModel).tag(openrouterModel) }
                            ForEach(openrouterModels, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(width: 240)
                    }
                }
            }
        }

        SettingsGroup(title: "API keys") {
            SettingsRow(title: "Anthropic", subtitle: "console.anthropic.com") { SecureField("sk-ant-…", text: $settings.anthropicKey).settingsField() }
            SettingsRow(title: "OpenAI", subtitle: "Also used for OpenAI voices") { SecureField("sk-…", text: $settings.openaiKey).settingsField() }
            SettingsRow(title: "OpenRouter", subtitle: "openrouter.ai/keys", last: true) { SecureField("sk-or-…", text: $settings.openrouterKey).settingsField() }
        }
    }

    private func blurb(_ p: LLMProvider) -> String {
        switch p {
        case .anthropic: return "Claude, straight from Anthropic."
        case .openai: return "GPT models from OpenAI."
        case .openrouter: return "One key for hundreds of models: Claude, GPT, Gemini, Grok…"
        }
    }
}

private struct VoicePage: View {
    @AppStorage("voiceEngine") private var voiceEngine = VoiceEngine.system.rawValue
    @AppStorage("openaiVoice") private var openaiVoice = "alloy"
    @AppStorage("systemVoiceID") private var systemVoiceID = ""

    var body: some View {
        SettingsGroup(title: "Speaking") {
            ForEach(VoiceEngine.allCases) { e in
                SettingsRow(title: e.displayName, last: e == VoiceEngine.allCases.last) {
                    Image(systemName: voiceEngine == e.rawValue ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(voiceEngine == e.rawValue ? Theme.accent : Theme.textTertiary)
                }
                .contentShape(Rectangle())
                .onTapGesture { voiceEngine = e.rawValue }
            }
        }
        if voiceEngine == VoiceEngine.openai.rawValue {
            SettingsGroup(title: "OpenAI voice") {
                SettingsRow(title: "Voice", subtitle: "Needs an OpenAI key.", last: true) {
                    Picker("", selection: $openaiVoice) {
                        ForEach(Speaker.openAIVoices, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .labelsHidden().frame(width: 160)
                }
            }
        }
        if voiceEngine == VoiceEngine.system.rawValue {
            SettingsGroup(title: "macOS voice") {
                SettingsRow(title: "Voice", subtitle: "Download nicer voices in System Settings → Accessibility → Spoken Content.", last: true) {
                    Picker("", selection: $systemVoiceID) {
                        Text("Default").tag("")
                        ForEach(AVSpeechSynthesisVoice.speechVoices()
                            .filter { $0.language.hasPrefix(String(Locale.current.identifier.prefix(2))) }, id: \.identifier) {
                            Text($0.name).tag($0.identifier)
                        }
                    }
                    .labelsHidden().frame(width: 180)
                }
            }
        }
    }
}

private struct MicrophonePage: View {
    @State private var granted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

    var body: some View {
        SettingsGroup(title: "Input") {
            SettingsRow(title: "Microphone", subtitle: "OpenBuddy uses your system input device. Change it in System Settings → Sound.") {
                Text(AVCaptureDevice.default(for: .audio)?.localizedName ?? "None")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            SettingsRow(title: "Access", last: true) {
                if granted {
                    Label("Allowed", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
                } else {
                    Button("Allow") { Task { granted = await SpeechRecognizer.requestPermissions() } }
                        .buttonStyle(ChipStyle(light: true))
                }
            }
        }
    }
}

private struct ShortcutsPage: View {
    var body: some View {
        SettingsGroup(title: "Talk") {
            SettingsRow(title: "Push to talk", subtitle: "Hold to talk, release to send.") { KeyCaps(keys: ["⌃ control", "⌥ option"]) }
            SettingsRow(title: "Ask by typing", subtitle: "From the menu bar icon.", last: true) { KeyCaps(keys: ["⌘", "K"]) }
        }
        Text("Custom shortcuts are coming in Phase 2.").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
    }
}

private struct KeyCaps: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { k in
                Text(k).font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.1)))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.12)))
            }
        }
    }
}

private struct CursorPage: View {
    @AppStorage("cursorColorHex") private var cursorColorHex = "#3B82F6"
    @AppStorage("buddyName") private var buddyName = "Buddy"
    @AppStorage("followCursor") private var followCursor = true
    private let colors = ["#3B82F6", "#8B5CF6", "#EC4899", "#F97316", "#22C55E", "#14B8A6", "#EAB308", "#F8FAFC"]

    var body: some View {
        SettingsGroup(title: "Buddy") {
            SettingsRow(title: "Name") { TextField("", text: $buddyName).settingsField() }
            SettingsRow(title: "Follow my cursor", subtitle: "Turn off to keep the buddy still until it points at something.", last: true) {
                Toggle("", isOn: $followCursor).toggleStyle(GlassToggleStyle())
            }
        }
        SettingsGroup(title: "Colour") {
            HStack(spacing: 10) {
                ForEach(colors, id: \.self) { hex in
                    ZStack {
                        Circle().fill(Color(hex: hex) ?? .blue).frame(width: 26, height: 26)
                        if cursorColorHex == hex {
                            Circle().stroke(Color.white, lineWidth: 2).frame(width: 32, height: 32)
                        }
                    }
                    .onTapGesture { cursorColorHex = hex }
                }
                Spacer()
                CursorShape().fill(Color(hex: cursorColorHex) ?? .blue).frame(width: 16, height: 20)
                    .shadow(color: (Color(hex: cursorColorHex) ?? .blue).opacity(0.8), radius: 6)
            }
            .padding(12)
        }
    }
}

private struct PermissionsPage: View {
    @State private var permissions = PermissionSnapshot.current()

    var body: some View {
        SettingsGroup(title: "Required") {
            PermissionRow(title: "Microphone & Speech", subtitle: "To hear you.", granted: permissions.speech) {
                Task { _ = await SpeechRecognizer.requestPermissions(); permissions = .current() }
            }
            PermissionRow(title: "Screen Recording", subtitle: "To see what you're looking at.", granted: permissions.screen) {
                ScreenCapture.requestPermission()
                openPrivacyPane("Privacy_ScreenCapture")
            }
            PermissionRow(title: "Accessibility", subtitle: "For the Control + Option hotkey.", granted: permissions.accessibility, last: true) {
                _ = PushToTalkMonitor.hasAccessibility(prompt: true)
                openPrivacyPane("Privacy_Accessibility")
            }
        }
        HStack {
            Button("Refresh") { permissions = .current() }.buttonStyle(ChipStyle())
            Text("After granting Screen Recording or Accessibility, quit and reopen OpenBuddy.")
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        }
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
    var subtitle: String?
    let granted: Bool
    var last = false
    let action: () -> Void

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, last: last) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
            } else {
                Button("Grant", action: action).buttonStyle(ChipStyle(light: true))
            }
        }
    }
}

/// Lists OpenRouter models that accept image input (needed to see the screen).
enum OpenRouterCatalog {
    static func visionModels() async -> [String] {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["data"] as? [[String: Any]] else { return [] }
        return models.compactMap { m -> String? in
            guard let id = m["id"] as? String, !id.hasSuffix(":batch"),
                  let arch = m["architecture"] as? [String: Any],
                  let inputs = arch["input_modalities"] as? [String],
                  inputs.contains("image") else { return nil }
            return id
        }
        .sorted()
    }
}

/// Applies the Dock and screen-recording visibility preferences.
@MainActor
enum AppAppearance {
    static func apply() {
        let d = UserDefaults.standard
        let showInDock = d.bool(forKey: "showInDock")
        let showInRecordings = d.object(forKey: "showInRecordings") as? Bool ?? true
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        for w in NSApp.windows {
            w.sharingType = showInRecordings ? .readOnly : .none
        }
    }
}
