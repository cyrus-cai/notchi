import AppKit
import Foundation
import SwiftUI

/// How long copies stay in `ClipboardHistory`. `forever` never deletes.
enum ClipboardRetention: Int, CaseIterable {
    case week = 7, month = 30, quarter = 90, year = 365, forever = 0

    /// Auto delete is off until the user turns it on.
    static let standard: ClipboardRetention = .forever
    /// The period Auto delete starts at when it is turned on.
    static let autoDeleteDefault: ClipboardRetention = .week
    /// The periods the Delete after menu offers.
    static let periods: [ClipboardRetention] = [.week, .month, .quarter, .year]

    var label: String { L("clipboardHistory.retention.\(rawValue)") }

    /// Copies last made before this go. `nil` keeps everything.
    var cutoff: Date? {
        guard rawValue > 0 else { return nil }
        return Calendar.current.date(byAdding: .day, value: -rawValue, to: Date())
    }
}

/// The text the user copied, kept on this Mac so Ask can find it again
/// ("the link I copied last week", "那段前天复制的报错"). Stored in SQLite
/// (`ClipboardStore`) for the period set in Settings → Memory (`retention`).
/// Recorded by the resting clipboard watcher (`NotchModel.senseTick`) with the
/// same exclusions Copy Sense uses: nothing a password manager marks concealed
/// or transient, nothing that looks like a credential, nothing Notchi wrote,
/// nothing from an app in `excludedApps`.
///
/// Its own switch, independent of Memory. With both on, copies are also
/// judged for memory (`feedsMemory`).
@MainActor
final class ClipboardHistory: ObservableObject {
    static let shared = ClipboardHistory()

    /// Off hides the setting, records nothing and gives Ask no
    /// `clipboard_history` tool.
    static let available = true

    struct ExcludedApp: Identifiable, Equatable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    nonisolated let store: ClipboardStore

    /// Bumped on every change, so a list on screen reloads.
    @Published private(set) var revision = 0

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if !enabled { clear() }
        }
    }

    @Published var retention: ClipboardRetention {
        didSet {
            UserDefaults.standard.set(retention.rawValue, forKey: Self.retentionKey)
            prune()
        }
    }

    @Published private(set) var excludedApps: [ExcludedApp] = []

    private static let enabledKey = "clipboardHistory.enabled"
    private static let decoupledKey = "clipboardHistory.decoupledFromMemory"
    private static let retentionKey = "clipboardHistory.retentionDays"
    private static let excludedKey = "clipboardHistory.excludedApps"

    /// Password managers are left out from the start; each can be restored.
    private static let defaultExcluded: [String: String] = [
        "com.1password.1password": "1Password",
        "com.agilebits.onepassword7": "1Password 7",
        "com.bitwarden.desktop": "Bitwarden",
        "com.apple.keychainaccess": "Keychain Access",
        "com.apple.Passwords": "Passwords",
    ]

    var recording: Bool { enabled }

    /// Copies are judged for memory only with both switches on.
    var feedsMemory: Bool { enabled && UserMemory.shared.enabled }

    static let textLimit = 20_000

    private var lastPrune = Date.distantPast

    private static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchi", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// The database file every saved copy lives in.
    static var fileURL: URL { folder.appendingPathComponent("clipboard.sqlite") }

    private init() {
        store = ClipboardStore(url: Self.fileURL)
        let defaults = UserDefaults.standard

        // Before this switch stood on its own, copies were kept only with
        // Memory on too. Carry that over once, so nobody starts recording
        // without having turned it on.
        var on = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        if !defaults.bool(forKey: Self.decoupledKey) {
            if defaults.object(forKey: UserMemory.enabledKey) != nil {
                on = on && UserMemory.shared.enabled
            }
            defaults.set(on, forKey: Self.enabledKey)
            defaults.set(true, forKey: Self.decoupledKey)
        }
        enabled = on

        let days = defaults.object(forKey: Self.retentionKey) as? Int ?? ClipboardRetention.standard.rawValue
        retention = ClipboardRetention(rawValue: days) ?? .standard

        let saved = defaults.dictionary(forKey: Self.excludedKey) as? [String: String] ?? Self.defaultExcluded
        excludedApps = Self.sorted(saved)

        importLegacyJSON()
        prune()
    }

    /// Newest first. A text copied again moves to the top instead of repeating.
    func add(_ text: String, app: String?, bundleID: String?) {
        guard enabled else { return }
        if let bundleID, excludedApps.contains(where: { $0.bundleID == bundleID }) { return }
        store.upsert(text: String(text.prefix(Self.textLimit)), app: app, bundleID: bundleID, at: Date())
        if Date().timeIntervalSince(lastPrune) > 6 * 3600 { prune() }
        revision += 1
    }

    func delete(_ id: Int64) {
        store.delete(id: id)
        revision += 1
    }

    func clear() {
        store.deleteAll()
        revision += 1
    }

    /// How many copies a shorter retention would delete now.
    func count(olderThan retention: ClipboardRetention) -> Int {
        guard let cutoff = retention.cutoff else { return 0 }
        return store.count(before: cutoff)
    }

    func count() -> Int { store.count() }

    /// Copies made in the last `days` days, newest first.
    func recent(days: Int, limit: Int) -> [ClipboardStore.Clip] {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        return store.search(since: since, limit: limit)
    }

    func exclude(bundleID: String, name: String) {
        var map = Dictionary(uniqueKeysWithValues: excludedApps.map { ($0.bundleID, $0.name) })
        map[bundleID] = name
        saveExcluded(map)
    }

    func include(bundleID: String) {
        var map = Dictionary(uniqueKeysWithValues: excludedApps.map { ($0.bundleID, $0.name) })
        map[bundleID] = nil
        saveExcluded(map)
    }

    /// The app's name as Finder shows it in the current language, or the name
    /// stored with the copy.
    static func displayName(bundleID: String?, fallback: String?) -> String? {
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return fallback
    }

    private func saveExcluded(_ map: [String: String]) {
        UserDefaults.standard.set(map, forKey: Self.excludedKey)
        excludedApps = Self.sorted(map)
    }

    private static func sorted(_ map: [String: String]) -> [ExcludedApp] {
        map.map { ExcludedApp(bundleID: $0.key, name: displayName(bundleID: $0.key, fallback: $0.value) ?? $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func prune() {
        lastPrune = Date()
        if let cutoff = retention.cutoff { store.prune(before: cutoff) }
        revision += 1
    }

    /// Up to 0.9.46 the last 50 copies lived in `clipboard-history.json`.
    private func importLegacyJSON() {
        struct Legacy: Decodable { var text: String; var copiedAt: Date; var app: String? }
        let url = Self.folder.appendingPathComponent("clipboard-history.json")
        guard let data = try? Data(contentsOf: url) else { return }
        if enabled, let saved = try? JSONDecoder().decode([Legacy].self, from: data) {
            // Oldest first, so the newest ends up newest.
            for entry in saved.reversed() {
                store.upsert(text: entry.text, app: entry.app, bundleID: nil, at: entry.copiedAt)
            }
            store.flush()
        }
        try? FileManager.default.removeItem(at: url)
    }
}

/// `clipboard_history`: search what the user copied.
struct ClipboardHistoryTool: NotchTool {
    static let toolName = "clipboard_history"
    let name = toolName
    let description = """
    Searches text the user copied on this Mac, kept for the period they set in \
    Settings, newest first, with when and from which app. Call when they refer \
    to something they copied earlier — "the link I copied last week", \
    "那段前天复制的报错" — and it is not the current clipboard (read_clipboard \
    reads that). This holds the exact copied text; facts about the user live in \
    memory instead. Narrow with query, app and dates rather than listing \
    everything.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string",
                      "description": "Words the copy contains. Every word must appear."],
            "app": ["type": "string",
                    "description": "Only copies made in this app, by name, e.g. \"Safari\"."],
            "since": ["type": "string",
                      "description": "Only copies made on or after this date, YYYY-MM-DD or YYYY-MM-DD HH:mm, local time."],
            "until": ["type": "string",
                      "description": "Only copies made on or before this date, YYYY-MM-DD or YYYY-MM-DD HH:mm, local time."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 20,
                      "description": "How many, 1 to 20. Default 10."],
        ],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        let query = (input["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let app = (input["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = min(max((input["limit"] as? NSNumber)?.intValue ?? 10, 1), 20)
        let since = Self.parseDate(input["since"] as? String, endOfDay: false)
        let until = Self.parseDate(input["until"] as? String, endOfDay: true)
        let (enabled, store) = await MainActor.run {
            (ClipboardHistory.shared.enabled, ClipboardHistory.shared.store)
        }
        guard enabled else { return "Copy history is off in Settings → Memory." }
        let found = store.search(query: query, app: app, since: since, until: until, limit: limit)
        guard !found.isEmpty else {
            return query.isEmpty && app == nil && since == nil && until == nil
                ? "Nothing copied yet."
                : "No saved copy matches."
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return found.map { clip in
            let body = clip.text.count > 1500 ? String(clip.text.prefix(1500)) + "…" : clip.text
            let from = clip.app.map { " from \($0)" } ?? ""
            let times = clip.copyCount > 1 ? " (copied \(clip.copyCount) times)" : ""
            return "## \(fmt.string(from: clip.lastCopiedAt))\(from)\(times)\n\(body)"
        }.joined(separator: "\n\n")
    }

    /// `YYYY-MM-DD` is the start of that day, or with `endOfDay` the end of it.
    private static func parseDate(_ raw: String?, endOfDay: Bool) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        if let date = fmt.date(from: raw) { return endOfDay ? date.addingTimeInterval(60) : date }
        fmt.dateFormat = "yyyy-MM-dd"
        if let day = fmt.date(from: String(raw.prefix(10))) {
            return endOfDay ? Calendar.current.date(byAdding: .day, value: 1, to: day) : day
        }
        return ISO8601DateFormatter().date(from: raw)
    }
}
