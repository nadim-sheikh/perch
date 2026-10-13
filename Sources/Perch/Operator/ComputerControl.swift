import AppKit
import ApplicationServices

/// Low-level mouse, keyboard, app and accessibility control.
/// Points are global AppKit coordinates (origin bottom-left of the main screen).
@MainActor
enum ComputerControl {
    // MARK: Mouse

    private static func quartz(_ p: CGPoint) -> CGPoint {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: mainHeight - p.y)
    }

    static func click(at p: CGPoint, button: CGMouseButton = .left, count: Int = 1) {
        let q = quartz(p)
        let (down, up): (CGEventType, CGEventType) = button == .right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: q, mouseButton: button)?.post(tap: .cghidEventTap)
        usleep(30_000)
        for i in 1...max(1, count) {
            let d = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: q, mouseButton: button)
            d?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            d?.post(tap: .cghidEventTap)
            let u = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: q, mouseButton: button)
            u?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            u?.post(tap: .cghidEventTap)
            usleep(60_000)
        }
    }

    static func drag(from a: CGPoint, to b: CGPoint) {
        let qa = quartz(a), qb = quartz(b)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: qa, mouseButton: .left)?.post(tap: .cghidEventTap)
        for i in 1...20 {
            let t = CGFloat(i) / 20
            let p = CGPoint(x: qa.x + (qb.x - qa.x) * t, y: qa.y + (qb.y - qa.y) * t)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(12_000)
        }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: qb, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    static func scroll(at p: CGPoint, dx: Int32, dy: Int32) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: quartz(p), mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    static func type(_ text: String) {
        let chars = Array(text.utf16)
        var i = 0
        while i < chars.count {
            let chunk = Array(chars[i..<min(i + 16, chars.count)])
            for keyDown in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown)
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e?.post(tap: .cghidEventTap)
            }
            usleep(12_000)
            i += 16
        }
    }

    /// Presses a combo like "cmd+shift+s", "return", "space", "left".
    @discardableResult
    static func key(_ combo: String) -> Bool {
        var flags: CGEventFlags = []
        var keyName = ""
        for part in combo.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: keyName = part
            }
        }
        guard let code = keyCodes[keyName] else { return false }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
            usleep(20_000)
        }
        return true
    }

    private static let keyCodes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
            "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
            "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        let f: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, c) in f.enumerated() { m["f\(i + 1)"] = c }
        return m
    }()

    // MARK: Apps

    /// Opens an app by (fuzzy) name. Returns the app name actually opened.
    static func openApp(_ name: String) async -> String? {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var candidates: [URL] = []
        for dir in dirs {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for item in items where item.hasSuffix(".app") { candidates.append(URL(fileURLWithPath: dir).appendingPathComponent(item)) }
            // one level deeper (e.g. /Applications/Adobe Premiere Pro 2026/…)
            for item in items where !item.hasSuffix(".app") {
                let sub = URL(fileURLWithPath: dir).appendingPathComponent(item)
                for inner in (try? FileManager.default.contentsOfDirectory(atPath: sub.path)) ?? [] where inner.hasSuffix(".app") {
                    candidates.append(sub.appendingPathComponent(inner))
                }
            }
        }
        func score(_ url: URL) -> Int {
            let n = url.deletingPathExtension().lastPathComponent.lowercased()
            if n == wanted { return 100 }
            if n.hasPrefix(wanted) { return 80 }
            if n.contains(wanted) { return 60 }
            let words = wanted.split(separator: " ")
            return words.allSatisfy { n.contains($0) } ? 50 : 0
        }
        guard let best = candidates.map({ ($0, score($0)) }).filter({ $0.1 > 0 }).max(by: { $0.1 < $1.1 })?.0 else { return nil }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: best, configuration: config)
        return best.deletingPathExtension().lastPathComponent
    }

    static func openFile(_ path: String, withApp app: String?) async -> Bool {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if let app, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)
            ?? findApp(named: app) {
            _ = try? await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        return NSWorkspace.shared.open(url)
    }

    private static func findApp(named name: String) -> URL? {
        NSWorkspace.shared.runningApplications.first { $0.localizedName?.lowercased().contains(name.lowercased()) == true }?.bundleURL
    }

    static func runAppleScript(_ source: String) -> String {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { return "Error: \(error[NSAppleScript.errorMessage] ?? error)" }
        return result?.stringValue ?? "ok"
    }

    // MARK: Accessibility

    struct UIElement {
        let id: Int
        let role: String
        let title: String
        let frame: CGRect     // global AppKit
        let element: AXUIElement
    }

    /// Clickable / readable elements in the frontmost app's focused window (+ menu bar).
    static func uiElements(limit: Int = 150) -> [UIElement] {
        guard let app = NSWorkspace.shared.frontmostApplication else { return [] }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var roots: [AXUIElement] = []
        if let w = attr(axApp, kAXFocusedWindowAttribute) { roots.append(w as! AXUIElement) }
        var out: [UIElement] = []
        let interesting: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXTextField",
                                        "AXTextArea", "AXLink", "AXMenuItem", "AXTab", "AXSlider", "AXComboBox", "AXCell", "AXStaticText", "AXImage"]
        var queue = roots
        var visited = 0
        while !queue.isEmpty, out.count < limit, visited < 4000 {
            let el = queue.removeFirst()
            visited += 1
            let role = attr(el, kAXRoleAttribute) as? String ?? ""
            if interesting.contains(role), let frame = frame(of: el), frame.width > 2, frame.height > 2 {
                let title = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute]
                    .compactMap { attr(el, $0) as? String }.first { !$0.isEmpty } ?? ""
                if !(role == "AXStaticText" && title.isEmpty) && !(role == "AXImage" && title.isEmpty) {
                    out.append(UIElement(id: out.count, role: role.replacingOccurrences(of: "AX", with: ""),
                                         title: String(title.prefix(60)), frame: frame, element: el))
                }
            }
            if let children = attr(el, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children) }
        }
        return out
    }

    static func press(_ el: AXUIElement) -> Bool {
        AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        guard let posV = attr(el, kAXPositionAttribute), let sizeV = attr(el, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posV as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeV as! AXValue, .cgSize, &size)
        // AX uses top-left global coordinates; convert to AppKit.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: pos.x, y: mainHeight - pos.y - size.height, width: size.width, height: size.height)
    }
}
