import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = OverlayManager()
    private let companion = Companion()
    private let hotkey = PushToTalkMonitor()
    private var settingsWindow: NSWindow?
    private var askPanel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        overlay.show()
        BuddyState.shared.startFollowingCursor()

        hotkey.onPress = { [weak self] in self?.companion.beginListening() }
        hotkey.onRelease = { [weak self] in self?.companion.endListening() }
        hotkey.start()

        Task {
            _ = await SpeechRecognizer.requestPermissions()
            if !ScreenCapture.hasPermission() { ScreenCapture.requestPermission() }
            _ = PushToTalkMonitor.hasAccessibility(prompt: true)
            if AppSettings.shared.activeKey.isEmpty { openSettings() }
        }
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "OpenBuddy")

        let menu = NSMenu()
        menu.addItem(withTitle: "Hold ⌃⌥ to talk", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(item("Ask by typing…", #selector(showAskPanel), "k"))
        menu.addItem(item("Stop talking", #selector(stopTalking), "."))
        menu.addItem(item("New conversation", #selector(newConversation), "n"))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), ","))
        menu.addItem(item("Quit OpenBuddy", #selector(quit), "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            w.title = "OpenBuddy Settings"
            w.contentView = NSHostingView(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showAskPanel() {
        askPanel?.close()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 56),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: AskField { [weak self, weak panel] text in
            panel?.close()
            self?.companion.askTyped(text)
        })
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - 230, y: screen.frame.maxY - 220))
        }
        askPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func stopTalking() { companion.interrupt(); BuddyState.shared.bubbleText = "" }
    @objc func newConversation() { companion.resetConversation() }
    @objc func quit() { NSApp.terminate(nil) }
}

struct AskField: View {
    let onSubmit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Ask about anything on your screen…", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
            .focused($focused)
            .onSubmit {
                let t = text.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { onSubmit(t) }
            }
            .onAppear { focused = true }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
