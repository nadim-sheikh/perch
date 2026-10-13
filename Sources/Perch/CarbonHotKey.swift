import AppKit
import Carbon.HIToolbox

/// Thread-safe store for hotkey actions, keyed by hotkey id.
private final class HotKeyRegistry: @unchecked Sendable {
    static let shared = HotKeyRegistry()
    private let lock = NSLock()
    private var actions: [UInt32: () -> Void] = [:]
    private var installed = false
    private var nextID: UInt32 = 1

    func reserveID() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        let id = nextID; nextID += 1; return id
    }
    func set(_ id: UInt32, _ action: (() -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        actions[id] = action
    }
    func fire(_ id: UInt32) {
        lock.lock(); let action = actions[id]; lock.unlock()
        action?()
    }
    func installHandlerIfNeeded() {
        lock.lock(); let already = installed; installed = true; lock.unlock()
        guard !already else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeyRegistry.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// A real system hotkey that is consumed when pressed, so the key never reaches
/// the focused app (no stray characters from dead keys like Option+U).
@MainActor
final class CarbonHotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// `keyCode` is a Carbon virtual key (e.g. kVK_ANSI_U); `modifiers` are Carbon
    /// flags (optionKey, shiftKey, cmdKey, controlKey).
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        HotKeyRegistry.shared.installHandlerIfNeeded()
        id = HotKeyRegistry.shared.reserveID()
        HotKeyRegistry.shared.set(id) { DispatchQueue.main.async { action() } }
        let hotKeyID = EventHotKeyID(signature: OSType(0x50524348) /* 'PRCH' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { HotKeyRegistry.shared.set(id, nil); return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKeyRegistry.shared.set(id, nil)
    }
}
