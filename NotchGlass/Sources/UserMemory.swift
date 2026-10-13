import Foundation

/// What Notchi remembers about the user across conversations: short facts the
/// chat model saves with `remember` ("works on a macOS app called Notchi",
/// "has a cat named Mochi") and drops with `forget`. Stored on this Mac only,
/// in Application Support, and listed in Settings where each one can be deleted.
///
/// Every Ask round carries them in the system prompt (`notchSystemPromptDated`).
/// They change rarely, so they sit above the date line and stay inside the
/// upstream prompt cache.
@MainActor
final class UserMemory: ObservableObject {
    static let shared = UserMemory()

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var text: String
        var createdAt = Date()
    }

    @Published private(set) var entries: [Entry] = []
    /// The master switch, off by default. Turning it on builds the memory from
    /// past conversations (`NotchModel.scanHistoryForMemories`); turning it off
    /// deletes every fact, so the next time it is on it builds again.
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: UserMemory.enabledKey) as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if !enabled {
                deleteAll()
                historyScanDone = false
            }
        }
    }
    private static let enabledKey = "memory.enabled"
    @Published private(set) var scanning = false

    /// The history is read for facts once; a failed read leaves this
    /// false so the next open tries again.
    var historyScanDone: Bool {
        get { UserDefaults.standard.bool(forKey: Self.scanDoneKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.scanDoneKey) }
    }
    private static let scanDoneKey = "memory.historyScanDone"

    /// Per fact, and in total: the prompt carries them on every turn.
    static let entryCharLimit = 300
    static let entryLimit = 100

    private static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchi", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    private let fileURL = UserMemory.folder.appendingPathComponent("memory.json")

    private init() {
        entries = Self.load(fileURL)
    }

    private static func load(_ url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return saved
    }

    // MARK: Facts from past conversations

    func beginScan() { scanning = true }

    /// The facts found in past conversations, saved like `remember` saves one.
    /// `nil` when the read failed; it is tried again next time.
    func finishScan(_ found: [String]?) {
        scanning = false
        // Turned off while the read was out: it was a request for nothing.
        guard enabled, let found else { return }
        historyScanDone = true
        for fact in found { _ = remember(fact) }
    }

    /// Save one fact. Returns what the model is told.
    func remember(_ raw: String) -> String {
        let text = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Error: give the fact to remember." }
        guard text.count <= Self.entryCharLimit else {
            return "Error: keep it under \(Self.entryCharLimit) characters — one short fact."
        }
        if entries.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
            return "Already remembered."
        }
        entries.append(Entry(text: text))
        // The oldest go first once the list is full.
        if entries.count > Self.entryLimit { entries.removeFirst(entries.count - Self.entryLimit) }
        save()
        return "Remembered."
    }

    /// Drop every fact containing `query`. Returns what the model is told.
    func forget(_ raw: String) -> String {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "Error: say what to forget." }
        let removed = entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
        guard !removed.isEmpty else {
            return "Nothing remembered contains \"\(query)\". Remembered facts:\n" + promptList
        }
        entries.removeAll { entry in removed.contains { $0.id == entry.id } }
        save()
        return "Forgot:\n" + removed.map { "- \($0.text)" }.joined(separator: "\n")
    }

    /// Rewrite the fact containing `query` as `fact`. Returns the fact as it
    /// was, for undo, or nil when nothing matched.
    func replace(matching query: String, with fact: String) -> Entry? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = fact.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !text.isEmpty, text.count <= Self.entryCharLimit,
              let index = entries.firstIndex(where: { $0.text.localizedCaseInsensitiveContains(query) })
        else { return nil }
        let before = entries[index]
        entries[index].text = text
        save()
        return before
    }

    /// Undo of `replace`: put the fact back as it was.
    func restore(_ entry: Entry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].text = entry.text
        } else {
            entries.append(entry)
        }
        save()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func deleteAll() {
        entries = []
        save()
    }

    /// The facts as the system prompt lists them.
    var promptList: String {
        entries.isEmpty ? "(none)" : entries.map { "- \($0.text)" }.joined(separator: "\n")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// `remember`: save a lasting fact about the user.
struct RememberTool: NotchTool {
    static let toolName = "remember"
    let name = toolName
    let description = """
    Saves one lasting fact about the user, kept across conversations on this \
    Mac. Call when they state something about themselves that will still be \
    true next week and would change later answers: what to call them, their \
    work or role, projects they are on, people they mention by name and how \
    they relate, preferences and dislikes, or when they say "remember …". One \
    short third-person fact per call, in their language. Do not save passwords, \
    account numbers, health or financial details unless they ask; the user's own \
    ID numbers (passport, 身份证, driver's licence) found for them are kept. Do \
    not save what is already listed under "What you know about the user". Then \
    answer as usual; mention the save only if they asked for it.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "fact": ["type": "string",
                     "description": "The fact, one short sentence about the user, e.g. \"在做一个叫 Notchi 的 macOS 应用\"."],
        ],
        "required": ["fact"],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        let fact = input["fact"] as? String ?? ""
        return await MainActor.run { UserMemory.shared.remember(fact) }
    }
}

/// `update_memory`: correct a remembered fact the user has just contradicted.
/// The answer shows "Updated memory" with an undo (`NotchModel.handleMemoryUpdate`).
struct UpdateMemoryTool: NotchTool {
    static let toolName = "update_memory"
    let name = toolName
    let description = """
    Rewrites one remembered fact about the user that is no longer true. Call \
    when what they say now contradicts a fact under "What you know about the \
    user" (a new job, a move, a changed preference): `old` is text from that \
    fact, `fact` the corrected sentence. Then answer as usual.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "old": ["type": "string", "description": "Text the outdated fact contains, e.g. its key word."],
            "fact": ["type": "string", "description": "The corrected fact, one short sentence about the user."],
        ],
        "required": ["old", "fact"],
    ]

    let handle: @Sendable (_ old: String, _ fact: String) async -> String

    func execute(_ input: [String: Any]) async throws -> String {
        await handle(input["old"] as? String ?? "", input["fact"] as? String ?? "")
    }
}

/// `forget`: drop remembered facts.
struct ForgetTool: NotchTool {
    static let toolName = "forget"
    let name = toolName
    let description = """
    Deletes remembered facts about the user that contain `query`. Call when \
    they ask you to forget something, or when a remembered fact is no longer \
    true (then `remember` the new one).
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string",
                      "description": "Text that the facts to delete contain, e.g. a name or a word from the fact."],
        ],
        "required": ["query"],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        let query = input["query"] as? String ?? ""
        return await MainActor.run { UserMemory.shared.forget(query) }
    }
}
