// Live search evaluation — NOT part of the app target.
//
// Drives the REAL agent stack (OpenAICompatAIService.streamTurn → AgentHarness →
// ToolRegistry.standard) against the REAL provider and the REAL search backend,
// over a batch of deliberately hard, search-requiring questions. Its whole reason
// to exist is the DeepSeek "swallowed answer" bug (GitHub #1): a model that writes
// its tool call as *text* markup instead of a structured `tool_call` used to end
// the turn with nothing on screen. This measures how often that actually happens
// live, and whether the recovery in `ToolMarkupFilter`/`AgentHarness` catches it.
//
//   swiftc -O scripts/search_eval/main.swift \
//       NotchGlass/Sources/AgentHarness.swift \
//       NotchGlass/Sources/AgentTools.swift \
//       NotchGlass/Sources/AIService.swift \
//       NotchGlass/Sources/APIKeyStore.swift \
//       NotchGlass/Sources/ProxyConfig.swift \
//       NotchGlass/Sources/Localization.swift \
//       -o /tmp/search_eval && /tmp/search_eval
//
// Keys are never passed in or printed: the harness reads the running app's own
// settings (`com.notchglass.app` defaults) at runtime, exactly as the app does.
//
// `OrbState` is stubbed below rather than dragging in Components.swift (2k lines
// of SwiftUI for a four-case tag the harness only forwards to the UI).

import Foundation

// MARK: - Stubs for the UI types the harness reports through

enum OrbState: Hashable { case composing, searching, solving, working }

// MARK: - Recording wrappers
//
// Two decorators give the A/B we need per round:
//   · the SERVICE wrapper sees the raw turn — whether the model leaked `<｜…｜>`
//     markup into its text, and which tool calls arrived *structured*;
//   · the TOOL wrapper sees what the registry actually RAN.
// A tool that ran but was never announced as a structured call is one the
// recovery reconstructed out of leaked markup.

final class Recorder: @unchecked Sendable {
    var leakedTurns = 0            // turns whose text carried `<｜` / `<|` markup
    var structuredCalls: [String] = []
    var executedCalls: [(name: String, query: String)] = []
    var rawTextChars = 0           // characters of `delta.content` seen on the wire
    var visibleChars = 0           // characters that survived the markup filter
    var turns = 0

    var recoveredCount: Int { max(0, executedCalls.count - structuredCalls.count) }

    func reset() {
        leakedTurns = 0; structuredCalls = []; executedCalls = []
        rawTextChars = 0; visibleChars = 0; turns = 0
    }
}

struct RecordingService: AgentCapableService {
    let inner: OpenAICompatAIService
    let rec: Recorder

    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        inner.stream(system: system, messages: messages)
    }

    func streamTurn(system: String, messages: [AgentMessage],
                    tools: [ToolSpec]) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var sawMarkup = false
                do {
                    for try await event in inner.streamTurn(system: system, messages: messages,
                                                            tools: tools) {
                        switch event {
                        case .text(let t):
                            rec.rawTextChars += t.count
                            if t.contains("<｜") || t.contains("<|") { sawMarkup = true }
                        case .toolCall(let _id, let name, _):
                            _ = _id
                            rec.structuredCalls.append(name)
                        default: break
                        }
                        continuation.yield(event)
                    }
                    rec.turns += 1
                    if sawMarkup { rec.leakedTurns += 1 }
                    continuation.finish()
                } catch {
                    rec.turns += 1
                    if sawMarkup { rec.leakedTurns += 1 }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct RecordingTool: NotchTool {
    let inner: NotchTool
    let rec: Recorder
    var name: String { inner.name }
    var description: String { inner.description }
    var schema: [String: Any] { inner.schema }
    func execute(_ input: [String: Any]) async throws -> String {
        let q = (input["query"] as? String) ?? (input["url"] as? String)
            ?? (input["expression"] as? String) ?? ""
        rec.executedCalls.append((name: inner.name, query: q))
        return try await inner.execute(input)
    }
}

/// Search tools must keep their `SourcedTool` conformance or the harness routes
/// them through the text-only path and the source badge goes dark.
struct RecordingSourcedTool: SourcedTool {
    let inner: SourcedTool
    let rec: Recorder
    var name: String { inner.name }
    var description: String { inner.description }
    var schema: [String: Any] { inner.schema }
    func execute(_ input: [String: Any]) async throws -> String {
        try await runSourced(input).text
    }
    func runSourced(_ input: [String: Any]) async throws -> (text: String, sources: [WebSource]) {
        let q = (input["query"] as? String) ?? (input["search_query"] as? String) ?? ""
        rec.executedCalls.append((name: inner.name, query: q))
        return try await inner.runSourced(input)
    }
}

// MARK: - The battery
//
// Two different kinds of hard, and keeping them apart is the whole point.
//
// `.chain` questions are hard because the ANSWER takes several steps — search,
// read, search again for a second fact, then reason over both. Extra searches
// here are *productive*; a ceiling that cuts them off is strangling real work.
//
// `.fruitless` questions are hard because the web has no clean answer to give.
// The model searches, gets near-miss results, rewords, searches again, and each
// round looks locally reasonable while going nowhere. Extra searches here are
// *waste*, and are what burned eight rounds and produced a blank answer on the
// two questions that started all this (both are in here verbatim).
//
// A search ceiling trades one against the other, so averaging the two together
// hides exactly the effect we're trying to measure. The summary reports them
// separately, and both must be read before touching `maxSearchRounds`.
//
// `.trap` questions are the control: they must NOT provoke searching at all
// (stable knowledge), or must provoke exactly one. They catch a ceiling change
// that "improves" the other two by making the model search for everything.

enum QueryKind: String {
    case chain      = "chain"       // multi-step; extra searches earn their keep
    case fruitless  = "fruitless"   // no clean web answer; extra searches are waste
    case trap       = "trap"        // should barely search, or not at all
}

let queries: [(id: String, q: String, kind: QueryKind)] = [
    // ── multi-step: the searches should compound, not repeat ──────────────────
    ("multi-hop-cn",   "英伟达最近一个财季的数据中心营收是多少？和上一财季比涨了多少百分比？", .chain),
    ("multi-hop-en",   "Who is the current CEO of Intel, when did they start, and what was the stock price change on the announcement day?", .chain),
    ("compare",        "比较一下 DeepSeek 最新旗舰模型和 Qwen 最新旗舰模型的上下文窗口和定价，列出数字。", .chain),
    ("fresh-cn",       "今天上证指数收盘是多少点？涨跌幅是多少？", .chain),
    ("fresh-en",       "What is the latest stable version of Swift, and what were the headline changes?", .chain),
    ("read-page",      "看一下 https://github.com/apple/swift 的 README，用三句话说明这个仓库现在主推什么。", .chain),
    ("date-math",      "距离下一个 WWDC 还有多少天？先查清楚日期再算。", .chain),
    ("mixed-tools",    "查一下现在一美元兑人民币多少，然后算 4999 美元是多少人民币。", .chain),
    ("chained-read",   "找一篇本周关于 Apple Silicon 的新闻，打开它，然后总结它的核心论点。", .chain),
    ("ambiguous-time", "苹果最近一次发布会是什么时候？发布了哪些硬件？", .chain),
    // Three genuinely separate facts before any arithmetic can start — the
    // deepest chain here, and the clearest test of a ceiling set too low.
    ("triple-hop",     "特斯拉最近一个财季在全球交付了多少辆车？比亚迪同期卖了多少辆？两者相差多少百分比？", .chain),
    ("two-lookups-math", "查一下现在一盎司黄金多少美元，再查一下美元兑人民币汇率，然后算出一克黄金大约多少人民币。", .chain),
    // Sources disagree, which tempts the model into re-searching for a tiebreak
    // rather than reporting the disagreement.
    ("disputed",       "现在世界上最高的建筑是哪一座？有没有已经封顶但还没投入使用、比它更高的？", .chain),

    // ── fruitless: the shape that produced the blank answers ──────────────────
    // The original incident, verbatim. A substituted-quote meme: the answer is
    // recognising it as a rewrite of a famous line, which no amount of searching
    // the rewritten text will surface.
    ("quote-origin",   "通过丑化我，丑化张雪峰老师，丑化亿万学子参加的大学招生志愿大填报。张雪峰老师的妻子，三十八年整了。认识还不止，共患难了! 这句话原文是什么", .fruitless),
    // The second incident, verbatim — same shape, different meme.
    ("meme-origin",    "勃勃，没想到你会问出这样的问题。我记得你可是上通天文下知地理中间还懂线性代数的啊。。 这句话原文是什么", .fruitless),
    // A misremembered line: the words as given appear nowhere, so every search
    // comes back near-miss. Answering well means saying which line it's probably
    // a garbling of — and saying so plainly if unsure.
    ("misquote",       "「人类的悲欢并不相通，我只觉得他们吵闹」这句话我可能记错了，原话是什么？出自哪里？", .fruitless),
    // Long-tail with almost no web presence. Classic reword-forever bait, and the
    // honest answer is "I couldn't find it."
    ("deep-obscure",   "Notchi 这个 macOS 刘海小工具是谁做的？用什么写的？开源吗？", .fruitless),
    // Hyper-specific real-time reading that no page publishes in this form.
    ("unanswerable",   "此时此刻北京朝阳区的实时 PM2.5 读数是多少？精确到个位。", .fruitless),
    // Kept from the original battery — the loop the nudge was first written for.
    ("no-clean-answer","南昌一月份的平均气温是多少度？", .fruitless),
    ("obscure",        "Keenable 这家搜索 API 公司是做什么的？定价怎么算？", .fruitless),

    // ── control: searching here is the bug ────────────────────────────────────
    ("stable-cs",      "冒泡排序的时间复杂度是多少？为什么是这个复杂度？", .trap),
    ("stable-lang",    "把这句话翻译成英文：光阴似箭，日月如梭。", .trap),
    // Looks like stable product trivia, is actually time-sensitive — the trap in
    // the other direction, so a "stop searching" change can't quietly win by
    // teaching the model to answer everything from memory.
    ("looks-stable",   "苹果目前在售的 MacBook Pro，顶配是哪颗芯片？", .trap),
]

// MARK: - Runner

@MainActor
func run() async {
    // Line-buffer stdout: a run is minutes long and usually watched through a
    // redirect, where the default block buffering shows nothing until it exits.
    setvbuf(stdout, nil, _IOLBF, 0)

    // `APIKeyStore` reads through `UserDefaults.standard`, which inside the app is
    // the `com.notchglass.app` domain but in a standalone binary is this process's
    // own — so without this the store finds no Exa key, `ToolRegistry.standard`
    // concludes no search backend is configured, and the whole battery runs with no
    // searcher at all: a green run that measured nothing. Adding the app's domain to
    // the standard search list makes every read resolve exactly as it does in the app.
    UserDefaults.standard.addSuite(named: "com.notchglass.app")

    // Read the app's own configuration, exactly as the app does — including the
    // key, which this process never prints and the operator never sees.
    let defaults = UserDefaults(suiteName: "com.notchglass.app")
    let provider = Provider(rawValue: defaults?.string(forKey: "selected_provider") ?? "") ?? .deepseek
    let model = defaults?.string(forKey: "model.\(provider.rawValue)").flatMap {
        $0.isEmpty ? nil : $0
    } ?? provider.defaultModel
    guard let key = defaults?.string(forKey: "api_key.\(provider.rawValue)"), !key.isEmpty else {
        print("No stored key for \(provider.displayName) — configure it in Settings first.")
        exit(1)
    }
    let searchBackend = defaults?.string(forKey: "searchBackend") ?? "(native)"
    let searchKeyed = (defaults?.string(forKey: "aux_key.\(searchBackend)")?.isEmpty == false)

    // The search ceiling under test (`AgentHarness.maxSearchRounds`), overridden
    // via SEARCH_ROUNDS. Sweeping it is the whole reason to run this battery more
    // than once: too low strangles a genuinely multi-hop question, too high lets a
    // fruitless one reword the same query until the round budget is gone. Left nil
    // the harness keeps its own default, so a plain run measures what ships.
    let searchCeiling = ProcessInfo.processInfo.environment["SEARCH_ROUNDS"].flatMap(Int.init)

    print("provider    : \(provider.displayName)")
    print("model       : \(model)")
    print("search      : \(searchBackend)\(searchKeyed ? " (keyed)" : " (NO KEY — will fall back)")")
    print("searchRounds: \(searchCeiling.map(String.init) ?? "(harness default)")")
    print("queries     : \(queries.count)")
    print(String(repeating: "─", count: 78))

    let rec = Recorder()
    let service = RecordingService(
        inner: OpenAICompatAIService(provider: provider, apiKey: key, model: model), rec: rec)

    // The same registry the app builds, each tool wrapped so we can see what ran.
    // `search_history` and `ask_user` are excluded: both need live app state, and
    // neither is on the search path this is measuring.
    let registry = ToolRegistry(ToolRegistry.standard(for: provider).tools.map { tool in
        if let sourced = tool as? SourcedTool {
            return RecordingSourcedTool(inner: sourced, rec: rec) as NotchTool
        }
        return RecordingTool(inner: tool, rec: rec) as NotchTool
    })
    print("tools       : \(registry.tools.map(\.name).joined(separator: ", "))")
    // Refuse to run a *search* evaluation with no searcher. This exact failure —
    // the registry silently falling back to the tool-less set — produced a full,
    // clean-looking sweep in which not one query ever searched. A battery that
    // can't measure the thing it exists to measure must stop, not report zeros.
    guard registry.tools.contains(where: {
        $0.name == WebSearchTool.toolName
    }) else {
        print("\nNo search tool in the registry — nothing to evaluate. "
              + "Configure a search backend in Settings first (and a key when required).")
        exit(1)
    }
    print(String(repeating: "─", count: 78))

    var emptyAnswers = 0
    var leakedQueries = 0
    var recoveredQueries = 0
    var failures: [String] = []
    // Per-kind tallies, because a ceiling that helps one kind hurts the other and
    // one combined average shows neither. `hitCeiling` is the number that decides
    // whether a sweep measured anything at all: if no query ever reaches the
    // ceiling, every ceiling is the same ceiling and the run has no opinion.
    var searchesByKind: [QueryKind: Int] = [:]
    var hitCeilingByKind: [QueryKind: Int] = [:]
    var countByKind: [QueryKind: Int] = [:]
    var answerCharsByKind: [QueryKind: Int] = [:]

    for (i, item) in queries.enumerated() {
        rec.reset()
        var harness = AgentHarness(service: service, registry: registry)
        if let searchCeiling { harness.maxSearchRounds = searchCeiling }
        var answer = ""
        let started = Date()
        var thrown: Error? = nil

        do {
            try await harness.run(
                system: notchSystemPromptDated(),
                messages: [AgentMessage(kind: .text(role: "user", text: item.q))],
                onText: { piece in answer += piece; rec.visibleChars += piece.count },
                onActivity: { _, _ in },
                onSources: { _ in })
        } catch {
            thrown = error
        }

        let elapsed = Date().timeIntervalSince(started)
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { emptyAnswers += 1 }
        if rec.leakedTurns > 0 { leakedQueries += 1 }
        if rec.recoveredCount > 0 { recoveredQueries += 1 }
        if let thrown { failures.append("\(item.id): \(thrown.localizedDescription)") }

        let searchCount = rec.executedCalls.filter { $0.name == WebSearchTool.toolName }.count
        let ceiling = harness.maxSearchRounds
        let reachedCeiling = searchCount >= ceiling
        countByKind[item.kind, default: 0] += 1
        searchesByKind[item.kind, default: 0] += searchCount
        answerCharsByKind[item.kind, default: 0] += trimmed.count
        if reachedCeiling { hitCeilingByKind[item.kind, default: 0] += 1 }

        print("[\(i + 1)/\(queries.count)] \(item.id) [\(item.kind.rawValue)]  ·  "
              + "\(String(format: "%.1fs", elapsed))")
        print("   Q: \(item.q)")
        print("   turns=\(rec.turns)  leaked-turns=\(rec.leakedTurns)  "
              + "structured=\(rec.structuredCalls.count)  executed=\(rec.executedCalls.count)  "
              + "recovered=\(rec.recoveredCount)")
        // Answer length is reported here, from the real string — the `A:` preview
        // below is clipped for readability, and reading length off that preview
        // makes every long answer look identical.
        print("   searches=\(searchCount)/\(ceiling)\(reachedCeiling ? "  ← HIT CEILING" : "")"
              + "  answerChars=\(trimmed.count)")
        for call in rec.executedCalls {
            let q = call.query.isEmpty ? "" : "  \"\(call.query.prefix(60))\""
            print("      · \(call.name)\(q)")
        }
        if let thrown {
            print("   ✗ ERROR: \(thrown.localizedDescription)")
        } else if trimmed.isEmpty {
            print("   ✗ EMPTY ANSWER  (raw wire text was \(rec.rawTextChars) chars)")
        } else {
            let oneLine = trimmed.split(whereSeparator: \.isNewline).joined(separator: " ")
            print("   A: \(oneLine.prefix(220))\(oneLine.count > 220 ? "…" : "")")
        }
        print("")
    }

    print(String(repeating: "─", count: 78))
    print("queries              : \(queries.count)")
    print("empty answers        : \(emptyAnswers)")
    print("queries that leaked  : \(leakedQueries)")
    print("queries recovered    : \(recoveredQueries)")
    print("stream errors        : \(failures.count)")
    for f in failures { print("   · \(f)") }

    print("")
    print("by kind   (chain: more searching should mean a better answer;")
    print("           fruitless: more searching means waste;")
    print("           trap: searching at all is the bug)")
    for kind in [QueryKind.chain, .fruitless, .trap] {
        let n = countByKind[kind] ?? 0
        guard n > 0 else { continue }
        let s = searchesByKind[kind] ?? 0
        let hit = hitCeilingByKind[kind] ?? 0
        let chars = answerCharsByKind[kind] ?? 0
        print(String(format: "  %-10s n=%2d  searches=%3d (%.1f/query)  hit-ceiling=%d  avgAnswer=%d chars",
                     (kind.rawValue as NSString).utf8String!, n, s, Double(s) / Double(n), hit, chars / n))
    }
    let totalHit = hitCeilingByKind.values.reduce(0, +)
    if totalHit == 0 {
        print("")
        print("⚠️  No query reached the ceiling. This sweep cannot distinguish one")
        print("    ceiling from another — the number under test never bound. Raise the")
        print("    difficulty (or lower the ceiling) before drawing any conclusion.")
    }
}

// `run()` is `@MainActor`, and in a command-line binary the main actor IS the main
// thread — so parking that thread on a semaphore means the task can never be
// scheduled and the process hangs forever, looking exactly like a very slow run.
// `dispatchMain()` parks the thread while still servicing the main queue.
Task { @MainActor in
    await run()
    exit(0)
}
dispatchMain()
