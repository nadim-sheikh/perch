import AppKit
import ApplicationServices
import Foundation
import UniformTypeIdentifiers

/// The result of one tool call, sent back to the model.
struct ToolOutput {
    var text: String
    var isError = false
    /// JPEG screenshots (base64) the model should see next.
    var images: [String] = []

    static func error(_ text: String) -> ToolOutput { ToolOutput(text: text, isError: true) }
}

/// Everything a helper can do on this Mac: files, shell, web, app and screen control, and the
/// user's connected apps. One toolbox lives for one agent turn.
@MainActor
final class AgentToolbox {
    nonisolated static let maxOutputChars = 12_000

    enum Scope {
        /// Background helpers: every tool.
        case helper
        /// The buddy acting on the spot: only screen and app control, no shell, files or AppleScript.
        case actions
    }

    /// Tools that send mouse or keyboard events, which need Accessibility permission.
    static let inputTools: Set<String> = ["click", "click_element", "type_text", "press_key", "scroll"]

    /// Lookups with no side effects, safe to run at the same time.
    static let parallelSafe: Set<String> = ["read_file", "list_files", "search_files", "web_search", "web_fetch"]

    /// True when every call is an independent lookup (or a connected-app call, which the model
    /// only batches when they don't depend on each other).
    static func canRunTogether(_ names: [String]) -> Bool {
        names.count > 1 && names.allSatisfy { parallelSafe.contains($0) || $0.hasPrefix("mcp__") }
    }

    /// Tools the buddy may use directly.
    static let actionTools: Set<String> = [
        "open_app", "open_url", "take_screenshot", "list_ui_elements", "click_element", "click",
        "type_text", "press_key", "scroll", "wait",
    ]

    /// Apps that run whatever is typed into them. Without Full access, keystrokes never go to them.
    static let terminalApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.ScriptEditor2", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "com.apple.Automator",
    ]

    private let agent: BuddyAgent?
    private let scope: Scope
    private var full: Bool { scope == .helper && agent?.accessLevel == .fullAccess }
    private var folder: URL { agent?.folder ?? FileManager.default.homeDirectoryForCurrentUser }
    private var screens: [CapturedScreen] = []
    private var elements: [ComputerControl.UIElement] = []
    private var apps: [MCPConnection] = []
    private var appTools: [String: (MCPConnection, String)] = [:]
    private var appProblems: [String] = []

    init(agent: BuddyAgent?, scope: Scope) {
        self.agent = agent
        self.scope = scope
    }

    func rememberScreens(_ s: [CapturedScreen]) { screens = s }

    // MARK: Connected apps

    /// Gets the user's connected apps (MCP servers) from the pool and collects their tools.
    /// Apps still starting after a few seconds are skipped this time rather than holding up the turn.
    func connectApps() async {
        guard scope == .helper else { return }
        let defs = ConnectorStore.shared.enabled.filter(\.usableByAgents)
        guard !defs.isEmpty else { return }
        let (ready, problems) = await MCPPool.shared.connections(for: defs, wait: 8)
        apps = ready
        appProblems = problems
        for conn in ready {
            for tool in conn.tools {
                var name = Self.functionName(server: conn.definition.id, tool: tool.name)
                var salt = 0
                while appTools[name] != nil {
                    salt += 1
                    name = Self.functionName(server: conn.definition.id, tool: tool.name, salt: salt)
                }
                appTools[name] = (conn, tool.name)
            }
        }
    }

    /// Pooled connections stay open for the next turn.
    func close() {
        apps = []
    }

    var promptNote: String {
        guard scope == .helper else { return "" }
        var lines: [String] = []
        if !apps.isEmpty {
            lines.append("CONNECTED APPS: \(apps.map(\.definition.name).joined(separator: ", ")). Use their mcp__ tools for the user's own data.")
        }
        if !appProblems.isEmpty {
            lines.append("These connected apps failed to start this time: \(appProblems.joined(separator: "; ")). If the task needs one, tell the user to check it in Perch → Settings → Integrations.")
        }
        if !full {
            lines.append("ACCESS: safe mode. File tools and run_command only reach your working folder. run_command allows only \(Self.safePrograms.sorted().joined(separator: ", ")), with plain arguments: no redirects (< >), $, backticks, backslashes, brackets ( ) { } or VAR= prefixes. run_applescript is off, and typing into Terminal-like apps is blocked. If a task needs more, say the user can switch you to Full access in Settings → Agents.")
        }
        return lines.isEmpty ? "" : "\n\n" + lines.joined(separator: "\n")
    }

    // MARK: Definitions

    var definitions: [[String: Any]] {
        if scope == .actions {
            return Self.builtIn.filter { Self.actionTools.contains(Self.name(of: $0)) }
        }
        var defs = Self.builtIn
        for (name, (conn, toolName)) in appTools.sorted(by: { $0.key < $1.key }) {
            guard let tool = conn.tools.first(where: { $0.name == toolName }) else { continue }
            defs.append(["type": "function", "function": [
                "name": name,
                "description": "[\(conn.definition.name)] \(tool.description)".prefix(1000).description,
                "parameters": tool.inputSchema,
            ]])
        }
        return defs
    }

    private static func name(of definition: [String: Any]) -> String {
        (definition["function"] as? [String: Any])?["name"] as? String ?? ""
    }

    private static func fn(_ name: String, _ description: String, _ properties: [String: [String: Any]] = [:],
                           required: [String] = []) -> [String: Any] {
        ["type": "function", "function": [
            "name": name, "description": description,
            "parameters": ["type": "object", "properties": properties, "required": required],
        ]]
    }

    private static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private static func num(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
    private static func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }

    private static let builtIn: [[String: Any]] = [
        fn("read_file", "Read a text file. Relative paths are inside your working folder.",
           ["path": str("File path"), "offset": num("First line to read (1-based)"), "limit": num("Number of lines")],
           required: ["path"]),
        fn("write_file", "Create or overwrite a text file (parent folders are created).",
           ["path": str("File path"), "content": str("Full file content")], required: ["path", "content"]),
        fn("edit_file", "Replace exact text in a file. old_text must appear exactly once unless replace_all is true.",
           ["path": str("File path"), "old_text": str("Exact text to find"), "new_text": str("Replacement"),
            "replace_all": bool("Replace every occurrence")], required: ["path", "old_text", "new_text"]),
        fn("list_files", "List a folder's contents.",
           ["path": str("Folder path (default: your working folder)"), "recursive": bool("Include subfolders")]),
        fn("search_files", "Search file contents with a regular expression (grep).",
           ["pattern": str("Regular expression"), "path": str("Folder or file (default: your working folder)")],
           required: ["pattern"]),
        fn("run_command", "Run a shell command (zsh) in your working folder and return its output. In safe mode only a short list of file tools is allowed, every path must stay inside your working folder, and redirects, $, backticks and brackets are refused.",
           ["command": str("The command"), "timeout_seconds": num("Default 120, max 600")], required: ["command"]),
        fn("web_search", "Search the web. Returns titles, links and snippets.",
           ["query": str("Search query")], required: ["query"]),
        fn("web_fetch", "Download a web page and return its readable text.",
           ["url": str("http(s) URL")], required: ["url"]),
        fn("open_app", "Open (or bring to front) a Mac app by its exact name (or the start of it), e.g. \"Google Chrome\", \"Notes\", \"Finder\".",
           ["name": str("App name")], required: ["name"]),
        fn("open_url", "Open an http(s) web address, optionally in a specific browser app, or a folder or document by path (e.g. ~/Downloads).",
           ["url": str("URL (e.g. https://youtube.com) or a path starting with ~/ or /"), "app": str("Optional exact app name, e.g. \"Google Chrome\"")],
           required: ["url"]),
        fn("take_screenshot", "See the user's screens. Coordinates in the images are used by click and scroll."),
        fn("list_ui_elements", "List buttons, fields, links and text in the front app's window, with ids for click_element. Faster and more precise than screenshots when it works."),
        fn("click_element", "Click an element by its id from the latest list_ui_elements.",
           ["id": num("Element id")], required: ["id"]),
        fn("click", "Click at a point in the latest screenshot (pixel coordinates in that image).",
           ["x": num("X in screenshot pixels"), "y": num("Y in screenshot pixels"), "screen": num("Screen number (default 1)"),
            "double": bool("Double-click"), "right": bool("Right-click")], required: ["x", "y"]),
        fn("type_text", "Type text into whatever has keyboard focus. Refused in password fields.", ["text": str("Text to type")], required: ["text"]),
        fn("press_key", "Press a key or shortcut, e.g. \"return\", \"cmd+l\", \"cmd+shift+t\", \"down\".",
           ["keys": str("Key combo")], required: ["keys"]),
        fn("scroll", "Scroll at a point in the latest screenshot, or where the mouse is.",
           ["direction": ["type": "string", "enum": ["up", "down", "left", "right"]], "amount": num("Lines, default 5"),
            "x": num("Optional X in screenshot pixels"), "y": num("Optional Y"), "screen": num("Screen number")],
           required: ["direction"]),
        fn("wait", "Wait for an app or page to load.", ["seconds": num("1 to 10")], required: ["seconds"]),
        fn("run_applescript", "Run AppleScript to control apps (e.g. Chrome tabs, Finder, Mail drafts). Full access only.",
           ["script": str("AppleScript source")], required: ["script"]),
    ]

    // MARK: Running tools

    /// Tools after which the screen may have changed, so element ids from list_ui_elements are stale.
    private static let changesScreen: Set<String> = ["click_element", "click", "type_text", "press_key", "open_app", "open_url"]

    func run(name: String, arguments a: [String: Any]) async -> ToolOutput {
        if scope == .actions && !Self.actionTools.contains(name) {
            return .error("\(name) isn't available here. Use the screen tools, or hand the job to a helper.")
        }
        if let (conn, tool) = appTools[name] {
            do { return try await conn.call(tool, arguments: a) }
            catch { return .error("The app tool failed: \(error.localizedDescription)") }
        }
        if Self.inputTools.contains(name) && !AXIsProcessTrusted() {
            return .error("Perch doesn't have Accessibility permission, so clicks and typing don't reach other apps. Tell the user to allow Perch in System Settings → Privacy & Security → Accessibility, then quit and reopen Perch.")
        }
        defer { if Self.changesScreen.contains(name) { elements = [] } }
        switch name {
        case "read_file": return await readFile(a)
        case "write_file": return writeFile(a)
        case "edit_file": return editFile(a)
        case "list_files": return await listFiles(a)
        case "search_files": return await searchFiles(a)
        case "run_command": return await runCommand(a)
        case "web_search": return await WebTools.search(a["query"] as? String ?? "")
        case "web_fetch": return await WebTools.fetch(a["url"] as? String ?? "")
        case "open_app": return await openApp(a)
        case "open_url": return await openURL(a)
        case "take_screenshot": return await takeScreenshot()
        case "list_ui_elements": return listElements()
        case "click_element": return clickElement(a)
        case "click": return click(a)
        case "type_text":
            guard let text = a["text"] as? String else { return .error("Missing text.") }
            if let refusal = keyboardRefusal() { return .error(refusal) }
            if Self.focusIsSecure() {
                return .error("The focused field is a password field. Perch never types into those; ask the user to type it.")
            }
            ComputerControl.type(text)
            return ToolOutput(text: "Typed \(text.count) characters.")
        case "press_key":
            let keys = a["keys"] as? String ?? ""
            if let refusal = keyboardRefusal() { return .error(refusal) }
            return ComputerControl.key(keys) ? ToolOutput(text: "Pressed \(keys).") : .error("Unknown key combo: \(keys)")
        case "scroll": return scroll(a)
        case "wait":
            let s = min(10, max(0.2, Self.double(a["seconds"]) ?? 1))
            try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
            return ToolOutput(text: "Waited \(s) seconds.")
        case "run_applescript":
            guard full else { return .error("AppleScript needs Full access (Settings → Agents).") }
            let r = await Shell.run(executable: "/usr/bin/osascript", arguments: ["-e", a["script"] as? String ?? ""],
                                    cwd: folder, timeout: 60)
            let text = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return ToolOutput(text: text.isEmpty ? (r.status == 0 ? "ok" : "Failed (exit \(r.status))") : Self.clip(text),
                              isError: r.status != 0)
        default:
            return .error("There is no tool called \(name).")
        }
    }

    // MARK: Files

    /// A path or command the current access level doesn't allow; the message goes back to the model.
    private struct Refusal: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Resolves a tool path (`~`, relative to the working folder, `..`, symlinks) to where a file operation really
    /// lands. Without Full access it must stay inside the working folder. Writes never reach a helper's `.perch`
    /// settings or Perch's connectors, in any mode.
    private func path(_ raw: Any?, writing: Bool = false) throws -> URL? {
        guard let s = raw as? String, !s.isEmpty else { return nil }
        let expanded = (s as NSString).expandingTildeInPath
        let url = Self.resolved(expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : folder.appendingPathComponent(expanded))
        if !full && !Self.isInside(url, Self.resolved(folder)) {
            throw Refusal(message: "\(s) is outside your working folder (\(folder.path)). Safe mode only reaches files there; Full access in Settings → Agents lifts this.")
        }
        if writing && Self.isProtected(url) {
            throw Refusal(message: "\(s) holds Perch's own settings, which helpers can't change. Ask the user to change it in Perch's Settings.")
        }
        return url
    }

    /// Standardizes a file URL and resolves symlinks in the part of it that exists.
    nonisolated static func resolved(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        // attributesOfItem doesn't follow a final symlink, so a dangling link still counts as existing.
        while (try? FileManager.default.attributesOfItem(atPath: existing.path)) == nil, existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var out = existing.resolvingSymlinksInPath()
        for part in rest { out.appendPathComponent(part) }
        return out
    }

    nonisolated static func isInside(_ url: URL, _ base: URL) -> Bool {
        let p = url.path, b = base.path
        return p == b || p.hasPrefix(b.hasSuffix("/") ? b : b + "/")
    }

    /// Every helper's `.perch` folder (its access level and settings) and the connectors folder (commands Perch runs).
    nonisolated static func isProtected(_ url: URL) -> Bool {
        if isInside(url, resolved(ConnectorStore.folder)) { return true }
        let agents = resolved(AgentPaths.agents)
        guard isInside(url, agents) else { return false }
        let inner = url.pathComponents.dropFirst(agents.pathComponents.count)
        return inner.count >= 2 && inner[inner.startIndex + 1] == ".perch"
    }

    private func readFile(_ a: [String: Any]) async -> ToolOutput {
        let url: URL
        do {
            guard let u = try path(a["path"]) else { return .error("Missing path.") }
            url = u
        } catch { return .error(error.localizedDescription) }
        guard let text = await Task.detached(operation: { try? String(contentsOf: url, encoding: .utf8) }).value else {
            return .error("Couldn't read \(url.path) as text (missing, a folder, or not UTF-8).")
        }
        var lines = text.components(separatedBy: "\n")
        let offset = max(1, Self.int(a["offset"]) ?? 1)
        if offset > 1 { lines = Array(lines.dropFirst(offset - 1)) }
        if let limit = Self.int(a["limit"]), limit > 0 { lines = Array(lines.prefix(limit)) }
        return ToolOutput(text: Self.clip(lines.joined(separator: "\n")))
    }

    private func writeFile(_ a: [String: Any]) -> ToolOutput {
        let url: URL
        do {
            guard let u = try path(a["path"], writing: true), let content = a["content"] as? String else {
                return .error("Missing path or content.")
            }
            url = u
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return ToolOutput(text: "Wrote \(url.path) (\(content.count) characters).")
        } catch let refusal as Refusal {
            return .error(refusal.message)
        } catch {
            return .error("Couldn't write \(a["path"] as? String ?? ""): \(error.localizedDescription)")
        }
    }

    private func editFile(_ a: [String: Any]) -> ToolOutput {
        let target: URL?
        do { target = try path(a["path"], writing: true) } catch { return .error(error.localizedDescription) }
        guard let url = target, let old = a["old_text"] as? String, let new = a["new_text"] as? String, !old.isEmpty
        else { return .error("Missing path, old_text or new_text.") }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .error("Couldn't read \(url.path).") }
        let count = text.components(separatedBy: old).count - 1
        if count == 0 { return .error("old_text wasn't found in \(url.lastPathComponent).") }
        if count > 1 && a["replace_all"] as? Bool != true {
            return .error("old_text appears \(count) times. Add more surrounding text or set replace_all.")
        }
        do {
            try text.replacingOccurrences(of: old, with: new).write(to: url, atomically: true, encoding: .utf8)
            return ToolOutput(text: "Edited \(url.path) (\(count) replacement\(count == 1 ? "" : "s")).")
        } catch {
            return .error("Couldn't save \(url.path): \(error.localizedDescription)")
        }
    }

    private func listFiles(_ a: [String: Any]) async -> ToolOutput {
        let url: URL
        do { url = try path(a["path"]) ?? folder } catch { return .error(error.localizedDescription) }
        let recursive = a["recursive"] as? Bool == true
        let out: [String]? = await Task.detached {
            let fm = FileManager.default
            guard recursive else {
                return (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]))?.prefix(500).map {
                    $0.lastPathComponent + ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? "/" : "")
                }.sorted()
            }
            var out: [String] = []
            let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            while let item = e?.nextObject() as? URL, out.count < 500 {
                if ["node_modules", ".git", ".build"].contains(item.lastPathComponent) { e?.skipDescendants(); continue }
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                out.append(String(item.path.dropFirst(url.path.count + 1)) + (isDir ? "/" : ""))
            }
            return out
        }.value
        guard let out else { return .error("Couldn't list \(url.path).") }
        return ToolOutput(text: out.isEmpty ? "(empty)" : out.joined(separator: "\n"))
    }

    private func searchFiles(_ a: [String: Any]) async -> ToolOutput {
        guard let pattern = a["pattern"] as? String else { return .error("Missing pattern.") }
        let target: String
        do { target = (try path(a["path"]) ?? folder).path } catch { return .error(error.localizedDescription) }
        let r = await Shell.run(executable: "/usr/bin/grep",
                                arguments: ["-rnIE", "--exclude-dir=node_modules", "--exclude-dir=.git", "-m", "20", "-e", pattern, target],
                                cwd: folder, timeout: 60)
        if r.output.isEmpty { return ToolOutput(text: "No matches.") }
        return ToolOutput(text: Self.clip(r.output))
    }

    // MARK: Shell

    /// Programs safe-mode helpers may start: they read and organize files and can't start other programs.
    /// Anything else needs Full access.
    private static let safePrograms: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "pwd", "echo", "mkdir", "cp", "mv", "touch", "grep", "sort", "uniq",
        "diff", "date", "which", "file", "zip", "unzip", "tar", "jq", "cd",
    ]

    private func runCommand(_ a: [String: Any]) async -> ToolOutput {
        guard let command = a["command"] as? String, !command.isEmpty else { return .error("Missing command.") }
        if let blocked = blockedReason(command) { return .error(blocked) }
        let timeout = min(600, max(1, Self.double(a["timeout_seconds"]) ?? 120))
        let r = await Shell.run(executable: "/bin/zsh", arguments: ["-c", command], cwd: folder, timeout: timeout)
        var text = r.output.isEmpty ? "(no output)" : r.output
        if r.timedOut { text += "\n(stopped after \(Int(timeout)) seconds)" }
        text += "\n[exit code \(r.status)]"
        return ToolOutput(text: Self.clip(text), isError: r.status != 0)
    }

    /// Why a command can't run. Full access only blocks sudo. Safe mode allows the programs above with plain
    /// arguments, and every path they name must stay inside the working folder.
    private func blockedReason(_ command: String) -> String? {
        let words = command.split(whereSeparator: { " \t\n;&|()".contains($0) }).map(String.init)
        if words.contains("sudo") { return "sudo isn't allowed. Ask the user to run it themselves." }
        if full { return nil }
        if let bad = ["<", ">", "(", ")", "{", "}", "$", "`", "\\", "**"].first(where: { command.contains($0) }) {
            return "\(bad) isn't allowed in safe mode (no redirects, substitutions, subshells, escapes or ** globs). Use write_file to create files."
        }
        for segment in command.components(separatedBy: CharacterSet(charactersIn: ";|&\n")) {
            // zsh removes quotes, so check what it will see.
            let tokens = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { $0.filter { $0 != "\"" && $0 != "'" } }
            guard let program = tokens.first else { continue }
            if program.contains("=") { return "Setting variables before a command isn't allowed in safe mode." }
            guard Self.safePrograms.contains(program) else {
                return "\(program) isn't allowed in safe mode. Allowed: \(Self.safePrograms.sorted().joined(separator: ", "))."
            }
            let args = Array(tokens.dropFirst())
            if let option = args.enumerated().first(where: { Self.startsPrograms($0.element, program: program, first: $0.offset == 0) }) {
                return "\(program) \(option.element) isn't allowed in safe mode."
            }
            if program == "cd" && args.count != 1 { return "In safe mode cd needs one folder inside your working folder." }
            for arg in args {
                if let refusal = pathRefusal(arg, alwaysPath: program == "cd") { return refusal }
            }
        }
        return nil
    }

    /// Options that make an allowed program start another one, or write outside the folder.
    private static func startsPrograms(_ arg: String, program: String, first: Bool) -> Bool {
        let short = arg.hasPrefix("-") && !arg.hasPrefix("--")
        switch program {
        case "zip": return arg.hasPrefix("--test") || arg.hasPrefix("--unzip-command") || (short && arg.contains("T"))
        case "tar":
            return (arg.hasPrefix("--") && ["program", "command", "checkpoint", "script", "absolute", "insecure"].contains { arg.contains($0) })
                || arg.hasPrefix("@") || ((short || first) && !arg.hasPrefix("--") && arg.contains("P"))
        case "sort": return arg.hasPrefix("--compress-program")
        default: return false
        }
    }

    /// Checks one argument the shell will see: anything naming a path must resolve inside the working folder.
    private func pathRefusal(_ arg: String, alwaysPath: Bool) -> String? {
        if arg.hasPrefix("=") || (arg.hasPrefix("~") && arg != "~" && !arg.hasPrefix("~/")) {
            return "\(arg) isn't allowed in safe mode."
        }
        var value = arg
        if arg.hasPrefix("-") {
            // The value of --name=value can be a path; a path glued to a short option can't be checked.
            guard let eq = arg.firstIndex(of: "=") else {
                return arg.contains("/") ? "Put the path in \(arg) in its own argument." : nil
            }
            value = String(arg[arg.index(after: eq)...])
        }
        guard !value.isEmpty else { return nil }
        let expanded = (value as NSString).expandingTildeInPath
        let base = expanded.hasPrefix("/") ? "" : folder.path + "/"
        // Expand globs the way zsh will, so a match that's a symlink to somewhere else is caught too.
        let candidates = value.contains(where: { "*?[".contains($0) }) ? Self.glob(base + expanded) : [base + expanded]
        for candidate in candidates {
            let exists = (try? FileManager.default.attributesOfItem(atPath: candidate)) != nil
            guard alwaysPath || exists || value.contains("/") || value.hasPrefix("~") || value == ".." else { continue }
            do { _ = try path(candidate, writing: true) } catch { return error.localizedDescription }
        }
        return nil
    }

    private static func glob(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        guard Darwin.glob(pattern, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_matchc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
    }

    // MARK: Apps and screen

    /// Without Full access, nothing may start or type into an app that runs typed commands.
    private func launchRefusal(_ appURL: URL) -> String? {
        guard !full, let id = Bundle(url: appURL)?.bundleIdentifier, Self.terminalApps.contains(id) else { return nil }
        return "\(appURL.deletingPathExtension().lastPathComponent) runs typed commands, so it needs a helper with Full access."
    }

    private func keyboardRefusal() -> String? {
        guard !full, let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
              Self.terminalApps.contains(id) else { return nil }
        return "\(app.localizedName ?? "That app") runs typed commands, so typing into it needs a helper with Full access."
    }

    /// True when keyboard focus is in a password field.
    private static func focusIsSecure() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        var subrole: AnyObject?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSubroleAttribute as CFString, &subrole)
        return subrole as? String == kAXSecureTextFieldSubrole
    }

    /// Finds an installed app by its exact name or the start of it, so "Arc" never opens Archive Utility.
    private static func app(named name: String) -> URL? { ComputerControl.appURL(named: name, minScore: 80) }

    private static func noApp(_ name: String) -> ToolOutput {
        .error("No installed app is called \(name) or starts with it. Use the app's exact name.")
    }

    private func openApp(_ a: [String: Any]) async -> ToolOutput {
        guard let name = a["name"] as? String, !name.isEmpty else { return .error("Missing app name.") }
        guard let appURL = Self.app(named: name) else { return Self.noApp(name) }
        if let refusal = launchRefusal(appURL) { return .error(refusal) }
        let shown = appURL.deletingPathExtension().lastPathComponent
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let app: NSRunningApplication
        do { app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config) }
        catch { return .error("Couldn't open \(shown): \(error.localizedDescription)") }
        // Slow apps (Premiere, Xcode) take seconds to finish launching.
        for _ in 0..<50 where !(app.isFinishedLaunching && app.isActive) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return ToolOutput(text: app.isFinishedLaunching && app.isActive
                          ? "Opened \(shown)." : "Opened \(shown), but it isn't in front yet. Wait, then take a screenshot.")
    }

    private func openURL(_ a: [String: Any]) async -> ToolOutput {
        guard let raw = (a["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .error("Missing url.")
        }
        let appName = (a["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if raw.hasPrefix("~") || raw.hasPrefix("/") { return await openPath(raw, appName: appName) }
        guard let url = URL(string: raw.contains("://") ? raw : "https://" + raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else {
            return .error("open_url only opens http(s) web addresses, or folders and documents by path (~/… or /…).")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let appName {
            guard let appURL = Self.app(named: appName) else { return Self.noApp(appName) }
            let shown = appURL.deletingPathExtension().lastPathComponent
            guard NSWorkspace.shared.urlsForApplications(toOpen: url).contains(where: { $0.standardizedFileURL == appURL.standardizedFileURL }) else {
                return .error("\(shown) can't open web pages. Leave out app to use the default browser.")
            }
            do { _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) }
            catch { return .error("Couldn't open \(raw) in \(shown): \(error.localizedDescription)") }
            try? await Task.sleep(nanoseconds: 800_000_000)
            return ToolOutput(text: "Opened \(url.absoluteString) in \(shown).")
        }
        guard NSWorkspace.shared.open(url) else { return .error("Couldn't open \(raw).") }
        try? await Task.sleep(nanoseconds: 800_000_000)
        return ToolOutput(text: "Opened \(url.absoluteString) in the default browser.")
    }

    /// Opens a folder in Finder or a document in its app. Without Full access, programs and scripts (which run
    /// when opened) and hidden files are refused, and safe-mode helpers stay inside their working folder.
    private func openPath(_ raw: String, appName: String?) async -> ToolOutput {
        let url: URL
        do {
            guard let u = try path(raw) else { return .error("Missing path.") }
            url = u
        } catch { return .error(error.localizedDescription) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return .error("Nothing exists at \(raw).") }
        if !full {
            if url.pathComponents.contains(where: { $0.hasPrefix(".") }) { return .error("Hidden files and folders can't be opened here.") }
            if Self.runsWhenOpened(url, isDirectory: isDir.boolValue) {
                return .error("\(url.lastPathComponent) is a program or script, and opening it would run it. That needs a helper with Full access.")
            }
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            if let appName {
                guard let appURL = Self.app(named: appName) else { return Self.noApp(appName) }
                if let refusal = launchRefusal(appURL) { return .error(refusal) }
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
            } else {
                _ = try await NSWorkspace.shared.open(url, configuration: config)
            }
        } catch {
            return .error("Couldn't open \(url.path): \(error.localizedDescription)")
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        return ToolOutput(text: "Opened \(url.path).")
    }

    /// Apps, scripts, installers and link files: opening one runs code or another URL.
    nonisolated static func runsWhenOpened(_ url: URL, isDirectory: Bool) -> Bool {
        let risky = ["app", "command", "tool", "sh", "zsh", "bash", "terminal", "workflow", "action", "scpt", "scptd",
                     "applescript", "pkg", "mpkg", "jar", "webloc", "inetloc", "fileloc", "prefpane", "mobileconfig"]
        if risky.contains(url.pathExtension.lowercased()) { return true }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        if isDirectory { return type.map { $0.conforms(to: .bundle) || $0.conforms(to: .application) } ?? false }
        if FileManager.default.isExecutableFile(atPath: url.path) { return true }
        guard let type else { return true }
        return [UTType.executable, .application, .script, .bundle, .package, .internetShortcut, .aliasFile].contains { type.conforms(to: $0) }
    }

    private func takeScreenshot() async -> ToolOutput {
        guard ScreenCapture.hasPermission() else {
            return .error("Perch doesn't have Screen Recording permission. Ask the user to allow it in System Settings → Privacy & Security.")
        }
        do {
            screens = try await ScreenCapture.captureAll()
        } catch {
            return .error("Couldn't take a screenshot: \(error.localizedDescription)")
        }
        let desc = screens.map {
            "screen \($0.index): \(Int($0.imageSize.width))x\(Int($0.imageSize.height)) pixels\($0.containsCursor ? " (mouse is here)" : "")"
        }.joined(separator: "\n")
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        return ToolOutput(text: "Front app: \(front)\n\(desc)", images: screens.map(\.jpegBase64))
    }

    /// After a batch of on-screen actions, what the screen holds now, so the model can carry on without
    /// spending a step on list_ui_elements. Element ids are refreshed here, after the whole batch has run.
    func screenAfterActions(_ names: [String]) async -> String? {
        guard names.contains(where: Self.changesScreen.contains), AXIsProcessTrusted() else { return nil }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let listing = listElements()
        return listing.isError ? nil : "Screen now (use these ids with click_element):\n" + listing.text
    }

    private func listElements() -> ToolOutput {
        guard AXIsProcessTrusted() else {
            return .error("Perch doesn't have Accessibility permission. Ask the user to allow it in System Settings → Privacy & Security, or use take_screenshot and click.")
        }
        elements = ComputerControl.uiElements()
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        guard !elements.isEmpty else { return ToolOutput(text: "Front app: \(front). No readable elements; use take_screenshot instead.") }
        let lines = elements.map { "\($0.id). \($0.role) \"\($0.title)\"" }
        return ToolOutput(text: "Front app: \(front)\n" + lines.joined(separator: "\n"))
    }

    private func clickElement(_ a: [String: Any]) -> ToolOutput {
        guard let id = Self.int(a["id"]), let el = elements.first(where: { $0.id == id }) else {
            return .error("No element with that id. Call list_ui_elements first.")
        }
        // Read the frame again: the window may have moved or the element may be gone since the list.
        guard let frame = ComputerControl.frame(of: el.element), frame.width > 0, frame.height > 0 else {
            return .error("\(el.role) \"\(el.title)\" isn't there any more. Call list_ui_elements again.")
        }
        if ComputerControl.press(el.element) { return ToolOutput(text: "Pressed \(el.role) \"\(el.title)\".") }
        var pid: pid_t = 0
        AXUIElementGetPid(el.element, &pid)
        guard pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return .error("Its app isn't in front any more, so a click could land on another window. Bring it forward and call list_ui_elements again.")
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard NSScreen.screens.contains(where: { $0.frame.contains(center) }) else {
            return .error("\(el.role) \"\(el.title)\" is off screen. Scroll to it and call list_ui_elements again.")
        }
        ComputerControl.click(at: center)
        return ToolOutput(text: "\(el.role) \"\(el.title)\" can't be pressed directly, so Perch clicked its middle. That isn't confirmed; take a screenshot to check.")
    }

    /// The global point for x/y in a screenshot, or nil when x/y weren't given.
    private func point(_ a: [String: Any]) throws -> CGPoint? {
        guard let x = Self.double(a["x"]), let y = Self.double(a["y"]) else { return nil }
        let n = Self.int(a["screen"]) ?? 1
        guard let screen = screens.first(where: { $0.index == n }) else {
            throw Refusal(message: "Take a screenshot first, then use its pixel coordinates.")
        }
        guard screen.isStillValid else { throw Refusal(message: "Displays changed since the screenshot; take a new screenshot first.") }
        return screen.globalPoint(fromImagePoint: CGPoint(x: x, y: y))
    }

    private func click(_ a: [String: Any]) -> ToolOutput {
        let p: CGPoint
        do {
            guard let found = try point(a) else { return .error("Missing x or y.") }
            p = found
        } catch { return .error(error.localizedDescription) }
        ComputerControl.click(at: p, button: a["right"] as? Bool == true ? .right : .left, count: a["double"] as? Bool == true ? 2 : 1)
        return ToolOutput(text: "Clicked.")
    }

    private func scroll(_ a: [String: Any]) -> ToolOutput {
        let amount = Int32(min(50, max(1, Self.int(a["amount"]) ?? 5)))
        let at: CGPoint
        do { at = try point(a) ?? NSEvent.mouseLocation } catch { return .error(error.localizedDescription) }
        let (dx, dy): (Int32, Int32)
        switch a["direction"] as? String {
        case "up": (dx, dy) = (0, amount)
        case "left": (dx, dy) = (amount, 0)
        case "right": (dx, dy) = (-amount, 0)
        default: (dx, dy) = (0, -amount)
        }
        ComputerControl.scroll(at: at, dx: dx, dy: dy)
        return ToolOutput(text: "Scrolled.")
    }

    // MARK: Helpers

    nonisolated static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// A whole number from the model's arguments; nil for missing, non-finite or huge values.
    nonisolated static func int(_ v: Any?) -> Int? {
        guard let d = double(v), d.isFinite, abs(d) < 1_000_000_000 else { return nil }
        return Int(d)
    }

    nonisolated static func clip(_ text: String) -> String {
        guard text.count > maxOutputChars else { return text }
        let half = maxOutputChars / 2
        return String(text.prefix(half)) + "\n…(\(text.count - maxOutputChars) characters cut)…\n" + String(text.suffix(half))
    }

    /// Function names must match ^[a-zA-Z0-9_-]{1,64}$ (ASCII only). The server part is capped at 20 characters.
    /// Names that would be too long, or that collide (pass a `salt` above 0), end in a short hash that stays the
    /// same across launches, so no tool is ever dropped.
    nonisolated static func functionName(server: String, tool: String, salt: Int = 0) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".unicodeScalars)
        let clean = { (s: String) in String(String.UnicodeScalarView(s.unicodeScalars.map { allowed.contains($0) ? $0 : "_" })) }
        let name = "mcp__\(clean(server).prefix(20))__\(clean(tool))"
        guard name.count > 64 || salt > 0 else { return name }
        var hash: UInt32 = 2_166_136_261 // FNV-1a
        for byte in "\(server)\u{0}\(tool)\u{0}\(salt)".utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return String(name.prefix(57)) + "_" + String(format: "%06x", hash & 0xFF_FFFF)
    }
}

/// Runs a program off the main thread with a timeout. Each run leads its own process group, so stopping it also
/// stops everything it started. Groups still alive (running commands, and background jobs such as a dev server
/// started with `&`) are remembered per working folder until `killJobs(in:)` or `killAll()` stops them.
enum Shell {
    struct Result { var output: String; var status: Int32; var timedOut: Bool }

    private static let lock = NSLock()
    /// Working folder path → process group ids started there.
    nonisolated(unsafe) private static var groups: [String: Set<pid_t>] = [:]

    static func run(executable: String, arguments: [String], cwd: URL, timeout: Double,
                    environment: [String: String] = AgentSettings.environment()) async -> Result {
        let pipe = Pipe()
        let collector = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { h in collector.append(h.availableData) }
        let (pid, err) = spawn(executable, arguments, cwd: cwd, environment: environment,
                               output: pipe.fileHandleForWriting.fileDescriptor)
        try? pipe.fileHandleForWriting.close()
        guard err == 0 else {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
            return Result(output: "Couldn't start: \(String(cString: strerror(err)))", status: -1, timedOut: false)
        }
        let key = cwd.standardizedFileURL.path
        remember(pid, in: key)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if !collector.finished { collector.timedOut = true; stop(pid) }
                }
                Thread {
                    var status: Int32 = 0
                    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                    collector.finished = true
                    // Don't wait for end-of-file: a background job (a dev server started with &) keeps the pipe
                    // open forever. Give the reader a moment to collect the last output, then let go.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                        pipe.fileHandleForReading.readabilityHandler = nil
                        try? pipe.fileHandleForReading.close()
                        if !isAlive(pid) { forget(pid, in: key) }
                        let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                        cont.resume(returning: Result(output: collector.text, status: code, timedOut: collector.timedOut))
                    }
                }.start()
            }
        } onCancel: {
            stop(pid)
        }
    }

    /// Stops every command and background job started in `folder` (a helper's working folder).
    static func killJobs(in folder: URL) {
        lock.lock()
        let found = groups.removeValue(forKey: folder.standardizedFileURL.path) ?? []
        lock.unlock()
        found.forEach(stop)
    }

    /// Stops every command and background job Perch started. Blocks for up to a second, so call it when quitting.
    static func killAll() {
        lock.lock()
        let all = groups.values.reduce(into: Set<pid_t>()) { $0.formUnion($1) }
        groups = [:]
        lock.unlock()
        for pgid in all { kill(-pgid, SIGTERM) }
        for _ in 0..<10 where all.contains(where: isAlive) { usleep(100_000) }
        for pgid in all where isAlive(pgid) { kill(-pgid, SIGKILL) }
    }

    private static func remember(_ pgid: pid_t, in key: String) {
        lock.lock(); defer { lock.unlock() }
        groups[key, default: []].insert(pgid)
        for (k, ids) in groups { groups[k] = ids.filter(isAlive) }
        groups = groups.filter { !$0.value.isEmpty }
    }

    private static func forget(_ pgid: pid_t, in key: String) {
        lock.lock(); defer { lock.unlock() }
        groups[key]?.remove(pgid)
        if groups[key]?.isEmpty == true { groups[key] = nil }
    }

    private static func isAlive(_ pgid: pid_t) -> Bool { kill(-pgid, 0) == 0 }

    /// Ends a whole process group: TERM now, KILL two seconds later for anything that ignored it.
    private static func stop(_ pgid: pid_t) {
        guard kill(-pgid, SIGTERM) == 0 else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(-pgid, SIGKILL) }
    }

    /// Starts `executable` as the leader of a new process group, reading /dev/null and writing to `output`.
    private static func spawn(_ executable: String, _ arguments: [String], cwd: URL, environment: [String: String],
                              output: Int32) -> (pid_t, Int32) {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Children start with default signal handling, so TERM really stops them even if Perch ignores a signal.
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                              | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, output, 2)
        posix_spawn_file_actions_addchdir_np(&actions, cwd.path)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let err = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        return (pid, err)
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        var timedOut = false
        var finished = false
        func append(_ d: Data) { lock.lock(); data.append(d.prefix(max(0, 2_000_000 - data.count))); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
}

/// Web search (DuckDuckGo's HTML page, no key needed) and page fetching.
enum WebTools {
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    /// web_fetch stops reading after this many bytes.
    private static let maxFetchBytes = 3_000_000

    static func search(_ query: String) async -> ToolOutput {
        guard !query.isEmpty, var comps = URLComponents(string: "https://html.duckduckgo.com/html/") else { return .error("Missing query.") }
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps.url else { return .error("Bad query.") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return .error("The search didn't respond. Try again or use web_fetch on a site you know.") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let html = String(decoding: data, as: UTF8.self)
        // DuckDuckGo answers bots with HTTP 202 and a challenge page instead of results.
        if status != 200 || html.contains("anomaly-modal") || html.contains("/anomaly.js") || html.contains("challenge-form") {
            return .error("DuckDuckGo is blocking automated searches right now (HTTP \(status)). Searching again won't help for a while; web_fetch a site you know instead (for example https://en.wikipedia.org/wiki/Special:Search?search=…).")
        }

        let linkRe = try! NSRegularExpression(pattern: #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])
        let snippetRe = try! NSRegularExpression(pattern: #"class="result__snippet"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])
        let ns = html as NSString
        let links = linkRe.matches(in: html, range: NSRange(location: 0, length: ns.length))
        let snippets = snippetRe.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var results: [String] = []
        for (i, m) in links.prefix(8).enumerated() {
            var href = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
            if let c = URLComponents(string: href.hasPrefix("//") ? "https:" + href : href),
               let target = c.queryItems?.first(where: { $0.name == "uddg" })?.value {
                href = target
            }
            let title = plainText(ns.substring(with: m.range(at: 2)))
            let snippet = i < snippets.count ? plainText(ns.substring(with: snippets[i].range(at: 1))) : ""
            results.append("\(i + 1). \(title)\n   \(href)\n   \(snippet)")
        }
        if results.isEmpty {
            if html.contains("no-results") { return ToolOutput(text: "No results found. Try different words, or web_fetch a site directly.") }
            return .error("The search page came back in a form Perch can't read, so there are no results to show. Use web_fetch on a site you know instead.")
        }
        return ToolOutput(text: results.joined(separator: "\n"))
    }

    static func fetch(_ raw: String) async -> ToolOutput {
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return .error("web_fetch needs an http(s) URL.")
        }
        if let refusal = privateHostRefusal(url) { return .error(refusal) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req, delegate: RedirectGuard())
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            var data = Data()
            var cut = false
            for try await byte in bytes {
                if data.count >= maxFetchBytes { cut = true; break }
                data.append(byte)
            }
            bytes.task.cancel()
            var text = String(decoding: data, as: UTF8.self)
            if type.contains("html") || text.lowercased().contains("<html") { text = plainText(text) }
            if cut { text += "\n…(page cut after \(maxFetchBytes / 1_000_000) MB)" }
            let final = response.url ?? url
            return ToolOutput(text: "[HTTP \(status)] \(final.absoluteString)\n\n" + AgentToolbox.clip(text), isError: status >= 400)
        } catch {
            return .error("Couldn't load \(raw): \(error.localizedDescription)")
        }
    }

    /// Why a URL can't be fetched: web_fetch only reaches public hosts, never this Mac or the local network.
    static func privateHostRefusal(_ url: URL) -> String? {
        guard let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty else {
            return "That URL has no host."
        }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return "Couldn't look up \(host)." }
        defer { freeaddrinfo(first) }
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let n = node {
            if let addr = n.pointee.ai_addr, isPrivate(addr) {
                return "web_fetch only reaches public websites, not this Mac or the local network (\(host))."
            }
            node = n.pointee.ai_next
        }
        return nil
    }

    private static func isPrivate(_ addr: UnsafePointer<sockaddr>) -> Bool {
        switch Int32(addr.pointee.sa_family) {
        case AF_INET:
            return isPrivateV4(addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                withUnsafeBytes(of: p.pointee.sin_addr) { Array($0) }
            })
        case AF_INET6:
            let b = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) }
            }
            // ::, ::1, IPv4-compatible and IPv4-mapped addresses carry an IPv4 address in the last 4 bytes.
            if b[0..<10].allSatisfy({ $0 == 0 }) && (b[10..<12].allSatisfy({ $0 == 0 }) || b[10..<12].allSatisfy({ $0 == 0xff })) {
                return isPrivateV4(Array(b[12..<16]))
            }
            return (b[0] & 0xfe) == 0xfc            // fc00::/7 unique local
                || (b[0] == 0xfe && b[1] >= 0x80)   // fe80::/10 link-local, fec0::/10 site-local
                || b[0] == 0xff                     // multicast
        default:
            return true
        }
    }

    private static func isPrivateV4(_ b: [UInt8]) -> Bool {
        b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224
            || (b[0] == 169 && b[1] == 254) || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
            || (b[0] == 100 && (64...127).contains(b[1])) || (b[0] == 198 && (18...19).contains(b[1]))
    }

    /// Checks every redirect too, so a public page can't send web_fetch to a private address.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  WebTools.privateHostRefusal(url) == nil else { return nil }
            return request
        }
    }

    /// Rough HTML to text: drops scripts, styles and tags, decodes common entities.
    static func plainText(_ html: String) -> String {
        var s = html
        for pattern in [#"<script[\s\S]*?</script>"#, #"<style[\s\S]*?</style>"#, #"<noscript[\s\S]*?</noscript>"#, #"<!--[\s\S]*?-->"#] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: #"<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
