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
        let q = quartz(p)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: q, mouseButton: .left)?.post(tap: .cghidEventTap)
        // Like click: let the move land first, and pin the wheel event to the point too.
        usleep(30_000)
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        e?.location = q
        e?.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    /// Types text into the focused field. Line breaks press Return; emoji are never split.
    static func type(_ text: String) {
        for (n, line) in text.components(separatedBy: "\n").enumerated() {
            if n > 0 { key("return") }
            var chunk: [UniChar] = []
            func send() {
                guard !chunk.isEmpty else { return }
                for keyDown in [true, false] {
                    let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown)
                    e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    e?.post(tap: .cghidEventTap)
                }
                usleep(12_000)
                chunk = []
            }
            for ch in line {
                let units = Array(String(ch).utf16)
                if chunk.count + units.count > 16 { send() }
                chunk += units
            }
            send()
        }
    }

    /// Presses a combo like "cmd+shift+s", "return", "space", "left", "cmd++" / "cmd+plus", "cmd+minus".
    @discardableResult
    static func key(_ combo: String) -> Bool {
        var flags: CGEventFlags = []
        var keyName = ""
        var spec = combo.lowercased().trimmingCharacters(in: .whitespaces)
        // "+" is both the separator and a key: a trailing "++" (or a lone "+") means the plus key.
        if spec == "+" || spec.hasSuffix("++") {
            keyName = "+"
            spec = String(spec.dropLast(spec == "+" ? 1 : 2))
        }
        for part in spec.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: keyName = part
            }
        }
        // Plus is Shift + "=" on the keyboard.
        if keyName == "+" || keyName == "plus" { keyName = "="; flags.insert(.maskShift) }
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
            "minus": 27, "equals": 24,
            "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        let f: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, c) in f.enumerated() { m["f\(i + 1)"] = c }
        return m
    }()

    // MARK: Apps

    /// Finds an installed app by (fuzzy) name. `minScore` 80 accepts only exact or prefix matches.
    static func appURL(named name: String, minScore: Int = 1) -> URL? {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/System/Library/CoreServices",
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
        return candidates.map({ ($0, score($0)) }).filter({ $0.1 >= minScore }).max(by: { $0.1 < $1.1 })?.0
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

    // MARK: Accessibility

    struct UIElement {
        let id: Int
        let role: String
        let title: String
        let frame: CGRect     // global AppKit
        let element: AXUIElement
    }

    /// Clickable / readable elements in the frontmost app's focused window, then its menu bar
    /// (the top-level menus, plus the items of a menu that is open).
    static func uiElements(limit: Int = 150) -> [UIElement] {
        guard let app = NSWorkspace.shared.frontmostApplication else { return [] }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // A busy or hung app must not freeze Perch for seconds per element.
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        enableAccessibilityTree(of: app, axApp)

        var menuRoots: [AXUIElement] = []
        if let bar = attr(axApp, kAXMenuBarAttribute) {
            for item in attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                menuRoots.append(item)
                // Only an open menu's items are on screen; closed ones have no usable frames.
                if attr(item, kAXSelectedAttribute) as? Bool == true { menuRoots.append(contentsOf: children(of: item)) }
            }
        }
        var out: [UIElement] = []
        if let w = attr(axApp, kAXFocusedWindowAttribute) {
            collect(from: [w as! AXUIElement], into: &out, limit: max(limit - menuRoots.count, limit / 2), maxVisits: 4000)
        }
        collect(from: menuRoots, into: &out, limit: limit, maxVisits: 1000)
        return out
    }

    private static let interestingRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXLink",
        "AXMenuBarItem", "AXMenuItem", "AXTab", "AXSlider", "AXComboBox", "AXCell", "AXStaticText", "AXImage",
    ]

    /// Breadth-first walk from `roots`, appending readable elements until `limit` is reached.
    private static func collect(from roots: [AXUIElement], into out: inout [UIElement], limit: Int, maxVisits: Int) {
        var queue = roots
        var head = 0
        while head < queue.count, out.count < limit, head < maxVisits {
            let el = queue[head]
            head += 1
            let role = attr(el, kAXRoleAttribute) as? String ?? ""
            if interestingRoles.contains(role), let frame = frame(of: el), frame.width > 2, frame.height > 2 {
                let title = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute]
                    .compactMap { attr(el, $0) as? String }.first { !$0.isEmpty } ?? ""
                if !(role == "AXStaticText" && title.isEmpty) && !(role == "AXImage" && title.isEmpty) {
                    out.append(UIElement(id: out.count, role: role.replacingOccurrences(of: "AX", with: ""),
                                         title: String(title.prefix(60)), frame: frame, element: el))
                }
            }
            // Menu bar items are listed on their own; don't wander into every closed menu.
            if role != "AXMenuBarItem" { queue.append(contentsOf: children(of: el)) }
        }
    }

    private static func children(of el: AXUIElement) -> [AXUIElement] {
        attr(el, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// Apps whose accessibility tree we already switched on (keyed by pid).
    private static var enabledTrees: Set<pid_t> = []

    /// Chromium and Electron apps (Chrome, Slack, VS Code…) only expose their page content once
    /// asked to. Other apps ignore the attribute. The tree is built asynchronously, so wait a moment
    /// the first time.
    private static func enableAccessibilityTree(of app: NSRunningApplication, _ axApp: AXUIElement) {
        guard !enabledTrees.contains(app.processIdentifier) else { return }
        enabledTrees.insert(app.processIdentifier)
        var changed = AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
        // Chrome only honours the older VoiceOver flag; it changes window animations elsewhere, so keep it to Chrome.
        if app.bundleIdentifier?.hasPrefix("com.google.Chrome") == true {
            changed = AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success || changed
        }
        if changed { usleep(250_000) }
    }

    static func press(_ el: AXUIElement) -> Bool {
        AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    /// An element's current frame in global AppKit coordinates, or nil when it's gone.
    static func frame(of el: AXUIElement) -> CGRect? {
        guard let posV = attr(el, kAXPositionAttribute), let sizeV = attr(el, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posV as! AXValue, .cgPoint, &pos), AXValueGetValue(sizeV as! AXValue, .cgSize, &size) else { return nil }
        // AX uses top-left global coordinates; convert to AppKit.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: pos.x, y: mainHeight - pos.y - size.height, width: size.width, height: size.height)
    }
}
