import Foundation

// MARK: - Agent turn protocol
//
// The single-shot `AIService.stream(system:messages:)` answers a question in one
// pass: text in, text out. An *agent* turn is richer — the model may decide to
// call a tool, the harness runs it, feeds the result back, and the model
// continues, possibly for several rounds, until it has nothing left to do. That
// loop needs more than a `String` stream: it needs to see, per turn, the text the
// model wrote, any tool calls it requested, and why it stopped.
//
// `TurnEvent` is that richer stream. `AIService.streamTurn` yields these events
// for one model turn; `AgentHarness` runs the multi-turn loop on top. The old
// `stream(system:messages:)` stays exactly as it was — every non-agent path
// (title generation, the `complete` convenience, any provider that can't or
// won't do tools) keeps using it untouched. Tool support is purely additive.

/// One incremental event from a single agent turn.
enum TurnEvent: Sendable {
    /// A chunk of visible answer text to append (same semantics as the plain
    /// `stream`'s yielded String).
    case text(String)
    /// The concrete model the provider actually ran, echoed back in the stream's
    /// `model` field. For OpenRouter's `openrouter/free` auto-router this is the
    /// only place the real model surfaces (the request only names the router);
    /// the UI shows it under the answer. Emitted at most once per turn.
    case model(String)
    /// A tool-call block just OPENED in the stream: the model has committed to
    /// running `name`, but its arguments are still streaming in. Emitted so the
    /// UI can raise the activity line the moment the decision is visible instead
    /// of waiting the seconds it takes the arguments JSON to finish — the window
    /// in which a preface-then-search turn used to show no progress at all. The
    /// assembled `.toolCall` for the same call still follows.
    case toolCallStarted(name: String)
    /// The model finished a tool-call request: it wants `name(input)` run, keyed
    /// by `id` so the result can be matched back. Emitted once per tool call after
    /// its arguments have fully streamed in.
    case toolCall(id: String, name: String, input: [String: Any])
    /// The turn ended. `stopReason` is the provider's reason: `"tool_use"`/
    /// `"tool_calls"` means the model is waiting on tool results and the harness
    /// should run another turn; anything else (`"end_turn"`, `"stop"`, …) means
    /// the model is done.
    case finished(stopReason: String?)
}

/// One web result a search tool surfaced — the structured source behind a cited
/// answer, kept so the UI can show a clickable source badge under the answer. The
/// text fed back to the model is separate (and lossy); this preserves the URL +
/// metadata the model's prose would otherwise drop. `Codable` so it rides on the
/// persisted `Turn`.
struct WebSource: Codable, Equatable, Sendable, Identifiable {
    var id: String { url }
    let title: String
    let url: String
    /// The publication date as the provider reported it, if any (e.g. "2026-06-23").
    var date: String?

    /// The page's host with any leading `www.` dropped — "www.tmtpost.com" →
    /// "tmtpost.com", "finance.sina.com.cn" → "finance.sina.com.cn". This is the
    /// "web address" the search activity line reads out ("Reading tmtpost.com"),
    /// deliberately the whole host (not the short `site` label) so it reads as an
    /// address. Falls back to the short `site` when the URL has no host.
    var host: String {
        guard var host = URL(string: url)?.host else { return site }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// The short site name shown on the badge — the registrable domain's main
    /// label, so "www.tmtpost.com" → "tmtpost", "finance.sina.com.cn" → "sina",
    /// "so.com" → "so". We take the second-to-last label *unless* the host ends in
    /// a country-code SLD like ".com.cn"/".co.uk" (where the real name is one
    /// further left). Falls back to the title's first token when there's no host.
    var site: String {
        guard let host = URL(string: url)?.host else {
            return title.split(separator: " ").first.map(String.init) ?? title
        }
        var labels = host.split(separator: ".").map(String.init)
        if labels.first == "www" { labels.removeFirst() }
        guard labels.count >= 2 else { return labels.first ?? host }
        // Two-part public suffixes (com.cn, co.uk, com.hk, …): the name sits one
        // label further left than the usual second-to-last.
        let twoPartSuffix: Set<String> = ["com", "co", "net", "org", "gov", "edu"]
        let secondToLast = labels[labels.count - 2]
        if labels.count >= 3, twoPartSuffix.contains(secondToLast) {
            return labels[labels.count - 3]
        }
        return secondToLast
    }
}

/// One tool call the model made, paired with the result the harness produced —
/// the unit a follow-up turn needs to continue the conversation.
struct ToolInvocation: Sendable {
    let id: String
    let name: String
    let input: [String: Any]
    /// The string result fed back to the model. On a tool error this carries the
    /// error text and `isError` is true (the model is told the call failed and can
    /// adapt, rather than the whole turn dying).
    var result: String = ""
    var isError: Bool = false
    /// Structured sources a search tool surfaced this call, for the UI's source
    /// badge. Empty for non-search tools; the model never sees these (it gets
    /// `result`), they ride straight to the on-screen turn.
    var sources: [WebSource] = []
}

/// The conversation as the harness threads it back to the provider. Beyond the
/// plain user/assistant text turns, an agent conversation also carries
/// *assistant tool-call* turns and *tool-result* turns, which the two wire
/// formats (Anthropic vs OpenAI) encode differently. `AgentMessage` is the
/// provider-neutral shape; each client lowers it to its own JSON.
struct AgentMessage: Sendable {
    enum Kind: Sendable {
        /// Plain text turn — `role` is "user" or "assistant", `text` is the body.
        case text(role: String, text: String)
        /// An assistant turn that requested tool calls. `text` is any prose the
        /// model wrote alongside the calls (often empty); `calls` are the requests.
        case assistantToolCalls(text: String, calls: [ToolInvocation])
        /// The results of those calls, sent back as the next user turn.
        case toolResults([ToolInvocation])
    }
    let kind: Kind
}

/// The streaming-turn capability. A provider that can drive tool calls implements
/// this in addition to the base `stream`; one that can't simply doesn't, and the
/// harness falls back to plain single-shot streaming. `tools` is the JSON-Schema
/// tool list in the provider's expected shape's *neutral* form (see `ToolSpec`).
protocol AgentCapableService: AIService {
    func streamTurn(system: String,
                    messages: [AgentMessage],
                    tools: [ToolSpec]) -> AsyncThrowingStream<TurnEvent, Error>
}

/// A tool as advertised to the model: a name, a description the model reads to
/// decide when to call it, and a JSON-Schema object describing its input. Kept
/// provider-neutral; each client serializes it into Anthropic's `{name,
/// description, input_schema}` or OpenAI's `{type:"function", function:{...}}`.
struct ToolSpec: Sendable {
    let name: String
    let description: String
    /// The JSON Schema for the tool input, as a nested dictionary
    /// (`["type": "object", "properties": [...], "required": [...]]`).
    let schema: [String: Any]
}

// MARK: - Tool protocol & registry

/// A capability the agent can invoke. Implementations are pure-ish leaf actions —
/// read the clipboard, fetch the time, open a URL — that take a decoded input dict
/// and return a short string the model reads back. Kept off the main actor so
/// several can run concurrently; a tool that must touch the main actor (UI, NSApp)
/// hops there itself inside `execute`.
protocol NotchTool: Sendable {
    /// Stable identifier the model calls by. Lowercase snake_case, e.g.
    /// `read_clipboard`.
    var name: String { get }
    /// What the tool does and *when* to use it — the model relies on this to decide
    /// whether to call it, so be prescriptive about the trigger, not just the action.
    var description: String { get }
    /// JSON Schema for `execute`'s input (a `type: object`). An argument-less tool
    /// returns an empty-properties object.
    var schema: [String: Any] { get }
    /// Run the tool. `input` is the model's decoded arguments. Return a short
    /// string the model reads; throw to signal failure (the harness turns the
    /// thrown error into an `isError` tool result rather than aborting the turn).
    func execute(_ input: [String: Any]) async throws -> String
}

extension NotchTool {
    /// The advertised spec derived from the tool's own metadata.
    var spec: ToolSpec { ToolSpec(name: name, description: description, schema: schema) }
}

/// A tool that, besides the string it feeds the model, surfaces structured web
/// sources for the UI's source badge. A search tool runs once and produces both:
/// the model reads `text`, the on-screen turn keeps `sources`. Tools that conform
/// are run through `runSourced` instead of `execute`, so the structured URLs
/// aren't lost to the text-only path.
protocol SourcedTool: NotchTool {
    /// Run the tool, returning the model-facing text *and* the structured sources.
    func runSourced(_ input: [String: Any]) async throws -> (text: String, sources: [WebSource])
}

/// The set of tools available to the agent this turn. Construction decides the
/// surface: an unconfigured or restricted session can be handed an empty registry,
/// which makes `submit` fall straight back to plain streaming (no tools → no
/// agent loop).
struct ToolRegistry: Sendable {
    let tools: [NotchTool]

    init(_ tools: [NotchTool]) { self.tools = tools }

    var isEmpty: Bool { tools.isEmpty }
    var specs: [ToolSpec] { tools.map(\.spec) }

    func tool(named name: String) -> NotchTool? {
        tools.first { $0.name == name }
    }

    /// Run one invocation, capturing success or failure into the invocation's
    /// `result`/`isError` so the harness can thread it back regardless of outcome.
    /// An unknown tool name is itself an error result, never a crash. A
    /// `SourcedTool` also fills `sources` (for the UI badge) from the same run.
    func run(_ call: ToolInvocation) async -> ToolInvocation {
        var out = call
        guard let tool = tool(named: call.name) else {
            out.result = "Error: no tool named \(call.name)."
            out.isError = true
            return out
        }
        do {
            if let sourced = tool as? SourcedTool {
                let (text, sources) = try await sourced.runSourced(call.input)
                out.result = text
                out.sources = sources
            } else {
                out.result = try await tool.execute(call.input)
            }
        } catch {
            out.result = "Error: \(error.localizedDescription)"
            out.isError = true
        }
        return out
    }
}

// MARK: - The harness loop

/// Drives the agentic loop on top of an `AgentCapableService`. Each iteration:
/// stream one turn, surfacing text as it arrives; if the model requested tools,
/// run them concurrently, append the assistant-call turn and the tool-result turn
/// to the running conversation, and loop; otherwise stop.
///
/// The harness is deliberately UI-agnostic — it reports progress through two
/// callbacks so `NotchModel` can drive its existing streaming `Turn` without the
/// harness knowing anything about SwiftUI. It also respects cancellation at every
/// await point (the surrounding `Task` is cancelled on supersede / panel close,
/// exactly as the plain path), and bounds itself with `maxIterations` so a model
/// that loops forever on tools can't pin the task open.
struct AgentHarness {
    let service: AgentCapableService
    let registry: ToolRegistry
    /// Hard ceiling on tool-call rounds. A well-behaved turn finishes in 1–3; the
    /// cap is a runaway-loop backstop, after which we force a final no-tools turn so
    /// the user still gets a closing answer instead of a dangling tool request.
    var maxIterations: Int = 8

    /// Minimum on-screen time for the tool-activity line, so a fast tool (clipboard
    /// and time return in milliseconds) still shows a full, readable cue instead of
    /// a one-frame flicker. The tools run *during* this window — it delays only the
    /// label's clear, not the work. Sized to comfortably cover a fade-in, a beat to
    /// read it, and the fade-out.
    static let minActivityVisible: TimeInterval = 0.9

    /// Streamed visible text → append to the on-screen answer (same role as the
    /// plain `stream`'s chunks). Main-actor isolated: it drives `NotchModel`'s
    /// `@MainActor` UI state, and the harness awaits it per chunk so ordering holds.
    /// Not `@Sendable` — it's only ever called from the harness's `run`, which the
    /// caller runs on the main actor, so it can capture main-actor mutable state.
    typealias TextSink = @MainActor (String) -> Void
    /// A tool is about to run / has finished → drive a transient "🔍 searching…"
    /// activity line on the streaming turn. `nil` clears it. The `OrbState`
    /// rides alongside so the wait line's thinking orb can wear the matching
    /// reference mode (globe while searching, orbits while a tool works) —
    /// decided HERE, where the tool name is known, never re-derived from the
    /// localized label downstream. Also main-actor.
    typealias ActivitySink = @MainActor (String?, OrbState) -> Void
    /// A search round produced structured sources → attach them to the answer turn
    /// for the source badge. Called with the round's sources (accumulated across
    /// rounds is the caller's job). Main-actor.
    typealias SourcesSink = @MainActor ([WebSource]) -> Void
    /// The concrete model the provider ran → stamp it on the answer turn so the
    /// footer can show which model produced this reply (esp. for the
    /// `openrouter/free` auto-router). Fires once, on the first turn that reports
    /// a model. Main-actor.
    typealias ModelSink = @MainActor (String) -> Void

    /// Run the loop to completion. `onText` receives answer chunks; `onActivity`
    /// receives tool-progress labels; `onSources` receives any web sources a search
    /// round surfaced. Returns when the model stops asking for tools (or the
    /// iteration cap forces a close). Throws on a real stream error or
    /// cancellation, exactly like the plain path, so the caller's existing
    /// catch/persist logic applies unchanged.
    ///
    /// `@MainActor` so the whole loop runs where the plain single-shot stream loop
    /// ran — UI sinks fire synchronously in order, and the consuming side of
    /// `streamTurn` (whose producer stays on a detached `URLSession` task) is driven
    /// from the main actor exactly as the old `for await chunk` loop was.
    @MainActor
    func run(system: String,
             messages: [AgentMessage],
             onText: @escaping TextSink,
             onActivity: @escaping ActivitySink,
             onSources: @escaping SourcesSink,
             onModel: ModelSink? = nil) async throws {
        var convo = messages
        var iteration = 0
        // True once the model has run at least one tool round. It changes what the
        // *gap* should say: before any tool the wait is plain "thinking" (the load
        // view's dots); after a tool round, the gap is the model reading what it
        // just fetched, so we keep a "composing" cue on screen instead of dropping
        // back to generic dots (the empty state Cyrus flagged). It also tells a
        // second-or-later tool round to say "refining" rather than "searching".
        var didTool = false
        // The concrete model is reported to `onModel` at most once across the whole
        // answer (a multi-turn tool answer keeps the model of its first turn).
        var reportedModel = false
        // How many *search* rounds (not generic tool rounds) have completed. Drives
        // the escalating "stop searching, answer now" nudge that breaks the runaway
        // re-search loop on queries the web can't cleanly answer — see
        // `searchStopNudge`. Counts only search rounds because only search is prone
        // to the loop; a clipboard/time read never spirals.
        var searchRounds = 0

        while true {
            try Task.checkCancellation()
            // Past the cap, advertise no tools: the model is forced to answer from
            // what it has, guaranteeing a terminating turn.
            let toolsThisTurn = iteration >= maxIterations ? [] : registry.specs

            var assistantText = ""
            var pendingCalls: [ToolInvocation] = []
            var stopReason: String? = nil
            // First visible token of *this* turn clears whatever gap label was
            // showing (a "composing…" carried over from the prior tool round):
            // the answer is now arriving, so the cue has done its job.
            var clearedGapLabel = false
            // Defends against a model that occasionally emits its tool call as
            // plain text DSL (`<|…|>` markup) instead of a structured tool_call —
            // an intermittent provider glitch. The filter swallows that markup so
            // the user never sees raw `<|DSML|invoke …>` soup in the answer.
            var markupFilter = ToolMarkupFilter()

            for try await event in service.streamTurn(system: system,
                                                      messages: convo,
                                                      tools: toolsThisTurn) {
                try Task.checkCancellation()
                switch event {
                case .text(let piece):
                    let visible = markupFilter.feed(piece)
                    guard !visible.isEmpty else { continue }
                    if !clearedGapLabel {
                        onActivity(nil, .composing)
                        clearedGapLabel = true
                    }
                    assistantText += visible
                    onText(visible)
                case .model(let ran):
                    // Report the concrete model once for the whole answer — the
                    // first turn that names it wins (a multi-tool answer keeps the
                    // model it started on).
                    if !reportedModel {
                        reportedModel = true
                        onModel?(ran)
                    }
                case .toolCallStarted(let name):
                    // The model has committed to a tool; its arguments are still
                    // streaming. Raise the activity line NOW, from the name alone,
                    // so the wait never goes dark between a spoken preface and the
                    // tool actually running. The label is re-derived (and, for
                    // read_page, refined with the page's host) when the assembled
                    // calls execute below — same helpers, so the words agree.
                    let preview = [ToolInvocation(id: "", name: name, input: [:])]
                    onActivity(activityLabel(for: preview, isRepeatRound: didTool),
                               Self.orbState(for: preview))
                    // Text after this point is call-adjacent prose, not the answer
                    // displacing the label — don't let it clear the line.
                    clearedGapLabel = true
                case .toolCall(let id, let name, let input):
                    pendingCalls.append(ToolInvocation(id: id, name: name, input: input))
                case .finished(let reason):
                    stopReason = reason
                }
            }
            // Flush any character held back as a possible markup opener: if the
            // stream ended mid-`<` it was just a stray `<`, so let it through.
            if let tail = markupFilter.flush(), !tail.isEmpty {
                assistantText += tail
                onText(tail)
            }

            // Whether the provider stopped because it hit the token limit (OpenAI
            // `"length"` / Anthropic `"max_tokens"`) rather than finishing cleanly.
            // Two very different failure modes ride this flag, handled below.
            let truncated = stopReason == "length" || stopReason == "max_tokens"

            // No tool calls (or we suppressed them at the cap) → the model is done.
            if pendingCalls.isEmpty {
                onActivity(nil, .composing)
                // A clean stop → done. But if the model ran out of budget mid-answer,
                // the visible text is cut off mid-sentence with no sign to the user.
                // Append a short marker so the reply doesn't just trail off as if
                // complete. (Only when we actually streamed something — a truncated
                // *empty* turn is the malformed-response case the stream layer already
                // retries, not ours to annotate.)
                if truncated && !assistantText.isEmpty {
                    onText(L("error.truncated"))
                }
                return
            }

            // Truncated *while emitting a tool call*: the arguments JSON was very
            // likely cut off mid-object, so `decodeArgs` fell back to an empty/partial
            // input dict — executing on that runs the tool with garbage (an empty
            // `url`, a blank `query`) and confuses the model with a spurious error.
            // Don't run it. Instead push the assistant text we did get plus a system
            // note telling the model its output was too long, and loop so it retries
            // more concisely. Count the round so a model that keeps overshooting still
            // hits the cap and is forced to a final answer rather than spinning.
            if truncated && iteration < maxIterations {
                // ALWAYS append the assistant turn, even with no prose (the common
                // case — models usually emit tool calls without preamble). Skipping
                // it would leave the note adjacent to the previous user-role message
                // (the question, or tool results — which lower to role "user" on
                // Anthropic), breaking the strict user/assistant alternation. An
                // *empty* assistant turn is equally rejected, so stand in a marker
                // the model reads as its own cut-off output.
                let replay = assistantText.isEmpty ? "[output truncated]" : assistantText
                convo.append(AgentMessage(kind: .text(role: "assistant", text: replay)))
                convo.append(AgentMessage(kind: .text(role: "user", text:
                    "[System note] Your previous message was cut off because it "
                    + "exceeded the length limit before the tool call finished, so it "
                    + "could not be run. Issue fewer tool calls at once and keep each "
                    + "one's arguments short, or answer directly if you already have "
                    + "enough to respond.")))
                onActivity(nil, .composing)
                iteration += 1
                continue
            }

            // Surface what's running, then execute every call concurrently. The
            // results are reassembled in request order so the wire turn lines up
            // with the assistant's tool_use blocks.
            //
            // Hold the activity line on screen for at least `minActivityVisible`
            // even when the tool returns almost instantly (the clipboard/time
            // tools take milliseconds): otherwise the cue flickers in and out in a
            // frame and reads as a glitch. We don't slow the actual work — the
            // tools run during the dwell — we only delay *clearing* the label so it
            // completes a full appear → settle → disappear cycle. The fade in/out
            // itself is the view's `.transition(.opacity)` (see `turnView`).
            let shownAt = Date()
            onActivity(activityLabel(for: pendingCalls, isRepeatRound: didTool),
                       Self.orbState(for: pendingCalls))
            let completed = await runConcurrently(pendingCalls)
            let elapsed = Date().timeIntervalSince(shownAt)
            if elapsed < Self.minActivityVisible {
                let remaining = Self.minActivityVisible - elapsed
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            try Task.checkCancellation()
            // Hand any structured sources this round produced to the UI so they can
            // appear as a source badge under the answer. Deduped/accumulated on the
            // caller's side across rounds.
            let roundSources = completed.flatMap(\.sources)
            if !roundSources.isEmpty { onSources(roundSources) }
            // Don't clear into a blank gap: the next turn is the model reading these
            // results and composing the answer, which takes a real round-trip. Carry
            // a "composing…" cue through that gap so the wait stays narrated; the
            // next turn's first token (or its next tool round) replaces it. Only the
            // fetch-style tools warrant this — a clipboard/time read composes
            // instantly, so for those we just clear. `read_page` gets the cue too
            // (the model chews on up to ~8k chars of page text) but deliberately
            // stays out of `isSearchTool`: it must not count as a search round or
            // draw the stop-searching nudge — reading a page is how the model
            // *escapes* the re-search loop, not another lap of it.
            if pendingCalls.contains(where: { Self.isSearchTool($0.name) || $0.name == "read_page" }) {
                // The read-the-results gap is still the search flow — keep the globe.
                onActivity(L("agent.activity.composing"), .searching)
            } else {
                onActivity(nil, .composing)
            }
            try Task.checkCancellation()

            // If this round searched, escalate the pressure to answer rather than
            // search yet again: append a round-scaled "stop searching" note to each
            // search result's text. Keyed off how many search rounds already
            // finished (`searchRounds`), so the first search runs clean and the nudge
            // hardens each subsequent round until the cap. This is what stops a model
            // from re-wording the same fruitless query forever (the "南昌一月气温" loop).
            var resultsToSend = completed
            let didSearchThisRound = pendingCalls.contains { Self.isSearchTool($0.name) }
            if didSearchThisRound,
               let nudge = Self.searchStopNudge(priorSearchRounds: searchRounds,
                                                cap: maxIterations) {
                for i in resultsToSend.indices where Self.isSearchTool(resultsToSend[i].name) {
                    resultsToSend[i].result += nudge
                }
            }

            convo.append(AgentMessage(kind: .assistantToolCalls(text: assistantText,
                                                                calls: pendingCalls)))
            convo.append(AgentMessage(kind: .toolResults(resultsToSend)))
            if didSearchThisRound { searchRounds += 1 }
            didTool = true
            iteration += 1
            _ = stopReason  // reason is informational; presence of calls drives the loop
        }
    }

    /// Execute all of a turn's tool calls at once, preserving request order in the
    /// returned array (a `tool_result` must map back to its `tool_use` by id, and
    /// some providers also care about order).
    private func runConcurrently(_ calls: [ToolInvocation]) async -> [ToolInvocation] {
        await withTaskGroup(of: (Int, ToolInvocation).self) { group in
            for (i, call) in calls.enumerated() {
                group.addTask { (i, await registry.run(call)) }
            }
            var out = Array<ToolInvocation?>(repeating: nil, count: calls.count)
            for await (i, done) in group { out[i] = done }
            return out.compactMap { $0 }
        }
    }

    /// Tool names that hit the network for fresh information — the ones whose
    /// follow-up "reading the results" gap is worth narrating with a "composing…"
    /// cue. `lookup_web` is GLM's client search tool (deliberately not named
    /// `web_search` to avoid colliding with GLM's builtin); `$web_search` is Kimi's
    /// builtin echo; `keenable_search` / `exa_search` are the unified client searchers.
    private static func isSearchTool(_ name: String) -> Bool {
        name == "lookup_web" || name == "$web_search"
            || name == "exa_search" || name == "keenable_search"
    }

    /// An escalating "stop searching, answer now" nudge appended to each search
    /// result's text, keyed by how many search rounds have already happened. This is
    /// the cure for the runaway-search loop: when a query has no clean answer on the
    /// web (e.g. "南昌一月气温", where every result is near-miss climate filler with no
    /// hard number), a model left to its own devices keeps *rewording and re-searching*
    /// forever — each round it sees fresh-but-still-inconclusive results and optimistically
    /// tries again, burning every iteration until the cap forces an empty close. The fix
    /// is to gently raise the pressure to answer from what's in hand, so the model
    /// *chooses* to stop (and say "I couldn't find it" if need be) instead of being
    /// hard-cut. Pressure ramps with the round count rather than slamming a wall, so a
    /// genuinely multi-step query that legitimately needs 3–4 searches isn't strangled.
    ///
    /// Returned text is the instruction the *model* reads, so it is deliberately
    /// English (and not run through `L()`): every provider — domestic CJK models
    /// included — follows an English system-style directive most reliably, exactly as
    /// the tool descriptions are English. `priorSearchRounds` is the number of search
    /// rounds already completed *before* this one (0 on the first search → no nudge).
    ///
    /// `cap` is the harness's `maxIterations`; the final-warning tier keys off "this is
    /// the last round before tools are withdrawn" so the wording matches reality.
    private static func searchStopNudge(priorSearchRounds: Int, cap: Int) -> String? {
        // The round about to be appended is search #(priorSearchRounds + 1). The harness
        // withdraws tools entirely once `iteration >= cap`, so the last round in which a
        // search can still be issued is round `cap`. One short blank line separates the
        // nudge from the results so it reads as a distinct instruction, not result text.
        let thisRound = priorSearchRounds + 1
        let nudge: String
        if thisRound < 2 {
            return nil  // first search: let it run clean, no pressure yet
        } else if thisRound >= cap {
            // Last round a search can still be issued — after this the harness withdraws
            // tools, so make the deadline explicit.
            nudge = "This is your last chance to search. On the next turn you must give "
                  + "the user an answer — even if that answer is that you could not find "
                  + "reliable information on this. Do not search again."
        } else if thisRound == 2 {
            nudge = "You have already searched once. Prefer answering from the results "
                  + "you now have; search again only if a specific, essential fact is "
                  + "still missing."
        } else {
            nudge = "You have searched \(priorSearchRounds) times. Do not search again "
                  + "unless it is truly unavoidable — answer from what you already have, "
                  + "or tell the user plainly that the search did not turn up an answer."
        }
        return "\n\n[System note] " + nudge
    }

    /// The thinking-orb mode for the running calls — the semantic twin of
    /// `activityLabel`, decided from the same tool names in the same place so
    /// the orb and the words can never disagree. The whole search flow (search,
    /// refine, read a page) wears the reference's searching globe; everything
    /// else that runs a tool wears the working orbits; `ask_user` is a wait on
    /// the human, not work, so it keeps the calm thinking ribbon (the wait line
    /// is usually hidden behind the question card there anyway).
    static func orbState(for calls: [ToolInvocation]) -> OrbState {
        if let first = calls.first, calls.count == 1 {
            switch first.name {
            case "lookup_web", "$web_search", "exa_search", "keenable_search", "read_page":
                return .searching
            case "ask_user":
                return .composing
            default:
                return .working
            }
        }
        // A multi-call round is mixed work; orbits is the honest generic.
        return .working
    }

    /// A short, human-readable progress label for the running calls, e.g.
    /// "Searching the web…". `isRepeatRound` is true on a second-or-later tool
    /// round, where a search reads as "digging deeper" rather than a fresh start.
    /// Falls back to a generic line for unmapped tools.
    private func activityLabel(for calls: [ToolInvocation], isRepeatRound: Bool) -> String {
        if let first = calls.first, calls.count == 1 {
            switch first.name {
            case "lookup_web", "$web_search", "exa_search", "keenable_search":
                return L(isRepeatRound ? "agent.activity.refining" : "agent.activity.search")
            case "ask_user": return L("agent.activity.askUser")
            case "read_clipboard": return L("agent.activity.clipboard")
            case "current_datetime": return L("agent.activity.time")
            case "calculate": return L("agent.activity.calc")
            case "read_page":
                // Read the host out of the url argument so it reads as an address
                // ("Reading tmtpost.com"); fall back to the generic line if absent.
                if let raw = first.input["url"] as? String,
                   var host = URL(string: raw)?.host {
                    if host.hasPrefix("www.") { host.removeFirst(4) }
                    return L("agent.activity.readingPage", host)
                }
                return L("agent.activity.working")
            default:
                // An unmapped tool still gets NAMED rather than hiding behind a
                // bare "Working…" — the weakest wait line in the app. The raw id
                // is prettified just enough to read as words ("fetch_weather" →
                // "fetch weather").
                let pretty = first.name
                    .trimmingCharacters(in: CharacterSet(charactersIn: "$"))
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                if !pretty.isEmpty {
                    return L("agent.activity.runningTool", pretty)
                }
            }
        }
        return L("agent.activity.working")
    }
}

/// Strips tool-call DSL markup that some models occasionally leak into their
/// *text* output instead of returning a structured tool_call. The tell-tale is a
/// `<|…|>` opener (e.g. MiniMax's `<|DSML|tool_calls>` / `<|DSML|invoke name=…>`);
/// normal answer prose never contains the `<` + pipe sequence, so it's a safe
/// sentinel. The pipe comes in two flavors: the ASCII `|` (U+007C) and the
/// **fullwidth** `｜` (U+FF5C). Chinese-trained tokenizers (MiniMax, DeepSeek,
/// GLM, Kimi, Qwen) emit their special control tokens with the fullwidth bar —
/// the real leaked token is `<｜tool▁calls｜>`, not `<|...|>` — so both must be
/// treated as the opener, or the markup sails straight through (the bug Cyrus
/// kept seeing after the half-width-only first fix).
///
/// Stateful because text streams in token by token: an opener can be split across
/// chunks (`<`, then `|DS`…). Once an opener is seen, *everything* from it onward
/// in the turn is swallowed — the whole leaked tool-call block (tags plus the
/// query text nested inside) is junk to the user, and a well-behaved turn won't
/// resume prose after starting one. A lone trailing `<` is held back until the
/// next chunk (or `flush`) disambiguates whether it began an opener.
private struct ToolMarkupFilter {
    private var suppressing = false   // saw `<|` — swallow the rest of the turn
    private var heldBracket = false   // last char was a bare `<`, decision pending

    /// The opener's second character: the ASCII vertical bar or its fullwidth
    /// twin. Matching both is what makes the filter catch the Chinese-tokenizer
    /// markup (`<｜…｜>`) and not just the half-width `<|…|>`.
    private static func isPipe(_ c: Character) -> Bool { c == "|" || c == "\u{FF5C}" }

    /// Feed one streamed chunk; returns the portion safe to show the user.
    mutating func feed(_ piece: String) -> String {
        if suppressing { return "" }
        var out = ""
        // A `<` carried over from the previous chunk: decide it now.
        var s = Substring(piece)
        if heldBracket {
            heldBracket = false
            if let first = s.first {
                if Self.isPipe(first) { suppressing = true; return out }  // `<|` → leak begins
                out.append("<")                                          // stray `<`, keep it
            } else {
                heldBracket = true                                  // still nothing after `<`
                return out
            }
        }
        while let lt = s.firstIndex(of: "<") {
            out += s[s.startIndex..<lt]
            let after = s.index(after: lt)
            if after == s.endIndex {        // chunk ends exactly on `<` — hold it
                heldBracket = true
                return out
            }
            if Self.isPipe(s[after]) {      // `<|` → start of leaked markup
                suppressing = true
                return out
            }
            out.append("<")                 // a `<` not followed by `|` is real text
            s = s[after...]
        }
        out += s
        return out
    }

    /// Stream ended: release a held bare `<` (it never became an opener).
    mutating func flush() -> String? {
        defer { heldBracket = false }
        return heldBracket ? "<" : nil
    }
}
