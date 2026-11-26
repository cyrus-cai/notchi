import AppKit
import EventKit
import Foundation
import SwiftUI

// MARK: - Level

/// How often Notchi writes to the user without being asked (Settings → Chat).
///
/// Every level runs the same agent (`ProactiveEngine.think`); a level sets how
/// often it wakes on its own in working hours, how many messages a day it may
/// send, and the score Jev must give a message. Due reminders and events that
/// are about to start are sent at every level.
enum ProactiveLevel: String, CaseIterable, Identifiable {
    case off, minimal, balanced, frequent

    var id: String { rawValue }
    var label: String { L("proactive.level.\(rawValue)") }

    /// Messages in any 24 hours, every source counted. `frequent` has none:
    /// the user's replies set its pace (`ProactiveEngine.messageGap`).
    var dailyCap: Int {
        switch self {
        case .off: return 0
        case .minimal: return 3
        case .balanced: return 6
        case .frequent: return .max
        }
    }

    /// The gap an agent message keeps from the message before it. A due
    /// reminder or a starting event has a time of its own and is held to the
    /// cap only.
    var messageGap: TimeInterval {
        self == .frequent ? 15 * 60 : 60 * 60
    }

    /// How long the agent goes without waking in working hours.
    var wakeInterval: TimeInterval? {
        switch self {
        case .off: return nil
        case .minimal: return 4 * 3600
        case .balanced: return 2 * 3600
        case .frequent: return 3600
        }
    }

    /// The lowest score Jev may give a message for it to be sent
    /// (`NoNoAccount.checkProactive`).
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

/// Decides when Notchi writes first, in three parts.
///
/// Wake: the agent wakes on the level's interval in working hours, at a time it
/// set for itself last time, and when the user comes back to the Mac. After
/// every Ask round it also updates its notebook, without writing to the user.
///
/// Think: one agent run (`think`) with read-only tools (time, calendar,
/// reminders, web, pages, mail, clipboard, the user's history here) and its
/// notebook (`notebook`, a Markdown file the user can open and edit). It
/// rewrites the notebook, picks its next wake, and may hand over one message.
///
/// Speak: every message passes the same gate (`allows`): quiet hours, not in a
/// meeting, the user at the Mac, the daily cap, the gap, and Jev's score. Due
/// reminders and starting events are found without the agent and pass the cap
/// and Jev only.
@MainActor
final class ProactiveEngine: ObservableObject {
    static let shared = ProactiveEngine()

    @Published var level: ProactiveLevel = .stored {
        didSet {
            guard level != oldValue else { return }
            ProactiveLevel.stored = level
            if level == .off { pending = nil }
        }
    }

    weak var model: NotchModel?

    /// A message Notchi sent on its own and what the user did with it. The
    /// last `outcomeLimit` go to the agent, so what it writes next follows
    /// what the user answered and what they let pass.
    struct Outcome: Codable, Equatable {
        var text: String
        var sentAt: Date
        /// The user's next message in that thread, when they wrote one
        /// within `replyWindow`.
        var reply: String?
    }

    private(set) var outcomes: [Outcome] = [] {
        didSet {
            guard outcomes != oldValue else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(outcomes), forKey: Self.outcomesKey)
        }
    }

    private static let outcomesKey = "proactive.outcomes"
    private static let outcomeLimit = 20
    /// How long after a message the user's next one counts as the reply to it.
    private static let replyWindow: TimeInterval = 6 * 3600

    private static let sentAtKey = "proactive.sentAt"
    private static let seenKey = "proactive.seen"
    private static let lastWakeKey = "proactive.lastWake"
    private static let nextWakeKey = "proactive.nextWake"
    private static let wakeLogKey = "proactive.wakes"
    /// Follow-ups stored before the agent existed; moved into the notebook once.
    private static let legacyFollowUpsKey = "proactive.followUps"

    private static let tickInterval: TimeInterval = 60
    /// How long before its start an event is announced.
    private static let eventLead: TimeInterval = 10 * 60
    /// How long after its time a message is still worth sending.
    private static let eventGrace: TimeInterval = 5 * 60
    private static let reminderGrace: TimeInterval = 30 * 60
    /// The hour reminders due today with no time are sent.
    private static let dayReminderHour = 9

    /// Weekdays, from `workStartHour` to `workEndHour` local time: when the
    /// agent wakes on its own interval.
    private static let workStartHour = 9
    private static let workEndHour = 19
    /// Any day, from `dayStartHour` to `dayEndHour`: when an agent message may
    /// be sent and a wake the agent set for itself may run.
    private static let dayStartHour = 8
    private static let dayEndHour = 22
    /// Away from the Mac this long: an agent message waits for the user.
    private static let awayAfter: TimeInterval = 5 * 60
    /// Away this long and back: the agent wakes.
    private static let returnAfter: TimeInterval = 10 * 60
    /// The fewest minutes between two wakes of any kind.
    private static let wakeGap: TimeInterval = 30 * 60
    private static let wakesPerDay = 24
    /// Tool rounds in one wake, and search rounds among them.
    private static let toolRounds = 6
    private static let searchRounds = 3
    /// How long an agent message waits for the gate before it is dropped.
    private static let messageGrace: TimeInterval = 2 * 3600
    private static let notebookLimit = 6000
    private static let digestLimit = 8000

    private var timer: Timer?
    private var ticking = false
    private var store = EKEventStore()
    private var storeStatus: [EKAuthorizationStatus] = []

    /// The message the last wake handed over, until it is sent or dropped.
    private var pending: Candidate?
    /// Agent runs and notebook updates, one after another, so two never
    /// write the notebook at once.
    private var job: Task<Void, Never>?
    private var thinking = false
    private var wasAway = false
    private var cameBack = false

    /// The notebook's text, for Settings.
    @Published private(set) var notebook: String = ""

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.outcomesKey),
           let saved = try? JSONDecoder().decode([Outcome].self, from: data) {
            outcomes = saved
        }
        notebook = (try? String(contentsOf: Self.notebookURL, encoding: .utf8)) ?? ""
        migrateFollowUps()
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

    // MARK: Notebook

    static var notebookURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Notch", isDirectory: true)
            .appendingPathComponent("proactive-notebook.md")
    }

    /// The notebook as the agent reads it: the file on disk, which the user
    /// may have edited.
    private func readNotebook() -> String {
        let text = (try? String(contentsOf: Self.notebookURL, encoding: .utf8)) ?? ""
        if text != notebook { notebook = text }
        return text
    }

    private func writeNotebook(_ text: String) {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.notebookLimit))
        try? FileManager.default.createDirectory(at: Self.notebookURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? (trimmed.isEmpty ? "" : trimmed + "\n").write(to: Self.notebookURL, atomically: true, encoding: .utf8)
        notebook = trimmed
    }

    /// Open the notebook in the user's editor, from Settings.
    func openNotebook() {
        if !FileManager.default.fileExists(atPath: Self.notebookURL.path) { writeNotebook(notebook) }
        NSWorkspace.shared.open(Self.notebookURL)
    }

    /// Follow-ups stored before the agent existed become notebook lines, and
    /// the earliest one the next wake.
    private func migrateFollowUps() {
        struct FollowUp: Codable { var text: String; var fireAt: Date }
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.legacyFollowUpsKey) else { return }
        defaults.removeObject(forKey: Self.legacyFollowUpsKey)
        guard let saved = try? JSONDecoder().decode([FollowUp].self, from: data), !saved.isEmpty else { return }
        let stamp = Self.stampFormatter("yyyy-MM-dd HH:mm")
        let lines = saved.map { "- Bring up at \(stamp.string(from: $0.fireAt)): \($0.text)" }
        writeNotebook((readNotebook() + "\n" + lines.joined(separator: "\n")))
        if let first = saved.map(\.fireAt).min(), first > Date() { nextWake = first }
    }

    // MARK: Tick

    private struct Candidate {
        let key: String
        let text: String
        /// The line on the resting notch.
        let glance: String
        let due: Date
        let expires: Date
        /// Written by the agent; passes the whole gate.
        var fromAgent = false

        /// `reminder`, `event` or `followup`: the key's own prefix, and what
        /// the gateway's `kind` takes.
        var kind: String {
            if fromAgent { return "followup" }
            return key.hasPrefix("event:") ? "event" : "reminder"
        }
    }

    private func tick() {
        guard level != .off, model != nil, !LicenseLock.isLocked else { return }
        let now = Date()
        noteAway(now: now)
        maybeWake(now: now)
        guard !ticking else { return }
        ticking = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.ticking = false }
            var candidates = await self.dueReminders(now: now) + self.dueEvents(now: now)
            if let pending = self.pending {
                if pending.expires < now { self.pending = nil } else { candidates.append(pending) }
            }
            candidates.sort { $0.due < $1.due }

            var seen = self.seen
            defer { self.seen = seen }
            for candidate in candidates where seen[candidate.key] == nil {
                if candidate.expires < now {
                    seen[candidate.key] = now
                    continue
                }
                guard self.level != .off, self.allows(candidate, now: now) else { continue }
                // The main thread is taking a round: Jev is not asked for a
                // message that cannot be written yet.
                guard self.model?.canPostProactiveMessage == true else { return }
                if let score = await self.worth(candidate, now: now), score < self.level.floor {
                    seen[candidate.key] = now
                    if candidate.fromAgent { self.pending = nil }
                    continue
                }
                // A round is being written into the main thread: next minute.
                guard self.model?.postProactiveMessage(candidate.text, glance: candidate.glance) == true
                else { return }
                seen[candidate.key] = now
                self.sentDates = self.sentDates + [now]
                self.outcomes = Array((self.outcomes + [Outcome(text: candidate.text, sentAt: now)])
                    .suffix(Self.outcomeLimit))
                if candidate.fromAgent { self.pending = nil }
                // One message a minute at most.
                return
            }
        }
    }

    /// The gate. Every message: the daily cap. An agent message also: the
    /// hours of the day, not during a meeting, the user at the Mac, and the
    /// level's gap, doubled for each message in a row the user let pass.
    private func allows(_ candidate: Candidate, now: Date) -> Bool {
        let sent = sentDates
        guard sent.count < level.dailyCap else { return false }
        guard candidate.fromAgent else { return true }
        let hour = Calendar.current.component(.hour, from: now)
        guard hour >= Self.dayStartHour, hour < Self.dayEndHour else { return false }
        guard Self.idleSeconds() < Self.awayAfter, !inMeeting(now: now) else { return false }
        if let last = sent.last, now.timeIntervalSince(last) < messageGap(now: now) { return false }
        return true
    }

    /// The level's gap, doubled for each message in a row the user let pass,
    /// up to eight hours. One reply brings it back.
    private func messageGap(now: Date) -> TimeInterval {
        var ignored = 0
        for outcome in outcomes.reversed() {
            if outcome.reply != nil { break }
            if now.timeIntervalSince(outcome.sentAt) >= Self.replyWindow { ignored += 1 }
        }
        return min(level.messageGap * pow(2, Double(min(ignored, 5))), 8 * 3600)
    }

    /// The user wrote `reply` right after Notchi's own message `to`: keep it as
    /// that message's outcome. Called from `NotchModel` after the round.
    func noteReply(to text: String, reply: String) {
        guard let i = outcomes.lastIndex(where: { $0.text == text }), outcomes[i].reply == nil,
              Date().timeIntervalSince(outcomes[i].sentAt) < Self.replyWindow else { return }
        outcomes[i].reply = String(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
    }

    /// The outcomes as lines for the agent.
    private func outcomeLines(now: Date) -> String {
        let stamp = Self.stampFormatter("MM-dd HH:mm")
        return outcomes.compactMap { o in
            let result: String
            if let reply = o.reply {
                result = "they replied: \"\(reply)\""
            } else if now.timeIntervalSince(o.sentAt) >= Self.replyWindow {
                result = "no reply"
            } else {
                result = "no reply yet"
            }
            return "- \(stamp.string(from: o.sentAt)) you wrote: \"\(o.text)\" → \(result)"
        }.joined(separator: "\n")
    }

    /// Jev's score for sending `candidate` now, or nil when there is none: no
    /// account, a failed request, or text that looks like a credential, which
    /// is never sent to be judged.
    private func worth(_ candidate: Candidate, now: Date) async -> Double? {
        let message = String(candidate.text.prefix(600))
        guard !ClipPrivacy.containsSecret(message) else { return nil }
        let clock = Self.stampFormatter("EEEE HH:mm")
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

    // MARK: Wake

    private var lastWake: Date? {
        get { UserDefaults.standard.object(forKey: Self.lastWakeKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastWakeKey) }
    }

    /// The time the agent set for its next look, if any.
    private var nextWake: Date? {
        get { UserDefaults.standard.object(forKey: Self.nextWakeKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.nextWakeKey) }
    }

    /// The wakes of the last 24 hours.
    private var wakeDates: [Date] {
        get {
            let all = UserDefaults.standard.array(forKey: Self.wakeLogKey) as? [Date] ?? []
            return all.filter { Date().timeIntervalSince($0) < 24 * 3600 }
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.wakeLogKey) }
    }

    static func isWorkingHours(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard !calendar.isDateInWeekend(date) else { return false }
        let hour = calendar.component(.hour, from: date)
        return hour >= workStartHour && hour < workEndHour
    }

    private static func isDaytime(_ date: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= dayStartHour && hour < dayEndHour
    }

    /// Seconds since the last keyboard, mouse or trackpad event.
    static func idleSeconds() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// Notes a return to the Mac after `returnAfter` away, for `maybeWake`.
    private func noteAway(now: Date) {
        let idle = Self.idleSeconds()
        if idle >= Self.returnAfter {
            wasAway = true
        } else if wasAway, idle < 60 {
            wasAway = false
            cameBack = true
        }
    }

    /// Wake the agent when a wake is due and no message of the last one is
    /// still waiting: the time it set for itself (any day, daytime), the
    /// level's interval (working hours), or the user back at the Mac (working
    /// hours). Never twice within `wakeGap`, at most `wakesPerDay` a day.
    private func maybeWake(now: Date) {
        guard let interval = level.wakeInterval, !thinking, pending == nil,
              let model, let service = model.proactiveService else { return }
        let back = cameBack
        cameBack = false
        if let last = lastWake, now.timeIntervalSince(last) < Self.wakeGap { return }
        guard wakeDates.count < Self.wakesPerDay else { return }

        let reason: String
        if let at = nextWake, now >= at, Self.isDaytime(now) {
            reason = "the time you set for yourself last time"
        } else if Self.isWorkingHours(now), back {
            reason = "the user just came back to the Mac"
        } else if Self.isWorkingHours(now), lastWake.map({ now.timeIntervalSince($0) >= interval }) ?? true {
            reason = "your regular check"
        } else {
            return
        }

        let since = lastWake ?? now.addingTimeInterval(-24 * 3600)
        let conversation = conversationDigest(model.history, unified: model.unifiedThreadsEnabled,
                                              since: since, now: now)
        let notes = readNotebook()
        // Nothing to follow and nothing said since the last wake: no request.
        guard !notes.isEmpty || !conversation.isEmpty || !outcomes.isEmpty else {
            lastWake = now
            return
        }
        lastWake = now
        wakeDates = wakeDates + [now]
        if nextWake.map({ $0 <= now }) == true { nextWake = nil }
        thinking = true
        enqueue { [weak self] in
            guard let self else { return }
            defer { self.thinking = false }
            await self.think(service: service, reason: reason, notes: notes,
                             conversation: conversation, now: now)
        }
    }

    /// Run `work` after every earlier agent run and notebook update.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = job
        job = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    // MARK: Think

    /// One wake: the agent reads its notebook and what happened since, checks
    /// what it needs with its tools, rewrites the notebook, sets its next wake
    /// and may hand over one message for the gate.
    private func think(service: AIService, reason: String, notes: String,
                       conversation: String, now: Date) async {
        var context = "Now: \(Self.stampFormatter("yyyy-MM-dd HH:mm EEEE").string(from: now)) "
            + "(\(TimeZone.current.identifier))\nWhy you woke: \(reason)\n\n"
        context += "Your notebook:\n" + (notes.isEmpty ? "(empty)" : notes) + "\n\n"
        context += "Conversation with the user since you last woke, oldest first:\n"
            + (conversation.isEmpty ? "(none)" : conversation) + "\n\n"
        let history = outcomeLines(now: now)
        if !history.isEmpty {
            context += "Messages you sent on your own, and what the user did with them:\n" + history + "\n\n"
        }
        let loops = ChatLoopManager.shared.loops.filter(\.active).map { "- every \($0.intervalMinutes) min: \(String($0.prompt.prefix(160)))" }
        if !loops.isEmpty {
            context += "Scheduled tasks that already run on their own (leave their topics to them):\n"
                + loops.joined(separator: "\n") + "\n\n"
        }

        let tools = agentTools()
        let reply: String?
        if let agent = service as? AgentCapableService, APIKeyStore.selectedProvider.supportsTools, !tools.isEmpty {
            reply = await runAgent(agent, tools: tools, system: proactiveWakeSystemPrompt(tools: true),
                                   context: context)
        } else {
            reply = await ask(service, system: proactiveWakeSystemPrompt(tools: false), prompt: context)
        }
        guard let reply, let parsed = Self.parse(reply, now: now) else { return }
        if let book = parsed.notebook { writeNotebook(book) }
        nextWake = parsed.wake
        guard level != .off, let text = parsed.message else { return }
        pending = Candidate(key: "agent:\(Int(now.timeIntervalSince1970))", text: text, glance: text,
                            due: now, expires: now.addingTimeInterval(Self.messageGrace), fromAgent: true)
    }

    /// The agent's read-only tools. Mail only when Mail is running and Notchi
    /// may already script it, so a wake never raises a permission prompt.
    private func agentTools() -> [NotchTool] {
        var tools: [NotchTool] = [DateTimeTool(), ReadPageTool()]
        tools.append(WebSearchTool(provider: APIKeyStore.resolvedSearchBackend()?.searchProvider
            ?? AnySearchProvider()))
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { tools.append(ReadCalendarTool()) }
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { tools.append(ReadRemindersTool()) }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty,
           !PermissionPromptGate.automationMayAsk("com.apple.mail") {
            tools.append(ReadMailTool())
        }
        if ClipboardHistory.available { tools.append(ClipboardHistoryTool()) }
        tools.append(SearchHistoryTool { [weak self] query in
            await MainActor.run { self?.model?.searchArchive(query) ?? .empty }
        })
        return tools
    }

    private func runAgent(_ agent: AgentCapableService, tools: [NotchTool], system: String,
                          context: String) async -> String? {
        var harness = AgentHarness(service: agent, registry: ToolRegistry(tools))
        harness.maxIterations = Self.toolRounds
        harness.maxSearchRounds = Self.searchRounds
        harness.requestContext = NoNoRequestContext(surface: NoNoRequestContext.suggest)
        var out = ""
        do {
            try await RequestAudit.$purpose.withValue("proactive") {
                try await harness.run(
                    system: system,
                    messages: [AgentMessage(kind: .text(role: "user", text: context))],
                    onText: { out += $0 },
                    onActivity: { _, _ in },
                    onSources: { _ in },
                    onRetract: { n in out = String(out.dropLast(min(n, out.count))) })
            }
        } catch {
            return nil
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One request with no tools; nil when it fails or comes back empty.
    private func ask(_ service: AIService, system: String, prompt: String) async -> String? {
        var reply = ""
        do {
            let chunks = RequestAudit.$purpose.withValue("proactive") {
                NoNoRequestContext.$current.withValue(
                    NoNoRequestContext(surface: NoNoRequestContext.suggest)
                ) {
                    service.stream(system: system,
                                   messages: [ChatMessage(role: "user", content: prompt)])
                }
            }
            for try await chunk in chunks { reply += chunk }
        } catch {
            return nil
        }
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    struct Parsed: Equatable {
        /// Nil when the reply had no NOTEBOOK section: the notebook stays.
        var notebook: String?
        var wake: Date?
        var message: String?
    }

    /// The sections that end the agent's reply. Nil when there is no NOTEBOOK
    /// section and no MESSAGE line: a reply off the format changes nothing.
    /// A wake is kept between five minutes and fourteen days out.
    static func parse(_ reply: String, now: Date) -> Parsed? {
        let lines = reply.components(separatedBy: .newlines)
        guard let start = lines.lastIndex(where: { NotchModel.keyedLine($0).uppercased().hasPrefix("NOTEBOOK:") })
                ?? lines.lastIndex(where: { NotchModel.keyedLine($0).uppercased().hasPrefix("MESSAGE:") })
        else { return nil }
        var parsed = Parsed()
        var book: [String]?
        let stamp = stampFormatter("yyyy-MM-dd HH:mm")
        for raw in lines[start...] {
            let line = NotchModel.keyedLine(raw)
            let upper = line.uppercased()
            func value(_ key: String) -> String {
                line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            }
            if upper.hasPrefix("NOTEBOOK:") {
                let rest = value("NOTEBOOK:")
                book = rest.isEmpty ? [] : [rest]
            } else if upper.hasPrefix("WAKE:") {
                parsed.wake = stamp.date(from: value("WAKE:")).flatMap {
                    $0 > now.addingTimeInterval(5 * 60) && $0 < now.addingTimeInterval(14 * 24 * 3600) ? $0 : nil
                }
                if let lines = book { parsed.notebook = lines.joined(separator: "\n") }
                book = nil
            } else if upper.hasPrefix("MESSAGE:") {
                let text = value("MESSAGE:")
                if !text.isEmpty, text.uppercased() != "NONE", text.count <= 400 { parsed.message = text }
            } else if upper.hasPrefix("BASIS:") {
                continue
            } else if book != nil {
                book?.append(raw)
            }
        }
        if let lines = book { parsed.notebook = lines.joined(separator: "\n") }
        if let text = parsed.notebook, text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "(EMPTY)" {
            parsed.notebook = ""
        }
        return parsed
    }

    // MARK: After a round

    /// After an Ask round: the agent updates its notebook from the exchange
    /// and may set its next wake. It writes nothing to the user here. One
    /// request with no tools, on the model that answers background questions.
    func roundEnded(question: String, answer: String, service: AIService) {
        guard level != .off, !(service is StubAIService), !LicenseLock.isLocked else { return }
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, !ClipPrivacy.containsSecret(asked) else { return }
        let now = Date()
        enqueue { [weak self] in
            guard let self else { return }
            let notes = self.readNotebook()
            var prompt = "Now: \(Self.stampFormatter("yyyy-MM-dd HH:mm EEEE").string(from: now)) "
                + "(\(TimeZone.current.identifier))\n\n"
            prompt += "Your notebook:\n" + (notes.isEmpty ? "(empty)" : notes) + "\n\n"
            if let wake = self.nextWake {
                prompt += "Your next wake is set for \(Self.stampFormatter("yyyy-MM-dd HH:mm").string(from: wake)).\n\n"
            }
            prompt += "The exchange that just ended:\nUser: \(String(asked.prefix(1500)))\n\n"
                + "You: \(String(answer.prefix(1500)))"
            guard let reply = await self.ask(service, system: proactiveNoteSystemPrompt, prompt: prompt),
                  let parsed = Self.parse(reply, now: now) else { return }
            if let book = parsed.notebook { self.writeNotebook(book) }
            if let wake = parsed.wake, self.nextWake.map({ wake < $0 }) ?? true { self.nextWake = wake }
        }
    }

    // MARK: Conversation

    /// The conversation since `since` as text for the agent, the newest kept
    /// first up to `digestLimit`. With unified threads that is the main thread
    /// alone; otherwise every thread, merged by time. An answer has no
    /// `sentAt` of its own and takes the time of the message before it. Loop
    /// rounds and turns that look like a credential are left out.
    func conversationDigest(_ history: [NotchModel.HistoryItem], unified: Bool,
                            since: Date, now: Date) -> String {
        let threads = unified
            ? history.filter { $0.mainThread && $0.source == .ask }
            : history.filter { $0.t > since }
        var dated: [(date: Date, order: Int, turn: NotchModel.Turn)] = []
        for item in threads {
            var last: Date?
            for turn in item.conversation {
                if let at = turn.sentAt { last = at }
                guard let date = last, date > since, turn.loopRound == nil else { continue }
                dated.append((date, dated.count, turn))
            }
        }
        let turns = dated.sorted { ($0.date, $0.order) < ($1.date, $1.order) }

        let stamp = Self.stampFormatter("MM-dd HH:mm")
        var lines: [String] = []
        var size = 0
        for entry in turns.reversed() {
            let turn = entry.turn
            let body = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, !turn.isLocal, !ClipPrivacy.containsSecret(body) else { continue }
            let who = turn.role == "user" ? "User" : turn.proactive ? "You (on your own)" : "You"
            let note = turn.isError ? " (failed)" : turn.interrupted ? " (cut off)" : ""
            let line = "[\(stamp.string(from: entry.date))] \(who)\(note): "
                + String(body.prefix(turn.role == "user" ? 600 : 400))
            guard size + line.count <= Self.digestLimit else { break }
            lines.append(line)
            size += line.count + 1
        }
        return lines.reversed().joined(separator: "\n")
    }

    // MARK: Meetings

    /// An event with someone else in it is on now, and the user has not
    /// declined it.
    private func inMeeting(now: Date) -> Bool {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return false }
        let store = currentStore()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600),
                                                 end: now.addingTimeInterval(60), calendars: nil)
        return store.events(matching: predicate).contains { event in
            guard !event.isAllDay, event.status != .canceled,
                  let start = event.startDate, let end = event.endDate,
                  start <= now, end > now,
                  let attendees = event.attendees, attendees.contains(where: { !$0.isCurrentUser })
            else { return false }
            return attendees.first(where: \.isCurrentUser)?.participantStatus != .declined
        }
    }

    // MARK: Reminders and events

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

    private static func clean(_ text: String?) -> String? {
        let line = text?.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? nil : line
    }

    private static func stampFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
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
}

// MARK: - Prompts

/// A wake's system prompt. `tools` is false for a backend that runs no tools
/// (a CLI, a provider without tool calls): it works from what it is given.
func proactiveWakeSystemPrompt(tools: Bool) -> String {
    let checking = tools
        ? """
        Use your tools to check what you need: the time, the user's calendar and \
        reminders, the web and pages, their mail, their clipboard, their history \
        in this app. Check only what your notebook or the new conversation gives \
        you a reason to check, and check each thing at most once.
        """
        : "Work from what is below; you cannot check anything else."
    return """
    You are Notchi, a Mac assistant. This is not a chat turn: you woke up on \
    your own to decide whether to write to the user unprompted. Nobody is \
    waiting for a reply.

    You keep a notebook of what you are following for the user. It is below, \
    with what was said since you last woke. \(checking)

    Write to the user only when one thing is worth their attention now and \
    they would be glad you said it unprompted: something they are waiting on \
    changed, something they said they would do is due, a question you asked \
    them is still open and matters, something you said you would do. Not: \
    small talk; anything they already know; anything you already wrote about \
    that they did not take up; anything a scheduled task below already covers; \
    anything they turned down or you refused. Write more of the kinds they \
    replied to and fewer of the kinds they let pass. When in doubt, write nothing.

    End your reply with exactly these sections and nothing after them:
    NOTEBOOK:
    <the whole notebook, rewritten: one "- " line per thing you follow, saying \
    what it is, why, when and how to check it next, and what you found last. \
    Add what the new conversation gives you to follow. Drop what is settled, \
    no longer wanted, or out of date. At most 30 lines. (empty) when there is \
    nothing.>
    WAKE: <yyyy-MM-dd HH:mm local time, the next time something here needs a \
    look, or NONE>
    MESSAGE: <one or two short sentences to send now, in the language the user \
    writes in, addressed to them as "you" ("你"), naming the thing so it reads \
    clearly on its own, no greeting; or NONE>
    BASIS: <what the message rests on: the conversation line or the URL; empty with NONE>
    """
}

/// After an Ask round: update the notebook only.
let proactiveNoteSystemPrompt = """
You are Notchi, a Mac assistant that also writes to the user on its own at \
times you choose. You keep a notebook of what you are following for the user. \
An exchange with the user just ended. Update the notebook from it; you do not \
write to the user now.

Worth a line: something the user is waiting on that may change (a release, a \
price, a reply, a result, an order); something they said they would do, with \
its time; a question you asked them that you cannot go on without; something \
you said you would do or could not finish; how something they are working on \
turned out, when that is worth asking about later. Not worth a line: small \
talk, a question fully answered, anything they turned down or you refused, \
anything a reminder or event was just set for. Settle lines this exchange \
answered or the user no longer wants. Change nothing when there is nothing.

Reply with exactly these sections and nothing else:
NOTEBOOK:
<the whole notebook, rewritten: one "- " line per thing, saying what it is, \
why, when and how to check it next. At most 30 lines. (empty) when there is \
nothing.>
WAKE: <yyyy-MM-dd HH:mm local time, when something here first needs a look, \
or NONE>
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
