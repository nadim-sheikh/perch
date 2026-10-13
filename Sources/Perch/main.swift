import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = OverlayManager()
    private let notch = NotchController()
    private let companion = Companion.shared
    private let hotkey = PushToTalkMonitor()
    private var askPanel: NSPanel?
    private var fixHotKey: CarbonHotKey?

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
        IntegrationSuggestions.shared.start()
        ElementMarks.startTracking()
        SpeechRecognizer.preloadParakeet()
        Speaker.warmUp()

        hotkey.onPress = { [weak self] in self?.companion.beginListening() }
        hotkey.onRelease = { [weak self] in self?.companion.endListening() }
        hotkey.onCancelTalk = { [weak self] in self?.companion.cancelListening() }
        hotkey.onDoubleTapControl = { NotchModel.shared.openTextInput() }
        hotkey.onDictateStart = { TextTools.shared.startDictation() }
        hotkey.onDictateEnd = { TextTools.shared.endDictation() }
        hotkey.start()
        // Option+Shift+U fixes the selected text (consumed so no accent is typed).
        fixHotKey = CarbonHotKey(keyCode: UInt32(kVK_ANSI_U), modifiers: UInt32(optionKey | shiftKey)) {
            TextTools.shared.fixFocusedText()
        }
        DebugLog.write("fix hotkey Option+Shift+U registered: \(fixHotKey != nil)")
        AppAppearance.apply()

        Task {
            _ = await SpeechRecognizer.requestPermissions()
            if !ScreenCapture.hasPermission() { ScreenCapture.requestPermission() }
            _ = PushToTalkMonitor.hasAccessibility(prompt: true)
            // Home opens when the user clicks a chat or the expand button. The exception is a first
            // run with no key, where Home opens on AI Models to ask for one.
            if !AppSettings.shared.hasKey {
                HomeRouter.shared.settings = .ai
                showHome()
            } else if CommandLine.arguments.contains("--home") {
                showHome()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop helper runs and their child processes so nothing keeps working after Perch quits,
        // close connected-app servers, and write any chat changes still waiting to be saved.
        AgentManager.shared.shutdown()
        MCPPool.shared.closeAll()
        ConversationStore.shared.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHome()
        return true
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Perch")

        let menu = NSMenu()
        menu.addItem(withTitle: "Hold ⌃⌥ to talk", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(item("Open Home", #selector(openHomeFromMenu), "h"))
        menu.addItem(item("Ask by typing…", #selector(showAskPanel), "k"))
        menu.addItem(item("Stop talking", #selector(stopTalking), "."))
        menu.addItem(item("New chat", #selector(newConversation), "n"))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), ","))
        menu.addItem(item("Quit Perch", #selector(quit), "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    /// Home lives inside the notch panel: one shape that grows and shrinks.
    func showHome() {
        // The notch activates Perch itself, after noting which app to hand focus back to.
        NotchModel.shared.openHomePanel()
    }

    func hideHome() {
        NotchModel.shared.closeHome()
    }

    @objc func openHomeFromMenu() {
        HomeRouter.shared.settings = nil
        showHome()
    }

    @objc func openSettings() {
        HomeRouter.shared.settings = AppSettings.shared.hasKey ? .general : .ai
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
        // Hand focus back to the app the user was in, so the buddy (and any helper) acts there, not on Perch.
        let previousApp = NSWorkspace.shared.frontmostApplication
        panel.contentView = NSHostingView(rootView: AskField { [weak self, weak panel] text in
            panel?.close()
            if let previousApp, previousApp != NSRunningApplication.current { previousApp.activate() }
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

Migration.run()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

