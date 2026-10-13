import AppKit

/// Precise screen marks from macOS Accessibility.
///
/// Fast vision models are poor at guessing pixel coordinates. So before asking, Perch reads the
/// real buttons, menus and fields of the app you're using, draws a small number on each one in
/// the screenshot, and lists them for the model. The model marks by number (`[MARK:12:label]`)
/// and Perch highlights that element's exact frame. Pixel guesses are snapped to the element under them.
@MainActor
enum ElementMarks {
    struct Item {
        let number: Int
        let role: String
        let title: String
        let frame: CGRect   // global AppKit
    }

    struct Map {
        let items: [Item]
        let screen: CapturedScreen
        func item(_ n: Int) -> Item? { items.first { $0.number == n } }
    }

    /// The last app the user was in other than Perch (when they type into Perch's notch box,
    /// Perch is frontmost, but they mean the app behind it).
    private(set) static var lastExternalApp: NSRunningApplication?

    static func startTracking() {
        lastExternalApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == NSRunningApplication.current ? nil : $0 }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { lastExternalApp = app }
        }
    }

    /// Reads the elements on `screen` and returns the map plus a screenshot with numbers drawn on.
    static func build(for screen: CapturedScreen) -> (Map, CapturedScreen)? {
        let front = NSWorkspace.shared.frontmostApplication
        let app = front == NSRunningApplication.current ? lastExternalApp : front
        let raw = ComputerControl.uiElements(of: app, limit: 140)
        let screenArea = screen.appKitFrame.width * screen.appKitFrame.height
        var items: [Item] = []
        for el in raw {
            let f = el.frame.intersection(screen.appKitFrame)
            guard !f.isNull, f.width >= 4, f.height >= 4, f.width * f.height < screenArea * 0.5 else { continue }
            // Skip unnamed decorative text; keep anything clickable even without a title.
            if el.role == "StaticText" && el.title.isEmpty { continue }
            items.append(Item(number: items.count + 1, role: el.role, title: el.title, frame: f))
        }
        guard !items.isEmpty else { return nil }
        let map = Map(items: items, screen: screen)
        return (map, annotate(screen, items) ?? screen)
    }

    /// Text list for the prompt: number, role, name and centre in screenshot pixels.
    static func promptList(_ map: Map) -> String {
        let s = map.screen
        let lines = map.items.map { it -> String in
            let c = imagePoint(CGPoint(x: it.frame.midX, y: it.frame.midY), s)
            let name = it.title.isEmpty ? "" : " \"\(it.title.prefix(50))\""
            return "\(it.number): \(it.role)\(name) at \(Int(c.x)),\(Int(c.y))"
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Parsing

    private static let markRegex = try! NSRegularExpression(pattern: #"\[MARK:\s*(\d+)\s*(?::\s*([^\]]*))?\]"#, options: [.caseInsensitive])

    static func marks(in text: String, map: Map?) -> [ScreenMark] {
        guard let map else { return [] }
        let ns = NSRange(text.startIndex..., in: text)
        return markRegex.matches(in: text, range: ns).compactMap { m in
            guard let r = Range(m.range(at: 1), in: text), let n = Int(text[r]), let it = map.item(n) else { return nil }
            let label = Range(m.range(at: 2), in: text).map { text[$0].trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            return ScreenMark(kind: .highlight(it.frame.insetBy(dx: -2, dy: -2)), label: label ?? (it.title.isEmpty ? nil : it.title))
        }
    }

    /// The smallest element under a point, to snap a guessed coordinate onto something real.
    static func element(at p: CGPoint, map: Map?) -> Item? {
        guard let map else { return nil }
        let hits = map.items.filter { $0.frame.insetBy(dx: -6, dy: -6).contains(p) }
        return hits.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// Snaps highlight/circle marks made from pixel guesses onto the real element underneath.
    static func snap(_ marks: [ScreenMark], map: Map?) -> [ScreenMark] {
        guard map != nil else { return marks }
        return marks.map { m in
            guard let it = element(at: m.anchor, map: map) else { return m }
            switch m.kind {
            case .highlight, .circle:
                return ScreenMark(kind: .highlight(it.frame.insetBy(dx: -2, dy: -2)), label: m.label ?? (it.title.isEmpty ? nil : it.title))
            case .arrow(let from, _):
                return ScreenMark(kind: .arrow(from, CGPoint(x: it.frame.midX, y: it.frame.midY)), label: m.label)
            }
        }
    }

    // MARK: Drawing numbers on the screenshot

    private static func imagePoint(_ g: CGPoint, _ s: CapturedScreen) -> CGPoint {
        CGPoint(x: (g.x - s.appKitFrame.minX) / s.appKitFrame.width * s.imageSize.width,
                y: (s.appKitFrame.maxY - g.y) / s.appKitFrame.height * s.imageSize.height)
    }

    private static func annotate(_ s: CapturedScreen, _ items: [Item]) -> CapturedScreen? {
        guard let data = Data(base64Encoded: s.jpegBase64), let src = NSImage(data: data) else { return nil }
        let size = s.imageSize
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size   // 1 point = 1 pixel, so marks line up exactly
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        src.draw(in: NSRect(origin: .zero, size: size))
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        for it in items {
            // Top-left corner of the element in image space (drawing is bottom-up).
            let tl = imagePoint(CGPoint(x: it.frame.minX, y: it.frame.maxY), s)
            let br = imagePoint(CGPoint(x: it.frame.maxX, y: it.frame.minY), s)
            let box = NSRect(x: tl.x, y: size.height - br.y, width: br.x - tl.x, height: br.y - tl.y)
            NSColor.systemPink.withAlphaComponent(0.55).setStroke()
            let outline = NSBezierPath(rect: box); outline.lineWidth = 1; outline.stroke()
            let text = "\(it.number)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let ts = text.size(withAttributes: attrs)
            let tag = NSRect(x: box.minX, y: box.maxY - ts.height - 1, width: ts.width + 4, height: ts.height + 1)
            NSColor.systemPink.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: tag, xRadius: 3, yRadius: 3).fill()
            text.draw(at: NSPoint(x: tag.minX + 2, y: tag.minY), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return nil }
        return CapturedScreen(index: s.index, jpegBase64: jpeg.base64EncodedString(), imageSize: s.imageSize,
                              appKitFrame: s.appKitFrame, displayID: s.displayID, containsCursor: s.containsCursor)
    }
}
