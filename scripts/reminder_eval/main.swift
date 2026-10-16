// Regression harness for RemindersService's Chinese relative-time parsing — NOT
// part of the app target.
//
// Compiles the real service straight from Sources/ so what's asserted is exactly
// what ships:
//
//   swiftc -O scripts/reminder_eval/main.swift \
//       NotchGlass/Sources/RemindersService.swift \
//       -o /tmp/reminder_eval && /tmp/reminder_eval
//
// `RemindersError.errorDescription` calls the app's `L(...)` localizer, which lives
// in Localization.swift behind a SwiftUI import; rather than drag that whole file
// into a headless build, this harness stubs `L` below. The relative-time parser
// (the only thing under test) never touches it.
//
// Every case is asserted against a FIXED anchor — Fri 2026-06-19 11:35 local —
// so the expected dates never drift with wall-clock time. `ChineseRelativeDate`
// takes the anchor directly; the few NSDataDetector-backed cases are checked for
// shape (non-nil / future) rather than an exact instant, since the detector reads
// the real `Date()`.

import Foundation

// Stub for the app's localizer (see header).
func L(_ key: String) -> String { key }
func L(_ key: String, _ args: CVarArg...) -> String { key }

// MARK: - Fixed anchor

let cal = Calendar.current
// Friday, June 19 2026, 11:35:00 local — the same moment the feature was probed
// against, so a human can eyeball the expected offsets.
let anchor: Date = {
    var c = DateComponents()
    c.year = 2026; c.month = 6; c.day = 19; c.hour = 11; c.minute = 35; c.second = 0
    return cal.date(from: c)!
}()

let fmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

func ymdhm(_ d: Date) -> String { fmt.string(from: d) }

// MARK: - Assertions

var passed = 0
var failed = 0

/// Assert `ChineseRelativeDate.parse(input)` lands on `expected` ("yyyy-MM-dd HH:mm")
/// when anchored to our fixed moment.
func expect(_ input: String, _ expected: String) {
    let got = ChineseRelativeDate.parse(input, now: anchor)
    let gotStr = got.map(ymdhm) ?? "nil"
    if gotStr == expected {
        passed += 1
    } else {
        failed += 1
        print("  ❌ \(input)\n       expected \(expected)\n       got      \(gotStr)")
    }
}

/// Assert the parser declines `input` (returns nil) — it's not a relative phrase,
/// so it must fall through to NSDataDetector untouched.
func expectNil(_ input: String) {
    if let got = ChineseRelativeDate.parse(input, now: anchor) {
        failed += 1
        print("  ❌ \(input)\n       expected nil (fall through to detector)\n       got      \(ymdhm(got))")
    } else {
        passed += 1
    }
}

// MARK: - The corpus
//
// Anchor: Fri 2026-06-19 11:35. Default hour for dateless day+ offsets is 9am;
// minute/hour offsets add to the anchor minute directly.

print("—— Chinese relative-time parsing (anchor \(ymdhm(anchor)) Fri) ——")

// Minute / hour offsets — add to the anchor, no 9am snap.
expect("5分钟后提醒我", "2026-06-19 11:40")
expect("5分钟后", "2026-06-19 11:40")
expect("三十分钟后喝水", "2026-06-19 12:05")
expect("半小时后", "2026-06-19 12:05")
expect("一个小时后开会", "2026-06-19 12:35")
expect("两个小时后", "2026-06-19 13:35")
expect("3小时后", "2026-06-19 14:35")
expect("一个半小时后", "2026-06-19 13:05")

// Day offsets (numeric + day-words) — snap to 9am unless a clock time is named.
expect("三天后开会", "2026-06-22 09:00")
expect("3天后开会", "2026-06-22 09:00")
expect("3天之后", "2026-06-22 09:00")
expect("大后天提醒我", "2026-06-22 09:00")
expect("后天下午两点", "2026-06-21 14:00")
expect("明天", "2026-06-20 09:00")            // bare day-word resolves to 9am
expect("明天上午九点", "2026-06-20 09:00")
expect("三天后下午三点开会", "2026-06-22 15:00")
expect("十天后", "2026-06-29 09:00")

// Week offsets.
expect("两周后体检", "2026-07-03 09:00")
expect("一周后", "2026-06-26 09:00")
expect("3个星期后", "2026-07-10 09:00")
expect("两个礼拜后", "2026-07-03 09:00")

// Month offsets.
expect("一个月后", "2026-07-19 09:00")
expect("两个月后复诊", "2026-08-19 09:00")
expect("3个月后", "2026-09-19 09:00")

// Year offset.
expect("一年后", "2027-06-19 09:00")

// Relative month + named day — the bare "下月" form the detector trips on.
expect("下月15号交房租", "2026-07-15 09:00")
expect("下月15号下午三点", "2026-07-15 15:00")
expect("下下月3号", "2026-08-03 09:00")
expect("这个月20号", "2026-06-20 09:00")

// Month end.
expect("月底前交报告", "2026-06-30 09:00")
expect("这个月底", "2026-06-30 09:00")
expect("下月底", "2026-07-31 09:00")

// Clock-time disambiguation embedded in offsets.
expect("两天后晚上8点", "2026-06-21 20:00")
expect("三天后早上7点半", "2026-06-22 07:30")
expect("一周后中午12点", "2026-06-26 12:00")

// Must DECLINE — absolute / named-weekday phrasing belongs to NSDataDetector,
// and non-time lines must not be misread as reminders.
print("\n—— fall-through cases (parser must return nil) ——")
expectNil("周三开会")
expectNil("买牛奶")
expectNil("写一封邮件给老板")
expectNil("1月15号")
expectNil("晚上八点")            // bare clock time, no offset → detector territory
expectNil("上周五买的牛奶")      // past reference
expectNil("")

// MARK: - Past-offset filtering through the public API
//
// `futureDate(in:)` filters anything ≤ now. With the live clock these are only
// meaningful as "did the parser produce a past date that got filtered" — checked
// here by asserting the *parser* yields a past date for backward day-words.
print("\n—— past day-words resolve behind the anchor ——")
func expectPast(_ input: String) {
    if let got = ChineseRelativeDate.parse(input, now: anchor), got < anchor {
        passed += 1
    } else {
        failed += 1
        print("  ❌ \(input) — expected a date before the anchor")
    }
}
expectPast("前天")
expectPast("大前天")
expectPast("昨天")

// MARK: - Public API: past phrases are filtered, future phrases survive
//
// `futureDate(in:)` runs against the live clock, so assert only direction here:
// a backward day-word must never come back (it's < now and gets filtered), while
// a far-future offset must.
print("\n—— futureDate(in:) past-filtering (live clock) ——")
if RemindersService.futureDate(in: "前天买的牛奶") == nil { passed += 1 }
else { failed += 1; print("  ❌ 前天买的牛奶 — a past phrase leaked through futureDate") }

if RemindersService.futureDate(in: "三个月后体检") != nil { passed += 1 }
else { failed += 1; print("  ❌ 三个月后体检 — a future phrase was dropped by futureDate") }

// MARK: - Summary

print(String(format: "\n=== %d passed, %d failed ===", passed, failed))
exit(failed == 0 ? 0 : 1)
