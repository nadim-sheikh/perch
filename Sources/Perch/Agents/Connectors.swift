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
        case browser                 // OAuth sign-in in the browser (helpers can't use it yet: shown as Coming soon)
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
    var domain: String? { ConnectorCatalog.domains[id] }

    /// Helpers can start this connector themselves (no browser sign-in needed).
    var usableByAgents: Bool { auth != .browser }
}

enum ConnectorCatalog {
    /// Each service's own website, used to load its real logo.
    static let domains: [String: String] = [
        "notion": "notion.so", "linear": "linear.app", "atlassian": "atlassian.com", "asana": "asana.com",
        "todoist": "todoist.com", "slack": "slack.com", "hubspot": "hubspot.com", "figma": "figma.com",
        "canva": "canva.com", "github": "github.com", "vercel": "vercel.com", "supabase": "supabase.com",
        "sentry": "sentry.io", "stripe": "stripe.com", "google-workspace": "workspace.google.com", "airtable": "airtable.com",
    ]

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

    enum Status: Equatable { case unknown, checking, connected, failed(String) }

    @Published private(set) var enabled: [ConnectorDefinition] = []
    @Published var status: [String: Status] = [:]
    /// Bumped on every check, connect and disconnect, so an older check can't overwrite newer status.
    private var checkGeneration: [String: Int] = [:]

    nonisolated static let folder = AgentPaths.root.appendingPathComponent("Connectors", isDirectory: true)
    private let saveURL = folder.appendingPathComponent("connectors.json")
    static let browserSignInNote = "Needs a browser sign-in, which helpers can't use yet. Disconnect it for now."

    init() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: saveURL), let list = try? JSONDecoder().decode([ConnectorDefinition].self, from: data) {
            enabled = list
        }
        migrateCustomIDs()
    }

    func isEnabled(_ id: String) -> Bool { enabled.contains { $0.id == id } }

    /// Adds the connector (or updates its secrets), then checks that it really answers.
    /// Secrets go to the Keychain; helpers start the server when they run.
    func connect(_ def: ConnectorDefinition, secrets: [String: String] = [:]) {
        guard def.usableByAgents else { return }
        for (k, v) in secrets {
            Keychain.set(v.trimmingCharacters(in: .whitespacesAndNewlines), for: "connector.\(def.id).\(k)")
        }
        if !isEnabled(def.id) { enabled.append(def) }
        persist()
        check(def)
    }

    func disconnect(_ def: ConnectorDefinition) {
        enabled.removeAll { $0.id == def.id }
        status[def.id] = nil
        checkGeneration[def.id, default: 0] += 1
        MCPPool.shared.drop(def.id)
        persist()
        for name in secretNames(def) { Keychain.set("", for: "connector.\(def.id).\(name)") }
    }

    /// Adds a custom connector. Its id is ASCII-only (it becomes part of tool names) and unique.
    func addCustom(name: String, transport: ConnectorDefinition.Transport, auth: ConnectorDefinition.Auth, secrets: [String: String]) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let def = ConnectorDefinition(id: uniqueID(for: name), name: name, category: "Custom", symbol: "puzzlepiece.extension",
                                      colorHex: "#64748B", blurb: "Your custom connector.", transport: transport, auth: auth, isCustom: true)
        connect(def, secrets: secrets)
    }

    /// "custom-" plus the name's ASCII letters and digits (or a short hash when there are none), made unique.
    private func uniqueID(for name: String) -> String {
        var slug = String(name.lowercased().unicodeScalars.map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? Character($0) : "-" })
        slug = slug.split(separator: "-").joined(separator: "-")
        if slug.isEmpty { slug = Self.shortHash(name) }
        let base = "custom-" + String(slug.prefix(32))
        var id = base
        var n = 2
        while isEnabled(id) || ConnectorCatalog.all.contains(where: { $0.id == id }) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }

    /// Six hex digits from the name (FNV-1a), stable across launches.
    private static func shortHash(_ text: String) -> String {
        var h: UInt32 = 2_166_136_261
        for b in text.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return String(format: "%06x", h & 0xFFFFFF)
    }

    /// Older builds made ids from any letters (e.g. "custom-café"), which breaks tool names. Rename them
    /// and move their secrets.
    private func migrateCustomIDs() {
        var changed = false
        for i in enabled.indices where enabled[i].isCustom {
            let old = enabled[i]
            guard old.id.unicodeScalars.contains(where: { !(("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-") }) else { continue }
            let newID = uniqueID(for: old.name)
            for name in secretNames(old) {
                let value = Keychain.get("connector.\(old.id).\(name)")
                Keychain.set(value, for: "connector.\(newID).\(name)")
                Keychain.set("", for: "connector.\(old.id).\(name)")
            }
            enabled[i].id = newID
            changed = true
        }
        if changed { persist() }
    }

    /// Checks that each connector answers. This also warms them up for helpers.
    func refreshStatus() {
        for def in enabled { check(def) }
    }

    /// Shows "Checking…" until the connector answers or fails. Results for a connector that was
    /// disconnected, reconnected or re-checked meanwhile are dropped.
    private func check(_ def: ConnectorDefinition) {
        checkGeneration[def.id, default: 0] += 1
        guard def.usableByAgents else { status[def.id] = nil; return }
        let generation = checkGeneration[def.id]
        status[def.id] = .checking
        Task {
            let (ready, problems) = await MCPPool.shared.connections(for: [def], wait: 60)
            guard checkGeneration[def.id] == generation, isEnabled(def.id) else { return }
            status[def.id] = ready.isEmpty ? .failed(String((problems.first ?? "No answer").prefix(160))) : .connected
        }
    }

    /// Secret values for one connector, by name (e.g. TOKEN or an env var name).
    func secrets(for def: ConnectorDefinition) -> [String: String] {
        var out: [String: String] = [:]
        for name in secretNames(def) {
            let v = Keychain.get("connector.\(def.id).\(name)")
            if !v.isEmpty { out[name] = v }
        }
        return out
    }

    private func secretNames(_ def: ConnectorDefinition) -> [String] {
        switch def.auth {
        case .token: return ["TOKEN"]
        case .env(let names, _): return names
        default: return []
        }
    }

    private func persist() {
        if let data = try? JSONEncoder.pretty.encode(enabled) { try? data.write(to: saveURL, options: .atomic) }
    }
}
