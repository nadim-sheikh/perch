import AppKit
import SwiftUI

struct AgentsSettingsPage: View {
    @ObservedObject var roster = AgentRoster.shared
    @ObservedObject var settings = AppSettings.shared
    @AppStorage("agentAuthMode") private var authMode = AgentAuthMode.claudeLogin.rawValue
    @AppStorage("agentModel") private var agentModel = ""
    @AppStorage("agentSounds") private var sounds = true
    @AppStorage("speakAgentUpdates") private var speak = true
    @State private var cliPath = ClaudeCodeRun.locateCLI()

    var body: some View {
        SettingsGroup(title: "Engine") {
            SettingsRow(title: "Claude Code", subtitle: cliPath == nil
                        ? "Helpers run on Claude Code, which isn't installed yet."
                        : "Helpers run on your own Claude Code at \(cliPath!).") {
                if cliPath == nil {
                    Button("Get it") { NSWorkspace.shared.open(URL(string: "https://claude.com/claude-code")!) }
                        .buttonStyle(ChipStyle(light: true))
                } else {
                    Label("Found", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
                }
            }
            SettingsRow(title: "Sign in with", subtitle: authHelp) {
                Picker("", selection: $authMode) {
                    ForEach(AgentAuthMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 200)
            }
            if authMode == AgentAuthMode.claudeLogin.rawValue {
                SettingsRow(title: "Claude login", subtitle: "Opens Terminal so you can sign in to Claude Code.") {
                    Button("Sign in…") { openClaudeLogin() }.buttonStyle(ChipStyle(light: true))
                }
            }
            SettingsRow(title: "Model", subtitle: "Leave empty for Claude Code's default. Examples: sonnet, opus, haiku (or an OpenRouter model id).", last: true) {
                TextField("default", text: $agentModel).settingsField()
            }
        }

        SettingsGroup(title: "Updates") {
            SettingsRow(title: "Sounds", subtitle: "A pop when a helper starts and a chime when it's done.") {
                Toggle("", isOn: $sounds).toggleStyle(GlassToggleStyle())
            }
            SettingsRow(title: "Speak updates", subtitle: "Your buddy reads out a one-line summary when a helper finishes.", last: true) {
                Toggle("", isOn: $speak).toggleStyle(GlassToggleStyle())
            }
        }

        SettingsGroup(title: "Helpers") {
            ForEach(roster.agents) { agent in
                AgentSettingsRow(agent: agent, last: agent.id == roster.agents.last?.id)
            }
        }
        HStack {
            Button { HomeRouter.shared.showNewAgent = true } label: { Label("New helper", systemImage: "plus") }
                .buttonStyle(ChipStyle())
            Button { NSWorkspace.shared.open(AgentPaths.agents) } label: { Label("Open helpers folder", systemImage: "folder") }
                .buttonStyle(ChipStyle())
        }
    }

    private var authHelp: String {
        switch AgentAuthMode(rawValue: authMode) ?? .claudeLogin {
        case .claudeLogin: return "Uses your Claude subscription through Claude Code."
        case .anthropicKey: return settings.anthropicKey.isEmpty ? "Add your Anthropic key in AI Models first." : "Uses the Anthropic key from AI Models."
        case .openrouterKey: return settings.openrouterKey.isEmpty ? "Add your OpenRouter key in AI Models first." : "Uses the OpenRouter key from AI Models."
        }
    }

    private func openClaudeLogin() {
        let env = AgentSettings.environment()
        let script = "#!/bin/zsh\nexport PATH=\"\(env["PATH"] ?? "")\"\necho 'Type /login and follow the steps, then /exit.'\nclaude\n"
        let url = AgentPaths.root.appendingPathComponent("claude-login.command")
        try? FileManager.default.createDirectory(at: AgentPaths.root, withIntermediateDirectories: true)
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
}

private struct AgentSettingsRow: View {
    let agent: BuddyAgent
    var last: Bool

    var body: some View {
        SettingsRow(title: agent.name, subtitle: "\(agent.role) · \(agent.accessLevel.detail)", last: last) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { agent.accessLevel },
                    set: { var a = agent; a.accessLevel = $0; AgentRoster.shared.update(a) })) {
                    ForEach(AgentAccessLevel.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 160)
                Button { AgentRoster.shared.setArchived(agent.id, !agent.archived) } label: {
                    Image(systemName: agent.archived ? "tray.and.arrow.up" : "archivebox")
                }
                .buttonStyle(IconButtonStyle())
                .help(agent.archived ? "Unarchive" : "Archive")
            }
        }
    }
}

// MARK: Integrations

struct IntegrationsSettingsPage: View {
    @ObservedObject var store = ConnectorStore.shared
    @State private var search = ""
    @State private var category = "All"
    @State private var secretSheet: ConnectorDefinition?
    @State private var showCustom = false

    private var categories: [String] { ["All"] + Array(Set(ConnectorCatalog.all.map(\.category))).sorted() }

    private var catalog: [ConnectorDefinition] {
        ConnectorCatalog.all.filter { def in
            !store.isEnabled(def.id)
                && (category == "All" || def.category == category)
                && (search.isEmpty || def.name.lowercased().contains(search.lowercased()))
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            TextField("Search integrations", text: $search).textFieldStyle(.plain).font(.system(size: 12))
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(categories, id: \.self) { c in
                    Button(c) { category = c }.buttonStyle(ChipStyle(light: category == c))
                }
            }
        }

        if !store.enabled.isEmpty {
            SettingsGroup(title: "Connected") {
                ForEach(store.enabled) { def in
                    SettingsRow(title: def.name, subtitle: statusText(def), last: def.id == store.enabled.last?.id) {
                        HStack(spacing: 6) {
                            if store.status[def.id] == .needsSignIn {
                                Button("Sign in") { store.signInAgain(def) }.buttonStyle(ChipStyle(light: true))
                            }
                            Button("Disconnect") { store.disconnect(def) }.buttonStyle(ChipStyle())
                        }
                    }
                }
            }
            Button { store.refreshStatus() } label: { Label("Check connections", systemImage: "arrow.clockwise") }
                .buttonStyle(ChipStyle())
        }

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
            ForEach(catalog) { def in
                ConnectorCard(def: def) {
                    switch def.auth {
                    case .token, .env: secretSheet = def
                    default: store.connect(def)
                    }
                }
            }
            CustomConnectorCard { showCustom = true }
        }

        Text("Connections are free MCP servers. Browser sign-in happens through Claude Code in a Terminal window; tokens stay in your Keychain. Your helpers use connected apps automatically.")
            .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            .onAppear { store.refreshStatus() }
            .sheet(item: $secretSheet) { def in SecretSheet(def: def) { secretSheet = nil } }
            .sheet(isPresented: $showCustom) { CustomConnectorSheet { showCustom = false } }
    }

    private func statusText(_ def: ConnectorDefinition) -> String {
        switch store.status[def.id] ?? .unknown {
        case .connected: return "Connected"
        case .checking: return "Checking…"
        case .needsSignIn: return "Needs sign-in"
        case .failed(let m): return "Problem: \(m)"
        case .unknown: return def.blurb
        }
    }
}

private struct ConnectorCard: View {
    let def: ConnectorDefinition
    let onConnect: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(hex: def.colorHex) ?? .gray)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: def.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white))
                Spacer()
                Button("Connect", action: onConnect).buttonStyle(ChipStyle(light: true))
            }
            Text(def.name).font(.system(size: 12.5, weight: .semibold))
            Text(def.blurb).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(hovering ? Theme.hover : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardStroke))
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct CustomConnectorCard: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3])))
                Text("Custom connector").font(.system(size: 12.5, weight: .semibold))
                Text("Any MCP server: a URL or a command on this Mac.").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        }
        .buttonStyle(.plain)
    }
}

private struct SecretSheet: View {
    let def: ConnectorDefinition
    let onDone: () -> Void
    @State private var values: [String: String] = [:]

    private var names: [String] {
        switch def.auth {
        case .token: return ["TOKEN"]
        case .env(let n, _): return n
        default: return []
        }
    }
    private var help: String {
        switch def.auth {
        case .token(_, _, let h), .env(_, let h): return h
        default: return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect \(def.name)").font(.system(size: 16, weight: .bold))
            Text(help).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            ForEach(names, id: \.self) { n in
                SecureField(n == "TOKEN" ? "Token" : n, text: Binding(get: { values[n] ?? "" }, set: { values[n] = $0 }))
                    .settingsField()
            }
            HStack {
                Spacer()
                Button("Cancel", action: onDone).buttonStyle(ChipStyle())
                Button("Connect") {
                    ConnectorStore.shared.connect(def, secrets: values)
                    onDone()
                }
                .buttonStyle(GlassPillStyle(height: 28))
                .disabled(names.contains { (values[$0] ?? "").isEmpty })
            }
        }
        .padding(22).frame(width: 420).background(Theme.window).preferredColorScheme(.dark)
    }
}

private struct CustomConnectorSheet: View {
    let onDone: () -> Void
    @State private var name = ""
    @State private var remote = true
    @State private var url = ""
    @State private var command = ""
    @State private var argsText = ""
    @State private var authKind = 0   // 0 none, 1 browser, 2 token
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom connector").font(.system(size: 16, weight: .bold))
            TextField("Name", text: $name).settingsField()
            Picker("", selection: $remote) {
                Text("Remote (HTTP)").tag(true)
                Text("Command on this Mac").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            if remote {
                TextField("https://example.com/mcp", text: $url).settingsField()
                Picker("Sign-in", selection: $authKind) {
                    Text("None").tag(0)
                    Text("Browser sign-in").tag(1)
                    Text("API key").tag(2)
                }
                .frame(width: 260)
                if authKind == 2 { SecureField("API key (sent as Bearer token)", text: $token).settingsField() }
            } else {
                TextField("Command, e.g. npx", text: $command).settingsField()
                TextField("Arguments, e.g. -y some-mcp-server", text: $argsText).settingsField()
            }
            HStack {
                Spacer()
                Button("Cancel", action: onDone).buttonStyle(ChipStyle())
                Button("Add") {
                    let store = ConnectorStore.shared
                    if remote {
                        let auth: ConnectorDefinition.Auth = authKind == 1 ? .browser
                            : authKind == 2 ? .token(header: "Authorization", prefix: "Bearer ", help: "") : .none
                        store.addCustom(name: name, transport: .http(url: url), auth: auth, secrets: authKind == 2 ? ["TOKEN": token] : [:])
                    } else {
                        let args = argsText.split(separator: " ").map(String.init)
                        store.addCustom(name: name, transport: .stdio(command: command, args: args), auth: .none, secrets: [:])
                    }
                    onDone()
                }
                .buttonStyle(GlassPillStyle(height: 28))
                .disabled(name.isEmpty || (remote ? !url.hasPrefix("http") : command.isEmpty))
            }
        }
        .padding(22).frame(width: 440).background(Theme.window).preferredColorScheme(.dark)
    }
}
