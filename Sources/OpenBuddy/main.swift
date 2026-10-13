import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = OverlayManager()
    private let notch = NotchController()
    private let companion = Companion.shared
    private let hotkey = PushToTalkMonitor()
    private var homeWindow: NSWindow?
    private var askPanel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        overlay.show()
        BuddyState.shared.startFollowingCursor()

        NotchModel.shared.openHome = { [weak self] id in
            if let id { HomeRouter.shared.openChat(id) } else { HomeRouter.shared.settings = nil }
            self?.showHome()
        }
        NotchModel.shared.openSettings = { [weak self] in self?.openSettings() }
        NotchModel.shared.openAgent = { [weak self] slug in
            HomeRouter.shared.openAgent(slug)
            self?.showHome()
        }
        notch.show()

        hotkey.onPress = { [weak self] in self?.companion.beginListening() }
        hotkey.onRelease = { [weak self] in self?.companion.endListening() }
        hotkey.onDoubleTapControl = { NotchModel.shared.openTextInput() }
        hotkey.start()
        AppAppearance.apply()

        Task {
            _ = await SpeechRecognizer.requestPermissions()
            if !ScreenCapture.hasPermission() { ScreenCapture.requestPermission() }
            _ = PushToTalkMonitor.hasAccessibility(prompt: true)
            if AppSettings.shared.activeKey.isEmpty && !CommandLine.arguments.contains("--home") {
                HomeRouter.shared.settings = .ai
            }
            showHome()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHome()
        return true
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "OpenBuddy")

        let menu = NSMenu()
        menu.addItem(withTitle: "Hold ⌃⌥ to talk", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(item("Open Home", #selector(openHomeFromMenu), "h"))
        menu.addItem(item("Ask by typing…", #selector(showAskPanel), "k"))
        menu.addItem(item("Stop talking", #selector(stopTalking), "."))
        menu.addItem(item("New chat", #selector(newConversation), "n"))
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

    func showHome() {
        if homeWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.standardWindowButton(.closeButton)?.isHidden = true
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            w.backgroundColor = NSColor(Theme.window)
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: HomeView(onClose: { [weak w] in w?.orderOut(nil) }))
            w.center()
            homeWindow = w
            AppAppearance.apply()
        }
        NSApp.activate(ignoringOtherApps: true)
        homeWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openHomeFromMenu() {
        HomeRouter.shared.settings = nil
        showHome()
    }

    @objc func openSettings() {
        HomeRouter.shared.settings = .general
        showHome()
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
        panel.appearance = NSAppearance(named: .darkAqua)
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
