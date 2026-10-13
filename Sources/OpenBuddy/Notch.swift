import AppKit
import SwiftUI

/// A black surface that hangs from the top-centre of the main screen (blending
/// into the hardware notch on MacBooks). It grows into an activity pill while
/// listening/thinking, and into a "peek" panel of recent chats on hover.
@MainActor
final class NotchModel: ObservableObject {
    static let shared = NotchModel()
    enum Mode: Equatable { case collapsed, activity, peek }
    @Published var mode: Mode = .collapsed
    var notchHeight: CGFloat = 32
    var openHome: ((UUID?) -> Void)?
    var openSettings: (() -> Void)?
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
    private var leaveDeadline: Date?
    // The panel is sized to fit the largest state; only the visible shape takes clicks.
    private let panelSize = CGSize(width: 520, height: 320)

    func show() {
        let view = NotchRootView()
            .environmentObject(model)
            .environmentObject(BuddyState.shared)
            .environmentObject(ConversationStore.shared)
        panel.contentView = NSHostingView(rootView: view)
        layout()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    private func layout() {
        let s = screen
        model.notchHeight = max(s.safeAreaInsets.top, 28)
        panel.setFrame(NSRect(x: s.frame.midX - panelSize.width / 2, y: s.frame.maxY - panelSize.height,
                              width: panelSize.width, height: panelSize.height), display: true)
    }

    /// Hit-test region (global coords) for the current state.
    private func activeRect() -> NSRect {
        let s = screen
        let size: CGSize
        switch model.mode {
        case .collapsed: size = CGSize(width: 220, height: model.notchHeight + 4)
        case .activity: size = CGSize(width: 300, height: model.notchHeight + 4)
        case .peek: size = CGSize(width: 480, height: 300)
        }
        return NSRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height, width: size.width, height: size.height)
    }

    private func tick() {
        let inside = activeRect().contains(NSEvent.mouseLocation)
        // Only let the panel take clicks where the visible shape is.
        panel.ignoresMouseEvents = !inside

        let busy: Bool = {
            switch BuddyState.shared.phase {
            case .listening, .thinking, .responding: return true
            default: return false
            }
        }()

        if inside {
            leaveDeadline = nil
            if model.mode != .peek && UserDefaults.standard.object(forKey: "notchPeek") as? Bool ?? true {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { model.mode = .peek }
            }
        } else if model.mode == .peek {
            if leaveDeadline == nil { leaveDeadline = Date().addingTimeInterval(0.35) }
            if let d = leaveDeadline, Date() > d {
                leaveDeadline = nil
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { model.mode = busy ? .activity : .collapsed }
            }
        } else {
            let target: NotchModel.Mode = busy ? .activity : .collapsed
            if model.mode != target {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.mode = target }
            }
        }
    }
}

/// Black shape with rounded bottom corners and small inverted "shoulders" at the top.
struct NotchShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in r: CGRect) -> Path {
        let s: CGFloat = 8 // shoulder size
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
    @AppStorage("cursorColorHex") private var cursorColorHex = "#3B82F6"

    private var size: CGSize {
        switch model.mode {
        case .collapsed: return CGSize(width: 200, height: model.notchHeight)
        case .activity: return CGSize(width: 300, height: model.notchHeight)
        case .peek: return CGSize(width: 470, height: peekHeight)
        }
    }

    private var peekHeight: CGFloat {
        let rows = min(store.conversations.count, 3)
        return model.notchHeight + 40 + CGFloat(max(rows, 1)) * 58 + 54
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(radius: model.mode == .peek ? 22 : 10)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(model.mode == .peek ? 0.5 : 0), radius: 16, y: 6)

                switch model.mode {
                case .collapsed: EmptyView()
                case .activity: activity.padding(.horizontal, 22).frame(height: model.notchHeight)
                case .peek: peek.padding(.horizontal, 26).transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }

    private var activity: some View {
        HStack {
            MascotView(size: 18)
            Spacer()
            switch state.phase {
            case .listening:
                WaveBars(level: state.audioLevel, color: Color(hex: cursorColorHex) ?? .blue)
            case .thinking:
                ProgressView().controlSize(.small).tint(.white)
            default:
                Image(systemName: "waveform").font(.system(size: 12)).foregroundStyle(Color(hex: cursorColorHex) ?? .blue)
            }
        }
    }

    private var peek: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                LogoGlyph().frame(width: 20, height: 12)
                Spacer()
                Button { model.openSettings?() } label: { Image(systemName: "gearshape.fill") }
                    .buttonStyle(IconButtonStyle())
            }
            .frame(height: model.notchHeight)

            CursorShape().fill(Color(hex: cursorColorHex) ?? .blue)
                .frame(width: 12, height: 14)
                .shadow(color: (Color(hex: cursorColorHex) ?? .blue).opacity(0.9), radius: 6)
                .padding(.bottom, 8)

            if store.conversations.isEmpty {
                Text("Hold Control + Option and ask me anything.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .frame(height: 58)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.conversations.prefix(3).enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Divider().overlay(Color.white.opacity(0.1)).padding(.leading, 52) }
                        PeekRow(conversation: c).onTapGesture { model.openHome?(c.id) }
                    }
                }
            }

            HStack {
                Button { store.newConversation(); model.openHome?(store.selectedID) } label: {
                    Label("New chat", systemImage: "plus")
                }
                .buttonStyle(ChipStyle())
                Spacer()
                Button { model.openHome?(nil) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(IconButtonStyle())
                .background(Circle().stroke(Color.white.opacity(0.2)))
                .help("Open Home")
            }
            .padding(.top, 10)
        }
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

struct WaveBars: View {
    let level: Float
    let color: Color
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5) { i in
                let factor: CGFloat = [0.5, 0.8, 1, 0.8, 0.5][i]
                Capsule().fill(color)
                    .frame(width: 3, height: 4 + CGFloat(level) * 16 * factor)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
