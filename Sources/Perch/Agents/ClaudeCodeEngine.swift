import Foundation

/// Events we care about from `claude -p --output-format stream-json`.
enum AgentEvent {
    case sessionStarted(sessionID: String)
    case textDelta(String)
    case assistantText(String)
    case toolStarted(id: String, name: String, input: [String: Any])
    case toolFinished(id: String, isError: Bool)
    case finished(result: String, isError: Bool, costUSD: Double?, sessionID: String?)
    case exited(code: Int32, stderrTail: String)
}

/// How agents authenticate with Claude Code.
enum AgentAuthMode: String, CaseIterable, Identifiable {
    case claudeLogin, anthropicKey, openrouterKey
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claudeLogin: return "My Claude Code login"
        case .anthropicKey: return "My Anthropic API key"
        case .openrouterKey: return "My OpenRouter key"
        }
    }
}

/// Runs one agent turn with the user's own Claude Code CLI.
final class ClaudeCodeRun {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var buffer = Data()
    private var stderrTail = ""
    private let onEvent: (AgentEvent) -> Void

    static func locateCLI() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    init(cli: String, arguments: [String], cwd: URL, environment: [String: String], onEvent: @escaping (AgentEvent) -> Void) {
        self.onEvent = onEvent
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
    }

    func start() throws {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty else { return }
            self.consume(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty else { return }
            self.stderrTail = String((self.stderrTail + String(decoding: data, as: UTF8.self)).suffix(2000))
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.stdout.fileHandleForReading.readabilityHandler = nil
            self.stderr.fileHandleForReading.readabilityHandler = nil
            // Flush whatever is left.
            let rest = self.stdout.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty { self.consume(rest) }
            self.onEvent(.exited(code: p.terminationStatus, stderrTail: self.stderrTail))
        }
        try process.run()
    }

    /// Ask nicely first (SIGINT keeps partial work), then insist.
    func interrupt() {
        guard process.isRunning else { return }
        process.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [process] in
            if process.isRunning { process.terminate() }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handle(obj) }
        }
    }

    private func handle(_ e: [String: Any]) {
        switch e["type"] as? String {
        case "system":
            if e["subtype"] as? String == "init", let sid = e["session_id"] as? String {
                onEvent(.sessionStarted(sessionID: sid))
            }
        case "stream_event":
            guard let ev = e["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
                  let delta = ev["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, e["parent_tool_use_id"] is NSNull || e["parent_tool_use_id"] == nil
            else { return }
            onEvent(.textDelta(text))
        case "assistant":
            guard e["parent_tool_use_id"] is NSNull || e["parent_tool_use_id"] == nil,
                  let msg = e["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return }
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onEvent(.assistantText(t))
                    }
                case "tool_use":
                    onEvent(.toolStarted(id: block["id"] as? String ?? UUID().uuidString,
                                         name: block["name"] as? String ?? "tool",
                                         input: block["input"] as? [String: Any] ?? [:]))
                default: break
                }
            }
        case "user":
            guard let msg = e["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return }
            for block in content where block["type"] as? String == "tool_result" {
                onEvent(.toolFinished(id: block["tool_use_id"] as? String ?? "", isError: block["is_error"] as? Bool ?? false))
            }
        case "result":
            onEvent(.finished(result: e["result"] as? String ?? "",
                              isError: e["is_error"] as? Bool ?? false,
                              costUSD: e["total_cost_usd"] as? Double,
                              sessionID: e["session_id"] as? String))
        default:
            break
        }
    }
}

/// Turns a tool call into a friendly present/past phrase.
enum StepDescriber {
    static func describe(id: String, name: String, input: [String: Any]) -> AgentStep {
        func file(_ key: String = "file_path") -> String {
            (input[key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "a file"
        }
        switch name {
        case "Write":
            return AgentStep(id: id, kind: .edit, present: "Creating \(file())", past: "Created \(file())", detail: input["file_path"] as? String)
        case "Edit", "MultiEdit", "NotebookEdit":
            return AgentStep(id: id, kind: .edit, present: "Editing \(file())", past: "Edited \(file())", detail: input["file_path"] as? String)
        case "Read":
            return AgentStep(id: id, kind: .read, present: "Reading \(file())", past: "Read \(file())", detail: input["file_path"] as? String)
        case "Bash":
            let cmd = input["command"] as? String ?? ""
            let (present, past) = commandPhrase(cmd, description: input["description"] as? String)
            return AgentStep(id: id, kind: .command, present: present, past: past, detail: cmd)
        case "WebSearch":
            let q = input["query"] as? String ?? "the web"
            return AgentStep(id: id, kind: .web, present: "Searching for \(q)", past: "Searched for \(q)", detail: q)
        case "WebFetch":
            let host = (input["url"] as? String).flatMap { URL(string: $0)?.host } ?? "a page"
            return AgentStep(id: id, kind: .web, present: "Reading \(host)", past: "Read \(host)", detail: input["url"] as? String)
        case "Glob", "Grep":
            let p = input["pattern"] as? String ?? "files"
            return AgentStep(id: id, kind: .search, present: "Looking for \(p)", past: "Looked for \(p)", detail: p)
        case "TodoWrite":
            return AgentStep(id: id, kind: .plan, present: "Planning the steps", past: "Planned the steps")
        case "Task", "Agent":
            return AgentStep(id: id, kind: .helper, present: "Asking a helper", past: "Asked a helper", detail: input["description"] as? String)
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.split(separator: "_", omittingEmptySubsequences: true)
                let server = parts.count > 1 ? String(parts[1]).replacingOccurrences(of: "perch-", with: "").capitalized : "an app"
                return AgentStep(id: id, kind: .app, present: "Using \(server)", past: "Used \(server)")
            }
            return AgentStep(id: id, kind: .other, present: "Using \(name)", past: "Used \(name)")
        }
    }

    private static func commandPhrase(_ cmd: String, description: String?) -> (String, String) {
        let c = cmd.lowercased()
        let table: [(String, String, String)] = [
            ("npm install", "Installing dependencies", "Installed dependencies"),
            ("pip install", "Installing packages", "Installed packages"),
            ("uv pip", "Installing packages", "Installed packages"),
            ("npm run build", "Building the project", "Built the project"),
            ("npm test", "Running the tests", "Ran the tests"),
            ("pytest", "Running the tests", "Ran the tests"),
            ("git commit", "Committing changes", "Committed changes"),
            ("git push", "Pushing to the remote", "Pushed to the remote"),
            ("curl", "Downloading something", "Downloaded something"),
            ("python", "Running a script", "Ran a script"),
            ("node", "Running a script", "Ran a script"),
            ("mkdir", "Making folders", "Made folders"),
            ("ls", "Looking around", "Looked around"),
        ]
        if let hit = table.first(where: { c.hasPrefix($0.0) || c.contains(" && \($0.0)") }) { return (hit.1, hit.2) }
        if let d = description, !d.isEmpty {
            return (d, d)
        }
        let first = cmd.split(separator: " ").first.map(String.init) ?? "a command"
        return ("Running \(first)", "Ran \(first)")
    }
}

/// Splits the agent's final message into the reply and the tagged blocks.
enum FinalReplyParser {
    struct Parsed {
        var body: String
        var summary: String?
        var title: String?
        var nextActions: [String]
        var artifacts: [String]
    }

    static func parse(_ text: String) -> Parsed {
        func block(_ tag: String) -> String? {
            guard let open = text.range(of: "<\(tag)>"), let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
            else { return nil }
            return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func bullets(_ s: String?) -> [String] {
            (s ?? "").split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-•* ")).trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        }
        var body = text
        for tag in ["SUMMARY", "NEXT_ACTIONS", "DONE_TITLE", "ARTIFACTS", "ROUTINE"] {
            while let open = body.range(of: "<\(tag)>") {
                if let close = body.range(of: "</\(tag)>", range: open.upperBound..<body.endIndex) {
                    body.removeSubrange(open.lowerBound..<close.upperBound)
                } else {
                    body.removeSubrange(open.lowerBound..<body.endIndex)
                }
            }
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = block("SUMMARY") ?? body.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init)
        return Parsed(body: body, summary: summary, title: block("DONE_TITLE"),
                      nextActions: Array(bullets(block("NEXT_ACTIONS")).prefix(4)),
                      artifacts: bullets(block("ARTIFACTS")))
    }

    /// Hides tag blocks while the reply is still streaming.
    static func visibleStreamingText(_ text: String) -> String {
        if let tag = text.range(of: "<SUMMARY>") ?? text.range(of: "<NEXT_ACTIONS>") ?? text.range(of: "<DONE_TITLE>") ?? text.range(of: "<ARTIFACTS>") {
            return String(text[..<tag.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
