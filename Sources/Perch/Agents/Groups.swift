import AppKit
import SwiftUI

/// A group chat of several helpers working on one request together.
struct AgentGroup: Codable, Identifiable, Equatable {
    struct Post: Codable, Identifiable, Equatable {
        enum Kind: String, Codable { case user, assignment, note }
        var id = UUID()
        var date = Date()
        var kind: Kind
        var text: String
        var agent: String?      // slug for assignments
        var turnID: UUID?       // the helper turn doing this part
    }
    var id = UUID()
    var name: String
    var members: [String]
    var posts: [Post] = []
    var updated = Date()
}

@MainActor
final class GroupStore: ObservableObject {
    static let shared = GroupStore()
    @Published private(set) var groups: [AgentGroup] = []
    @Published var planning: Set<UUID> = []

    private let url = AgentPaths.root.appendingPathComponent("groups.json")

    init() {
        if let data = try? Data(contentsOf: url), let g = try? JSONDecoder().decode([AgentGroup].self, from: data) { groups = g }
    }

    func group(_ id: UUID) -> AgentGroup? { groups.first { $0.id == id } }

    @discardableResult
    func create(name: String, members: [String]) -> AgentGroup {
        let g = AgentGroup(name: name.isEmpty ? "Squad" : name, members: members)
        groups.insert(g, at: 0)
        save()
        return g
    }

    func delete(_ id: UUID) {
        groups.removeAll { $0.id == id }
        save()
    }

    private func mutate(_ id: UUID, _ change: (inout AgentGroup) -> Void) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        change(&groups[i])
        groups[i].updated = Date()
        save()
    }

    /// Posts the user's message, splits the work among members, and starts each helper.
    func send(_ text: String, to id: UUID) {
        guard let group = group(id) else { return }
        mutate(id) { $0.posts.append(.init(kind: .user, text: text)) }
        let roster = AgentRoster.shared
        let members = group.members.compactMap { roster.agent($0) }
        guard !members.isEmpty else { return }

        // @mentions pick helpers directly.
        let mentioned = members.filter { text.localizedCaseInsensitiveContains("@\($0.name)") || text.localizedCaseInsensitiveContains("@\($0.id)") }
        if !mentioned.isEmpty {
            assign(mentioned.map { ($0.id, text) }, in: id)
            return
        }
        planning.insert(id)
        Task {
            let plan = await Coordinator.split(text, among: members)
            planning.remove(id)
            assign(plan.isEmpty ? [(members[0].id, text)] : plan, in: id)
        }
    }

    private func assign(_ plan: [(slug: String, task: String)], in id: UUID) {
        guard let group = group(id) else { return }
        let roster = AgentRoster.shared
        let summary = plan.compactMap { p in roster.agent(p.slug).map { "- \($0.name): \(p.task)" } }.joined(separator: "\n")
        for p in plan {
            guard let agent = roster.agent(p.slug) else { continue }
            let context = """
            You're working in the group chat "\(group.name)" with other helpers. The user's request was split like this:
            \(summary)
            Do only your part. Others are doing theirs at the same time.
            """
            let turnID = AgentManager.shared.launch(slug: agent.id, prompt: p.task, context: context)
            mutate(id) { $0.posts.append(.init(kind: .assignment, text: p.task, agent: agent.id, turnID: turnID)) }
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: AgentPaths.root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.pretty.encode(groups) { try? data.write(to: url, options: .atomic) }
    }
}

/// Uses the buddy's AI model to split a request among helpers.
@MainActor
enum Coordinator {
    static func split(_ request: String, among members: [BuddyAgent]) async -> [(slug: String, task: String)] {
        let settings = AppSettings.shared
        let roster = members.map { "- \($0.id): \($0.name), \($0.role). \($0.oneLiner)" }.joined(separator: "\n")
        let prompt = """
        Split this request among the helpers below so each does a distinct, self-contained part that plays to their role.
        Not every helper needs a part. Reply with JSON only: [{"slug": "...", "task": "..."}]

        Helpers:
        \(roster)

        Request: \(request)
        """
        let client = LLMClient(provider: settings.provider, apiKey: settings.activeKey, model: settings.activeModel)
        var out = ""
        do {
            for try await chunk in client.stream(system: "You plan work for a small team. Output JSON only.", history: [], prompt: prompt, screens: []) {
                out += chunk
            }
        } catch { return [] }
        guard let start = out.firstIndex(of: "["), let end = out.lastIndex(of: "]"),
              let data = String(out[start...end]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let valid = Set(members.map(\.id))
        return arr.compactMap { item in
            guard let slug = item["slug"] as? String, valid.contains(slug), let task = item["task"] as? String else { return nil }
            return (slug, task)
        }
    }
}

// MARK: Views

struct GroupAvatar: View {
    let members: [BuddyAgent]
    var size: CGFloat = 30
    var body: some View {
        ZStack {
            ForEach(Array(members.prefix(3).enumerated()), id: \.element.id) { i, a in
                AgentAvatar(agent: a, size: size * 0.66)
                    .offset(x: CGFloat(i - 1) * size * 0.22, y: i == 1 ? -size * 0.14 : size * 0.1)
            }
        }
        .frame(width: size, height: size)
    }
}

struct GroupRow: View {
    let group: AgentGroup
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let members = group.members.compactMap { AgentRoster.shared.agent($0) }
        HStack(spacing: 10) {
            GroupAvatar(members: members, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(members.map(\.name).joined(separator: ", ")).font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(selected ? Color.black.opacity(0.6) : Theme.textSecondary)
            }
            Spacer()
        }
        .foregroundStyle(selected ? Color.black : Theme.textPrimary)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(selected ? AnyShapeStyle(Theme.userBubble) : AnyShapeStyle(hovering ? Theme.hover : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct GroupChatView: View {
    let group: AgentGroup
    @ObservedObject var store = GroupStore.shared
    @ObservedObject var manager = AgentManager.shared
    @State private var text = ""

    var body: some View {
        let members = group.members.compactMap { AgentRoster.shared.agent($0) }
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                GroupAvatar(members: members, size: 38)
                Text(group.name).font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4).background(Capsule().fill(Theme.card))
            }
            .padding(.top, 44).padding(.bottom, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        MessageBubble(message: Message(role: .assistant,
                            text: "Squad assembled: \(members.map(\.name).joined(separator: ", ")). Tell us what you need, I'll split it up. Use @Name to pick someone."), dimmed: true)
                        ForEach(group.posts) { post in postView(post).id(post.id) }
                        if store.planning.contains(group.id) {
                            HStack(spacing: 8) { TypingDots(); Text("Splitting up the work…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 28).padding(.vertical, 8)
                }
                .onChange(of: group.posts.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
                .onAppear { proxy.scrollTo("bottom") }
            }

            HStack(spacing: 8) {
                Image(systemName: "keyboard").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                TextField("Message the squad…  (@Name to pick)", text: $text)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .onSubmit {
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        text = ""
                        NSSound(named: "Tink")?.play()
                        store.send(t, to: group.id)
                    }
            }
            .padding(.horizontal, 14).frame(height: 38)
            .background(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
            .padding(.horizontal, 22).padding(.bottom, 16)
        }
    }

    @ViewBuilder private func postView(_ post: AgentGroup.Post) -> some View {
        switch post.kind {
        case .user:
            MessageBubble(message: Message(role: .user, text: post.text))
        case .note:
            Text(post.text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        case .assignment:
            if let slug = post.agent, let agent = AgentRoster.shared.agent(slug) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        AgentAvatar(agent: agent, size: 24, working: manager.running.contains(slug))
                        Text(agent.name).font(.system(size: 12, weight: .semibold))
                        Text("· \(post.text)").font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    }
                    if let id = post.turnID, let turn = manager.turns[slug]?.first(where: { $0.id == id }) {
                        AgentTurnView(agent: agent, turn: turn, showPrompt: false)
                            .padding(.leading, 32)
                    }
                }
            }
        }
    }
}

struct NewGroupSheet: View {
    var onDone: (AgentGroup?) -> Void
    @ObservedObject var roster = AgentRoster.shared
    @State private var name = ""
    @State private var picked: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New squad").font(.system(size: 16, weight: .bold))
            Text("Pick a few helpers. Send one message and Perch splits the work.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            TextField("Squad name (e.g. Launch Team)", text: $name).settingsField()
            VStack(spacing: 4) {
                ForEach(roster.agents.filter { !$0.archived }) { a in
                    HStack(spacing: 10) {
                        AgentAvatar(agent: a, size: 26)
                        Text(a.name).font(.system(size: 12.5, weight: .medium))
                        Text(a.role).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Image(systemName: picked.contains(a.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(picked.contains(a.id) ? Theme.accent : Theme.textTertiary)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                    .contentShape(Rectangle())
                    .onTapGesture { if picked.contains(a.id) { picked.remove(a.id) } else { picked.insert(a.id) } }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }.buttonStyle(ChipStyle())
                Button("Create") { onDone(GroupStore.shared.create(name: name, members: Array(picked))) }
                    .buttonStyle(GlassPillStyle(height: 28))
                    .disabled(picked.count < 2)
            }
        }
        .padding(22).frame(width: 420).background(Theme.window).preferredColorScheme(.dark)
    }
}
