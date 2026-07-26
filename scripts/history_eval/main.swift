// Regression + evaluation harness for the `search_history` tool — NOT part of the
// app target.
//
// Compiles the REAL tool and the REAL archive query straight from Sources/, so
// what's measured is exactly what ships:
//
//   swiftc -O scripts/history_eval/main.swift \
//       $(ls NotchGlass/Sources/*.swift | grep -v NotchGlassApp.swift) \
//       -o /tmp/history_eval && /tmp/history_eval
//
// (The whole source set goes in because `SearchHistoryTool` sits on the app's tool
// protocol and the query lives on `NotchModel`; the alternative — stubbing them —
// would test a copy rather than the shipping code. Only `NotchGlassApp.swift` is
// excluded, for its `@main`.)
//
// Part A — fixtures, every case anchored to a FIXED "now" (Sun 2026-07-26 15:00
// local) via the tool's injectable clock, so expected windows never drift with
// wall-clock time.
// Part B — the user's REAL history.json, if present: what a handful of natural
// questions actually retrieve, plus size and latency of the digest the model reads.

import Foundation

typealias Item = NotchModel.HistoryItem
typealias Turn = NotchModel.Turn

// MARK: - Fixed anchor

let cal = Calendar.current
/// Sunday, July 26 2026, 15:00 local.
let anchor: Date = {
    var c = DateComponents()
    c.year = 2026; c.month = 7; c.day = 26; c.hour = 15; c.minute = 0
    return cal.date(from: c)!
}()

/// A local wall-clock instant, as an offset in days from the anchor's day.
func day(_ offset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    let base = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: anchor))!
    return cal.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
}

// MARK: - Fixtures
//
// Shaped after a real archive: mostly Ask rows with generated titles, a handful of
// captures, a couple of agent runs (one failed), and the two rows that must never
// surface (the in-flight question, and the thread on screen).

let currentThreadID = UUID()

func ask(_ t: Date, title: String?, q: String, a: String, turns: [Turn]? = nil,
         id: UUID = UUID()) -> Item {
    Item(id: id, q: q, a: a, t: t, turns: turns, title: title, source: .ask)
}

func capture(_ t: Date, _ line: String, _ source: Item.Source) -> Item {
    Item(q: line, a: "", t: t, turns: [], source: source)
}

func agent(_ t: Date, title: String, prompt: String, outcome: String?) -> Item {
    var item = Item(q: prompt, a: "done", t: t, turns: [], title: title, source: .agent)
    item.agentOutcome = outcome
    return item
}

var fixtures: [Item] = [
    // ── today (Sun 2026-07-26)
    ask(day(0, 14, 30), title: "小米 SU7 售价", q: "小米su7现在多少钱",
        a: "标准版 21.59 万起。"),
    capture(day(0, 11, 5), "会议结论\n下周二出第一版设计稿", .note),   // multi-line
    agent(day(0, 9, 40), title: "修 hint 闪烁", prompt: "修一下中文输入法下 hint 闪烁",
          outcome: "failure"),
    // ── yesterday (Sat 2026-07-25) — 23:50 is the end-of-day boundary case
    ask(day(-1, 23, 50), title: "Redis 连接池泄漏", q: "为什么连接数一直涨",
        a: "多半是连接池没有归还，检查 finally 里的 close。",
        turns: [Turn(role: "user", text: "为什么连接数一直涨"),
                Turn(role: "assistant", text: "多半是连接池没有归还。"),
                Turn(role: "user", text: "怎么确认是 Redis 那边"),
                Turn(role: "assistant", text: "看 CLIENT LIST 的 age 分布。")]),
    capture(day(-1, 8, 15), "和房东谈了房租 月底答复", .note),
    capture(day(-1, 7, 0), "交房租", .reminder),
    // ── 6 days back (Mon 2026-07-20) — outside a 7-day window's far edge is day -6
    ask(day(-6, 16, 20), title: nil, q: "翻译一下 diligence", a: "尽职、勤勉。"),
    agent(day(-6, 10, 0), title: "落地页字重", prompt: "把落地页标题字重调细",
          outcome: "success"),
    // ── 40 days back, for "the whole archive" vs a window
    capture(day(-40, 12, 0), "旧笔记 早已归档", .note),
]

// The in-flight question: parked in `history` the instant it's submitted. Must
// never come back as a past activity.
var inFlight = ask(day(0, 15, 0), title: nil, q: "我今天的主要工作内容是什么", a: "")
inFlight.pending = true
fixtures.append(inFlight)

// The thread currently on screen: already in the wire context verbatim.
fixtures.append(ask(day(0, 14, 55), title: "当前这轮", q: "这个怎么弄", a: "这样弄。",
                    id: currentThreadID))

/// The tool under test, anchored and pointed at a given archive.
func tool(_ items: [Item], currentThread: UUID? = currentThreadID) -> SearchHistoryTool {
    SearchHistoryTool(
        lookup: { query in
            NotchModel.archiveDigest(query, in: items, currentThread: currentThread)
        },
        now: { anchor })
}

// MARK: - Assertions

var passed = 0
var failed = 0
var caseIndex = 0

/// Run one case: `input` is the tool call's arguments exactly as a model would
/// send them. `expect` gets the rendered digest and returns nil on success or the
/// reason it failed.
func check(_ name: String, _ input: [String: Any], items: [Item] = fixtures,
           currentThread: UUID? = currentThreadID,
           _ expect: (String) -> String?) async {
    caseIndex += 1
    let out = (try? await tool(items, currentThread: currentThread).execute(input)) ?? "<threw>"
    if let reason = expect(out) {
        failed += 1
        print("  ✗ \(caseIndex). \(name)\n      \(reason)")
        // The digest is what the model reads — print it on failure, indented.
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            print("      | \(line)")
        }
    } else {
        passed += 1
        print("  ✓ \(caseIndex). \(name)")
    }
}

/// How many entry lines the digest lists (rows are numbered "N. [kind] …").
func entryCount(_ digest: String) -> Int {
    digest.split(separator: "\n").filter { line in
        guard let dot = line.firstIndex(of: ".") else { return false }
        return Int(line[line.startIndex..<dot]) != nil
    }.count
}

func requireCount(_ digest: String, _ n: Int) -> String? {
    let got = entryCount(digest)
    return got == n ? nil : "expected \(n) entries, got \(got)"
}

func requireContains(_ digest: String, _ needles: [String]) -> String? {
    for needle in needles where !digest.contains(needle) {
        return "missing “\(needle)”"
    }
    return nil
}

func requireAbsent(_ digest: String, _ needles: [String]) -> String? {
    for needle in needles where digest.contains(needle) {
        return "should not contain “\(needle)”"
    }
    return nil
}

// MARK: - Part A · fixtures

print("=== Part A · fixtures (anchor Sun 2026-07-26 15:00) ===\n")

await check("no arguments → whole archive, newest first", [:]) { d in
    requireCount(d, 9)
        // The two withheld rows.
        ?? requireAbsent(d, ["我今天的主要工作内容是什么", "当前这轮"])
        ?? requireContains(d, ["newest first", "小米 SU7 售价", "旧笔记 早已归档"])
        // Newest first: today's Ask must precede yesterday's.
        ?? (d.range(of: "小米 SU7 售价")!.lowerBound < d.range(of: "Redis 连接池泄漏")!.lowerBound
            ? nil : "rows are not newest-first")
}

await check("days:1 → today only", ["days": 1]) { d in
    requireCount(d, 3)
        ?? requireContains(d, ["小米 SU7 售价", "会议结论", "修 hint 闪烁"])
        ?? requireAbsent(d, ["Redis 连接池泄漏"])
}

await check("since:\"today\" → same as days:1", ["since": "today"]) { d in
    requireCount(d, 3) ?? requireContains(d, ["2026-07-26"])
}

await check("yesterday, whole day (23:50 row must survive)",
            ["since": "yesterday", "until": "yesterday"]) { d in
    requireCount(d, 3)
        ?? requireContains(d, ["Redis 连接池泄漏", "和房东谈了房租", "交房租"])
        ?? requireAbsent(d, ["小米 SU7 售价"])
}

await check("until:\"today\" includes all of today (00:00 boundary)",
            ["until": "today"]) { d in
    requireCount(d, 9) ?? requireContains(d, ["小米 SU7 售价"])
}

await check("explicit ISO window 07-20 → 07-21", ["since": "2026-07-20", "until": "2026-07-21"]) { d in
    requireCount(d, 2)
        ?? requireContains(d, ["diligence", "落地页字重", "2026-07-20 → 2026-07-21"])
}

await check("kind:note", ["kind": "note"]) { d in
    requireCount(d, 3)
        ?? requireContains(d, ["kind note", "[note]"])
        ?? requireAbsent(d, ["[ask]", "[reminder]", "[agent"])
}

await check("kind:reminder", ["kind": "reminder"]) { d in
    requireCount(d, 1) ?? requireContains(d, ["交房租"])
}

await check("keyword in a NOTE's body (Recent's filter can't do this)",
            ["query": "房东"]) { d in
    requireCount(d, 1) ?? requireContains(d, ["和房东谈了房租", "matching"])
}

await check("keyword in an ANSWER, not the title", ["query": "finally"]) { d in
    requireCount(d, 1) ?? requireContains(d, ["Redis 连接池泄漏"])
}

await check("keyword deep in a multi-turn thread", ["query": "CLIENT LIST"]) { d in
    requireCount(d, 1) ?? requireContains(d, ["Redis 连接池泄漏"])
}

await check("no match → explicit \"nothing recorded\", no invention",
            ["query": "zzz-nonexistent"]) { d in
    requireCount(d, 0)
        ?? requireContains(d, ["No entries found", "do not invent"])
}

await check("agent rows carry their outcome", ["kind": "agent"]) { d in
    requireCount(d, 2)
        ?? requireContains(d, ["[agent·failure]", "[agent·success]"])
}

await check("limit:2 caps the list AND admits it is a slice", ["limit": 2]) { d in
    requireCount(d, 2)
        ?? requireContains(d, ["小米 SU7 售价",
                               "The 2 most recent of 9 matching entries",
                               "only the newest slice"])
}

await check("a complete list does NOT claim to be a slice", ["days": 1]) { d in
    requireAbsent(d, ["most recent of", "only the newest slice"])
        ?? requireContains(d, ["3 entries"])
}

await check("limit:999 clamps to 60 (not an error)", ["limit": 999]) { d in
    requireCount(d, 9)
}

await check("backwards window is read as the window meant",
            ["since": "today", "until": "2026-07-20"]) { d in
    requireCount(d, 8)
        ?? requireContains(d, ["2026-07-20 → 2026-07-26"])
        ?? requireAbsent(d, ["旧笔记 早已归档"])
}

await check("multi-line note is flattened onto one line", ["kind": "note", "days": 1]) { d in
    requireContains(d, ["会议结论 下周二出第一版设计稿"])
        ?? requireCount(d, 1)
}

await check("full ISO timestamp is tolerated as a day",
            ["since": "2026-07-26T00:00:00Z"]) { d in
    requireCount(d, 3)
}

await check("integer argument arriving as a string", ["days": "1", "limit": "2"]) { d in
    requireCount(d, 2)
}

await check("unknown kind is ignored rather than matching nothing",
            ["kind": "screenshot"]) { d in
    requireCount(d, 9)
}

await check("an Ask with no generated title doesn't repeat itself",
            ["query": "diligence"]) { d in
    // Headline IS the question here, so no "asked:" echo line.
    requireCount(d, 1) ?? requireAbsent(d, ["asked: 翻译一下 diligence"])
}

await check("an Ask WITH a title also shows the literal question",
            ["query": "小米"]) { d in
    requireContains(d, ["小米 SU7 售价", "asked: 小米su7现在多少钱"])
}

await check("empty archive reads as nothing recorded, not as an error",
            [:], items: []) { d in
    requireContains(d, ["No entries found"])
}

// Budget: 400 long rows, all inside the window.
let fatArchive: [Item] = (0..<400).map { i in
    ask(day(0, 12, i % 60),
        title: "很长的标题 " + String(repeating: "凑字数", count: 40) + " #\(i)",
        q: String(repeating: "很长的问题内容", count: 40),
        a: "answer")
}

await check("budget: output stays under the 6000-char cap and says what it dropped",
            ["limit": 60], items: fatArchive, currentThread: nil) { d in
    if d.count > 6000 { return "digest is \(d.count) chars, over the 6000 cap" }
    return requireContains(d, ["omitted to stay within budget", "narrow the date window"])
        // Both truncations at once (60-row cap of 400 matches, then the budget):
        // the model must hear about both, not just the one that fired last.
        ?? requireContains(d, ["The 60 most recent of 400 matching entries"])
}

await check("per-row caps keep one pathological row from eating the digest",
            ["limit": 1], items: fatArchive, currentThread: nil) { d in
    // headlineCap 220 + bodyCap 160 + framing, comfortably under a KB.
    d.count < 900 ? nil : "single row rendered \(d.count) chars"
}

print("\n  Part A: \(passed)/\(passed + failed) passed"
      + (failed == 0 ? "" : "  ← \(failed) FAILED"))

// MARK: - Part B · the real archive

print("\n=== Part B · real archive ===\n")

let realURL = FileManager.default.urls(for: .applicationSupportDirectory,
                                       in: .userDomainMask).first!
    .appendingPathComponent("Notch/history.json")

if let data = try? Data(contentsOf: realURL),
   let items = try? JSONDecoder().decode([Item].self, from: data) {
    let days = Set(items.map { cal.startOfDay(for: $0.t) })
    let kinds = Dictionary(grouping: items, by: \.source.rawValue).mapValues(\.count)
    print("  \(items.count) rows, \(days.count) distinct days, kinds \(kinds.sorted { $0.key < $1.key })")
    if let newest = items.map(\.t).max(), let oldest = items.map(\.t).min() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        print("  span \(f.string(from: oldest)) → \(f.string(from: newest))\n")
    }

    // Anchor Part B at the archive's own newest day, so "today"/"yesterday" land on
    // rows that exist regardless of when this harness is run.
    let newestDay = items.map(\.t).max() ?? anchor
    let realTool = SearchHistoryTool(
        lookup: { q in NotchModel.archiveDigest(q, in: items, currentThread: nil) },
        now: { newestDay })
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
    print("  (anchored at the archive's newest day, \(f.string(from: newestDay)))\n")

    let probes: [(String, [String: Any])] = [
        ("“我今天做了什么”",            ["days": 1]),
        ("“我昨天做了什么”",            ["since": "yesterday", "until": "yesterday"]),
        ("“我这周主要在忙什么”",        ["days": 7]),
        ("“我记录的主要内容是什么”",    ["kind": "note"]),
        ("“我让 agent 干了什么”",       ["kind": "agent", "days": 7]),
        ("“我问过 Notch 相关的什么”",   ["query": "notch"]),
        ("“我提过发版的事吗”",          ["query": "发版"]),
        ("整个档案（无参数）",           [:]),
    ]

    for (label, input) in probes {
        let start = DispatchTime.now()
        let digest = (try? await realTool.execute(input)) ?? "<threw>"
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        let rows = entryCount(digest)
        // Rough token proxy: CJK runs about 1 token per character, so chars is the
        // number that matters for context budget.
        print(String(format: "  %-26@ → %2d rows, %4d chars, %.1fms",
                     label as NSString, rows, digest.count, ms))
    }

    // Show one digest in full — the "what did I do today" case, which is the whole
    // point of the feature.
    print("\n  ── the digest the model actually reads for “我今天做了什么”:\n")
    let sample = (try? await realTool.execute(["days": 1])) ?? ""
    for line in sample.split(separator: "\n", omittingEmptySubsequences: false) {
        print("  | \(line)")
    }
} else {
    print("  (no readable history.json at \(realURL.path) — Part B skipped)")
}

print("")
exit(failed == 0 ? 0 : 1)
