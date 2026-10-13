import Foundation

enum MCPError: LocalizedError {
    case server(String)
    case timedOut(String)
    case closed
    case badResponse
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .server(let m): return m
        case .timedOut(let method): return "No answer to \(method) in time."
        case .closed: return "The app's server stopped."
        case .badResponse: return "The app's server sent something unexpected."
        case .sessionExpired: return "The app's session expired. Perch reconnects on the next task."
        }
    }
}

/// How JSON-RPC messages reach an MCP server.
protocol MCPTransport: AnyObject {
    var isAlive: Bool { get }
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any]
    func notify(_ method: String) async
    func close()
}

/// One running connection to a connected app's MCP server, for a single agent turn.
final class MCPConnection: @unchecked Sendable {
    static let protocolVersion = "2025-06-18"

    struct Tool {
        var name: String
        var description: String
        var inputSchema: [String: Any]
    }

    let definition: ConnectorDefinition
    private let transport: MCPTransport
    private(set) var tools: [Tool] = []

    private init(definition: ConnectorDefinition, transport: MCPTransport) {
        self.definition = definition
        self.transport = transport
    }

    static func open(_ def: ConnectorDefinition, secrets: [String: String]) async throws -> MCPConnection {
        let transport: MCPTransport
        switch def.transport {
        case .stdio(let command, let args):
            var env = AgentSettings.environment()
            if case .env(let names, _) = def.auth { for n in names { env[n] = secrets[n] ?? "" } }
            transport = try StdioTransport(command: command, args: args, environment: env)
        case .http(let url):
            guard let u = URL(string: url) else { throw MCPError.server("Bad server URL: \(url)") }
            var headers: [String: String] = [:]
            if case .token(let header, let prefix, _) = def.auth { headers[header] = prefix + (secrets["TOKEN"] ?? "") }
            transport = HTTPTransport(url: u, headers: headers)
        }
        let conn = MCPConnection(definition: def, transport: transport)
        do {
            try await conn.handshake()
        } catch {
            transport.close()
            throw error
        }
        return conn
    }

    private func handshake() async throws {
        _ = try await transport.request("initialize", [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "Perch", "version": "1.0"],
        ], timeout: 90)
        await transport.notify("notifications/initialized")
        var cursor: String?
        repeat {
            let result = try await transport.request("tools/list", cursor.map { ["cursor": $0] } ?? [:], timeout: 60)
            for t in result["tools"] as? [[String: Any]] ?? [] {
                guard let name = t["name"] as? String else { continue }
                var schema = t["inputSchema"] as? [String: Any] ?? [:]
                schema["$schema"] = nil
                if schema["type"] == nil { schema["type"] = "object" }
                if schema["properties"] == nil { schema["properties"] = [:] as [String: Any] }
                tools.append(Tool(name: name, description: t["description"] as? String ?? name, inputSchema: schema))
            }
            cursor = result["nextCursor"] as? String
        } while cursor != nil
    }

    func call(_ tool: String, arguments: [String: Any]) async throws -> ToolOutput {
        activity.begin()
        defer { activity.end() }
        let result = try await transport.request("tools/call", ["name": tool, "arguments": arguments], timeout: 300)
        var parts: [String] = []
        for item in result["content"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "text": parts.append(item["text"] as? String ?? "")
            case "resource":
                let r = item["resource"] as? [String: Any]
                parts.append(r?["text"] as? String ?? "[resource \(r?["uri"] as? String ?? "")]")
            case "resource_link": parts.append("[link] \(item["uri"] as? String ?? "")")
            default: parts.append("[\(item["type"] as? String ?? "content")]")
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured) {
            parts.append(String(decoding: data, as: UTF8.self))
        }
        return ToolOutput(text: AgentToolbox.clip(parts.joined(separator: "\n")), isError: result["isError"] as? Bool ?? false)
    }

    var isAlive: Bool { transport.isAlive }

    /// Tracks use so the pool never closes a connection in the middle of a call.
    let activity = Activity()

    final class Activity: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private var last = Date()
        func begin() { lock.lock(); active += 1; last = Date(); lock.unlock() }
        func end() { lock.lock(); active -= 1; last = Date(); lock.unlock() }
        func idle(since cutoff: Date) -> Bool { lock.lock(); defer { lock.unlock() }; return active == 0 && last < cutoff }
    }

    func close() { transport.close() }
}

/// Keeps connected apps running between agent turns, so local servers (npx, uvx) start once
/// instead of on every task. Idle connections close after a while.
@MainActor
final class MCPPool {
    static let shared = MCPPool()
    static let idleLimit: TimeInterval = 15 * 60

    private struct Entry { var conn: MCPConnection; var key: String; var lastUsed: Date }
    private var live: [String: Entry] = [:]
    private var opening: [String: (key: String, task: Task<MCPConnection, Error>)] = [:]
    private var sweeper: Timer?

    /// Connections for these apps. Waits at most `wait` seconds for ones still starting; those keep
    /// starting in the background and are ready next time.
    func connections(for defs: [ConnectorDefinition], wait: TimeInterval) async -> (ready: [MCPConnection], problems: [String]) {
        startSweeper()
        let tasks = defs.map { def -> (ConnectorDefinition, Task<MCPConnection, Error>) in (def, task(for: def)) }
        return await withTaskGroup(of: (String, Result<MCPConnection, Error>?).self) { group in
            for (def, task) in tasks {
                group.addTask { (def.name, await Self.result(of: task, within: wait)) }
            }
            var ready: [MCPConnection] = []
            var problems: [String] = []
            for await (name, result) in group {
                switch result {
                case .success(let conn)?: ready.append(conn)
                case .failure(let error)?: problems.append("\(name) (\(error.localizedDescription))")
                case nil: problems.append("\(name) (still starting, try again in a moment)")
                }
            }
            return (ready, problems)
        }
    }

    /// The task's result, or nil if it isn't done within `seconds`. The task itself keeps running
    /// (a task group would wait for it, so this races with a continuation instead).
    nonisolated private static func result(of task: Task<MCPConnection, Error>, within seconds: TimeInterval) async -> Result<MCPConnection, Error>? {
        await withCheckedContinuation { (cont: CheckedContinuation<Result<MCPConnection, Error>?, Never>) in
            let once = Once()
            Task { let r = await task.result; if once.claim() { cont.resume(returning: r) } }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() { cont.resume(returning: nil) }
            }
        }
    }

    /// Closes a connector's server, e.g. after it's disconnected or its secrets change.
    func drop(_ id: String) {
        live.removeValue(forKey: id)?.conn.close()
        opening.removeValue(forKey: id)?.task.cancel()
    }

    /// Closes every server (and their child processes). Call when Perch quits.
    func closeAll() {
        for id in Set(live.keys).union(opening.keys) { drop(id) }
        sweeper?.invalidate()
        sweeper = nil
    }

    private func task(for def: ConnectorDefinition) -> Task<MCPConnection, Error> {
        let secrets = ConnectorStore.shared.secrets(for: def)
        let key = Self.key(def, secrets)
        if var entry = live[def.id] {
            if entry.key == key && entry.conn.isAlive {
                entry.lastUsed = Date()
                live[def.id] = entry
                let conn = entry.conn
                return Task { conn }
            }
            drop(def.id)
        }
        if let pending = opening[def.id], pending.key == key { return pending.task }
        let task = Task { try await MCPConnection.open(def, secrets: secrets) }
        opening[def.id] = (key, task)
        Task { [weak self] in
            let result = await task.result
            guard let self, self.opening[def.id]?.key == key else {
                if case .success(let conn) = result { conn.close() }
                return
            }
            self.opening[def.id] = nil
            if case .success(let conn) = result { self.live[def.id] = Entry(conn: conn, key: key, lastUsed: Date()) }
        }
        return task
    }

    private static func key(_ def: ConnectorDefinition, _ secrets: [String: String]) -> String {
        let data = (try? JSONEncoder().encode(def)) ?? Data()
        return String(decoding: data, as: UTF8.self) + secrets.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }

    private func startSweeper() {
        guard sweeper == nil else { return }
        sweeper = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in MCPPool.shared.sweep() }
        }
    }

    private func sweep() {
        let cutoff = Date().addingTimeInterval(-Self.idleLimit)
        for (id, entry) in live where !entry.conn.isAlive || (entry.lastUsed < cutoff && entry.conn.activity.idle(since: cutoff)) {
            drop(id)
        }
    }
}

/// Lets exactly one of several racing callers win.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// A local MCP server started as a child process, speaking newline-delimited JSON-RPC.
private final class StdioTransport: MCPTransport, @unchecked Sendable {
    /// One message bigger than this means the server is broken; it is stopped rather than buffered forever.
    private static let maxLineBytes = 32 * 1024 * 1024
    private static let stderrLinesKept = 6

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var buffer = Data()
    private var stderrTail: [String] = []
    private var stderrPartial = ""
    private var nextID = 1
    private var closed = false

    var isAlive: Bool { process.isRunning }

    /// Writing to a server that just exited must not kill Perch with SIGPIPE.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    init(command: String, args: [String], environment: [String: String]) throws {
        _ = Self.ignoreSIGPIPE
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        process.environment = environment
        process.currentDirectoryURL = ConnectorStore.folder
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] h in self?.consume(h.availableData) }
        errors.fileHandleForReading.readabilityHandler = { [weak self] h in self?.keepStderr(h.availableData) }
        process.terminationHandler = { [weak self] _ in
            // Give the last stderr lines (e.g. "env: uvx: No such file or directory") a moment to arrive.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                self.failAll(self.stoppedError())
            }
        }
        // Foundation starts the child as the leader of its own process group, so close() can stop
        // everything it spawned (npx and uvx start further processes).
        try process.run()
    }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let id = takeID()
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        // Stop must not wait out the timeout: cancelling resolves the call and tells the server.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                register(id, cont)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self else { return }
                    self.resolve(id, .failure(self.withStderr(MCPError.timedOut(method))))
                }
                if Task.isCancelled { resolve(id, .failure(CancellationError())) }
                else if !write(message) { resolve(id, .failure(stoppedError())) }
            }
        } onCancel: { [weak self] in
            self?.resolve(id, .failure(CancellationError()))
            self?.write(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": id]])
        }
    }

    func notify(_ method: String) async {
        _ = write(["jsonrpc": "2.0", "method": method])
    }

    func close() {
        lock.lock()
        let first = !closed
        closed = true
        lock.unlock()
        guard first else { return }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        // Stop the whole process group, then make sure anything that ignored SIGTERM goes too.
        let group = process.processIdentifier
        if group > 0 {
            kill(-group, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { kill(-group, SIGKILL) }
        }
        failAll(MCPError.closed)
    }

    /// The last few lines the server wrote to stderr, kept for error messages.
    private func keepStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        stderrPartial += String(decoding: data, as: UTF8.self)
        var lines = stderrPartial.components(separatedBy: "\n")
        stderrPartial = String((lines.removeLast()).suffix(500))
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { stderrTail.append(String(trimmed.prefix(300))) }
        }
        if stderrTail.count > Self.stderrLinesKept { stderrTail.removeFirst(stderrTail.count - Self.stderrLinesKept) }
    }

    private func recentStderr() -> String {
        lock.lock(); defer { lock.unlock() }
        let partial = stderrPartial.trimmingCharacters(in: .whitespaces)
        return (stderrTail + (partial.isEmpty ? [] : [partial])).suffix(Self.stderrLinesKept).joined(separator: " | ")
    }

    private func withStderr(_ error: MCPError) -> MCPError {
        let tail = recentStderr()
        guard !tail.isEmpty else { return error }
        return .server("\(error.localizedDescription) It said: \(tail)")
    }

    private func stoppedError() -> MCPError { withStderr(.closed) }

    private func takeID() -> Int {
        lock.lock(); defer { lock.unlock() }
        nextID += 1
        return nextID - 1
    }

    private func register(_ id: Int, _ cont: CheckedContinuation<[String: Any], Error>) {
        lock.lock(); defer { lock.unlock() }
        pending[id] = cont
    }

    @discardableResult
    private func write(_ message: [String: Any]) -> Bool {
        guard process.isRunning, var data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        data.append(0x0A)
        do { try input.fileHandleForWriting.write(contentsOf: data) } catch { return false }
        return true
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<nl))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        let overflow = buffer.count > Self.maxLineBytes
        if overflow { buffer = Data() }
        lock.unlock()
        if overflow {
            failAll(MCPError.server("The app's server sent a message larger than \(Self.maxLineBytes / 1_048_576) MB."))
            close()
            return
        }
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let method = obj["method"] as? String, let id = obj["id"] {
                // Requests from the server: answer pings, decline the rest.
                if method == "ping" { write(["jsonrpc": "2.0", "id": id, "result": [:] as [String: Any]]) }
                else { write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Not supported"]]) }
                continue
            }
            guard let id = obj["id"] as? Int else { continue }
            resolve(id, MCPResponse.parse(obj))
        }
    }

    private func resolve(_ id: Int, _ result: Result<[String: Any], Error>) {
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        cont?.resume(with: result)
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let all = pending
        pending = [:]
        lock.unlock()
        for cont in all.values { cont.resume(throwing: error) }
    }
}

/// A remote MCP server over Streamable HTTP (JSON or SSE replies).
private final class HTTPTransport: MCPTransport, @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private let lock = NSLock()
    private var _sessionID: String?
    private var _nextID = 1
    /// The version the server chose in its initialize reply; sent on every later request.
    private var _protocolVersion: String?
    private var _alive = true

    private var sessionID: String? {
        get { lock.lock(); defer { lock.unlock() }; return _sessionID }
        set { lock.lock(); _sessionID = newValue; lock.unlock() }
    }
    private var protocolVersion: String? {
        get { lock.lock(); defer { lock.unlock() }; return _protocolVersion }
        set { lock.lock(); _protocolVersion = newValue; lock.unlock() }
    }
    private func takeID() -> Int {
        lock.lock(); defer { lock.unlock() }
        _nextID += 1
        return _nextID - 1
    }

    /// False once the server has dropped our session, so the pool opens a fresh connection.
    var isAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return _alive
    }

    init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        guard isAlive else { throw MCPError.sessionExpired }
        let id = takeID()
        let response = try await post(["jsonrpc": "2.0", "id": id, "method": method, "params": params], expecting: id, timeout: timeout)
        guard let response else { throw MCPError.badResponse }
        let result = try MCPResponse.parse(response).get()
        if method == "initialize" {
            protocolVersion = result["protocolVersion"] as? String ?? MCPConnection.protocolVersion
        }
        return result
    }

    func notify(_ method: String) async {
        _ = try? await post(["jsonrpc": "2.0", "method": method], expecting: nil, timeout: 30)
    }

    func close() {
        guard let sessionID else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "DELETE"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        if let protocolVersion { req.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        URLSession.shared.dataTask(with: req).resume()
    }

    /// The server forgot our session (it restarted, or the session timed out).
    private func markExpired() {
        lock.lock()
        _alive = false
        _sessionID = nil
        lock.unlock()
    }

    /// Answers a request the server sent inside a reply stream: pings get an empty result, the rest are declined.
    private func answerServerRequest(_ obj: [String: Any]) {
        guard let method = obj["method"] as? String, let id = obj["id"] else { return }
        let reply: [String: Any] = method == "ping"
            ? ["jsonrpc": "2.0", "id": id, "result": [:] as [String: Any]]
            : ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Not supported"] as [String: Any]]
        Task { [weak self] in _ = try? await self?.post(reply, expecting: nil, timeout: 30) }
    }

    private func post(_ message: [String: Any], expecting id: Int?, timeout: TimeInterval) async throws -> [String: Any]? {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let sentSession = sessionID
        if let sentSession { req.setValue(sentSession, forHTTPHeaderField: "Mcp-Session-Id") }
        if let protocolVersion { req.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        req.httpBody = try JSONSerialization.data(withJSONObject: message)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw MCPError.badResponse }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = sid }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw MCPError.server("Not signed in (HTTP \(http.statusCode)). Check the token in Settings → Integrations.")
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 500 { break } }
            // The spec answers an unknown session with 404; some servers use 400 and say so in the body.
            if sentSession != nil,
               http.statusCode == 404 || (http.statusCode == 400 && body.localizedCaseInsensitiveContains("session")) {
                markExpired()
                throw MCPError.sessionExpired
            }
            throw MCPError.server("HTTP \(http.statusCode): \(body.prefix(300))")
        }
        guard let id else { return nil }

        if (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream") {
            var data = ""
            for try await line in bytes.lines {
                if line.hasPrefix("data:") {
                    data += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    // `lines` skips blank separators, so try each data line as a full event.
                    if let obj = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] {
                        data = ""
                        if obj["method"] != nil { answerServerRequest(obj); continue }
                        if obj["id"] as? Int == id { return obj }
                    }
                }
            }
            throw MCPError.badResponse
        }
        var raw = Data()
        for try await byte in bytes { raw.append(byte) }
        let json = try JSONSerialization.jsonObject(with: raw)
        if let obj = json as? [String: Any] { return obj }
        if let list = json as? [[String: Any]] { return list.first { $0["id"] as? Int == id } }
        throw MCPError.badResponse
    }
}

private enum MCPResponse {
    static func parse(_ obj: [String: Any]) -> Result<[String: Any], Error> {
        if let err = obj["error"] as? [String: Any] {
            return .failure(MCPError.server(err["message"] as? String ?? "Unknown error"))
        }
        return .success(obj["result"] as? [String: Any] ?? [:])
    }
}
