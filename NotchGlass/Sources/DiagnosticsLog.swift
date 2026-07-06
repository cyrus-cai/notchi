import Foundation

/// A tiny, local-only diagnostics ring for *failures* — so when an Ask falls over
/// there's a breadcrumb to look at, without ever phoning home (XII-85).
///
/// **It records metadata only — never payload.** No prompt text, no clipboard
/// contents, no answer, no API key. Just: when, which provider, the HTTP status
/// (when known), and a short error category string. That keeps the app's "no
/// telemetry / no account / private by default" promise intact: nothing here
/// could reconstruct what the user asked or what they had copied, and nothing
/// leaves the machine — entries live in memory and (optionally) a small local
/// file the user could read or delete themselves.
///
/// Use it from the failure paths (the `submit` catch, the service layer) via
/// `DiagnosticsLog.shared.record(...)`. The most recent entries are kept; old
/// ones roll off so the log can't grow without bound.
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()

    /// One failure breadcrumb. Deliberately holds nothing that could identify the
    /// content of a request — only the shape of the failure.
    struct Entry: Codable {
        let at: Date
        /// Provider display name (e.g. "Anthropic", "OpenRouter") — not the key.
        let provider: String
        /// HTTP status when the failure was an HTTP error, else nil (e.g. a timeout
        /// or offline drop that never reached a response).
        let status: Int?
        /// A short, payload-free category, e.g. "http", "timeout", "offline",
        /// "malformed", "cancelled", "unknown". No free-form server body, no message
        /// that could echo user content.
        let kind: String
    }

    private let maxEntries = 50
    private let queue = DispatchQueue(label: "com.notchglass.diagnostics")
    private var entries: [Entry] = []

    /// Where the optional on-disk copy lives — under Application Support, the user's
    /// own account-private area. Nil if the directory can't be resolved.
    private let fileURL: URL? = {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first
        else { return nil }
        let appDir = dir.appendingPathComponent("Notchi", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("diagnostics.json")
    }()

    private init() {
        load()
    }

    /// Record a failure breadcrumb. Categorize from a raw `Error` so callers don't
    /// have to — but they can pass an explicit `status`/`kind` when they know more
    /// (e.g. the service layer already parsed the HTTP code).
    func record(provider: String, status: Int? = nil, kind: String? = nil, error: Error? = nil) {
        let resolvedKind = kind ?? DiagnosticsLog.categorize(error)
        let entry = Entry(at: Date(), provider: provider, status: status, kind: resolvedKind)
        queue.async { [weak self] in
            guard let self else { return }
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
            self.persist()
        }
    }

    /// The recent breadcrumbs, newest last. Snapshotted so callers never touch the
    /// mutable store off-queue.
    var recent: [Entry] {
        queue.sync { entries }
    }

    /// Wipe the log (memory + disk). For a future "clear diagnostics" affordance.
    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            self.entries.removeAll()
            if let url = self.fileURL { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: - Categorization

    /// Map a raw error to a short, payload-free category. URLError cases become
    /// network categories; everything else is "unknown". Crucially this reads only
    /// the error's *type/code*, never any attached message that might carry content.
    private static func categorize(_ error: Error?) -> String {
        guard let error else { return "unknown" }
        if error is CancellationError { return "cancelled" }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:                 return "timeout"
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .cannotConnectToHost,
                 .cannotFindHost:           return "offline"
            default:                        return "network"
            }
        }
        return "unknown"
    }

    // MARK: - Persistence (best-effort, runs on `queue`)

    private func persist() {
        guard let url = fileURL else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func load() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let restored = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = Array(restored.suffix(maxEntries))
    }
}
