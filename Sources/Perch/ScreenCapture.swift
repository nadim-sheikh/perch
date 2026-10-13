import AppKit
import ScreenCaptureKit

/// One captured display, with what we need to map image pixels back to screen points.
struct CapturedScreen {
    let index: Int            // 1-based, as shown to the model
    let jpegBase64: String
    let imageSize: CGSize     // pixels in the JPEG sent to the model
    let appKitFrame: CGRect   // the matching NSScreen frame (global AppKit coords)
    let displayID: CGDirectDisplayID
    let containsCursor: Bool

    /// Convert a point in screenshot pixels (top-left origin) to global AppKit coordinates.
    func globalPoint(fromImagePoint p: CGPoint) -> CGPoint {
        let xPt = p.x / imageSize.width * appKitFrame.width
        let yPt = p.y / imageSize.height * appKitFrame.height
        return CGPoint(x: appKitFrame.minX + xPt, y: appKitFrame.maxY - yPt)
    }

    /// False once the display was unplugged, moved or resized since the screenshot,
    /// so its pixel coordinates no longer map to the same place. Check before clicking.
    @MainActor var isStillValid: Bool {
        ScreenCapture.screen(for: displayID, in: NSScreen.screens)?.frame == appKitFrame
    }
}

enum ScreenCapture {
    static let maxImageWidth: CGFloat = 1280

    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    /// The screen under the cursor. Edges count as inside (NSMouseInRect), so the shared edge
    /// between two displays resolves the same way everywhere; otherwise the nearest screen.
    @MainActor static func cursorScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        if let hit = screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) { return hit }
        return screens.min { distance(mouse, $0.frame) < distance(mouse, $1.frame) }
    }

    /// Captures only the display the cursor is on: every extra screenshot costs tokens.
    static func captureCursorScreen() async throws -> CapturedScreen? {
        try await capture(onlyCursorScreen: true).first
    }

    /// Captures every display (cursor screen first), excluding this app's own windows (the buddy overlay).
    /// A display that fails to capture is skipped instead of failing the whole capture.
    static func captureAll() async throws -> [CapturedScreen] {
        try await capture(onlyCursorScreen: false)
    }

    private static func capture(onlyCursorScreen: Bool) async throws -> [CapturedScreen] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let (frames, cursorID) = await MainActor.run { () -> ([CGDirectDisplayID: CGRect], CGDirectDisplayID?) in
            (Dictionary(NSScreen.screens.map { (displayID(of: $0), $0.frame) }, uniquingKeysWith: { a, _ in a }),
             cursorScreen().map(displayID(of:)))
        }

        // Put the screen with the cursor first so "screen 1" is where the user is looking.
        var displays = content.displays.sorted { a, b in a.displayID == cursorID && b.displayID != cursorID }
        if onlyCursorScreen { displays = Array(displays.filter { $0.displayID == cursorID }.prefix(1)) }

        var results: [CapturedScreen] = []
        var lastError: Error?
        for display in displays {
            guard let frame = frames[display.displayID] else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = min(1, maxImageWidth / CGFloat(display.width))
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = true

            let cgImage: CGImage
            do {
                cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            } catch {
                lastError = error
                continue
            }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else { continue }

            results.append(CapturedScreen(
                index: results.count + 1,
                jpegBase64: jpeg.base64EncodedString(),
                imageSize: CGSize(width: cgImage.width, height: cgImage.height),
                appKitFrame: frame,
                displayID: display.displayID,
                containsCursor: display.displayID == cursorID
            ))
        }
        // Only report a failure when nothing at all could be captured.
        if results.isEmpty, let lastError { throw lastError }
        return results
    }

    static func screen(for displayID: CGDirectDisplayID, in screens: [NSScreen]) -> NSScreen? {
        screens.first { self.displayID(of: $0) == displayID }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }
}
