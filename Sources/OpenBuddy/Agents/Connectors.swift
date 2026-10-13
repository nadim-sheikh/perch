import AppKit
import Foundation

/// A connectable app: an MCP server your helpers can use.
struct ConnectorDefinition: Identifiable, Hashable, Codable {
    enum Transport: Hashable, Codable {
        case http(url: String)
        case stdio(command: String, args: [String])
    }
    enum Auth: Hashable, Codable {
        case none
        case browser                 // Claude Code runs the OAuth sign-in
        case token(header: String, prefix: String, help: String)   // API key / personal token
        case env(names: [String], help: String)                     // env vars for a local server
    }

    var id: String               // also the MCP server name
    var name: String
    var category: String
    var symbol: String
    var colorHex: String
    var blurb: String
    var transport: Transport
    var auth: Auth
    var useCases: [String] = []
    var isCustom = false
}

enum ConnectorCatalog {
    static let all: [ConnectorDefinition] = [
        .init(id: "notion", name: "Notion", category: "Docs", symbol: "doc.richtext", colorHex: "#2F3437",
              blurb: "Read and write pages and databases.", transport: .http(url: "https://mcp.notion.com/mcp"), auth: .browser,
              useCases: ["Summarise my meeting notes page", "Add a row to my reading list"]),
        .init(id: "linear", name: "Linear", category: "Projects", symbol: "checklist", colorHex: "#5E6AD2",
              blurb: "Triage issues and plan cycles.", transport: .http(url: "https://mcp.linear.app/mcp"), auth: .browser,
              useCases: ["What's assigned to me?", "File a bug for this"]),
        .init(id: "atlassian", name: "Jira & Confluence", category: "Projects", symbol: "ticket", colorHex: "#0C66E4",
              blurb: "Search tickets and wiki pages.", transport: .http(url: "https://mcp.atlassian.com/v2/mcp"), auth: .browser),
        .init(id: "asana", name: "Asana", category: "Projects", symbol: "circle.hexagongrid", colorHex: "#F06A6A",
              blurb: "Tasks, projects and goals.", transport: .http(url: "https://mcp.asana.com/v2/mcp"), auth: .browser),
        .init(id: "todoist", name: "Todoist", category: "Projects", symbol: "checkmark.circle", colorHex: "#E44332",
              blurb: "Your to-do lists.", transport: .http(url: "https://ai.todoist.net/mcp"), auth: .browser),
        .init(id: "slack", name: "Slack", category: "Communication", symbol: "number", colorHex: "#4A154B",
              blurb: "Search and post in channels (needs workspace approval).", transport: .http(url: "https://mcp.slack.com/mcp"), auth: .browser),
        .init(id: "hubspot", name: "HubSpot", category: "CRM", symbol: "person.2.circle", colorHex: "#FF7A59",
              blurb: "Contacts, deals and companies.", transport: .http(url: "https://mcp.hubspot.com/anthropic"), auth: .browser),
        .init(id: "figma", name: "Figma", category: "Design", symbol: "paintpalette", colorHex: "#A259FF",
              blurb: "Read designs and components.", transport: .http(url: "https://mcp.figma.com/mcp"), auth: .browser),
        .init(id: "canva", name: "Canva", category: "Design", symbol: "scribble.variable", colorHex: "#00C4CC",
              blurb: "Find and create designs.", transport: .http(url: "https://mcp.canva.com/mcp"), auth: .browser),
        .init(id: "github", name: "GitHub", category: "Dev", symbol: "chevron.left.forwardslash.chevron.right", colorHex: "#24292F",
              blurb: "Repos, issues and pull requests.", transport: .http(url: "https://api.githubcopilot.com/mcp/"),
              auth: .token(header: "Authorization", prefix: "Bearer ", help: "Create a personal access token at github.com/settings/tokens")),
        .init(id: "vercel", name: "Vercel", category: "Dev", symbol: "triangle.fill", colorHex: "#000000",
              blurb: "Deployments and logs.", transport: .http(url: "https://mcp.vercel.com"), auth: .browser),
        .init(id: "supabase", name: "Supabase", category: "Dev", symbol: "cylinder.split.1x2", colorHex: "#3ECF8E",
              blurb: "Databases and edge functions.", transport: .http(url: "https://mcp.supabase.com/mcp"), auth: .browser),
        .init(id: "sentry", name: "Sentry", category: "Dev", symbol: "exclamationmark.triangle", colorHex: "#362D59",
              blurb: "Errors and performance issues.", transport: .http(url: "https://mcp.sentry.dev/mcp"), auth: .browser),
        .init(id: "stripe", name: "Stripe", category: "Finance", symbol: "creditcard", colorHex: "#635BFF",
              blurb: "Payments, customers and invoices.", transport: .http(url: "https://mcp.stripe.com"), auth: .browser),
        .init(id: "google-workspace", name: "Google Workspace", category: "Google", symbol: "envelope", colorHex: "#4285F4",
              blurb: "Gmail, Calendar, Drive, Docs and Sheets (runs on your Mac).",
              transport: .stdio(command: "uvx", args: ["workspace-mcp", "--tool-tier", "core"]),
              auth: .env(names: ["GOOGLE_OAUTH_CLIENT_ID", "GOOGLE_OAUTH_CLIENT_SECRET"],
                         help: "Create a Desktop OAuth client in Google Cloud Console (APIs & Services → Credentials) and paste its ID and secret. Needs uv installed.")),
        .init(id: "airtable", name: "Airtable", category: "Docs", symbol: "tablecells", colorHex: "#FCB400",
              blurb: "Bases, tables and records (runs on your Mac).",
              transport: .stdio(command: "npx", args: ["-y", "airtable-mcp-server"]),
              auth: .env(names: ["AIRTABLE_API_KEY"], help: "Create a personal access token at airtable.com/create/tokens")),
    ]
}

/// The user's connections, persisted without secrets (secrets live in Keychain).
@MainActor
final class ConnectorStore: ObservableObject {
    static let shared = ConnectorStore()

    enum Status: Equatable { case unknown, checking, connected, needsSignIn, failed(String) }

    @Published private(set) var enabled: [ConnectorDefinition] = []
    @Published var status: [String: Status] = [:]

    nonisolated static let folder = AgentPaths.root.appendingPathComponent("Connectors", isDirectory: true)
    /// Directory where servers are registered with Claude Code (local scope), so sign-ins persist.
    nonisolated static let mcpHome = folder.appendingPathComponent("MCPHome", isDirectory: true)
    private let saveURL = folder.appendingPathComponent("connectors.json")
    var configURL: URL { Self.folder.appendingPathComponent("mcp.json") }

    init() {
        try? FileManager.default.createDirectory(at: Self.mcpHome, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: saveURL), let list = try? JSONDecoder().decode([ConnectorDefinition].self, from: data) {
            enabled = list
        }
        writeConfig()
    }

    func isEnabled(_ id: String) -> Bool { enabled.contains { $0.id == id } }

    /// Adds the connector and, for browser sign-in servers, opens a Terminal window to sign in.
    func connect(_ def: ConnectorDefinition, secrets: [String: String] = [:]) {
        for (k, v) in secrets { Keychain.set(v, for: "connector.\(def.id).\(k)") }
        if !isEnabled(def.id) { enabled.append(def) }
        persist()
        writeConfig()
        switch def.auth {
        case .browser:
            if case .http(let url) = def.transport {
                status[def.id] = .needsSignIn
                runInTerminal(title: "Connect \(def.name)", commands: [
                    "claude mcp remove -s local \(def.id) >/dev/null 2>&1",
                    "claude mcp add -s local -t http \(def.id) \(url)",
                    "echo; echo 'Signing in to \(def.name)… finish in your browser.'",
                    "claude mcp login \(def.id)",
                    "echo; echo 'Done! You can close this window and go back to OpenBuddy.'",
                ])
            }
        default:
            status[def.id] = .connected
        }
    }

    func signInAgain(_ def: ConnectorDefinition) { connect(def) }

    func disconnect(_ def: ConnectorDefinition) {
        enabled.removeAll { $0.id == def.id }
        status[def.id] = nil
        persist()
        writeConfig()
        if case .browser = def.auth {
            let cli = ClaudeCodeRun.locateCLI() ?? "claude"
            Task.detached {
                _ = Self.shell([cli, "mcp", "logout", def.id])
                _ = Self.shell([cli, "mcp", "remove", "-s", "local", def.id])
            }
        }
        for name in secretNames(def) { Keychain.set("", for: "connector.\(def.id).\(name)") }
    }

    func addCustom(name: String, transport: ConnectorDefinition.Transport, auth: ConnectorDefinition.Auth, secrets: [String: String]) {
        var slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0 + String($1) }
        slug = "custom-" + slug.split(separator: "-").joined(separator: "-")
        let def = ConnectorDefinition(id: slug, name: name, category: "Custom", symbol: "puzzlepiece.extension", colorHex: "#64748B",
                                      blurb: "Your custom connector.", transport: transport, auth: auth, isCustom: true)
        connect(def, secrets: secrets)
    }

    /// Asks Claude Code whether each browser sign-in server is authenticated.
    func refreshStatus() {
        guard let cli = ClaudeCodeRun.locateCLI() else { return }
        for def in enabled {
            guard case .browser = def.auth else { status[def.id] = .connected; continue }
            status[def.id] = .checking
            let id = def.id
            Task.detached {
                let out = Self.shell([cli, "mcp", "get", id], cwd: Self.mcpHome)
                let s: Status
                if out.contains("Connected") { s = .connected }
                else if out.lowercased().contains("auth") { s = .needsSignIn }
                else if out.contains("No MCP server") { s = .needsSignIn }
                else { s = .failed(String(out.suffix(160))) }
                await MainActor.run { ConnectorStore.shared.status[id] = s }
            }
        }
    }

    // MARK: Config for agent runs

    /// Writes the MCP config passed to `claude -p --mcp-config`. Secrets are `${VAR}` references
    /// resolved from the process environment, never written to disk.
    func writeConfig() {
        var servers: [String: Any] = [:]
        for def in enabled {
            switch def.transport {
            case .http(let url):
                var entry: [String: Any] = ["type": "http", "url": url]
                if case .token(let header, let prefix, _) = def.auth {
                    entry["headers"] = [header: "\(prefix)${\(envName(def, "TOKEN"))}"]
                }
                servers[def.id] = entry
            case .stdio(let command, let args):
                var entry: [String: Any] = ["type": "stdio", "command": command, "args": args]
                if case .env(let names, _) = def.auth {
                    entry["env"] = Dictionary(uniqueKeysWithValues: names.map { ($0, "${\(envName(def, $0))}") })
                }
                servers[def.id] = entry
            }
        }
        let json: [String: Any] = ["mcpServers": servers]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    /// Secret values for the agent process environment.
    func secretEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        for def in enabled {
            for name in secretNames(def) {
                let v = Keychain.get("connector.\(def.id).\(name)")
                if !v.isEmpty { env[envName(def, name)] = v }
            }
        }
        return env
    }

    /// Lines for the agent prompt describing what's connected.
    func promptSection() -> String {
        guard !enabled.isEmpty else { return "" }
        let names = enabled.map(\.name).joined(separator: ", ")
        return "\n\nCONNECTED APPS: \(names). Use their tools for the user's own data. If one fails because it isn't signed in, tell the user to reconnect it in OpenBuddy → Settings → Integrations. Never run sign-in commands yourself."
    }

    var allowedToolPatterns: [String] { enabled.map { "mcp__\($0.id)" } }

    private func secretNames(_ def: ConnectorDefinition) -> [String] {
        switch def.auth {
        case .token: return ["TOKEN"]
        case .env(let names, _): return names
        default: return []
        }
    }

    private func envName(_ def: ConnectorDefinition, _ name: String) -> String {
        "OB_" + (def.id + "_" + name).uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }.reduce("") { $0 + String($1) }
    }

    private func persist() {
        if let data = try? JSONEncoder.pretty.encode(enabled) { try? data.write(to: saveURL, options: .atomic) }
    }

    /// Opens Terminal with a small script, so sign-in happens somewhere the user can see.
    private func runInTerminal(title: String, commands: [String]) {
        let env = AgentSettings.environment()
        let script = """
        #!/bin/zsh
        export PATH="\(env["PATH"] ?? "")"
        cd "\(Self.mcpHome.path)"
        echo "\(title)"
        \(commands.joined(separator: "\n"))
        """
        let url = Self.folder.appendingPathComponent("connect.command")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    nonisolated static func shell(_ args: [String], cwd: URL? = nil) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        if let cwd { p.currentDirectoryURL = cwd }
        p.environment = AgentSettings.environment()
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return error.localizedDescription }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
