import AppKit
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
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
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
    they completed in that many past days. Call for "what's left to do", \
    "what's due this week", "what did I finish".
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "due_within_days": ["type": "integer", "minimum": 0, "maximum": 365,
                                "description": "Open reminders due from now through this many days (0 = today). Overdue ones are included. Omit for every open reminder."],
            "completed_days": ["type": "integer", "minimum": 1, "maximum": 90,
                               "description": "List reminders completed in this many past days instead of open ones."],
            "query": ["type": "string", "description": "Only reminders whose title or notes contain this text."],
        ],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        guard granted else { return "Error: \(L("reminders.error.permission"))" }
        let cal = Calendar.current
        let now = Date()
        let query = PersonalDataFormat.string(input["query"])?.lowercased()

        let completedDays = PersonalDataFormat.int(input["completed_days"])
        let predicate: NSPredicate
        var heading: String
        if let completedDays {
            let since = cal.date(byAdding: .day, value: -min(max(completedDays, 1), 90), to: now) ?? now
            predicate = store.predicateForCompletedReminders(withCompletionDateStarting: since,
                                                             ending: now, calendars: nil)
            heading = "Completed in the last \(completedDays) days:"
        } else if let within = PersonalDataFormat.int(input["due_within_days"]) {
            let endDay = cal.date(byAdding: .day, value: min(max(within, 0), 365) + 1,
                                  to: cal.startOfDay(for: now)) ?? now
            predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil,
                                                              ending: endDay, calendars: nil)
            heading = within == 0 ? "Open, due today or overdue:" : "Open, due within \(within) days or overdue:"
        } else {
            predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil,
                                                              ending: nil, calendars: nil)
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
        guard !reminders.isEmpty else { return String(heading.dropLast()) + ": none." }

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
    action=delete removes it after the user confirms. Identify it by `id` from \
    read_reminders, or by `query` (text in its title). If several match, the \
    result lists them with ids; call again with the right id. For "cancel the \
    reminder" use delete. Never say it changed until the result says so.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["complete", "reschedule", "delete"],
                       "description": "What to do with the reminder."],
            "id": ["type": "string", "description": "The reminder's id from read_reminders."],
            "query": ["type": "string", "description": "Text in the reminder's title, when there is no id."],
            "due": ["type": "string", "description": "reschedule only: the new local time, YYYY-MM-DDTHH:MM."],
        ],
        "required": ["action"],
    ]

    let confirm: @Sendable (String) async throws -> Bool
    let mark: @Sendable (String?) async -> Void

    func execute(_ input: [String: Any]) async throws -> String {
        guard let action = PersonalDataFormat.string(input["action"]),
              ["complete", "reschedule", "delete"].contains(action) else {
            return "Error: action must be complete, reschedule or delete."
        }
        let store = EKEventStore()
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        guard granted else { return "Error: \(L("reminders.error.permission"))" }

        let reminder: EKReminder
        if let id = PersonalDataFormat.string(input["id"]) {
            guard let found = store.calendarItem(withIdentifier: id) as? EKReminder else {
                return "Error: no reminder has id \(id). Call read_reminders for current ids."
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

        switch action {
        case "complete":
            reminder.isCompleted = true
        case "reschedule":
            guard let raw = PersonalDataFormat.string(input["due"]),
                  let due = Self.parseDue(raw) else {
                return "Error: give the new due time as YYYY-MM-DDTHH:MM in the user's local time."
            }
            guard due > Date() else { return "Error: that time is already past." }
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
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
        let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        return "Moved \"\(title)\" to \(due.map(PersonalDataFormat.dayAndTime) ?? "the new time")."
    }

    /// Local wall-clock `YYYY-MM-DDTHH:MM` (or with a space), or a full ISO
    /// stamp.
    private static func parseDue(_ raw: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
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
    with ids. Never say it changed until the result says so.
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
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        guard granted else {
            return "Error: Calendar access is off for Notchi. The user can turn it on in System Settings → Privacy & Security → Calendars."
        }
        let event: EKEvent
        if let id = PersonalDataFormat.string(input["id"]) {
            guard let found = store.event(withIdentifier: id) else {
                return "Error: no event has id \(id). Call read_calendar for current ids."
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

        switch action {
        case "move":
            guard let raw = PersonalDataFormat.string(input["start"]), let start = Self.parse(raw) else {
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
            do { try store.remove(event, span: .thisEvent, commit: true) } catch {
                return "Error: \(error.localizedDescription)"
            }
            return "Deleted \"\(title)\"."
        }
        do { try store.save(event, span: .thisEvent, commit: true) } catch {
            return "Error: \(error.localizedDescription)"
        }
        return "Updated \"\(event.title ?? title)\": \(PersonalDataFormat.dayAndTime(event.startDate))–\(PersonalDataFormat.time(event.endDate))"
            + (event.location.map { " · \($0)" } ?? "") + "."
    }

    private static func parse(_ raw: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = format
            if let date = f.date(from: raw) { return date }
        }
        return ISO8601DateFormatter().date(from: raw)
    }
}

/// `schedule_action`: run a shell command once, some minutes from now — "mute
/// for an hour, then unmute". The command is confirmed when it is scheduled;
/// the wait lives in the app and ends with it.
struct ScheduleActionTool: NotchTool {
    static let toolName = "schedule_action"
    let name = toolName
    let description = """
    Runs one shell command on this Mac once, `minutes` from now (1 to 1440) — \
    to undo something later ("mute for an hour, then unmute") or do it at a set \
    time. The user confirms the command now. It runs only while the app stays \
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

/// `travel_time`: how long a trip takes now, from Apple Maps (MapKit), with
/// no key and no location permission — both ends are named places.
struct TravelTimeTool: NotchTool {
    static let toolName = "travel_time"
    let name = toolName
    let description = """
    Estimates how long a trip takes right now between two named places, with \
    current traffic, using Apple Maps: distance and minutes by car, on foot or \
    by public transit. Pass place names or addresses as the user wrote them; \
    add the city when it is clear from the conversation.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "from": ["type": "string", "description": "Start place or address."],
            "to": ["type": "string", "description": "Destination place or address."],
            "mode": ["type": "string", "enum": ["driving", "walking", "transit"],
                     "description": "Default driving (also right for a taxi)."],
        ],
        "required": ["from", "to"],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        guard let from = PersonalDataFormat.string(input["from"]),
              let to = PersonalDataFormat.string(input["to"]) else { return "Error: give from and to." }
        let mode = PersonalDataFormat.string(input["mode"]) ?? "driving"
        guard let start = await Self.place(from) else { return "Apple Maps could not find \"\(from)\"." }
        guard let end = await Self.place(to) else { return "Apple Maps could not find \"\(to)\"." }
        let request = MKDirections.Request()
        request.source = start
        request.destination = end
        request.departureDate = Date()
        request.transportType = mode == "walking" ? .walking : mode == "transit" ? .transit : .automobile
        do {
            let eta = try await MKDirections(request: request).calculateETA()
            let minutes = Int((eta.expectedTravelTime / 60).rounded())
            let km = eta.distance / 1000
            return String(format: "%@ → %@ by %@: about %d minutes, %.1f km (Apple Maps, leaving now).",
                          start.name ?? from, end.name ?? to, mode, minutes, km)
        } catch {
            return "Apple Maps could not route that (\(error.localizedDescription))."
        }
    }

    private static func place(_ query: String) async -> MKMapItem? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        return try? await MKLocalSearch(request: request).start().mapItems.first
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
    contain it.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "from": ["type": "string", "description": "First day, local YYYY-MM-DD. Omit for 7 days ago."],
            "days": ["type": "integer", "minimum": 1, "maximum": 31, "description": "Days from `from`. Default 7."],
            "query": ["type": "string", "description": "Keep photos whose labels or text contain this (e.g. whiteboard, 白板, receipt)."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 8, "description": "Photos to read, 1 to 8. Default 4."],
        ],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            return "Error: Photos access is off for Notchi. The user can allow it in System Settings → Privacy & Security → Photos."
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
    action=read returns one message's text by `id` from a list. Newest first.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["unread", "search", "read"]],
            "query": ["type": "string", "description": "search: text in the sender or subject."],
            "id": ["type": "string", "description": "read: the message id from a list."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 30, "description": "unread/search: how many, default 10."],
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
        switch await MailService.list(unread: action == "unread", query: query, limit: limit) {
        case .failure(let error): return "Error: \(error.errorDescription ?? "")"
        case .success(let rows):
            guard !rows.isEmpty else { return action == "unread" ? "No unread messages in the inbox." : "No message matches \"\(query)\"." }
            return rows.map { "- \($0.date) · \($0.sender) · \($0.subject) · id \($0.id)" }.joined(separator: "\n")
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
    ("what did I note about the trip", "my last few notes").
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
        }
        guard !notes.isEmpty else {
            return query.isEmpty ? "No notes found." : "No notes contain \"\(query)\"."
        }
        return notes.map { note in
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
