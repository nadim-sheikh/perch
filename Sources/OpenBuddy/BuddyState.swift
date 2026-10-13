import AppKit
import SwiftUI

enum BuddyPhase: Equatable {
    case idle
    case listening
    case thinking
    case responding
    case error(String)
}

/// Shared, observable state that drives the cursor overlay.
@MainActor
final class BuddyState: ObservableObject {
    static let shared = BuddyState()

    enum Navigation { case following, flying, pointing, returning }

    /// Buddy position in global AppKit coordinates (origin bottom-left of main screen).
    @Published var position: CGPoint = NSEvent.mouseLocation
    @Published var phase: BuddyPhase = .idle
    @Published var bubbleText: String = ""
    @Published var pointLabel: String?
    @Published var audioLevel: Float = 0
    @Published var navigation: Navigation = .following
    /// Rotation of the triangle in degrees (0 = resting tilt) and scale during flight.
    @Published var rotation: Double = 0
    @Published var flightScale: CGFloat = 1
    @Published var callout: String?

    var isPointing: Bool { navigation != .following }

    private var followTimer: Timer?
    private var flightTimer: Timer?
    private let cursorOffset = CGPoint(x: 16, y: -18)
    private var pointingStartedMouse: CGPoint = .zero

    private static let phrases = ["right here!", "this one!", "over here!", "here it is!", "found it!", "look here!", "this spot!"]

    func startFollowingCursor() {
        followTimer?.invalidate()
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followTick() }
        }
        RunLoop.main.add(followTimer!, forMode: .common)
    }

    private func followTick() {
        let mouse = NSEvent.mouseLocation
        if navigation == .pointing {
            // If the user moves the mouse a lot while we point, give up and come back.
            if hypot(mouse.x - pointingStartedMouse.x, mouse.y - pointingStartedMouse.y) > 220 { returnToCursor() }
            return
        }
        guard navigation == .following, AppSettings.shared.followCursor else { return }
        let target = CGPoint(x: mouse.x + cursorOffset.x, y: mouse.y + cursorOffset.y)
        // A tiny bit of lag makes it feel alive without trailing behind.
        let next = CGPoint(x: position.x + (target.x - position.x) * 0.45,
                           y: position.y + (target.y - position.y) * 0.45)
        if abs(next.x - position.x) > 0.25 || abs(next.y - position.y) > 0.25 { position = next }
    }

    /// Fly along an arc to a global point, point at it, then fly back.
    func point(at target: CGPoint, label: String?, hold: TimeInterval = 3.5) {
        pointLabel = label
        pointingStartedMouse = NSEvent.mouseLocation
        fly(to: target, returning: false) { [weak self] in
            guard let self else { return }
            self.navigation = .pointing
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                self.callout = label ?? Self.phrases.randomElement()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
                guard self?.navigation == .pointing else { return }
                self?.returnToCursor()
            }
        }
    }

    func returnToCursor() {
        withAnimation(.easeOut(duration: 0.2)) { callout = nil }
        pointLabel = nil
        let mouse = NSEvent.mouseLocation
        fly(to: CGPoint(x: mouse.x + cursorOffset.x, y: mouse.y + cursorOffset.y), returning: true) { [weak self] in
            self?.navigation = .following
        }
    }

    /// Timer-driven flight along a quadratic Bézier arc. The triangle turns to
    /// face where it's going and swells a little mid-flight.
    private func fly(to target: CGPoint, returning: Bool, completion: @escaping () -> Void) {
        flightTimer?.invalidate()
        navigation = returning ? .returning : .flying
        let start = position
        let distance = hypot(target.x - start.x, target.y - start.y)
        var duration = min(max(distance / 1400, 0.45), 1.1)
        if returning { duration *= 0.8 }
        // Lift the control point perpendicular to the path for a gentle arc.
        let mid = CGPoint(x: (start.x + target.x) / 2, y: (start.y + target.y) / 2)
        let lift = min(distance * 0.2, 160)
        let nx = -(target.y - start.y) / max(distance, 1), ny = (target.x - start.x) / max(distance, 1)
        let control = CGPoint(x: mid.x + nx * lift, y: mid.y + abs(ny) * lift + lift * 0.3)
        let began = Date()

        let path = Flight(start: start, control: control, target: target, began: began, duration: duration)
        flightTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                if self.step(path) {
                    timer.invalidate()
                    completion()
                }
            }
        }
        RunLoop.main.add(flightTimer!, forMode: .common)
    }

    private struct Flight {
        let start: CGPoint, control: CGPoint, target: CGPoint
        let began: Date
        let duration: Double
    }

    /// Advances one frame of a flight. Returns true when it has landed.
    private func step(_ f: Flight) -> Bool {
        let raw: Double = min(1, Date().timeIntervalSince(f.began) / f.duration)
        let t: CGFloat = raw < 0.5 ? CGFloat(4 * raw * raw * raw) : CGFloat(1 - pow(-2 * raw + 2, 3) / 2)
        let u: CGFloat = 1 - t
        let a: CGFloat = u * u, b: CGFloat = 2 * u * t, c: CGFloat = t * t
        position = CGPoint(x: a * f.start.x + b * f.control.x + c * f.target.x,
                           y: a * f.start.y + b * f.control.y + c * f.target.y)
        // Tangent of the curve gives the heading. View space has y flipped.
        let dx: CGFloat = 2 * u * (f.control.x - f.start.x) + 2 * t * (f.target.x - f.control.x)
        let dy: CGFloat = 2 * u * (f.control.y - f.start.y) + 2 * t * (f.target.y - f.control.y)
        // The triangle's tip points up-left (-135° in view space) at rest.
        var heading = Double(atan2(-dy, dx)) * 180 / .pi + 135
        if heading > 180 { heading -= 360 }
        if heading < -180 { heading += 360 }
        let blend: Double = raw > 0.85 ? (1 - raw) / 0.15 : min(1, raw / 0.1)
        rotation = heading * blend
        flightScale = 1 + 0.3 * CGFloat(sin(.pi * raw))
        if raw >= 1 {
            rotation = 0
            flightScale = 1
            return true
        }
        return false
    }
}
