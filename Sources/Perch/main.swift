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
        IntegrationSuggestions.shared.start()
        if let i = CommandLine.arguments.firstIndex(of: "--ask"), i + 1 < CommandLine.arguments.count {
            let question = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Companion.shared.askTyped(question) }
        }
        SpeechRecognizer.preloadParakeet()

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

    private var homeCover: NSView?

    /// The notch's own rectangle at the top of the screen (where Home morphs from/to).
    private func notchFrame(_ screen: NSScreen) -> NSRect {
        let n = NotchModel.shared
        return NSRect(x: screen.frame.midX - n.collapsedWidth / 2, y: screen.frame.maxY - n.notchHeight,
                      width: n.collapsedWidth, height: n.notchHeight)
    }

    func showHome() {
        let screen = NSScreen.screens.first ?? NSScreen.main!
        let size = CGSize(width: 880, height: 580)
        let target = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                            width: size.width, height: size.height)

        if homeWindow == nil {
            let w = HomePanel(contentRect: target, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.level = .statusBar + 2
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 480)
            let host = NSHostingView(rootView: HomeView(onClose: { [weak self] in self?.hideHome() }))
            let container = NSView()
            container.wantsLayer = true
            host.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(host)
            // Black cover = the notch itself; it fades away once the shape has grown.
            let cover = NSView()
            cover.wantsLayer = true
            cover.layer?.backgroundColor = NSColor.black.cgColor
            cover.layer?.cornerRadius = 14
            cover.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(cover)
            for v in [host, cover] {
                NSLayoutConstraint.activate([
                    v.leadingAnchor.constraint(equalTo: container.leadingAnchor), v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    v.topAnchor.constraint(equalTo: container.topAnchor), v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                ])
            }
            w.contentView = container
            homeCover = cover
            homeWindow = w
            AppAppearance.apply()
        }
        guard let w = homeWindow, let cover = homeCover else { return }
        NSApp.activate(ignoringOtherApps: true)
        if w.isVisible && w.alphaValue > 0.9 { w.makeKeyAndOrderFront(nil); return }

        NotchModel.shared.homeOpen = true
        cover.alphaValue = 1
        w.alphaValue = 1
        w.setFrame(notchFrame(screen), display: false)
        w.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            w.animator().setFrame(target, display: true)
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                cover.animator().alphaValue = 0
            }
        })
    }

    func hideHome() {
        guard let w = homeWindow, w.isVisible, let cover = homeCover else { return }
        let screen = NSScreen.screens.first ?? NSScreen.main!
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            cover.animator().alphaValue = 1
        }, completionHandler: {
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.32
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0.0, 0.7, 0.4)
                    w.animator().setFrame(self.notchFrame(screen), display: true)
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        w.orderOut(nil)
                        NotchModel.shared.homeOpen = false
                    }
                })
            }
        })
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

Migration.run()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

/// Borderless Home panel that hangs from the notch.
final class HomePanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.hideHome()
    }
}
