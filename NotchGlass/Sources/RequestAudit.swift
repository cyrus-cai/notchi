import Foundation

/// Settings → **Audit**: one line per model request the app sent, newest first.
///
/// Local-only. A record says which part of the app sent the request, which
/// provider, model and endpoint were asked, what came back (an HTTP status, or
/// the CLI process's outcome), how long it took, how long the first token took,
/// and the token counts the provider itself reported. Beside it, in a file of
/// its own, is what was sent: the HTTP method, URL, headers and body, or the CLI
/// command line and its stdin. Keys are left out of that copy — credential
/// headers and query items are dropped — and inline image data is replaced by
/// its type and size. It never holds an answer or a response body.
///
/// Stored as JSON under Application Support/Notchi — the same folder
/// `DiagnosticsLog` uses — and capped at `maxEntries` so it can't grow without
/// bound. Nothing here is ever sent anywhere.
final class RequestAudit: @unchecked Sendable {
    static let shared = RequestAudit()

    /// Posted on the main queue after a request is recorded, so an open
    /// Settings → Audit pane redraws without polling.
    static let didChange = Notification.Name("notch.requestAudit.didChange")

    /// One finished request.
    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        /// When the request started.
        let at: Date
        let provider: String
        let model: String
        /// Endpoint host for an HTTP request, the binary name for a CLI one.
        let host: String
        let transport: Transport
        let outcome: Outcome
        /// The HTTP status when the request reached a response, else nil (a
        /// timeout never does; neither does a CLI run).
        let status: Int?
        /// Short failure category, in `DiagnosticsLog`'s vocabulary — "timeout",
        /// "offline", "cutOff", "cli", … Nil on success.
        let kind: String?
        let milliseconds: Int
        /// Send → first streamed token. `nil` when nothing streamed at all.
        let firstToken: Int?
        let inputTokens: Int
        let outputTokens: Int
        /// How many times the request went out. Above 1 when a transient
        /// failure was retried behind the scenes.
        let attempts: Int
        /// Which part of the app sent it: `NoNoRequestContext`'s surface ("ask",
        /// "shortcut", "title", "memory", …), or the Jev route. Nil on records
        /// from before it was kept, and on a request sent outside any surface.
        var surface: String? = nil
        /// The full URL without credential query items, for an HTTP request.
        var url: String? = nil
        /// The failure's own words, when there are any — a provider's error
        /// message, cut to 300 characters.
        var error: String? = nil
        /// Whether a copy of what was sent is on disk (`RequestAudit.payload(for:)`).
        var hasPayload: Bool? = nil
        /// A tool call's own argument, on one line: the search query, the page,
        /// the command, the file. Kept on the record itself, not only in the
        /// payload file, so the card can say what the call did without a read.
        var call: String? = nil
        /// That argument's name as the tool spelled it ("query", "url", "command"),
        /// so the card can label the value the way the call did.
        var callName: String? = nil
        /// Whether the request went to Notchi's gateway, decided when it was
        /// recorded from the host it was actually sent to (`sentHost`), not
        /// from the provider or transport label. Nil on records from before it
        /// was kept; `servedByNotchi` falls back to the stored host for those.
        var viaNotchi: Bool? = nil

        var tokens: Int { inputTokens + outputTokens }

        /// Whether Notchi served this request. Tool runs never leave the app.
        var servedByNotchi: Bool {
            guard transport != .tool else { return false }
            return viaNotchi ?? (host == RequestAudit.notchiHost)
        }
    }

    /// How the request left the app: an HTTP call, a local agent CLI run — or a
    /// tool the turn ran. Tools share the record shape so the flow chart can draw
    /// them on the same clock; they are never sent anywhere, so they carry no
    /// endpoint or token counts.
    enum Transport: String, Codable { case http, cli, tool, jev }

    enum Outcome: String, Codable { case ok, failed, cancelled }

    /// The ticket of the request a wrapper is running, for code below it that
    /// builds the actual `URLRequest` (Jev's shared `send`).
    @TaskLocal static var current: Ticket?

    /// A finer name for the call site than the gateway surface, for this log
    /// only. The surface also decides billing, so a request that bills as
    /// "memory" but is a reply to a copy is labeled here instead of there.
    @TaskLocal static var purpose: String?

    /// One request in flight. Every method is callable from any queue; `finish`
    /// is idempotent, so a cancellation racing a completion still logs once.
    final class Ticket: @unchecked Sendable {
        let id = UUID()
        private let provider: String
        private let model: String
        private let host: String
        private let transport: Transport
        private let surface: String?
        private let started = Date()

        private let lock = NSLock()
        private var firstTokenAt: Int?
        private var status: Int?
        private var input = 0
        private var output = 0
        private var attempts = 0
        private var finished = false
        private var url: String?
        /// The HTTP request as sent. Its body is parsed into the kept copy only
        /// when the record is written, off the request's own path.
        private var sentRequest: URLRequest?
        private var payload: [String: Any]?
        private var call: (name: String, value: String)?

        init(provider: String, model: String, host: String, transport: Transport,
             surface: String? = RequestAudit.purpose ?? NoNoRequestContext.current?.surface) {
            self.provider = provider
            self.model = model
            self.host = host
            self.transport = transport
            self.surface = surface
        }

        /// Keep a copy of the HTTP request about to go out. A retry calls this
        /// again with the same request; the last copy wins.
        func request(_ request: URLRequest) {
            let url = request.url.flatMap(RequestAudit.publicURL)
            lock.lock(); self.url = url; sentRequest = request; lock.unlock()
        }

        /// Keep a copy of a CLI run: the binary, its arguments, its stdin, and
        /// any file written for it to read (path → contents).
        func command(_ binary: String, _ arguments: [String], stdin: String?,
                     files: [String: String] = [:]) {
            var payload: [String: Any] = ["command": binary, "arguments": arguments]
            if let stdin { payload["stdin"] = stdin }
            if !files.isEmpty { payload["files"] = files }
            lock.lock(); self.payload = payload; lock.unlock()
        }

        /// Keep a copy of a tool call's arguments.
        func input(_ input: [String: Any]) {
            let payload: [String: Any] = ["tool": model,
                                          "input": RequestAudit.scrub(input)]
            let call = RequestAudit.callSummary(in: input)
            lock.lock(); self.payload = payload; self.call = call; lock.unlock()
        }

        /// One request going out on the wire. A retry calls this again.
        func attempt() {
            lock.lock(); attempts += 1; lock.unlock()
        }

        func status(_ code: Int) {
            lock.lock(); status = code; lock.unlock()
        }

        func tokens(input: Int, output: Int) {
            let i = max(0, input), o = max(0, output)
            guard i > 0 || o > 0 else { return }
            lock.lock(); self.input += i; self.output += o; lock.unlock()
        }

        /// Mark the first streamed token. Safe to call on every chunk.
        func firstToken() {
            lock.lock()
            if firstTokenAt == nil {
                firstTokenAt = Int(Date().timeIntervalSince(started) * 1000)
            }
            lock.unlock()
        }

        /// Close the ticket and file the record. Only the first call has an
        /// effect.
        func finish(_ outcome: Outcome,
                    error: Error? = nil,
                    status explicitStatus: Int? = nil,
                    kind explicitKind: String? = nil) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let code = explicitStatus ?? status
            let (inTokens, outTokens, tries) = (input, output, attempts)
            let ttft = firstTokenAt
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            let (sentURL, sentRequest, sent) = (url, self.sentRequest, payload)
            let sentCall = call
            lock.unlock()

            let kind: String?
            switch outcome {
            case .ok, .cancelled: kind = nil
            case .failed:         kind = explicitKind ?? (code != nil ? "http"
                                                              : DiagnosticsLog.categorize(error))
            }

            RequestAudit.shared.append(Entry(id: id,
                                             at: started,
                                             provider: provider,
                                             model: model,
                                             host: host,
                                             transport: transport,
                                             outcome: outcome,
                                             status: code,
                                             kind: kind,
                                             milliseconds: elapsed,
                                             firstToken: ttft,
                                             inputTokens: inTokens,
                                             outputTokens: outTokens,
                                             attempts: max(1, tries),
                                             surface: surface,
                                             url: sentURL,
                                             error: outcome == .failed
                                                 ? RequestAudit.message(for: error) : nil,
                                             hasPayload: sent != nil || sentRequest != nil,
                                             call: sentCall?.value,
                                             callName: sentCall?.name,
                                             viaNotchi: transport == .tool ? false
                                                 : (sentRequest?.url?.host ?? host) == RequestAudit.notchiHost),
                                       request: sentRequest,
                                       payload: sent)
        }
    }

    /// The host of Notchi's gateway, local override included. A request counts
    /// as Notchi's only when it was sent there.
    static var notchiHost: String? { URL(string: Provider.nonoEndpoint)?.host }

    /// What the log keeps: the most recent 1,000 records, and nothing older than
    /// 90 days. A count alone makes "how long does history last" depend on how
    /// busy the week was; an age alone lets a runaway loop grow an unbounded
    /// file. The pair bounds both the file and how far back the chart can page.
    private let maxEntries = 1000
    private let maxAge: TimeInterval = 90 * 24 * 60 * 60
    private let lock = NSLock()
    private var entries: [Entry] = []
    private let writes = DispatchQueue(label: "com.notchglass.request-audit")

    /// Same directory, same best-effort write as `DiagnosticsLog`.
    let fileURL: URL? = {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first
        else { return nil }
        let appDir = dir.appendingPathComponent("Notchi", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("requests.json")
    }()

    /// One file per record holding what was sent, named by the record's id.
    /// Kept apart from `requests.json` so the list stays small to rewrite.
    let payloadDirectory: URL? = {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first
        else { return nil }
        let payloads = dir.appendingPathComponent("Notchi/requests", isDirectory: true)
        try? FileManager.default.createDirectory(at: payloads, withIntermediateDirectories: true)
        return payloads
    }()

    private init() {
        load()
    }

    // MARK: - Recording

    func begin(provider: String, model: String, host: String,
               transport: Transport) -> Ticket {
        Ticket(provider: provider, model: model, host: host, transport: transport)
    }

    /// One tool run inside a turn. `model` holds the tool's name, which is what
    /// the chart's tool lane labels it with.
    func beginTool(_ name: String) -> Ticket {
        Ticket(provider: "Tool", model: name, host: "", transport: .tool)
    }

    /// One Jev call — the app's own gateway-side classifier (`/sense`, `/react`,
    /// `/linkcheck`, `/followup`). `model` holds the surface's route name. These
    /// are model calls in the chart's sense, so they ride its model lane.
    func beginJev(surface: String, host: String) -> Ticket {
        Ticket(provider: "Jev", model: surface, host: host, transport: .jev, surface: surface)
    }

    fileprivate func append(_ entry: Entry, request: URLRequest?, payload: [String: Any]?) {
        lock.lock()
        let before = Set(entries.map(\.id))
        entries.append(entry)
        prune(&entries, now: entry.at)
        let snapshot = entries
        let dropped = before.subtracting(snapshot.map(\.id))
        lock.unlock()

        writes.async { [fileURL, payloadDirectory] in
            if let dir = payloadDirectory {
                // Parsed and pretty-printed here, on the write queue: a chat body
                // is the whole conversation, and the request that sent it, or
                // the main thread finishing it, shouldn't pay for the copy.
                let kept = request.map(RequestAudit.describe) ?? payload
                if let kept, let payloadData = try? JSONSerialization.data(
                    withJSONObject: kept,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                    try? payloadData.write(to: dir.appendingPathComponent("\(entry.id.uuidString).json"),
                                           options: .atomic)
                }
                for id in dropped {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id.uuidString).json"))
                }
            }
            guard let url = fileURL,
                  let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: RequestAudit.didChange, object: nil)
        }
    }

    /// Oldest first, newest last.
    var recent: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    /// What was sent for one record, pretty-printed JSON. Nil when no copy was
    /// kept (an older record) or it has been pruned.
    func payload(for id: UUID) -> String? {
        guard let dir = payloadDirectory,
              let data = try? Data(contentsOf: dir.appendingPathComponent("\(id.uuidString).json"))
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        writes.async { [fileURL, payloadDirectory] in
            if let dir = payloadDirectory { try? FileManager.default.removeItem(at: dir) }
            guard let url = fileURL else { return }
            try? FileManager.default.removeItem(at: url)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: RequestAudit.didChange, object: nil)
        }
    }

    // MARK: - What was sent

    /// Header and query names that carry a credential. Matched as substrings,
    /// lowercased, so `x-api-key`, `x-goog-api-key` and `Authorization` all go.
    private static let secretNames = ["authorization", "api-key", "apikey", "api_key",
                                      "token", "cookie", "secret", "password"]

    private static func isSecret(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "key" || secretNames.contains { lower.contains($0) }
    }

    /// The one argument that says what a tool call did, named the way the tool
    /// named it. Ordered by how much it tells the reader: a search's query, a
    /// page, a command, a file, a pattern. A tool that spelled its argument
    /// something else falls back to its only string argument, and a call whose
    /// shape can't be put in one line is left without one.
    private static let callArguments = ["query", "command", "url", "file_path", "path",
                                        "pattern", "prompt", "text", "name"]

    fileprivate static func callSummary(in input: [String: Any]) -> (name: String, value: String)? {
        func line(_ raw: String) -> String? {
            let text = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return text.count > 240 ? String(text.prefix(240)) + "…" : text
        }
        for name in callArguments {
            if let raw = input[name] as? String, let value = line(raw) {
                return (name, value)
            }
        }
        let strings = input.values.compactMap { ($0 as? String).flatMap(line) }
        guard strings.count == 1,
              let name = input.first(where: { ($0.value as? String).flatMap(line) != nil })?.key
        else { return nil }
        return (name, strings[0])
    }

    /// The request's URL without credential query items, and (`describe`) the copy to keep:
    /// method, URL, the non-credential headers, and the body — parsed when it
    /// is JSON, so the copy reads as the structure it was, else as text.
    fileprivate static func publicURL(_ raw: URL) -> String? {
        guard var parts = URLComponents(url: raw, resolvingAgainstBaseURL: false) else { return nil }
        parts.queryItems = parts.queryItems?.filter { !isSecret($0.name) }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        return parts.string
    }

    fileprivate static func describe(_ request: URLRequest) -> [String: Any] {
        let url = request.url.flatMap(publicURL)
        var payload: [String: Any] = ["method": request.httpMethod ?? "GET"]
        if let url { payload["url"] = url }
        let headers = (request.allHTTPHeaderFields ?? [:]).filter { !isSecret($0.key) }
        if !headers.isEmpty { payload["headers"] = headers }
        if let body = request.httpBody, !body.isEmpty {
            if let json = try? JSONSerialization.jsonObject(with: body) {
                payload["body"] = scrub(json)
            } else {
                payload["body"] = String(data: body, encoding: .utf8) ?? "<\(body.count) bytes>"
            }
        }
        return payload
    }

    /// Replace inline image data with a short note of what it was. A data URL
    /// keeps its media type; a bare base64 string over 4 KB (Anthropic's and
    /// Gemini's image blocks) keeps only its size. Everything else is kept as is.
    fileprivate static func scrub(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues { scrub($0) }
        case let list as [Any]:
            return list.map { scrub($0) }
        case let text as String:
            if text.hasPrefix("data:"), let comma = text.firstIndex(of: ","),
               text[..<comma].hasSuffix(";base64") {
                let type = text.dropFirst(5).prefix { $0 != ";" }
                return "<\(type), \(text.count - text.distance(from: text.startIndex, to: comma)) base64 characters>"
            }
            if text.count > 4096, !text.contains(" "), !text.contains("\n"),
               text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }) {
                return "<\(text.count) base64 characters>"
            }
            return text
        default:
            return value
        }
    }

    /// A failure's own words, when it has any: a provider's error message, or
    /// the error's description. Cut to 300 characters.
    fileprivate static func message(for error: Error?) -> String? {
        guard let error, !(error is CancellationError) else { return nil }
        var text: String
        if case let .http(_, _, body, _) = error as? OpenAICompatAIService.ServiceError,
           let detail = OpenAICompatAIService.ServiceError.detail(from: body) {
            text = detail
        } else {
            text = error.localizedDescription
        }
        text = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }

    // MARK: - Persistence

    private func load() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let restored = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        var kept = Array(restored.suffix(maxEntries))
        prune(&kept, now: Date())
        entries = kept
    }

    /// Drop the tail past the count cap and anything past the age cap. Oldest
    /// first, so both cuts are from the front.
    private func prune(_ list: inout [Entry], now: Date) {
        if list.count > maxEntries { list.removeFirst(list.count - maxEntries) }
        let cutoff = now.addingTimeInterval(-maxAge)
        if let firstKept = list.firstIndex(where: { $0.at >= cutoff }) {
            if firstKept > 0 { list.removeFirst(firstKept) }
        } else {
            list.removeAll()
        }
    }
}
