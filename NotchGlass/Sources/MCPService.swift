import Foundation

// MARK: - MCP servers
//
// Model Context Protocol servers the user lists in `mcp.json` (Application
// Support/Notchi), in the shape Claude Desktop, Cursor and VS Code already use.
// Each server is started (stdio) or reached (streamable HTTP) once, at launch
// and again whenever the file changes; every tool it offers joins the chat
// model's tools as `mcp_<server>_<tool>`.
//
// A tool the server marks read-only runs directly, like `read_file`. Anything
// else waits on the in-answer card first, like a flagged `run_shell`, unless
// the server's `autoApprove` names it.

/// One server entry in `mcp.json`.
struct MCPServerSpec: Sendable, Equatable {
    let name: String
    var command: String?
    var args: [String] = []
    var env: [String: String] = [:]
    var cwd: String?
    var url: URL?
    var headers: [String: String] = [:]
    /// `tools`: glob patterns a tool must match to be offered. Empty = all.
    var include: [String] = []
    /// `exclude`: glob patterns that keep a tool off.
    var exclude: [String] = []
    /// `autoApprove` (or Cline's `alwaysAllow`): tools that run without the card.
    var autoApprove: [String] = []

    func offers(_ tool: String) -> Bool {
        (include.isEmpty || include.contains { MCPConfig.matches($0, tool) })
            && !exclude.contains { MCPConfig.matches($0, tool) }
    }

    func autoApproves(_ tool: String) -> Bool {
        autoApprove.contains { MCPConfig.matches($0, tool) }
    }
}

/// A remote server forgot the session (HTTP 404 on it); the connection
/// starts a new one and retries once.
struct MCPSessionExpired: LocalizedError {
    var errorDescription: String? { "The server ended the session." }
}

struct MCPError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum MCPConfig {
    /// `~/Library/Application Support/Notchi/mcp.json`, beside the diagnostics
    /// log and the request audit.
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Notchi", isDirectory: true)
            .appendingPathComponent("mcp.json")
    }

    /// What a new file starts with: one example server, switched off.
    static let template = """
    {
      "mcpServers": {
        "filesystem": {
          "command": "npx",
          "args": ["-y", "@modelcontextprotocol/server-filesystem", "~/Documents"],
          "disabled": true
        }
      }
    }

    """

    /// The servers the file lists, the ones it lists but can't start (with
    /// why), and an error when the file itself can't be read. A missing file
    /// is no servers, not an error.
    struct Loaded {
        var specs: [MCPServerSpec] = []
        var skipped: [(name: String, reason: String)] = []
        var disabled: [String] = []
        var error: String?
    }

    static func load() -> Loaded {
        var out = Loaded()
        guard let data = try? Data(contentsOf: fileURL) else { return out }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            out.error = "mcp.json is not a JSON object."
            return out
        }
        // Claude Desktop / Cursor say `mcpServers`, VS Code says `servers`.
        let servers = (root["mcpServers"] as? [String: Any]) ?? (root["servers"] as? [String: Any]) ?? [:]
        for name in servers.keys.sorted() {
            guard let entry = servers[name] as? [String: Any] else {
                out.skipped.append((name, "Not a JSON object."))
                continue
            }
            if entry["disabled"] as? Bool == true {
                out.disabled.append(name)
                continue
            }
            switch spec(name: name, entry: entry) {
            case .success(let spec): out.specs.append(spec)
            case .failure(let error): out.skipped.append((name, error.message))
            }
        }
        return out
    }

    private static func spec(name: String, entry: [String: Any]) -> Result<MCPServerSpec, MCPError> {
        var missing: [String] = []
        let expand = { (value: String) in Self.expand(value, missing: &missing) }
        var spec = MCPServerSpec(name: name)
        let type = (entry["type"] as? String)?.lowercased()
        if type == "sse" {
            return .failure(MCPError("The legacy SSE transport is not supported; use the server's streamable HTTP URL."))
        }
        if let raw = entry["url"] as? String {
            guard let url = URL(string: expand(raw)), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return .failure(MCPError("url is not an http(s) address."))
            }
            spec.url = url
            for (key, value) in (entry["headers"] as? [String: Any]) ?? [:] {
                if let value = value as? String { spec.headers[key] = expand(value) }
            }
        } else if let command = entry["command"] as? String, !command.isEmpty {
            spec.command = expand(command)
            spec.args = ((entry["args"] as? [Any]) ?? []).map { expand("\($0)") }
            for (key, value) in (entry["env"] as? [String: Any]) ?? [:] {
                spec.env[key] = expand("\(value)")
            }
            spec.cwd = (entry["cwd"] as? String).map(expand)
        } else {
            return .failure(MCPError("Give a command or a url."))
        }
        spec.include = strings(entry["tools"])
        spec.exclude = strings(entry["exclude"])
        spec.autoApprove = strings(entry["autoApprove"]) + strings(entry["alwaysAllow"])
        // A secret left unset would start the server with an empty credential,
        // which fails later and less clearly.
        if !missing.isEmpty {
            return .failure(MCPError("Set \(missing.joined(separator: ", ")) first."))
        }
        return .success(spec)
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// `${NAME}` from Notchi's own environment, and a leading `~`.
    private static func expand(_ value: String, missing: inout [String]) -> String {
        var out = ""
        var rest = Substring(value)
        while let open = rest.range(of: "${") {
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else { break }
            out += rest[..<open.lowerBound]
            let key = String(rest[open.upperBound..<close])
            if let found = ProcessInfo.processInfo.environment[key] {
                out += found
            } else {
                missing.append(key)
            }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return out.hasPrefix("~") ? (out as NSString).expandingTildeInPath : out
    }

    /// Shell-style glob: `*`, `?` and `[...]`.
    static func matches(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }

    static var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    /// Creates the file from `template` when there is none, so "Edit" always
    /// has something to open.
    static func ensureFile() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: fileURL.path) else { return }
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? template.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Transports

/// JSON-RPC to one server.
protocol MCPTransport: AnyObject, Sendable {
    /// Sends a request and waits for its result. A JSON-RPC error is thrown.
    func request(_ method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any]
    func notify(_ method: String, params: [String: Any]?) async
    /// The protocol version `initialize` settled on, sent on later HTTP requests.
    func setProtocolVersion(_ version: String)
    func close()
}

enum MCPMessage {
    /// The result of a response, or its error thrown.
    static func result(of message: [String: Any]) throws -> [String: Any] {
        if let error = message["error"] as? [String: Any] {
            let text = (error["message"] as? String) ?? "Unknown error"
            throw MCPError(text)
        }
        return (message["result"] as? [String: Any]) ?? [:]
    }

    /// A response id as an Int; servers echo what they were sent.
    static func id(of message: [String: Any]) -> Int? {
        if let n = message["id"] as? NSNumber { return n.intValue }
        if let s = message["id"] as? String { return Int(s) }
        return nil
    }

    static func request(id: Int?, method: String, params: [String: Any]?) -> [String: Any] {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { message["id"] = id }
        if let params { message["params"] = params }
        return message
    }
}

/// A local server: a child process speaking newline-delimited JSON on its
/// stdin and stdout. Spawned through `ShellEnvironment`, so `npx` and `uvx`
/// resolve on the user's shell PATH the way they do in a terminal.
final class MCPStdioTransport: MCPTransport, @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let lock = NSLock()
    /// Writes take their own lock: a write blocked on a full pipe must not
    /// keep `receive` from draining the server's output.
    private let writeLock = NSLock()
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var stderrTail = ""
    private var closed = false
    /// Called once when the process exits on its own.
    var onExit: (@Sendable (String) -> Void)?
    /// Called when the server says its tool list changed.
    var onToolsChanged: (@Sendable () -> Void)?

    /// Ignoring SIGPIPE turns a write to a server that already exited into a
    /// thrown error instead of the end of Notchi.
    private static let ignorePipeSignal: Void = { _ = signal(SIGPIPE, SIG_IGN) }()

    init(spec: MCPServerSpec) throws {
        _ = Self.ignorePipeSignal
        guard let command = spec.command else { throw MCPError("No command.") }
        let binary: String
        if command.contains("/") {
            binary = command
        } else if let found = ShellEnvironment.which([command]) {
            binary = found
        } else {
            throw MCPError("\(command) was not found on your shell PATH.")
        }
        let cwd = spec.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let process = ShellEnvironment.makeProcess(binary, spec.args, cwd: cwd)
        var env = process.environment ?? [:]
        for (key, value) in spec.env { env[key] = value }
        process.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        self.process = process
        input = inPipe.fileHandleForWriting

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.receive(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.keepStderr(data)
        }
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let reason = self.exitReason(status: proc.terminationStatus)
            let wasClosed = self.finish(MCPError(reason))
            if !wasClosed { self.onExit?(reason) }
        }
        do {
            try process.run()
        } catch {
            throw MCPError("Could not start \(command): \(error.localizedDescription)")
        }
    }

    func setProtocolVersion(_ version: String) {}

    func request(_ method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any] {
        lock.lock()
        let id = nextID
        nextID += 1
        lock.unlock()
        let data = try Self.line(MCPMessage.request(id: id, method: method, params: params))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
                lock.lock()
                if closed {
                    lock.unlock()
                    cont.resume(throwing: MCPError(stderrSummary ?? "The server is not running."))
                    return
                }
                pending[id] = cont
                lock.unlock()
                do {
                    try write(data)
                } catch {
                    resolve(id, .failure(MCPError("Could not reach the server: \(error.localizedDescription)")))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, self.resolve(id, .failure(MCPError("\(method) took longer than \(Int(timeout))s."))) else { return }
                    self.cancelOnServer(id)
                }
            }
        } onCancel: {
            if resolve(id, .failure(CancellationError())) { cancelOnServer(id) }
        }
    }

    func notify(_ method: String, params: [String: Any]?) async {
        guard let data = try? Self.line(MCPMessage.request(id: nil, method: method, params: params)) else { return }
        try? write(data)
    }

    func close() {
        lock.lock()
        let wasClosed = closed
        lock.unlock()
        guard !wasClosed else { return }
        _ = finish(MCPError("The server was stopped."))
        writeLock.lock()
        try? input.close()
        writeLock.unlock()
        guard process.isRunning else { return }
        let process = self.process
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    // MARK: Plumbing

    private static func line(_ message: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        return data
    }

    private func write(_ data: Data) throws {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { throw MCPError("The server is not running.") }
        writeLock.lock()
        defer { writeLock.unlock() }
        try input.write(contentsOf: data)
    }

    private func cancelOnServer(_ id: Int) {
        Task { await notify("notifications/cancelled", params: ["requestId": id]) }
    }

    /// Hands a response to its waiting request; false when nothing waited.
    @discardableResult
    private func resolve(_ id: Int, _ outcome: Result<[String: Any], Error>) -> Bool {
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        guard let cont else { return false }
        cont.resume(with: outcome)
        return true
    }

    /// Marks the transport closed and fails every waiting request; returns
    /// whether it was already closed.
    private func finish(_ error: Error) -> Bool {
        lock.lock()
        let wasClosed = closed
        closed = true
        let waiting = pending
        pending = [:]
        lock.unlock()
        for cont in waiting.values { cont.resume(throwing: error) }
        return wasClosed
    }

    private func receive(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: line) else { continue }
            // A batch arrives as an array.
            let messages = (object as? [[String: Any]]) ?? [(object as? [String: Any])].compactMap { $0 }
            for message in messages { handle(message) }
        }
    }

    private func handle(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            if let id = message["id"] {
                answerServerRequest(method: method, id: id)
            } else if method == "notifications/tools/list_changed" {
                onToolsChanged?()
            }
            return
        }
        guard let id = MCPMessage.id(of: message) else { return }
        resolve(id, Result { try MCPMessage.result(of: message) })
    }

    /// Notchi offers no client features (sampling, roots, elicitation), so
    /// beyond `ping` a server's request is answered "not supported".
    private func answerServerRequest(method: String, id: Any) {
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if method == "ping" {
            reply["result"] = [String: Any]()
        } else {
            reply["error"] = ["code": -32601, "message": "Notchi does not support \(method)."] as [String: Any]
        }
        if let data = try? Self.line(reply) { try? write(data) }
    }

    private func keepStderr(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        stderrTail = String((stderrTail + text).suffix(2000))
        lock.unlock()
    }

    /// The server's last stderr line, which is usually why it stopped.
    private var stderrSummary: String? {
        lock.lock()
        defer { lock.unlock() }
        let lines = stderrTail.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.last.map { String($0.prefix(300)) }
    }

    private func exitReason(status: Int32) -> String {
        let base = "The server exited (code \(status))."
        guard let detail = stderrSummary else { return base }
        return base + " " + detail
    }
}

/// A remote server over streamable HTTP: every message is a POST, and the
/// answer comes back as JSON or as a short event stream.
final class MCPHTTPTransport: MCPTransport, @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private let lock = NSLock()
    private var nextID = 1
    private var sessionID: String?
    private var protocolVersion: String?

    init(spec: MCPServerSpec) throws {
        guard let url = spec.url else { throw MCPError("No url.") }
        self.url = url
        headers = spec.headers
    }

    func setProtocolVersion(_ version: String) {
        lock.lock(); protocolVersion = version; lock.unlock()
    }

    func request(_ method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any] {
        lock.lock()
        let id = nextID
        nextID += 1
        lock.unlock()
        let message = MCPMessage.request(id: id, method: method, params: params)
        guard let reply = try await post(message, timeout: timeout, awaiting: id) else {
            throw MCPError("The server sent no reply to \(method).")
        }
        return try MCPMessage.result(of: reply)
    }

    func notify(_ method: String, params: [String: Any]?) async {
        let message = MCPMessage.request(id: nil, method: method, params: params)
        _ = try? await post(message, timeout: 15, awaiting: nil)
    }

    func close() {
        lock.lock()
        let session = sessionID
        sessionID = nil
        lock.unlock()
        guard let session else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "DELETE"
        req.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        ProxyConfig.urlSession.dataTask(with: req).resume()
    }

    private func post(_ message: [String: Any], timeout: TimeInterval, awaiting id: Int?) async throws -> [String: Any]? {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        lock.lock()
        let session = sessionID, version = protocolVersion
        lock.unlock()
        if let session { req.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        if let version { req.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        req.httpBody = try JSONSerialization.data(withJSONObject: message)

        let (bytes, response) = try await ProxyConfig.urlSession.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw MCPError("Not an HTTP response.") }
        if let assigned = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            lock.lock(); sessionID = assigned; lock.unlock()
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 400 { break }
            }
            let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if http.statusCode == 404, session != nil {
                lock.lock(); sessionID = nil; lock.unlock()
                throw MCPSessionExpired()
            }
            let auth = http.statusCode == 401 || http.statusCode == 403
                ? " Check the Authorization header in mcp.json." : ""
            throw MCPError("HTTP \(http.statusCode)." + auth + (text.isEmpty ? "" : " " + String(text.prefix(300))))
        }
        guard let id else { return nil }

        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if type.contains("text/event-stream") {
            // Each event's data is one JSON-RPC message; requests and
            // notifications from the server may come first. An event is
            // complete once its data lines parse, so blank separators are not
            // needed to find its end.
            var data = ""
            for try await line in bytes.lines {
                if line.hasPrefix("data:") {
                    var chunk = line.dropFirst(5)
                    if chunk.first == " " { chunk = chunk.dropFirst() }
                    data += data.isEmpty ? String(chunk) : "\n" + String(chunk)
                } else if !data.isEmpty, !line.hasPrefix(":") {
                    data = ""
                }
                guard !data.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) else { continue }
                data = ""
                if let found = Self.reply(in: object, to: id) { return found }
            }
            return nil
        }
        var body = Data()
        for try await byte in bytes { body.append(byte) }
        guard let object = try? JSONSerialization.jsonObject(with: body) else {
            throw MCPError("The server's reply is not JSON.")
        }
        return Self.reply(in: object, to: id)
    }

    private static func reply(in object: Any, to id: Int) -> [String: Any]? {
        let messages = (object as? [[String: Any]]) ?? [(object as? [String: Any])].compactMap { $0 }
        return messages.first { $0["method"] == nil && MCPMessage.id(of: $0) == id }
    }
}

// MARK: - A connected server

struct MCPToolInfo: @unchecked Sendable {
    let name: String
    let title: String?
    let description: String
    let inputSchema: [String: Any]
    let readOnly: Bool
}

/// One live server: its transport, past `initialize`, and its tools.
final class MCPConnection: @unchecked Sendable {
    static let protocolVersion = "2025-06-18"

    let spec: MCPServerSpec
    let transport: MCPTransport

    private init(spec: MCPServerSpec, transport: MCPTransport) {
        self.spec = spec
        self.transport = transport
    }

    /// Starts or reaches the server and completes the handshake. The first run
    /// of an `npx` server downloads it, so the handshake gets a long timeout.
    static func connect(_ spec: MCPServerSpec,
                        onExit: @escaping @Sendable (String) -> Void,
                        onToolsChanged: @escaping @Sendable () -> Void) async throws -> MCPConnection {
        let transport: MCPTransport
        if spec.url != nil {
            transport = try MCPHTTPTransport(spec: spec)
        } else {
            let stdio = try MCPStdioTransport(spec: spec)
            stdio.onExit = onExit
            stdio.onToolsChanged = onToolsChanged
            transport = stdio
        }
        let connection = MCPConnection(spec: spec, transport: transport)
        do {
            try await connection.initialize()
        } catch {
            transport.close()
            throw error
        }
        return connection
    }

    private func initialize() async throws {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let result = try await transport.request("initialize", params: [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Notchi", "version": version],
        ], timeout: 90)
        if let agreed = result["protocolVersion"] as? String { transport.setProtocolVersion(agreed) }
        await transport.notify("notifications/initialized", params: nil)
    }

    /// Every tool the server lists, across pages, that `spec` lets through.
    func listTools() async throws -> [MCPToolInfo] {
        var tools: [MCPToolInfo] = []
        var cursor: String?
        for _ in 0..<20 {
            let params: [String: Any]? = cursor.map { ["cursor": $0] }
            let result = try await transport.request("tools/list", params: params, timeout: 30)
            for raw in (result["tools"] as? [[String: Any]]) ?? [] {
                guard let name = raw["name"] as? String, spec.offers(name) else { continue }
                let annotations = raw["annotations"] as? [String: Any]
                tools.append(MCPToolInfo(
                    name: name,
                    title: (raw["title"] as? String) ?? (annotations?["title"] as? String),
                    description: (raw["description"] as? String) ?? "",
                    inputSchema: (raw["inputSchema"] as? [String: Any]) ?? [:],
                    readOnly: annotations?["readOnlyHint"] as? Bool == true))
            }
            cursor = result["nextCursor"] as? String
            if cursor == nil { break }
        }
        return tools
    }

    func call(_ tool: String, arguments: [String: Any]) async throws -> String {
        let params: [String: Any] = ["name": tool, "arguments": arguments]
        let result: [String: Any]
        do {
            result = try await transport.request("tools/call", params: params, timeout: 300)
        } catch is MCPSessionExpired {
            try await initialize()
            result = try await transport.request("tools/call", params: params, timeout: 300)
        }
        let text = Self.render(result)
        if result["isError"] as? Bool == true { throw MCPError(text.isEmpty ? "The tool failed." : text) }
        return text.isEmpty ? "(no output)" : text
    }

    static let outputLimit = 12_000

    /// The result's content as text the model reads. Images and audio are
    /// named, not inlined: tool results on the wire are text.
    static func render(_ result: [String: Any]) -> String {
        var parts: [String] = []
        for item in (result["content"] as? [[String: Any]]) ?? [] {
            switch item["type"] as? String {
            case "text":
                if let text = item["text"] as? String { parts.append(text) }
            case "image", "audio":
                parts.append("[\(item["type"] as? String ?? "media"): \(item["mimeType"] as? String ?? "unknown type"), not shown]")
            case "resource":
                let resource = item["resource"] as? [String: Any]
                if let text = resource?["text"] as? String {
                    parts.append(text)
                } else {
                    parts.append("[resource: \(resource?["uri"] as? String ?? "")]")
                }
            case "resource_link":
                let name = (item["name"] as? String) ?? ""
                parts.append("[link: \(name) \(item["uri"] as? String ?? "")]")
            default:
                continue
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"],
           JSONSerialization.isValidJSONObject(structured),
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) {
            parts.append(String(decoding: data, as: UTF8.self))
        }
        var text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > outputLimit {
            let cut = text.count - outputLimit
            text = text.prefix(outputLimit) + "\n[… \(cut) characters omitted …]"
        }
        return text
    }

    func close() { transport.close() }
}

// MARK: - The servers, for the app

/// Owns the configured servers: starts them at launch, restarts them when
/// `mcp.json` changes, and hands each question their tools.
@MainActor
final class MCPHub: ObservableObject {
    static let shared = MCPHub()

    /// More tools than this are held behind `load_tools` rather than sent on
    /// every request: a big server (dozens of tools) would otherwise cost every
    /// question its descriptions.
    static let advertiseLimit = 8

    enum Status: Equatable {
        case starting
        case ready(tools: Int)
        case failed(String)
        case off
    }

    struct Server: Identifiable, Equatable {
        let name: String
        var status: Status
        var id: String { name }
    }

    @Published private(set) var servers: [Server] = []
    @Published private(set) var configError: String?

    private var connections: [String: MCPConnection] = [:]
    private var tools: [String: [MCPToolInfo]] = [:]
    private var loadedStamp: Date?
    /// Bumped on every reload, so a connect that finishes after the next
    /// reload began is dropped instead of resurrecting a stale server.
    private var generation = 0

    private init() {}

    /// Reads `mcp.json` and connects every enabled server. Safe to call again:
    /// it starts over.
    func reload() {
        generation += 1
        let current = generation
        for connection in connections.values { connection.close() }
        connections = [:]
        tools = [:]
        loadedStamp = MCPConfig.modificationDate
        let loaded = MCPConfig.load()
        configError = loaded.error
        var list = loaded.specs.map { Server(name: $0.name, status: .starting) }
        list += loaded.skipped.map { Server(name: $0.name, status: .failed($0.reason)) }
        list += loaded.disabled.map { Server(name: $0, status: .off) }
        servers = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for spec in loaded.specs { connect(spec, generation: current) }
    }

    /// Reloads when the file changed since the last read. Cheap enough to call
    /// on every question.
    func reloadIfChanged() {
        if MCPConfig.modificationDate != loadedStamp { reload() }
    }

    /// Restarts one server, from Settings.
    func restart(_ name: String) {
        // A server the file can't start (an unset secret) needs the file
        // read again, not a restart.
        guard let spec = MCPConfig.load().specs.first(where: { $0.name == name }) else {
            reload()
            return
        }
        connections.removeValue(forKey: name)?.close()
        tools[name] = nil
        set(name, .starting)
        connect(spec, generation: generation)
    }

    private func connect(_ spec: MCPServerSpec, generation current: Int) {
        let name = spec.name
        Task { [weak self] in
            do {
                let connection = try await MCPConnection.connect(
                    spec,
                    onExit: { reason in
                        Task { @MainActor in MCPHub.shared.lost(name, reason: reason, generation: current) }
                    },
                    onToolsChanged: {
                        Task { @MainActor in await MCPHub.shared.refreshTools(name) }
                    })
                let list = try await connection.listTools()
                guard let self, self.generation == current else { connection.close(); return }
                self.connections[name] = connection
                self.tools[name] = list
                self.set(name, .ready(tools: list.count))
            } catch {
                guard let self, self.generation == current else { return }
                self.set(name, .failed(error.localizedDescription))
            }
        }
    }

    private func lost(_ name: String, reason: String, generation current: Int) {
        guard generation == current, connections[name] != nil else { return }
        connections[name] = nil
        tools[name] = nil
        set(name, .failed(reason))
    }

    private func refreshTools(_ name: String) async {
        guard let connection = connections[name],
              let list = try? await connection.listTools(),
              connections[name] === connection else { return }
        tools[name] = list
        set(name, .ready(tools: list.count))
    }

    private func set(_ name: String, _ status: Status) {
        guard let index = servers.firstIndex(where: { $0.name == name }) else { return }
        servers[index].status = status
    }

    /// The connected servers' tools for one question. `confirm` shows the
    /// in-answer card for a call that changes something.
    func agentTools(confirm: @escaping MCPTool.Confirm) -> [NotchTool] {
        var out: [NotchTool] = []
        var taken = Set<String>()
        for name in connections.keys.sorted() {
            guard let connection = connections[name] else { continue }
            for info in tools[name] ?? [] {
                let wire = MCPTool.wireName(server: name, tool: info.name)
                guard taken.insert(wire).inserted else { continue }
                out.append(MCPTool(name: wire, server: name, info: info,
                                   connection: connection, confirm: confirm))
            }
        }
        return out
    }
}

// MARK: - The tool the model calls

/// One MCP tool, as a `NotchTool`.
struct MCPTool: NotchTool {
    /// Shows the card: server, tool title, arguments; true when the user chose to run it.
    typealias Confirm = @Sendable (_ server: String, _ tool: String, _ input: [String: Any]) async throws -> Bool

    let name: String
    let description: String
    let schema: [String: Any]
    let server: String
    let info: MCPToolInfo
    let connection: MCPConnection
    let confirm: Confirm

    init(name: String, server: String, info: MCPToolInfo, connection: MCPConnection, confirm: @escaping Confirm) {
        self.name = name
        self.server = server
        self.info = info
        self.connection = connection
        self.confirm = confirm
        var text = info.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = info.title ?? info.name }
        if text.count > 1000 { text = text.prefix(1000) + "…" }
        description = text + "\n\n(A tool from the user's \(server) MCP server.)"
        schema = Self.sanitized(info.inputSchema)
    }

    func execute(_ input: [String: Any]) async throws -> String {
        if !info.readOnly && !connection.spec.autoApproves(info.name) {
            guard try await confirm(server, info.title ?? info.name, input) else {
                return "The user did not approve this. It was not run. Do not retry it."
            }
        }
        return try await connection.call(info.name, arguments: input)
    }

    /// `mcp_<server>_<tool>`, in the characters and length every provider
    /// accepts for a function name.
    static func wireName(server: String, tool: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let clean = { (s: String) in String(s.map { allowed.contains($0) ? $0 : "_" }) }
        return String("mcp_\(clean(server))_\(clean(tool))".prefix(64))
    }

    /// The server's input schema as a function's parameters: always an object
    /// with properties, without the keywords some providers reject.
    static func sanitized(_ schema: [String: Any]) -> [String: Any] {
        var out = schema
        out.removeValue(forKey: "$schema")
        out.removeValue(forKey: "$id")
        out["type"] = "object"
        if !(out["properties"] is [String: Any]) { out["properties"] = [String: Any]() }
        return out
    }
}
