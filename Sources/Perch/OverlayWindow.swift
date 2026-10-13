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
        level = .statusBar
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
    /// This panel's screen shows the notch island (it follows the mouse), so the buddy tucks away under it.
    private var holdsNotch: Bool { NotchController.hostScreen?.frame == screenFrame }
    @EnvironmentObject var state: BuddyState
    @EnvironmentObject var settings: AppSettings
    @AppStorage("cursorColorHex") private var cursorColorHex = "#3B82F6"

    private var color: Color { Color(hex: cursorColorHex) ?? .blue }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !state.marks.isEmpty {
                MarksLayer(screenFrame: screenFrame, marks: state.marks, color: color)
                    .transition(.opacity)
            }
            cursorLayer
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .ignoresSafeArea()
    }

    private var cursorLayer: some View {
        GeometryReader { _ in
            if screenFrame.insetBy(dx: -40, dy: -40).contains(state.position) {
                let local = CGPoint(x: state.position.x - screenFrame.minX, y: screenFrame.maxY - state.position.y)
                let overNotch = holdsNotch && local.y < 44 && abs(local.x - screenFrame.width / 2) < 280 && state.navigation == .following
                ZStack(alignment: .topLeading) {
                    BuddyCursor(color: color, phase: state.phase, level: state.audioLevel,
                                rotation: state.rotation, scale: state.flightScale)
                        .position(local)
                        .opacity(overNotch ? 0 : 1)
                        .animation(.easeOut(duration: 0.15), value: overNotch)

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

    /// Place the bubble right-below the buddy, flipping near the edges and never
    /// tucking under the notch / menu bar.
    private func bubbleOffset(for p: CGPoint) -> CGSize {
        let width: CGFloat = 300
        let x = p.x + width + 40 > screenFrame.width ? p.x - width - 18 : p.x + 18
        let topClearance: CGFloat = 70   // below the notch strip
        let y = min(max(p.y + 14, topClearance), screenFrame.height - 200)
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

/// A soft, rounded pointer: a friendly teardrop that points up-left, with
/// gently curved sides and rounded corners instead of sharp spikes.
struct CursorShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        let tip = CGPoint(x: r.minX + w * 0.08, y: r.minY + h * 0.08)
        let right = CGPoint(x: r.minX + w * 0.92, y: r.minY + h * 0.52)
        let notch = CGPoint(x: r.minX + w * 0.5, y: r.minY + h * 0.6)
        let bottom = CGPoint(x: r.minX + w * 0.4, y: r.maxY - h * 0.06)
        var p = Path()
        p.move(to: tip)
        // top edge bows out slightly toward the right shoulder
        p.addQuadCurve(to: right, control: CGPoint(x: r.minX + w * 0.72, y: r.minY + h * 0.14))
        // inner curve into the tail notch
        p.addQuadCurve(to: notch, control: CGPoint(x: r.minX + w * 0.66, y: r.minY + h * 0.64))
        // tail
        p.addQuadCurve(to: bottom, control: CGPoint(x: r.minX + w * 0.52, y: r.maxY - h * 0.1))
        // back edge up to the tip
        p.addQuadCurve(to: tip, control: CGPoint(x: r.minX + w * 0.1, y: r.minY + h * 0.42))
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
