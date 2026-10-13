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

    /// Buddy position in global AppKit coordinates (origin bottom-left of main screen).
    @Published var position: CGPoint = NSEvent.mouseLocation
    @Published var phase: BuddyPhase = .idle
    @Published var bubbleText: String = ""
    @Published var pointLabel: String?
    @Published var audioLevel: Float = 0
    @Published var isPointing = false

    private var followTimer: Timer?
    private let cursorOffset = CGPoint(x: 22, y: -26)

    func startFollowingCursor() {
        followTimer?.invalidate()
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isPointing, AppSettings.shared.followCursor else { return }
                let mouse = NSEvent.mouseLocation
                let target = CGPoint(x: mouse.x + self.cursorOffset.x, y: mouse.y + self.cursorOffset.y)
                // Ease toward the cursor so the buddy trails it smoothly.
                self.position = CGPoint(
                    x: self.position.x + (target.x - self.position.x) * 0.25,
                    y: self.position.y + (target.y - self.position.y) * 0.25
                )
            }
        }
        RunLoop.main.add(followTimer!, forMode: .common)
    }

    /// Fly to a global point, hold there, then return to following the cursor.
    func point(at target: CGPoint, label: String?, hold: TimeInterval = 4.0) {
        isPointing = true
        pointLabel = label
        withAnimation(.spring(response: 0.7, dampingFraction: 0.75)) {
            position = target
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard let self else { return }
            self.pointLabel = nil
            self.isPointing = false
        }
    }
}
