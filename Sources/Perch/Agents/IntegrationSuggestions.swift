import AppKit
import ApplicationServices

/// Offers to connect an app after you've spent a little time in it (or on its website).
@MainActor
final class IntegrationSuggestions: ObservableObject {
    static let shared = IntegrationSuggestions()

    @Published var current: ConnectorDefinition?

    private var timer: Timer?
    private var dwell: [String: TimeInterval] = [:]
    private let dwellNeeded: TimeInterval = 12
    private let defaults = UserDefaults.standard

    /// Words in a window title or bundle ids that identify each connector.
    private let signals: [String: (titles: [String], bundles: [String])] = [
        "github": (["GitHub"], ["com.github.GitHubClient"]),
        "notion": (["Notion"], ["notion.id"]),
        "linear": (["Linear"], ["com.linear"]),
        "figma": (["Figma"], ["com.figma.Desktop"]),
        "slack": (["Slack"], ["com.tinyspeck.slackmacgap"]),
        "atlassian": (["Jira", "Confluence"], []),
        "asana": (["Asana"], []),
        "todoist": (["Todoist"], ["com.todoist.mac.Todoist"]),
        "hubspot": (["HubSpot"], []),
        "canva": (["Canva"], ["com.canva.CanvaDesktop"]),
        "vercel": (["Vercel"], []),
        "supabase": (["Supabase"], []),
        "sentry": (["Sentry"], []),
        "stripe": (["Stripe"], []),
        "google-workspace": (["Gmail", "Google Calendar", "Google Docs", "Google Sheets", "Google Drive"], []),
        "airtable": (["Airtable"], []),
    ]

    static let useCases: [String: [String]] = [
        "github": ["Find issues about this bug", "Draft a release checklist", "Review recent CI failures"],
        "notion": ["Summarise this page", "Add a row to my tracker", "Find my meeting notes"],
        "linear": ["What's assigned to me?", "File a bug for this", "Plan next cycle"],
        "figma": ["Describe this design", "List the components", "Check spacing issues"],
        "slack": ["Catch me up on #general", "Draft a reply", "Find that link from yesterday"],
        "atlassian": ["What's blocking the sprint?", "Find the spec page", "Create a ticket"],
        "google-workspace": ["Summarise my inbox", "What's on my calendar?", "Draft a follow-up email"],
    ]

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard current == nil, defaults.object(forKey: "integrationSuggestions") as? Bool ?? true,
              let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }
        let title = Self.frontWindowTitle(app) ?? ""
        let bundle = app.bundleIdentifier ?? ""
        for (id, sig) in signals {
            let hit = sig.bundles.contains(bundle) || sig.titles.contains { title.localizedCaseInsensitiveContains($0) }
            // Only offer apps helpers can actually use (not ones that need a browser sign-in).
            guard hit, let def = ConnectorCatalog.all.first(where: { $0.id == id }), def.usableByAgents else { continue }
            dwell[id, default: 0] += 2
            if dwell[id]! >= dwellNeeded, shouldAsk(id) {
                dwell[id] = 0
                defaults.set(Date(), forKey: "suggest.lastAsked.\(id)")
                defaults.set(Date(), forKey: "suggest.lastAskedAny")
                NSSound(named: "Purr")?.play()
                current = def
            }
            return
        }
    }

    private func shouldAsk(_ id: String) -> Bool {
        if ConnectorStore.shared.isEnabled(id) { return false }
        if defaults.bool(forKey: "suggest.never.\(id)") { return false }
        if let snooze = defaults.object(forKey: "suggest.snooze.\(id)") as? Date, snooze > Date() { return false }
        if let last = defaults.object(forKey: "suggest.lastAsked.\(id)") as? Date, Date().timeIntervalSince(last) < 86_400 { return false }
        if let any = defaults.object(forKey: "suggest.lastAskedAny") as? Date, Date().timeIntervalSince(any) < 3_600 { return false }
        return true
    }

    func answer(yes: Bool, never: Bool = false) {
        guard let def = current else { return }
        current = nil
        if yes {
            HomeRouter.shared.settings = .integrations
            (NSApp.delegate as? AppDelegate)?.showHome()
        } else if never {
            defaults.set(true, forKey: "suggest.never.\(def.id)")
        } else {
            defaults.set(Date().addingTimeInterval(7 * 86_400), forKey: "suggest.snooze.\(def.id)")
        }
    }

    private static func frontWindowTitle(_ app: NSRunningApplication) -> String? {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var win: AnyObject?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success, let w = win else { return nil }
        var title: AnyObject?
        guard AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }
}
