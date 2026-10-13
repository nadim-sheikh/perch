import AppKit
import SwiftUI

/// The "island" that lives in the MacBook notch (or floats under the menu bar on
/// screens without one). One presentation is shown at a time, picked by priority.
@MainActor
final class NotchModel: ObservableObject {
    static let shared = NotchModel()

    enum Presentation: Equatable {
        case docked, listening, thinking, speaking, agents, peek, textInput, textResponse
        var isCard: Bool { self == .peek || self == .textInput || self == .textResponse }
    }

    @Published var presentation: Presentation = .docked
    @Published var hovering = false
    @Published var textInputOpen = false
    @Published var responseText = ""
    @Published var responseQuestion = ""
    @Published var responseVisible = false
    @Published var responseFinished = false
    @Published var dismissProgress: Double = 1   // countdown ring for the notch answer
    @Published var agentRotation = 0

    var notchHeight: CGFloat = 32
    var hardwareNotchWidth: CGFloat = 0
    var collapsedWidth: CGFloat { max(hardwareNotchWidth, 150) + 64 }

    var openHome: ((UUID?) -> Void)?
    var openAgent: ((String) -> Void)?
    var openSettings: (() -> Void)?
    var requestKeyFocus: (() -> Void)?
    var releaseKeyFocus: (() -> Void)?

    /// Opens the typing box in the notch.
    func openTextInput() {
        NSSound(named: "Tink")?.play()
        textInputOpen = true
        requestKeyFocus?()
    }

    func closeTextInput(sent: Bool) {
        textInputOpen = false
        releaseKeyFocus?()
    }

    func showResponse(question: String) {
        responseQuestion = question
        responseText = ""
        responseFinished = false
        responseVisible = true
        dismissProgress = 1
    }

    func dismissResponse() {
        responseVisible = false
        responseText = ""
    }
}

final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar + 1
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
    }
    override var canBecomeKey: Bool { true }
}

@MainActor
final class NotchController {
    private let panel = NotchPanel()
    private let model = NotchModel.shared
    private var timer: Timer?
    private var hoverStarted: Date?
    private var leaveDeadline: Date?
    private var suppressUntilReentry = false
    private var previousApp: NSRunningApplication?
    private var lastRotation = Date()
    private var lastTick = Date()
    private var clickMonitor: Any?
    private let panelSize = CGSize(width: 560, height: 420)

    func show() {
        let view = NotchRootView()
            .environmentObject(model)
            .environmentObject(BuddyState.shared)
            .environmentObject(ConversationStore.shared)
            .environmentObject(AgentManager.shared)
            .environmentObject(AgentRoster.shared)
        panel.contentView = NSHostingView(rootView: view)
        layout()
        panel.orderFrontRegardless()

        model.requestKeyFocus = { [weak self] in
            guard let self else { return }
            self.previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
            self.panel.makeKey()
        }
        model.releaseKeyFocus = { [weak self] in
            guard let self else { return }
            self.panel.resignKey()
            if let app = self.previousApp, app != NSRunningApplication.current { app.activate() }
            self.previousApp = nil
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        // Clicking anywhere else closes the peek / typing box.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.model.textInputOpen { self.model.closeTextInput(sent: false) }
                if self.model.presentation == .peek { self.suppressUntilReentry = true }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    private func layout() {
        let s = screen
        model.notchHeight = max(s.safeAreaInsets.top, 28)
        if let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
            model.hardwareNotchWidth = s.frame.width - left.width - right.width
        } else {
            model.hardwareNotchWidth = 0
        }
        panel.setFrame(NSRect(x: s.frame.midX - panelSize.width / 2, y: s.frame.maxY - panelSize.height,
                              width: panelSize.width, height: panelSize.height), display: true)
    }

    /// The visible shape's size for a presentation (matches NotchRootView).
    private func visibleSize(_ p: NotchModel.Presentation) -> CGSize {
        switch p {
        case .docked: return CGSize(width: model.collapsedWidth, height: model.notchHeight)
        case .listening, .thinking, .speaking, .agents: return CGSize(width: model.collapsedWidth + 120, height: model.notchHeight)
        case .peek: return CGSize(width: 480, height: 400)
        case .textInput: return CGSize(width: 480, height: 150)
        case .textResponse: return CGSize(width: 480, height: 330)
        }
    }

    private func hitRect(_ p: NotchModel.Presentation, inflate: CGFloat) -> NSRect {
        let s = screen
        let size = visibleSize(p)
        return NSRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height, width: size.width, height: size.height)
            .insetBy(dx: -inflate, dy: -inflate)
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        let mouse = NSEvent.mouseLocation
        let current = model.presentation
        let inside = hitRect(current, inflate: current.isCard ? 12 : 6).contains(mouse)
        panel.ignoresMouseEvents = !inside && !model.textInputOpen
        if model.hovering != inside { model.hovering = inside }

        // Hover dwell → peek, with re-entry suppression after an explicit dismiss.
        if inside {
            leaveDeadline = nil
            if hoverStarted == nil { hoverStarted = now }
        } else {
            hoverStarted = nil
            suppressUntilReentry = false
        }
        let peekEnabled = UserDefaults.standard.object(forKey: "notchPeek") as? Bool ?? true
        let wantsPeek: Bool = {
            guard peekEnabled, !suppressUntilReentry else { return false }
            if current == .peek {
                if inside { return true }
                if leaveDeadline == nil { leaveDeadline = now.addingTimeInterval(0.3) }
                return now < (leaveDeadline ?? now)
            }
            return (hoverStarted.map { now.timeIntervalSince($0) > 0.18 } ?? false)
        }()

        // Countdown for a notch answer: pauses while hovered.
        if model.responseVisible && model.responseFinished && !inside {
            let words = Double(model.responseText.split(separator: " ").count)
            let total = min(max(4 + words * 0.06, 6), 30)
            model.dismissProgress -= dt / total
            if model.dismissProgress <= 0 { model.dismissResponse() }
        }

        // Rotate between running helpers every 2.5s.
        if AgentManager.shared.running.count > 1, now.timeIntervalSince(lastRotation) > 2.5 {
            lastRotation = now
            withAnimation(.easeInOut(duration: 0.35)) { model.agentRotation += 1 }
        }

        let next = resolve(wantsPeek: wantsPeek)
        if next != current {
            let spring: Animation = next.isCard
                ? .spring(response: 0.42, dampingFraction: 0.78)
                : .spring(response: 0.36, dampingFraction: 0.86)
            withAnimation(spring) { model.presentation = next }
        }
    }

    /// Priority: typing > answer > voice > peek > helpers > docked.
    private func resolve(wantsPeek: Bool) -> NotchModel.Presentation {
        if model.textInputOpen { return .textInput }
        if model.responseVisible { return .textResponse }
        switch BuddyState.shared.phase {
        case .listening: return .listening
        case .thinking: return .thinking
        case .responding: return wantsPeek ? .peek : .speaking
        default: break
        }
        if wantsPeek { return .peek }
        if !AgentManager.shared.running.isEmpty { return .agents }
        return .docked
    }

    func handleClickOnDocked() {
        model.openHome?(nil)
    }
}

/// Black shape with concave top "shoulders" and rounded bottom corners.
struct NotchShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in r: CGRect) -> Path {
        let s: CGFloat = 8
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + s, y: r.minY + s), control: CGPoint(x: r.minX + s, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.minX + s + radius, y: r.maxY), control: CGPoint(x: r.minX + s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - s - radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - s, y: r.maxY - radius), control: CGPoint(x: r.maxX - s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + s))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - s, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchRootView: View {
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var state: BuddyState
    @EnvironmentObject var store: ConversationStore
    @EnvironmentObject var agents: AgentManager
    @EnvironmentObject var roster: AgentRoster
    @AppStorage("cursorColorHex") private var cursorColorHex = "#3B82F6"

    private var accent: Color { Color(hex: cursorColorHex) ?? .blue }

    private var size: CGSize {
        switch model.presentation {
        case .docked: return CGSize(width: model.collapsedWidth, height: model.notchHeight)
        case .listening, .thinking, .speaking, .agents: return CGSize(width: model.collapsedWidth + 120, height: model.notchHeight)
        case .peek: return CGSize(width: 470, height: peekHeight)
        case .textInput: return CGSize(width: 470, height: model.notchHeight + 92)
        case .textResponse: return CGSize(width: 470, height: responseHeight)
        }
    }

    private var peekRows: Int { min(agentRows.count + min(store.conversations.count, 2), 5) }
    private var peekHeight: CGFloat { model.notchHeight + 40 + CGFloat(max(peekRows, 1)) * 58 + 54 }
    private var responseHeight: CGFloat {
        let lines = max(1, model.responseText.count / 58 + model.responseText.filter { $0 == "\n" }.count + 1)
        return min(model.notchHeight + 96 + CGFloat(lines) * 18, 330)
    }

    private var agentRows: [BuddyAgent] {
        roster.agents.filter { !$0.archived && (agents.running.contains($0.id) || agents.lastTurn($0.id) != nil) }
            .sorted { agents.lastActivity($0.id) > agents.lastActivity($1.id) }
            .prefix(3).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if model.presentation == .listening { CornerGlow(color: accent).frame(width: size.width + 60, height: size.height + 40) }

                NotchShape(radius: model.presentation.isCard ? 24 : 11)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(model.presentation.isCard ? 0.45 : 0), radius: 18, y: 6)
                    .onTapGesture { if model.presentation == .docked || model.presentation == .agents { model.openHome?(nil) } }

                Group {
                    switch model.presentation {
                    case .docked: dockedView
                    case .listening, .thinking, .speaking: activityStrip
                    case .agents: agentStrip
                    case .peek: peek.padding(.horizontal, 26)
                    case .textInput: NotchTextInput().padding(.horizontal, 26)
                    case .textResponse: NotchTextResponse().padding(.horizontal, 26)
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)).animation(.easeOut(duration: 0.22).delay(0.08)),
                    removal: .opacity.animation(.easeIn(duration: 0.1))))
                .id(model.presentation)
            }
            .frame(width: size.width, height: size.height)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }

    // MARK: Compact states

    private var dockedView: some View {
        HStack {
            MiniFace()
            Spacer()
            if !agents.unread.isEmpty {
                Text("\(agents.unread.count)").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                    .frame(width: 16, height: 16).background(Circle().fill(accent))
            } else {
                Circle().fill(accent).frame(width: 6, height: 6).shadow(color: accent.opacity(0.9), radius: 4)
            }
        }
        .padding(.horizontal, 18).frame(height: model.notchHeight)
    }

    private var activityStrip: some View {
        HStack(spacing: 8) {
            MascotView(size: 18, happy: true)
            Text(stripLabel).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                .contentTransition(.opacity)
            Spacer()
            switch model.presentation {
            case .listening: WaveBars(level: state.audioLevel, color: accent)
            case .thinking: ThinkingDots(color: accent)
            default: EqualizerBars(color: accent)
            }
        }
        .padding(.horizontal, 20).frame(height: model.notchHeight)
    }

    private var stripLabel: String {
        switch model.presentation {
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        default: return "Speaking"
        }
    }

    private var agentStrip: some View {
        let running = roster.agents.filter { agents.running.contains($0.id) }
        let agent = running.isEmpty ? nil : running[model.agentRotation % running.count]
        return HStack(spacing: 8) {
            if let agent {
                AgentAvatar(agent: agent, size: 18)
                Text(running.count > 1 ? "\(running.count) helpers working" : "\(agent.name) is working")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    .id(agent.id)
                    .transition(.push(from: .bottom))
                Spacer()
                ThinkingDots(color: agent.tint)
            }
        }
        .padding(.horizontal, 20).frame(height: model.notchHeight)
    }

    // MARK: Peek

    private var peek: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.openHome?(nil) } label: { LogoGlyph().frame(width: 20, height: 12) }
                    .buttonStyle(.plain)
                Spacer()
                Button { model.openSettings?() } label: { Image(systemName: "gearshape.fill") }
                    .buttonStyle(IconButtonStyle())
            }
            .frame(height: model.notchHeight)

            CursorShape().fill(accent)
                .frame(width: 12, height: 14)
                .shadow(color: accent.opacity(0.9), radius: 6)
                .padding(.bottom, 6)

            if agentRows.isEmpty && store.conversations.isEmpty {
                VStack(spacing: 6) {
                    MascotView(size: 34)
                    Text("Hold Control + Option and ask me anything.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                .frame(height: 70)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(agentRows.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Divider().overlay(Color.white.opacity(0.1)).padding(.leading, 52) }
                        PeekAgentRow(agent: a)
                            .onTapGesture { model.openAgent?(a.id) }
                            .modifier(StaggerIn(index: i))
                    }
                    ForEach(Array(store.conversations.prefix(max(0, 5 - agentRows.count)).prefix(2).enumerated()), id: \.element.id) { i, c in
                        Divider().overlay(Color.white.opacity(0.1)).padding(.leading, 52).opacity(agentRows.isEmpty && i == 0 ? 0 : 1)
                        PeekRow(conversation: c)
                            .onTapGesture { model.openHome?(c.id) }
                            .modifier(StaggerIn(index: agentRows.count + i))
                    }
                }
            }

            HStack {
                Button { model.openTextInput() } label: { Label("Type", systemImage: "keyboard") }
                    .buttonStyle(ChipStyle())
                Button { model.openSettings?(); HomeRouter.shared.settings = .integrations } label: {
                    Label("Apps", systemImage: "square.grid.2x2")
                }
                .buttonStyle(ChipStyle())
                Spacer()
                Button { model.openHome?(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(IconButtonStyle())
                    .background(Circle().stroke(Color.white.opacity(0.2)))
                    .help("Open Home")
            }
            .padding(.top, 10)
        }
    }
}

/// Rows slide in one after another when the peek opens.
struct StaggerIn: ViewModifier {
    let index: Int
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 8)
            .onAppear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.82).delay(0.05 + Double(index) * 0.035)) { shown = true }
            }
    }
}

private struct PeekAgentRow: View {
    let agent: BuddyAgent
    @EnvironmentObject var agents: AgentManager
    @State private var spread = false

    var body: some View {
        let turn = agents.lastTurn(agent.id)
        let working = agents.running.contains(agent.id)
        HStack(spacing: 12) {
            AgentAvatar(agent: agent, size: 38, working: working)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(agent.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if agents.unread.contains(agent.id) { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
                    Spacer()
                    if working {
                        ThinkingDots(color: agent.tint)
                    } else if let t = turn {
                        Text((t.finishedAt ?? t.startedAt).shortTime).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Text(working ? (turn?.steps.last?.present ?? "Working on it…") : (turn?.summary ?? turn?.prompt ?? agent.role))
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            if let files = turn?.artifacts, !files.isEmpty, !working {
                FilePile(paths: Array(files.prefix(3)), spread: spread)
                    .onHover { h in withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { spread = h } }
            }
        }
        .foregroundStyle(.white)
        .frame(height: 58)
        .contentShape(Rectangle())
    }
}

/// A fanned stack of a helper's latest files; spreads out on hover, drag out to Finder.
struct FilePile: View {
    let paths: [String]
    let spread: Bool
    var body: some View {
        ZStack {
            ForEach(Array(paths.enumerated()), id: \.offset) { i, path in
                let rotations: [Double] = [-6, 3, -2]
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white)
                    .frame(width: 30, height: 38)
                    .overlay(Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(.gray))
                    .shadow(radius: 2)
                    .rotationEffect(.degrees(spread ? 0 : rotations[i % 3]))
                    .offset(x: spread ? CGFloat(i) * -34 : CGFloat(i) * -4)
                    .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    .onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: path)) ?? NSItemProvider() }
                    .help(URL(fileURLWithPath: path).lastPathComponent)
            }
        }
        .frame(width: 40, height: 44)
    }
}

private struct PeekRow: View {
    let conversation: Conversation
    var body: some View {
        HStack(spacing: 12) {
            AvatarView(seed: conversation.id.uuidString, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(conversation.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(conversation.updated.shortTime).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                Text(conversation.preview).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .frame(height: 58)
        .contentShape(Rectangle())
    }
}

// MARK: Typing in the notch

struct NotchTextInput: View {
    @EnvironmentObject var model: NotchModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            Color.clear.frame(height: model.notchHeight - 6)
            HStack(alignment: .center, spacing: 10) {
                MascotView(size: 26)
                TextField("Ask about anything on your screen…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...3)
                    .focused($focused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 26, height: 26).background(Circle().fill(text.isEmpty ? Color.white.opacity(0.3) : Color.white))
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08)))
            HStack {
                Text("Return to send · Esc to close").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                Spacer()
                Button { model.closeTextInput(sent: false) } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle())
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true } }
        .onExitCommand { model.closeTextInput(sent: false) }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        text = ""
        NSSound(named: "Pop")?.play()
        model.closeTextInput(sent: true)
        Companion.shared.askTyped(t, inNotch: true)
    }
}

struct NotchTextResponse: View {
    @EnvironmentObject var model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear.frame(height: model.notchHeight - 8)
            HStack(spacing: 8) {
                MascotView(size: 20)
                Text(model.responseQuestion).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer()
                CountdownRing(progress: model.dismissProgress, paused: model.hovering)
                    .onTapGesture { model.dismissResponse() }
                    .help("Dismiss")
            }
            ScrollView {
                if model.responseText.isEmpty {
                    ThinkingDots(color: Theme.accent).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                } else {
                    Text(model.responseText).font(.system(size: 13.5)).foregroundStyle(.white)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.easeOut(duration: 0.15), value: model.responseText)
                }
            }
            HStack(spacing: 6) {
                Button { model.openTextInput() } label: { Label("Follow up", systemImage: "arrowshape.turn.up.left") }
                    .buttonStyle(ChipStyle())
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.responseText, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(ChipStyle())
                Spacer()
            }
            .padding(.bottom, 12)
        }
    }
}

/// Small ring that drains while an answer waits to auto-dismiss.
struct CountdownRing: View {
    let progress: Double
    let paused: Bool
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 2)
            Circle().trim(from: 0, to: max(0, progress)).stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: paused ? "pause.fill" : "xmark").font(.system(size: 6, weight: .bold)).foregroundStyle(.white.opacity(0.8))
        }
        .frame(width: 16, height: 16)
        .opacity(paused ? 0.6 : 1)
        .animation(.easeOut(duration: 0.15), value: paused)
    }
}

// MARK: Little animations

/// Two eyes that blink now and then, shown in the docked island.
struct MiniFace: View {
    @State private var blink = false
    var body: some View {
        HStack(spacing: 5) {
            Capsule().fill(Color.white).frame(width: 4, height: blink ? 1 : 6)
            Capsule().fill(Color.white).frame(width: 4, height: blink ? 1 : 6)
        }
        .frame(height: 8)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 2.5...5)))
                withAnimation(.easeInOut(duration: 0.08)) { blink = true }
                try? await Task.sleep(for: .milliseconds(120))
                withAnimation(.easeInOut(duration: 0.1)) { blink = false }
            }
        }
    }
}

struct WaveBars: View {
    let level: Float
    let color: Color
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5) { i in
                let factor: CGFloat = [0.5, 0.8, 1, 0.8, 0.5][i]
                Capsule().fill(color).frame(width: 3, height: 4 + CGFloat(level) * 16 * factor)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

/// Three dots pulsing in turn.
struct ThinkingDots: View {
    var color: Color = .white
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3.5) {
                ForEach(0..<3) { i in
                    let phase = (sin((t - Double(i) * 0.2) * .pi * 2 / 1.2) + 1) / 2
                    Circle().fill(color).frame(width: 5, height: 5)
                        .opacity(0.3 + 0.7 * phase)
                        .scaleEffect(0.8 + 0.2 * phase)
                }
            }
        }
    }
}

/// Speaking equaliser: bars moving on offset sine waves.
struct EqualizerBars: View {
    let color: Color
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<4) { i in
                    let period = [0.9, 1.1, 1.3, 1.0][i]
                    let h = 5 + 11 * (sin(t * .pi * 2 / period + Double(i)) + 1) / 2
                    Capsule().fill(color).frame(width: 3, height: h)
                }
            }
        }
    }
}

/// Coloured glow bleeding out of the notch corners while listening.
struct CornerGlow: View {
    let color: Color
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let pulse = 0.7 + 0.25 * sin(t * .pi * 2 / 2.2)
                let blobs: [(CGFloat, CGFloat, Color)] = [
                    (0.08, 0.55, color), (0.92, 0.55, color),
                    (0.5, 0.95, color.opacity(0.6)),
                ]
                for (i, b) in blobs.enumerated() {
                    let dx = 10 * sin(t * .pi * 2 / 6 + Double(i))
                    let dy = 6 * cos(t * .pi * 2 / 5 + Double(i))
                    let c = CGPoint(x: size.width * b.0 + dx, y: size.height * b.1 + dy)
                    let r: CGFloat = 26
                    g.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                           with: .color(b.2.opacity(pulse * 0.8)))
                }
            }
            .blur(radius: 18)
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        .transition(.opacity.animation(.easeIn(duration: 0.4)))
    }
}
