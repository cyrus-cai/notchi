import AppKit
import EventKit
import Foundation
import SwiftUI

// MARK: - Level

/// How often Notchi writes to the user without being asked (Settings → Chat).
/// Each level adds sources to the one before it and raises the daily limit.
///
///   - `minimal`: a reminder that is due, a calendar event about to start.
///   - `balanced`: also the things the user said they would do by a time
///     (`ProactiveEngine.considerFollowUp`).
///   - `frequent`: the same sources, checked in on sooner and more often.
enum ProactiveLevel: String, CaseIterable, Identifiable {
    case off, minimal, balanced, frequent

    var id: String { rawValue }
    var label: String { L("proactive.level.\(rawValue)") }

    /// Messages in any 24 hours, every source counted.
    var dailyCap: Int {
        switch self {
        case .off: return 0
        case .minimal: return 3
        case .balanced: return 6
        case .frequent: return 15
        }
    }

    /// The gap a follow-up keeps from the message before it. A due reminder or
    /// a starting event has a time of its own and is held to the cap only.
    var followUpGap: TimeInterval {
        self == .frequent ? 15 * 60 : 60 * 60
    }

    var followsUp: Bool { self == .balanced || self == .frequent }

    /// The lowest score Jev may give a message for it to be sent
    /// (`NoNoAccount.checkProactive`). A higher level sends more of what is
    /// due.
    var floor: Double {
        switch self {
        case .off: return 1
        case .minimal: return 0.6
        case .balanced: return 0.45
        case .frequent: return 0.3
        }
    }

    private static let key = "proactive.level"

    /// New installs start on `minimal`; an install that ran before this
    /// existed stays `off` until the user picks a level.
    static var stored: ProactiveLevel {
        get {
            let defaults = UserDefaults.standard
            if let raw = defaults.string(forKey: key), let level = ProactiveLevel(rawValue: raw) {
                return level
            }
            guard !OnboardingService.hasRunBefore else { return .off }
            defaults.set(ProactiveLevel.minimal.rawValue, forKey: key)
            return .minimal
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

// MARK: - Engine

/// Decides when Notchi writes first. Once a minute it collects what is due
/// (reminders, calendar events, stored follow-ups), drops what the level's
/// limits rule out, and hands one message to `NotchModel.postProactiveMessage`,
/// which writes it into the main thread and shows a line on the resting notch.
///
/// The limits come first and cost nothing. What passes them is put to Jev
/// (`NoNoAccount.checkProactive`): a score under the level's `floor` drops the
/// message for good, and no answer sends it. The lines themselves are not
/// written here: a reminder's and an event's are fixed sentences, and a
/// follow-up's was written when it was stored.
@MainActor
final class ProactiveEngine: ObservableObject {
    static let shared = ProactiveEngine()

    @Published var level: ProactiveLevel = .stored {
        didSet {
            guard level != oldValue else { return }
            ProactiveLevel.stored = level
            if level == .off { followUps = [] }
        }
    }

    weak var model: NotchModel?

    /// Something the user said they would do, with the line to send when its
    /// time comes.
    struct FollowUp: Codable, Equatable {
        var id = UUID()
        var text: String
        var fireAt: Date
    }

    private(set) var followUps: [FollowUp] = [] {
        didSet {
            guard followUps != oldValue else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(followUps), forKey: Self.followUpsKey)
        }
    }

    private static let followUpsKey = "proactive.followUps"
    private static let sentAtKey = "proactive.sentAt"
    private static let seenKey = "proactive.seen"

    private static let tickInterval: TimeInterval = 60
    /// How long before its start an event is announced.
    private static let eventLead: TimeInterval = 10 * 60
    /// How long after its time a message is still worth sending.
    private static let eventGrace: TimeInterval = 5 * 60
    private static let reminderGrace: TimeInterval = 30 * 60
    private static let followUpGrace: TimeInterval = 12 * 3600
    /// The hour reminders due today with no time are sent.
    private static let dayReminderHour = 9
    private static let followUpLimit = 50

    private var timer: Timer?
    private var ticking = false
    private var store = EKEventStore()
    private var storeStatus: [EKAuthorizationStatus] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.followUpsKey),
           let saved = try? JSONDecoder().decode([FollowUp].self, from: data) {
            followUps = saved
        }
    }

    /// Start the minute timer. Called once from `NotchModel.init`.
    func start(model: NotchModel) {
        self.model = model
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// When the last message was sent. Announcements and feature nudges keep
    /// an hour from it (`NotchModel.maybeShowAnnouncement`).
    var lastSentAt: Date? { sentDates.last }

    func sentRecently(within seconds: TimeInterval) -> Bool {
        guard let last = lastSentAt else { return false }
        return Date().timeIntervalSince(last) < seconds
    }

    // MARK: Tick

    private struct Candidate {
        let key: String
        let text: String
        /// The line on the resting notch.
        let glance: String
        let due: Date
        let expires: Date
        var followUp: UUID?

        /// `reminder`, `event` or `followup`: the key's own prefix, and what
        /// the gateway's `kind` takes.
        var kind: String {
            if followUp != nil { return "followup" }
            return key.hasPrefix("event:") ? "event" : "reminder"
        }
    }

    private func tick() {
        guard level != .off, !ticking, model != nil else { return }
        ticking = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.ticking = false }
            let now = Date()
            var candidates = await self.dueReminders(now: now) + self.dueEvents(now: now)
            if self.level.followsUp { candidates += self.dueFollowUps(now: now) }
            candidates.sort { $0.due < $1.due }

            var seen = self.seen
            defer { self.seen = seen }
            for candidate in candidates where seen[candidate.key] == nil {
                if candidate.expires < now {
                    seen[candidate.key] = now
                    if let id = candidate.followUp { self.followUps.removeAll { $0.id == id } }
                    continue
                }
                guard self.level != .off, self.allows(candidate, now: now) else { continue }
                // The main thread is taking a round: Jev is not asked for a
                // message that cannot be written yet.
                guard self.model?.canPostProactiveMessage == true else { return }
                if let score = await self.worth(candidate, now: now), score < self.level.floor {
                    seen[candidate.key] = now
                    if let id = candidate.followUp { self.followUps.removeAll { $0.id == id } }
                    continue
                }
                // A round is being written into the main thread: next minute.
                guard self.model?.postProactiveMessage(candidate.text, glance: candidate.glance) == true
                else { return }
                seen[candidate.key] = now
                self.sentDates = self.sentDates + [now]
                if let id = candidate.followUp { self.followUps.removeAll { $0.id == id } }
                // One message a minute at most.
                return
            }
        }
    }

    private func allows(_ candidate: Candidate, now: Date) -> Bool {
        let sent = sentDates
        guard sent.count < level.dailyCap else { return false }
        if candidate.followUp != nil, let last = sent.last,
           now.timeIntervalSince(last) < level.followUpGap {
            return false
        }
        return true
    }

    /// Jev's score for sending `candidate` now, or nil when there is none: no
    /// account, a failed request, or text that looks like a credential, which
    /// is never sent to be judged.
    private func worth(_ candidate: Candidate, now: Date) async -> Double? {
        let message = String(candidate.text.prefix(600))
        guard !ClipPrivacy.containsSecret(message) else { return nil }
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "EEEE HH:mm"
        return await NoNoAccount.shared.checkProactive(
            kind: candidate.kind, message: message,
            localTime: clock.string(from: now), sentToday: sentDates.count)?.probability
    }

    // MARK: Sent log

    /// The sends of the last 24 hours, oldest first.
    private var sentDates: [Date] {
        get {
            let all = UserDefaults.standard.array(forKey: Self.sentAtKey) as? [Date] ?? []
            return all.filter { Date().timeIntervalSince($0) < 24 * 3600 }
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.sentAtKey) }
    }

    /// What has been sent or let go, by candidate key, so the same reminder or
    /// event is never written twice. Entries older than a week are dropped.
    private var seen: [String: Date] {
        get {
            let all = UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: Date] ?? [:]
            return all.filter { Date().timeIntervalSince($0.value) < 7 * 24 * 3600 }
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.seenKey) }
    }

    // MARK: Sources

    /// The store to read with, rebuilt when either grant changed: a store keeps
    /// the access it was created under (`RemindersService.currentStore`).
    private func currentStore() -> EKEventStore {
        let status = [EKEventStore.authorizationStatus(for: .event),
                      EKEventStore.authorizationStatus(for: .reminder)]
        if status != storeStatus {
            store = EKEventStore()
            storeStatus = status
        }
        return store
    }

    /// Reads only with access already granted. The engine never raises a
    /// permission prompt; Settings asks when a level is picked
    /// (`requestAccess`).
    private func dueEvents(now: Date) -> [Candidate] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let store = currentStore()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-Self.eventGrace),
            end: now.addingTimeInterval(Self.eventLead), calendars: nil)
        let clock = DateFormatter()
        clock.timeStyle = .short
        clock.dateStyle = .none
        return store.events(matching: predicate).compactMap { event in
            guard !event.isAllDay, event.status != .canceled,
                  let start = event.startDate,
                  start > now.addingTimeInterval(-Self.eventGrace),
                  start <= now.addingTimeInterval(Self.eventLead),
                  event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined,
                  let title = Self.clean(event.title)
            else { return nil }
            let time = clock.string(from: start)
            let place = Self.clean(event.location).flatMap { $0.contains("://") ? nil : $0 }
            let text = place.map { L("proactive.event.at", title, time, $0) }
                ?? L("proactive.event", title, time)
            let id = event.eventIdentifier ?? title
            return Candidate(key: "event:\(id):\(Int(start.timeIntervalSince1970))",
                             text: text, glance: title, due: start.addingTimeInterval(-Self.eventLead),
                             expires: start.addingTimeInterval(Self.eventGrace))
        }
    }

    private func dueReminders(now: Date) async -> [Candidate] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return [] }
        let store = currentStore()
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: now)
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: min(dayStart, now.addingTimeInterval(-Self.reminderGrace)),
            ending: now.addingTimeInterval(60), calendars: nil)
        // Titles and dates only cross the continuation: `EKReminder` is not
        // sendable.
        struct Due { let id: String; let title: String; let date: Date; let timed: Bool }
        let found: [Due] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { reminders in
                cont.resume(returning: (reminders ?? []).compactMap { reminder in
                    guard let parts = reminder.dueDateComponents,
                          let date = Calendar.current.date(from: parts),
                          let title = Self.clean(reminder.title) else { return nil }
                    return Due(id: reminder.calendarItemIdentifier, title: title,
                               date: date, timed: parts.hour != nil)
                })
            }
        }
        var out: [Candidate] = []
        for due in found where due.timed && due.date <= now
            && due.date > now.addingTimeInterval(-Self.reminderGrace) {
            out.append(Candidate(key: "reminder:\(due.id):\(Int(due.date.timeIntervalSince1970))",
                                 text: L("proactive.reminder", due.title), glance: due.title,
                                 due: due.date, expires: due.date.addingTimeInterval(Self.reminderGrace)))
        }
        // Reminders due today with no time: one message for all of them.
        let dayTitles = found.filter { !$0.timed && cal.isDate($0.date, inSameDayAs: now) }
            .map(\.title)
        if !dayTitles.isEmpty,
           let sendAt = cal.date(bySettingHour: Self.dayReminderHour, minute: 0, second: 0, of: now),
           now >= sendAt, let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) {
            let shown = Array(dayTitles.prefix(8))
            let text = shown.count == 1
                ? L("proactive.dueToday.one", shown[0])
                : L("proactive.dueToday.many", ListFormatter.localizedString(byJoining: shown))
            out.append(Candidate(key: "reminders-day:\(Int(dayStart.timeIntervalSince1970))",
                                 text: text, glance: shown[0], due: sendAt, expires: dayEnd))
        }
        return out
    }

    private func dueFollowUps(now: Date) -> [Candidate] {
        followUps.filter { $0.fireAt <= now }.map {
            Candidate(key: "followup:\($0.id.uuidString)", text: $0.text, glance: $0.text,
                      due: $0.fireAt, expires: $0.fireAt.addingTimeInterval(Self.followUpGrace),
                      followUp: $0.id)
        }
    }

    private static func clean(_ text: String?) -> String? {
        let line = text?.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? nil : line
    }

    // MARK: Access

    /// Ask for Calendar and Reminders read access, from Settings when a level
    /// is picked. Either one refused just leaves that source out.
    func requestAccess() {
        Task {
            let store = EKEventStore()
            if EKEventStore.authorizationStatus(for: .reminder) != .fullAccess {
                _ = try? await PermissionPromptGate.during { try await store.requestFullAccessToReminders() }
            }
            if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
                _ = try? await PermissionPromptGate.during { try await store.requestFullAccessToEvents() }
            }
        }
    }

    // MARK: Follow-ups

    /// After an Ask round: when the user's message names a future time and the
    /// answer filed nothing for it, ask `service` whether the message states
    /// something they mean to do by then, and store the line to send at that
    /// time. One request, on the model that answers background questions.
    func considerFollowUp(question: String, answer: String, filedSomething: Bool, service: AIService) {
        guard level.followsUp, !filedSomething, !(service is StubAIService) else { return }
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...600).contains(asked.count), RemindersService.futureDate(in: asked) != nil
        else { return }
        let now = Date()
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "yyyy-MM-dd HH:mm EEEE"
        let prompt = "Now: \(clock.string(from: now)) (\(TimeZone.current.identifier))\n\n"
            + "User: \(asked)\n\nAssistant: \(String(answer.prefix(600)))"
        Task { [weak self] in
            var reply = ""
            do {
                let chunks = RequestAudit.$purpose.withValue("followup") {
                    NoNoRequestContext.$current.withValue(
                        NoNoRequestContext(surface: NoNoRequestContext.suggest)
                    ) {
                        service.stream(system: followUpSystemPrompt,
                                       messages: [ChatMessage(role: "user", content: prompt)])
                    }
                }
                for try await chunk in chunks { reply += chunk }
            } catch {
                return
            }
            guard let self, self.level.followsUp,
                  let parsed = Self.parseFollowUp(reply, now: Date()) else { return }
            guard !self.followUps.contains(where: { $0.text == parsed.text }) else { return }
            self.followUps = Array((self.followUps + [parsed]).suffix(Self.followUpLimit))
        }
    }

    /// `followUpSystemPrompt`'s reply: nil for NONE, a time already past or
    /// more than 60 days out, or anything off the format.
    static func parseFollowUp(_ reply: String, now: Date) -> FollowUp? {
        var at: Date?
        var text = ""
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        for raw in reply.split(whereSeparator: \.isNewline) {
            let line = NotchModel.keyedLine(raw)
            let upper = line.uppercased()
            if upper.hasPrefix("AT:") {
                at = stamp.date(from: line.dropFirst(3).trimmingCharacters(in: .whitespaces))
            } else if upper.hasPrefix("TEXT:") {
                text = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let at, !text.isEmpty, text.count <= 300,
              at > now.addingTimeInterval(5 * 60),
              at < now.addingTimeInterval(60 * 24 * 3600) else { return nil }
        return FollowUp(text: text, fireAt: at)
    }
}

let followUpSystemPrompt = """
You are Notchi, a Mac assistant. Below is one exchange with the user. Decide \
whether the user's message states something they themselves intend or need to \
do by a specific future time: a deadline, a plan, a promise to someone. You \
would write to them when that time comes. These are not it: a question about a \
time or a fact, someone else's schedule, a wish with no time, and anything the \
assistant's reply already set a reminder or an event for. Resolve relative \
dates ("明天", "next Friday") against Now. When in doubt, reply NONE.

Reply NONE, or exactly these two lines and nothing else:
AT: yyyy-MM-dd HH:mm
TEXT: <one sentence>

AT is local time, when to write to them: the stated time; 09:00 for a day with \
no time; 09:00 on the day of a deadline. TEXT is the one short sentence to \
send at that time, in the language the user wrote in, naming the thing and its \
time as it will read then ("today", not "Friday"). No greeting, and no offer \
to set a reminder.
"""

// MARK: - Resting ear

/// The left ear's content when a proactive message lands: Notchi's eyes and
/// one faint line, the same type as `RestingLicenseEar`. The line is the
/// reminder or event title, cut to `maxTextWidth`.
struct RestingMessageEar: View {
    let text: String

    static let maxTextWidth: CGFloat = 150

    var body: some View {
        HStack(spacing: 0) {
            NotchiFace(expression: .offer)
                .frame(width: NotchiFace.slotWidth)
            Text(text)
                .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                .tracking(0.3)
                .foregroundStyle(Tokens.text2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.textWidth(text), alignment: .leading)
                .padding(.leading, NotchIsland.faceTextGap)
        }
    }

    /// The text's width for the ear's slot, measured because the island sizes
    /// the ear before it is drawn.
    static func textWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: Tokens.TypeSize.meta)
        let width = (text as NSString).size(withAttributes: [.font: font, .kern: 0.3]).width
        return min(ceil(width), maxTextWidth)
    }
}
