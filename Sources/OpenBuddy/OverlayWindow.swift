import AppKit
import SwiftUI

/// A transparent, click-through panel covering one screen. The buddy is drawn
/// in whichever panel contains its current global position.
final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayManager {
    private var panels: [OverlayPanel] = []

    func show() {
        rebuild()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    private func rebuild() {
        panels.forEach { $0.orderOut(nil) }
        panels = NSScreen.screens.map { screen in
            let panel = OverlayPanel(screen: screen)
            let view = BuddyOverlayView(screenFrame: screen.frame)
                .environmentObject(BuddyState.shared)
                .environmentObject(AppSettings.shared)
            panel.contentView = NSHostingView(rootView: view)
            panel.orderFrontRegardless()
            return panel
        }
    }
}

struct BuddyOverlayView: View {
    let screenFrame: CGRect
    @EnvironmentObject var state: BuddyState
    @EnvironmentObject var settings: AppSettings
    @AppStorage("cursorColorHex") private var cursorColorHex = "#3B82F6"

    private var color: Color { Color(hex: cursorColorHex) ?? .blue }

    var body: some View {
        GeometryReader { _ in
            if screenFrame.insetBy(dx: -40, dy: -40).contains(state.position) {
                let local = CGPoint(x: state.position.x - screenFrame.minX, y: screenFrame.maxY - state.position.y)
                ZStack(alignment: .topLeading) {
                    BuddyCursor(color: color, phase: state.phase, level: state.audioLevel,
                                rotation: state.rotation, scale: state.flightScale)
                        .position(local)

                    if let callout = state.callout {
                        Text(callout)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(color))
                            .foregroundStyle(.white)
                            .shadow(color: color.opacity(0.5), radius: 8)
                            .position(x: local.x + 14, y: local.y + 30)
                            .transition(.scale(scale: 0.6, anchor: .top).combined(with: .opacity))
                    }

                    if !state.bubbleText.isEmpty && state.navigation == .following {
                        SpeechBubble(text: state.bubbleText, color: color)
                            .frame(maxWidth: 300, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .offset(bubbleOffset(for: local))
                            .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.72), value: state.bubbleText.isEmpty)
                .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
            }
        }
        .ignoresSafeArea()
    }

    /// Place the bubble right-below the buddy, flipping near the edges.
    private func bubbleOffset(for p: CGPoint) -> CGSize {
        let width: CGFloat = 300
        let x = p.x + width + 40 > screenFrame.width ? p.x - width - 18 : p.x + 18
        let y = min(max(p.y + 14, 8), screenFrame.height - 200)
        return CGSize(width: x, height: y)
    }
}

/// The buddy: a glowing triangle that breathes when idle, shows sound bars while
/// listening, a spinning arc while thinking, and turns to face its flight path.
struct BuddyCursor: View {
    let color: Color
    let phase: BuddyPhase
    let level: Float
    var rotation: Double = 0
    var scale: CGFloat = 1
    @State private var spin = false

    var body: some View {
        ZStack {
            if phase == .thinking {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 26, height: 26)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true } }
                    .onDisappear { spin = false }
            }
            CursorShape()
                .fill(color)
                .overlay(CursorShape().stroke(.white.opacity(0.9), lineWidth: 1.2))
                .frame(width: 15, height: 18)
                .shadow(color: color.opacity(0.75), radius: 7)
                .rotationEffect(.degrees(rotation))
                .scaleEffect(scale)
            if phase == .listening {
                HStack(spacing: 2) {
                    ForEach(0..<5) { i in
                        let profile: [CGFloat] = [0.5, 0.8, 1, 0.8, 0.5]
                        Capsule().fill(color).frame(width: 2.5, height: 3 + CGFloat(level) * 14 * profile[i])
                    }
                }
                .offset(x: 20, y: 2)
                .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(width: 80, height: 80)
    }
}

struct CursorShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY + r.height * 0.15))
        p.addLine(to: CGPoint(x: r.midX, y: r.midY + r.height * 0.2))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.25, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct SpeechBubble: View {
    let text: String
    let color: Color

    var body: some View {
        WordRevealText(text: text)
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(.white)
            .lineSpacing(2)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 0.12, green: 0.125, blue: 0.145).opacity(0.96))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(color.opacity(0.55), lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.25), radius: 12)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: text.count / 12)
    }
}

/// Reveals words one after another: each fades in, un-blurs and rises.
struct WordRevealText: View {
    let text: String
    @State private var revealed = 0
    @State private var timer: Timer?

    var body: some View {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        words.enumerated().reduce(Text("")) { acc, item in
            let (i, w) = item
            let piece = Text(i == 0 ? w : " " + w)
            return acc + (i < revealed ? piece : piece.foregroundColor(.clear))
        }
        .onAppear { start(total: words.count) }
        .onChange(of: words.count) { _, n in start(total: n) }
    }

    private func start(total: Int) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { t in
            MainActor.assumeIsolated {
                if revealed < total { revealed += 1 } else { t.invalidate() }
            }
        }
    }
}
