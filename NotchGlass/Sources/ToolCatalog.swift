import Foundation

// MARK: - Tool groups and deferred tools
//
// What the model sees is smaller than what the app implements. Tools about one
// thing (the calendar, reminders, notes, mail, files, memory, the clipboard)
// are advertised as one tool each, with an `action` that picks the member that
// runs (`GroupedTool`). Each member keeps its own code; only its name and
// description leave the wire.
//
// The tools a question rarely needs are held back (`ToolCatalog.deferred`): the
// first turn advertises the rest plus `load_tools`, and a held tool joins the
// wire once the model loads it or calls it by name. The list a run starts with
// is the same on every question, so a provider's prompt cache keeps matching
// from one question to the next, and within a run the list only grows.

/// Several tools behind one name. `action` picks the member; the member gets
/// the input with `action` removed, or kept when it reads `action` itself.
struct GroupedTool: NotchTool {
    struct Route: Sendable {
        let action: String
        let tool: NotchTool
        /// The member reads `action` itself (`manage_event`, `read_mail`, …).
        let keepsAction: Bool
    }

    let name: String
    let description: String
    let schema: [String: Any]
    let routes: [Route]

    func execute(_ input: [String: Any]) async throws -> String {
        let actions = routes.map(\.action)
        guard let action = input["action"] as? String,
              let route = routes.first(where: { $0.action == action }) else {
            return "Error: action must be one of \(actions.joined(separator: ", "))."
        }
        var inner = input
        if !route.keepsAction { inner.removeValue(forKey: "action") }
        return try await route.tool.execute(inner)
    }
}

enum ToolCatalog {
    /// One member of a group: the tool it wraps, the actions that reach it, and
    /// its sentence in the group's description.
    struct Part {
        let member: String
        let actions: [String]
        let keepsAction: Bool
        let copy: String
        /// The group properties this member reads.
        let properties: [String]
    }

    struct Group {
        let name: String
        let intro: String
        let parts: [Part]
        let outro: String
        let properties: [String: [String: Any]]
    }

    /// Held back until the model loads them, with the line `load_tools` lists
    /// for each. Measured on the use-case eval (2026-10-21): together these
    /// are called on about 7% of questions; holding back the shell, files,
    /// mail, photos and history tools as well sent half the questions through
    /// an extra `load_tools` round, and a held-back photos tool went unused
    /// where the answer was in a photo.
    static let deferred: [(name: String, summary: String)] = [
        ("manage_loop", "repeat a task on a schedule, or watch something over time"),
        ("schedule_action", "run a command on this Mac later"),
        ("travel_time", "how long a trip takes, from Apple Maps"),
        ("recent_songs", "what the user played in Music lately"),
        ("wifi_status", "the Wi-Fi network and its signal"),
        ("account_usage", "what the user spent and has left on Notchi Balance"),
    ]

    static var deferredNames: Set<String> { Set(deferred.map(\.name)) }

    static func summary(of name: String) -> String? {
        deferred.first { $0.name == name }?.summary
    }

    /// A description's first sentence, cut to one line for `load_tools`.
    static func brief(_ description: String) -> String {
        let line = description.split(whereSeparator: \.isNewline).first.map(String.init) ?? description
        let sentence = line.range(of: ". ").map { String(line[..<$0.lowerBound]) } ?? line
        return sentence.count > 160 ? sentence.prefix(160) + "…" : sentence
    }

    /// Members replaced by their group, which takes the place of the first
    /// member in the list. A group with no member present is left out; one
    /// with some members present offers only their actions.
    static func assemble(_ tools: [NotchTool]) -> [NotchTool] {
        let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var placed = Set<String>()
        var out: [NotchTool] = []
        for tool in tools {
            guard let group = groups.first(where: { g in g.parts.contains { $0.member == tool.name } }) else {
                out.append(tool)
                continue
            }
            guard !placed.contains(group.name) else { continue }
            placed.insert(group.name)
            out.append(build(group, from: byName))
        }
        return out
    }

    private static func build(_ group: Group, from tools: [String: NotchTool]) -> NotchTool {
        let present = group.parts.filter { tools[$0.member] != nil }
        let routes = present.flatMap { part in
            part.actions.map { GroupedTool.Route(action: $0, tool: tools[part.member]!, keepsAction: part.keepsAction) }
        }
        var properties: [String: Any] = [
            "action": ["type": "string", "enum": routes.map(\.action)],
        ]
        for key in present.flatMap(\.properties) {
            properties[key] = group.properties[key]
        }
        let description = ([group.intro] + present.map(\.copy) + [group.outro])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return GroupedTool(name: group.name, description: description,
                           schema: ["type": "object", "properties": properties, "required": ["action"]],
                           routes: routes)
    }

    /// The member a call reaches: `create_event` for `calendar` action=create.
    /// A call that is not to a group, or names no action yet, keeps its name.
    static func member(of name: String, input: [String: Any]) -> String {
        guard let group = groups.first(where: { $0.name == name }),
              let action = input["action"] as? String,
              let part = group.parts.first(where: { $0.actions.contains(action) })
        else { return name }
        return part.member
    }

    // MARK: Groups

    static let groups: [Group] = [calendar, reminders, notes, mail, files, memory, clipboard]

    private static let timeZone: [String: Any] = [
        "type": "string",
        "description": "When the user gives the time on another place's clock (\"9am PT\", \"东京时间 10 点\"): that IANA zone, e.g. America/Los_Angeles, with the time written on that clock. Omit for this Mac's time.",
    ]

    static let calendar = Group(
        name: "calendar",
        intro: "The user's Apple Calendar on this Mac.",
        parts: [
            Part(member: ReadCalendarTool.toolName, actions: ["list"], keepsAction: false,
                 copy: "action=list reads the events from `from` for `days`, for questions about their schedule: what's on a day, when they are free, when a meeting is.",
                 properties: ["from", "days", "query"]),
            Part(member: CreateEventTool.toolName, actions: ["create"], keepsAction: false,
                 copy: "action=create adds an event: a meeting, appointment, call, trip or anything else that takes up time at a set moment (\"周五下午三点和 Amy 开会\"). Give `title` and an absolute local `start`; omit `end` unless the user gave one or a length.",
                 properties: ["title", "start", "end", "location", "alert_minutes", "repeat", "repeat_count", "repeat_until", "time_zone"]),
            Part(member: ManageEventTool.toolName, actions: ["move", "update", "delete"], keepsAction: true,
                 copy: "action=move gives an existing event a new `start` and keeps its length, action=update changes its `title` or `location`, action=delete removes it after the user confirms. Identify it by `id` from action=list, or by `query` (text in its title) within the next 60 days; if several match, the result lists them with ids. For a repeating event, span=future changes this and every later one; ask the user which they mean.",
                 properties: ["id", "query", "start", "title", "location", "time_zone", "span"]),
        ],
        outro: "Never say an event was added or changed until the result says so.",
        properties: [
            "from": ["type": "string", "description": "list: first day, local YYYY-MM-DD. Omit for today."],
            "days": ["type": "integer", "minimum": 1, "maximum": 31,
                     "description": "list: how many days from `from`, 1 to 31. Default 1."],
            "query": ["type": "string", "description": "list: only events whose title, location or notes contain this. move/update/delete: text in the event's title, when there is no id."],
            "id": ["type": "string", "description": "move/update/delete: the event's id from action=list."],
            "title": ["type": "string", "description": "create: what the event is, a short line in the user's language without the time. update: the new title."],
            "start": ["type": "string", "description": "create/move: the local start, YYYY-MM-DDTHH:MM (for example 2026-10-16T15:00), or YYYY-MM-DD for an all-day event."],
            "end": ["type": "string", "description": "create: when it ends, in the same form as start. Omit for one hour (or one day, all-day)."],
            "location": ["type": "string", "description": "create/update: where, if the user said."],
            "alert_minutes": ["type": "integer", "minimum": 0,
                              "description": "create: minutes before the start to notify. Default 10; 0 when the user wants no alert."],
            "repeat": ["type": "string", "enum": ["daily", "weekdays", "weekly", "monthly"],
                       "description": "create: when it repeats (\"every Tuesday\", \"每个工作日\"). Weekly repeats on the start's weekday."],
            "repeat_count": ["type": "integer", "minimum": 2, "maximum": 366,
                             "description": "create, with repeat: how many times in all, when the user gave a number."],
            "repeat_until": ["type": "string", "description": "create, with repeat: the last day it happens, YYYY-MM-DD."],
            "time_zone": timeZone,
            "span": ["type": "string", "enum": ["this", "future"],
                     "description": "move/update/delete on a repeating event: this one only (default) or this and all later ones."],
        ])

    static let reminders = Group(
        name: "reminders",
        intro: "The user's Apple Reminders on this Mac.",
        parts: [
            Part(member: ReadRemindersTool.toolName, actions: ["list"], keepsAction: false,
                 copy: "action=list reads the open reminders, overdue included: \"what's left to do\", \"what's due this week\", \"what's on my shopping list\". `due_within_days` keeps those due within that many days; `completed_days` lists what they completed instead; `list` keeps one Reminders list. Each line names its list, and the result ends with the list names.",
                 properties: ["due_within_days", "completed_days", "query", "list"]),
            Part(member: "create_reminder", actions: ["create"], keepsAction: false,
                 copy: "action=create sets a reminder when the user asks to be reminded or to save something that names a time: `title`, and an absolute local `due`. Something that takes up time at a set moment is a calendar event instead.",
                 properties: ["title", "due", "repeat", "repeat_until", "list", "time_zone"]),
            Part(member: ManageReminderTool.toolName, actions: ["complete", "reschedule", "delete", "move", "rename"], keepsAction: true,
                 copy: "To change one: action=complete marks it done, reschedule moves it to a new `due`, delete removes it after the user confirms (also for \"cancel the reminder\"), move puts it in another `list`, rename changes its `title` and keeps its time. Identify it by `id` from action=list, or by `query` (text in its title); if several match, the result lists them with ids.",
                 properties: ["id", "query", "due", "title", "list", "time_zone"]),
        ],
        outro: "Never say a reminder was saved or changed until the result says so.",
        properties: [
            "due_within_days": ["type": "integer", "minimum": 0, "maximum": 365,
                                "description": "list: open reminders due from now through this many days (0 = today), overdue included."],
            "completed_days": ["type": "integer", "minimum": 1, "maximum": 90,
                               "description": "list: reminders completed in this many past days instead of open ones."],
            "query": ["type": "string", "description": "list: only reminders whose title or notes contain this. Changes: text in its title, when there is no id."],
            "list": ["type": "string", "description": "The Reminders list, as the user names it (\"groceries\", \"买菜\", \"Work\"). list: only this one. create: the one it goes in; omit for their default. move: the one it goes to."],
            "id": ["type": "string", "description": "The reminder's id from action=list."],
            "title": ["type": "string", "description": "create: what to remind them about, one short line in their language, keeping a repeat phrase such as \"every Monday\". rename: the new title."],
            "due": ["type": "string", "description": "create/reschedule: when it fires, local YYYY-MM-DDTHH:MM (for example 2026-08-20T15:00), in the future. Omit only for a reminder with genuinely no time."],
            "repeat": ["type": "string", "enum": ["daily", "weekly", "monthly"],
                       "description": "create: when the user asks for it to repeat. Weekly repeats on the due date's weekday."],
            "repeat_until": ["type": "string", "description": "create, with repeat: the last day it repeats, YYYY-MM-DD, when the user says until when."],
            "time_zone": timeZone,
        ])

    static let notes = Group(
        name: "notes",
        intro: "The user's notes (Apple Notes or their Markdown folder).",
        parts: [
            Part(member: "create_note", actions: ["create"], keepsAction: false,
                 copy: "action=create saves a note when the message is something to keep rather than a question or a request: a todo, an idea, a fact to remember, a snippet, an explicit \"note this\". Pass their words as `text`; the first line becomes the title. If it could be a question, answer instead. A named time is a reminder; a meeting is a calendar event.",
                 properties: ["text"]),
            Part(member: ReadNotesTool.toolName, actions: ["list"], keepsAction: false,
                 copy: "action=list reads the most recently edited notes, or those containing `query`, for questions about what they wrote down; a `query` also searches Apple Notes when Notchi keeps its own notes elsewhere.",
                 properties: ["query", "limit"]),
            Part(member: EditNoteTool.toolName, actions: ["add_tag", "replace", "delete"], keepsAction: true,
                 copy: "To change a saved note: action=add_tag appends a #tag, replace rewrites its `text` (Markdown notes only), delete removes it after the user confirms. Find it by `query`; when several match, the result lists them, and you call again with `pick`.",
                 properties: ["query", "tag", "text", "pick"]),
        ],
        outro: "Never say a note was saved or changed until the result says so.",
        properties: [
            "text": ["type": "string", "description": "create: the complete note text, in the user's language. replace: the note's new text."],
            "query": ["type": "string", "description": "list: only notes whose title or text contains this; omit for the most recent. add_tag/replace/delete: text the note contains."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 10,
                      "description": "list: how many notes, 1 to 10. Default 5."],
            "tag": ["type": "string", "description": "add_tag: the tag, without #."],
            "pick": ["type": "integer", "minimum": 1, "description": "Which of several matches, from the list a previous call returned."],
        ])

    static let mail = Group(
        name: "mail",
        intro: "The user's Apple Mail.",
        parts: [
            Part(member: ReadMailTool.toolName, actions: ["unread", "search", "read"], keepsAction: true,
                 copy: "action=unread lists unread messages; action=search lists messages whose sender or subject contains `query`, then those from the last `days` days whose text contains it (an order or tracking number, an error message, an invoice number), with the line it was found in; action=read returns one message's text by `id`. Newest first.",
                 properties: ["query", "id", "limit", "days"]),
            Part(member: DraftMailTool.toolName, actions: ["draft"], keepsAction: false,
                 copy: "action=draft saves a draft in Mail's Drafts: a reply (`reply_to_id`) or a new message (`to`, `subject`), with `body` in the language and tone the user asked for. It is never sent; the user reviews and sends it.",
                 properties: ["body", "reply_to_id", "to", "subject"]),
        ],
        outro: "",
        properties: [
            "query": ["type": "string", "description": "search: text in the sender, subject or message body."],
            "id": ["type": "string", "description": "read: the message id from a list."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 30, "description": "unread/search: how many, default 10."],
            "days": ["type": "integer", "minimum": 1, "maximum": 365,
                     "description": "search: how far back the message text is searched. Default 30; widen it for \"last March\", \"上个月\"."],
            "body": ["type": "string", "description": "draft: the message text."],
            "reply_to_id": ["type": "string", "description": "draft: reply to this inbox message (id from a list)."],
            "to": ["type": "string", "description": "draft, new message: the recipient address."],
            "subject": ["type": "string", "description": "draft, new message: the subject."],
        ])

    static let files = Group(
        name: "files",
        intro: "Files in the user's Downloads, Desktop and Documents folders on this Mac.",
        parts: [
            Part(member: ListFilesTool.toolName, actions: ["list"], keepsAction: false,
                 copy: "action=list finds files, most recently changed first, with size and date (\"the latest PDF in Downloads\", \"that contract on my Desktop\"); it searches subfolders when `query` or `content` is given. Use `content` when they describe what is IN the file (\"the screenshot with the 快充 times\"): it searches the text inside documents and the text macOS recognized in screenshots and photos. It matches exact words, so put other wordings in `content_any`: synonyms and the term in Chinese and English, e.g. 押金 → [\"押金\", \"保证金\", \"deposit\"]. Use folder=all when unsure where it is.",
                 properties: ["folder", "query", "content", "content_any", "kind", "limit"]),
            Part(member: ReadFileTool.toolName, actions: ["read"], keepsAction: false,
                 copy: "action=read returns the text of one PDF or text file, or the text in an image, by `path`: one action=list gave, or one the user names inside those folders. Other folders cannot be read.",
                 properties: ["path"]),
        ],
        outro: "",
        properties: [
            "folder": ["type": "string", "enum": ["downloads", "desktop", "documents", "all"],
                       "description": "list: which folder; all searches the three."],
            "query": ["type": "string", "description": "list: only files whose name contains this."],
            "content": ["type": "string",
                        "description": "list: words that appear inside the file, including text in a screenshot. Several words must all appear."],
            "content_any": ["type": "array", "items": ["type": "string"], "maxItems": 10,
                            "description": "list: alternative wordings of what is inside the file; a file matches if it contains any one."],
            "kind": ["type": "string", "enum": ["pdf", "image", "text", "any"],
                     "description": "list: only this kind of file. Default any."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 50,
                      "description": "list: how many, 1 to 50. Default 15."],
            "path": ["type": "string", "description": "read: the file's path, e.g. ~/Downloads/report.pdf."],
        ])

    static let memory = Group(
        name: "memory",
        intro: "Your memory folder: Markdown files you keep across conversations on this Mac.",
        parts: [
            Part(member: MemoryListTool.toolName, actions: ["list"], keepsAction: false,
                 copy: "action=list lists the files with size and last update. The prompt already shows each file's opening lines, so call it only when it says there are more; with no memory folder in the prompt, the folder is empty.",
                 properties: []),
            Part(member: MemoryReadTool.toolName, actions: ["read"], keepsAction: false,
                 copy: "action=read returns one `file` in full, when its opening lines suggest it holds what the answer needs, or before rewriting it.",
                 properties: ["file"]),
            Part(member: MemoryWriteTool.toolName, actions: ["write"], keepsAction: false,
                 copy: "action=write creates or replaces a `file` with `content`: whatever will help you later, in any shape — who the user is, their work and projects, people they mention, preferences, things they asked you to remember. \(memoryOrganizationRules) `content` replaces the whole file, so read the file first when adding to it. Do not save passwords, account numbers, health or financial details unless they ask. Then answer as usual; mention the save only if they asked for it.",
                 properties: ["file", "content"]),
            Part(member: MemoryDeleteTool.toolName, actions: ["delete"], keepsAction: false,
                 copy: "action=delete removes a file when the user asks you to forget what it holds, or when it is no longer true or useful; to drop part of a file, rewrite it instead.",
                 properties: ["file"]),
        ],
        outro: "",
        properties: [
            "file": ["type": "string", "description": "The file name, e.g. \"projects.md\"."],
            "content": ["type": "string", "description": "write: the file's full new text, Markdown."],
        ])

    static let clipboard = Group(
        name: "clipboard",
        intro: "The user's clipboard.",
        parts: [
            Part(member: "read_clipboard", actions: ["read"], keepsAction: false,
                 copy: "action=read returns the text on it now, when the user refers to \"this\", \"what I copied\", or content that is not already in the conversation.",
                 properties: []),
            Part(member: ClipboardHistoryTool.toolName, actions: ["history"], keepsAction: false,
                 copy: "action=history lists text they copied recently on this Mac (up to the last 50, newest first, with when and from which app), for something copied earlier (\"the link I copied\", \"那段我刚复制的报错\").",
                 properties: ["query", "limit"]),
            Part(member: CopyToClipboardTool.toolName, actions: ["copy"], keepsAction: false,
                 copy: "action=copy puts `text` on the clipboard, replacing what is there, when they ask to copy something (\"复制到剪贴板\"); pass exactly the text to paste.",
                 properties: ["text"]),
        ],
        outro: "",
        properties: [
            "query": ["type": "string", "description": "history: only copies containing this text."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 50,
                      "description": "history: how many, 1 to 50. Default 10."],
            "text": ["type": "string", "description": "copy: exactly what to paste."],
        ])
}

extension ToolInvocation {
    /// The tool that runs for this call: the group member for a grouped call.
    var capability: String { ToolCatalog.member(of: name, input: input) }
}

// MARK: - load_tools

/// Which held-back tools a run has loaded so far, in load order. Shared by the
/// registry and its `load_tools`, and read on every turn.
final class ToolLoadout: @unchecked Sendable {
    let held: [String]
    private var order: [String] = []
    private let lock = NSLock()

    init(held: [String]) { self.held = held }

    var loaded: [String] { lock.lock(); defer { lock.unlock() }; return order }

    func isHeld(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return held.contains(name) && !order.contains(name)
    }

    /// Loads the held names among `names`; returns the ones newly loaded.
    @discardableResult
    func load(_ names: [String]) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var added: [String] = []
        for name in names where held.contains(name) && !order.contains(name) {
            order.append(name)
            added.append(name)
        }
        return added
    }
}

/// `load_tools`: puts held-back tools on the wire for the rest of this run.
struct LoadToolsTool: NotchTool {
    static let toolName = "load_tools"
    let name = toolName
    let description: String
    let schema: [String: Any]
    let loadout: ToolLoadout

    init(loadout: ToolLoadout, summaries: [String: String] = [:]) {
        self.loadout = loadout
        let lines = loadout.held.map { "- \($0): \(summaries[$0] ?? ToolCatalog.summary(of: $0) ?? $0)" }
        description = """
        Adds tools you do not have yet. When the request needs one of these, call \
        load_tools first with the ones it needs; they can be called from your next step:
        \(lines.joined(separator: "\n"))
        """
        schema = [
            "type": "object",
            "properties": [
                "tools": ["type": "array", "items": ["type": "string", "enum": loadout.held],
                          "description": "The tools to add."],
            ],
            "required": ["tools"],
        ]
    }

    func execute(_ input: [String: Any]) async throws -> String {
        let asked = (input["tools"] as? [String]) ?? (input["tools"] as? String).map { [$0] } ?? []
        let unknown = asked.filter { !loadout.held.contains($0) }
        let added = loadout.load(asked)
        let ready = asked.filter { loadout.held.contains($0) }
        guard !ready.isEmpty else {
            return "Error: give tools from this list: \(loadout.held.joined(separator: ", "))."
        }
        var out = "Loaded \(ready.joined(separator: ", ")). Call them now."
        if !unknown.isEmpty { out += " Not available: \(unknown.joined(separator: ", "))." }
        let guide = notchToolStances(for: Set(added))
        if !guide.isEmpty { out += "\n\nHow to use them:\n" + guide }
        return out
    }
}
