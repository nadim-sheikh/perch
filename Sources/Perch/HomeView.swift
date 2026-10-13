import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case ai = "AI Models"
    case voice = "Voice"
    case microphone = "Microphone"
    case dictation = "Dictation"
    case shortcuts = "Shortcuts"
    case cursor = "Cursor"
    case permissions = "Permissions"
    case agents = "Agents"
    case integrations = "Integrations"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .ai: return "sparkles"
        case .voice: return "waveform"
        case .microphone: return "mic.fill"
        case .dictation: return "character.cursor.ibeam"
        case .shortcuts: return "command"
        case .cursor: return "cursorarrow"
        case .permissions: return "lock.shield.fill"
        case .agents: return "circle.grid.cross.fill"
        case .integrations: return "puzzlepiece.extension.fill"
        }
    }

    var group: String {
        switch self {
        case .general, .ai, .permissions: return ""
        case .voice, .microphone, .dictation, .shortcuts, .cursor: return "BUDDY"
        case .agents, .integrations: return "WORK"
        }
    }
}

/// Which page the Home window shows.
@MainActor
final class HomeRouter: ObservableObject {
    static let shared = HomeRouter()
    @Published var settings: SettingsSection?
    @Published var search = ""
    /// Agent whose chat is open (takes priority over a buddy chat).
    @Published var selectedAgent: String?
    @Published var showNewAgent = false
    @Published var showNewGroup = false
    @Published var selectedGroup: UUID?

    func openGroup(_ id: UUID) {
        settings = nil
        selectedAgent = nil
        selectedGroup = id
    }

    func openAgent(_ slug: String) {
        settings = nil
        selectedGroup = nil
        selectedAgent = slug
        AgentManager.shared.clearUnread(slug)
    }

    func openChat(_ id: UUID?) {
        settings = nil
        selectedAgent = nil
        selectedGroup = nil
        ConversationStore.shared.selectedID = id
    }
}

struct HomeView: View {
    @ObservedObject var router = HomeRouter.shared
    @ObservedObject var store = ConversationStore.shared
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let section = router.settings {
                    SettingsSidebar(selection: section)
                } else {
                    HomeSidebar()
                }
            }
            .frame(width: 222)
            .background(Theme.sidebar)

            ZStack(alignment: .topTrailing) {
                Group {
                    if let section = router.settings {
                        SettingsPage(section: section)
                    } else if let gid = router.selectedGroup, let group = GroupStore.shared.group(gid) {
                        GroupChatView(group: group).id(gid)
                    } else if let slug = router.selectedAgent, let agent = AgentRoster.shared.agent(slug) {
                        AgentChatView(agent: agent).id(slug)
                    } else if let c = store.selected {
                        ConversationView(conversation: c)
                    } else {
                        HomeEmptyState()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle())
                    .padding(.top, 44).padding(.trailing, 16)
            }
            .background(Theme.window)
        }
        .overlay(alignment: .top) {
            // The top edge fades from black so Home reads as the notch opening up.
            LinearGradient(colors: [.black, .black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 80)
                .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $router.showNewGroup) {
            NewGroupSheet { group in
                router.showNewGroup = false
                if let group { router.openGroup(group.id) }
            }
        }
        .sheet(isPresented: $router.showNewAgent) {
            NewAgentSheet { agent in
                router.showNewAgent = false
                if let agent { router.openAgent(agent.id) }
            }
        }
    }
}

// MARK: Sidebar

struct HomeSidebar: View {
    @ObservedObject var router = HomeRouter.shared
    @ObservedObject var store = ConversationStore.shared
    @AppStorage("buddyName") private var buddyName = "Perch"

    @ObservedObject var roster = AgentRoster.shared
    @ObservedObject var agents = AgentManager.shared
    @ObservedObject var groups = GroupStore.shared

    private func confirmDelete(_ a: BuddyAgent) {
        let alert = NSAlert()
        alert.messageText = "Delete \(a.name)?"
        alert.informativeText = "Their folder and memory go to the Trash. Poof, like a cloud."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .statusBar + 3
        if alert.runModal() == .alertFirstButtonReturn {
            if router.selectedAgent == a.id { router.selectedAgent = nil }
            AgentManager.shared.delete(a.id)
        }
    }

    var filteredAgents: [BuddyAgent] {
        let q = router.search.trimmingCharacters(in: .whitespaces).lowercased()
        return roster.agents.filter { !$0.archived && (q.isEmpty || $0.name.lowercased().contains(q)) }
            .sorted { agents.lastActivity($0.id) > agents.lastActivity($1.id) }
    }

    var filtered: [Conversation] {
        let q = router.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.conversations }
        return store.conversations.filter { $0.title.lowercased().contains(q) || $0.preview.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                LogoGlyph().frame(width: 22, height: 14)
                Text("Perch").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.top, 52)
            .padding(.horizontal, 16)

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    TextField("Search", text: $router.search).textFieldStyle(.plain).font(.system(size: 12))
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))

                Menu {
                    Button("New chat") { router.openChat(store.newConversation()) }
                    Button("New helper…") { router.showNewAgent = true }
                    Button("New squad (group chat)…") { router.showNewGroup = true }
                } label: { Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                    .help("New chat or helper")
            }
            .padding(.horizontal, 12)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(groups.groups) { g in
                        GroupRow(group: g, selected: router.selectedGroup == g.id)
                            .onTapGesture { router.openGroup(g.id) }
                            .contextMenu { Button("Delete squad", role: .destructive) { groups.delete(g.id) } }
                    }
                    ForEach(filteredAgents) { a in
                        AgentRow(agent: a, selected: router.selectedAgent == a.id)
                            .onTapGesture { router.openAgent(a.id) }
                            .contextMenu {
                                Button("Open folder") { NSWorkspace.shared.open(a.folder) }
                                Button("Archive") { AgentRoster.shared.setArchived(a.id, true) }
                                Button("Delete…", role: .destructive) { confirmDelete(a) }
                            }
                    }
                    if !filtered.isEmpty {
                        Text("CHATS").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8).padding(.top, 10)
                    }
                    ForEach(filtered) { c in
                        ConversationRow(conversation: c, selected: router.selectedAgent == nil && c.id == store.selectedID)
                            .onTapGesture { router.openChat(c.id) }
                            .contextMenu {
                                Button("Delete", role: .destructive) { store.delete(c.id) }
                            }
                    }
                }
                .padding(.horizontal, 8)
            }

            Divider().overlay(Theme.cardStroke).padding(.horizontal, 12)

            HStack(spacing: 10) {
                MascotView(size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(buddyName).font(.system(size: 12, weight: .semibold))
                    Text("Free & open source").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button { router.settings = .general } label: { Image(systemName: "gearshape.fill") }
                    .buttonStyle(IconButtonStyle())
            }
            .padding(.horizontal, 14).padding(.bottom, 12)
        }
    }
}

struct AgentRow: View {
    let agent: BuddyAgent
    let selected: Bool
    @ObservedObject var manager = AgentManager.shared
    @State private var hovering = false

    var body: some View {
        let turn = manager.lastTurn(agent.id)
        let working = manager.running.contains(agent.id)
        HStack(spacing: 10) {
            AgentAvatar(agent: agent, size: 30, working: working)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(agent.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if manager.unread.contains(agent.id) {
                        Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    } else if let t = turn {
                        Text((t.finishedAt ?? t.startedAt).shortTime).font(.system(size: 10))
                            .foregroundStyle(selected ? Color.black.opacity(0.55) : Theme.textSecondary)
                    }
                }
                Text(working ? (turn?.steps.last?.present ?? "Working on it…") : (turn?.summary ?? turn?.prompt ?? agent.role))
                    .font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(selected ? Color.black.opacity(0.6) : Theme.textSecondary)
            }
        }
        .foregroundStyle(selected ? Color.black : Theme.textPrimary)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? AnyShapeStyle(Theme.userBubble) : AnyShapeStyle(hovering ? Theme.hover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(seed: conversation.id.uuidString, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(conversation.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(conversation.updated.shortTime).font(.system(size: 10)).foregroundStyle(selected ? Color.black.opacity(0.55) : Theme.textSecondary)
                }
                Text(conversation.preview).font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(selected ? Color.black.opacity(0.6) : Theme.textSecondary)
            }
        }
        .foregroundStyle(selected ? Color.black : Theme.textPrimary)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? AnyShapeStyle(Theme.userBubble) : AnyShapeStyle(hovering ? Theme.hover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Two-stroke wave mark used as the app logo.
struct LogoGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            p.move(to: CGPoint(x: 0, y: size.height * 0.4))
            p.addLine(to: CGPoint(x: size.width * 0.25, y: size.height * 0.9))
            p.addLine(to: CGPoint(x: size.width * 0.5, y: size.height * 0.2))
            p.addLine(to: CGPoint(x: size.width * 0.75, y: size.height * 0.65))
            p.addLine(to: CGPoint(x: size.width, y: size.height * 0.3))
            ctx.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: Main area

struct HomeEmptyState: View {
    @AppStorage("buddyName") private var buddyName = "Perch"
    @ObservedObject private var settings = AppSettings.shared
    private let tagline = [
        "Hold Control + Option and hand me a chore.",
        "Hold Control + Option. I'm all ears. Well, all cloud.",
        "Hold Control + Option and point me at a problem.",
        "Need a hand? I've got two tiny ones.",
        "Double-tap Control if you'd rather type.",
    ].randomElement()!

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 12 ? "Morning" : h < 17 ? "Afternoon" : "Evening"
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "\(part)." : "\(part), \(first)."
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack(alignment: .top) {
                TalkButton(title: "Hi, how can I help ^_^?")
                    .padding(.top, 66)
                MascotView(size: 96, animated: true, showHands: true)
            }
            Text(greeting).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.textPrimary)
            if settings.hasKey {
                Text(tagline)
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            } else {
                Text("Add your OpenRouter key first, so I can think.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Button { HomeRouter.shared.settings = .ai } label: { Label("Add key", systemImage: "key.fill") }
                    .buttonStyle(GlassPillStyle(height: 28))
            }
            Spacer()
            TypeField().frame(width: 320).padding(.bottom, 24)
        }
    }
}

struct ConversationView: View {
    let conversation: Conversation
    @ObservedObject var store = ConversationStore.shared
    @AppStorage("buddyName") private var buddyName = "Perch"

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                AvatarView(seed: conversation.id.uuidString, size: 30)
                Text(conversation.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.card))
            }
            .padding(.top, 44).padding(.bottom, 8)
            .frame(maxWidth: 360)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        MessageBubble(message: Message(role: .assistant,
                            text: "Type below, or hold Control + Option and just talk. I don't bite. I'm vapour."), dimmed: true)
                        ForEach(conversation.messages) { m in
                            MessageBubble(message: m) {
                                if let last = conversation.messages.last(where: { $0.role == .user }) {
                                    Companion.shared.askTyped(last.text)
                                }
                            }
                        }
                        if let streaming = store.streamingText, store.selectedID == conversation.id {
                            if streaming.isEmpty {
                                TypingDots()
                            } else {
                                MessageBubble(message: Message(role: .assistant, text: streaming))
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 28).padding(.vertical, 8)
                }
                .onChange(of: conversation.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: store.streamingText) { _, _ in proxy.scrollTo("bottom") }
                .onAppear { proxy.scrollTo("bottom") }
            }

            HStack(alignment: .bottom, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    TalkButton(title: "Hold Control + Option to talk").padding(.top, 34)
                    MascotView(tint: Color(red: 0.72, green: 0.64, blue: 0.95), size: 54, showHands: true).offset(x: -6, y: -4)
                }
                TypeField().frame(width: 170)
            }
            .padding(.horizontal, 22).padding(.bottom, 8)
            ReleaseHint()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30).padding(.bottom, 12)
        }
    }
}

struct MessageBubble: View {
    let message: Message
    var dimmed = false
    var onRetry: (() -> Void)?

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.08, green: 0.1, blue: 0.2))
                    .textSelection(.enabled)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.userBubble))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color(red: 0.2, green: 0.25, blue: 0.55), lineWidth: 1))
            }
        case .assistant:
            HStack {
                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundStyle(dimmed ? Theme.textSecondary : Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.08)))
                Spacer(minLength: 60)
            }
        case .error:
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("My cloud got a bit tangled. Want to try again?", systemImage: "cloud.drizzle")
                        .font(.system(size: 12)).foregroundStyle(Theme.textPrimary.opacity(0.85))
                    DisclosureGroup("Technical details") {
                        Text(message.text).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    }
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))

                Text(message.date.shortTime).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                if let onRetry {
                    Button(action: onRetry) { Label("Retry", systemImage: "arrow.clockwise") }
                        .buttonStyle(ChipStyle(light: true))
                }
            }
        }
    }
}

struct TypingDots: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle().fill(Theme.textSecondary).frame(width: 6, height: 6)
                    .opacity(0.3 + 0.7 * max(0, sin(phase + Double(i) * 0.9)))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08)))
        .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi * 2 } }
    }
}

/// "Release to send", shown only while the user is holding to talk.
struct ReleaseHint: View {
    @ObservedObject var state = BuddyState.shared

    var body: some View {
        Text("Release to send").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textTertiary)
            .opacity(state.phase == .listening ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: state.phase == .listening)
    }
}

/// Press and hold to talk (same as holding Control + Option).
struct TalkButton: View {
    let title: String
    @ObservedObject var state = BuddyState.shared
    @State private var pressing = false

    var body: some View {
        Button {} label: {
            Label(state.phase == .listening ? "Listening…" : title, systemImage: "mic.fill")
                .frame(minWidth: 200)
        }
        .buttonStyle(GlassPillStyle(height: 34))
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing else { return }
                    pressing = true
                    Companion.shared.beginListening()
                }
                .onEnded { _ in
                    pressing = false
                    Companion.shared.endListening()
                }
        )
    }
}

struct TypeField: View {
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            TextField("Type…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    text = ""
                    Companion.shared.askTyped(t)
                }
        }
        .padding(.horizontal, 14).frame(height: 36)
        .background(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
    }
}
