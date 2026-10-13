import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Avatar for an agent: pastel disc with the mascot tinted in the agent's colour.
struct AgentAvatar: View {
    let agent: BuddyAgent
    var size: CGFloat = 30
    var working = false

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [agent.backdrop.mix(with: .white, by: 0.3), agent.backdrop], center: .topLeading, startRadius: 1, endRadius: size))
            MascotView(tint: agent.tint, size: size * 0.66).allowsHitTesting(false).offset(y: size * 0.03)
        }
        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if working {
                BreathingDot(color: Theme.accent).frame(width: size * 0.3, height: size * 0.3)
                    .offset(x: 2, y: 2)
            }
        }
    }
}

/// Small pulsing status dot ("breathing").
struct BreathingDot: View {
    var color: Color = Theme.accent
    @State private var on = false
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.35)).scaleEffect(on ? 2.0 : 1).opacity(on ? 0 : 0.8)
            Circle().fill(color).scaleEffect(on ? 1 : 0.85)
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) { on = true } }
    }
}

/// Soft reveal for newly appearing content: fade, un-blur and rise.
struct MagicalAppear: ViewModifier {
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 6)
            .offset(y: shown ? 0 : 6)
            .onAppear { withAnimation(.easeOut(duration: 0.35)) { shown = true } }
    }
}

extension View {
    func magicalAppear() -> some View { modifier(MagicalAppear()) }
}

// MARK: Agent chat

struct AgentChatView: View {
    let agent: BuddyAgent
    @ObservedObject var manager = AgentManager.shared

    var body: some View {
        let turns = manager.turns[agent.id] ?? []
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                AgentAvatar(agent: agent, size: 34, working: manager.running.contains(agent.id))
                HStack(spacing: 4) {
                    Text(agent.name).font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Theme.card))
                .onTapGesture { NSWorkspace.shared.open(agent.folder) }
                .help("Open \(agent.name)'s folder")
            }
            .padding(.top, 44).padding(.bottom, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        MessageBubble(message: Message(role: .assistant, text: introLine), dimmed: true)
                        if turns.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(agent.suggestedAsks, id: \.self) { ask in
                                    Button(ask) { AgentManager.shared.launch(slug: agent.id, prompt: ask) }
                                        .buttonStyle(ChipStyle())
                                }
                            }
                        }
                        ForEach(turns) { turn in
                            AgentTurnView(agent: agent, turn: turn).id(turn.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 28).padding(.vertical, 8)
                }
                .onChange(of: turns.last?.steps.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: turns.last?.state) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: turns.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
                .onAppear { proxy.scrollTo("bottom") }
            }

            AgentComposer(agent: agent)
        }
        .onAppear { manager.clearUnread(agent.id) }
    }

    private var introLine: String {
        "I'm \(agent.name). \(agent.oneLiner) Type below whenever you're ready, or hold Control and Option to just talk to me."
    }
}

struct AgentTurnView: View {
    let agent: BuddyAgent
    let turn: AgentTurn
    var showPrompt = true
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showPrompt { MessageBubble(message: Message(role: .user, text: turn.prompt)) }

            if turn.state == .working {
                workingView
            } else if turn.state == .queued {
                HStack(spacing: 8) {
                    Label("Queued. Starts when the current task is done.", systemImage: "clock")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Cancel") { AgentManager.shared.cancelQueued(agent.id, turnID: turn.id) }
                        .buttonStyle(ChipStyle())
                }
            } else {
                if !turn.steps.isEmpty || !turn.progress.isEmpty {
                    DisclosureGroup(isExpanded: $expanded) {
                        stepList.padding(.top, 6)
                    } label: {
                        Text("\(turn.steps.count + turn.progress.count) progress messages")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    .tint(Theme.textSecondary)
                }

                if let error = turn.error, turn.canContinue == true {
                    MessageBubble(message: Message(role: .assistant, text: error), dimmed: true)
                    Button { AgentManager.shared.retry(agent.id, turnID: turn.id) } label: { Label("Continue", systemImage: "play.fill") }
                        .buttonStyle(ChipStyle())
                } else if let error = turn.error {
                    MessageBubble(message: Message(role: .error, text: error, date: turn.finishedAt ?? Date())) {
                        AgentManager.shared.retry(agent.id, turnID: turn.id)
                    }
                } else if turn.state == .stopped && turn.reply.isEmpty {
                    Label("Stopped. Send another message to keep going.", systemImage: "stop.circle")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                } else if !turn.reply.isEmpty {
                    MarkdownText(text: turn.reply).magicalAppear()
                }

                if !turn.artifacts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(turn.artifacts, id: \.self) { ArtifactTile(path: $0) }
                        }
                    }
                }

                if !turn.nextActions.isEmpty && turn.state == .finished {
                    HStack(spacing: 6) {
                        ForEach(turn.nextActions, id: \.self) { action in
                            Button(action) { AgentManager.shared.launch(slug: agent.id, prompt: action) }
                                .buttonStyle(ChipStyle())
                        }
                    }
                }

                Text(footer).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var workingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepList
            if !turn.liveText.isEmpty {
                Text(FinalReplyParser.visibleStreamingText(turn.liveText))
                    .font(.system(size: 13)).foregroundStyle(Theme.textPrimary.opacity(0.9))
                    .magicalAppear()
            }
            HStack(spacing: 8) {
                BreathingDot().frame(width: 7, height: 7)
                Text(statusPhrase).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: statusPhrase)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Self.format(turn.duration)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                }
                Button { AgentManager.shared.stop(agent.id) } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(ChipStyle())
            }
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(turn.progress.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary.opacity(0.8)).magicalAppear()
            }
            ForEach(turn.steps) { step in
                StepRow(step: step).magicalAppear()
            }
        }
    }

    private var statusPhrase: String {
        if let s = turn.steps.last(where: { !$0.done }) { return s.present + "…" }
        if !turn.liveText.isEmpty { return "Writing…" }
        return turn.steps.isEmpty ? "Working on it…" : "Thinking…"
    }

    private var footer: String {
        var parts = [Self.format(turn.duration), (turn.finishedAt ?? turn.startedAt).shortTime]
        if !turn.artifacts.isEmpty { parts.append("\(turn.artifacts.count) file\(turn.artifacts.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

struct StepRow: View {
    let step: AgentStep
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11)).frame(width: 16)
                    .foregroundStyle(step.isError ? .orange : Theme.textSecondary)
                Text(step.done ? step.past : step.present).font(.system(size: 12.5))
                    .foregroundStyle(Theme.textPrimary.opacity(step.done ? 0.75 : 0.95))
                    .lineLimit(1)
                if !step.done { ProgressView().controlSize(.mini) }
                Spacer()
                if step.detail != nil {
                    Button { showDetail.toggle() } label: { Image(systemName: showDetail ? "chevron.up" : "chevron.down") }
                        .buttonStyle(IconButtonStyle())
                }
            }
            if showDetail, let d = step.detail {
                Text(d).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(red: 0.8, green: 0.85, blue: 0.95))
                    .textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
            }
        }
    }

    private var icon: String {
        if step.isError { return "exclamationmark.triangle" }
        switch step.kind {
        case .edit: return "doc.text"
        case .command: return "terminal"
        case .web: return "globe"
        case .read: return "doc.plaintext"
        case .search: return "magnifyingglass"
        case .plan: return "checklist"
        case .app: return "puzzlepiece.extension"
        case .helper: return "person.2"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

/// A file the agent made: Quick Look thumbnail, click to open, drag out to Finder.
struct ArtifactTile: View {
    let path: String
    @State private var thumb: NSImage?
    @State private var pressed = false

    var body: some View {
        let url = URL(fileURLWithPath: path)
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06))
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 150, height: 96).clipped()
                } else {
                    Image(systemName: icon(url)).font(.system(size: 26)).foregroundStyle(color(url))
                }
            }
            .frame(width: 150, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(url.lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1).frame(width: 150, alignment: .leading)
        }
        .scaleEffect(pressed ? 0.97 : 1)
        .onTapGesture { NSWorkspace.shared.open(url) }
        .onLongPressGesture(minimumDuration: 0.01, pressing: { p in withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { pressed = p } }, perform: {})
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .task {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 300, height: 192), scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                thumb = rep.nsImage
            }
        }
    }

    private func icon(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "globe"
        case "md", "txt": return "doc.plaintext.fill"
        case "pdf", "doc", "docx": return "doc.text.fill"
        case "csv", "xlsx": return "tablecells.fill"
        case "png", "jpg", "jpeg", "gif", "webp": return "photo.fill"
        case "pptx", "key": return "rectangle.on.rectangle.fill"
        case "js", "ts", "py", "swift": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.fill"
        }
    }

    private func color(_ url: URL) -> Color {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return Color(red: 0.08, green: 0.72, blue: 0.65)
        case "md", "txt": return Color(red: 0.39, green: 0.45, blue: 0.55)
        case "csv", "xlsx": return Color(red: 0.13, green: 0.77, blue: 0.37)
        case "pptx", "key": return Color(red: 0.92, green: 0.70, blue: 0.03)
        default: return Color(red: 0.15, green: 0.39, blue: 0.92)
        }
    }
}

/// Renders markdown with paragraphs, headings and bullet lists.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func lineView(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            Color.clear.frame(height: 2)
        } else if line.hasPrefix("#") {
            let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            Text(inline(title)).font(.system(size: 14, weight: .bold))
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(Theme.textSecondary)
                Text(inline(String(line.dropFirst(2)))).font(.system(size: 13))
            }
        } else if line.hasPrefix("|") {
            Text(line).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textPrimary.opacity(0.85))
        } else {
            Text(inline(line)).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Talk/type composer for an agent chat.
struct AgentComposer: View {
    let agent: BuddyAgent
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    TalkButton(title: "Hold Control + Option to talk").padding(.top, 34)
                    MascotView(tint: agent.tint, size: 54, showHands: true).offset(x: -6, y: -4)
                }
                HStack(spacing: 8) {
                    Image(systemName: "keyboard").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    TextField("Message \(agent.name)…", text: $text)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .onSubmit {
                            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            text = ""
                            NSSound(named: "Tink")?.play()
                            AgentManager.shared.launch(slug: agent.id, prompt: t)
                        }
                }
                .padding(.horizontal, 14).frame(height: 36)
                .background(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
            }
            ReleaseHint().padding(.leading, 8)
        }
        .padding(.horizontal, 22).padding(.bottom, 12)
    }
}

/// Sheet for creating a new helper.
struct NewAgentSheet: View {
    var onDone: (BuddyAgent?) -> Void
    @State private var name = ""
    @State private var role = ""
    @State private var oneLiner = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                MascotView(size: 44)
                VStack(alignment: .leading) {
                    Text("New helper").font(.system(size: 16, weight: .bold))
                    Text("A helper works in the background with its own folder and memory.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            TextField("Name (e.g. Inbox Ian)", text: $name).settingsField().frame(maxWidth: .infinity)
            TextField("Role (e.g. Email assistant)", text: $role).settingsField()
            TextField("What should it do for you?", text: $oneLiner).settingsField()
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }.buttonStyle(ChipStyle())
                Button("Create") {
                    let a = try? AgentRoster.shared.create(
                        name: name.trimmingCharacters(in: .whitespaces),
                        role: role.isEmpty ? "Helper" : role,
                        oneLiner: oneLiner.isEmpty ? "Helps with whatever you need." : oneLiner)
                    if let a { AgentManager.shared.registerNewAgent(a) }
                    onDone(a)
                }
                .buttonStyle(GlassPillStyle(height: 28))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 400)
        .background(Theme.window)
        .preferredColorScheme(.dark)
    }
}
