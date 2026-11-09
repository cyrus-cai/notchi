import AppKit
import CryptoKit
import Foundation
import Network

// MARK: - MCP servers
//
// Model Context Protocol servers the user lists in `mcp.json` (Application
// Support/Notchi), in the shape Claude Desktop, Cursor and VS Code already use,
// plus the servers already set up in those apps, Claude Code, Codex, Windsurf
// and Gemini CLI. Each server is started (stdio) or reached (streamable HTTP)
// once, at launch and again whenever a file changes one; every tool it offers
// joins the chat model's tools as `mcp_<server>_<tool>`.
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
    /// The built-in connector whose OAuth sign-in authorizes this server.
    var oauthConnector: String?

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

    /// Another app's MCP settings. Their servers are used too, so a server set
    /// up there works here without copying it into `mcp.json`.
    struct Source {
        let app: String
        let url: URL
        var codex = false
    }

    static let sources: [Source] = {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let support = home.appendingPathComponent("Library/Application Support")
        return [
            Source(app: "Claude Desktop", url: support.appendingPathComponent("Claude/claude_desktop_config.json")),
            Source(app: "Claude Code", url: home.appendingPathComponent(".claude.json")),
            Source(app: "Codex", url: home.appendingPathComponent(".codex/config.toml"), codex: true),
            Source(app: "Cursor", url: home.appendingPathComponent(".cursor/mcp.json")),
            Source(app: "VS Code", url: support.appendingPathComponent("Code/User/mcp.json")),
            Source(app: "Windsurf", url: home.appendingPathComponent(".codeium/windsurf/mcp_config.json")),
            Source(app: "Gemini CLI", url: home.appendingPathComponent(".gemini/settings.json")),
        ]
    }()

    /// The servers the files list, the ones they list but can't start (with
    /// why), and an error when `mcp.json` itself can't be read. A missing file
    /// is no servers, not an error.
    struct Loaded {
        var specs: [MCPServerSpec] = []
        var skipped: [(name: String, reason: String)] = []
        var disabled: [String] = []
        var error: String?
        /// The app each server came from; nil for `mcp.json`.
        var sources: [String: String] = [:]
        /// Every entry as read, to tell whether a changed file changed a server.
        var raw: [String: Any] = [:]

        var fingerprint: Data? {
            try? JSONSerialization.data(
                withJSONObject: ["servers": raw, "sources": sources, "error": error ?? ""],
                options: .sortedKeys)
        }
    }

    /// Servers from `mcp.json` and other apps' settings are switched off for
    /// now; only the connectors signed in from Settings load.
    static let userServersEnabled = false

    /// Connectors first, then `mcp.json`, then each other app in `sources` order. A name already
    /// taken is skipped, so an entry in `mcp.json` (`"disabled": true` included)
    /// overrides another app's server of the same name.
    static func load() -> Loaded {
        var out = Loaded()
        var taken = Set<String>()
        for connector in MCPConnector.all where MCPTokenStore.load(connector.id) != nil {
            taken.insert(connector.id)
            var spec = MCPServerSpec(name: connector.id)
            spec.url = connector.url
            spec.oauthConnector = connector.id
            out.specs.append(spec)
            out.sources[connector.id] = connector.title
            out.raw[connector.id] = ["url": connector.url.absoluteString]
        }
        guard userServersEnabled else { return out }
        if let data = try? Data(contentsOf: fileURL) {
            if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                add(servers(in: root), source: nil, base: fileURL.deletingLastPathComponent(),
                    to: &out, taken: &taken)
            } else {
                out.error = "mcp.json is not a JSON object."
            }
        }
        for source in sources {
            guard let data = try? Data(contentsOf: source.url) else { continue }
            let entries: [String: Any]
            if source.codex {
                guard let text = String(data: data, encoding: .utf8) else { continue }
                entries = codexServers(MiniTOML.parse(text))
            } else {
                guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                entries = servers(in: root)
            }
            add(entries, source: source.app, base: source.url.deletingLastPathComponent(),
                to: &out, taken: &taken)
        }
        return out
    }

    /// Claude Desktop / Cursor say `mcpServers`, VS Code says `servers`.
    private static func servers(in root: [String: Any]) -> [String: Any] {
        (root["mcpServers"] as? [String: Any]) ?? (root["servers"] as? [String: Any]) ?? [:]
    }

    private static func add(_ entries: [String: Any], source: String?, base: URL,
                            to out: inout Loaded, taken: inout Set<String>) {
        for name in entries.keys.sorted() where taken.insert(name).inserted {
            out.raw[name] = entries[name]
            out.sources[name] = source
            guard let entry = entries[name] as? [String: Any] else {
                out.skipped.append((name, "Not a JSON object."))
                continue
            }
            if entry["disabled"] as? Bool == true {
                out.disabled.append(name)
                continue
            }
            switch spec(name: name, entry: entry, base: base) {
            case .success(let spec): out.specs.append(spec)
            case .failure(let error): out.skipped.append((name, error.message))
            }
        }
    }

    /// Codex's `[mcp_servers.<name>]` tables, in `mcp.json`'s shape.
    private static func codexServers(_ root: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (name, value) in (root["mcp_servers"] as? [String: Any]) ?? [:] {
            guard var entry = value as? [String: Any] else { continue }
            if entry["enabled"] as? Bool == false { entry["disabled"] = true }
            var headers = (entry["http_headers"] as? [String: Any]) ?? [:]
            for (header, variable) in (entry["env_http_headers"] as? [String: Any]) ?? [:] {
                headers[header] = "${\(variable)}"
            }
            if let variable = entry["bearer_token_env_var"] as? String {
                headers["Authorization"] = "Bearer ${\(variable)}"
            }
            if !headers.isEmpty { entry["headers"] = headers }
            if let tools = entry["enabled_tools"] { entry["tools"] = tools }
            if let tools = entry["disabled_tools"] { entry["exclude"] = tools }
            out[name] = entry
        }
        return out
    }

    /// A relative `cwd` or `./command` is taken from the folder of the file
    /// that lists it.
    private static func spec(name: String, entry: [String: Any], base: URL) -> Result<MCPServerSpec, MCPError> {
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
            spec.cwd = (entry["cwd"] as? String).map(expand).map {
                $0.hasPrefix("/") ? $0 : base.appendingPathComponent($0).standardized.path
            }
            if let command = spec.command, command.hasPrefix("./") || command.hasPrefix("../") {
                let folder = spec.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? base
                spec.command = folder.appendingPathComponent(command).standardized.path
            }
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

    /// When `mcp.json` and each file in `sources` last changed.
    static var modificationDates: [Date?] {
        ([fileURL] + sources.map(\.url)).map {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
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
    private let connector: String?
    private let lock = NSLock()
    private var nextID = 1
    private var sessionID: String?
    private var protocolVersion: String?

    init(spec: MCPServerSpec) throws {
        guard let url = spec.url else { throw MCPError("No url.") }
        self.url = url
        headers = spec.headers
        connector = spec.oauthConnector
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
        if let connector, let token = MCPTokenStore.load(connector) {
            req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        }
        ProxyConfig.urlSession.dataTask(with: req).resume()
    }

    /// A connector's server answered 401: the access token is refreshed and
    /// the message sent once more.
    private struct Unauthorized: Error {}

    private func post(_ message: [String: Any], timeout: TimeInterval, awaiting id: Int?) async throws -> [String: Any]? {
        do {
            return try await send(message, timeout: timeout, awaiting: id, refresh: false)
        } catch is Unauthorized {
            do {
                return try await send(message, timeout: timeout, awaiting: id, refresh: true)
            } catch is Unauthorized {
                let title = MCPConnector.find(connector)?.title ?? "The server"
                throw MCPError("\(title) refused the sign-in. Connect it again in Settings.")
            }
        }
    }

    private func send(_ message: [String: Any], timeout: TimeInterval, awaiting id: Int?,
                      refresh: Bool) async throws -> [String: Any]? {
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
        if let connector {
            let token = try await MCPTokens.shared.accessToken(connector, forceRefresh: refresh)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
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
            if http.statusCode == 401, connector != nil { throw Unauthorized() }
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
        if let local = MCPLocalTransport.server(for: spec) {
            transport = MCPLocalTransport(local)
        } else if spec.url != nil {
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


    enum Status: Equatable {
        case starting
        case ready(tools: Int)
        case failed(String)
        case off
    }

    struct Server: Identifiable, Equatable {
        let name: String
        /// The app whose settings list it; nil for `mcp.json`.
        let source: String?
        var status: Status
        var id: String { name }
    }

    @Published private(set) var servers: [Server] = []
    @Published private(set) var configError: String?

    private var connections: [String: MCPConnection] = [:]
    private var tools: [String: [MCPToolInfo]] = [:]
    private var loadedStamps: [Date?] = []
    private var loadedFingerprint: Data?
    /// Bumped on every reload, so a connect that finishes after the next
    /// reload began is dropped instead of resurrecting a stale server.
    private var generation = 0

    private init() {}

    /// Reads the files and connects every enabled server. Safe to call again:
    /// it starts over.
    func reload() {
        loadedStamps = MCPConfig.modificationDates
        apply(MCPConfig.load())
    }

    private func apply(_ loaded: MCPConfig.Loaded) {
        generation += 1
        let current = generation
        for connection in connections.values { connection.close() }
        connections = [:]
        tools = [:]
        loadedFingerprint = loaded.fingerprint
        configError = loaded.error
        let source = { (name: String) in loaded.sources[name] }
        var list = loaded.specs.map { Server(name: $0.name, source: source($0.name), status: .starting) }
        list += loaded.skipped.map { Server(name: $0.name, source: source($0.name), status: .failed($0.reason)) }
        list += loaded.disabled.map { Server(name: $0, source: source($0), status: .off) }
        servers = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for spec in loaded.specs { connect(spec, generation: current) }
    }

    /// Reloads when a file changed one of its servers since the last read.
    /// Cheap enough to call on every question: a file is read again only when
    /// it was saved, and servers restart only when an entry differs (Claude
    /// Code saves `~/.claude.json` all the time for other reasons).
    func reloadIfChanged() {
        let stamps = MCPConfig.modificationDates
        guard stamps != loadedStamps else { return }
        loadedStamps = stamps
        let loaded = MCPConfig.load()
        if loaded.fingerprint != loadedFingerprint { apply(loaded) }
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

    /// The apps `load_tools` names, from one question's MCP tools: each
    /// server's tools and the connector's defaults among them.
    nonisolated static func connectedApps(_ tools: [NotchTool]) -> [ConnectedApp] {
        var order: [String] = []
        var byServer: [String: [MCPTool]] = [:]
        for case let tool as MCPTool in tools {
            if byServer[tool.server] == nil { order.append(tool.server) }
            byServer[tool.server, default: []].append(tool)
        }
        return order.map { server in
            let list = byServer[server] ?? []
            let connector = MCPConnector.find(server)
            let defaults = (connector?.defaultTools ?? []).compactMap { raw in
                list.first { $0.info.name == raw }?.name
            }
            return ConnectedApp(title: connector?.title ?? server, tools: list.map(\.name), defaults: defaults)
        }
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

// MARK: - Codex's config.toml

/// Enough TOML to read Codex's `[mcp_servers.*]` tables: tables, dotted and
/// quoted keys, strings (basic, literal, multi-line), numbers, booleans,
/// arrays and inline tables. Arrays of tables (`[[x]]`) are skipped. A line
/// it can't read is skipped, not the whole file.
enum MiniTOML {
    static func parse(_ text: String) -> [String: Any] {
        var parser = Parser(chars: Array(text))
        return parser.document()
    }

    private struct Parser {
        let chars: [Character]
        var i = 0
        var root: [String: Any] = [:]

        init(chars: [Character]) { self.chars = chars }

        var peek: Character? { i < chars.count ? chars[i] : nil }

        func at(_ s: String) -> Bool {
            let s = Array(s)
            return i + s.count <= chars.count && Array(chars[i..<i + s.count]) == s
        }

        mutating func skipSpace(newlines: Bool) {
            while let c = peek {
                if c == " " || c == "\t" || c == "\r" || (newlines && c == "\n") {
                    i += 1
                } else if c == "#" {
                    while let c = peek, c != "\n" { i += 1 }
                } else {
                    break
                }
            }
        }

        mutating func skipLine() {
            while let c = peek, c != "\n" { i += 1 }
        }

        mutating func document() -> [String: Any] {
            var table: [String]? = []
            while true {
                skipSpace(newlines: true)
                guard let c = peek else { break }
                if at("[[") {
                    table = nil
                    skipLine()
                } else if c == "[" {
                    i += 1
                    skipSpace(newlines: false)
                    table = key()
                    skipSpace(newlines: false)
                    if peek == "]" { i += 1 } else { table = nil }
                    skipLine()
                } else if let path = key() {
                    skipSpace(newlines: false)
                    guard peek == "=" else { skipLine(); continue }
                    i += 1
                    skipSpace(newlines: false)
                    if let value = value(), let table {
                        Self.insert(value, at: table + path, into: &root)
                    }
                    skipLine()
                } else {
                    skipLine()
                }
            }
            return root
        }

        /// A dotted key: `a.b."c d"`. Nil when there is none here.
        mutating func key() -> [String]? {
            var parts: [String] = []
            while true {
                skipSpace(newlines: false)
                if peek == "\"" || peek == "'" {
                    guard let part = string() else { return nil }
                    parts.append(part)
                } else {
                    var part = ""
                    while let c = peek, c.isLetter || c.isNumber || c == "_" || c == "-" {
                        part.append(c)
                        i += 1
                    }
                    guard !part.isEmpty else { return nil }
                    parts.append(part)
                }
                skipSpace(newlines: false)
                guard peek == "." else { return parts }
                i += 1
            }
        }

        mutating func value() -> Any? {
            guard let c = peek else { return nil }
            switch c {
            case "\"", "'":
                return string()
            case "[":
                i += 1
                var items: [Any] = []
                while true {
                    skipSpace(newlines: true)
                    if peek == "]" { i += 1; return items }
                    guard let item = value() else { return nil }
                    items.append(item)
                    skipSpace(newlines: true)
                    if peek == "," { i += 1 }
                }
            case "{":
                i += 1
                var table: [String: Any] = [:]
                while true {
                    skipSpace(newlines: false)
                    if peek == "}" { i += 1; return table }
                    guard let path = key() else { return nil }
                    skipSpace(newlines: false)
                    guard peek == "=" else { return nil }
                    i += 1
                    skipSpace(newlines: false)
                    guard let item = value() else { return nil }
                    Self.insert(item, at: path, into: &table)
                    skipSpace(newlines: false)
                    if peek == "," { i += 1 }
                }
            default:
                var token = ""
                while let c = peek, !",]}\n#".contains(c) {
                    token.append(c)
                    i += 1
                }
                token = token.trimmingCharacters(in: .whitespaces)
                if token == "true" { return true }
                if token == "false" { return false }
                let digits = token.replacingOccurrences(of: "_", with: "")
                if let number = Int(digits) { return number }
                if let number = Double(digits) { return number }
                return token.isEmpty ? nil : token
            }
        }

        mutating func string() -> String? {
            guard let quote = peek else { return nil }
            let literal = quote == "'"
            let triple = at(String(repeating: quote, count: 3))
            i += triple ? 3 : 1
            if triple, peek == "\n" { i += 1 }
            var out = ""
            while let c = peek {
                if triple ? at(String(repeating: quote, count: 3)) : c == quote {
                    i += triple ? 3 : 1
                    return out
                }
                if !triple && c == "\n" { return nil }
                i += 1
                guard c == "\\" && !literal, let next = peek else {
                    out.append(c)
                    continue
                }
                i += 1
                switch next {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "u", "U":
                    let count = next == "u" ? 4 : 8
                    guard i + count <= chars.count,
                          let code = UInt32(String(chars[i..<i + count]), radix: 16),
                          let scalar = Unicode.Scalar(code) else { return nil }
                    out.unicodeScalars.append(scalar)
                    i += count
                case "\n":
                    // A line-ending backslash joins the next line.
                    while let c = peek, c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1 }
                default: out.append(next)
                }
            }
            return nil
        }

        static func insert(_ value: Any, at path: [String], into table: inout [String: Any]) {
            guard let first = path.first else { return }
            if path.count == 1 {
                table[first] = value
                return
            }
            var child = (table[first] as? [String: Any]) ?? [:]
            insert(value, at: Array(path.dropFirst()), into: &child)
            table[first] = child
        }
    }
}

// MARK: - Connectors

/// A remote MCP server Notchi knows by name, signed in to with OAuth from
/// Settings > Connect instead of a line in `mcp.json`.
struct MCPConnector: Identifiable, Sendable {
    let id: String
    let title: String
    let url: URL
    /// Scopes to ask for instead of every one the server lists.
    var scopes: [String]?
    /// Set for GitHub: its OAuth App signs in with the device flow, which needs
    /// no client secret. Everything else registers itself (DCR).
    var githubClientID: String?
    /// Set for Google: its authorization server has no registration, so
    /// Notchi signs in as the desktop client made for it in Google Cloud.
    var client: StaticClient?
    /// The tools `load_tools(app:)` adds, by the server's names; the rest load
    /// by name. Empty: all of them when there are ten or fewer.
    var defaultTools: [String]
    /// The group Settings lists it under.
    var category: Category

    enum Category: String, CaseIterable {
        case docs, mail, projects, developer
    }

    /// A client Notchi was issued ahead of time.
    struct StaticClient: Sendable {
        let id: String
        /// Kept out of the source: the build writes it into Info.plist from
        /// NOTCHI_GOOGLE_CLIENT_SECRET. Nil for a public client, which signs
        /// in with PKCE alone.
        let secretKey: String?
        /// Added to the sign-in address.
        let authParams: [String: String]
        /// The sign-in and token addresses, for a server that does not publish
        /// OAuth metadata. Nil: found from the server.
        var authorize: URL? = nil
        var token: URL? = nil

        var secret: String? {
            guard let secretKey else { return nil }
            let value = Bundle.main.object(forInfoDictionaryKey: secretKey) as? String
            return (value?.isEmpty == false && value?.hasPrefix("$(") == false) ? value : nil
        }
    }

    static let google = StaticClient(
        id: "1073923399222-5kkq0aduqeb6kgiasi3ber4vrbr9dnj1.apps.googleusercontent.com",
        secretKey: "NotchiGoogleClientSecret",
        authParams: ["access_type": "offline", "prompt": "consent"])

    /// The Notchi app registered in Microsoft Entra: a public client for
    /// personal and work accounts, redirect http://127.0.0.1/callback.
    static let microsoftClientID = ""

    static let microsoft = StaticClient(
        id: microsoftClientID,
        secretKey: nil,
        authParams: ["prompt": "select_account"],
        authorize: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
        token: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!)

    init(_ id: String, _ title: String, _ url: String, scopes: [String]? = nil,
         githubClientID: String? = nil, client: StaticClient? = nil, defaultTools: [String] = [],
         category: Category = .developer) {
        self.id = id
        self.title = title
        self.url = URL(string: url)!
        self.scopes = scopes
        self.githubClientID = githubClientID
        self.client = client
        self.defaultTools = defaultTools
        self.category = category
    }

    /// Off until Google verifies the app: unverified, it serves 100 test users
    /// and its refresh tokens last 7 days.
    static let googleEnabled = false

    static var all: [MCPConnector] {
        listed.filter { connector in
            switch connector.client?.id {
            case google.id?: return googleEnabled
            case microsoft.id?: return !microsoftClientID.isEmpty
            default: return true
            }
        }
    }

    private static let listed: [MCPConnector] = [
        MCPConnector("notion", "Notion", "https://mcp.notion.com/mcp",
                     defaultTools: ["notion-search", "notion-fetch", "notion-create-pages", "notion-update-page"], category: .docs),
        MCPConnector("linear", "Linear", "https://mcp.linear.app/mcp",
                     defaultTools: ["list_issues", "get_issue", "create_issue", "update_issue",
                                    "list_projects", "list_teams", "create_comment"], category: .projects),
        // Outlook has no MCP server for personal accounts; OutlookServer
        // answers in Notchi, over Microsoft Graph.
        MCPConnector("outlook", "Outlook", "https://graph.microsoft.com/v1.0",
                     scopes: ["offline_access", "User.Read", "Mail.ReadWrite"],
                     client: microsoft, category: .mail),
        MCPConnector("gmail", "Gmail", "https://gmailmcp.googleapis.com/mcp/v1",
                     scopes: ["https://www.googleapis.com/auth/gmail.modify"],
                     client: google, category: .mail),
        MCPConnector("googlecalendar", "Google Calendar", "https://calendarmcp.googleapis.com/mcp/v1",
                     scopes: ["https://www.googleapis.com/auth/calendar"],
                     client: google, category: .mail),
        MCPConnector("googledrive", "Google Drive", "https://drivemcp.googleapis.com/mcp/v1",
                     scopes: ["https://www.googleapis.com/auth/drive"],
                     client: google, category: .docs),
        MCPConnector("dropbox", "Dropbox", "https://mcp.dropbox.com/mcp", category: .docs),
        MCPConnector("granola", "Granola", "https://mcp.granola.ai/mcp", category: .docs),
        MCPConnector("miro", "Miro", "https://mcp.miro.com/", category: .projects),
        MCPConnector("vercel", "Vercel", "https://mcp.vercel.com"),
        MCPConnector("cloudflare", "Cloudflare", "https://mcp.cloudflare.com/mcp"),
        MCPConnector("supabase", "Supabase", "https://mcp.supabase.com/mcp",
                     defaultTools: ["list_projects", "list_tables", "execute_sql", "get_logs", "search_docs"]),
        MCPConnector("stripe", "Stripe", "https://mcp.stripe.com"),
        // Netlify lists a scope of its own for Claude; ask only for the general ones.
        MCPConnector("netlify", "Netlify", "https://netlify-mcp.netlify.app/mcp",
                     scopes: ["offline_access", "read", "write"]),
        MCPConnector("huggingface", "Hugging Face", "https://huggingface.co/mcp"),
        MCPConnector("github", "GitHub", "https://api.githubcopilot.com/mcp/",
                     scopes: ["repo", "read:org", "read:user", "user:email", "notifications", "gist", "read:project"],
                     githubClientID: "Ov23lixrOXQWEKxIYhBX",
                     defaultTools: ["get_me", "search_repositories", "get_file_contents", "search_code",
                                    "search_issues", "issue_read", "issue_write", "search_pull_requests",
                                    "pull_request_read", "list_issues"], category: .projects),
    ]

    static func find(_ id: String?) -> MCPConnector? {
        all.first { $0.id == id }
    }
}

/// What one OAuth sign-in left: the client Notchi registered for it and the
/// tokens it got.
struct MCPOAuthToken: Codable, Sendable {
    var clientID: String
    var clientSecret: String?
    var tokenEndpoint: URL
    var resource: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
}

/// Tokens in `UserDefaults`, one entry per connector, like `APIKeyStore`'s
/// keys: Notchi's self-signed certificate has no Team ID, so the keychain ties
/// an item to one build and asks for the login password after every update.
enum MCPTokenStore {
    private static let prefix = "mcp_oauth."

    static func load(_ id: String) -> MCPOAuthToken? {
        guard let data = UserDefaults.standard.data(forKey: prefix + id) else { return nil }
        return try? JSONDecoder().decode(MCPOAuthToken.self, from: data)
    }

    static func save(_ token: MCPOAuthToken, for id: String) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        UserDefaults.standard.set(data, forKey: prefix + id)
    }

    static func delete(_ id: String) {
        UserDefaults.standard.removeObject(forKey: prefix + id)
    }
}

/// Hands out a connector's access token, refreshing it when it is about to
/// expire or the server refused it. One refresh at a time per connector: a
/// refresh token is single-use, so two at once would void the sign-in.
actor MCPTokens {
    static let shared = MCPTokens()

    private var refreshing: [String: Task<MCPOAuthToken, Error>] = [:]

    func accessToken(_ id: String, forceRefresh: Bool) async throws -> String {
        let title = MCPConnector.find(id)?.title ?? id
        guard var token = MCPTokenStore.load(id) else {
            throw MCPError("\(title) is not connected. Connect it in Settings.")
        }
        let stale = token.expiresAt.map { $0.timeIntervalSinceNow < 60 } ?? false
        if forceRefresh || stale { token = try await refresh(id, title: title, token) }
        return token.accessToken
    }

    private func refresh(_ id: String, title: String, _ token: MCPOAuthToken) async throws -> MCPOAuthToken {
        if let running = refreshing[id] { return try await running.value }
        let task = Task<MCPOAuthToken, Error> {
            guard let refreshToken = token.refreshToken else {
                MCPTokenStore.delete(id)
                throw MCPError("The \(title) sign-in expired. Connect it again in Settings.")
            }
            var fields = ["grant_type": "refresh_token", "refresh_token": refreshToken,
                          "client_id": token.clientID]
            if !token.resource.isEmpty { fields["resource"] = token.resource }
            fields["client_secret"] = token.clientSecret
            let (status, body) = try await MCPOAuth.postForm(token.tokenEndpoint, fields)
            if (400..<500).contains(status) {
                MCPTokenStore.delete(id)
                throw MCPError("The \(title) sign-in expired. Connect it again in Settings.")
            }
            guard status == 200, let fresh = MCPOAuth.token(from: body, base: token) else {
                throw MCPError("Could not refresh the \(title) sign-in (HTTP \(status)).")
            }
            MCPTokenStore.save(fresh, for: id)
            return fresh
        }
        refreshing[id] = task
        defer { refreshing[id] = nil }
        return try await task.value
    }
}

/// The MCP authorization flow (OAuth 2.1): find the server's authorization
/// server, register Notchi with it (dynamic client registration), send the
/// user to sign in with PKCE, and catch the code on a loopback port.
enum MCPOAuth {
    struct Server {
        let authorize: URL
        let token: URL
        let register: URL?
        let resource: String
        let scopes: [String]
    }

    static func discover(_ url: URL) async throws -> Server {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let path = comps.path == "/" ? "" : comps.path
        comps.query = nil
        comps.path = "/.well-known/oauth-protected-resource" + path
        var resource = try? await getJSON(comps.url!)
        if resource == nil {
            comps.path = "/.well-known/oauth-protected-resource"
            resource = try? await getJSON(comps.url!)
        }
        comps.path = ""
        let origin = comps.url!
        let issuer = (resource?["authorization_servers"] as? [String])?.first.flatMap(URL.init(string:)) ?? origin

        var meta: [String: Any]?
        var issuerComps = URLComponents(url: issuer, resolvingAgainstBaseURL: false)!
        let issuerPath = issuerComps.path == "/" ? "" : issuerComps.path
        for wellKnown in ["/.well-known/oauth-authorization-server", "/.well-known/openid-configuration"] {
            issuerComps.path = wellKnown + issuerPath
            if let found = try? await getJSON(issuerComps.url!) { meta = found; break }
        }
        guard let meta,
              let authorize = (meta["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let token = (meta["token_endpoint"] as? String).flatMap(URL.init(string:)) else {
            throw MCPError("The server does not describe how to sign in.")
        }
        let register = (meta["registration_endpoint"] as? String).flatMap(URL.init(string:))
        return Server(authorize: authorize, token: token, register: register,
                      resource: (resource?["resource"] as? String) ?? url.absoluteString,
                      scopes: (resource?["scopes_supported"] as? [String]) ?? [])
    }

    /// Registers Notchi as a public client for this one redirect address.
    static func register(_ server: Server, redirect: String) async throws -> (id: String, secret: String?) {
        guard let endpoint = server.register else {
            throw MCPError("The server does not let Notchi register itself.")
        }
        var req = URLRequest(url: endpoint, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "Notchi",
            "client_uri": "https://notch.website",
            "logo_uri": "https://notch.website/icon-light.png",
            "redirect_uris": [redirect],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        let (data, response) = try await ProxyConfig.urlSession.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = body["client_id"] as? String else {
            throw MCPError("Registering Notchi with the server failed (HTTP \(status)).")
        }
        return (id, body["client_secret"] as? String)
    }

    static func token(from body: Data, base: MCPOAuthToken) -> MCPOAuthToken? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let access = json["access_token"] as? String else { return nil }
        var out = base
        out.accessToken = access
        if let refresh = json["refresh_token"] as? String { out.refreshToken = refresh }
        let expires = (json["expires_in"] as? NSNumber)?.doubleValue
        out.expiresAt = expires.map { Date().addingTimeInterval($0) }
        return out
    }

    static func postForm(_ url: URL, _ fields: [String: String]) async throws -> (Int, Data) {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Data(fields.map { "\(encode($0.key))=\(encode($0.value))" }
            .joined(separator: "&").utf8)
        let (data, response) = try await ProxyConfig.urlSession.data(for: req)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private static func getJSON(_ url: URL) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await ProxyConfig.urlSession.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError("Not found.")
        }
        return json
    }

    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func randomString() -> String {
        base64url(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    static func challenge(_ verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Settings' Connect / Disconnect for each connector.
@MainActor
final class MCPConnectorAuth: ObservableObject {
    static let shared = MCPConnectorAuth()

    enum Phase: Equatable {
        case idle
        case waiting
        /// GitHub's device flow: the code the user enters on github.com.
        case code(String)
        case failed(String)
    }

    @Published private(set) var phases: [String: Phase] = [:]
    @Published private(set) var connected: Set<String>

    private struct Pending {
        let connector: MCPConnector
        let server: MCPOAuth.Server
        let clientID: String
        let clientSecret: String?
        let redirect: String
        let verifier: String
        let state: String
    }

    private var listener: NWListener?
    private var pending: Pending?
    private var current: String?
    private var timeoutTask: Task<Void, Never>?
    private static let timeout: TimeInterval = 300

    private init() {
        connected = Set(MCPConnector.all.map(\.id).filter { MCPTokenStore.load($0) != nil })
    }

    func phase(_ id: String) -> Phase { phases[id] ?? .idle }

    func isWaiting(_ id: String) -> Bool {
        switch phase(id) {
        case .waiting, .code: return true
        default: return false
        }
    }

    func connect(_ connector: MCPConnector) {
        cancel()
        current = connector.id
        phases[connector.id] = .waiting
        Task {
            do {
                if let clientID = connector.githubClientID {
                    try await beginDevice(connector, clientID: clientID)
                } else {
                    try await begin(connector)
                }
            } catch {
                guard current == connector.id else { return }
                fail(error.localizedDescription)
            }
        }
    }

    func cancel() {
        teardown()
        if let id = current, isWaiting(id) { phases[id] = .idle }
        current = nil
        pending = nil
    }

    func disconnect(_ connector: MCPConnector) {
        MCPTokenStore.delete(connector.id)
        connected.remove(connector.id)
        phases[connector.id] = .idle
        MCPHub.shared.reload()
    }

    private func begin(_ connector: MCPConnector) async throws {
        let port = try await listen()
        let redirect = "http://127.0.0.1:\(port)/callback"
        var server: MCPOAuth.Server
        if let issued = connector.client, let authorize = issued.authorize, let token = issued.token {
            server = MCPOAuth.Server(authorize: authorize, token: token, register: nil,
                                     resource: "", scopes: [])
        } else {
            server = try await MCPOAuth.discover(connector.url)
        }
        let client: (id: String, secret: String?)
        if let issued = connector.client {
            if issued.secretKey != nil, issued.secret == nil {
                throw MCPError("This build of Notchi has no \(connector.title) client secret.")
            }
            client = (issued.id, issued.secret)
            // Google and Microsoft take no resource parameter; the scopes name the API.
            server = MCPOAuth.Server(authorize: server.authorize, token: server.token,
                                     register: nil, resource: "", scopes: server.scopes)
        } else {
            client = try await MCPOAuth.register(server, redirect: redirect)
        }
        guard current == connector.id else { return }
        let verifier = MCPOAuth.randomString()
        let state = MCPOAuth.randomString()
        pending = Pending(connector: connector, server: server, clientID: client.id,
                          clientSecret: client.secret, redirect: redirect,
                          verifier: verifier, state: state)
        var comps = URLComponents(url: server.authorize, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "code_challenge", value: MCPOAuth.challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        if !server.resource.isEmpty {
            items.append(URLQueryItem(name: "resource", value: server.resource))
        }
        for (name, value) in (connector.client?.authParams ?? [:]).sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: name, value: value))
        }
        let scopes = connector.scopes ?? server.scopes
        if !scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " ")))
        }
        comps.queryItems = (comps.queryItems ?? []) + items
        guard let url = comps.url else { throw MCPError("Could not build the sign-in address.") }
        NSWorkspace.shared.open(url)
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
            guard let self, !Task.isCancelled, self.current == connector.id else { return }
            self.cancel()
        }
    }

    /// GitHub's device flow: get a code, copy it, open github.com/login/device,
    /// then poll until the user approves. No client secret is involved.
    private func beginDevice(_ connector: MCPConnector, clientID: String) async throws {
        let scope = (connector.scopes ?? []).joined(separator: " ")
        let (status, data) = try await MCPOAuth.postForm(
            URL(string: "https://github.com/login/device/code")!,
            ["client_id": clientID, "scope": scope])
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let verify = (json["verification_uri"] as? String).flatMap(URL.init(string:)) else {
            let reason = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error_description"] as? String
            throw MCPError(reason ?? "GitHub did not start the sign-in (HTTP \(status)).")
        }
        guard current == connector.id else { return }
        var interval = max(5, (json["interval"] as? NSNumber)?.doubleValue ?? 5)
        let deadline = Date().addingTimeInterval((json["expires_in"] as? NSNumber)?.doubleValue ?? 900)
        phases[connector.id] = .code(userCode)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(userCode, forType: .string)
        NSWorkspace.shared.open(verify)

        let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard current == connector.id else { return }
            let (_, body) = try await MCPOAuth.postForm(tokenURL, [
                "client_id": clientID, "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
            let reply = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            switch reply["error"] as? String {
            case "authorization_pending"?:
                continue
            case "slow_down"?:
                interval += 5
                continue
            case "access_denied"?:
                throw MCPError("The sign-in was cancelled.")
            case let error?:
                throw MCPError((reply["error_description"] as? String) ?? error)
            case nil:
                let base = MCPOAuthToken(clientID: clientID, clientSecret: nil, tokenEndpoint: tokenURL,
                                         resource: connector.url.absoluteString, accessToken: "",
                                         refreshToken: nil, expiresAt: nil)
                guard let token = MCPOAuth.token(from: body, base: base) else {
                    throw MCPError("GitHub sent no token.")
                }
                guard current == connector.id else { return }
                MCPTokenStore.save(token, for: connector.id)
                connected.insert(connector.id)
                phases[connector.id] = .idle
                current = nil
                MCPHub.shared.reload()
                return
            }
        }
        throw MCPError("The code expired. Connect again.")
    }

    /// A loopback-only listener; returns its port once it is ready.
    private func listen() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            Task { @MainActor in self?.read(conn, accumulated: Data()) }
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    if let port = listener.port?.rawValue {
                        cont.resume(returning: port)
                    } else {
                        cont.resume(throwing: MCPError("Could not open a local port for the sign-in."))
                    }
                case .failed, .cancelled:
                    resumed = true
                    cont.resume(throwing: MCPError("Could not open a local port for the sign-in."))
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
    }

    private func read(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { conn.cancel(); return }
                var buf = accumulated
                if let data { buf.append(data) }
                if let head = String(data: buf, encoding: .utf8), head.contains("\r\n\r\n") {
                    self.route(conn, head: head)
                } else if error != nil || complete || buf.count > 16384 {
                    conn.cancel()
                } else {
                    self.read(conn, accumulated: buf)
                }
            }
        }
    }

    private func route(_ conn: NWConnection, head: String) {
        let parts = head.components(separatedBy: " ")
        guard parts.count >= 2, let target = URLComponents(string: parts[1]),
              target.path == "/callback", let pending else {
            respond(conn, status: "404 Not Found", body: "")
            return
        }
        let query = { (name: String) in target.queryItems?.first { $0.name == name }?.value }
        guard query("state") == pending.state else {
            respond(conn, status: "400 Bad Request", body: "")
            return
        }
        let title = pending.connector.title
        guard let code = query("code"), !code.isEmpty else {
            respond(conn, status: "200 OK", body: Self.page("\(title) was not connected. You can close this tab."))
            fail("The sign-in was cancelled.")
            return
        }
        respond(conn, status: "200 OK", body: Self.page("\(title) is connected. You can close this tab and go back to Notchi."))
        teardown()
        Task { await exchange(code, pending) }
    }

    private func exchange(_ code: String, _ pending: Pending) async {
        var fields = ["grant_type": "authorization_code", "code": code,
                      "redirect_uri": pending.redirect, "client_id": pending.clientID,
                      "code_verifier": pending.verifier]
        if !pending.server.resource.isEmpty { fields["resource"] = pending.server.resource }
        fields["client_secret"] = pending.clientSecret
        let base = MCPOAuthToken(clientID: pending.clientID, clientSecret: pending.clientSecret,
                                 tokenEndpoint: pending.server.token, resource: pending.server.resource,
                                 accessToken: "", refreshToken: nil, expiresAt: nil)
        do {
            let (status, body) = try await MCPOAuth.postForm(pending.server.token, fields)
            guard status == 200, let token = MCPOAuth.token(from: body, base: base) else {
                fail("\(pending.connector.title) did not accept the sign-in (HTTP \(status)).")
                return
            }
            let id = pending.connector.id
            MCPTokenStore.save(token, for: id)
            connected.insert(id)
            phases[id] = .idle
            current = nil
            self.pending = nil
            MCPHub.shared.reload()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        teardown()
        if let id = current { phases[id] = .failed(message) }
        current = nil
        pending = nil
    }

    private func teardown() {
        listener?.cancel()
        listener = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func respond(_ conn: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func page(_ text: String) -> String {
        """
        <!doctype html><meta charset="utf-8"><title>Notchi</title>
        <body style="font:15px -apple-system,sans-serif;display:flex;height:90vh;align-items:center;justify-content:center;color:#333">
        <p>\(text)</p></body>
        """
    }
}
