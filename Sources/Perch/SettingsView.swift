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
            .padding(.top, 50).padding(.horizontal, 14).padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.0) { group, sections in
                        if !group.isEmpty {
                            Text(group).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
                        }
                        ForEach(sections) { s in
                            // A real button so VoiceOver and keyboard users can pick the page too.
                            Button { router.settings = s } label: { SidebarItem(section: s, selected: s == selection) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            Text("Perch \(Bundle.main.shortVersion)")
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
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                }
                content
            }
            .padding(.horizontal, 22).padding(.top, 54).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var subtitle: String {
        switch section {
        case .general: return ""
        case .ai: return "Your key stays in your Keychain."
        case .voice: return ""
        case .microphone: return ""
        case .dictation: return ""
        case .shortcuts: return ""
        case .cursor: return ""
        case .permissions: return ""
        case .agents: return ""
        case .integrations: return ""
        }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .general: GeneralPage()
        case .ai: AIPage()
        case .voice: VoicePage()
        case .microphone: MicrophonePage()
        case .dictation: DictationPage()
        case .shortcuts: ShortcutsPage()
        case .cursor: CursorPage()
        case .permissions: PermissionsPage()
        case .agents: AgentsSettingsPage()
        case .integrations: IntegrationsSettingsPage()
        }
    }
}

private struct DictationPage: View {
    var body: some View {
        SettingsGroup(title: "Dictate anywhere") {
            SettingsRow(title: "Hold to dictate", subtitle: "In any text box, hold Control + Shift, speak, then let go. Your words are typed where the cursor is.") {
                KeyCaps(keys: ["⌃ control", "⇧ shift"])
            }
            SettingsRow(title: "Speech to text", subtitle: "Uses the engine chosen in Microphone, so it can run privately on your Mac.") {
                Button("Microphone") { HomeRouter.shared.settings = .microphone }.buttonStyle(ChipStyle())
            }
            SettingsRow(title: "Permissions", subtitle: "Needs Microphone to hear you and Accessibility to type into other apps.", last: true) {
                Button("Permissions") { HomeRouter.shared.settings = .permissions }.buttonStyle(ChipStyle())
            }
        }
    }
}

private struct GeneralPage: View {
    @AppStorage("showInDock") private var showInDock = false
    @AppStorage("showInRecordings") private var showInRecordings = true
    @AppStorage("notchPeek") private var notchPeek = true

    var body: some View {
        SettingsGroup(title: "Behavior") {
            SettingsRow(title: "Show in Dock", subtitle: nil) {
                Toggle("", isOn: $showInDock).toggleStyle(GlassToggleStyle())
            }
            SettingsRow(title: "Show in screen recordings", subtitle: nil) {
                Toggle("", isOn: $showInRecordings).toggleStyle(GlassToggleStyle())
            }
            SettingsRow(title: "Quick peek on notch hover", subtitle: nil, last: true) {
                Toggle("", isOn: $notchPeek).toggleStyle(GlassToggleStyle())
            }
        }
        .onChange(of: showInDock) { _, _ in AppAppearance.apply() }
        .onChange(of: showInRecordings) { _, _ in AppAppearance.apply() }

        SettingsGroup(title: "Updates") {
            SettingsRow(title: "Version", subtitle: Bundle.main.shortVersion, last: true) { EmptyView() }
        }
    }
}

private struct AIPage: View {
    @ObservedObject var settings = AppSettings.shared
    @AppStorage("perchModel") private var model = PerchModel.defaultID
    @State private var custom = ""
    @State private var speed: [String: String] = [:]
    @State private var testing: String?

    private var isCustom: Bool { !PerchModel.choices.contains { $0.id == model } }

    var body: some View {
        SettingsGroup(title: "Model") {
            ForEach(PerchModel.choices) { c in
                SettingsRow(title: c.name, subtitle: speed[c.id].map { "\(c.note) · \($0)" } ?? c.note) {
                    HStack(spacing: 8) {
                        Button(testing == c.id ? "Testing…" : "Test speed") { test(c.id) }
                            .buttonStyle(ChipStyle())
                            .disabled(testing != nil || settings.openrouterKey.isEmpty)
                        Image(systemName: model == c.id ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(model == c.id ? Theme.accent : Theme.textTertiary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { model = c.id }
            }
            SettingsRow(title: "Custom", subtitle: "Any OpenRouter model id that can see images.", last: true) {
                HStack(spacing: 8) {
                    TextField("provider/model", text: $custom).settingsField()
                        .onSubmit { if !custom.trimmingCharacters(in: .whitespaces).isEmpty { model = custom.trimmingCharacters(in: .whitespaces) } }
                    Image(systemName: isCustom ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isCustom ? Theme.accent : Theme.textTertiary)
                }
            }
        }
        .onAppear { if isCustom { custom = model } }
        Text("Used for everything: talking, showing on screen, helpers and fixing text.")
            .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)

        SettingsGroup(title: "API key") {
            SettingsRow(title: "OpenRouter", subtitle: nil) {
                SecureField("sk-or-…", text: $settings.openrouterKey).settingsField()
            }
            SettingsRow(title: "Status", subtitle: nil, last: true) {
                HStack(spacing: 8) {
                    KeyStatusLabel()
                    Button("Check key") { OpenRouterKeyCheck.shared.check() }
                        .buttonStyle(ChipStyle(light: true))
                        .disabled(settings.openrouterKey.isEmpty)
                }
            }
        }
        Link("Get a key at openrouter.ai/keys", destination: URL(string: "https://openrouter.ai/keys")!)
            .font(.system(size: 11))
    }

    /// Times a tiny request: how long until the model's first word, and the whole reply.
    private func test(_ id: String) {
        testing = id
        Task {
            let start = Date()
            var first: Double?
            var ok = false
            do {
                let client = LLMClient(model: id, maxTokens: 40)
                for try await chunk in client.stream(system: "Reply in one short sentence.", history: [], prompt: "Say hi.", screens: []) {
                    if first == nil && !chunk.trimmingCharacters(in: .whitespaces).isEmpty { first = Date().timeIntervalSince(start) }
                }
                ok = true
            } catch {
                speed[id] = "error: \(error.localizedDescription.prefix(60))"
            }
            if ok {
                let total = Date().timeIntervalSince(start)
                speed[id] = String(format: "first word %.1fs, done %.1fs", first ?? total, total)
            }
            testing = nil
        }
    }
}

/// The OpenRouter key's real state. Checks it once when first shown.
struct KeyStatusLabel: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var check = OpenRouterKeyCheck.shared

    var body: some View {
        Group {
            if settings.openrouterKey.isEmpty {
                Label("No key", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
            } else {
                switch check.state {
                case .unchecked: Label("Not checked", systemImage: "questionmark.circle").foregroundStyle(Theme.textSecondary)
                case .checking: Label("Checking…", systemImage: "hourglass").foregroundStyle(Theme.textSecondary)
                case .valid: Label("Valid", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .invalid: Label("Invalid key", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                case .unreachable(let why): Label("Couldn't check", systemImage: "wifi.exclamationmark").foregroundStyle(.orange).help(why)
                }
            }
        }
        .font(.system(size: 12))
        .onAppear { if !settings.openrouterKey.isEmpty, check.state == .unchecked { check.check() } }
    }
}

private struct VoicePage: View {
    @AppStorage("voiceEngine") private var voiceEngine = VoiceEngine.kokoro.rawValue
    @AppStorage("kokoroVoice") private var kokoroVoice = "af_heart"
    @AppStorage("voiceSpeed") private var voiceSpeed = 1.0
    @State private var previewing = false
    /// Its own speaker, so the button can wait for the preview to finish.
    @MainActor private static let previewSpeaker = Speaker()

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
        if voiceEngine == VoiceEngine.kokoro.rawValue {
            SettingsGroup(title: "Natural voice") {
                SettingsRow(title: "Pace") {
                    Slider(value: $voiceSpeed, in: 0.8...1.15).frame(width: 160)
                }
                SettingsRow(title: "Voice", subtitle: "Runs privately on your Mac. First use downloads ~330 MB.", last: true) {
                    HStack(spacing: 6) {
                        Picker("", selection: $kokoroVoice) {
                            ForEach(Kokoro.voices, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().frame(width: 160)
                        Button(previewing ? "…" : "Play") {
                            previewing = true
                            Task {
                                await Self.previewSpeaker.speak("Hey! I'm Perch. This is how I sound now. Better, right?")
                                previewing = false
                            }
                        }
                        .buttonStyle(ChipStyle(light: true))
                        .disabled(previewing)
                    }
                }
            }
        }
    }
}

private struct MicrophonePage: View {
    @State private var granted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @AppStorage("speechEngine") private var engine = SpeechEngine.parakeet.rawValue
    @State private var parakeet: Parakeet.State = .notLoaded

    var body: some View {
        SettingsGroup(title: "Speech to text") {
            SettingsRow(title: "Engine", subtitle: engine == SpeechEngine.parakeet.rawValue
                        ? "NVIDIA Parakeet, runs privately on your Mac." : "Apple's built-in recognizer.") {
                Picker("", selection: $engine) {
                    ForEach(SpeechEngine.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 190)
            }
            if engine == SpeechEngine.parakeet.rawValue {
                SettingsRow(title: "Model", subtitle: parakeetText, last: true) {
                    if case .downloading(let p) = parakeet {
                        ProgressView(value: p).frame(width: 120)
                    } else if parakeet != .ready {
                        Button("Download") { load() }.buttonStyle(ChipStyle(light: true))
                    } else {
                        Label("Ready", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
                    }
                }
            }
        }
        .task { parakeet = await Parakeet.shared.state }

        SettingsGroup(title: "Input") {
            SettingsRow(title: "Microphone", subtitle: "Perch uses your system input device. Change it in System Settings → Sound.") {
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

extension MicrophonePage {
    var parakeetText: String {
        switch parakeet {
        case .notLoaded: return "About 220 MB, downloaded once."
        case .downloading(let p): return "Downloading… \(Int(p * 100))%"
        case .ready: return "Loaded on the Neural Engine."
        case .failed(let m): return "Couldn't load: \(m)"
        }
    }

    func load() {
        parakeet = .downloading(0)
        Task.detached {
            await Parakeet.shared.load { state in Task { @MainActor in parakeet = state } }
        }
    }
}

private struct ShortcutsPage: View {
    var body: some View {
        SettingsGroup(title: "Talk & type") {
            SettingsRow(title: "Talk to Perch", subtitle: "Hold, speak, release.") { KeyCaps(keys: ["⌃ control", "⌥ option"]) }
            SettingsRow(title: "Type to Perch", subtitle: "Double-tap Control to open the box in the notch.", last: true) { KeyCaps(keys: ["⌃ control", "⌃ control"]) }
        }
        SettingsGroup(title: "In any text box") {
            SettingsRow(title: "Dictate", subtitle: "Hold, speak, and your words are typed where the cursor is.") { KeyCaps(keys: ["⌃ control", "⇧ shift"]) }
            SettingsRow(title: "Fix spelling & grammar", subtitle: "Select text, then fix it in place.", last: true) { KeyCaps(keys: ["⌥ option", "⇧ shift", "U"]) }
        }
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
    @AppStorage("buddyName") private var buddyName = "Perch"
    @AppStorage("followCursor") private var followCursor = true
    private let colors = ["#3B82F6", "#8B5CF6", "#EC4899", "#F97316", "#22C55E", "#14B8A6", "#EAB308", "#F8FAFC"]

    var body: some View {
        SettingsGroup(title: "Buddy") {
            SettingsRow(title: "Name") { TextField("", text: $buddyName).settingsField() }
            SettingsRow(title: "Follow my cursor", subtitle: nil, last: true) {
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
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsGroup(title: "Perch needs") {
            PermissionRow(title: "Microphone", subtitle: "To hear you.", granted: permissions.speech) {
                Task {
                    _ = await SpeechRecognizer.requestPermissions()
                    permissions = .current()
                    if !permissions.speech { PermissionGuide.open(.microphone) }
                }
            }
            PermissionRow(title: "Screen Recording", subtitle: "To see what you see and point at it.", granted: permissions.screen) {
                ScreenCapture.requestPermission()
                PermissionGuide.open(.screen)
            }
            PermissionRow(title: "Accessibility", subtitle: "For the shortcuts, and so I can click and type for you.", granted: permissions.accessibility, last: true) {
                _ = PushToTalkMonitor.hasAccessibility(prompt: true)
                PermissionGuide.open(.accessibility)
            }
        }
        if permissions.screen && permissions.accessibility && permissions.speech {
            Label("All set. I can see, hear and point.", systemImage: "checkmark.seal.fill")
                .font(.system(size: 12)).foregroundStyle(.green)
        } else {
            Text("If a switch was already on, turn it off and on again, then reopen Perch.")
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        }
        Color.clear.frame(height: 0)
            .onAppear { permissions = .current() }
            .onReceive(refresh) { _ in permissions = .current() }
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
