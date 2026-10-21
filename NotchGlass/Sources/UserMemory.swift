import Foundation

/// What Notchi remembers: a folder of Markdown files the model writes however
/// it likes. There is no fixed format: it picks the file names, what goes in
/// each, and when to rewrite or delete one. The chat model reaches it through
/// `memory_list` / `memory_read` / `memory_write` / `memory_delete`, and a
/// copy worth keeping is filed there too (`NotchModel.senseRemember`).
/// Stored on this Mac only, in Application Support, and listed in Settings
/// where each file can be deleted.
///
/// Every Ask round carries the file list with each file's opening lines in the
/// system prompt (`promptList`); the model reads a whole file when it needs it.
@MainActor
final class UserMemory: ObservableObject {
    static let shared = UserMemory()

    /// One file, as Settings lists it.
    struct Entry: Identifiable, Equatable {
        let id: String          // the file name
        var preview: String     // the first line of body text
        var modified: Date
    }

    @Published private(set) var entries: [Entry] = []
    /// The master switch, on for new installs, off for existing ones. Off, nothing reads or writes the
    /// folder, copies included, and no clipboard history is kept
    /// (`ClipboardHistory.recording`). Turning it on builds the memory from past
    /// conversations (`NotchModel.scanHistoryForMemories`); turning it off
    /// deletes every file, so the next time it is on it builds again.
    @Published var enabled: Bool = OnboardingService.firstRunDefault(UserMemory.enabledKey, fresh: true, existing: false) {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if !enabled {
                deleteAll()
                historyScanDone = false
            }
        }
    }
    static let enabledKey = "memory.enabled"
    @Published private(set) var scanning = false

    /// The history is read once; a failed read leaves this false so the next
    /// open tries again.
    var historyScanDone: Bool {
        get { UserDefaults.standard.bool(forKey: Self.scanDoneKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.scanDoneKey) }
    }
    private static let scanDoneKey = "memory.historyScanDone"

    /// Per file, and for the opening lines the prompt carries per file.
    static let fileCharLimit = 20_000
    static let fileLimit = 200
    private static let headLines = 3
    private static let promptCharLimit = 6_000

    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchi", isDirectory: true)
        let dir = base.appendingPathComponent("Memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        migrateFactList()
        reload()
    }

    /// The old fixed-format memory (`memory.json`, one fact per entry) becomes
    /// one file in the folder, once.
    private func migrateFactList() {
        let old = Self.folder.deletingLastPathComponent().appendingPathComponent("memory.json")
        struct Fact: Decodable { var text: String }
        guard let data = try? Data(contentsOf: old) else { return }
        if let facts = try? JSONDecoder().decode([Fact].self, from: data), !facts.isEmpty {
            let body = "# About the user\n\n" + facts.map { "- \($0.text)" }.joined(separator: "\n") + "\n"
            let url = Self.folder.appendingPathComponent("about-user.md")
            if !FileManager.default.fileExists(atPath: url.path) {
                try? body.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        try? FileManager.default.moveItem(at: old, to: old.appendingPathExtension("migrated"))
    }

    /// Files at the top level and one folder down, newest first.
    private func fileURLs() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]
        let fm = FileManager.default
        func list(_ dir: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles])) ?? []
        }
        var files: [URL] = []
        for url in list(Self.folder) {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                files += list(url).filter {
                    (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }
            } else if values?.isRegularFile == true {
                files.append(url)
            }
        }
        return files.sorted { modified($0) > modified($1) }
    }

    /// A file's name as the model and Settings see it: "notes.md", or
    /// "work/notchi.md" one folder down.
    private func relativeName(_ url: URL) -> String {
        let root = Self.folder.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : url.lastPathComponent
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func reload() {
        entries = fileURLs().map { url in
            let lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // Body text over a heading; a heading only when that is all there is.
            let line = lines.first { !$0.hasPrefix("#") } ?? lines.first ?? ""
            let preview = line.trimmingCharacters(in: CharacterSet(charactersIn: "#-* ").union(.whitespaces))
            return Entry(id: relativeName(url), preview: preview, modified: modified(url))
        }
        // By name, so a file being edited in Settings holds its place.
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// A model-given file name, kept inside the folder: at most one folder
    /// level ("work/notchi.md"), no leading dots, `.md` added when it has no
    /// extension. Nil when unusable.
    static func safeName(_ raw: String) -> String? {
        var parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/").map { part -> String in
                var p = part.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "-")
                while p.hasPrefix(".") { p.removeFirst() }
                return p
            }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty, parts.count <= 2, parts.allSatisfy({ $0.count <= 80 }) else { return nil }
        if (parts[parts.count - 1] as NSString).pathExtension.isEmpty { parts[parts.count - 1] += ".md" }
        return parts.joined(separator: "/")
    }

    private func url(_ name: String) -> URL? {
        Self.safeName(name).map { Self.folder.appendingPathComponent($0) }
    }

    // MARK: Files

    func list() -> String {
        let files = fileURLs()
        guard !files.isEmpty else { return "The memory folder is empty." }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        return files.map { url in
            let size = (try? String(contentsOf: url, encoding: .utf8))?.count ?? 0
            return "- \(relativeName(url)) (\(size) chars, updated \(day.string(from: modified(url))))"
        }.joined(separator: "\n")
    }

    /// The file's text, or nil when there is no such file.
    func read(_ name: String) -> String? {
        guard let url = url(name) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Create or replace a file. Returns an error for the model, or nil.
    @discardableResult
    func write(_ name: String, content: String) -> String? {
        guard let url = url(name) else { return "Error: give a plain file name, e.g. \"projects.md\"." }
        guard content.count <= Self.fileCharLimit else {
            return "Error: keep a file under \(Self.fileCharLimit) characters; split it into several files."
        }
        let isNew = !FileManager.default.fileExists(atPath: url.path)
        guard !isNew || fileURLs().count < Self.fileLimit else {
            return "Error: the folder holds \(Self.fileLimit) files; merge or delete some first."
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return "Error: could not write \(relativeName(url))."
        }
        reload()
        return nil
    }

    /// Returns whether a file was deleted.
    @discardableResult
    func remove(_ name: String) -> Bool {
        guard let url = url(name), (try? FileManager.default.removeItem(at: url)) != nil else { return false }
        removeIfEmpty(url.deletingLastPathComponent())
        reload()
        return true
    }

    /// A folder left with no files goes too; the root stays.
    private func removeIfEmpty(_ dir: URL) {
        guard dir.standardizedFileURL != Self.folder.standardizedFileURL,
              let rest = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              rest.allSatisfy({ $0.hasPrefix(".") }) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    func delete(_ id: String) { remove(id) }

    /// Every file, and the clipboard history the folder is filed from.
    func deleteAll() {
        ClipboardHistory.shared.clear()
        let items = (try? FileManager.default.contentsOfDirectory(at: Self.folder,
                                                                 includingPropertiesForKeys: nil)) ?? []
        for url in items { try? FileManager.default.removeItem(at: url) }
        reload()
    }

    // MARK: Facts from past conversations

    func beginScan() { scanning = true }

    /// The facts found in past conversations go into one file.
    /// `nil` when the read failed; it is tried again next time.
    func finishScan(_ found: [String]?) {
        scanning = false
        // Turned off while the read was out: it was a request for nothing.
        guard enabled, let found else { return }
        historyScanDone = true
        guard !found.isEmpty else { return }
        // Parked in the about file; `NotchModel.tidyMemory` then files each
        // fact where it belongs.
        let name = "about-user.md"
        let current = read(name) ?? "# About the user\n"
        let body = current.trimmingCharacters(in: .newlines) + "\n"
            + found.map { "- \($0)" }.joined(separator: "\n") + "\n"
        write(name, content: String(body.prefix(Self.fileCharLimit)))
    }

    /// The folder in full, newest first, for a model that will rewrite one of
    /// its files: whole files while they fit a budget, then names only.
    var promptContents: String {
        var out = ""
        var names: [String] = []
        for url in fileURLs() {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let block = "\n## \(relativeName(url))\n\(text)"
            if names.isEmpty, out.count + block.count <= 16_000 {
                out += block
            } else {
                names.append(relativeName(url))
            }
        }
        if !names.isEmpty { out += "\n\nOther files (not shown): " + names.joined(separator: ", ") }
        return out.isEmpty ? "(empty)" : out.trimmingCharacters(in: .newlines)
    }

    /// The folder as the system prompt shows it: each file's name and opening
    /// lines, newest first, within a fixed budget.
    var promptList: String {
        var out = ""
        for url in fileURLs() {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let lines = text.split(whereSeparator: \.isNewline).prefix(Self.headLines)
            var block = "\n## \(relativeName(url))\n" + lines.joined(separator: "\n")
            if text.split(whereSeparator: \.isNewline).count > Self.headLines { block += "\n…" }
            if out.count + block.count > Self.promptCharLimit {
                out += "\n(more files: call memory action=list)"
                break
            }
            out += block
        }
        return out.isEmpty ? "(empty)" : out.trimmingCharacters(in: .newlines)
    }
}

/// `memory_list`: the files in the memory folder.
struct MemoryListTool: NotchTool {
    static let toolName = "memory_list"
    let name = toolName
    let description = """
    Lists the files in your memory folder with their size and last update. \
    The prompt already shows each file's opening lines; call this when it says \
    there are more files.
    """
    let schema: [String: Any] = ["type": "object", "properties": [String: Any]()]

    func execute(_ input: [String: Any]) async throws -> String {
        await MainActor.run { UserMemory.shared.list() }
    }
}

/// `memory_read`: one memory file in full.
struct MemoryReadTool: NotchTool {
    static let toolName = "memory_read"
    let name = toolName
    let description = """
    Reads one file from your memory folder in full. Call when the opening \
    lines in the prompt suggest the file holds what this answer needs, or \
    before rewriting a file with memory_write.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": ["file": ["type": "string", "description": "The file name, e.g. \"projects.md\"."]],
        "required": ["file"],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        let file = input["file"] as? String ?? ""
        return await MainActor.run {
            UserMemory.shared.read(file) ?? "No file named \"\(file)\". Files:\n" + UserMemory.shared.list()
        }
    }
}

/// `memory_write`: create or replace a memory file. The answer shows "Updated
/// memory" with an undo (`NotchModel.handleMemoryWrite`).
struct MemoryWriteTool: NotchTool {
    static let toolName = "memory_write"
    let name = toolName
    let description = """
    Creates or replaces one file in your memory folder, which you keep across \
    conversations on this Mac. Write whatever will help you later, in any \
    shape you like: who the user is, their work and projects, people they \
    mention, preferences, things they asked you to remember, notes on ongoing \
    matters. \(memoryOrganizationRules) `content` replaces the \
    whole file, so read the file first when adding to it. Do not save \
    passwords, account numbers, health or financial details unless they ask. \
    Then answer as usual; mention the save only if they asked for it.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "file": ["type": "string", "description": "The file name, e.g. \"projects.md\"."],
            "content": ["type": "string", "description": "The file's full new text, Markdown."],
        ],
        "required": ["file", "content"],
    ]

    let handle: @Sendable (_ file: String, _ content: String) async -> String

    func execute(_ input: [String: Any]) async throws -> String {
        await handle(input["file"] as? String ?? "", input["content"] as? String ?? "")
    }
}

/// `memory_delete`: drop a memory file.
struct MemoryDeleteTool: NotchTool {
    static let toolName = "memory_delete"
    let name = toolName
    let description = """
    Deletes one file from your memory folder. Call when the user asks you to \
    forget what it holds, or when it is no longer true or useful. To drop part \
    of a file, rewrite it with memory_write instead.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": ["file": ["type": "string", "description": "The file name, e.g. \"projects.md\"."]],
        "required": ["file"],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        let file = input["file"] as? String ?? ""
        return await MainActor.run {
            UserMemory.shared.remove(file) ? "Deleted \(file)." : "No file named \"\(file)\"."
        }
    }
}
