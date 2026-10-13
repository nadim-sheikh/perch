import Foundation
import SwiftUI

/// Where agents, skills and connectors live: a visible folder in the user's home.
enum AgentPaths {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Perch", isDirectory: true)
    static let agents = root.appendingPathComponent("Agents", isDirectory: true)
    static let memory = root.appendingPathComponent("Memory", isDirectory: true)
}

enum AgentAccessLevel: String, Codable, CaseIterable, Identifiable {
    case askFirst, fullAccess
    var id: String { rawValue }
    var title: String { self == .askFirst ? "Safe" : "Full access" }
    var detail: String {
        self == .askFirst
            ? "Can edit files in its folder, browse the web and run common dev tools. Riskier commands are blocked."
            : "Can run any command on your Mac without asking. Only use for helpers you trust."
    }
}

/// A named, persistent background helper with its own folder and memory.
struct BuddyAgent: Codable, Identifiable, Hashable {
    var id: String              // slug, e.g. "shippy"
    var name: String
    var role: String
    var oneLiner: String
    var hue: Double
    var suggestedAsks: [String] = []
    var sessionID: String?
    /// Kept in `AgentAccessStore`, never in agent.json, which the helper itself can edit.
    var accessLevel: AgentAccessLevel = .askFirst
    var createdAt = Date()
    var archived = false

    private enum CodingKeys: String, CodingKey {
        case id, name, role, oneLiner, hue, suggestedAsks, sessionID, createdAt, archived
    }

    var folder: URL { AgentPaths.agents.appendingPathComponent(id, isDirectory: true) }
    var outputFolder: URL { folder.appendingPathComponent("output", isDirectory: true) }
    var tmpFolder: URL { folder.appendingPathComponent("tmp", isDirectory: true) }
    var metaFolder: URL { folder.appendingPathComponent(".perch", isDirectory: true) }
    var tint: Color { Color(hue: hue, saturation: 0.45, brightness: 0.95) }
    var backdrop: Color { Color(hue: hue, saturation: 0.18, brightness: 1.0) }
}

/// One step the agent took (a tool call), shown as a friendly row.
struct AgentStep: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case edit, command, web, read, search, plan, app, helper, other }
    var id: String
    var kind: Kind
    var present: String     // "Editing index.html"
    var past: String        // "Edited index.html"
    var detail: String?     // command text, URL, etc.
    var done = false
    var isError = false
}

enum AgentTurnState: String, Codable { case queued, working, finished, failed, stopped }

/// One request to an agent and everything that happened while doing it.
struct AgentTurn: Codable, Identifiable, Equatable {
    var id = UUID()
    var prompt: String
    var startedAt = Date()
    var finishedAt: Date?
    var state: AgentTurnState = .working
    var steps: [AgentStep] = []
    var progress: [String] = []
    var liveText = ""
    var reply = ""
    var summary: String?
    var title: String?
    var nextActions: [String] = []
    var artifacts: [String] = []
    var error: String?
    var costUSD: Double?
    /// Extra instructions sent with the prompt (e.g. a squad's split), reused by Retry.
    var context: String?
    /// The request came with a screenshot.
    var hadScreenshot: Bool?
    /// It stopped at the step limit; Continue picks up where it left off.
    var canContinue: Bool?

    var duration: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }
}

/// The roster of agents, persisted per agent in `.perch/agent.json`.
@MainActor
final class AgentRoster: ObservableObject {
    static let shared = AgentRoster()
    @Published private(set) var agents: [BuddyAgent] = []

    init() {
        load()
        if agents.isEmpty {
            for a in Self.starterCast { _ = try? found(a) }
        }
    }

    static let starterCast: [BuddyAgent] = [
        BuddyAgent(id: "shippy", name: "Shippy", role: "Web builder",
                   oneLiner: "Builds websites, landing pages and small web apps, then opens them for you.",
                   hue: 0.72, suggestedAsks: ["Make me a portfolio site", "Build a landing page for my product"]),
        BuddyAgent(id: "research-buddy", name: "Research Buddy", role: "Researcher",
                   oneLiner: "Digs into any topic on the web and writes a clear, sourced report.",
                   hue: 0.07, suggestedAsks: ["Research the best mics under $200", "Summarise today's AI news"]),
    ]

    func agent(_ slug: String) -> BuddyAgent? { agents.first { $0.id == slug } }

    /// Creates the agent's folder, notes and metadata.
    @discardableResult
    func found(_ agent: BuddyAgent) throws -> BuddyAgent {
        let fm = FileManager.default
        for dir in [agent.folder, agent.outputFolder, agent.tmpFolder, agent.metaFolder] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let notes = agent.folder.appendingPathComponent("AGENTS.md")
        if !fm.fileExists(atPath: notes.path) {
            try Self.notesTemplate(agent).write(to: notes, atomically: true, encoding: .utf8)
        }
        save(agent)
        if let i = agents.firstIndex(where: { $0.id == agent.id }) { agents[i] = agent } else { agents.append(agent) }
        return agent
    }

    func create(name: String, role: String, oneLiner: String) throws -> BuddyAgent {
        var slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0 + String($1) }
        slug = slug.split(separator: "-").joined(separator: "-")
        if slug.isEmpty { slug = "helper" }
        var unique = slug, n = 2
        while agent(unique) != nil { unique = "\(slug)-\(n)"; n += 1 }
        let hue = Double(abs(unique.hashValue % 1000)) / 1000
        return try found(BuddyAgent(id: unique, name: name, role: role, oneLiner: oneLiner, hue: hue))
    }

    func update(_ agent: BuddyAgent) {
        save(agent)
        if let i = agents.firstIndex(where: { $0.id == agent.id }) { agents[i] = agent }
    }

    /// Moves the helper's folder to the Trash and forgets it.
    func delete(_ slug: String) {
        guard let a = agent(slug) else { return }
        try? FileManager.default.trashItem(at: a.folder, resultingItemURL: nil)
        AgentAccessStore.remove(slug)
        agents.removeAll { $0.id == slug }
    }

    /// Archiving stops the helper's work and clears its badge.
    func setArchived(_ slug: String, _ archived: Bool) {
        guard var a = agent(slug) else { return }
        if archived {
            AgentManager.shared.stop(slug)
            AgentManager.shared.clearUnread(slug)
        }
        a.archived = archived
        update(a)
    }

    private func save(_ agent: BuddyAgent) {
        AgentAccessStore.set(agent.accessLevel, for: agent.id)
        let url = agent.metaFolder.appendingPathComponent("agent.json")
        try? FileManager.default.createDirectory(at: agent.metaFolder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.pretty.encode(agent) { try? data.write(to: url, options: .atomic) }
    }

    private func load() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: AgentPaths.agents, includingPropertiesForKeys: nil) else { return }
        // Access levels used to live in agent.json. Move them out once; after that the file's value is ignored.
        struct LegacyAccess: Decodable { var accessLevel: AgentAccessLevel? }
        let migrate = !AgentAccessStore.migrated
        agents = dirs.compactMap { dir in
            let url = dir.appendingPathComponent(".perch/agent.json")
            guard let data = try? Data(contentsOf: url), var agent = try? JSONDecoder().decode(BuddyAgent.self, from: data) else { return nil }
            if migrate {
                agent.accessLevel = (try? JSONDecoder().decode(LegacyAccess.self, from: data))?.accessLevel ?? .askFirst
                save(agent)
            } else {
                agent.accessLevel = AgentAccessStore.level(for: agent.id)
            }
            return agent
        }
        .sorted { $0.createdAt < $1.createdAt }
        AgentAccessStore.migrated = true
    }

    private static func notesTemplate(_ a: BuddyAgent) -> String {
        """
        # \(a.name)

        You are \(a.name), one of the user's Perch helpers. Your job: \(a.oneLiner)
        This folder is your home. Your notes live in this file and everything you make goes here.
        The user comes back to you over time, so keep what you learn.

        ## Identity
        - Name: \(a.name)
        - Role: \(a.role)
        - Voice: first person, friendly, consistent.

        ## Standing preferences
        (One line each. Things the user told you to always or never do.)

        ## Notes
        (Your memory. When you learn something lasting about this job, add it here with
        today's date and remove anything outdated. Never write passwords, tokens or keys here.)

        """
    }
}

/// Each helper's access level, kept in Perch's preferences where helpers' file and shell tools can't change it.
enum AgentAccessStore {
    private static let migratedKey = "agentAccessMigrated"
    private static func key(_ slug: String) -> String { "agentAccess.\(slug)" }

    static var migrated: Bool {
        get { UserDefaults.standard.bool(forKey: migratedKey) }
        set { UserDefaults.standard.set(newValue, forKey: migratedKey) }
    }

    static func level(for slug: String) -> AgentAccessLevel {
        UserDefaults.standard.string(forKey: key(slug)).flatMap(AgentAccessLevel.init(rawValue:)) ?? .askFirst
    }

    static func set(_ level: AgentAccessLevel, for slug: String) { UserDefaults.standard.set(level.rawValue, forKey: key(slug)) }

    static func remove(_ slug: String) { UserDefaults.standard.removeObject(forKey: key(slug)) }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
