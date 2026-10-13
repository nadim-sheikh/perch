import AppKit
import SwiftUI

/// Floating helper shown while System Settings is open: drag Perch's icon into the list.
@MainActor
enum PermissionGuide {
    private static var panel: NSPanel?

    static func open(_ kind: Kind) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.anchor)") {
            NSWorkspace.shared.open(url)
        }
        show(kind)
    }

    enum Kind: String {
        case screen, accessibility, microphone
        var anchor: String {
            switch self {
            case .screen: return "Privacy_ScreenCapture"
            case .accessibility: return "Privacy_Accessibility"
            case .microphone: return "Privacy_Microphone"
            }
        }
        var title: String {
            switch self {
            case .screen: return "Screen Recording"
            case .accessibility: return "Accessibility"
            case .microphone: return "Microphone"
            }
        }
    }

    private static func show(_ kind: Kind) {
        panel?.close()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 92),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: GuideCard(kind: kind) { close() })
        if let s = NSScreen.main {
            p.setFrameOrigin(NSPoint(x: s.visibleFrame.midX - 180, y: s.visibleFrame.minY + 40))
        }
        p.orderFrontRegardless()
        panel = p
        // Close by itself once the permission is granted.
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { t in
            MainActor.assumeIsolated {
                let s = PermissionSnapshot.current()
                let done = kind == .screen ? s.screen : kind == .accessibility ? s.accessibility : s.speech
                if done || panel == nil { t.invalidate(); if done { NSSound(named: "Glass")?.play(); close() } }
            }
        }
    }

    static func close() {
        panel?.close()
        panel = nil
    }
}

private struct GuideCard: View {
    let kind: PermissionGuide.Kind
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable().frame(width: 52, height: 52)
                .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
                .help("Drag me into the list")
            VStack(alignment: .leading, spacing: 3) {
                Text("Drag me into \(kind.title)").font(.system(size: 13, weight: .semibold))
                Text("Then flip my switch on. I'll wait right here.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle())
        }
        .padding(14)
        .frame(width: 360, height: 92)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(red: 0.1, green: 0.1, blue: 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.1)))
        .preferredColorScheme(.dark)
    }
}
