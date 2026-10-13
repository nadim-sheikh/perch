import AppKit
import ApplicationServices
import Foundation

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
    static let maxOutputChars = 30_000

    private let agent: BuddyAgent
    private var full: Bool { agent.accessLevel == .fullAccess }
    private var screens: [CapturedScreen] = []
    private var elements: [ComputerControl.UIElement] = []
    private var apps: [MCPConnection] = []
    private var appTools: [String: (MCPConnection, String)] = [:]
    private var appProblems: [String] = []

    init(agent: BuddyAgent) { self.agent = agent }

    func rememberScreens(_ s: [CapturedScreen]) { screens = s }

    // MARK: Connected apps

    /// Starts the user's connected apps (MCP servers) in parallel and collects their tools.
    func connectApps() async {
        let defs = ConnectorStore.shared.enabled.filter(\.usableByAgents)
        let secrets = Dictionary(uniqueKeysWithValues: defs.map { ($0.id, ConnectorStore.shared.secrets(for: $0)) })
        let started = await withTaskGroup(of: (ConnectorDefinition, Result<MCPConnection, Error>).self) { group in
            for def in defs {
                group.addTask {
                    do { return (def, .success(try await MCPConnection.open(def, secrets: secrets[def.id] ?? [:]))) }
                    catch { return (def, .failure(error)) }
                }
            }
            var out: [(ConnectorDefinition, Result<MCPConnection, Error>)] = []
            for await r in group { out.append(r) }
            return out
        }
        for (def, result) in started {
            switch result {
            case .success(let conn):
                apps.append(conn)
                for tool in conn.tools {
                    appTools[Self.functionName(server: def.id, tool: tool.name)] = (conn, tool.name)
                }
            case .failure(let error):
                appProblems.append("\(def.name) (\(error.localizedDescription))")
            }
        }
    }

    func close() {
        for app in apps { app.close() }
        apps = []
    }

    var promptNote: String {
        var lines: [String] = []
        if !apps.isEmpty {
            lines.append("CONNECTED APPS: \(apps.map(\.definition.name).joined(separator: ", ")). Use their mcp__ tools for the user's own data.")
        }
        if !appProblems.isEmpty {
            lines.append("These connected apps failed to start this time: \(appProblems.joined(separator: "; ")). If the task needs one, tell the user to check it in Perch → Settings → Integrations.")
        }
        if !full {
            lines.append("ACCESS: safe mode. run_command only allows common file, dev and download tools; run_applescript is off. If a task needs more, say the user can switch you to Full access in Settings → Agents.")
        }
        return lines.isEmpty ? "" : "\n\n" + lines.joined(separator: "\n")
    }

    // MARK: Definitions

    var definitions: [[String: Any]] {
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
        fn("run_command", "Run a shell command (zsh) in your working folder and return its output.",
           ["command": str("The command"), "timeout_seconds": num("Default 120, max 600")], required: ["command"]),
        fn("web_search", "Search the web. Returns titles, links and snippets.",
           ["query": str("Search query")], required: ["query"]),
        fn("web_fetch", "Download a web page and return its readable text.",
           ["url": str("http(s) URL")], required: ["url"]),
        fn("open_app", "Open (or bring to front) a Mac app by name, e.g. \"Google Chrome\", \"Notes\", \"Finder\".",
           ["name": str("App name")], required: ["name"]),
        fn("open_url", "Open a web address, optionally in a specific browser app.",
           ["url": str("URL, e.g. https://youtube.com"), "app": str("Optional app name, e.g. \"Google Chrome\"")],
           required: ["url"]),
        fn("take_screenshot", "See the user's screens. Coordinates in the images are used by click and scroll."),
        fn("list_ui_elements", "List buttons, fields, links and text in the front app's window, with ids for click_element. Faster and more precise than screenshots when it works."),
        fn("click_element", "Click an element by its id from the latest list_ui_elements.",
           ["id": num("Element id")], required: ["id"]),
        fn("click", "Click at a point in the latest screenshot (pixel coordinates in that image).",
           ["x": num("X in screenshot pixels"), "y": num("Y in screenshot pixels"), "screen": num("Screen number (default 1)"),
            "double": bool("Double-click"), "right": bool("Right-click")], required: ["x", "y"]),
        fn("type_text", "Type text into whatever has keyboard focus.", ["text": str("Text to type")], required: ["text"]),
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

    func run(name: String, arguments a: [String: Any]) async -> ToolOutput {
        if let (conn, tool) = appTools[name] {
            do { return try await conn.call(tool, arguments: a) }
            catch { return .error("The app tool failed: \(error.localizedDescription)") }
        }
        switch name {
        case "read_file": return readFile(a)
        case "write_file": return writeFile(a)
        case "edit_file": return editFile(a)
        case "list_files": return listFiles(a)
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
            ComputerControl.type(text)
            return ToolOutput(text: "Typed \(text.count) characters.")
        case "press_key":
            let keys = a["keys"] as? String ?? ""
            return ComputerControl.key(keys) ? ToolOutput(text: "Pressed \(keys).") : .error("Unknown key combo: \(keys)")
        case "scroll": return scroll(a)
        case "wait":
            let s = min(10, max(0.2, Self.double(a["seconds"]) ?? 1))
            try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
            return ToolOutput(text: "Waited \(s) seconds.")
        case "run_applescript":
            guard full else { return .error("AppleScript needs Full access (Settings → Agents).") }
            let out = ComputerControl.runAppleScript(a["script"] as? String ?? "")
            return ToolOutput(text: out, isError: out.hasPrefix("Error"))
        default:
            return .error("There is no tool called \(name).")
        }
    }

    // MARK: Files

    private func path(_ raw: Any?) -> URL? {
        guard let s = raw as? String, !s.isEmpty else { return nil }
        let expanded = (s as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : agent.folder.appendingPathComponent(expanded)
    }

    private func readFile(_ a: [String: Any]) -> ToolOutput {
        guard let url = path(a["path"]) else { return .error("Missing path.") }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .error("Couldn't read \(url.path) as text (missing, a folder, or not UTF-8).")
        }
        var lines = text.components(separatedBy: "\n")
        let offset = max(1, Int(Self.double(a["offset"]) ?? 1))
        if offset > 1 { lines = Array(lines.dropFirst(offset - 1)) }
        if let limit = Self.double(a["limit"]) { lines = Array(lines.prefix(Int(limit))) }
        return ToolOutput(text: Self.clip(lines.joined(separator: "\n")))
    }

    private func writeFile(_ a: [String: Any]) -> ToolOutput {
        guard let url = path(a["path"]), let content = a["content"] as? String else { return .error("Missing path or content.") }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return ToolOutput(text: "Wrote \(url.path) (\(content.count) characters).")
        } catch {
            return .error("Couldn't write \(url.path): \(error.localizedDescription)")
        }
    }

    private func editFile(_ a: [String: Any]) -> ToolOutput {
        guard let url = path(a["path"]), let old = a["old_text"] as? String, let new = a["new_text"] as? String, !old.isEmpty
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

    private func listFiles(_ a: [String: Any]) -> ToolOutput {
        let url = path(a["path"]) ?? agent.folder
        let fm = FileManager.default
        var out: [String] = []
        if a["recursive"] as? Bool == true {
            let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            while let item = e?.nextObject() as? URL, out.count < 500 {
                if ["node_modules", ".git", ".build"].contains(item.lastPathComponent) { e?.skipDescendants(); continue }
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                out.append(String(item.path.dropFirst(url.path.count + 1)) + (isDir ? "/" : ""))
            }
        } else {
            guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else {
                return .error("Couldn't list \(url.path).")
            }
            out = items.prefix(500).map {
                $0.lastPathComponent + ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? "/" : "")
            }.sorted()
        }
        return ToolOutput(text: out.isEmpty ? "(empty)" : out.joined(separator: "\n"))
    }

    private func searchFiles(_ a: [String: Any]) async -> ToolOutput {
        guard let pattern = a["pattern"] as? String else { return .error("Missing pattern.") }
        let target = (path(a["path"]) ?? agent.folder).path
        let r = await Shell.run(executable: "/usr/bin/grep",
                                arguments: ["-rnIE", "--exclude-dir=node_modules", "--exclude-dir=.git", "-m", "20", pattern, target],
                                cwd: agent.folder, timeout: 60)
        if r.output.isEmpty { return ToolOutput(text: "No matches.") }
        return ToolOutput(text: Self.clip(r.output))
    }

    // MARK: Shell

    /// Programs safe-mode helpers may start. Anything else needs Full access.
    private static let safePrograms: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "pwd", "echo", "mkdir", "cp", "mv", "touch", "find", "grep", "sort", "uniq",
        "diff", "date", "which", "file", "zip", "unzip", "tar", "python3", "python", "uv", "uvx", "pip", "pip3", "npm",
        "npx", "node", "curl", "git", "open", "jq", "sed", "awk", "cd",
    ]

    private func runCommand(_ a: [String: Any]) async -> ToolOutput {
        guard let command = a["command"] as? String, !command.isEmpty else { return .error("Missing command.") }
        if let blocked = Self.blockedReason(command, full: full) { return .error(blocked) }
        let timeout = min(600, max(1, Self.double(a["timeout_seconds"]) ?? 120))
        let r = await Shell.run(executable: "/bin/zsh", arguments: ["-c", command], cwd: agent.folder, timeout: timeout)
        var text = r.output.isEmpty ? "(no output)" : r.output
        if r.timedOut { text += "\n(stopped after \(Int(timeout)) seconds)" }
        text += "\n[exit code \(r.status)]"
        return ToolOutput(text: Self.clip(text), isError: r.status != 0)
    }

    private static func blockedReason(_ command: String, full: Bool) -> String? {
        let words = command.split(whereSeparator: { " \t\n;&|()".contains($0) }).map(String.init)
        if words.contains("sudo") { return "sudo isn't allowed. Ask the user to run it themselves." }
        if full { return nil }
        if command.contains("$(") || command.contains("`") {
            return "Command substitution isn't allowed in safe mode."
        }
        let segments = command.components(separatedBy: CharacterSet(charactersIn: ";|&\n"))
        for segment in segments {
            let tokens = segment.split(separator: " ").map(String.init).filter { !$0.contains("=") || $0.hasPrefix("-") }
            guard let program = tokens.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) else { continue }
            if !safePrograms.contains(program) {
                return "\(program) isn't allowed in safe mode. Allowed: \(safePrograms.sorted().joined(separator: ", "))."
            }
        }
        return nil
    }

    // MARK: Apps and screen

    private func openApp(_ a: [String: Any]) async -> ToolOutput {
        guard let name = a["name"] as? String, !name.isEmpty else { return .error("Missing app name.") }
        guard let opened = await ComputerControl.openApp(name) else { return .error("Couldn't find an app called \(name).") }
        try? await Task.sleep(nanoseconds: 600_000_000)
        return ToolOutput(text: "Opened \(opened).")
    }

    private func openURL(_ a: [String: Any]) async -> ToolOutput {
        guard var raw = (a["url"] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return .error("Missing url.") }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw) else { return .error("That isn't a valid URL: \(raw)") }
        if let appName = a["app"] as? String, !appName.isEmpty {
            guard let appURL = ComputerControl.appURL(named: appName) else { return .error("Couldn't find an app called \(appName).") }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            do {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
            } catch {
                return .error("Couldn't open \(raw) in \(appName): \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            return ToolOutput(text: "Opened \(raw) in \(appURL.deletingPathExtension().lastPathComponent).")
        }
        guard NSWorkspace.shared.open(url) else { return .error("Couldn't open \(raw).") }
        try? await Task.sleep(nanoseconds: 800_000_000)
        return ToolOutput(text: "Opened \(raw) in the default browser.")
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
        guard let id = Self.double(a["id"]).map(Int.init), let el = elements.first(where: { $0.id == id }) else {
            return .error("No element with that id. Call list_ui_elements first.")
        }
        if !ComputerControl.press(el.element) {
            ComputerControl.click(at: CGPoint(x: el.frame.midX, y: el.frame.midY))
        }
        return ToolOutput(text: "Clicked \(el.role) \"\(el.title)\".")
    }

    private func point(_ a: [String: Any]) -> CGPoint? {
        guard let x = Self.double(a["x"]), let y = Self.double(a["y"]) else { return nil }
        let n = Int(Self.double(a["screen"]) ?? 1)
        guard let screen = screens.first(where: { $0.index == n }) else { return nil }
        return screen.globalPoint(fromImagePoint: CGPoint(x: x, y: y))
    }

    private func click(_ a: [String: Any]) -> ToolOutput {
        guard let p = point(a) else { return .error("Take a screenshot first, then click using its pixel coordinates.") }
        ComputerControl.click(at: p, button: a["right"] as? Bool == true ? .right : .left, count: a["double"] as? Bool == true ? 2 : 1)
        return ToolOutput(text: "Clicked.")
    }

    private func scroll(_ a: [String: Any]) -> ToolOutput {
        let amount = Int32(Self.double(a["amount"]) ?? 5)
        let at = point(a) ?? NSEvent.mouseLocation
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

    static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func clip(_ text: String) -> String {
        guard text.count > maxOutputChars else { return text }
        let half = maxOutputChars / 2
        return String(text.prefix(half)) + "\n…(\(text.count - maxOutputChars) characters cut)…\n" + String(text.suffix(half))
    }

    /// Function names must match ^[a-zA-Z0-9_-]{1,64}$.
    static func functionName(server: String, tool: String) -> String {
        let clean = { (s: String) in String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }) }
        return String("mcp__\(clean(server))__\(clean(tool))".prefix(64))
    }
}

/// Runs a program off the main thread with a timeout.
enum Shell {
    struct Result { var output: String; var status: Int32; var timedOut: Bool }

    static func run(executable: String, arguments: [String], cwd: URL, timeout: Double,
                    environment: [String: String] = AgentSettings.environment()) async -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let collector = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { h in collector.append(h.availableData) }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
                let timer = DispatchWorkItem { if process.isRunning { collector.timedOut = true; process.terminate() } }
                process.terminationHandler = { p in
                    timer.cancel()
                    pipe.fileHandleForReading.readabilityHandler = nil
                    collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
                    cont.resume(returning: Result(output: collector.text, status: p.terminationStatus, timedOut: collector.timedOut))
                }
                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                } catch {
                    cont.resume(returning: Result(output: "Couldn't start: \(error.localizedDescription)", status: -1, timedOut: false))
                }
            }
        } onCancel: {
            if process.isRunning { process.interrupt() }
        }
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        var timedOut = false
        func append(_ d: Data) { lock.lock(); data.append(d.prefix(max(0, 2_000_000 - data.count))); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
}

/// Web search (DuckDuckGo's HTML page, no key needed) and page fetching.
enum WebTools {
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    static func search(_ query: String) async -> ToolOutput {
        guard !query.isEmpty, var comps = URLComponents(string: "https://html.duckduckgo.com/html/") else { return .error("Missing query.") }
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps.url else { return .error("Bad query.") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return .error("The search didn't respond. Try again or use web_fetch on a site you know.") }
        let html = String(decoding: data, as: UTF8.self)

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
        if results.isEmpty { return ToolOutput(text: "No results found. Try different words, or web_fetch a site directly.") }
        return ToolOutput(text: results.joined(separator: "\n"))
    }

    static func fetch(_ raw: String) async -> ToolOutput {
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return .error("web_fetch needs an http(s) URL.")
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            var text = String(decoding: data.prefix(3_000_000), as: UTF8.self)
            if type.contains("html") || text.lowercased().contains("<html") { text = plainText(text) }
            return ToolOutput(text: "[HTTP \(status)] \(url.absoluteString)\n\n" + AgentToolbox.clip(text), isError: status >= 400)
        } catch {
            return .error("Couldn't load \(raw): \(error.localizedDescription)")
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
