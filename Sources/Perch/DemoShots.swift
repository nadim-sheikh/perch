import AppKit
import ImageIO
import SwiftUI

/// `Perch --demo-shots <folder>` renders the README's demo images from the real views, using sample
/// text instead of the user's chats, and exits. Nothing on the screen is captured.
@MainActor
enum DemoShots {
    static func render(to folder: URL) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // The notch going from resting to listening, thinking and answering, as one animated GIF.
        let notchSize = CGSize(width: 640, height: 250)
        var frames: [(NSBitmapImageRep, Double)] = []
        for (presentation, seconds) in [(NotchModel.Presentation.docked, 1.2), (.listening, 1.6), (.thinking, 1.2), (.textResponse, 3.5)] {
            let model = demoNotch(presentation)
            model.responseQuestion = "How do I export this at 1080p?"
            model.responseText = "Open File, then Export, and pick Media. I've marked File for you, and I'll show the next step when it's open."
            model.dismissProgress = 0.7
            if let rep = snap(onDesktop(notch(model), height: notchSize.height), size: notchSize, to: folder,
                              presentation == .textResponse ? "notch-answer" : nil) {
                frames.append((rep, seconds))
            }
        }
        writeGIF(frames, to: folder.appendingPathComponent("notch-demo.gif"))

        snap(guideScene, size: CGSize(width: 760, height: 430), to: folder, "guide-marks")

        for (name, section) in [("settings-voice", SettingsSection.voice), ("settings-microphone", .microphone),
                                ("settings-shortcuts", .shortcuts), ("settings-general", .general)] {
            let view = HStack(spacing: 0) {
                SettingsSidebar(selection: section).frame(width: 210).background(Theme.sidebar)
                SettingsPage(section: section).background(Theme.window)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(20)
            .background(backdrop)
            snap(view, size: CGSize(width: 920, height: 620), to: folder, name)
        }
    }

    // MARK: Scenes

    private static func demoNotch(_ p: NotchModel.Presentation) -> NotchModel {
        let m = NotchModel()
        m.hardwareNotchWidth = 185
        m.notchHeight = 32
        m.presentation = p
        return m
    }

    private static func notch(_ model: NotchModel) -> some View {
        NotchRootView()
            .environmentObject(model)
            .environmentObject(BuddyState.shared)
            .environmentObject(ConversationStore.shared)
            .environmentObject(AgentManager.shared)
            .environmentObject(AgentRoster.shared)
    }

    private static var backdrop: some View {
        LinearGradient(colors: [Color(red: 0.20, green: 0.24, blue: 0.42), Color(red: 0.47, green: 0.33, blue: 0.55),
                                Color(red: 0.93, green: 0.62, blue: 0.52)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The notch hangs from a thin menu bar over a wallpaper, like on a MacBook.
    private static func onDesktop<V: View>(_ content: V, height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            backdrop
            Color.black.opacity(0.25).frame(height: 32)
            content
        }
        .frame(height: height)
    }

    /// Guide mode: a mock editor window with File highlighted, the cursor pointing and the bubble talking.
    private static var guideScene: some View {
        let pink = Color(red: 1.0, green: 0.36, blue: 0.62)
        let blue = Color(hex: "#3B82F6") ?? .blue
        return ZStack(alignment: .topLeading) {
            backdrop
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 11, height: 11) }
                    Text("Video Editor").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6)).padding(.leading, 10)
                }
                .padding(12)
                HStack(spacing: 18) {
                    ForEach(["File", "Edit", "Clip", "Sequence", "View"], id: \.self) {
                        Text($0).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)).frame(width: 150)
                    RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.5))
                }
                .padding(12)
            }
            .frame(width: 600, height: 330)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.13, green: 0.13, blue: 0.15)))
            .offset(x: 40, y: 50)
            // The mark on "File".
            RoundedRectangle(cornerRadius: 6).stroke(pink, lineWidth: 2.5)
                .background(RoundedRectangle(cornerRadius: 6).fill(pink.opacity(0.15)))
                .frame(width: 44, height: 26)
                .offset(x: 46, y: 88)
                .shadow(color: pink.opacity(0.7), radius: 6)
            CloudCursor(color: blue).frame(width: 28, height: 28).offset(x: 84, y: 108)
            Text("Click File up here, then Export → Media. I'll guide you through the rest.")
                .font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white).lineSpacing(2)
                .frame(width: 260, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 0.12, green: 0.125, blue: 0.145).opacity(0.96))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(blue.opacity(0.55), lineWidth: 1)))
                .shadow(color: .black.opacity(0.25), radius: 12)
                .offset(x: 118, y: 134)
        }
    }

    // MARK: Rendering

    /// Draws the view in an off-screen window (so AppKit controls render too) and saves a PNG when named.
    @discardableResult
    private static func snap<V: View>(_ view: V, size: CGSize, to folder: URL, _ name: String?) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).preferredColorScheme(.dark))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        defer { window.orderOut(nil) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let name { try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png")) }
        return rep
    }

    private static func writeGIF(_ frames: [(NSBitmapImageRep, Double)], to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (rep, seconds) in frames {
            guard let image = rep.cgImage else { continue }
            CGImageDestinationAddImage(dest, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: seconds]] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
    }
}
