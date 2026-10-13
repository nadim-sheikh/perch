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

    var body: some View {
        GeometryReader { _ in
            if screenFrame.insetBy(dx: -40, dy: -40).contains(state.position) {
                let local = CGPoint(
                    x: state.position.x - screenFrame.minX,
                    y: screenFrame.maxY - state.position.y
                )
                ZStack(alignment: .topLeading) {
                    BuddyCursor(color: settings.cursorColor, phase: state.phase, level: state.audioLevel)
                        .position(local)

                    if let label = state.pointLabel {
                        Text(label)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(settings.cursorColor))
                            .foregroundStyle(.white)
                            .position(x: local.x, y: local.y + 28)
                    }

                    if !state.bubbleText.isEmpty {
                        SpeechBubble(text: state.bubbleText, color: settings.cursorColor)
                            .frame(maxWidth: 340, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .offset(bubbleOffset(for: local))
                    }
                }
                .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
            }
        }
        .ignoresSafeArea()
    }

    /// Place the bubble to the right of the buddy, flipping left near the edge.
    private func bubbleOffset(for p: CGPoint) -> CGSize {
        let width: CGFloat = 340
        let x = p.x + width + 40 > screenFrame.width ? p.x - width - 24 : p.x + 24
        let y = min(max(p.y + 16, 8), screenFrame.height - 200)
        return CGSize(width: x, height: y)
    }
}

/// The buddy itself: a small triangle cursor that pulses while listening and
/// spins while thinking.
struct BuddyCursor: View {
    let color: Color
    let phase: BuddyPhase
    let level: Float
    @State private var spin = false

    var body: some View {
        ZStack {
            if phase == .listening {
                Circle()
                    .fill(color.opacity(0.25))
                    .frame(width: 30 + CGFloat(level) * 40, height: 30 + CGFloat(level) * 40)
                    .animation(.easeOut(duration: 0.08), value: level)
            }
            if phase == .thinking {
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 30, height: 30)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
                    }
                    .onDisappear { spin = false }
            }
            CursorShape()
                .fill(color)
                .overlay(CursorShape().stroke(.white, lineWidth: 1.5))
                .frame(width: 18, height: 22)
                .shadow(color: color.opacity(0.6), radius: 6)
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
        Text(text)
            .font(.system(size: 13.5))
            .foregroundStyle(.white)
            .lineSpacing(2)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.82))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(color.opacity(0.7), lineWidth: 1)
                    )
            )
            .shadow(radius: 8)
    }
}
