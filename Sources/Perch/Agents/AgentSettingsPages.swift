import AppKit
import SwiftUI

struct AgentsSettingsPage: View {
    @ObservedObject var roster = AgentRoster.shared
    @ObservedObject var settings = AppSettings.shared
    @AppStorage("agentSounds") private var sounds = true
    @AppStorage("speakAgentUpdates") private var speak = true

    var body: some View {
        SettingsGroup(title: "Engine") {
            SettingsRow(title: "OpenRouter", subtitle: settings.openrouterKey.isEmpty
                        ? "Helpers run on your OpenRouter key. Add it in AI Models first."
                        : "Helpers run on your OpenRouter key.") {
                KeyStatusLabel()
            }
            SettingsRow(title: "Model", subtitle: "Every helper, and the buddy, use the same model.", last: true) {
                Text(PerchModel.name).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }

        SettingsGroup(title: "Updates") {
            SettingsRow(title: "Sounds", subtitle: nil) {
                Toggle("", isOn: $sounds).toggleStyle(GlassToggleStyle())
            }
            SettingsRow(title: "Speak updates", subtitle: nil, last: true) {
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
            Button { HomeRouter.shared.settings = nil; HomeRouter.shared.showNewGroup = true } label: { Label("New squad", systemImage: "person.3") }
                .buttonStyle(ChipStyle())
            Button { NSWorkspace.shared.open(AgentPaths.agents) } label: { Label("Open helpers folder", systemImage: "folder") }
                .buttonStyle(ChipStyle())
        }
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
                Button {
                    let alert = NSAlert()
                    alert.messageText = "Delete \(agent.name)?"
                    alert.informativeText = "Their folder and memory go to the Trash."
                    alert.addButton(withTitle: "Delete")
                    alert.addButton(withTitle: "Cancel")
                    alert.window.level = .statusBar + 3
                    if alert.runModal() == .alertFirstButtonReturn { AgentManager.shared.delete(agent.id) }
                } label: { Image(systemName: "trash") }
                .buttonStyle(IconButtonStyle())
                .help("Delete")
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

    /// Apps helpers can use come first; "Coming soon" ones follow.
    private var catalog: [ConnectorDefinition] {
        let matches = ConnectorCatalog.all.filter { def in
            !store.isEnabled(def.id)
                && (category == "All" || def.category == category)
                && (search.isEmpty || def.name.lowercased().contains(search.lowercased()))
        }
        return matches.filter(\.usableByAgents) + matches.filter { !$0.usableByAgents }
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
                            ConnectorLogo(def: def, size: 22)
                            if hasSecrets(def) {
                                Button(tokenLabel(def)) { secretSheet = def }.buttonStyle(ChipStyle())
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
                    if hasSecrets(def) { secretSheet = def } else { store.connect(def) }
                }
            }
            CustomConnectorCard { showCustom = true }
        }

        Text("Tokens stay in your Keychain. Apps marked Coming soon need a browser sign-in, which helpers can't use yet.")
            .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            .onAppear { store.refreshStatus() }
            .sheet(item: $secretSheet) { def in SecretSheet(def: def) { secretSheet = nil } }
            .sheet(isPresented: $showCustom) { CustomConnectorSheet { showCustom = false } }
    }

    private func statusText(_ def: ConnectorDefinition) -> String {
        guard def.usableByAgents else { return ConnectorStore.browserSignInNote }
        switch store.status[def.id] ?? .unknown {
        case .connected: return "Connected"
        case .checking: return "Checking…"
        case .failed(let m): return "Problem: \(m)"
        case .unknown: return def.blurb
        }
    }

    private func hasSecrets(_ def: ConnectorDefinition) -> Bool {
        switch def.auth {
        case .token, .env: return true
        case .none, .browser: return false
        }
    }

    private func tokenLabel(_ def: ConnectorDefinition) -> String {
        if case .env(let names, _) = def.auth, names.count > 1 { return "Change keys" }
        return "Change token"
    }
}

private struct ConnectorCard: View {
    let def: ConnectorDefinition
    let onConnect: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ConnectorLogo(def: def, size: 32)
                Spacer()
                if def.usableByAgents {
                    Button("Connect", action: onConnect).buttonStyle(ChipStyle(light: true))
                } else {
                    Text("Coming soon").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary)
                        .help("Needs a browser sign-in, which helpers can't use yet.")
                }
            }
            Text(def.name).font(.system(size: 12.5, weight: .semibold))
            Text(def.blurb).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(hovering ? Theme.hover : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardStroke))
        .opacity(def.usableByAgents ? 1 : 0.55)
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0 && def.usableByAgents }
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
            Text(ConnectorStore.shared.isEnabled(def.id) ? "Change \(def.name) token" : "Connect \(def.name)")
                .font(.system(size: 16, weight: .bold))
            Text(help).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            ForEach(names, id: \.self) { n in
                SecureField(n == "TOKEN" ? "Token" : n, text: Binding(get: { values[n] ?? "" }, set: { values[n] = $0 }))
                    .settingsField()
            }
            HStack {
                Spacer()
                Button("Cancel", action: onDone).buttonStyle(ChipStyle())
                Button(ConnectorStore.shared.isEnabled(def.id) ? "Save" : "Connect") {
                    ConnectorStore.shared.connect(def, secrets: values)
                    onDone()
                }
                .buttonStyle(GlassPillStyle(height: 28))
                .disabled(names.contains { (values[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
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
    @State private var useToken = false
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
                Picker("Sign-in", selection: $useToken) {
                    Text("None").tag(false)
                    Text("API key").tag(true)
                }
                .frame(width: 260)
                if useToken { SecureField("API key (sent as Bearer token)", text: $token).settingsField() }
            } else {
                TextField("Command, e.g. npx", text: $command).settingsField()
                TextField("Arguments, e.g. -y some-mcp-server \"my folder\"", text: $argsText).settingsField()
            }
            HStack {
                Spacer()
                Button("Cancel", action: onDone).buttonStyle(ChipStyle())
                Button("Add") {
                    let store = ConnectorStore.shared
                    if remote {
                        let auth: ConnectorDefinition.Auth = useToken ? .token(header: "Authorization", prefix: "Bearer ", help: "") : .none
                        store.addCustom(name: name, transport: .http(url: url.trimmingCharacters(in: .whitespaces)), auth: auth,
                                        secrets: useToken ? ["TOKEN": token] : [:])
                    } else {
                        store.addCustom(name: name, transport: .stdio(command: command.trimmingCharacters(in: .whitespaces),
                                                                      args: Self.splitArguments(argsText)),
                                        auth: .none, secrets: [:])
                    }
                    onDone()
                }
                .buttonStyle(GlassPillStyle(height: 28))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || (remote ? !url.hasPrefix("http") || (useToken && token.isEmpty) : command.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(22).frame(width: 440).background(Theme.window).preferredColorScheme(.dark)
    }

    /// Splits arguments like a shell does: spaces separate them, quotes ('…' or "…") keep spaces,
    /// and a backslash escapes the next character (except inside single quotes).
    static func splitArguments(_ text: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inArg = false
        var quote: Character?
        var escaped = false
        for c in text {
            if escaped { current.append(c); escaped = false; inArg = true; continue }
            if c == "\\" && quote != "'" { escaped = true; inArg = true; continue }
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
                continue
            }
            if c == "'" || c == "\"" { quote = c; inArg = true; continue }
            if c.isWhitespace {
                if inArg { args.append(current); current = ""; inArg = false }
                continue
            }
            current.append(c)
            inArg = true
        }
        if escaped { current.append("\\") }
        if inArg { args.append(current) }
        return args
    }
}
