import EventKit
import Foundation

/// Why an event write failed, so the tool result can tell the model (and the
/// model the user) what to do about it.
enum CalendarError: LocalizedError {
    /// TCC denied Calendar access (or the user clicked "Don't Allow").
    case permissionDenied
    /// No calendar to file into (no Calendar account configured).
    case noCalendar
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Calendar access is off for Notchi. The user can turn it on in System Settings → Privacy & Security → Calendars."
        case .noCalendar:
            return "There is no calendar to add the event to. The user needs a calendar account in the Calendar app."
        case .saveFailed(let msg):
            return msg
        }
    }
}

/// Files events into Apple Calendar via EventKit, for `create_event`.
///
/// Asks for write-only access: Notchi adds events and never reads the user's
/// calendar, so it does not ask to see it. The jump back to the event is a
/// `ical://ekevent/` link, which Calendar opens on that event.
enum CalendarService {
    /// The live EventKit connection, rebuilt when the authorization status
    /// changes under it — the same reason `RemindersService.currentStore()`
    /// gives: a store keeps the grant it was created under for its lifetime.
    private static var _store = EKEventStore()
    private static var _storeStatus = EKEventStore.authorizationStatus(for: .event)
    private static let storeLock = NSLock()

    private static func currentStore() -> EKEventStore {
        storeLock.lock()
        defer { storeLock.unlock() }
        let status = EKEventStore.authorizationStatus(for: .event)
        if status != _storeStatus {
            _store = EKEventStore()
            _storeStatus = status
        }
        return _store
    }

    struct Draft: Sendable {
        var title: String
        var start: Date
        var end: Date
        var allDay: Bool
        var location: String?
        var notes: String?
        /// Minutes before the start to alert; nil for none. All-day events
        /// alert at 9:00 that day.
        var alertMinutes: Int? = 10
    }

    /// Save one event. On success the value is a link that opens it in
    /// Calendar, or nil when EventKit gave back no identifier (the event exists;
    /// the jump then opens Calendar itself).
    static func createEvent(_ draft: Draft,
                            completion: @escaping @MainActor (Result<String?, CalendarError>) -> Void) {
        let store = currentStore()
        store.requestWriteOnlyAccessToEvents { granted, _ in
            let result: Result<String?, CalendarError> =
                granted ? write(draft, store: store) : .failure(.permissionDenied)
            Task { @MainActor in completion(result) }
        }
    }

    static func deepLink(identifier: String) -> String {
        "ical://ekevent/\(identifier)?method=show&options=more"
    }

    private static func write(_ draft: Draft, store: EKEventStore) -> Result<String?, CalendarError> {
        guard let calendar = store.defaultCalendarForNewEvents else {
            return .failure(.noCalendar)
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.allDay
        if let location = draft.location, !location.isEmpty { event.location = location }
        if let notes = draft.notes, !notes.isEmpty { event.notes = notes }
        // An event the user asked for should tell them when it comes: Calendar
        // applies no default alert to events an app creates.
        if let minutes = draft.alertMinutes {
            let offset = draft.allDay ? 9 * 3600 : -Double(minutes * 60)
            event.addAlarm(EKAlarm(relativeOffset: offset))
        }
        do {
            try store.save(event, span: .thisEvent, commit: true)
            let id = event.calendarItemIdentifier
            return .success(id.isEmpty ? nil : deepLink(identifier: id))
        } catch {
            return .failure(.saveFailed(error.localizedDescription))
        }
    }
}
