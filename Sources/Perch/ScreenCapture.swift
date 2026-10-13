import AppKit
import ScreenCaptureKit

/// One captured display, with what we need to map image pixels back to screen points.
struct CapturedScreen {
    let index: Int            // 1-based, as shown to the model
    let jpegBase64: String
    let imageSize: CGSize     // pixels in the JPEG sent to the model
    let appKitFrame: CGRect   // the matching NSScreen frame (global AppKit coords)
    let isMain: Bool
    let containsCursor: Bool

    /// Convert a point in screenshot pixels (top-left origin) to global AppKit coordinates.
    func globalPoint(fromImagePoint p: CGPoint) -> CGPoint {
        let xPt = p.x / imageSize.width * appKitFrame.width
        let yPt = p.y / imageSize.height * appKitFrame.height
        return CGPoint(x: appKitFrame.minX + xPt, y: appKitFrame.maxY - yPt)
    }
}

enum ScreenCapture {
    static let maxImageWidth: CGFloat = 1280

    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    /// Captures every display, excluding this app's own windows (the buddy overlay).
    static func captureAll() async throws -> [CapturedScreen] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let mouse = NSEvent.mouseLocation

        // Put the screen with the cursor first so "screen 1" is where the user is looking.
        let screens = NSScreen.screens
        var results: [CapturedScreen] = []
        let displays = content.displays.sorted { a, b in
            let fa = screenFor(a.displayID, in: screens)?.frame.contains(mouse) ?? false
            let fb = screenFor(b.displayID, in: screens)?.frame.contains(mouse) ?? false
            return fa && !fb
        }

        for (i, display) in displays.enumerated() {
            guard let nsScreen = screenFor(display.displayID, in: screens) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = min(1, maxImageWidth / CGFloat(display.width))
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = true

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else { continue }

            results.append(CapturedScreen(
                index: i + 1,
                jpegBase64: jpeg.base64EncodedString(),
                imageSize: CGSize(width: cgImage.width, height: cgImage.height),
                appKitFrame: nsScreen.frame,
                isMain: nsScreen == NSScreen.main,
                containsCursor: nsScreen.frame.contains(mouse)
            ))
        }
        return results
    }

    private static func screenFor(_ displayID: CGDirectDisplayID, in screens: [NSScreen]) -> NSScreen? {
        screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }
}
