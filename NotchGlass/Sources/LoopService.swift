import SwiftUI
import AppKit
import Network

// MARK: - /loop

/// `/loop` re-runs one prompt on an interval: as an Agent task (the same CLI
/// session, round after round — `AgentTaskManager`) or as an Ask thread (the
/// same conversation — `ChatLoopManager` below). This file holds what both
/// share: the interval vocabulary, the wall clock rounds wait on, the interval
/// card the compose chip opens, and the round column a loop's record reads in.
enum LoopInterval {
    /// The interval card's preset rows, in minutes.
    static let presets = [10, 30, 60, 360, 1440]
    /// What a typed value may be: one minute to one day.
    static let typedRange = 1...1440
    static let defaultMinutes = 60
    /// What an agent writes at the end of a report to end its own loop.
    static let doneMarker = "[loop:done]"
    private static let lastKey = "loop.lastIntervalMinutes"

    /// The interval `/loop` last picked, so the next arming lands on it.
    static var lastMinutes: Int {
        let stored = UserDefaults.standard.integer(forKey: lastKey)
        return typedRange.contains(stored) ? stored : defaultMinutes
    }

    static func remember(_ minutes: Int) {
        guard typedRange.contains(minutes) else { return }
        UserDefaults.standard.set(minutes, forKey: lastKey)
    }

    /// Appended to every loop round's prompt on the wire only — the record
    /// keeps the prompt the user wrote. It states the loop's real settings, so
    /// a round never has to guess them, and what the round may do about the
    /// schedule: nothing, except report that a stop condition the user wrote
    /// has been met. Even then the loop only pauses (`LoopEndReason.doneSuggested`).
    static func wireSuffix(minutes: Int, round: Int?, endsAt: Date? = nil,
                           weekdaysOnly: Bool = false, pageSlug: String? = nil) -> String {
        var schedule = "repeats every \(short(minutes))"
        if weekdaysOnly { schedule += " on weekdays" }
        if let endsAt {
            schedule += " until "
                + endsAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        }
        let roundText = "This is a recurring task that \(schedule)."
        let pageText = pageSlug.map {
            " This task already has a live page (\($0), https://\($0).\(PagesService.domain))."
                + " Append the full findings to that page with page(action=\"append\", page_id=\"\($0)\", text=...),"
                + " and keep your reply in this thread to one brief sentence plus the page URL on its own line."
        } ?? ""
        return "\n\n(" + roundText
            + " State the finding directly as a normal update — never mention round numbers or check framing"
            + " (no \"Round N\", \"第 N 轮\", \"本轮\", \"这一轮\", \"本次巡检\")."
            + " The app runs the schedule. You cannot start, stop, pause or re-time this loop,"
            + " and you have no tool for it, so never say you changed it."
            + " Only if the message above names a condition for stopping and that condition is now met,"
            + " end your reply with \(doneMarker); the app then pauses the loop and asks the user."
            + " Finding nothing new is not a reason to stop."
            + pageText + ")"
    }

    /// A loop round's answer as shown while it streams: the done marker
    /// removed, including the part of it that has already arrived.
    static func hidingDoneMarker(_ text: String) -> String {
        var out = text.replacingOccurrences(of: doneMarker, with: "")
        for n in stride(from: doneMarker.count - 1, through: 1, by: -1)
            where out.hasSuffix(doneMarker.prefix(n)) {
            out.removeLast(n)
            break
        }
        return out
    }

    /// The first slot of a schedule still ahead: `slot` itself, or as many
    /// intervals past it as have gone by. Nil `slot` counts one interval from now.
    static func nextSlot(from slot: Date?, minutes: Int, now: Date = Date()) -> Date {
        let step = TimeInterval(max(minutes, 1) * 60)
        guard let slot else { return now.addingTimeInterval(step) }
        guard slot <= now else { return slot }
        let passed = (now.timeIntervalSince(slot) / step).rounded(.down) + 1
        return slot.addingTimeInterval(passed * step)
    }

    /// "45m" · "1h" · "1h 30m" · "6h" · "1d".
    static func short(_ minutes: Int) -> String {
        if minutes >= 1440, minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        return "\(minutes)m"
    }

    /// A waiting loop's countdown: the elapsed clock's own format under an hour
    /// ("8m 40s"), hours and minutes past it ("23h 41m").
    static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        if s >= 3600 { return String(format: "%dh %02dm", s / 3600, s % 3600 / 60) }
        return s < 60 ? "\(s)s" : String(format: "%dm %02ds", s / 60, s % 60)
    }

    /// Wait for a wall-clock moment. Checked every 30s rather than slept out in
    /// one go, so a Mac that sleeps past the deadline runs the round once on
    /// wake instead of sleeping the whole remainder again. A round that comes
    /// due while the Mac is offline waits until the network is back.
    static func wait(until date: Date) async throws {
        while true {
            let remaining = date.timeIntervalSinceNow
            if remaining <= 0 { break }
            try await Task.sleep(nanoseconds: UInt64(min(remaining, 30) * 1_000_000_000))
        }
        while !NetworkReachability.shared.isOnline {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// When a loop's next round is due after a failed round: right away if the
    /// Mac is offline (`wait` then holds it until the network is back), one
    /// interval from now otherwise.
    static func nextAfterFailure(intervalMinutes: Int) -> Date {
        NetworkReachability.shared.isOnline
            ? Date().addingTimeInterval(TimeInterval(intervalMinutes * 60))
            : Date()
    }
}

/// Whether the Mac has a usable network path. Loops read it so a round never
/// starts offline.
final class NetworkReachability: @unchecked Sendable {
    static let shared = NetworkReachability()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true

    var isOnline: Bool {
        lock.lock(); defer { lock.unlock() }
        return online
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.online = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "notch.loop.reachability", qos: .utility))
    }
}

/// Why a loop is no longer running. Shown in its ⌘ card and in the banner
/// that announces it, so a loop never stops without saying why.
enum LoopEndReason: String, Codable {
    /// Stop in the ⌘ card, or a stop from a manage_loop request.
    case stopped
    /// The Routines switch.
    case paused
    /// A round wrote `LoopInterval.doneMarker`. The loop is paused, not ended:
    /// Continue or the Routines switch picks it back up.
    case doneSuggested
    /// The end date the user set has passed.
    case endDate
    /// The agent CLI could not be found.
    case failed

    var cardText: String { L("loop.reason.\(rawValue)") }
}

/// What a loop's ⌘ card shows about it — the same for a chat loop and an agent
/// loop. `id` is the loop's (an agent loop's is its task's).
struct LoopMenuInfo: Equatable, Identifiable {
    var id: UUID = UUID()
    /// The loop's prompt. The card names each loop by it when a thread holds
    /// more than one.
    var prompt: String = ""
    let intervalMinutes: Int
    let rounds: Int
    let nextRoundAt: Date?
    let active: Bool
    var endReason: LoopEndReason? = nil
}

// MARK: - Loop log

/// Every change to a chat loop's schedule, one line each, in
/// Application Support/Notchi/loops.log. A loop that stops says why and from
/// which call site, so a loop that went quiet can be traced afterwards.
enum LoopLog {
    private static let queue = DispatchQueue(label: "notch.loop.log", qos: .utility)
    private static let maxBytes = 512 * 1024
    /// Local time, so a line reads against the clock the user saw.
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static var url: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first else { return nil }
        let appDir = dir.appendingPathComponent("Notchi", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("loops.log")
    }

    static func write(_ line: String) {
        let text = "\(stampFormatter.string(from: Date())) \(line)\n"
        queue.async {
            guard let url, let data = text.data(using: .utf8) else { return }
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
               size > maxBytes {
                // Keep the newer half.
                if let old = try? Data(contentsOf: url) {
                    try? old.suffix(maxBytes / 2).write(to: url)
                }
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }
}

// MARK: - Chat loops

/// Ask loops. The rounds themselves run through the ordinary chat pipeline
/// (`NotchModel.runChatLoopRound` — tools, persistence and Recent all
/// unchanged); this owns only the schedule: when the next round is due, how
/// many have run, and when the loop is over.
///
/// A loop has its own id; `threadID` is the thread its rounds answer in. One
/// thread can hold any number of loops. Records written before loops had
/// their own id carry none, and their loop id is their thread's.
///
/// Loops are written to `UserDefaults` so a quit does not end them; the thread
/// itself already lives in Recent. A stopped loop stays on disk after its tray
/// row is dismissed, so reopening its thread from Recent can still continue it.
@MainActor
final class ChatLoopManager: ObservableObject {
    static let shared = ChatLoopManager()

    struct ChatLoop: Identifiable, Equatable {
        /// The loop's own id.
        let id: UUID
        /// The thread its rounds answer in — also its Recent row's id.
        var threadID: UUID
        let prompt: String
        var intervalMinutes: Int
        var startedAt: Date
        /// Loop rounds started so far.
        var rounds = 1
        /// Set while a loop round is running.
        var roundStartedAt: Date? = Date()
        var lastRoundDuration: TimeInterval = 0
        var nextRoundAt: Date? = nil
        var active = true
        /// Ended on a failed round, for the settled row's dot.
        var failed = false
        /// A stopped loop whose tray row was tapped or closed. The loop is kept
        /// so its thread can continue it.
        var dismissed = false
        /// The last moment a round may start, when the user named an end date;
        /// nil runs until it is stopped.
        var endsAt: Date? = nil
        /// Rounds skip Saturdays and Sundays.
        var weekdaysOnly = false
        /// Set while the Routines switch has the loop off: when its next round
        /// was due, so switching it back on keeps the same schedule.
        var pausedSlot: Date? = nil
        /// Why the loop stopped; nil while it runs.
        var endReason: LoopEndReason? = nil
        /// Bound Notchi page (`<slug>.notch.website`), auto-set when a round
        /// creates or updates a page.
        var pageSlug: String? = nil
        var pageTitle: String? = nil

        var isRunning: Bool { roundStartedAt != nil }
        var isWaiting: Bool { active && !isRunning }
        var interval: TimeInterval { TimeInterval(intervalMinutes * 60) }

        var menuInfo: LoopMenuInfo {
            LoopMenuInfo(id: id, prompt: prompt, intervalMinutes: intervalMinutes,
                         rounds: rounds, nextRoundAt: nextRoundAt, active: active,
                         endReason: active ? nil : endReason)
        }
    }

    /// Disk shape of a loop. A round that was in flight is stored as not yet
    /// run, due when it started: the stream died with the process, and the
    /// same round runs again at launch.
    ///
    /// Every field past the required ones is read leniently: a value this
    /// build does not know (an `endReason` added later) reads as absent
    /// instead of failing the record.
    private struct Record: Codable {
        let id: UUID
        /// Absent in records written before loops had their own id: the loop's
        /// thread is then `id`.
        var threadID: UUID? = nil
        let prompt: String
        let intervalMinutes: Int
        let startedAt: Date
        let rounds: Int
        let lastRoundDuration: TimeInterval
        let nextRoundAt: Date?
        var active: Bool? = nil
        var failed: Bool? = nil
        var dismissed: Bool? = nil
        var endsAt: Date? = nil
        var weekdaysOnly: Bool? = nil
        var pausedSlot: Date? = nil
        var endReason: LoopEndReason? = nil
        var pageSlug: String? = nil
        var pageTitle: String? = nil

        init(id: UUID, threadID: UUID?, prompt: String, intervalMinutes: Int,
             startedAt: Date, rounds: Int, lastRoundDuration: TimeInterval,
             nextRoundAt: Date?, active: Bool?, failed: Bool?, dismissed: Bool?,
             endsAt: Date?, weekdaysOnly: Bool?, pausedSlot: Date?,
             endReason: LoopEndReason?, pageSlug: String? = nil, pageTitle: String? = nil) {
            self.id = id; self.threadID = threadID; self.prompt = prompt
            self.intervalMinutes = intervalMinutes; self.startedAt = startedAt
            self.rounds = rounds; self.lastRoundDuration = lastRoundDuration
            self.nextRoundAt = nextRoundAt; self.active = active; self.failed = failed
            self.dismissed = dismissed; self.endsAt = endsAt
            self.weekdaysOnly = weekdaysOnly; self.pausedSlot = pausedSlot
            self.endReason = endReason; self.pageSlug = pageSlug; self.pageTitle = pageTitle
        }

        enum CodingKeys: String, CodingKey {
            case id, threadID, prompt, intervalMinutes, startedAt, rounds, lastRoundDuration,
                 nextRoundAt, active, failed, dismissed, endsAt, weekdaysOnly, pausedSlot,
                 endReason, pageSlug, pageTitle
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            prompt = try c.decode(String.self, forKey: .prompt)
            intervalMinutes = (try? c.decode(Int.self, forKey: .intervalMinutes))
                ?? LoopInterval.defaultMinutes
            startedAt = (try? c.decode(Date.self, forKey: .startedAt)) ?? Date()
            rounds = (try? c.decode(Int.self, forKey: .rounds)) ?? 0
            lastRoundDuration = (try? c.decode(TimeInterval.self, forKey: .lastRoundDuration)) ?? 0
            threadID = try? c.decodeIfPresent(UUID.self, forKey: .threadID)
            nextRoundAt = try? c.decodeIfPresent(Date.self, forKey: .nextRoundAt)
            active = try? c.decodeIfPresent(Bool.self, forKey: .active)
            failed = try? c.decodeIfPresent(Bool.self, forKey: .failed)
            dismissed = try? c.decodeIfPresent(Bool.self, forKey: .dismissed)
            endsAt = try? c.decodeIfPresent(Date.self, forKey: .endsAt)
            weekdaysOnly = try? c.decodeIfPresent(Bool.self, forKey: .weekdaysOnly)
            pausedSlot = try? c.decodeIfPresent(Date.self, forKey: .pausedSlot)
            endReason = try? c.decodeIfPresent(LoopEndReason.self, forKey: .endReason)
            pageSlug = try? c.decodeIfPresent(String.self, forKey: .pageSlug)
            pageTitle = try? c.decodeIfPresent(String.self, forKey: .pageTitle)
        }
    }

    private static let persistKey = "notch_chat_loops"

    /// Every loop on record, in start order.
    @Published private(set) var loops: [ChatLoop] = []
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var restored = false
    /// Entries on disk this build could not read. Written back unchanged on
    /// every save, so a record never disappears because one build failed to
    /// read it.
    private var unreadable: [Any] = []

    /// Starts round `round` of loop `loopID` on thread `threadID`; false when
    /// it could not start. Set by `NotchModel`, which owns the chat pipeline.
    var runRound: ((_ threadID: UUID, _ prompt: String, _ round: Int, _ loopID: UUID) -> Bool)?
    /// Whether any round is streaming on the thread right now.
    var isThreadBusy: ((UUID) -> Bool)?

    private init() {
        loadFromDisk()
    }

    /// The loop with this id.
    func loop(for id: UUID) -> ChatLoop? { loops.first { $0.id == id } }

    /// Moves a loop's later rounds to another thread (a loop moved out of the
    /// main thread into a sub-thread of its own).
    func rehome(loopID: UUID, to threadID: UUID) {
        guard let i = loops.firstIndex(where: { $0.id == loopID }) else { return }
        loops[i].threadID = threadID
        persist()
    }
    func isActive(_ id: UUID) -> Bool { loop(for: id)?.active == true }

    /// Binds a Notchi page to a loop so subsequent rounds automatically append
    /// to it instead of piling reports into the thread.
    func bindPage(loopID: UUID, slug: String, title: String?) {
        guard let i = loops.firstIndex(where: { $0.id == loopID }) else { return }
        var changed = false
        if loops[i].pageSlug != slug {
            loops[i].pageSlug = slug
            changed = true
        }
        if let title, !title.isEmpty, loops[i].pageTitle != title {
            loops[i].pageTitle = title
            changed = true
        }
        if changed {
            persist()
            LoopLog.write("bindPage \(LoopLog.short(loopID)) slug=\(slug)")
        }
    }
    /// The loops whose rounds answer in `threadID`, in start order.
    func loops(onThread threadID: UUID) -> [ChatLoop] { loops.filter { $0.threadID == threadID } }
    func hasActiveLoop(onThread threadID: UUID) -> Bool {
        loops.contains { $0.threadID == threadID && $0.active }
    }
    /// The loops the task list shows.
    var listed: [ChatLoop] { loops.filter { !$0.dismissed } }

    /// The loop a turn belongs to: the turn's own `loopID`, or — on a turn saved
    /// before turns carried one — the loop whose id is the thread's.
    func loopID(forTurnLoopID turnLoopID: UUID?, threadID: UUID) -> UUID {
        turnLoopID ?? threadID
    }

    /// The ⌘ card's facts for a thread, one per loop. A loop thread with no
    /// record (stopped and dismissed before stopped loops were kept) reads as
    /// one stopped loop, from its turns, under the thread's id.
    func menuInfo(forThread threadID: UUID, turns: [NotchModel.Turn]) -> [LoopMenuInfo] {
        let found = loops(onThread: threadID)
        if !found.isEmpty { return found.map(\.menuInfo) }
        guard let rounds = turns.compactMap(\.loopRound).max() else { return [] }
        let prompt = turns.first(where: { $0.role == "user" })?.text ?? ""
        return [LoopMenuInfo(id: threadID, prompt: prompt,
                             intervalMinutes: LoopInterval.lastMinutes, rounds: rounds,
                             nextRoundAt: nil, active: false)]
    }

    /// Arm the waits. `NotchModel` calls this after Recent is on disk and
    /// `runRound` is wired, so a due round continues the saved thread.
    func restore() {
        guard !restored else { return }
        restored = true
        let now = Date()
        for i in loops.indices where loops[i].active && (loops[i].endsAt.map { $0 < now } ?? false) {
            loops[i].active = false
            loops[i].nextRoundAt = nil
            loops[i].endReason = .endDate
            LoopLog.write("restore \(LoopLog.short(loops[i].id)) end-date passed")
        }
        persist()
        for loop in loops where loop.active && !loop.isRunning {
            let next = loop.nextRoundAt ?? now.addingTimeInterval(loop.interval)
            schedule(loop.id, at: next)
        }
        LoopLog.write("restore active=\(loops.filter(\.active).count) total=\(loops.count)")
    }

    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistKey) else { return }
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            // Not a list this build can read at all. Keep the bytes under a
            // side key before anything is saved over them.
            UserDefaults.standard.set(data, forKey: Self.persistKey + ".unreadable")
            LoopLog.write("load failed: \(data.count) bytes kept under \(Self.persistKey).unreadable")
            return
        }
        let now = Date()
        let decoder = JSONDecoder()
        for element in array {
            guard let one = try? JSONSerialization.data(withJSONObject: element),
                  let record = try? decoder.decode(Record.self, from: one) else {
                unreadable.append(element)
                continue
            }
            let active = record.active ?? true
            let next = active ? record.nextRoundAt
                ?? now.addingTimeInterval(TimeInterval(record.intervalMinutes * 60)) : nil
            loops.append(ChatLoop(id: record.id, threadID: record.threadID ?? record.id,
                                  prompt: record.prompt,
                                  intervalMinutes: record.intervalMinutes,
                                  startedAt: record.startedAt, rounds: record.rounds,
                                  roundStartedAt: nil,
                                  lastRoundDuration: record.lastRoundDuration,
                                  nextRoundAt: next, active: active,
                                  failed: record.failed ?? false,
                                  dismissed: record.dismissed ?? false,
                                  endsAt: record.endsAt,
                                  weekdaysOnly: record.weekdaysOnly ?? false,
                                  pausedSlot: active ? nil : record.pausedSlot,
                                  endReason: active ? nil : record.endReason,
                                  pageSlug: record.pageSlug,
                                  pageTitle: record.pageTitle))
        }
        LoopLog.write("load \(loops.count) loops, \(unreadable.count) unreadable")
    }

    /// Round one of loop `id` has just been handed to the chat pipeline on
    /// `threadID`.
    func register(id: UUID, threadID: UUID, prompt: String, minutes: Int,
                  endsAt: Date? = nil, weekdaysOnly: Bool = false) {
        loops.removeAll { $0.id == id }
        loops.append(ChatLoop(id: id, threadID: threadID, prompt: prompt,
                              intervalMinutes: minutes, startedAt: Date(),
                              endsAt: endsAt, weekdaysOnly: weekdaysOnly))
        persist()
        LoopLog.write("start \(LoopLog.short(id)) thread=\(LoopLog.short(threadID)) every=\(minutes)m round 1 now")
    }

    /// A loop whose round one waits for `firstRoundAt` ("every morning at 9").
    /// Nothing has run yet.
    func register(id: UUID, threadID: UUID, prompt: String, minutes: Int, firstRoundAt: Date,
                  endsAt: Date? = nil, weekdaysOnly: Bool = false) {
        loops.removeAll { $0.id == id }
        loops.append(ChatLoop(id: id, threadID: threadID, prompt: prompt,
                              intervalMinutes: minutes, startedAt: firstRoundAt, rounds: 0,
                              roundStartedAt: nil, endsAt: endsAt, weekdaysOnly: weekdaysOnly))
        LoopLog.write("start \(LoopLog.short(id)) thread=\(LoopLog.short(threadID)) every=\(minutes)m first=\(firstRoundAt)")
        schedule(id, at: firstRoundAt)
    }

    /// A loop started by manage_loop from an answer on thread `threadID`. Round
    /// one runs when that answer's round finishes (`roundFinished`); the timer
    /// here is only the fallback if that finish never lands.
    func registerAfterCurrentRound(id: UUID, threadID: UUID, prompt: String, minutes: Int,
                                   endsAt: Date? = nil, weekdaysOnly: Bool = false) {
        register(id: id, threadID: threadID, prompt: prompt, minutes: minutes,
                 firstRoundAt: Date().addingTimeInterval(Self.firstRoundFallback),
                 endsAt: endsAt, weekdaysOnly: weekdaysOnly)
    }

    private static let firstRoundFallback: TimeInterval = 60

    /// A round on thread `threadID` finished. `loopRound` is the round number
    /// its answer carried and `loopID` the loop it belongs to — nil for a
    /// follow-up the user typed into the thread, which keeps every loop's
    /// schedule and does not count as a round. `quietly` is a round superseded
    /// before it answered: the wait restarts, no banner. `done` is a round
    /// whose answer carried `LoopInterval.doneMarker`: the loop pauses there.
    func roundFinished(threadID: UUID, loopID: UUID?, loopRound: Int?, failed: Bool,
                       quietly: Bool = false, done: Bool = false, answer: String = "") {
        defer { runHeldRounds(onThread: threadID) }
        guard loopRound != nil else { return }
        let id = loopID ?? threadID
        guard let i = loops.firstIndex(where: { $0.id == id }), loops[i].active else { return }
        if let started = loops[i].roundStartedAt {
            loops[i].lastRoundDuration = Date().timeIntervalSince(started)
            loops[i].roundStartedAt = nil
        }
        if quietly {
            LoopLog.write("round \(LoopLog.short(id)) #\(loopRound ?? 0) superseded")
            schedule(id)
            return
        }
        let loop = loops[i]
        // The round reports the user's stop condition met. The loop pauses on
        // its schedule and the banner asks the user; it does not end here.
        if done {
            LoopLog.write("round \(LoopLog.short(id)) #\(loopRound ?? 0) wrote the done marker")
            pause(id, reason: .doneSuggested)
            notify(loop, subtitle: L("notify.loop.doneSuggested"),
                   silent: false, answer: answer)
            return
        }
        if let endsAt = loop.endsAt, Date().addingTimeInterval(loop.interval) > endsAt {
            end(id, failed: failed, reason: .endDate)
            notify(loop, subtitle: L("notify.loop.endDate", loop.rounds),
                   silent: false, answer: answer)
            return
        }
        LoopLog.write("round \(LoopLog.short(id)) #\(loopRound ?? 0) \(failed ? "failed" : "ok")")
        notify(loop, subtitle: "",
               silent: true, answer: answer)
        // A failed round does not end the loop; only Stop does. Offline, the
        // next round runs as soon as the network is back.
        if failed {
            schedule(id, at: LoopInterval.nextAfterFailure(intervalMinutes: loop.intervalMinutes))
        } else {
            schedule(id)
        }
    }

    /// A round on the thread just ended, so the thread is free. Rounds held
    /// back while it streamed (due now, or within the fallback wait) run now,
    /// one at a time: the first one to start makes the thread busy again, and
    /// the rest wait for its finish.
    private func runHeldRounds(onThread threadID: UUID) {
        for loop in loops where loop.threadID == threadID && loop.isWaiting {
            let due = loop.nextRoundAt ?? Date()
            if due.timeIntervalSinceNow <= Self.firstRoundFallback {
                schedule(loop.id, at: Date())
            }
        }
    }

    /// The Stop in the loop's ⌘ card. A round already streaming finishes; no
    /// further round starts.
    func stop(_ id: UUID, file: String = #fileID, line: Int = #line) {
        guard isActive(id) else { return }
        LoopLog.write("stop \(LoopLog.short(id)) from \(file):\(line)")
        end(id, failed: false, reason: .stopped)
    }

    /// The Continue in a stopped loop's ⌘ card. The next round runs now.
    /// `turns` rebuilds a loop thread that has no record (see `menuInfo`).
    func resume(_ id: UUID, threadID: UUID? = nil, turns: [NotchModel.Turn] = [],
                file: String = #fileID, line: Int = #line) {
        if loop(for: id) == nil, let threadID,
           let rounds = turns.compactMap(\.loopRound).max(),
           let prompt = turns.first(where: { $0.role == "user" })?.text {
            loops.append(ChatLoop(id: id, threadID: threadID, prompt: prompt,
                                  intervalMinutes: LoopInterval.lastMinutes,
                                  startedAt: Date(), rounds: rounds,
                                  roundStartedAt: nil, active: false))
        }
        guard let i = loops.firstIndex(where: { $0.id == id }), !loops[i].active
        else { return }
        LoopLog.write("continue \(LoopLog.short(id)) from \(file):\(line)")
        loops[i].active = true
        loops[i].failed = false
        loops[i].dismissed = false
        loops[i].pausedSlot = nil
        loops[i].endReason = nil
        loops[i].startedAt = Date()
        persist()
        schedule(id, at: Date())
    }

    /// The Routines switch's off. Like Stop — a round already streaming
    /// finishes — but the slot the next round was due in is kept for `unpause`.
    func pause(_ id: UUID, reason: LoopEndReason = .paused,
               file: String = #fileID, line: Int = #line) {
        guard let loop = loop(for: id), loop.active else { return }
        LoopLog.write("pause \(LoopLog.short(id)) reason=\(reason.rawValue) from \(file):\(line)")
        let slot = loop.nextRoundAt
            ?? loop.roundStartedAt.map { $0.addingTimeInterval(loop.interval) }
            ?? Date().addingTimeInterval(loop.interval)
        end(id, failed: false, reason: reason)
        guard let i = loops.firstIndex(where: { $0.id == id }) else { return }
        loops[i].pausedSlot = slot
        persist()
    }

    /// The Routines switch's on. Unlike Continue, nothing runs now: the next
    /// round is the paused schedule's next slot.
    func unpause(_ id: UUID, file: String = #fileID, line: Int = #line) {
        guard let i = loops.firstIndex(where: { $0.id == id }), !loops[i].active
        else { return }
        LoopLog.write("unpause \(LoopLog.short(id)) from \(file):\(line)")
        let next = LoopInterval.nextSlot(from: loops[i].pausedSlot,
                                         minutes: loops[i].intervalMinutes)
        loops[i].active = true
        loops[i].failed = false
        loops[i].dismissed = false
        loops[i].pausedSlot = nil
        loops[i].endReason = nil
        loops[i].startedAt = Date()
        schedule(id, at: next)
    }

    /// manage_loop's delete: the loop stops if it is running and leaves the
    /// task list and Routines, on or off. The thread stays in Recent.
    func delete(_ id: UUID, file: String = #fileID, line: Int = #line) {
        LoopLog.write("delete \(LoopLog.short(id)) from \(file):\(line)")
        if isActive(id) { end(id, failed: false, reason: .stopped) }
        dismiss(id)
    }

    /// Drop a finished loop's row from the task list. The thread stays in
    /// Recent and can still continue the loop.
    func dismiss(_ id: UUID) {
        guard let i = loops.firstIndex(where: { $0.id == id }), !loops[i].active
        else { return }
        loops[i].dismissed = true
        persist()
    }

    /// The thread was deleted from Recent: its stopped loops go with it. A
    /// running loop keeps running and starts the thread again.
    func forgetStopped(onThread threadID: UUID) {
        let gone = loops.filter { $0.threadID == threadID && !$0.active }
        guard !gone.isEmpty else { return }
        for loop in gone {
            timers[loop.id]?.cancel()
            timers[loop.id] = nil
            LoopLog.write("forget \(LoopLog.short(loop.id)) (thread deleted)")
        }
        loops.removeAll { $0.threadID == threadID && !$0.active }
        persist()
    }

    /// The header chip's new pick. A waiting loop restarts its wait from now;
    /// a round already streaming keeps going and uses the new gap after it.
    func setInterval(_ id: UUID, minutes: Int) {
        guard LoopInterval.typedRange.contains(minutes),
              let i = loops.firstIndex(where: { $0.id == id }), loops[i].active
        else { return }
        LoopInterval.remember(minutes)
        loops[i].intervalMinutes = minutes
        persist()
        LoopLog.write("interval \(LoopLog.short(id)) every=\(minutes)m")
        if loops[i].isWaiting { schedule(id) }
    }

    private func end(_ id: UUID, failed: Bool, reason: LoopEndReason) {
        timers[id]?.cancel()
        timers[id] = nil
        guard let i = loops.firstIndex(where: { $0.id == id }) else { return }
        loops[i].active = false
        loops[i].failed = failed
        loops[i].endReason = reason
        loops[i].nextRoundAt = nil
        if let started = loops[i].roundStartedAt {
            loops[i].lastRoundDuration = Date().timeIntervalSince(started)
        }
        loops[i].roundStartedAt = nil
        persist()
        LoopLog.write("end \(LoopLog.short(id)) reason=\(reason.rawValue) after \(loops[i].rounds) rounds")
    }

    private func schedule(_ id: UUID, after delay: TimeInterval? = nil, at date: Date? = nil) {
        guard let i = loops.firstIndex(where: { $0.id == id }), loops[i].active else { return }
        var next = date ?? Date().addingTimeInterval(delay ?? loops[i].interval)
        if loops[i].weekdaysOnly {
            while Calendar.current.isDateInWeekend(next) {
                next = Calendar.current.date(byAdding: .day, value: 1, to: next) ?? next.addingTimeInterval(86400)
            }
        }
        loops[i].nextRoundAt = next
        persist()
        timers[id]?.cancel()
        timers[id] = Task { [weak self] in
            do { try await LoopInterval.wait(until: next) } catch { return }
            self?.fire(id)
        }
    }

    private func persist() {
        // A round in flight is stored as not yet run and due when it started:
        // if the app quits mid-round, the same round runs again at launch
        // instead of the loop skipping to one interval later.
        let records: [Record] = loops.map { loop in
            Record(id: loop.id, threadID: loop.threadID, prompt: loop.prompt,
                   intervalMinutes: loop.intervalMinutes,
                   startedAt: loop.startedAt,
                   rounds: loop.isRunning ? max(loop.rounds - 1, 0) : loop.rounds,
                   lastRoundDuration: loop.lastRoundDuration,
                   nextRoundAt: loop.roundStartedAt ?? loop.nextRoundAt,
                   active: loop.active, failed: loop.failed,
                   dismissed: loop.dismissed, endsAt: loop.endsAt,
                   weekdaysOnly: loop.weekdaysOnly, pausedSlot: loop.pausedSlot,
                   endReason: loop.active ? nil : loop.endReason,
                   pageSlug: loop.pageSlug, pageTitle: loop.pageTitle)
        }
        guard let encoded = try? JSONEncoder().encode(records) else {
            LoopLog.write("save failed: could not encode \(records.count) loops")
            return
        }
        var data = encoded
        if !unreadable.isEmpty,
           var array = (try? JSONSerialization.jsonObject(with: encoded)) as? [Any] {
            array.append(contentsOf: unreadable)
            if let merged = try? JSONSerialization.data(withJSONObject: array) { data = merged }
        }
        UserDefaults.standard.set(data, forKey: Self.persistKey)
    }

    private func fire(_ id: UUID) {
        timers[id] = nil
        guard let i = loops.firstIndex(where: { $0.id == id }), loops[i].active,
              !loops[i].isRunning else { return }
        // A weekday skip can carry the next round past the end date.
        if let endsAt = loops[i].endsAt, Date() > endsAt {
            let loop = loops[i]
            end(id, failed: false, reason: .endDate)
            notify(loop, subtitle: L("notify.loop.endDate", loop.rounds), silent: false, answer: "")
            return
        }
        let threadID = loops[i].threadID
        // Another round (a follow-up, or another loop's round) is streaming on
        // the thread: let it finish. Its finish runs this round
        // (`runHeldRounds`); this is only the fallback if that never lands.
        // A round this manager just started counts too: it is not in the
        // chat pipeline's in-flight list until its submit has run.
        let siblingRunning = loops.contains {
            $0.threadID == threadID && $0.id != id && $0.isRunning
        }
        if siblingRunning || isThreadBusy?(threadID) == true {
            LoopLog.write("fire \(LoopLog.short(id)) held: thread busy")
            schedule(id, after: Self.firstRoundFallback)
            return
        }
        loops[i].rounds += 1
        loops[i].roundStartedAt = Date()
        loops[i].nextRoundAt = nil
        persist()
        let loop = loops[i]
        if runRound?(threadID, loop.prompt, loop.rounds, id) == true {
            LoopLog.write("fire \(LoopLog.short(id)) round #\(loop.rounds) started")
            return
        }
        // The round could not start (an answer still streaming on screen, an
        // archive that hasn't caught up). A missed round is not a dead loop:
        // give the round number back and try again shortly.
        guard let j = loops.firstIndex(where: { $0.id == id }) else { return }
        loops[j].rounds -= 1
        loops[j].roundStartedAt = nil
        LoopLog.write("fire \(LoopLog.short(id)) could not start; retry in \(Int(Self.firstRoundFallback))s")
        schedule(id, after: Self.firstRoundFallback)
    }

    private func notify(_ loop: ChatLoop, subtitle: String, silent: Bool,
                        answer: String) {
        NotificationService.shared.postAnswerReady(
            threadID: loop.threadID, title: nil, question: loop.prompt,
            answer: answer, subtitle: subtitle, silent: silent)
    }
}

// MARK: - Interval card

/// The interval chip's card: a minutes field on top, then the presets, then —
/// when the compose chip opened it — a row that lifts `/loop` without wiping
/// the prompt. A menu card never takes key focus (`MenuCardPanel`), so the
/// field reads keys through a local monitor while the card is up and the
/// prompt under it never sees them.
struct LoopIntervalMenu: View {
    let selected: Int
    let onSelect: (Int) -> Void
    let onDone: () -> Void
    /// Lifts the armed loop and keeps whatever is already in the prompt. Nil
    /// on a loop already running — that one stops from its own Stop, not here.
    var onClear: (() -> Void)? = nil

    /// The number the caret sits in — digits only. The unit is its own segment
    /// at the field's trailing edge, so a Delete takes a digit, never the unit.
    @State private var digits = ""
    @State private var unit: LoopUnit = .minutes
    /// The seeded value, not yet edited: the first digit or Delete replaces it
    /// whole, the way a selected field behaves.
    @State private var pristine = true
    @State private var highlight: Int? = nil
    @State private var keyMonitor: Any? = nil
    @State private var caretOn = true

    enum LoopUnit: Character {
        case minutes = "m", hours = "h", days = "d"

        var label: String {
            switch self {
            case .minutes: return L("loop.minutes")
            case .hours:   return L("loop.hours")
            case .days:    return L("loop.days")
            }
        }

        var factor: Int {
            switch self {
            case .minutes: return 1
            case .hours:   return 60
            case .days:    return 1440
            }
        }
    }

    private var parsed: Int? {
        guard let n = Int(digits), n > 0 else { return nil }
        let minutes = n * unit.factor
        return LoopInterval.typedRange.contains(minutes) ? minutes : nil
    }
    private var valid: Bool { digits.isEmpty || parsed != nil }
    private var offIndex: Int { LoopInterval.presets.count }
    private var rowCount: Int { LoopInterval.presets.count + (onClear == nil ? 0 : 1) }

    private var matchingPreset: Int? {
        parsed.flatMap { LoopInterval.presets.firstIndex(of: $0) }
    }

    private var width: CGFloat {
        var titles: [(String, String?)] = LoopInterval.presets.map {
            (LoopInterval.short($0), String?.none)
        }
        let unitWidest = [LoopUnit.minutes, .hours, .days]
            .max(by: { $0.label.count < $1.label.count })?.label
        titles.append(("0000", unitWidest))
        if onClear != nil { titles.append((L("loop.off"), nil)) }
        return MenuCard.width(titles: titles)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MenuCard.rowSpacing) {
            field
                .padding(.bottom, 3)
            ForEach(Array(LoopInterval.presets.enumerated()), id: \.offset) { index, minutes in
                MenuCardRow(title: LoopInterval.short(minutes),
                            emphasized: rowSelected(index),
                            selected: rowSelected(index),
                            onHoverIn: { highlight = index },
                            action: { pick(minutes) })
            }
            if onClear != nil {
                MenuCardRow(title: L("loop.off"),
                            selected: highlight == offIndex,
                            onHoverIn: { highlight = offIndex },
                            action: { onClear?() })
                    .padding(.top, 3)
            }
        }
        .padding(MenuCard.cardPad)
        .frame(width: width, alignment: .leading)
        .onAppear {
            seedField()
            installKeyMonitor()
        }
        .onDisappear(perform: removeKeyMonitor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("loop.chip.help"))
    }

    private func rowSelected(_ index: Int) -> Bool {
        if let highlight { return highlight == index }
        return matchingPreset == index
    }

    /// Settings' recessed field (`recessedSurface`, lit — it holds the keyboard
    /// while the card is up) at the card's row height. It opens on the interval
    /// already in effect, so the field is never a blank slot: digits at the
    /// caret, unit pinned to the trailing edge, switched with m / h / d.
    private var field: some View {
        HStack(spacing: 0) {
            Text(digits)
                .font(.sf(MenuCard.fontSize, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(valid ? Tokens.text1 : Tokens.danger)
            Rectangle()
                .fill(Tokens.text1)
                .frame(width: 1.5, height: 13)
                .opacity(caretOn ? 1 : 0)
                .padding(.leading, 1)
            Spacer(minLength: 8)
            Text(unit.label)
                .font(.sf(MenuCard.fontSize))
                .foregroundStyle(Tokens.text3)
        }
        .padding(.horizontal, 10)
        .frame(height: MenuCard.rowHeight)
        .recessedSurface(in: RoundedRectangle.control, lit: true)
        .accessibilityLabel(L("loop.chip.help"))
        .accessibilityValue("\(digits) \(unit.label)")
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 530_000_000)
                caretOn.toggle()
            }
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods.isDisjoint(with: [.command, .control, .option]) else { return event }
            switch event.keyCode {
            case 51, 117:                    // Delete / Forward Delete
                if pristine { digits = "" } else if !digits.isEmpty { digits.removeLast() }
                pristine = false
                highlight = nil
                return nil
            case 36, 76: commit(); return nil // Return / keypad Enter
            case 53: onDone(); return nil     // Esc
            case 126: step(-1); return nil    // ↑
            case 125: step(1); return nil     // ↓
            default:
                guard let raw = event.charactersIgnoringModifiers, let c = raw.first, c.isASCII
                else { return event }
                if c.isNumber {
                    if pristine { digits = "" }
                    pristine = false
                    if digits.count < 4 { digits.append(c) }
                    highlight = nil
                    return nil
                }
                if let key = c.lowercased().first, let picked = LoopUnit(rawValue: key) {
                    unit = picked
                    pristine = false
                    highlight = nil
                    return nil
                }
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    private func pick(_ minutes: Int) {
        LoopInterval.remember(minutes)
        onSelect(minutes)
    }

    private func commit() {
        // A row under the pointer (or the arrow keys) is the pick; typing into
        // the field drops the highlight, so the field wins after an edit.
        if let h = highlight {
            if h == offIndex { onClear?() } else { pick(LoopInterval.presets[h]) }
            return
        }
        if let value = parsed {
            pick(value)
            return
        }
        if !digits.isEmpty {
            Haptics.alignment()
            return
        }
        onDone()
    }

    /// Arrow keys walk the presets and mirror the highlighted one into the
    /// field, so Return commits what the field reads.
    private func step(_ delta: Int) {
        let current = highlight ?? matchingPreset ?? -1
        let next = min(max(current + delta, 0), rowCount - 1)
        highlight = next
        if next < LoopInterval.presets.count { setField(LoopInterval.presets[next]) }
    }

    private func seedField() { setField(selected) }

    /// Split minutes into the coarsest whole unit it fits: 1440 → `1 day`,
    /// 360 → `6 hr`, 90 → `90 min`.
    private func setField(_ minutes: Int) {
        if minutes % 1440 == 0 { digits = "\(minutes / 1440)"; unit = .days }
        else if minutes % 60 == 0 { digits = "\(minutes / 60)"; unit = .hours }
        else { digits = "\(minutes)"; unit = .minutes }
        pristine = true
    }
}

/// The compose chip's card, glass already on. Live loops reuse `LoopIntervalMenu`
/// without `onClear` — stopping is its own control.
struct LoopIntervalMenuCard: View {
    let selected: Int
    let onSelect: (Int) -> Void
    let onDone: () -> Void
    var onClear: (() -> Void)? = nil

    var body: some View {
        LoopIntervalMenu(selected: selected, onSelect: onSelect, onDone: onDone,
                         onClear: onClear)
            .preferredColorScheme(.dark)
            .menuCardBackground()
    }
}

/// Quiet header control for a loop already running. Hover brightens it so it
/// reads as a chip, not a label; the card is the compose interval menu.
struct LoopScheduleChip: View {
    let minutes: Int
    @Binding var open: Bool
    let onSelect: (Int) -> Void

    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                LucideIcon(mark: LucideIcons.loop, size: 11)
                Text(L("loop.every", LoopInterval.short(minutes)))
                    .monospacedDigit()
            }
            .font(.sf(Tokens.TypeSize.meta))
            .foregroundStyle(hovering ? Tokens.text2 : Tokens.text4)
            .lineLimit(1)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).exemptsDoubleClickPin()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        .notchTooltip(L("loop.change"))
        .accessibilityLabel(L("loop.change"))
        .modifier(MenuCardWindow(
            open: open,
            onDismiss: { _ in open = false },
            card: {
                AnyView(LoopIntervalMenuCard(
                    selected: minutes,
                    onSelect: { value in
                        onSelect(value)
                        open = false
                    },
                    onDone: { open = false }))
            }))
    }
}

// MARK: - Round column

/// A loop record's right column: one row per round, plus any follow-up typed
/// between rounds. Each row is a `RailTick`; the round's name shows as a
/// tooltip.
///
/// The column is *sticky*: it rides the visible top of the record instead of
/// the record's layout top, so a round taller than the viewport doesn't carry
/// the round list off screen. Mount it as a `.overlay(alignment: .topTrailing)`
/// on the record body, with the body padded by `width` + its gutter — the
/// overlay's frame is the travel the column slides along. See
/// `StickyColumn`.
struct LoopRoundSidebar: View {
    struct Item: Identifiable {
        let id: Int
        let title: String
        var isFollowUp = false
        var running = false
    }

    static let width: CGFloat = RailTick.hitWidth

    let items: [Item]
    let selected: Int
    let onSelect: (Int) -> Void

    private static var rowStride: CGFloat { RailTick.rowHeight }

    /// The column's laid-out height for `rows` rounds. The record reserves this
    /// much height so a short round can't let the column hang off its bottom.
    static func height(rows: Int) -> CGFloat {
        CGFloat(max(rows, 1)) * rowStride
    }

    @Environment(\.stickyScrollTopInset) private var stickyTopInset
    /// The tick under the pointer, by index into `items`.
    @State private var hoveredIndex: Int?

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                LoopRoundSidebarRow(item: item, selected: item.id == selected,
                                    hoverDistance: hoveredIndex.map { abs($0 - index) },
                                    onHover: { inside in
                                        if inside { hoveredIndex = index }
                                        else if hoveredIndex == index { hoveredIndex = nil }
                                    }) {
                    withAnimation(.easeOut(duration: 0.16)) { onSelect(item.id) }
                }
            }
        }
        .frame(width: Self.width, alignment: .topTrailing)
        .modifier(StickyColumn(rows: items.count, topInset: stickyTopInset))
    }
}

/// Holds the round column at the visible top of the record it overlays.
/// `bounds(of: .scrollView)` hands back the thread scroller's visible rect in
/// the overlay's own coordinates, so a positive `minY` is exactly the slice of
/// the record that has scrolled up past the viewport top — push the column down
/// by that much, plus the host's dissolve band (`stickyScrollTopInset`).
///
/// Clamped at both ends: never above the record's top, and never past the point
/// where the column's own bottom reaches the record's, so it leaves with the
/// record instead of hanging off it. Returns 0 where there is no scroller —
/// then the column sits at the record's top.
private struct StickyColumn: ViewModifier {
    let rows: Int
    let topInset: CGFloat

    func body(content: Content) -> some View {
        GeometryReader { geo in
            content.offset(y: offset(in: geo))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(width: LoopRoundSidebar.width)
    }

    private func offset(in geo: GeometryProxy) -> CGFloat {
        guard let visible = geo.bounds(of: .scrollView) else { return 0 }
        let travel = max(geo.size.height - LoopRoundSidebar.height(rows: rows), 0)
        return min(max(visible.minY + topInset, 0), travel)
    }
}

private struct LoopRoundSidebarRow: View {
    let item: LoopRoundSidebar.Item
    let selected: Bool
    let hoverDistance: Int?
    let onHover: (Bool) -> Void
    let action: () -> Void

    var body: some View {
        RailTick(selected: selected, hoverDistance: hoverDistance, alignment: .trailing,
                 onHover: onHover, action: action)
            .notchTooltip(item.title)
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityValue(item.running ? L("agent.thinking") : "")
            .id(item.id)
    }
}
