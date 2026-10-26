import Foundation

/// Settings → **Audit**: one line per model request the app sent, newest first.
///
/// Local-only and metadata-only. A record says which provider, model and endpoint
/// were asked, what came back (an HTTP status, or the CLI process's outcome), how
/// long it took, how long the first token took, and the token counts the provider
/// itself reported. It never holds a prompt, an answer, a response body or a key.
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

        var tokens: Int { inputTokens + outputTokens }
    }

    /// How the request left the app: an HTTP call, a local agent CLI run — or a
    /// tool the turn ran. Tools share the record shape so the flow chart can draw
    /// them on the same clock; they are never sent anywhere, so they carry no
    /// endpoint or token counts.
    enum Transport: String, Codable { case http, cli, tool, jev }

    enum Outcome: String, Codable { case ok, failed, cancelled }

    /// One request in flight. Every method is callable from any queue; `finish`
    /// is idempotent, so a cancellation racing a completion still logs once.
    final class Ticket: @unchecked Sendable {
        let id = UUID()
        private let provider: String
        private let model: String
        private let host: String
        private let transport: Transport
        private let started = Date()

        private let lock = NSLock()
        private var firstTokenAt: Int?
        private var status: Int?
        private var input = 0
        private var output = 0
        private var attempts = 0
        private var finished = false

        init(provider: String, model: String, host: String, transport: Transport) {
            self.provider = provider
            self.model = model
            self.host = host
            self.transport = transport
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
                                             attempts: max(1, tries)))
        }
    }

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
        Ticket(provider: "Jev", model: surface, host: host, transport: .jev)
    }

    fileprivate func append(_ entry: Entry) {
        lock.lock()
        entries.append(entry)
        prune(&entries, now: entry.at)
        let snapshot = entries
        lock.unlock()

        writes.async { [fileURL] in
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

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        writes.async { [fileURL] in
            guard let url = fileURL else { return }
            try? FileManager.default.removeItem(at: url)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: RequestAudit.didChange, object: nil)
        }
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
