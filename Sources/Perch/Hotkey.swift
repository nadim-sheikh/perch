import AppKit

/// Global keyboard shortcuts. Needs Accessibility permission to see keys in other apps.
/// - Hold Control+Option: talk to Perch.
/// - Double-tap Control: open the type box in the notch.
/// - Hold Control+Shift: dictate into the focused text field.
/// - Press Control+Option+F: fix spelling in the focused text field.
@MainActor
final class PushToTalkMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onDoubleTapControl: (() -> Void)?
    var onDictateStart: (() -> Void)?
    var onDictateEnd: (() -> Void)?
    var onFixText: (() -> Void)?

    private var controlDownAt: Date?
    private var lastControlTapAt: Date?
    private var otherKeyDuringControl = false

    private var flagsGlobal: Any?
    private var flagsLocal: Any?
    private var keyGlobal: Any?
    private var keyLocal: Any?

    private var isDown = false
    private var dictateDown = false
    private let talkCombo: NSEvent.ModifierFlags = [.control, .option]
    private let dictateCombo: NSEvent.ModifierFlags = [.control, .shift]

    func start() {
        flagsGlobal = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            MainActor.assumeIsolated { self?.handleFlags(e) }
        }
        flagsLocal = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            MainActor.assumeIsolated { self?.handleFlags(e) }
            return e
        }
        keyGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated { self?.handleKey(e) }
        }
        keyLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated { self?.handleKey(e) }
            return e
        }
    }

    private func handleFlags(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        detectControlDoubleTap(flags)

        let talk = flags == talkCombo
        if talk && !isDown { isDown = true; onPress?() }
        else if !talk && isDown { isDown = false; onRelease?() }

        let dictate = flags == dictateCombo
        if dictate && !dictateDown { dictateDown = true; onDictateStart?() }
        else if !dictate && dictateDown { dictateDown = false; onDictateEnd?() }
    }

    private func handleKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        if flags == [.control, .option], event.keyCode == 3 { onFixText?() }   // F
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
