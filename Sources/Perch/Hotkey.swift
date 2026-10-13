import AppKit

/// Global keyboard shortcuts. Needs Accessibility permission to see keys in other apps.
/// - Hold Control+Option: talk to Perch.
/// - Double-tap Control: open the type box in the notch.
/// - Hold Control+Shift: dictate into the focused text field.
/// (Option+Shift+U, fix spelling, is a `CarbonHotKey` registered in main.swift.)
///
/// Hold combos start on a short delay, and any key press cancels a pending hold,
/// so a shortcut like Ctrl+Option+T never accidentally starts voice listening. A key
/// pressed while already listening cancels the listen instead of sending it.
@MainActor
final class PushToTalkMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Talk combo turned out to be part of a shortcut: drop the listen without sending it.
    var onCancelTalk: (() -> Void)?
    var onDoubleTapControl: (() -> Void)?
    var onDictateStart: (() -> Void)?
    var onDictateEnd: (() -> Void)?

    private var controlDownAt: Date?
    private var lastControlTapAt: Date?
    private var otherKeyDuringControl = false
    private var lastFlags: NSEvent.ModifierFlags = []

    private var monitors: [Any] = []

    private var talkActive = false
    private var dictateActive = false
    private var pendingTalk: DispatchWorkItem?
    private var pendingDictate: DispatchWorkItem?
    private let holdDelay: TimeInterval = 0.2
    private let talkCombo: NSEvent.ModifierFlags = [.control, .option]
    private let dictateCombo: NSEvent.ModifierFlags = [.control, .shift]

    func start() {
        for mask in [NSEvent.EventTypeMask.flagsChanged] {
            monitors.append(NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in
                MainActor.assumeIsolated { self?.handleFlags(e) }
            } as Any)
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
                MainActor.assumeIsolated { self?.handleFlags(e) }
                return e
            } as Any)
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated { self?.handleKey(e) }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated { self?.handleKey(e) }
            return e
        } as Any)
    }

    private func handleFlags(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        detectControlDoubleTap(flags)

        // Talk (hold, delayed)
        if flags == talkCombo {
            if pendingTalk == nil && !talkActive {
                let w = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingTalk = nil
                    self.talkActive = true
                    self.onPress?()
                }
                pendingTalk = w
                DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: w)
            }
        } else {
            pendingTalk?.cancel(); pendingTalk = nil
            if talkActive { talkActive = false; onRelease?() }
        }

        // Dictation (hold, delayed)
        if flags == dictateCombo {
            if pendingDictate == nil && !dictateActive {
                let w = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingDictate = nil
                    self.dictateActive = true
                    self.onDictateStart?()
                }
                pendingDictate = w
                DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: w)
            }
        } else {
            pendingDictate?.cancel(); pendingDictate = nil
            if dictateActive { dictateActive = false; onDictateEnd?() }
        }
    }

    private func handleKey(_ event: NSEvent) {
        // A real key press means the user is doing a shortcut, not holding to talk.
        pendingTalk?.cancel(); pendingTalk = nil
        pendingDictate?.cancel(); pendingDictate = nil
        if talkActive && event.modifierFlags.contains(talkCombo) {
            talkActive = false
            onCancelTalk?()
        }
        // Ctrl+A then Ctrl+E is typing, not a double-tap.
        otherKeyDuringControl = true
        lastControlTapAt = nil
    }

    private func detectControlDoubleTap(_ flags: NSEvent.ModifierFlags) {
        let now = Date()
        let previous = lastFlags
        lastFlags = flags
        if flags == [.control] {
            // Only a fresh press starts a tap, not letting go of another modifier.
            guard previous.isEmpty else { return }
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
        } else if !flags.isEmpty {
            otherKeyDuringControl = true
            controlDownAt = nil
            lastControlTapAt = nil
        }
    }

    nonisolated static func hasAccessibility(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}
