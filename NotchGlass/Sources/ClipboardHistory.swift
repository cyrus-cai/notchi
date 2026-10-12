import AppKit
import Foundation

/// The last texts the user copied, kept on this Mac so Ask can find one again
/// ("the link I copied a minute ago", "the error I copied this morning").
/// Recorded by the resting clipboard watcher (`NotchModel.senseTick`) with the
/// same exclusions Copy Sense uses: nothing a password manager marks concealed
/// or transient, nothing that looks like a credential, nothing Notchi wrote.
/// Settings → Shortcuts turns it off and clears it.
@MainActor
final class ClipboardHistory: ObservableObject {
    static let shared = ClipboardHistory()

    /// Off until the feature is tested: nothing is recorded, the setting is
    /// hidden and Ask gets no `clipboard_history` tool.
    static let available = false

    struct Entry: Codable, Equatable {
        var text: String
        var copiedAt: Date
        var app: String?
    }

    @Published private(set) var entries: [Entry] = []
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: ClipboardHistory.enabledKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if !enabled { clear() }
        }
    }
    private static let enabledKey = "clipboardHistory.enabled"

    static let entryLimit = 50
    static let textLimit = 5000

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchi", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("clipboard-history.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    /// Newest first. A text copied again moves to the top instead of repeating.
    func add(_ text: String, app: String?) {
        guard enabled else { return }
        entries.removeAll { $0.text == text }
        entries.insert(Entry(text: String(text.prefix(Self.textLimit)), copiedAt: Date(), app: app), at: 0)
        if entries.count > Self.entryLimit { entries.removeLast(entries.count - Self.entryLimit) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// `clipboard_history`: search what the user copied recently.
struct ClipboardHistoryTool: NotchTool {
    static let toolName = "clipboard_history"
    let name = toolName
    let description = """
    Lists text the user copied recently on this Mac (up to the last 50 copies), \
    newest first, with when and from which app. Call when they refer to \
    something they copied earlier — "the link I copied", "那段我刚复制的报错" — \
    and it is not the current clipboard (read_clipboard reads that).
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "Only copies containing this text."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 50,
                      "description": "How many, 1 to 50. Default 10."],
        ],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        let query = (input["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let limit = min(max((input["limit"] as? NSNumber)?.intValue ?? 10, 1), 50)
        let (enabled, entries) = await MainActor.run {
            (ClipboardHistory.shared.enabled, ClipboardHistory.shared.entries)
        }
        guard enabled else { return "Clipboard history is off in Settings → Shortcuts." }
        let found = query.isEmpty ? entries
            : entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
        guard !found.isEmpty else {
            return query.isEmpty ? "Nothing copied yet." : "No recent copy contains \"\(query)\"."
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return found.prefix(limit).map { entry in
            let body = entry.text.count > 1500 ? String(entry.text.prefix(1500)) + "…" : entry.text
            let from = entry.app.map { " from \($0)" } ?? ""
            return "## \(fmt.string(from: entry.copiedAt))\(from)\n\(body)"
        }.joined(separator: "\n\n")
    }
}
