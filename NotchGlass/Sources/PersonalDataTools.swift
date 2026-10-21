import AppKit
import Contacts
import EventKit
import Foundation
import MapKit
import Photos
import Vision

// Read-only tools over the user's own Calendar, Reminders and notes, so Ask can
// answer "when am I free tomorrow" or "what's still open this week" without the
// Lab's shell tool. Each asks for its permission the first time it runs.

/// Shared formatting for the three tools: local wall-clock times, which is what
/// the user means and what the model is asked to quote back.
private enum PersonalDataFormat {
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd EEE"
        return f.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func dayAndTime(_ date: Date) -> String { "\(day(date)) \(time(date))" }

    /// `YYYY-MM-DD` in local time, or nil.
    static func parseDay(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(raw.prefix(10)))
    }

    static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return s?.isEmpty == false ? s : nil
    }
}

/// The user's Calendar events in a date range.
struct ReadCalendarTool: NotchTool {
    static let toolName = "read_calendar"
    let name = toolName
    let description = """
    Lists the user's Apple Calendar events in a date range, read on this Mac. \
    Call for questions about their schedule: what's on a day, when they are \
    free, when a meeting is. Give `from` as a local YYYY-MM-DD (call \
    current_datetime first if "today" is unclear) and `days` for the length.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "from": ["type": "string", "description": "First day, local YYYY-MM-DD. Omit for today."],
            "days": ["type": "integer", "minimum": 1, "maximum": 31,
                     "description": "How many days from `from`, 1 to 31. Default 1."],
            "query": ["type": "string", "description": "Only events whose title, location or notes contain this text."],
        ],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        let cal = Calendar.current
        let start = cal.startOfDay(for: PersonalDataFormat.parseDay(input["from"] as? String) ?? Date())
        let days = min(max(PersonalDataFormat.int(input["days"]) ?? 1, 1), 31)
        guard let end = cal.date(byAdding: .day, value: days, to: start) else { return "Error: bad range." }
        let query = PersonalDataFormat.string(input["query"])?.lowercased()

        let store = EKEventStore()
        let granted = (try? await PermissionPromptGate.during { try await store.requestFullAccessToEvents() }) ?? false
        guard granted else {
            return "Error: Calendar access is off for Notchi. The user can turn it on in System Settings → Privacy & Security → Calendars."
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        var events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        if let query {
            events = events.filter {
                [$0.title, $0.location, $0.notes].compactMap { $0?.lowercased() }
                    .contains { $0.contains(query) }
            }
        }
        let range = days == 1 ? PersonalDataFormat.day(start)
            : "\(PersonalDataFormat.day(start)) to \(PersonalDataFormat.day(end.addingTimeInterval(-1)))"
        guard !events.isEmpty else { return "No events \(query == nil ? "" : "matching that ")on \(range)." }

        var lines = ["Events, \(range) (local time):"]
        var currentDay = ""
        for event in events.prefix(200) {
            let day = PersonalDataFormat.day(event.startDate)
            if day != currentDay {
                lines.append(day)
                currentDay = day
            }
            let when = event.isAllDay ? "all day"
                : "\(PersonalDataFormat.time(event.startDate))–\(PersonalDataFormat.time(event.endDate))"
            var line = "- \(when) \(event.title ?? "(no title)")"
            if let location = event.location, !location.isEmpty { line += " · \(location)" }
            if let calendar = event.calendar?.title { line += " [\(calendar)]" }
            if let id = event.eventIdentifier { line += " · id \(id)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

/// The user's reminders: open ones (optionally only those due soon), or ones
/// completed recently.
struct ReadRemindersTool: NotchTool {
    static let toolName = "read_reminders"
    let name = toolName
    let description = """
    Lists the user's Apple Reminders, read on this Mac. By default the open \
    (not completed) ones, overdue included; `due_within_days` keeps only those \
    due within that many days from now; `completed_days` instead lists what \
    they completed in that many past days; `list` keeps one Reminders list \
    ("groceries", "买菜", "Work"). Each line names its list, and the result ends \
    with the user's list names. Call for "what's left to do", "what's due this \
    week", "what did I finish", "what's on my shopping list".
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "due_within_days": ["type": "integer", "minimum": 0, "maximum": 365,
                                "description": "Open reminders due from now through this many days (0 = today). Overdue ones are included. Omit for every open reminder."],
            "completed_days": ["type": "integer", "minimum": 1, "maximum": 90,
                               "description": "List reminders completed in this many past days instead of open ones."],
            "query": ["type": "string", "description": "Only reminders whose title or notes contain this text."],
            "list": ["type": "string", "description": "Only this Reminders list, as the user names it."],
        ],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        let store = EKEventStore()
        let granted = (try? await PermissionPromptGate.during { try await store.requestFullAccessToReminders() }) ?? false
        guard granted else { return "Error: \(L("reminders.error.permission"))" }
        let listNames = "Lists: " + store.calendars(for: .reminder).map(\.title).joined(separator: ", ")
        var lists: [EKCalendar]? = nil
        if let name = PersonalDataFormat.string(input["list"]) {
            guard let list = RemindersService.list(named: name, in: store) else {
                return "There is no reminder list called \"\(name)\". \(listNames)"
            }
            lists = [list]
        }
        let cal = Calendar.current
        let now = Date()
        let query = PersonalDataFormat.string(input["query"])?.lowercased()

        let completedDays = PersonalDataFormat.int(input["completed_days"])
        let predicate: NSPredicate
        var heading: String
        if let completedDays {
            let since = cal.date(byAdding: .day, value: -min(max(completedDays, 1), 90), to: now) ?? now
            predicate = store.predicateForCompletedReminders(withCompletionDateStarting: since,
                                                             ending: now, calendars: lists)
            heading = "Completed in the last \(completedDays) days:"
        } else if let within = PersonalDataFormat.int(input["due_within_days"]) {
            let endDay = cal.date(byAdding: .day, value: min(max(within, 0), 365) + 1,
                                  to: cal.startOfDay(for: now)) ?? now
            predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil,
                                                              ending: endDay, calendars: lists)
            heading = within == 0 ? "Open, due today or overdue:" : "Open, due within \(within) days or overdue:"
        } else {
            predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil,
                                                              ending: nil, calendars: lists)
            heading = "Open reminders:"
        }

        let found: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
        }
        var reminders = found
        if let query {
            reminders = reminders.filter {
                [$0.title, $0.notes].compactMap { $0?.lowercased() }.contains { $0.contains(query) }
            }
        }
        if let list = lists?.first { heading = "\(list.title) — " + heading }
        guard !reminders.isEmpty else { return String(heading.dropLast()) + ": none.\n" + listNames }

        func due(_ r: EKReminder) -> Date? { r.dueDateComponents.flatMap { cal.date(from: $0) } }
        if completedDays != nil {
            reminders.sort { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
        } else {
            // Dated first, soonest first; dateless after.
            reminders.sort { (due($0) ?? .distantFuture) < (due($1) ?? .distantFuture) }
        }
        var lines = [heading + " (local time)"]
        for r in reminders.prefix(200) {
            var line = "- \(r.title ?? "(no title)")"
            if completedDays != nil, let done = r.completionDate {
                line += " · done \(PersonalDataFormat.dayAndTime(done))"
            } else if let date = due(r) {
                let hasTime = r.dueDateComponents?.hour != nil
                line += " · due \(hasTime ? PersonalDataFormat.dayAndTime(date) : PersonalDataFormat.day(date))"
                if date < now { line += " (overdue)" }
            }
            if let list = r.calendar?.title { line += " [\(list)]" }
            line += " · id \(r.calendarItemIdentifier)"
            lines.append(line)
        }
        if reminders.count > 200 { lines.append("…and \(reminders.count - 200) more.") }
        lines.append(listNames)
        return lines.joined(separator: "\n")
    }
}

/// `manage_reminder`: complete, reschedule or delete one of the user's
/// reminders. Deleting waits on a Confirm card (`confirm`); a completed or
/// rescheduled reminder is marked on the answer like a filed one (`mark`).
struct ManageReminderTool: NotchTool {
    static let toolName = "manage_reminder"
    let name = toolName
    let description = """
    Changes one of the user's existing Apple Reminders: action=complete marks it \
    done, action=reschedule moves it to a new local `due` (YYYY-MM-DDTHH:MM), \
    action=delete removes it after the user confirms, action=move puts it in \
    another Reminders `list`, action=rename changes its `title` and keeps its \
    time, list and repeat. Identify it by `id` from \
    read_reminders, or by `query` (text in its title). If several match, the \
    result lists them with ids; call again with the right id. For "cancel the \
    reminder" use delete. Never say it changed until the result says so.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["complete", "reschedule", "delete", "move", "rename"],
                       "description": "What to do with the reminder."],
            "list": ["type": "string", "description": "move only: the list it goes to, as the user names it."],
            "title": ["type": "string", "description": "rename only: the new title."],
            "id": ["type": "string", "description": "The reminder's id from read_reminders."],
            "query": ["type": "string", "description": "Text in the reminder's title, when there is no id."],
            "due": ["type": "string", "description": "reschedule only: the new local time, YYYY-MM-DDTHH:MM."],
            "time_zone": ["type": "string", "description": "reschedule only: when the user gives the new time on another place's clock (\"10am Japan time\"), that IANA zone, e.g. Asia/Tokyo, with `due` on that clock."],
        ],
        "required": ["action"],
    ]

    let confirm: @Sendable (String) async throws -> Bool
    let mark: @Sendable (String?) async -> Void

    func execute(_ input: [String: Any]) async throws -> String {
        guard let action = PersonalDataFormat.string(input["action"]),
              ["complete", "reschedule", "delete", "move", "rename"].contains(action) else {
            return "Error: action must be complete, reschedule, delete, move or rename."
        }
        let store = EKEventStore()
        let granted = (try? await PermissionPromptGate.during { try await store.requestFullAccessToReminders() }) ?? false
        guard granted else { return "Error: \(L("reminders.error.permission"))" }

        let reminder: EKReminder
        if let id = PersonalDataFormat.string(input["id"]) {
            guard let found = store.calendarItem(withIdentifier: id) as? EKReminder else {
                return "Error: no reminder has id \(id). Call reminders action=list for current ids."
            }
            reminder = found
        } else if let query = PersonalDataFormat.string(input["query"])?.lowercased() {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            let open: [EKReminder] = await withCheckedContinuation { cont in
                store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
            }
            let matches = open.filter { ($0.title ?? "").lowercased().contains(query) }
            guard !matches.isEmpty else { return "No open reminder's title contains \"\(query)\"." }
            guard matches.count == 1 else {
                return "Several reminders match; call again with one id:\n"
                    + matches.prefix(20).map { "- \($0.title ?? "") · id \($0.calendarItemIdentifier)" }
                        .joined(separator: "\n")
            }
            reminder = matches[0]
        } else {
            return "Error: give the reminder's id or a query."
        }
        let title = reminder.title ?? ""
        var zone: TimeZone?

        switch action {
        case "complete":
            reminder.isCompleted = true
        case "rename":
            guard let newTitle = PersonalDataFormat.string(input["title"]) else { return "Error: give the new title." }
            reminder.title = newTitle
        case "move":
            guard let name = PersonalDataFormat.string(input["list"]) else { return "Error: give the list to move it to." }
            guard let list = RemindersService.list(named: name, in: store) else {
                return "There is no reminder list called \"\(name)\". Lists: "
                    + store.calendars(for: .reminder).map(\.title).joined(separator: ", ")
            }
            reminder.calendar = list
        case "reschedule":
            if let name = PersonalDataFormat.string(input["time_zone"]) {
                guard let found = TimeZone(identifier: name) else {
                    return "Error: time_zone \"\(name)\" is not an IANA time zone such as Asia/Tokyo."
                }
                zone = found
            }
            guard let raw = PersonalDataFormat.string(input["due"]),
                  let due = Self.parseDue(raw, in: zone ?? .current) else {
                return "Error: give the new due time as YYYY-MM-DDTHH:MM in the user's local time."
            }
            guard due > Date() else { return "Error: that time is already past." }
            reminder.dueDateComponents = RemindersService.dueComponents(due, in: zone)
            reminder.alarms?.forEach { reminder.removeAlarm($0) }
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        default:
            guard try await confirm(title) else {
                return "The user did not confirm. The reminder was not deleted. Do not retry."
            }
            do {
                try store.remove(reminder, commit: true)
            } catch {
                return "Error: \(error.localizedDescription)"
            }
            return "Deleted the reminder \"\(title)\"."
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
        let external = reminder.calendarItemExternalIdentifier
        await mark(external.map(RemindersService.deepLink(externalID:)))
        if action == "complete" { return "Marked \"\(title)\" as done." }
        if action == "move" { return "Moved \"\(title)\" to the \"\(reminder.calendar?.title ?? "")\" list." }
        if action == "rename" { return "Renamed \"\(title)\" to \"\(reminder.title ?? "")\"; its time, list and repeat are unchanged." }
        let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        var there = ""
        if let due, let zone, zone != .current {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = zone
            f.dateFormat = "yyyy-MM-dd HH:mm"
            there = " (\(f.string(from: due)) in \(zone.identifier))"
        }
        return "Moved \"\(title)\" to \(due.map(PersonalDataFormat.dayAndTime) ?? "the new time") this Mac's time\(there)."
    }

    /// Local wall-clock `YYYY-MM-DDTHH:MM` (or with a space), or a full ISO
    /// stamp.
    private static func parseDue(_ raw: String, in zone: TimeZone = .current) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = format
            if let date = f.date(from: raw) { return date }
        }
        return ISO8601DateFormatter().date(from: raw)
    }
}

/// `manage_event`: move, edit or delete one of the user's Calendar events.
/// Deleting waits on a Confirm card.
struct ManageEventTool: NotchTool {
    static let toolName = "manage_event"
    let name = toolName
    let description = """
    Changes an existing event in the user's Apple Calendar: action=move gives it \
    a new local `start` (YYYY-MM-DDTHH:MM) and keeps its length, action=update \
    changes its `title` or `location`, action=delete removes it after the user \
    confirms. Identify it by `id` from read_calendar, or by `query` (text in its \
    title) within the next 60 days. If several match, the result lists them \
    with ids. For a repeating event, span=future changes this and every later \
    one; without it only this one changes — ask the user which they mean. \
    Never say it changed until the result says so.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["move", "update", "delete"]],
            "id": ["type": "string", "description": "The event's id from read_calendar."],
            "query": ["type": "string", "description": "Text in the event's title, when there is no id."],
            "start": ["type": "string", "description": "move: the new local start, YYYY-MM-DDTHH:MM."],
            "title": ["type": "string", "description": "update: the new title."],
            "location": ["type": "string", "description": "update: the new location."],
            "time_zone": ["type": "string", "description": "move: the IANA time zone `start` is written in, when it is not this Mac's (America/Los_Angeles)."],
            "span": ["type": "string", "enum": ["this", "future"],
                     "description": "A repeating event: this one only (default) or this and all later ones."],
        ],
        "required": ["action"],
    ]

    let confirm: @Sendable (String) async throws -> Bool

    func execute(_ input: [String: Any]) async throws -> String {
        guard let action = PersonalDataFormat.string(input["action"]),
              ["move", "update", "delete"].contains(action) else {
            return "Error: action must be move, update or delete."
        }
        let store = EKEventStore()
        let granted = (try? await PermissionPromptGate.during { try await store.requestFullAccessToEvents() }) ?? false
        guard granted else {
            return "Error: Calendar access is off for Notchi. The user can turn it on in System Settings → Privacy & Security → Calendars."
        }
        let event: EKEvent
        if let id = PersonalDataFormat.string(input["id"]) {
            guard let found = store.event(withIdentifier: id) else {
                return "Error: no event has id \(id). Call calendar action=list for current ids."
            }
            event = found
        } else if let query = PersonalDataFormat.string(input["query"])?.lowercased() {
            let start = Calendar.current.startOfDay(for: Date())
            let end = Calendar.current.date(byAdding: .day, value: 60, to: start) ?? start
            let matches = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
                .filter { ($0.title ?? "").lowercased().contains(query) }
            guard !matches.isEmpty else { return "No event in the next 60 days has \"\(query)\" in its title." }
            guard matches.count == 1 else {
                return "Several events match; call again with one id:\n" + matches.prefix(20).map {
                    "- \(PersonalDataFormat.dayAndTime($0.startDate)) \($0.title ?? "") · id \($0.eventIdentifier ?? "")"
                }.joined(separator: "\n")
            }
            event = matches[0]
        } else {
            return "Error: give the event's id or a query."
        }
        let title = event.title ?? ""
        let span: EKSpan = PersonalDataFormat.string(input["span"]) == "future" ? .futureEvents : .thisEvent
        let repeating = event.hasRecurrenceRules
        let spanNote = !repeating ? "" : span == .futureEvents
            ? " This and every later occurrence changed."
            : " It repeats; only this occurrence changed (span=future changes the later ones too)."

        switch action {
        case "move":
            var zone = TimeZone.current
            if let name = PersonalDataFormat.string(input["time_zone"]) {
                guard let found = TimeZone(identifier: name) else {
                    return "Error: time_zone \"\(name)\" is not an IANA time zone such as America/Los_Angeles."
                }
                zone = found
                event.timeZone = found
            }
            guard let raw = PersonalDataFormat.string(input["start"]), let start = Self.parse(raw, in: zone) else {
                return "Error: give the new start as YYYY-MM-DDTHH:MM in the user's local time."
            }
            let length = event.endDate.timeIntervalSince(event.startDate)
            event.startDate = start
            event.endDate = start.addingTimeInterval(length)
        case "update":
            let newTitle = PersonalDataFormat.string(input["title"])
            let newLocation = PersonalDataFormat.string(input["location"])
            guard newTitle != nil || newLocation != nil else { return "Error: give a new title or location." }
            if let newTitle { event.title = newTitle }
            if let newLocation { event.location = newLocation }
        default:
            guard try await confirm("\(title) · \(PersonalDataFormat.dayAndTime(event.startDate))") else {
                return "The user did not confirm. The event was not deleted. Do not retry."
            }
            do { try store.remove(event, span: span, commit: true) } catch {
                return "Error: \(error.localizedDescription)"
            }
            return "Deleted \"\(title)\".\(spanNote)"
        }
        do { try store.save(event, span: span, commit: true) } catch {
            return "Error: \(error.localizedDescription)"
        }
        return "Updated \"\(event.title ?? title)\": \(PersonalDataFormat.dayAndTime(event.startDate))–\(PersonalDataFormat.time(event.endDate))"
            + (event.location.map { " · \($0)" } ?? "") + " (this Mac's time).\(spanNote)"
    }

    private static func parse(_ raw: String, in zone: TimeZone = .current) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = format
            if let date = f.date(from: raw) { return date }
        }
        return ISO8601DateFormatter().date(from: raw)
    }
}

/// `schedule_action`: run a shell command once, some minutes from now — "mute
/// for an hour, then unmute". A command `ShellRisk` flags is confirmed when
/// it is scheduled; the wait lives in the app and ends with it.
struct ScheduleActionTool: NotchTool {
    static let toolName = "schedule_action"
    let name = toolName
    let description = """
    Runs one shell command on this Mac once, `minutes` from now (1 to 1440) — \
    to undo something later ("mute for an hour, then unmute") or do it at a set \
    time. A risky command is confirmed by the user now. It runs only while the app stays \
    open. Use run_shell for anything to do right away.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "command": ["type": "string", "description": "The zsh command to run later."],
            "minutes": ["type": "integer", "minimum": 1, "maximum": 1440],
        ],
        "required": ["command", "minutes"],
    ]

    let schedule: @Sendable (_ command: String, _ minutes: Int) async throws -> String

    func execute(_ input: [String: Any]) async throws -> String {
        guard let command = PersonalDataFormat.string(input["command"]) else { return "Error: give the command." }
        guard let minutes = PersonalDataFormat.int(input["minutes"]), (1...1440).contains(minutes) else {
            return "Error: minutes must be 1 to 1440."
        }
        return try await schedule(command, minutes)
    }
}

/// `account_usage`: the Notchi Balance — what is left and what this month
/// cost, by model. `fetch` reads the gateway (`NotchModel.accountUsageReport`).
struct AccountUsageTool: NotchTool {
    static let toolName = "account_usage"
    let name = toolName
    let description = """
    Reads the user's Notchi Balance: credit left, today's spend and cap, and \
    what this month cost on Notchi's models, by model. Call for "how much have I \
    spent", "how much is left". Spending on the user's own API keys is billed \
    by those providers and is not here.
    """
    let schema: [String: Any] = ["type": "object", "properties": [String: Any]()]
    let fetch: @Sendable () async -> String
    func execute(_ input: [String: Any]) async throws -> String { await fetch() }
}

/// `recent_projects`: the folders the user last ran agent tasks in, newest
/// first (`AgentFolderMRU`), and opening one in Finder.
struct RecentProjectsTool: NotchTool {
    static let toolName = "recent_projects"
    let name = toolName
    let description = """
    Lists the project folders the user most recently ran agent tasks in, newest \
    first. Call for "that project", "the last project", "open my project \
    folder". Pass `open` (1 = newest) to open that folder in Finder.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "open": ["type": "integer", "minimum": 1, "description": "Open this one of the list in Finder (1 = newest)."],
        ],
    ]
    let folders: @Sendable () async -> [URL]
    func execute(_ input: [String: Any]) async throws -> String {
        let list = await folders()
        guard !list.isEmpty else { return "No agent task has been run in a project folder yet." }
        if let n = PersonalDataFormat.int(input["open"]) {
            guard list.indices.contains(n - 1) else { return "Error: there are only \(list.count) folders." }
            let folder = list[n - 1]
            let ok = await MainActor.run { NSWorkspace.shared.open(folder) }
            let path = (folder.path as NSString).abbreviatingWithTildeInPath
            return ok ? "Opened \(path) in Finder." : "Couldn't open \(path); it may have moved."
        }
        return "Recent project folders, newest first:\n" + list.enumerated().map {
            "\($0.offset + 1). \(($0.element.path as NSString).abbreviatingWithTildeInPath)"
        }.joined(separator: "\n")
    }
}

/// `travel_time`: how long a trip takes, leaving now or at a given time, from
/// Apple Maps (MapKit), with no key and no location permission — both ends are
/// named places.
struct TravelTimeTool: NotchTool {
    static let toolName = "travel_time"
    let name = toolName
    let description = """
    Estimates how long a trip takes between two named places using Apple \
    Maps: distance and minutes by car, on foot or by public transit. Leaving \
    now uses current traffic; for a trip at another time ("Friday at 6pm", \
    "to be there by 9") pass leave_at or arrive_by, and Maps uses the traffic \
    expected then. Where Apple Maps has no data (abroad, on a Mac set to the \
    China region) the trip is timed on OpenStreetMap, without traffic or \
    transit; the result says so. Pass place names or addresses as the user wrote them; \
    add the city when it is clear from the conversation. For the user's own \
    places write just home, work or here ("家", "公司", "这里" work too): \
    home and work come from their contact card or an address they gave \
    before, here from this Mac's location. If the result says an address is \
    unknown, ask for it, then call again with that address and save_as.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "from": ["type": "string", "description": "Start place or address."],
            "to": ["type": "string", "description": "Destination place or address."],
            "mode": ["type": "string", "enum": ["driving", "walking", "transit"],
                     "description": "Default driving (also right for a taxi)."],
            "save_as": ["type": "string", "enum": ["home", "work"],
                        "description": "When the user just told you their home or work address: keep the `from` address under this name for next time."],
            "leave_at": ["type": "string", "description": "Leaving at this local time, YYYY-MM-DDTHH:MM. Omit for now."],
            "arrive_by": ["type": "string", "description": "Arriving by this local time, YYYY-MM-DDTHH:MM. Give this or leave_at, not both."],
            "time_zone": ["type": "string", "description": "Time zone of leave_at / arrive_by when it is not this Mac's, e.g. America/Mexico_City."],
        ],
        "required": ["from", "to"],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        guard let from = PersonalDataFormat.string(input["from"]),
              let to = PersonalDataFormat.string(input["to"]) else { return "Error: give from and to." }
        let mode = PersonalDataFormat.string(input["mode"]) ?? "driving"
        let zone = PersonalDataFormat.string(input["time_zone"]).flatMap(TimeZone.init(identifier:)) ?? .current
        var leave: Date?
        var arrive: Date?
        // Given both, the time the user leaves wins: it is the one they set.
        if let raw = PersonalDataFormat.string(input["leave_at"]) {
            guard let date = Self.parseTime(raw, in: zone) else { return "Error: leave_at must be YYYY-MM-DDTHH:MM." }
            leave = date
        } else if let raw = PersonalDataFormat.string(input["arrive_by"]) {
            guard let date = Self.parseTime(raw, in: zone) else { return "Error: arrive_by must be YYYY-MM-DDTHH:MM." }
            arrive = date
        }
        // A time already past (a minute or two of slack aside) is timed as now.
        if let date = leave ?? arrive, date < Date().addingTimeInterval(-120) {
            return "Error: \(Self.stamp(date, zone)) has already passed. Omit leave_at for a trip leaving now."
        }
        if let kind = PersonalDataFormat.string(input["save_as"]).flatMap(UserPlaces.Kind.init(rawValue:)),
           UserPlaces.kind(of: from) == nil {
            UserPlaces.save(from, as: kind)
        }
        // Each end is searched near the other: "Avenida Benito Juárez" alone
        // finds a street in Beijing. The start goes first; when it cannot be
        // found alone, the destination is found first and the start near it.
        // Apple Maps on a Mac set to the China region searches and routes only
        // inside China: "1 Infinite Loop, Cupertino" comes back as a garage in
        // Suzhou, "Gare de Lyon" as nothing. Where Apple finds nothing, or a
        // pair implausibly far apart, or no route, OpenStreetMap is asked.
        let osm = { (abroadOnly: Bool) in
            await Self.openStreetMap(from: from, to: to, mode: mode, timed: leave != nil || arrive != nil, abroadOnly: abroadOnly)
        }
        var start: MKMapItem?
        var failure: String?
        switch await Self.resolve(from) {
        case .found(let item): start = item
        case .unknown(let message): failure = message
        }
        let end: MKMapItem
        switch await Self.resolve(to, near: start?.placemark.coordinate) {
        case .found(let item): end = item
        case .unknown(let message):
            if Self.mayAskOpenStreetMap(from, to), let answer = await osm(false) { return answer }
            return message
        }
        if start == nil {
            guard UserPlaces.kind(of: from) == nil,
                  case .found(let item) = await Self.resolve(from, near: end.placemark.coordinate) else {
                if Self.mayAskOpenStreetMap(from, to), let answer = await osm(false) { return answer }
                return failure ?? "Apple Maps could not find \"\(from)\"."
            }
            start = item
        }
        guard let start else { return failure ?? "Apple Maps could not find \"\(from)\"." }
        let apart = CLLocation(latitude: start.placemark.coordinate.latitude, longitude: start.placemark.coordinate.longitude)
            .distance(from: CLLocation(latitude: end.placemark.coordinate.latitude, longitude: end.placemark.coordinate.longitude))
        // Worse than nothing found: "Berlin Hauptbahnhof" comes back as Beijing
        // Railway Station, its destination as a shop nearby, and the trip
        // looks fine. A name with no CJK in it that Apple places in China is
        // checked on OpenStreetMap, and timed there when it lies abroad.
        if Self.mayAskOpenStreetMap(from, to),
           Self.placedInChina(from, start) || Self.placedInChina(to, end),
           let answer = await osm(true) { return answer }
        if apart > 1_000_000 {
            if let answer = await osm(false) { return answer }
            return "The two places are \(Int(apart / 1000)) km apart: \"\(from)\" was found as \(Self.describe(start)) and "
                + "\"\(to)\" as \(Self.describe(end)). If that is not what the user meant, add the city to the name and call again."
        }
        let request = MKDirections.Request()
        request.source = start
        request.destination = end
        if let arrive { request.arrivalDate = arrive } else { request.departureDate = leave ?? Date() }
        request.transportType = mode == "walking" ? .walking : mode == "transit" ? .transit : .automobile
        do {
            let eta = try await MKDirections(request: request).calculateETA()
            let minutes = Int((eta.expectedTravelTime / 60).rounded())
            let km = eta.distance / 1000
            let when: String
            if leave == nil, arrive == nil {
                when = "leaving now"
            } else {
                // Maps fills in the other end of the trip; both are stated so
                // the answer names the time it was timed for.
                when = "leaving \(Self.stamp(eta.expectedDepartureDate, zone)), arriving about \(Self.stamp(eta.expectedArrivalDate, zone))"
                    + (zone == .current ? "" : " (\(zone.identifier) time)")
                    + (mode == "driving" ? ", with the traffic expected then" : "")
            }
            return String(format: "%@ → %@ by %@: about %d minutes, %.1f km (Apple Maps, %@).",
                          start.name ?? from, end.name ?? to, mode, minutes, km, when)
        } catch {
            if let answer = await osm(false) { return answer }
            return "Apple Maps could not route that (\(error.localizedDescription))."
        }
    }

    // MARK: OpenStreetMap, where Apple Maps has no data

    /// A missing home or work address is the user's to give, not a place to
    /// look up; everything else may be tried on OpenStreetMap.
    private static func mayAskOpenStreetMap(_ from: String, _ to: String) -> Bool {
        [from, to].allSatisfy { UserPlaces.kind(of: $0) == nil || UserPlaces.kind(of: $0) == .here }
    }

    /// Apple placed a name with no CJK script in it inside China: likely the
    /// China-region Maps mismatch, worth checking on OpenStreetMap.
    private static func placedInChina(_ query: String, _ item: MKMapItem) -> Bool {
        guard UserPlaces.kind(of: query) == nil, item.placemark.isoCountryCode == "CN" else { return false }
        return !query.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value)
        }
    }

    /// The trip on OpenStreetMap: Nominatim finds each end, the FOSSGIS OSRM
    /// servers time it by car or on foot. No live or expected traffic, and no
    /// transit, which the result says. nil when either end or the route can't
    /// be had there either.
    /// `abroadOnly`: only when an end lies outside China, so a Latin-script
    /// name for a place that really is in China stays with Apple Maps.
    private static func openStreetMap(from: String, to: String, mode: String, timed: Bool,
                                      abroadOnly: Bool = false) async -> String? {
        guard mode != "transit" else {
            return "Apple Maps on this Mac has no data there, and OpenStreetMap has no transit timetables. "
                + "Call travel_time again with mode driving or walking, and tell the user it is not a transit time."
        }
        guard let a = await osmPoint(from) else { return nil }
        if abroadOnly, a.country == "cn", let probe = await osmPoint(to), probe.country == "cn" { return nil }
        // "Terminal 1" alone is anywhere; looked for near the start first.
        var b: OSMPoint
        if let nearby = await osmPoint(to, near: a) {
            b = nearby
        } else {
            guard let anywhere = await osmPoint(to) else {
                // The start is known abroad, so Apple's answer is no fallback.
                return "OpenStreetMap found \"\(from)\" as \(a.name) but could not find \"\(to)\" (Apple Maps on this Mac "
                    + "has no data there). Call again with a fuller or plainer name for it, such as \"BER Terminal 1\" or the street address."
            }
            // Found only far away: say where, rather than time a trip to the
            // wrong "Terminal 1".
            let km = CLLocation(latitude: a.lat, longitude: a.lon)
                .distance(from: CLLocation(latitude: anywhere.lat, longitude: anywhere.lon)) / 1000
            if km > 300 {
                return "OpenStreetMap found \"\(to)\" only as \(anywhere.name), \(Int(km)) km from \(a.name). "
                    + "If that is not what the user meant, call again with a fuller name, such as the place's full name and city."
            }
            b = anywhere
        }
        let profile = mode == "walking" ? "routed-foot" : "routed-car"
        let path = String(format: "%.6f,%.6f;%.6f,%.6f", a.lon, a.lat, b.lon, b.lat)
        guard let url = URL(string: "https://routing.openstreetmap.de/\(profile)/route/v1/driving/\(path)?overview=false"),
              let json = await osmFetch(url) as? [String: Any],
              json["code"] as? String == "Ok",
              let route = (json["routes"] as? [[String: Any]])?.first,
              let seconds = (route["duration"] as? NSNumber)?.doubleValue,
              let meters = (route["distance"] as? NSNumber)?.doubleValue else { return nil }
        let minutes = Int((seconds / 60).rounded())
        let caveat = timed ? "no traffic: the time of day the user named is not counted" : "no live traffic"
        return String(format: "%@ → %@ by %@: about %d minutes, %.1f km (OpenStreetMap, %@; Apple Maps on this Mac has no data there). "
                        + "Tell the user it is an OpenStreetMap estimate without traffic.",
                      a.name, b.name, mode, minutes, meters / 1000, caveat)
    }

    private struct OSMPoint { let name: String; let lat: Double; let lon: Double; var country = "" }

    private static func osmPoint(_ query: String, near: OSMPoint? = nil) async -> OSMPoint? {
        if UserPlaces.kind(of: query) == .here {
            guard let location = await LocationService.shared.current() else { return nil }
            return OSMPoint(name: "current location", lat: location.coordinate.latitude, lon: location.coordinate.longitude, country: "?")
        }
        var url = URLComponents(string: "https://nominatim.openstreetmap.org/search")!
        url.queryItems = [
            URLQueryItem(name: "q", value: query), URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "limit", value: "1"), URLQueryItem(name: "accept-language", value: "en"),
            URLQueryItem(name: "addressdetails", value: "1"),
        ]
        if let near {
            // About 150 km each way, and only results inside it.
            let box = String(format: "%.4f,%.4f,%.4f,%.4f", near.lon - 2, near.lat + 1.4, near.lon + 2, near.lat - 1.4)
            url.queryItems! += [URLQueryItem(name: "viewbox", value: box), URLQueryItem(name: "bounded", value: "1")]
        }
        guard let found = (await osmFetch(url.url!) as? [[String: Any]])?.first,
              let lat = Double(found["lat"] as? String ?? ""), let lon = Double(found["lon"] as? String ?? "") else { return nil }
        // "Gare de Lyon, Place Louis-Armand, Paris 12e, …, France": the first
        // part and the country are enough to say where it landed.
        var parts = (found["display_name"] as? String ?? query).components(separatedBy: ", ")
        // A house number comes first on its own ("15, Rue de la Paix, …").
        if parts.count > 2, parts[0].allSatisfy(\.isNumber) { parts[1] = "\(parts[0]) \(parts[1])"; parts.removeFirst() }
        let name = parts.count > 1 ? "\(parts[0]), \(parts[parts.count - 1])" : parts.first ?? query
        let country = ((found["address"] as? [String: Any])?["country_code"] as? String ?? "").lowercased()
        return OSMPoint(name: name, lat: lat, lon: lon, country: country)
    }

    /// Both services ask for an identifying User-Agent and light use; one
    /// request per end and one per route is that.
    private static func osmFetch(_ url: URL) async -> Any? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Notchi/1.0 (macOS; travel_time)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private enum Resolved {
        case found(MKMapItem)
        case unknown(String)
    }

    /// Wall-clock `YYYY-MM-DDTHH:MM` (or with a space) in `zone`.
    private static func parseTime(_ raw: String, in zone: TimeZone) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = format
            if let date = f.date(from: raw) { return date }
        }
        return nil
    }

    /// "Fri 2026-10-16 18:00" in `zone`.
    private static func stamp(_ date: Date, _ zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "EEE yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// A place name for Apple Maps, or the user's own home, work or current
    /// location. Never searches Maps for "home": that finds a business
    /// called Home, or a hotel, and the trip is timed from there.
    private static func resolve(_ query: String, near: CLLocationCoordinate2D? = nil) async -> Resolved {
        guard let kind = UserPlaces.kind(of: query) else {
            if let near, let item = await place(query, near: near) { return .found(item) }
            if let item = await place(query) { return .found(item) }
            return .unknown("Apple Maps could not find \"\(query)\".")
        }
        if kind == .here {
            guard let location = await LocationService.shared.current() else {
                return .unknown("This Mac's location is unknown (Location access for Notchi is off). Ask the user where they are.")
            }
            let item = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
            item.name = "current location"
            return .found(item)
        }
        guard let address = await UserPlaces.address(for: kind) else {
            return .unknown("The user's \(kind.rawValue) address is unknown: not on their own contact card and not given before. "
                + "Ask them for it, then call travel_time again with that address and save_as=\(kind.rawValue).")
        }
        guard let item = await place(address) else {
            return .unknown("Apple Maps could not find the saved \(kind.rawValue) address \"\(address)\". Ask the user for it again.")
        }
        item.name = "\(kind.rawValue) (\(address))"
        return .found(item)
    }

    /// `near` limits the search to about 150 km around that point. Also finds
    /// the place a Maps link's card draws its map around.
    static func place(_ query: String, near: CLLocationCoordinate2D? = nil) async -> MKMapItem? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let near {
            request.region = MKCoordinateRegion(center: near, latitudinalMeters: 300_000, longitudinalMeters: 300_000)
            if #available(macOS 15.0, *) { request.regionPriority = .required }
        }
        return try? await MKLocalSearch(request: request).start().mapItems.first
    }

    /// "Benito Juárez Airport, Mexico City, Mexico", for a result that names
    /// where a search actually landed.
    private static func describe(_ item: MKMapItem) -> String {
        let mark = item.placemark
        return [item.name, mark.locality, mark.country].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The user's own places for `travel_time`: home and work from the "me" card
/// in Contacts, else an address they gave before (kept on this Mac); here is
/// this Mac's location.
enum UserPlaces {
    enum Kind: String { case home, work, here }

    private static let words: [Kind: Set<String>] = [
        .home: ["home", "my home", "my place", "my house", "my apartment", "家", "家里", "家裡", "我家", "回家",
                "自宅", "家から", "집", "우리 집", "casa", "mi casa", "maison", "chez moi"],
        .work: ["work", "office", "my office", "公司", "单位", "單位", "办公室", "辦公室", "会社", "オフィス",
                "회사", "직장", "trabajo", "oficina", "bureau", "travail"],
        .here: ["here", "current location", "my location", "where i am", "这里", "這裡", "这儿", "当前位置", "目前位置",
                "ここ", "現在地", "여기", "aquí", "ici"],
    ]

    static func kind(of query: String) -> Kind? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return words.first { $0.value.contains(q) }?.key
    }

    private static func key(_ kind: Kind) -> String { "places.\(kind.rawValue)" }

    static func save(_ address: String, as kind: Kind) {
        UserDefaults.standard.set(address.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key(kind))
    }

    /// The contact card's address first: it is what the user keeps current.
    static func address(for kind: Kind) async -> String? {
        if let card = await contactCardAddress(kind) { return card }
        let saved = UserDefaults.standard.string(forKey: key(kind)) ?? ""
        return saved.isEmpty ? nil : saved
    }

    private static func contactCardAddress(_ kind: Kind) async -> String? {
        let store = CNContactStore()
        guard (try? await PermissionPromptGate.during { try await store.requestAccess(for: .contacts) }) == true else { return nil }
        let keys = [CNContactPostalAddressesKey as CNKeyDescriptor]
        guard let me = try? store.unifiedMeContactWithKeys(toFetch: keys) else { return nil }
        let label = kind == .home ? CNLabelHome : CNLabelWork
        guard let postal = me.postalAddresses.first(where: { $0.label == label })?.value else { return nil }
        let line = CNPostalAddressFormatter.string(from: postal, style: .mailingAddress)
            .replacingOccurrences(of: "\n", with: ", ")
        return line.isEmpty ? nil : line
    }
}

/// `read_photos`: recent photos from the user's Photos library, each with
/// what it shows (Vision labels) and the text in it, read on this Mac.
struct ReadPhotosTool: NotchTool {
    static let toolName = "read_photos"
    let name = toolName
    let description = """
    Reads photos from the user's Photos library taken in a date range, newest \
    first: when, what each shows (labels like whiteboard, receipt, document) \
    and the text in it, recognised on this Mac. Call for "the whiteboard photo \
    from last week", "the receipt I photographed". Give `from` (local \
    YYYY-MM-DD) and `days`; `query` keeps only photos whose labels or text \
    contain it. For a screenshot the user describes by what it says ("the \
    同程 screenshot with the 快充 times"), pass `query` WITHOUT `from`: that \
    searches the text of every screenshot from the last 12 months; several \
    words must all appear. Add scope=all to search ordinary photos too (a \
    passport or ID card photographed with the camera).
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "from": ["type": "string", "description": "First day, local YYYY-MM-DD. Omit for 7 days ago."],
            "days": ["type": "integer", "minimum": 1, "maximum": 31, "description": "Days from `from`. Default 7."],
            "query": ["type": "string", "description": "Keep photos whose labels or text contain this (e.g. whiteboard, 白板, receipt)."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 8, "description": "Photos to read, 1 to 8. Default 4."],
            "scope": ["type": "string", "enum": ["screenshots", "all"],
                      "description": "Text search without `from`: screenshots only (default) or every photo."],
        ],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        let status = await PermissionPromptGate.during { await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited else {
            return "Error: Photos access is off for Notchi. The user can allow it in System Settings → Privacy & Security → Photos."
        }
        if input["from"] == nil, let query = PersonalDataFormat.string(input["query"]) {
            return await Self.searchScreenshots(query,
                                                limit: min(max(PersonalDataFormat.int(input["limit"]) ?? 4, 1), 8),
                                                everyPhoto: PersonalDataFormat.string(input["scope"]) == "all")
        }
        let cal = Calendar.current
        let start = cal.startOfDay(for: PersonalDataFormat.parseDay(input["from"] as? String)
            ?? cal.date(byAdding: .day, value: -7, to: Date()) ?? Date())
        let days = min(max(PersonalDataFormat.int(input["days"]) ?? 7, 1), 31)
        let end = cal.date(byAdding: .day, value: days, to: start) ?? Date()
        let limit = min(max(PersonalDataFormat.int(input["limit"]) ?? 4, 1), 8)
        let query = PersonalDataFormat.string(input["query"])?.lowercased()

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@ AND creationDate < %@",
                                        PHAssetMediaType.image.rawValue, start as NSDate, end as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 60
        let assets = PHAsset.fetchAssets(with: options)
        var out: [String] = []
        var scanned = 0
        for i in 0..<assets.count where out.count < limit && scanned < 40 {
            scanned += 1
            let asset = assets.object(at: i)
            guard let image = await Self.image(for: asset) else { continue }
            let (labels, text) = Self.read(image)
            if let query, !(labels.joined(separator: " ") + " " + text).lowercased().contains(query) { continue }
            let when = asset.creationDate.map(PersonalDataFormat.dayAndTime) ?? "?"
            var line = "## Photo \(when)"
            if !labels.isEmpty { line += "\nShows: \(labels.joined(separator: ", "))" }
            line += text.isEmpty ? "\nNo text in it." : "\nText:\n\(String(text.prefix(2000)))"
            out.append(line)
        }
        guard !out.isEmpty else {
            return "No photos \(query == nil ? "" : "matching \"\(query!)\" ")from \(PersonalDataFormat.day(start)) for \(days) days."
        }
        return out.joined(separator: "\n\n")
    }

    /// A 1600-pixel rendition, downloaded from iCloud if needed.
    private static func image(for asset: PHAsset) async -> CGImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        return await withCheckedContinuation { cont in
            var resumed = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1600, height: 1600),
                                                  contentMode: .aspectFit, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded, !resumed else { return }
                resumed = true
                cont.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }

    /// Screenshots from the last 12 months whose text holds every word of
    /// `query`, newest first. Each screenshot's text is recognised once and
    /// kept in `ScreenshotTextCache`; a call spends at most a minute on new
    /// ones and says when it stopped early, so asking again picks up there.
    private static func searchScreenshots(_ query: String, limit: Int, everyPhoto: Bool) async -> String {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let options = PHFetchOptions()
        let since = (Calendar.current.date(byAdding: .month, value: -12, to: Date()) ?? Date()) as NSDate
        options.predicate = everyPhoto
            ? NSPredicate(format: "mediaType == %d AND creationDate >= %@", PHAssetMediaType.image.rawValue, since)
            : NSPredicate(format: "mediaType == %d AND (mediaSubtypes & %d) != 0 AND creationDate >= %@",
                          PHAssetMediaType.image.rawValue, PHAssetMediaSubtype.photoScreenshot.rawValue, since)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: options)
        let noun = everyPhoto ? "photos" : "screenshots"
        guard assets.count > 0 else { return "There are no \(noun) in Photos from the last 12 months." }
        let cache = ScreenshotTextCache.shared
        let deadline = Date().addingTimeInterval(60)
        var out: [String] = []
        var checked = 0
        var stoppedEarly = false
        for i in 0..<assets.count where out.count < limit {
            let asset = assets.object(at: i)
            let stamp = asset.modificationDate ?? asset.creationDate ?? .distantPast
            var text = cache.text(for: asset.localIdentifier, modified: stamp)
            if text == nil {
                guard Date() < deadline else { stoppedEarly = true; break }
                guard let image = await image(for: asset) else { continue }
                text = recognizeText(image)
                cache.store(text ?? "", for: asset.localIdentifier, modified: stamp)
            }
            checked += 1
            guard let found = text, !found.isEmpty else { continue }
            let lowered = found.lowercased()
            guard words.allSatisfy(lowered.contains) else { continue }
            let when = asset.creationDate.map(PersonalDataFormat.dayAndTime) ?? "?"
            out.append("## \(everyPhoto ? "Photo" : "Screenshot") \(when)\nText:\n\(String(found.prefix(2000)))")
        }
        cache.save()
        var reply = out.isEmpty
            ? "None contains \"\(query)\" among the \(checked) of \(assets.count) \(noun) from the last 12 months checked so far."
            : out.joined(separator: "\n\n")
        if stoppedEarly {
            reply += "\n\n(Stopped after \(checked) of \(assets.count) \(noun) to answer in time; call again with the same query to continue from there.)"
        }
        return reply
    }

    /// The recognised text alone — what a screenshot search needs.
    private static func recognizeText(_ image: CGImage) -> String {
        let recognize = VNRecognizeTextRequest()
        recognize.recognitionLevel = .accurate
        recognize.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
        try? VNImageRequestHandler(cgImage: image).perform([recognize])
        return (recognize.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Vision's top scene labels and the recognised text.
    private static func read(_ image: CGImage) -> (labels: [String], text: String) {
        let classify = VNClassifyImageRequest()
        let recognize = VNRecognizeTextRequest()
        recognize.recognitionLevel = .accurate
        recognize.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
        try? VNImageRequestHandler(cgImage: image).perform([classify, recognize])
        let labels = (classify.results ?? []).filter { $0.confidence > 0.3 }.prefix(4).map(\.identifier)
        let text = (recognize.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        return (Array(labels), text)
    }
}

/// `read_mail`: the user's Mail inbox — unread messages, a search by sender
/// or subject, or one message's text.
struct ReadMailTool: NotchTool {
    static let toolName = "read_mail"
    let name = toolName
    let description = """
    Reads the user's Apple Mail inbox: action=unread lists unread messages, \
    action=search lists messages whose sender or subject contains `query`, \
    then messages from the last `days` days (default 30, up to 365) whose text \
    contains it (an order or \
    tracking number, an error message, an invoice number), with the line it \
    was found in, \
    action=read returns one message's text by `id` from a list. Newest first.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["unread", "search", "read"]],
            "query": ["type": "string", "description": "search: text in the sender, subject or (last 30 days) message body."],
            "id": ["type": "string", "description": "read: the message id from a list."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 30, "description": "unread/search: how many, default 10."],
            "days": ["type": "integer", "minimum": 1, "maximum": 365,
                     "description": "search: how far back the message text is searched. Default 30; widen it for \"last March\", \"上个月\"."],
        ],
        "required": ["action"],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        let action = PersonalDataFormat.string(input["action"]) ?? "unread"
        if action == "read" {
            guard let id = PersonalDataFormat.string(input["id"]) else { return "Error: give the message id." }
            switch await MailService.read(id: id) {
            case .failure(let error): return "Error: \(error.errorDescription ?? "")"
            case .success(let m):
                let body = m.content.count > 6000 ? String(m.content.prefix(6000)) + "…" : m.content
                return "From: \(m.sender)\nSubject: \(m.subject)\nReceived: \(m.date)\n\n\(body)"
            }
        }
        let query = PersonalDataFormat.string(input["query"]) ?? ""
        if action == "search", query.isEmpty { return "Error: give the query." }
        let limit = min(max(PersonalDataFormat.int(input["limit"]) ?? 10, 1), 30)
        let days = min(max(PersonalDataFormat.int(input["days"]) ?? 30, 1), 365)
        switch await MailService.list(unread: action == "unread", query: query, limit: limit, days: days) {
        case .failure(let error): return "Error: \(error.errorDescription ?? "")"
        case .success(let rows):
            guard !rows.isEmpty else { return action == "unread" ? "No unread messages in the inbox." : "No message matches \"\(query)\"." }
            return rows.map { row in
                let found = row.snippet.isEmpty ? ""
                    : "\n  found in the text: …\(row.snippet.replacingOccurrences(of: "\n", with: " "))…"
                return "- \(row.date) · \(row.sender) · \(row.subject) · id \(row.id)\(found)"
            }.joined(separator: "\n")
        }
    }
}

/// `draft_mail`: save a reply (or a new message) to Mail's Drafts. Never sends.
struct DraftMailTool: NotchTool {
    static let toolName = "draft_mail"
    let name = toolName
    let description = """
    Saves an email draft in Apple Mail's Drafts — a reply to an inbox message \
    (`reply_to_id` from read_mail) or a new message (`to`, `subject`). It is \
    never sent: the user reviews and sends it. Write `body` in the language and \
    tone the user asked for.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "body": ["type": "string", "description": "The message text."],
            "reply_to_id": ["type": "string", "description": "Reply to this inbox message (id from read_mail)."],
            "to": ["type": "string", "description": "New message: the recipient address."],
            "subject": ["type": "string", "description": "New message: the subject."],
        ],
        "required": ["body"],
    ]

    let mark: @Sendable () async -> Void

    func execute(_ input: [String: Any]) async throws -> String {
        guard let body = PersonalDataFormat.string(input["body"]) else { return "Error: give the body." }
        let reply = PersonalDataFormat.string(input["reply_to_id"]) ?? ""
        let to = PersonalDataFormat.string(input["to"]) ?? ""
        if reply.isEmpty, to.isEmpty { return "Error: give reply_to_id, or to for a new message." }
        switch await MailService.draft(to: to, subject: PersonalDataFormat.string(input["subject"]) ?? "",
                                       body: body, replyID: reply) {
        case .failure(let error): return "Error: \(error.errorDescription ?? "")"
        case .success:
            await mark()
            return "Saved to Mail's Drafts. Not sent; the user reviews and sends it."
        }
    }
}

/// `edit_note`: tag or delete a note the user filed, wherever notes go
/// (`NoteDestination`). In the Markdown folder a note is one `## HH:MM`
/// entry of a day file; in Apple Notes it is the whole note. Deleting waits
/// on a Confirm card.
struct EditNoteTool: NotchTool {
    static let toolName = "edit_note"
    let name = toolName
    let description = """
    Changes a note the user saved: action=add_tag appends a #tag to it, \
    action=replace rewrites its text (Markdown notes only), action=delete \
    removes it after the user confirms. Find it by `query`, text it contains. \
    When several match, the result lists them; call again with `pick` (1-based). \
    Never say it changed until the result says so.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["add_tag", "replace", "delete"]],
            "query": ["type": "string", "description": "Text the note contains."],
            "tag": ["type": "string", "description": "add_tag: the tag, without #."],
            "text": ["type": "string", "description": "replace: the note's new text."],
            "pick": ["type": "integer", "minimum": 1, "description": "Which of several matches, from the list a previous call returned."],
        ],
        "required": ["action", "query"],
    ]

    let confirm: @Sendable (String) async throws -> Bool

    func execute(_ input: [String: Any]) async throws -> String {
        guard let action = PersonalDataFormat.string(input["action"]),
              ["add_tag", "replace", "delete"].contains(action),
              let query = PersonalDataFormat.string(input["query"]) else {
            return "Error: give action (add_tag, replace or delete) and query."
        }
        let pick = PersonalDataFormat.int(input["pick"])
        let tag = PersonalDataFormat.string(input["tag"])?
            .trimmingCharacters(in: CharacterSet(charactersIn: "#")).replacingOccurrences(of: " ", with: "")
        if action == "add_tag", tag?.isEmpty != false { return "Error: give the tag." }

        switch NoteDestination.current {
        case .markdownFolder:
            let found = await FileNotesService.findEntries(containing: query)
            guard let entry = Self.choose(found, pick: pick, label: { "\($0.day) \($0.time) \($0.text.prefix(60))" }) else {
                return Self.chooseMessage(found.map { "\($0.day) \($0.time) \($0.text.prefix(60))" }, query: query)
            }
            let newText: String?
            switch action {
            case "add_tag": newText = entry.text + " #" + (tag ?? "")
            case "replace":
                guard let text = PersonalDataFormat.string(input["text"]) else { return "Error: give the new text." }
                newText = text
            default:
                guard try await confirm(String(entry.text.prefix(120))) else {
                    return "The user did not confirm. The note was not deleted. Do not retry."
                }
                newText = nil
            }
            switch await FileNotesService.edit(entry, newText: newText) {
            case .success:
                return newText == nil ? "Deleted the note from \(entry.day) \(entry.time)."
                    : "Updated the note from \(entry.day) \(entry.time): \(newText!)"
            case .failure(let error):
                return "Error: \(error.errorDescription ?? "couldn't change the note.")"
            }
        case .appleNotes:
            guard action != "replace" else {
                return "Error: rewriting an Apple Notes note is not supported; add_tag or delete work."
            }
            let found: [(id: String, title: String)]
            switch await NotesService.findNotes(query: query) {
            case .success(let rows): found = rows
            case .failure(let error): return "Error: \(error.errorDescription ?? "couldn't read Apple Notes.")"
            }
            guard let note = Self.choose(found, pick: pick, label: { $0.title }) else {
                return Self.chooseMessage(found.map(\.title), query: query)
            }
            if action == "delete" {
                guard try await confirm(note.title) else {
                    return "The user did not confirm. The note was not deleted. Do not retry."
                }
            }
            switch await NotesService.edit(noteID: note.id, appendLine: action == "add_tag" ? "#" + (tag ?? "") : nil) {
            case .success:
                return action == "delete" ? "Deleted the note \"\(note.title)\"." : "Added #\(tag ?? "") to \"\(note.title)\"."
            case .failure(let error):
                return "Error: \(error.errorDescription ?? "couldn't change the note.")"
            }
        }
    }

    private static func choose<T>(_ found: [T], pick: Int?, label: (T) -> String) -> T? {
        if let pick { return found.indices.contains(pick - 1) ? found[pick - 1] : nil }
        return found.count == 1 ? found[0] : nil
    }

    private static func chooseMessage(_ labels: [String], query: String) -> String {
        guard !labels.isEmpty else { return "No note contains \"\(query)\"." }
        return "Several notes match; call again with pick:\n"
            + labels.prefix(15).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }
}

/// The user's notes, from wherever Notchi files them: Apple Notes, or the
/// Markdown folder when that is the note destination.
struct ReadNotesTool: NotchTool {
    static let toolName = "read_notes"
    let name = toolName
    let description = """
    Reads the user's notes on this Mac: the most recently edited ones, or those \
    containing `query`. Call when they ask about something they wrote down \
    ("what did I note about the trip", "my last few notes"). A `query` also \
    searches Apple Notes when Notchi keeps its own notes elsewhere; each \
    result says where it came from.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "Only notes whose title or text contains this. Omit for the most recent."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 10,
                      "description": "How many notes, 1 to 10. Default 5."],
        ],
    ]

    /// Per note, so a long note cannot crowd out the rest.
    private static let noteCharLimit = 3000

    func execute(_ input: [String: Any]) async throws -> String {
        let query = PersonalDataFormat.string(input["query"]) ?? ""
        let limit = min(max(PersonalDataFormat.int(input["limit"]) ?? 5, 1), 10)
        let notes: [NotesService.NoteText]
        switch NoteDestination.current {
        case .appleNotes:
            switch await NotesService.readNotes(query: query, limit: limit) {
            case .success(let found): notes = found
            case .failure(let error):
                return "Error: \(error.errorDescription ?? "couldn't read Apple Notes.")"
            }
        case .markdownFolder:
            notes = Self.markdownNotes(query: query, limit: limit)
            // Notchi files to Markdown here, but "my note 大理行程" is often
            // one the user keeps in Apple Notes. A search looks there too,
            // read only; the most-recent listing stays Notchi's own.
            if !query.isEmpty {
                var apple: [NotesService.NoteText] = []
                var appleError: String?
                switch await NotesService.readNotes(query: query, limit: limit) {
                case .success(let found): apple = found
                case .failure(let error): appleError = error.errorDescription ?? "couldn't read Apple Notes."
                }
                let own = Self.render(notes)
                let theirs = Self.render(apple)
                var parts: [String] = []
                if !own.isEmpty { parts.append("Notchi's notes (Markdown folder):\n\n" + own) }
                if !theirs.isEmpty { parts.append("Apple Notes (read only here):\n\n" + theirs) }
                if parts.isEmpty {
                    return "No notes contain \"\(query)\" in Notchi's notes"
                        + (appleError.map { ". Apple Notes could not be searched: \($0)" } ?? " or in Apple Notes.")
                }
                if let appleError { parts.append("(Apple Notes could not be searched: \(appleError))") }
                return parts.joined(separator: "\n\n")
            }
        }
        guard !notes.isEmpty else {
            return query.isEmpty ? "No notes found." : "No notes contain \"\(query)\"."
        }
        return Self.render(notes)
    }

    private static func render(_ notes: [NotesService.NoteText]) -> String {
        notes.map { note in
            var body = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.count > Self.noteCharLimit { body = String(body.prefix(Self.noteCharLimit)) + "…" }
            let when = note.modified.map { " (edited \(PersonalDataFormat.dayAndTime($0)))" } ?? ""
            return "## \(note.title)\(when)\n\(body)"
        }.joined(separator: "\n\n")
    }

    /// The Markdown folder's day files, newest first, each one a "note".
    private static func markdownNotes(query: String, limit: Int) -> [NotesService.NoteText] {
        let folder = URL(fileURLWithPath: FileNotesService.folderPath, isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var out: [NotesService.NoteText] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if !query.isEmpty, !text.localizedCaseInsensitiveContains(query) { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            out.append(.init(title: file.deletingPathExtension().lastPathComponent,
                             modified: modified, text: text))
            if out.count >= limit { break }
        }
        return out
    }
}

/// `recent_songs`: what the user played lately in the Music app, read through
/// AppleScript — each library track keeps its last played date and play count.
/// The first call raises the Automation prompt for Music; asking Music also
/// opens it when it is not running. Other players (NetEase, QQ Music) keep
/// their history to themselves.
struct RecentSongsTool: NotchTool {
    static let toolName = "recent_songs"
    let name = toolName
    let description = """
    Songs the user played recently in Apple's Music app, newest first, with \
    when each was last played and its play count. Call for "我最近听了什么歌", \
    "what was that song I played yesterday". Only the Music app's library; say \
    so when they use another player.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "days": ["type": "integer", "minimum": 1, "maximum": 90, "description": "How many days back. Default 7."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "How many songs. Default 20."],
        ],
    ]

    private static let queue = DispatchQueue(label: "com.notchglass.music-applescript")

    private struct Failure: Error {
        let message: String
    }

    func execute(_ input: [String: Any]) async throws -> String {
        let days = min(max((input["days"] as? NSNumber)?.intValue ?? 7, 1), 90)
        let limit = min(max((input["limit"] as? NSNumber)?.intValue ?? 20, 1), 50)
        let source = """
        tell application "Music"
            set cutoff to (current date) - (\(days) * days)
            set found to (every track of library playlist 1 whose played date > cutoff)
            set out to {}
            repeat with t in found
                set end of out to {name of t, artist of t, played date of t, played count of t}
            end repeat
            return out
        end tell
        """
        let result: Result<NSAppleEventDescriptor, Failure> = await withCheckedContinuation { cont in
            Self.queue.async {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    return cont.resume(returning: .failure(Failure(message: "Could not prepare the Music script.")))
                }
                // May raise the Automation prompt for Music: hold the panel.
                let value = PermissionPromptGate.automating("com.apple.Music") {
                    script.executeAndReturnError(&error)
                }
                if let error {
                    let number = error[NSAppleScript.errorNumber] as? Int ?? 0
                    if number == -1743 || number == -1744 {
                        return cont.resume(returning: .failure(Failure(message: "Notchi is not allowed to read Music. The user can allow it in System Settings → Privacy & Security → Automation.")))
                    }
                    return cont.resume(returning: .failure(Failure(message: error[NSAppleScript.errorMessage] as? String ?? "Music did not answer.")))
                }
                cont.resume(returning: .success(value))
            }
        }
        let list: NSAppleEventDescriptor
        switch result {
        case .failure(let failure): return failure.message
        case .success(let value): list = value
        }
        var songs: [(title: String, artist: String, played: Date, count: Int)] = []
        if list.numberOfItems > 0 {
            for i in 1...list.numberOfItems {
                guard let row = list.atIndex(i), row.numberOfItems == 4,
                      let played = row.atIndex(3)?.dateValue else { continue }
                songs.append((row.atIndex(1)?.stringValue ?? "", row.atIndex(2)?.stringValue ?? "",
                              played, Int(row.atIndex(4)?.int32Value ?? 0)))
            }
        }
        guard !songs.isEmpty else {
            return "No song in the Music library was played in the last \(days) days. Songs played in other apps (NetEase, QQ Music, Spotify) are not recorded here."
        }
        songs.sort { $0.played > $1.played }
        var lines = ["Played in the Music app in the last \(days) days, newest first:"]
        for song in songs.prefix(limit) {
            lines.append("- \(PersonalDataFormat.dayAndTime(song.played)) · \(song.title) — \(song.artist) · played \(song.count) times")
        }
        if songs.count > limit { lines.append("…and \(songs.count - limit) more.") }
        return lines.joined(separator: "\n")
    }
}

/// The text recognised in each screenshot, kept on this Mac so a later search
/// does not read the same screenshots again. Keyed by the Photos asset id and
/// dropped for an asset edited since. Never leaves the Mac.
final class ScreenshotTextCache: @unchecked Sendable {
    static let shared = ScreenshotTextCache()

    private struct Entry: Codable {
        var modified: Date
        var text: String
    }

    private let lock = NSLock()
    private var entries: [String: Entry]
    private var dirty = false
    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchi", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("screenshot-text.json")
    }()

    private init() {
        entries = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    func text(for id: String, modified: Date) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[id], abs(entry.modified.timeIntervalSince(modified)) < 1 else { return nil }
        return entry.text
    }

    func store(_ text: String, for id: String, modified: Date) {
        lock.lock(); defer { lock.unlock() }
        entries[id] = Entry(modified: modified, text: text)
        dirty = true
    }

    func save() {
        lock.lock()
        guard dirty, let data = try? JSONEncoder().encode(entries) else { lock.unlock(); return }
        dirty = false
        lock.unlock()
        try? data.write(to: fileURL, options: .atomic)
    }
}
