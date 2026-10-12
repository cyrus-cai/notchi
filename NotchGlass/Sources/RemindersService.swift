import EventKit
import Foundation

/// Why a reminder write failed, so the idle view can show the right recovery
/// hint (grant Reminders access vs. a generic retry) instead of a raw
/// EventKit message.
enum RemindersError: LocalizedError {
    /// TCC denied Reminders access (or the user clicked "Don't Allow").
    case permissionDenied
    /// No default list to file into (no Reminders account configured).
    case noList
    /// Anything else, carrying the EventKit message for debugging.
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return L("reminders.error.permission")
        case .noList:
            return L("reminders.error.noList")
        case .saveFailed(let msg):
            return msg
        }
    }
}

/// Files time-bound lines into Apple's Reminders app via EventKit.
///
/// This is the second half of the note branch's split: the intent engine only
/// decides ask-vs-note (a *semantic* read); whether a note is a **reminder** is
/// a *structural* read — does the line name a future point in time? — answered
/// deterministically by `futureDate(in:)` below. The date that decides the
/// routing is the same date filed as the reminder's due date, so the "Remind"
/// hint and the alarm that fires later can never disagree.
///
/// Unlike `NotesService` there's no AppleScript here: EventKit talks to the
/// reminders store directly. `requestFullAccessToReminders` is natively async
/// (its callback arrives off-main after the one-time TCC prompt), so the
/// main-thread deadlock dance the Notes path needs doesn't apply.
enum RemindersService {
    /// The live EventKit connection. NOT a `static let`: an `EKEventStore` caches
    /// the TCC grant it was created under for its whole lifetime, so if the user
    /// revokes Reminders access in System Settings and re-grants it, a store made
    /// before the revoke keeps reporting the *old* state — `requestFullAccess…`
    /// returns `granted: false` forever and the app loops the user back to
    /// Settings until relaunch. `currentStore()` rebuilds the instance whenever the
    /// system authorization status no longer matches the one the cached store was
    /// born under, so a fresh connection picks up the new grant without a restart.
    private static var _store = EKEventStore()
    /// The authorization status at the moment `_store` was created. A mismatch
    /// against the live status means a revoke/regrant happened out from under us.
    private static var _storeStatus = EKEventStore.authorizationStatus(for: .reminder)
    /// Guards the lazy rebuild — `createReminder` can be called from the main
    /// thread while a prior request's callback runs on EventKit's queue.
    private static let storeLock = NSLock()

    /// The store to use for this operation, rebuilt if Reminders authorization has
    /// changed since the cached one was created. Always call this instead of
    /// touching `_store` directly so a revoke→regrant is picked up live.
    private static func currentStore() -> EKEventStore {
        storeLock.lock()
        defer { storeLock.unlock() }
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status != _storeStatus {
            _store = EKEventStore()
            _storeStatus = status
        }
        return _store
    }

    // MARK: - Date detection (what makes a note a reminder)

    /// System date parser — handles natural phrasing in the languages the app
    /// targets ("明天下午三点", "周日早上十点", "tomorrow 3pm", "friday").
    /// Created once; matching a one-line string costs well under a millisecond,
    /// so callers can run it synchronously per keystroke.
    private static let detector =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// The first *future* moment named in `text`, or `nil` when there isn't one.
    /// Past references ("上周五买的牛奶过期了", "met john last tuesday") return
    /// dates behind now and are filtered out — remembering the past is a note,
    /// not a reminder.
    ///
    /// Two parsers, in order:
    ///   1. `ChineseRelativeDate` — a deterministic Swift parser for the *relative*
    ///      中文 phrasings NSDataDetector misses outright ("三天后", "两周后",
    ///      "下月15号", "5分钟后", "月底"). It's checked first because on the few
    ///      mixed lines where the detector *does* fire it tends to mis-anchor the
    ///      offset, and an explicit anchor to `Calendar.current` is always right.
    ///   2. NSDataDetector — the OS parser, which already nails absolute and
    ///      named-weekday phrasing ("周三", "明天下午三点", "1月15号", "tomorrow 3pm").
    /// The relative parser returns nil on anything it doesn't recognize, so ordinary
    /// absolute lines fall straight through to the detector unchanged.
    static func futureDate(in text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let now = Date()
        if let relative = ChineseRelativeDate.parse(text, now: now), relative > now {
            return relative
        }
        guard let detector else { return nil }
        return detector
            .matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
            .compactMap(\.date)
            .first { $0 > now }
    }

    // MARK: - Recurrence detection

    /// The repeat pattern named in `text`, or `nil` for a one-shot line. This is
    /// the keyword companion to `futureDate(in:)`: NSDataDetector finds *when* the
    /// first fire is, this finds *whether it repeats*. Plain lowercased substring
    /// checks (no regex — avoids escaping pitfalls) over the phrasings the app's
    /// users actually type, EN + 中文. A `.weekly(nil)` means "repeats weekly but no
    /// specific weekday was named" — `write` resolves that to the due date's own
    /// weekday (so "remind me weekly" typed on a Thursday repeats on Thursdays).
    /// Weekday-specific patterns are checked BEFORE the generic weekly fallback.
    enum RecurrenceKind: Equatable {
        case daily
        case weekly(EKWeekday?)
        case monthly
    }

    static func recurrenceKind(in text: String) -> RecurrenceKind? {
        let s = text.lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { s.contains($0) } }

        // Monthly — checked first so "每月" / "monthly" never get shadowed by a
        // stray "week"/"day" substring elsewhere in the line.
        if has(["every month", "each month", "monthly", "每月", "每个月"]) {
            return .monthly
        }

        // Specific weekday (EN + 中文) — must precede the generic weekly check.
        let weekdayMap: [(needles: [String], day: EKWeekday)] = [
            (["every monday", "every mon ", "每周一", "每週一", "每星期一", "每礼拜一"], .monday),
            (["every tuesday", "每周二", "每週二", "每星期二", "每礼拜二"], .tuesday),
            (["every wednesday", "每周三", "每週三", "每星期三", "每礼拜三"], .wednesday),
            (["every thursday", "每周四", "每週四", "每星期四", "每礼拜四"], .thursday),
            (["every friday", "每周五", "每週五", "每星期五", "每礼拜五"], .friday),
            (["every saturday", "每周六", "每週六", "每星期六", "每礼拜六"], .saturday),
            (["every sunday", "每周日", "每周天", "每週日", "每星期日", "每星期天", "每礼拜日", "每礼拜天"], .sunday),
        ]
        for entry in weekdayMap where has(entry.needles) {
            return .weekly(entry.day)
        }

        // Generic weekly (no day named) — resolved against the due date in `write`.
        if has(["every week", "each week", "weekly", "每周", "每週", "每星期", "每礼拜"]) {
            return .weekly(nil)
        }

        // Daily.
        if has(["every day", "each day", "everyday", "daily", "every morning",
                "every night", "every evening",
                "每天", "每日", "每早", "每晚", "每天早上", "每晚上"]) {
            return .daily
        }

        return nil
    }

    /// A *synthetic* base date for a recurrence phrase that names no concrete time
    /// — "每天喝水", "remind me every Monday", "monthly rent". Called by NotchModel
    /// ONLY as a fallback when `futureDate(in:)` returns nil, so that dateless
    /// recurring lines still produce a non-nil `detectedDue` and therefore route to
    /// Reminders instead of falling into the Notes branch. Returns nil when there's
    /// no recurrence keyword at all (so `futureDate` stays the sole authority for
    /// ordinary lines). All synthetic times anchor to 9am, the least-surprising
    /// default for "every X" with no clock time.
    static func recurrenceDate(in text: String) -> Date? {
        guard let kind = recurrenceKind(in: text) else { return nil }
        let cal = Calendar.current
        let now = Date()
        let synthesized: Date?
        switch kind {
        case .daily:
            // Tomorrow at 9am.
            let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
            synthesized = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        case .weekly(let day):
            if let day {
                // Next occurrence of that weekday at 9am.
                let comps = DateComponents(hour: 9, minute: 0,
                                           weekday: calendarWeekday(from: day))
                synthesized = cal.nextDate(after: now, matching: comps,
                                           matchingPolicy: .nextTime)
            } else {
                // No specific day → tomorrow 9am (weekday derived from this in `write`).
                let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
                synthesized = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
            }
        case .monthly:
            // First of next month at 9am.
            if let nextMonth = cal.date(byAdding: .month, value: 1, to: now) {
                var c = cal.dateComponents([.year, .month], from: nextMonth)
                c.day = 1; c.hour = 9; c.minute = 0; c.second = 0
                synthesized = cal.date(from: c)
            } else {
                synthesized = nil
            }
        }
        // Unlike `futureDate`, these dates are *synthesized* (not detected from the
        // text), so they normally land in the future by construction — but a DST
        // shift or a skewed system clock can push the computed instant into the past.
        // EventKit would silently accept a past due date and the reminder would never
        // fire (XII-97), so guard the same way `futureDate` does: only return a date
        // still ahead of now.
        guard let synthesized, synthesized > now else { return nil }
        return synthesized
    }

    /// EKWeekday (Sunday = 1 ... Saturday = 7) → Calendar's `.weekday` int, which
    /// uses the same 1...7 Sunday-first convention. Kept explicit so the mapping is
    /// obvious at the call site rather than relying on the raw values lining up.
    private static func calendarWeekday(from day: EKWeekday) -> Int { day.rawValue }

    /// Inverse of `calendarWeekday(from:)`: Calendar's `.weekday` int (1...7,
    /// Sunday-first) → EKWeekday, used to derive a bare "weekly" line's repeat day
    /// from its due date. Falls back to Sunday for an out-of-range value (can't
    /// happen for a real date, but keeps the initializer total).
    private static func ekWeekday(from calendarWeekday: Int) -> EKWeekday {
        EKWeekday(rawValue: calendarWeekday) ?? .sunday
    }

    // MARK: - Write

    /// Create a reminder from `text`, then call `completion` back **on the main
    /// thread** with the outcome. The first call shows the one-time TCC
    /// "access Reminders" prompt; everything after the prompt runs on EventKit's
    /// own queue, so this never blocks the caller.
    ///
    /// `due` is optional on purpose: a Tab override can force a line with no
    /// parseable time into Reminders — it files as a dateless reminder (shows in
    /// the list, just no alarm).
    /// On success the value is a deep link to the saved reminder
    /// (`x-apple-reminderkit://REMCDReminder/<externalID>`), so the record row can
    /// jump back to it; `nil` when EventKit gave back no external identifier
    /// (treated as a soft success — the reminder exists, we just can't link it).
    /// `recurrence` overrides the repeat read from the words (`recurrenceKind`),
    /// for a caller that was told the rule explicitly (`create_reminder`).
    static func createReminder(_ text: String, due: Date?, recurrence: RecurrenceKind? = nil,
                               completion: @escaping @MainActor (Result<String?, RemindersError>) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Task { @MainActor in completion(.success(nil)) }
            return
        }
        // Resolve the store up front so the access request and the subsequent
        // write share one connection — the grant the prompt produces lands on the
        // same store `write` saves through.
        let store = currentStore()
        store.requestFullAccessToReminders { granted, _ in
            let result: Result<String?, RemindersError> =
                granted ? write(trimmed, due: due, recurrence: recurrence, store: store) : .failure(.permissionDenied)
            Task { @MainActor in completion(result) }
        }
    }

    /// Deep link that opens a specific reminder in Reminders.app, built from its
    /// `calendarItemExternalIdentifier` (the iCloud/server UUID, stable for
    /// iCloud-backed lists — the common case). The `REMCDReminder/` path segment
    /// is what makes Reminders navigate to the item rather than just opening to
    /// its default view. The scheme is undocumented but has worked from macOS
    /// Monterey through Tahoe; `openCapture` falls back to opening the app if it
    /// ever stops resolving.
    static func deepLink(externalID: String) -> String {
        "x-apple-reminderkit://REMCDReminder/\(externalID)"
    }

    /// The actual EventKit save. Runs on whatever queue the access callback
    /// arrives on; the store is thread-safe. Takes the `store` explicitly (rather
    /// than reading `currentStore()` again) so it writes through the exact
    /// connection the access was granted on — a concurrent revoke/regrant can't
    /// swap the store out between the grant and the save.
    private static func write(_ text: String, due: Date?, recurrence: RecurrenceKind?,
                              store: EKEventStore) -> Result<String?, RemindersError> {
        guard let list = store.defaultCalendarForNewReminders() else {
            return .failure(.noList)
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        // Reminders titles are single-line: first line becomes the title, any
        // further lines ride along in the notes field rather than being lost.
        let parts = text.split(separator: "\n", maxSplits: 1,
                               omittingEmptySubsequences: false)
        reminder.title = String(parts[0])
        if parts.count > 1 {
            let rest = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty { reminder.notes = rest }
        }
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
            // The due date alone shows in the list but doesn't ring; the alarm is
            // what actually notifies at that moment.
            reminder.addAlarm(EKAlarm(absoluteDate: due))

            // If the line names a repeat ("every Monday", "每天", "monthly"), attach
            // the matching recurrence rule so the reminder actually repeats instead
            // of firing once and vanishing. Only when there IS a due date — a
            // dateless reminder with infinite recurrence reads as broken in the
            // Reminders app, so a Tab-forced dateless line stays one-shot.
            if let kind = recurrence ?? recurrenceKind(in: text) {
                let rule: EKRecurrenceRule
                switch kind {
                case .daily:
                    rule = EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
                case .weekly(let day):
                    // A named weekday repeats on that day; a bare "weekly" repeats on
                    // the due date's own weekday (least surprise).
                    let weekday = day ?? ekWeekday(from:
                        Calendar.current.component(.weekday, from: due))
                    rule = EKRecurrenceRule(
                        recurrenceWith: .weekly, interval: 1,
                        daysOfTheWeek: [EKRecurrenceDayOfWeek(weekday)],
                        daysOfTheMonth: nil, monthsOfTheYear: nil,
                        weeksOfTheYear: nil, daysOfTheYear: nil,
                        setPositions: nil, end: nil)
                case .monthly:
                    rule = EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
                }
                reminder.addRecurrenceRule(rule)
            }
        }
        do {
            try store.save(reminder, commit: true)
            // `calendarItemExternalIdentifier` is only populated after the commit
            // succeeds; read it now to build the row's jump-back link. Empty/absent
            // → nil link (soft success: the reminder saved, it just won't deep-link).
            let link: String?
            if let externalID = reminder.calendarItemExternalIdentifier, !externalID.isEmpty {
                link = deepLink(externalID: externalID)
            } else {
                link = nil
            }
            return .success(link)
        } catch {
            return .failure(.saveFailed(error.localizedDescription))
        }
    }
}

// MARK: - Chinese relative-time parser

/// Deterministic Swift parser for the *relative* 中文 time phrasings NSDataDetector
/// misses — the gap the Reminders feature kept tripping on. The OS detector is
/// strong on absolute and named-weekday phrasing ("周三", "明天下午三点", "1月15号")
/// but returns nothing for offset phrasings like "三天后", "两周后", "5分钟后",
/// "下月15号", or "月底". This fills exactly those, anchored to `Calendar.current`
/// so the result agrees with the rest of the app's date math.
///
/// Scope is deliberately narrow: only patterns the detector misses, recognized by a
/// handful of regexes over the phrasings users actually type. `parse` returns nil on
/// anything unrecognized, so ordinary lines fall straight through to the detector.
/// All matching is whole-string-cheap (a few small regexes), safe to run per
/// keystroke from `text.didSet`.
enum ChineseRelativeDate {
    /// The first relative moment named in `text`, anchored to `now`, or nil when no
    /// recognized relative phrase is present. Day-and-larger offsets that name no
    /// clock time default to 9am (matching `recurrenceDate`'s convention); minute and
    /// hour offsets add to `now` directly, since "5分钟后" means literally now + 5 min.
    static func parse(_ text: String, now: Date = Date()) -> Date? {
        // Sub-minute precision never matters for a reminder and only makes results
        // jitter; anchor every computation to the start of the current minute.
        let cal = Calendar.current
        let anchor = cal.date(bySetting: .second, value: 0, of: now) ?? now

        // Order matters: the most specific / smallest-unit patterns first, so a line
        // that names both ("三天后下午三点") is handled by the offset case (which then
        // folds in the clock time) rather than the bare clock-time fallback.
        if let d = parseMinuteHourOffset(text, anchor: anchor, cal: cal) { return d }
        if let d = parseDayOffset(text, anchor: anchor, cal: cal) { return d }
        if let d = parseWeekOffset(text, anchor: anchor, cal: cal) { return d }
        if let d = parseMonthOffset(text, anchor: anchor, cal: cal) { return d }
        if let d = parseYearOffset(text, anchor: anchor, cal: cal) { return d }
        if let d = parseRelativeMonthDay(text, anchor: anchor, cal: cal) { return d }
        if let d = parseMonthEnd(text, anchor: anchor, cal: cal) { return d }
        return nil
    }

    // MARK: Offset families

    /// "5分钟后", "半小时后", "两个小时后", "三个钟头后". Added straight onto `anchor`;
    /// a named clock time would contradict a minute/hour offset, so none is parsed.
    private static func parseMinuteHourOffset(_ text: String, anchor: Date,
                                              cal: Calendar) -> Date? {
        if let n = offsetAmount(text, unitPattern: "(?:分钟|分)") {
            return cal.date(byAdding: .minute, value: Int(n.rounded()), to: anchor)
        }
        if let n = offsetAmount(text, unitPattern: "(?:个?小时|个?钟头|个?钟)") {
            // "半小时" → 30 min; "一个半小时" → 90 min. `offsetAmount` already
            // folded the 半 into `n`, so this just converts hours → minutes.
            let minutes = Int((n * 60).rounded())
            return cal.date(byAdding: .minute, value: minutes, to: anchor)
        }
        return nil
    }

    /// "三天后", "3天之后", "大后天", "后天", "明天" (+ optional clock time). Day-grained,
    /// so it snaps to a clock time: an explicit one if named, else 9am.
    private static func parseDayOffset(_ text: String, anchor: Date, cal: Calendar) -> Date? {
        var days: Int?
        // Day-words first — they carry their own fixed offset.
        let dayWords: [(String, Int)] = [
            ("大后天", 3), ("大前天", -3),
            ("后天", 2), ("前天", -2),
            ("明天", 1), ("明日", 1), ("昨天", -1), ("昨日", -1),
            ("今天", 0), ("今日", 0),
        ]
        for (word, offset) in dayWords where text.contains(word) {
            days = offset
            break
        }
        if days == nil, let n = offsetAmount(text, unitPattern: "(?:天|日)") {
            days = Int(n.rounded())
        }
        guard let days else { return nil }
        let base = cal.date(byAdding: .day, value: days, to: anchor) ?? anchor
        return applyClock(parseClock(text), to: base, cal: cal)
    }

    /// "两周后", "下周" is handled by the detector, so here only the offset form:
    /// "N周后", "N个星期后", "N礼拜后" (+ optional clock time → else 9am).
    private static func parseWeekOffset(_ text: String, anchor: Date, cal: Calendar) -> Date? {
        guard let n = offsetAmount(text, unitPattern: "(?:个?星期|个?礼拜|周)") else { return nil }
        let base = cal.date(byAdding: .day, value: Int(n.rounded()) * 7, to: anchor) ?? anchor
        return applyClock(parseClock(text), to: base, cal: cal)
    }

    /// "N个月后", "N月后" (+ optional clock time → else 9am). Calendar month
    /// arithmetic clamps overlong days (Jan 31 + 1 month → Feb 28/29) on its own.
    private static func parseMonthOffset(_ text: String, anchor: Date, cal: Calendar) -> Date? {
        guard let n = offsetAmount(text, unitPattern: "(?:个月|月)") else { return nil }
        let base = cal.date(byAdding: .month, value: Int(n.rounded()), to: anchor) ?? anchor
        return applyClock(parseClock(text), to: base, cal: cal)
    }

    /// "N年后", "N年之后" (+ optional clock time → else 9am).
    private static func parseYearOffset(_ text: String, anchor: Date, cal: Calendar) -> Date? {
        guard let n = offsetAmount(text, unitPattern: "年") else { return nil }
        let base = cal.date(byAdding: .year, value: Int(n.rounded()), to: anchor) ?? anchor
        return applyClock(parseClock(text), to: base, cal: cal)
    }

    /// "下月15号", "下下月3号", "这个月20号". NSDataDetector already handles "下个月15号"
    /// (with 个) but trips on the bare "下月15号" form, so this covers both spellings.
    /// The named day number is required — a bare "下月" with no day is too vague to
    /// pin a reminder, and is left to fall through.
    private static func parseRelativeMonthDay(_ text: String, anchor: Date, cal: Calendar) -> Date? {
        // Month modifier: 下下(月) = +2, 下(月) = +1, 这/本(月) = 0.
        let monthOffset: Int
        if matches(text, pattern: "下下个?月") { monthOffset = 2 }
        else if matches(text, pattern: "下个?月") { monthOffset = 1 }
        else if matches(text, pattern: "(?:这|本)个?月") { monthOffset = 0 }
        else { return nil }

        // Day number: "15号" / "15日" / "十五号".
        guard let dayText = firstMatch(in: text, pattern: "([0-9零〇一二三四五六七八九十两]+)\\s*[号日]"),
              let day = chineseNumber(dayText), day >= 1, day <= 31 else { return nil }

        let targetMonth = cal.date(byAdding: .month, value: monthOffset, to: anchor) ?? anchor
        var comps = cal.dateComponents([.year, .month], from: targetMonth)
        comps.day = day
        let clock = parseClock(text)
        comps.hour = clock?.hour ?? 9
        comps.minute = clock?.minute ?? 0
        comps.second = 0
        return cal.date(from: comps)
    }

    /// "月底", "月末", "本月底", "下月底" → last day of the relevant month at the named
    /// clock time, else 9am.
    private static func parseMonthEnd(_ text: String, anchor: Date, cal: Calendar) -> Date? {
        guard text.contains("月底") || text.contains("月末") else { return nil }
        // "下月底" / "下个月底" → end of next month.
        let monthOffset = (text.contains("下月底") || text.contains("下个月底")
                           || text.contains("下月末") || text.contains("下个月末")) ? 1 : 0
        let inMonth = cal.date(byAdding: .month, value: monthOffset, to: anchor) ?? anchor
        guard let range = cal.range(of: .day, in: .month, for: inMonth) else { return nil }
        var comps = cal.dateComponents([.year, .month], from: inMonth)
        comps.day = range.upperBound - 1   // last valid day of that month
        let clock = parseClock(text)
        comps.hour = clock?.hour ?? 9
        comps.minute = clock?.minute ?? 0
        comps.second = 0
        return cal.date(from: comps)
    }

    // MARK: Shared sub-parsers

    /// Pull the numeric amount in front of `unitPattern` followed by a 后/之后/以后
    /// marker — the thing that makes a phrase *relative*. "三天后" → 3 (unit 天),
    /// "半小时后" → 0.5 (unit 小时), "一个半小时后" → 1.5. Returns nil if no such
    /// "<amount><unit><后>" run is present, so an absolute "三天" with no 后 is left
    /// for the detector. The amount can be Arabic or Chinese numerals; a bare unit
    /// with no leading number ("天后") defaults to 1.
    private static func offsetAmount(_ text: String, unitPattern: String) -> Double? {
        // Optional leading number, an optional 半 (possibly carrying its own 个 as in
        // "一个半小时"), the unit, an optional trailing 半, then a relative marker. Both
        // 半 slots are optional so "半小时后" (半 before, no number) and "一个半小时后"
        // (number + 个半 before) both parse.
        let pattern = "([0-9零〇一二三四五六七八九十两]*)(个?半)?\(unitPattern)(半?)(?:之?后|以后)"
        guard let groups = firstMatchGroups(in: text, pattern: pattern) else { return nil }
        let numberText = groups[1]
        let halfBefore = groups[2].contains("半")    // 半小时 / 一个半小时
        let halfAfter = !groups[3].isEmpty           // (trailing) 小时半
        var amount: Double
        if numberText.isEmpty {
            // No explicit count. "半小时后" → 0.5; bare "小时后" → 1.
            amount = halfBefore ? 0.5 : 1
        } else if let n = chineseNumber(numberText) {
            amount = Double(n)
            if halfBefore || halfAfter { amount += 0.5 }
        } else {
            return nil
        }
        return amount > 0 ? amount : nil
    }

    /// Parse a clock time out of `text` — "下午三点", "晚上8点半", "上午9点30分",
    /// "中午12点", "凌晨1点". Returns (hour 0…23, minute) or nil if none is named.
    /// Bare "三点" with no period word is treated as PM when 1…6 (a reminder for
    /// "三点" almost always means the afternoon), matching the detector's own lean.
    static func parseClock(_ text: String) -> (hour: Int, minute: Int)? {
        guard let groups = firstMatchGroups(
            in: text,
            pattern: "(上午|早上|早晨|凌晨|中午|下午|晚上|傍晚|夜里|夜晚)?\\s*"
                   + "([0-9零〇一二三四五六七八九十两]+)\\s*[点时:：]"
                   + "\\s*(半|[0-9零〇一二三四五六七八九十两]+)?\\s*分?")
        else { return nil }

        let period = groups[1]
        guard var hour = chineseNumber(groups[2]), hour >= 0, hour <= 24 else { return nil }
        if hour == 24 { hour = 0 }

        var minute = 0
        let minuteText = groups[3]
        if minuteText == "半" {
            minute = 30
        } else if !minuteText.isEmpty, let m = chineseNumber(minuteText), m >= 0, m < 60 {
            minute = m
        }

        switch period {
        case "下午", "晚上", "傍晚", "夜里", "夜晚":
            if hour < 12 { hour += 12 }
        case "中午":
            if hour < 12 { hour = 12 }
        case "凌晨":
            if hour == 12 { hour = 0 }   // "凌晨12点" → 0:00
        case "上午", "早上", "早晨":
            break
        case "":
            // No period word: a bare small hour reads as afternoon (3点 → 15:00),
            // which is what people mean by a reminder time far more often than 3am.
            if hour >= 1, hour <= 6 { hour += 12 }
        default:
            break
        }
        return (min(hour, 23), minute)
    }

    /// Set the clock on `base` to `clock`, or to 09:00 when no clock was named.
    private static func applyClock(_ clock: (hour: Int, minute: Int)?, to base: Date,
                                   cal: Calendar) -> Date? {
        cal.date(bySettingHour: clock?.hour ?? 9, minute: clock?.minute ?? 0,
                 second: 0, of: base)
    }

    // MARK: Numerals

    /// Parse an Arabic or Chinese numeral string to an Int. Handles plain digits
    /// ("15"), single characters ("三" → 3, "两" → 2, "〇/零" → 0), and the common
    /// 十-composed forms up to 99 ("十" → 10, "十五" → 15, "二十" → 20, "三十五" → 35).
    /// Returns nil for anything it can't read, so callers can reject it cleanly.
    static func chineseNumber(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if let n = Int(trimmed) { return n }

        let digits: [Character: Int] = [
            "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
        ]
        // Pure single digit.
        if trimmed.count == 1, let d = digits[trimmed.first!] { return d }

        // 十-composed: [tens]十[units], any part optional. "十" = 10, "十五" = 15,
        // "二十" = 20, "三十五" = 35. Hundreds ("一百") fall through to nil — out of
        // range for the units this parser deals in (days/weeks/months/hours).
        if let tenIndex = trimmed.firstIndex(of: "十") {
            let before = trimmed[trimmed.startIndex..<tenIndex]
            let after = trimmed[trimmed.index(after: tenIndex)...]
            let tens: Int
            if before.isEmpty {
                tens = 1                              // "十..." → 1×10
            } else if before.count == 1, let d = digits[before.first!] {
                tens = d
            } else {
                return nil
            }
            var units = 0
            if !after.isEmpty {
                guard after.count == 1, let d = digits[after.first!] else { return nil }
                units = d
            }
            return tens * 10 + units
        }
        return nil
    }

    // MARK: Regex helpers

    /// First capture group 1 of `pattern` in `text`, or nil.
    private static func firstMatch(in text: String, pattern: String) -> String? {
        firstMatchGroups(in: text, pattern: pattern)?[safe: 1]
    }

    /// All capture groups (index 0 = whole match) of the first occurrence of
    /// `pattern` in `text`, with absent optional groups as "". Nil if no match.
    private static func firstMatchGroups(in text: String, pattern: String) -> [String]? {
        guard let regex = compiledRegex(pattern) else { return nil }
        let full = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: full) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            guard let r = Range(m.range(at: i), in: text) else { return "" }
            return String(text[r])
        }
    }

    /// Whether `pattern` matches anywhere in `text`. Replaces
    /// `text.range(of:options:.regularExpression)`, which recompiles the regex on
    /// every call — this routes through the same compiled-regex cache instead.
    private static func matches(_ text: String, pattern: String) -> Bool {
        guard let regex = compiledRegex(pattern) else { return false }
        let full = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: full) != nil
    }

    /// Compile-once cache for the parser's regexes. Every pattern this enum uses is
    /// drawn from a fixed, finite set of string literals (the `unitPattern`s are
    /// themselves literals), so the pattern string is a sound cache key. Without
    /// this each `parse()` — run synchronously on every keystroke from `text.didSet`
    /// — recompiled a fresh `NSRegularExpression` per sub-parser, which compiles the
    /// pattern each time and showed up as main-thread jank during fast (IME) typing.
    private static let regexLock = NSLock()
    private static var regexCache: [String: NSRegularExpression] = [:]

    private static func compiledRegex(_ pattern: String) -> NSRegularExpression? {
        regexLock.lock()
        defer { regexLock.unlock() }
        if let cached = regexCache[pattern] { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache[pattern] = regex
        return regex
    }
}

private extension Array {
    /// Bounds-checked subscript — returns nil instead of trapping past the end.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
