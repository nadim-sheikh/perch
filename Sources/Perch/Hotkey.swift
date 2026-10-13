import AppKit

/// Hold Control+Option (and nothing else) to talk. Uses a global modifier
/// monitor, which needs Accessibility permission to see keys in other apps.
@MainActor
final class PushToTalkMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Double-tapping Control on its own opens the typing box.
    var onDoubleTapControl: (() -> Void)?

    private var controlDownAt: Date?
    private var lastControlTapAt: Date?
    private var otherKeyDuringControl = false

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false
    private let combo: NSEvent.ModifierFlags = [.control, .option]

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        detectControlDoubleTap(flags)
        let pressed = flags == combo
        if pressed && !isDown {
            isDown = true
            onPress?()
        } else if !pressed && isDown {
            isDown = false
            onRelease?()
        }
    }

    private func detectControlDoubleTap(_ flags: NSEvent.ModifierFlags) {
        let now = Date()
        if flags == [.control] {
            controlDownAt = now
            otherKeyDuringControl = false
        } else if flags.isEmpty, let down = controlDownAt {
            controlDownAt = nil
            guard !otherKeyDuringControl, now.timeIntervalSince(down) < 0.3 else { return }
            if let last = lastControlTapAt, now.timeIntervalSince(last) < 0.4 {
                lastControlTapAt = nil
                onDoubleTapControl?()
            } else {
                lastControlTapAt = now
            }
        } else {
            otherKeyDuringControl = true
            controlDownAt = nil
        }
    }

    nonisolated static func hasAccessibility(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}
