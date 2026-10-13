import AppKit

/// Simple spoken commands handled on the Mac with no AI call: instant and free.
/// Anything not matched exactly goes to the model as usual.
@MainActor
enum QuickCommands {
    private static let stopPhrases: Set<String> = [
        "stop", "stop it", "stop that", "stop now", "stop working", "stop everything", "stop all", "please stop",
        "cancel", "cancel it", "cancel that", "cancel everything", "never mind", "nevermind", "halt", "abort",
    ]

    /// Websites people name by brand.
    private static let sites: [String: String] = [
        "youtube": "https://www.youtube.com", "google": "https://www.google.com", "gmail": "https://mail.google.com",
        "google drive": "https://drive.google.com", "drive": "https://drive.google.com", "google docs": "https://docs.google.com",
        "google maps": "https://maps.google.com", "github": "https://github.com", "reddit": "https://www.reddit.com",
        "facebook": "https://www.facebook.com", "instagram": "https://www.instagram.com", "twitter": "https://x.com",
        "x": "https://x.com", "linkedin": "https://www.linkedin.com", "netflix": "https://www.netflix.com",
        "amazon": "https://www.amazon.com", "chatgpt": "https://chatgpt.com", "whatsapp web": "https://web.whatsapp.com",
        "openrouter": "https://openrouter.ai", "upwork": "https://www.upwork.com", "fiverr": "https://www.fiverr.com",
    ]

    /// Short names people say for apps whose real names are longer.
    private static let appAliases: [String: String] = [
        "chrome": "Google Chrome", "vs code": "Visual Studio Code", "vscode": "Visual Studio Code",
        "word": "Microsoft Word", "excel": "Microsoft Excel", "powerpoint": "Microsoft PowerPoint",
        "premiere": "Adobe Premiere Pro", "premiere pro": "Adobe Premiere Pro", "after effects": "Adobe After Effects",
        "photoshop": "Adobe Photoshop", "illustrator": "Adobe Illustrator", "settings": "System Settings",
        "system preferences": "System Settings", "app store": "App Store",
    ]

    private static let openRegex = try! NSRegularExpression(
        pattern: #"^(?:open|launch|start|go to|goto)\s+(?:up\s+)?(?:the\s+)?(.+?)(?:\s+(?:in|on|with|using)\s+(?:the\s+)?(.+?))?(?:\s+app)?$"#,
        options: [.caseInsensitive])

    /// Lowercased, with wake words and filler removed. Used for matching only.
    static func normalize(_ text: String) -> String { strippingFiller(text).lowercased() }

    /// Removes "Hey Perch," / "please" and edge punctuation but keeps the original casing,
    /// so URL paths like "bit.ly/AbC" survive.
    private static func strippingFiller(_ text: String) -> String {
        let edge = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?,;:"))
        var s = text.trimmingCharacters(in: edge)
        var stripped = true
        while stripped {
            stripped = false
            for prefix in ["hey perch", "hi perch", "ok perch", "okay perch", "perch", "please", "can you", "could you"]
            where s.lowercased().hasPrefix(prefix) {
                let rest = s.dropFirst(prefix.count)
                // Whole words only ("perch," or "perch open…", not "perched").
                guard let next = rest.first, !next.isLetter, !next.isNumber else { continue }
                s = String(rest).trimmingCharacters(in: edge)
                stripped = true
            }
        }
        if s.lowercased().hasSuffix(" please") { s = String(s.dropLast(7)).trimmingCharacters(in: edge) }
        return s
    }

    static func isStop(_ text: String) -> Bool { stopPhrases.contains(normalize(text)) }

    /// Stops the buddy and every helper. Returns what to say.
    static func stopEverything() -> String {
        let count = AgentManager.shared.stopAll()
        return count == 0 ? "Stopped." : "Stopped. \(count == 1 ? "Your helper is" : "All \(count) helpers are") off too."
    }

    /// Runs the command if it's one we know for sure. Returns the line to say, or nil to ask the model.
    static func handle(_ text: String) async -> String? {
        let original = strippingFiller(text)
        if stopPhrases.contains(original.lowercased()) { return stopEverything() }

        // Match case-insensitively but cut the pieces from the original, so URLs keep their casing.
        let ns = original as NSString
        guard let m = openRegex.firstMatch(in: original, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let rawTarget = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        let target = rawTarget.lowercased()
        let browserName = m.range(at: 2).location == NSNotFound ? nil : ns.substring(with: m.range(at: 2)).lowercased()

        if browserName == nil || browserName == "finder", let folder = folder(target) {
            guard NSWorkspace.shared.open(folder) else { return nil }
            return "Opening your \(folder.lastPathComponent) folder."
        }

        var browser: URL?
        if let name = browserName {
            // Only something that can open web pages counts as "in <browser>" ("open github in terminal" isn't one).
            guard let b = appURL(name), canOpenWebPages(b) else { return nil }
            browser = b
        }

        // A website: a known brand or something that looks like a domain (not a file like "readme.md").
        let siteURL = sites[target] ?? (looksLikeDomain(rawTarget) ? "https://\(rawTarget)" : nil)
        if let site = siteURL, let url = URL(string: site), browser != nil || exactApp(target) == nil {
            if let browser {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                guard (try? await NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: config)) != nil else { return nil }
                return "Opening \(display(rawTarget)) in \(browser.deletingPathExtension().lastPathComponent)."
            }
            guard NSWorkspace.shared.open(url) else { return nil }
            return "Opening \(display(rawTarget))."
        }

        // An app, only when the name matches clearly and no browser was named.
        guard browserName == nil, let app = appURL(target) else { return nil }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        guard (try? await NSWorkspace.shared.openApplication(at: app, configuration: config)) != nil else { return nil }
        return "Opening \(app.deletingPathExtension().lastPathComponent)."
    }

    /// File types people open by name; "readme.md" is a file, not a website.
    private static let fileExtensions: Set<String> = [
        "md", "txt", "rtf", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv", "json", "xml", "yaml", "yml",
        "pages", "numbers", "key", "png", "jpg", "jpeg", "gif", "heic", "svg", "psd", "mp3", "wav", "m4a", "mp4", "mov",
        "zip", "dmg", "pkg", "swift", "py", "js", "ts", "sh", "log", "prproj", "aep",
    ]

    private static func looksLikeDomain(_ target: String) -> Bool {
        guard target.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+(/\S*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return false }
        // With a path it's a URL; without one, a known file extension means a file name.
        if target.contains("/") { return true }
        let ext = target.split(separator: ".").last.map { $0.lowercased() } ?? ""
        return !fileExtensions.contains(ext)
    }

    private static func canOpenWebPages(_ app: URL) -> Bool {
        guard let page = URL(string: "https://example.com") else { return false }
        let target = app.standardizedFileURL.resolvingSymlinksInPath()
        return NSWorkspace.shared.urlsForApplications(toOpen: page).contains { $0.standardizedFileURL.resolvingSymlinksInPath() == target }
    }

    /// "my downloads", "the desktop folder", "documents" → that folder in the home directory.
    private static func folder(_ target: String) -> URL? {
        var name = target
        let said = name.hasPrefix("my ") || name.hasSuffix(" folder")
        if name.hasPrefix("my ") { name = String(name.dropFirst(3)) }
        if name.hasSuffix(" folder") { name = String(name.dropLast(7)) }
        let folders: [String: FileManager.SearchPathDirectory] = [
            "downloads": .downloadsDirectory, "desktop": .desktopDirectory, "documents": .documentDirectory,
        ]
        guard let dir = folders[name.trimmingCharacters(in: .whitespaces)] else { return nil }
        // A bare "open documents" could be an app of that name; "my …" or "… folder" can't.
        guard said || exactApp(name) == nil else { return nil }
        return FileManager.default.urls(for: dir, in: .userDomainMask).first
    }

    /// An app whose name starts with what was said (3+ letters, so "x" can't mean Xcode).
    private static func appURL(_ spoken: String) -> URL? {
        let name = appAliases[spoken] ?? spoken
        guard name.count >= 3 else { return nil }
        return ComputerControl.appURL(named: name, minScore: 80)
    }

    /// An app whose name is exactly what was said, e.g. a "Spotify" app for "open spotify".
    private static func exactApp(_ spoken: String) -> URL? {
        ComputerControl.appURL(named: appAliases[spoken] ?? spoken, minScore: 100)
    }

    private static func display(_ target: String) -> String {
        target.contains(".") ? target : target.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
            .replacingOccurrences(of: "Youtube", with: "YouTube").replacingOccurrences(of: "Github", with: "GitHub")
    }
}
