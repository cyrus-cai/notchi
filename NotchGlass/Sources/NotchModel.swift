import SwiftUI
import Combine
import AppKit   // NSWorkspace — opening Notes/Reminders for a Recent capture
import Carbon.HIToolbox
import UniformTypeIdentifiers   // UTType — is a pasted file URL an image? (agent ⌘V)

/// Images loaded back out of the history store (`NotchModel.historyImage(named:)`),
/// keyed by filename. File-scope rather than a static on the (main-actor) model, so
/// the loader can stay `nonisolated` — a thumbnail is read from wherever the view or
/// a background sweep happens to run. `NSCache` is thread-safe and evicts under
/// memory pressure, so a big archive can't pin every screenshot it ever saw in RAM.
private let historyImageCache = NSCache<NSString, NSImage>()

/// Decodes a JSON array element-by-element, dropping any element that fails to
/// decode instead of failing the whole array. Used for persisted history so one
/// corrupt or future-incompatible row can't wipe every Recent item (see
/// `loadHistory`). A single `try? decode([T].self …)` is all-or-nothing; this
/// isolates each element behind its own `try?`.
private struct LossyArray<T: Decodable>: Decodable {
    let elements: [T]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [T] = []
        while !container.isAtEnd {
            // Decode each element into a throwaway wrapper so a failure advances the
            // container past the bad element (a bare `try? container.decode(T.self)`
            // leaves the cursor stuck and loops forever). The wrapper swallows the
            // error and yields nil; the element is then skipped.
            if let decoded = try container.decode(LossyElement<T>.self).value {
                result.append(decoded)
            }
        }
        elements = result
    }
}

/// One element of a `LossyArray`: decodes a `T`, or captures the failure as `nil`
/// while still consuming the element so the parent container can advance.
private struct LossyElement<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// The live conversation's turns, split into their own ObservableObject so the
/// ~30Hz streaming flushes invalidate ONLY the views that actually render the
/// thread (NotchBody observes this store directly). Before the split `turns` was
/// `@Published` on `NotchModel` itself, and — `@Published` granularity being the
/// whole object — every streamed chunk re-evaluated the body of EVERY surface
/// observing the model: the settings panel, onboarding, What's New, the History
/// window, none of which render the conversation. The model still exposes a
/// `turns` forwarder so its own logic reads/writes exactly as before.
@MainActor
final class ConversationStore: ObservableObject {
    @Published var turns: [NotchModel.Turn] = []
}

/// The notch's interaction state. Mirrors the prototype's `mode` plus the
/// open/closed state, and owns the history list + AI calls.
@MainActor
final class NotchModel: ObservableObject {
    enum Mode: Equatable {
        case idle      // resting input, may show "Recent"
        case load      // waiting on the AI
        case result    // showing an answer
    }

    /// Where pressing Enter on the current line will *send* it — whatever the user
    /// last pinned, and nothing else. This is a routing destination, NOT a rendered
    /// surface: there's only ever one input on screen ("Type anything…"). It just
    /// determines whether Enter asks the AI or files the line somewhere.
    ///   · `chat`     — ask the AI a question (idle/load/result)
    ///   · `note`     — file the line as a new note in Apple Notes
    ///   · `reminder` — file the line in Apple Reminders with the time it names
    enum Panel: String, Equatable {
        case chat
        case note
        case reminder
    }

    /// One bubble in the on-screen conversation. `role` is `"user"` or
    /// `"assistant"`; the assistant turn is created empty and filled as the stream
    /// arrives (`streaming` is true until it finishes), which is what lets the text
    /// appear to grow in place.
    struct Turn: Identifiable, Codable, Equatable {
        var id = UUID()
        var role: String     // "user" | "assistant"
        var text: String
        var streaming: Bool = false
        /// The prompt-shortcut request still belongs to the transcript and wire
        /// context, but its generated instruction + selected-text payload is an
        /// implementation detail and should not render as a user bubble.
        var hidesUserBubble: Bool = false
        /// True on the *user* turn whose message was enriched with the clipboard, so
        /// the result view can show a permanent "based on what you copied" trace above
        /// it — not a flag that flashes during load and vanishes. Always false on
        /// assistant turns.
        var usedClipboard: Bool = false
        /// A transient "🔍 searching…" label shown on a *streaming assistant* turn
        /// while the agent harness runs a tool, then cleared. Purely runtime UI — it
        /// is never persisted (no `CodingKey`), so a saved conversation never carries
        /// a stale activity line. `nil` whenever no tool is running.
        var toolActivity: String? = nil
        /// The rest of a live answer's presentation state. These values are
        /// runtime-only, just like `toolActivity`: detached windows mirror the
        /// exact state the panel renders instead of reconstructing a second,
        /// lossy "Thinking" state from the question text.
        var thinkingWord: String? = nil
        var thinkingOrbState: OrbState? = nil
        var thinkingStartedAt: Date? = nil
        var pendingQuestion: PendingUserQuestion? = nil
        /// Web sources behind this assistant answer, when it was grounded by a
        /// search tool (GLM today). Drives the clickable source badge under the
        /// answer. Persisted, so reopening a recent item keeps its sources.
        var sources: [WebSource] = []
        /// True on an *assistant* turn whose text is a failure reason written by the
        /// error path (the XII-85 error card), not model output. Persisted, because a
        /// later successful round snapshots the whole thread into history — and the
        /// wire context must keep filtering the error turn out after a reopen, so the
        /// model never sees "Anthropic · HTTP 401" as something it once said.
        var isError: Bool = false
        /// The model this assistant turn was regenerated with (XII-135), when it
        /// differs from the user's default — set by a one-shot "regenerate with…"
        /// pick so the answer can show which model produced it. `nil` for the normal
        /// case (default model), so a plain answer carries no annotation. Persisted,
        /// so a reopened thread still shows the badge.
        var regenModel: String? = nil
        /// The concrete model the provider actually ran for this assistant answer,
        /// as echoed back in the stream's `model` field. Its whole reason to exist
        /// is the `openrouter/free` auto-router: the request only names the router,
        /// so this is the sole record of which model really replied (e.g.
        /// `openai/gpt-oss-20b:free`). The footer strips the vendor prefix and
        /// `:free` suffix to show a bare model name. `nil` when the provider didn't
        /// report one (or on the plain non-agent path). Persisted, so a reopened
        /// thread still shows it.
        var answerModel: String? = nil

        /// The images this (user) turn rode in with — the copied screenshot an Ask
        /// attached, or the shots pasted into an agent task — as filenames under
        /// `NotchModel.historyImagesDirectory`, never bytes: the archive is one JSON
        /// file rewritten after every answer, and inlining base64 screenshots would
        /// add hundreds of KB to every rewrite. Empty for a plain text turn; a file
        /// that's since been deleted simply renders as nothing.
        var imageFiles: [String] = []

        /// True on a turn that is an agent run's record (the task prompt, the
        /// CLI's report) rather than a chat exchange. Gates the chat-only
        /// affordances on a reopened run: regenerate would re-run the task's
        /// prompt against the *chat model*, which can't touch the run's folder —
        /// so an agent report never offers it. Persisted, so a reopened run
        /// stays distinguishable from an Ask thread.
        var isAgent: Bool = false

        /// An agent answer turn's work trail — the round's tool calls and
        /// narration, sliced per round at settle (`AgentExchange.log`). The
        /// reopened record renders it above the report, so the thread reads
        /// like the live detail page did. `nil` on chat turns and on agent
        /// records filed before the trail was persisted.
        var agentLog: [AgentLogEntry]? = nil

        init(id: UUID = UUID(), role: String, text: String,
             streaming: Bool = false, usedClipboard: Bool = false,
             hidesUserBubble: Bool = false) {
            self.id = id; self.role = role; self.text = text
            self.streaming = streaming; self.usedClipboard = usedClipboard
            self.hidesUserBubble = hidesUserBubble
        }

        // Same defensive decode as `HistoryItem` (see the long note there): turns
        // are persisted inside a saved thread, and the whole history list is
        // decoded in one `try?` — so a turn saved before `usedClipboard`/`streaming`
        // existed must NOT throw `keyNotFound` and take the entire list down with
        // it. `decodeIfPresent` + defaults is what keeps old saved conversations
        // loadable. `role`/`text` are required — every saved turn has them.
        // `toolActivity` is deliberately absent: it's runtime-only UI state.
        enum CodingKeys: String, CodingKey { case id, role, text, streaming, hidesUserBubble, usedClipboard, sources, isError, regenModel, answerModel, imageFiles, isAgent, agentLog }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id           = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            role         = try c.decode(String.self, forKey: .role)
            text         = try c.decode(String.self, forKey: .text)
            streaming    = try c.decodeIfPresent(Bool.self, forKey: .streaming) ?? false
            hidesUserBubble = try c.decodeIfPresent(Bool.self, forKey: .hidesUserBubble) ?? false
            usedClipboard = try c.decodeIfPresent(Bool.self, forKey: .usedClipboard) ?? false
            sources      = try c.decodeIfPresent([WebSource].self, forKey: .sources) ?? []
            isError      = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            regenModel   = try c.decodeIfPresent(String.self, forKey: .regenModel)
            answerModel  = try c.decodeIfPresent(String.self, forKey: .answerModel)
            imageFiles   = try c.decodeIfPresent([String].self, forKey: .imageFiles) ?? []
            isAgent      = try c.decodeIfPresent(Bool.self, forKey: .isAgent) ?? false
            agentLog     = try c.decodeIfPresent([AgentLogEntry].self, forKey: .agentLog)
        }
    }

    struct HistoryItem: Identifiable, Codable, Equatable {
        var id = UUID()
        var q: String
        var a: String
        var t: Date
        /// The full conversation, so reopening a recent item restores every turn
        /// (not just the first Q/A). Optional for backward-compatible decoding of
        /// items saved before multi-turn — those fall back to `[q, a]`.
        var turns: [Turn]? = nil
        /// A short title summarizing the actual conversation content. Generated
        /// asynchronously after the first answer so the recent list can show the
        /// topic (e.g. "小米高管") instead of a generic first prompt (e.g.
        /// "总结一下"). `nil` for legacy items and for unconfigured/offline sessions.
        var title: String? = nil
        /// What the recent list should display: the generated title when available,
        /// otherwise the first user message for backward compatibility.
        var displayTitle: String { title ?? q }

        /// Every image attached anywhere in this conversation, in turn order — a
        /// screenshot an Ask rode in on, the shots pasted into an agent task. The
        /// Recent / archive rows preview the first one; the transcript shows them
        /// all on the turn they belong to.
        var imageFiles: [String] { (turns ?? []).flatMap(\.imageFiles) }

        /// Where this captured line actually went. `.ask` is an AI Q&A and `.agent`
        /// a finished Codex/Claude run — both are threads that reopen; `.note`/
        /// `.reminder` are captures filed into Apple Notes/Reminders — they keep a
        /// trace in Recent but have no answer to reopen, so tapping one jumps to
        /// that note/reminder in its app instead.
        /// Defaults to `.ask`; decoded with `decodeIfPresent` (see `init(from:)`)
        /// so items saved before this field decode as `.ask`, not a hard failure.
        /// (Agent runs filed before `.agent` existed stay `.ask` — they read as
        /// ordinary threads, which is exactly what they were.)
        enum Source: String, Codable {
            case ask, note, reminder, agent

            /// Rows whose body reopens a conversation, as opposed to a capture
            /// whose body is inert and whose trailing button jumps to another app.
            /// Every "is this an Ask row?" branch means this.
            var isThread: Bool { self == .ask || self == .agent }
        }
        var source: Source = .ask

        /// The interaction that created this row, when it needs its own scoped
        /// history surface. Ordinary panel asks and prompt shortcuts leave this
        /// nil; a conversation started from the Force Touch popup is stamped here
        /// so that popup's History button never mixes in unrelated Ask rows.
        enum Origin: String, Codable {
            case forceTouch
        }
        var origin: Origin? = nil

        /// Deep link back to the exact note/reminder this capture created, so
        /// tapping the row jumps straight to it in Apple Notes/Reminders instead
        /// of re-filling the input. The note's `x-coredata://` id (opened via
        /// AppleScript `show`) for notes, an `x-apple-reminderkit://` URL for
        /// reminders. `nil` for `.ask` items, and for captures saved before this
        /// field existed — those fall back to opening the destination app's main
        /// window (see `openCapture`). The service layer captures the identifier at
        /// creation time; if that capture fails the link stays nil and the row
        /// still opens the app, never dead-ends.
        var link: String? = nil

        /// How an `.agent` run ended — "success" / "failure" / "cancelled".
        /// Lets the detail surfaces show a failed run as failed instead of
        /// reading like an ordinary answer. `nil` for non-agent rows and for
        /// runs filed before this field existed.
        var agentOutcome: String? = nil

        /// The CLI session an `.agent` run left behind, and where it was working.
        /// Present on every settled row whose run reported a session id — it's
        /// what lets the reopened thread's follow-up resume the run in place
        /// (`continueAgentThread`), and what the interrupted row's resume button
        /// re-issues the cut round into.
        struct AgentResume: Codable, Equatable {
            /// `AgentEngine.rawValue` — the engine that owns the session.
            let engine: String
            let folderPath: String
            /// The CLI's own conversation handle (claude `session_id` / codex
            /// `thread_id`) — what `--resume` / `exec resume` takes.
            let session: String
        }
        var agentResume: AgentResume? = nil

        /// True only on a row whose run the app died during — the one row that
        /// grows the explicit resume button (`openAgentResume`). A resumed run
        /// re-files this same row on settle with this back to false, so the
        /// affordance disappears the moment the work is no longer interrupted.
        var agentInterrupted: Bool = false

        /// Transient: true while the first answer for this thread is still
        /// streaming. Set when the question is submitted so the row appears in
        /// Recent immediately (showing the question, with a three-dot placeholder
        /// where the timestamp goes), cleared once the answer lands (`persistThread`)
        /// or the round fails with nothing to keep (`settlePending`). Never encoded
        /// (absent from `CodingKeys`) — a reloaded item is always settled, so a row
        /// can't come back from disk stuck mid-answer.
        var pending: Bool = false

        /// True on a row whose last round produced no answer — the model returned
        /// nothing, or the stream died before the first token. The row is kept
        /// anyway (the question is the user's, and deleting it is how a whole
        /// conversation used to disappear from Recent); this is what lets it read
        /// as failed instead of passing for an ordinary answer. `a` carries the
        /// reason. Persisted, so the marker survives a relaunch.
        var failed: Bool = false

        /// The turns to restore on reopen: the saved thread when present, else a
        /// two-turn thread rebuilt from the legacy `q`/`a` fields. A note/reminder
        /// capture has no conversation at all — never synthesize a ghost assistant
        /// bubble for it.
        var conversation: [Turn] {
            guard source.isThread else { return [] }
            return turns ?? [
                Turn(role: "user", text: q),
                Turn(role: "assistant", text: a),
            ]
        }

        init(id: UUID = UUID(), q: String, a: String, t: Date,
             turns: [Turn]? = nil, title: String? = nil,
             source: Source = .ask, link: String? = nil,
             agentResume: AgentResume? = nil, origin: Origin? = nil) {
            self.id = id; self.q = q; self.a = a; self.t = t
            self.turns = turns; self.title = title
            self.source = source; self.link = link
            self.agentResume = agentResume
            self.origin = origin
        }

        // Custom decoder — the load-bearing reason this exists: history is decoded
        // as one `try? JSONDecoder().decode([HistoryItem].self …)` (see
        // `loadHistory`), so if ONE item fails to decode the WHOLE list is dropped
        // and every Recent row vanishes. Swift's *synthesized* `Decodable` calls
        // `decode` (not `decodeIfPresent`) for non-optional stored properties even
        // when they carry a Swift default — the `= .ask` / `= nil` defaults apply
        // only to the memberwise init, NOT to decoding. So an item saved before
        // `source`/`link`/`turns`/`title` existed would throw `keyNotFound` and
        // wipe the list. Decoding the newer fields with `decodeIfPresent` (and
        // falling back to their defaults) is what actually makes old items decode
        // cleanly with no migration. `id`/`q`/`a`/`t` are required — every saved
        // item has always had them.
        enum CodingKeys: String, CodingKey {
            case id, q, a, t, turns, title, source, origin, link, agentOutcome, agentResume,
                 agentInterrupted, failed
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id     = try c.decode(UUID.self,   forKey: .id)
            q      = try c.decode(String.self, forKey: .q)
            a      = try c.decode(String.self, forKey: .a)
            t      = try c.decode(Date.self,   forKey: .t)
            turns  = try c.decodeIfPresent([Turn].self,  forKey: .turns)
            title  = try c.decodeIfPresent(String.self,  forKey: .title)
            source = try c.decodeIfPresent(Source.self,  forKey: .source) ?? .ask
            origin = try c.decodeIfPresent(Origin.self, forKey: .origin)
            link   = try c.decodeIfPresent(String.self,  forKey: .link)
            agentOutcome = try c.decodeIfPresent(String.self, forKey: .agentOutcome)
            agentResume = try c.decodeIfPresent(AgentResume.self, forKey: .agentResume)
            // Legacy rows (saved before this key) only carried `agentResume` when
            // the run WAS interrupted — so a missing key + a resume handle means
            // interrupted, not false, or old interrupted rows would lose their
            // resume button.
            agentInterrupted = try c.decodeIfPresent(Bool.self, forKey: .agentInterrupted)
                ?? (agentResume != nil)
            // Rows saved before failed rows were kept at all are, by definition,
            // rows that succeeded.
            failed = try c.decodeIfPresent(Bool.self, forKey: .failed) ?? false
        }

        /// Content search for the `search_history` tool — every place the user's own
        /// words could be, not just the row's title. The Recent list's filter
        /// matches `displayTitle` alone (that's the right behavior for skimming a
        /// list of rows), but a model asked "did I ever note anything about the
        /// landlord" has to find the word wherever it was written: in the generated
        /// title, in the captured line, in the answer, or in any turn of a longer
        /// thread.
        func matchesArchiveSearch(_ needle: String) -> Bool {
            if let title, title.localizedCaseInsensitiveContains(needle) { return true }
            if q.localizedCaseInsensitiveContains(needle) { return true }
            if a.localizedCaseInsensitiveContains(needle) { return true }
            return (turns ?? []).contains { $0.text.localizedCaseInsensitiveContains(needle) }
        }

        /// Squeeze a stored field onto ONE line: the digest is line-per-row, so a
        /// multi-line note ("会议结论\n下周二出稿") would otherwise split into what
        /// reads as two separate entries.
        private static func flattened(_ s: String) -> String {
            s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        /// Flatten to the one line the model reads (see `HistoryDigestRow`).
        ///
        /// The headline is free summarization the app already paid for: an Ask row's
        /// `title` was generated from the whole exchange, and a capture's `q` IS the
        /// user's line — so a day of activity reads as a day of activity without any
        /// transcript crossing the wire. `body` carries the literal question behind
        /// an Ask only when the title is a summary that doesn't already say it.
        var digestRow: HistoryDigestRow {
            var kind = source.rawValue
            // A failed run must not read like an ordinary finished task.
            if source == .agent, let outcome = agentOutcome, !outcome.isEmpty {
                kind += "·\(outcome)"
            }
            let headline = String(Self.flattened(displayTitle)
                .prefix(HistoryDigestRow.headlineCap))
            var body: String? = nil
            if source.isThread {
                let asked = Self.flattened(q)
                // Only when it adds something: an untitled row's headline already IS
                // the question, and repeating it would just spend budget.
                if !asked.isEmpty, asked != headline {
                    body = String(asked.prefix(HistoryDigestRow.bodyCap))
                }
            }
            return HistoryDigestRow(date: t, kind: kind, headline: headline, body: body)
        }
    }

    // Open / closed drives the grow-out-of-the-notch animation.
    @Published var open = false {
        didSet {
            if open {
                // A bucket that came back armed from the last launch still has to be
                // re-seeded (folder, live engine) — see `rearmPersistedAgentBucket`.
                // Done on open, not at init: the probes it needs shell out, and by
                // the first open the launch `warmUp()` has warmed their caches.
                rearmPersistedAgentBucket()
            }
        }
    }
    /// The brief "content dissolving" beat between a close request and the shell
    /// actually retracting. Closing used to be one snap — `open` flipped false and
    /// the glass body and its content collapsed on the same transaction, reading as
    /// a clamp. Now `beginClose()` raises this first: the content fades out while the
    /// shell holds its expanded size, and only once it's gone does `fullClose()` drop
    /// `open` and let the shell retract — so closing mirrors the staged feel of the
    /// open. `open` stays true through this beat, so window key-handoff and the
    /// expanded geometry hold until the real close lands.
    @Published var closing = false
    /// Which screen's island is unfurled. With one panel per display sharing this
    /// model, `open` alone would unfurl every screen at once — views gate on
    /// `isOpen(on:)` so only the hovered screen expands while the others keep
    /// their resting notch. `nil` while closed (and in single-screen debug paths,
    /// where it means "any screen").
    @Published var activeDisplay: CGDirectDisplayID? = nil
    @Published var mode: Mode = .idle

    /// The user pinned the current answer's card (the pin button in `resultHeader`).
    /// While set, `collapseOnLeave` bails: the pointer leaving no longer folds the
    /// panel, so the answer stays parked open for reading. Scoped to the answer on
    /// screen — cleared whenever the page changes underneath it (`newChat`, a fresh
    /// `submit`, a `fullClose`), so a pin never leaks onto the next conversation.
    @Published var isAnswerPinned = false

    /// Whether the pointer is currently over the open island. Maintained by the
    /// island's own `.onHover` (and seeded from the real pointer position on the
    /// closed→open edge, for a keyboard summon that lands under a resting cursor).
    /// The result header's trailing chips read it so they can rest INVISIBLE and
    /// fade in only under the cursor — at a glance the answer is all there is.
    @Published var pointerInside = false

    /// Mirrors `HoverSensitivity.current` so the island's SwiftUI tree re-renders
    /// when the level changes. The persisted value stays the source of truth (the
    /// hover gate reads it live); this is the observable shadow, and every writer
    /// goes through `applyHoverSensitivity`.
    @Published private(set) var hoverSensitivity: HoverSensitivity = .current

    /// The `.click` level's hover acknowledgement: WHICH screen's resting notch is
    /// flexed a few points out under the pointer, saying "yes, I'm here — click
    /// me". It is a *gesture*, not an open — the panel stays folded until the
    /// click lands. Per display, because every screen hosts its own island off
    /// this one model and only the one under the pointer should stir. Raised by
    /// `hoverEntered`, dropped by the peek watch (and by any open, so the flex
    /// never survives into the unfurl).
    @Published private(set) var hoverPeek: CGDirectDisplayID? = nil

    /// Whether `display`'s resting notch is wearing the click level's flex.
    func isPeeking(on display: CGDirectDisplayID?) -> Bool {
        guard let display, let peek = hoverPeek else { return false }
        return peek == display
    }

    /// This thread was opened by a user-defined prompt shortcut (`runPromptShortcut`)
    /// rather than by typing into the panel. Such a run is a one-shot — the user
    /// hit a hotkey on a selection and wants to read the answer — so the result
    /// view collapses its follow-up input into a small floating button that costs
    /// no height, and only expands into the full field when tapped. Cleared
    /// wherever the page changes underneath it (`newChat`, `fullClose`, a fresh
    /// typed `submit`), so it never leaks onto the next conversation.
    @Published var fromPromptShortcut = false

    /// Selection captured by an empty prompt shortcut whose destination is the
    /// notch. It stays invisible model context while the ordinary idle field asks
    /// for a one-off instruction; `submitCurrent` consumes and clears it.
    @Published private(set) var promptShortcutContext: String?
    var usingPromptShortcutContext: Bool { promptShortcutContext != nil }

    /// What the user had highlighted in the app they came from, read at the open
    /// edge (`SelectedTextCapture.ambient`) and carried into the idle prompt as
    /// context for the next ask. The whole point is that "translate this" works
    /// without copying anything first — the thing on screen *is* "this".
    ///
    /// It is never silent: the badge above the input says it is being used and
    /// hands back an × to drop it (`dropSelectionContext`), because a selection
    /// left over in some window the user isn't thinking about must never quietly
    /// steer an answer.
    @Published private(set) var selectionContext: String?
    /// The app that selection came from ("Safari"), for the badge. `nil` when the
    /// name is unavailable — the badge then just says a selection is in use.
    @Published private(set) var selectionContextSource: String?
    /// The last selection dropped with the badge's ×. Kept across closes so the
    /// same still-highlighted paragraph doesn't march back in on the next summon:
    /// the × means "not this text", and it holds until the user highlights
    /// something else.
    private var dismissedSelection: String?

    /// Settings → General, "Use selected text": whether opening the panel reads
    /// what the user had highlighted outside. On by default — it is the whole
    /// point of a notch you talk to ("translate this" with nothing copied) — but
    /// people who live with a permanent selection in an editor want the prompt to
    /// stay blank, so it is one switch away. Off also stops the accessibility read
    /// happening at all, not just the badge from drawing.
    @Published var selectionContextEnabled: Bool =
        UserDefaults.standard.object(forKey: NotchModel.selectionContextKey) as? Bool ?? true
    {
        didSet {
            UserDefaults.standard.set(selectionContextEnabled,
                                      forKey: NotchModel.selectionContextKey)
            if !selectionContextEnabled { clearSelectionContext() }
        }
    }
    private static let selectionContextKey = "selectionContextEnabled"

    /// The one-time "you can switch this off in Settings" note, shown after the
    /// user drops a carried selection for the FIRST time — see
    /// `dropSelectionContext`. Retires itself after a few seconds.
    @Published private(set) var selectionContextHintShown = false
    private var selectionContextHintTask: Task<Void, Never>?
    private static let selectionContextHintSeenKey = "selectionContextHintSeen"

    /// The model picker popover (anchored to the model chip in settings) is open.
    /// While set, `collapseOnLeave` bails exactly as it does for a pinned answer: the
    /// popover is a separate window outside the island's tracking area, so moving the
    /// pointer into it reads as "left the island" and would otherwise fold the panel
    /// out from under the open picker. Set true while the popover shows, false on close.
    @Published var isModelPickerOpen = false

    /// The cross-provider model-config card, summoned straight from the panel instead of
    /// from inside Settings. Opened by the settings chip, and by ⌘⇧I only as the fallback
    /// for a machine with no agent CLI installed (there, the agent picker has nothing to
    /// show). `NotchBody` hangs the popover off the panel body.
    @Published var showModelPicker = false

    /// What ⌘⇧I summons: the agent's model + reasoning-effort quick picker — the two dials
    /// turned between runs — regardless of mode or whether the Agent bucket is armed.
    /// `NotchBody` hangs the popover off the panel body; `ContentView` owns the chord.
    @Published var showAgentPicker = false

    /// The Ask model chip's quick menu — the agent quick picker's card on the chat
    /// side, listing the five most recently used models (`AskModelMRU`). `NotchBody`
    /// hangs the popover off the panel body like the other two pickers.
    @Published var showAskModelPicker = false

    /// The agent compose's folder chip menu — the recently worked-in projects
    /// (`AgentFolderMRU`), with the file panel as its tail row. Hung off the chip
    /// itself, exactly like the two model menus.
    @Published var showAgentFolderPicker = false

    /// A settled result's metadata card: the Chat footer's ⓘ model menu or the
    /// Agent follow-up row's command menu. Both live in a separate child window,
    /// so leaving the island to reach one must not fold the result page out from
    /// under the pointer.
    @Published var isResultMetadataMenuOpen = false

    /// The agent task whose detail page is open — the full-page work trail a
    /// status row's tap opens while its run is live (a settled row opens its
    /// Recent record instead, which shows the same trail). `nil` = no detail
    /// page; also cleared by `newChat` so Back/⌘N leaves it like any thread.
    @Published var agentDetailTaskID: UUID? = nil

    /// A model picked from the ⌘⇧I picker whose provider has no key yet. The picker
    /// can't take a key itself, so it hands the pick to Settings: the panel opens on the
    /// key section for that provider, and the model is selected the moment a key lands
    /// (the same "configure only when the pick needs it" flow the settings picker runs).
    /// `InlineSettingsView` consumes and clears it on appear.
    @Published var pendingModelSetup: PendingModelSetup?

    struct PendingModelSetup: Equatable {
        let provider: Provider
        let id: String
    }

    /// Agent compose state (XII: agent-to-Codex): ON while the idle input
    /// is composing an agent task — Enter starts a `AgentTaskManager` run
    /// instead of asking the chat model. Entered by the bucket pill's Agent half
    /// (or Shift-Tab), or by dropping a project folder on the island; left by
    /// Shift-Tab / Tab or the pill's Ask half — NOT by submitting.
    /// A bucket you *live in*, not one you pass through: persisted, so a submit,
    /// a close, and a relaunch all land you back where you were, armed on the
    /// same project and engine.
    @Published var agentComposeActive =
        UserDefaults.standard.bool(forKey: "agentBucketArmed") {
        didSet {
            UserDefaults.standard.set(agentComposeActive, forKey: "agentBucketArmed")
            guard agentComposeActive != oldValue else { return }
            // Chat and Agent own separate Recent views: switching buckets changes
            // which rows exist without touching Chat's source filter itself.
            // Invalidate the derived slice and release any index into the old one.
            agentFilteredHistoryCache = nil
            highlightedHistoryIndex = nil
            historyRecallIndex = nil
        }
    }

    /// The folder the composed task will run in — seeded from the remembered
    /// last project on entry, replaced via the folder chip or a drop. nil until
    /// the user has ever picked one; Enter then opens the picker, which doubles
    /// as the first run's confirmation gate.
    @Published var agentComposeFolder: URL? = nil

    /// Every enabled skill Codex reports for the current agent folder. Loaded via
    /// app-server rather than a filesystem scan so plugins, disabled entries, and
    /// repo-scoped skills follow Codex's own rules exactly.
    @Published private(set) var agentSkills: [CodexCLIService.Skill] = []
    private var agentSkillsTask: Task<Void, Never>?

    /// Which agent CLI the armed task will run on (Codex / Claude Code). Seeded
    /// from the remembered choice (raw read — no process probe at init) and
    /// persisted on change, so the armed mode survives relaunches whole. Driven
    /// by the compose row's model chip — picking a model picks its engine.
    @Published var agentArmedEngine: AgentEngine =
        AgentEngine.storedPreference ?? .codex {
        didSet { AgentEngine.rememberPreference(agentArmedEngine) }
    }

    /// The armed run's explicit model pick — a flag value from the armed
    /// engine's `modelChoices`, nil = that engine's own CLI-config default.
    /// Persisted alongside the engine so the whole compose survives relaunches.
    @Published var agentModelID: String? =
        UserDefaults.standard.string(forKey: "agentModel") {
        didSet { UserDefaults.standard.set(agentModelID, forKey: "agentModel") }
    }

    /// The armed run's reasoning effort (compose row's third chip); nil leaves
    /// both CLIs on their own defaults.
    @Published var agentEffort: AgentEffort? =
        UserDefaults.standard.string(forKey: "agentEffort").flatMap(AgentEffort.init) {
        didSet { UserDefaults.standard.set(agentEffort?.rawValue, forKey: "agentEffort") }
    }

    /// The images ⌘V-pasted into the agent compose — screenshots of the bug,
    /// a design mock, a before/after pair. Each ⌘V appends, so a task can carry
    /// several. They ride the run to the agent alongside the task text (codex
    /// attaches them with one `exec -i` each; claude gets them as vision blocks
    /// via `--input-format stream-json`). Session-only, cleared when the compose
    /// exits — an attachment belongs to the task being written, not the mode.
    @Published var agentComposeImages: [NSImage] = []

    /// Images explicitly ⌘V-pasted into an ordinary Ask. Kept separate from the
    /// system clipboard: copying an image never changes the UI or silently sends
    /// pixels. Each paste appends, and submit clears exactly this round's set.
    @Published var askComposeImages: [NSImage] = []

    /// How many images one agent round may carry. Both CLIs take far more —
    /// codex's `-i` is variadic (OpenAI accepts 500 images / 50MB per request)
    /// and claude's stream-json takes 100 image blocks — but Anthropic imposes a
    /// stricter per-image dimension cap on requests holding MORE than 20 images,
    /// so 20 is the line where neither engine needs special handling. (Screenshots
    /// encode at a 1568px long side anyway, well inside even that stricter cap.)
    static let composeImageLimit = 20
    static let agentImageLimit = composeImageLimit

    /// The last project chosen for an agent Codex task. Kept separately so the
    /// folder picker can reopen there even after the user explicitly exits agent
    /// mode.
    private static let agentFolderKey = "agentLastFolder"

    private static func savedAgentFolder(forKey key: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func saveAgentFolder(_ folder: URL?, forKey key: String) {
        if let folder {
            UserDefaults.standard.set(folder.path, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private var lastAgentFolder: URL? {
        get {
            Self.savedAgentFolder(forKey: Self.agentFolderKey)
        }
        set {
            Self.saveAgentFolder(newValue, forKey: Self.agentFolderKey)
        }
    }

    /// The NSOpenPanel for picking a agent folder is up. Gates `collapseOnLeave`
    /// exactly like `isModelPickerOpen`: the open panel is a separate window, so
    /// the pointer moving into it must not fold the island behind it.
    @Published var isFolderPickerOpen = false

    /// True while the AI is in its pre-stream *thinking* phase — from the moment a
    /// question is submitted until the first answer token lands (or the round ends).
    /// Drives the 3 thinking dots shown beside the physical notch. Deliberately
    /// SEPARATE from `mode`/`open`: if the cursor leaves mid-think the panel folds
    /// back to the resting notch, but the round keeps running detached — the dots
    /// must stay lit beside the collapsed notch until that round produces text or
    /// finishes, so this can't be gated on the panel being open.
    @Published var thinking = false
    /// The answer turn whose pre-stream wait `thinking` is currently tracking. Lets
    /// the first-token / finish handlers clear `thinking` only for the round that
    /// actually owns it, so a superseded round can't switch the dots off under a
    /// newer one.
    private var thinkingAnswerID: UUID? = nil

    /// How many Ask rounds are currently in flight — on screen or detached. A
    /// fully closed panel with a non-zero count means an answer is still
    /// streaming in the background, and the resting notch flexes into its busy
    /// ears — verb left, elapsed clock right (see `NotchIsland`) — so the work
    /// stays visible in the meanwhile; the walk-away notification and the Recent
    /// row cover the *result*. Unlike `thinking` (pre-stream wait only), this
    /// spans the whole round: incremented when a round's task starts, decremented
    /// on every exit path (clean finish, mid-stream error, supersede-cancel), so
    /// the indicator can never stick on after the last round settles.
    @Published private(set) var roundsInFlight = 0

    /// When the oldest still-running Ask round started — the resting notch's
    /// busy ear shows this elapsed clock (mirroring the agent card's), so
    /// "working" reads as *for how long*, not just an abstract wave.
    var busySince: Date? { inFlightRounds.first?.startedAt }

    /// The newest tool-activity line from ANY in-flight round, on screen or
    /// detached ("Searching the web…", "Reading github.com…"). Unlike
    /// `thinkingActivity` (on-screen rounds only), this one exists for the
    /// collapsed notch: the busy left ear shows whatever the AI is actually
    /// doing right now, falling back to a plain verb only between tools.
    /// Last-writer-wins across concurrent rounds; cleared when the last round
    /// settles (see the round task's defer).
    @Published private(set) var backgroundActivity: String? = nil

    /// True once an in-flight round has started streaming answer text — the
    /// collapsed busy ear's "Writing" phase. The tool-activity label is nil
    /// during the final compose/stream, and without this the ear would fall
    /// back to "Thinking" for the entire write. One publish per round (guarded
    /// in `appendChunk`), never per chunk; reset when a fresh round starts from
    /// idle and when the last round settles.
    @Published private(set) var backgroundWriting = false

    /// One still-streaming round's live mirror. A detached round streams into a
    /// task-local snapshot the screen can't see — this mirror is the model's
    /// copy of that snapshot, refreshed on every chunk/source, which is what
    /// lets a hover during the busy extension (or a tap on the round's pending
    /// Recent row) put the answer back on screen mid-write instead of landing
    /// on the idle prompt (see `attachInFlightRound`).
    private struct InFlightRound {
        let answerID: UUID
        let threadID: UUID
        var thread: [Turn]
        /// Stamped at append — feeds the resting notch's elapsed clock.
        let startedAt = Date()
    }

    /// Live mirrors of every round currently in flight, oldest first — appended
    /// when a round's task starts and removed on the same defer that settles
    /// `roundsInFlight`, so the two can never disagree.
    private var inFlightRounds: [InFlightRound] = []

    /// The cursor's velocity at the instant the island opened — SwiftUI
    /// orientation (+x right, +y down), points/second. Hover-opens pass the
    /// tracker's reading; every other path (⌘, / debug launches) leaves it
    /// zero, which renders as the standard calm unfurl. `NotchIsland` consumes
    /// it to seed the entry kick and ease the open spring — set *before* `open`
    /// flips so the view computes its animation from a fresh reading.
    /// Deliberately not `@Published`: it is only ever written immediately before
    /// `open` flips (which already invalidates the tree), so publishing it would
    /// just add a second whole-tree invalidation on the open edge.
    var entryVelocity: CGVector = .zero

    @Published var text = "" {      // current input (idle prompt or follow-up)
        didSet {
            let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // Deleting the hand-typed sigil retires its little explanation beside
            // the caret — but NOT the mode it pinned. The pin is sticky now (see
            // `manualPanelOverride`); switching back is Tab's job, or the pill's.
            if let trigger = typedNoteTriggerPrefix,
               !text.hasPrefix(trigger) {
                typedNoteTriggerPrefix = nil
                typedNoteModeActive = false
            }
            // A `/`-pinned prompt shortcut is still scoped to its line — it runs
            // its input through an AI instruction, so it parks the pinned mode
            // while it's up. Letting it go hands that mode back.
            if promptShortcutMode != nil,
               empty {
                promptShortcutMode = nil
                manualPanelOverride = Self.storedSubmitMode
            }
            // The `/` menu's highlight is scoped to the menu being open: every
            // edit that shuts it (a space, a submit, a delete-all) parks the
            // highlight back on the top row, and every edit that *narrows* it
            // clamps the highlight inside the shorter list — so the keyboard can
            // never sit on a row that isn't there.
            if !slashMenuOpen {
                slashHighlight = 0
            } else if slashHighlight >= slashMatches.count {
                slashHighlight = max(slashMatches.count - 1, 0)
            }
            if text == "/" { refreshAgentSkills(forceReload: true) }
            // Any real edit ends an ↑/↓ recall session, so the next ↑ starts fresh
            // from the newest item. `isRecallingText` shields the recall's own
            // fill from tripping this (it writes `text` too).
            if !isRecallingText { historyRecallIndex = nil }
            // Text arriving no longer folds the recent list: the Recent chevron
            // stays on the bucket row while you type (see `NotchBody.bucketRow` /
            // `promptHidesRecent`), so the list is that control's state alone —
            // closing it out from under a still-lit chevron was the incoherent half.
            //
            // The keyboard highlight DOES go, every keystroke. With text in the box
            // the arrows belong to the caret (`PromptField` routes ↑/↓ to the field
            // once it isn't empty), so a highlight left behind would be un-walkable
            // — and a stale one must never steal Enter from the visible text.
            // (`historyConfirmHighlighted` also guards on `!hasText` as a backstop.)
            if hasText, highlightedHistoryIndex != nil {
                highlightedHistoryIndex = nil
            }
            // Feed the "actively typing" signal that holds off hover-leave folding
            // (the one exception to leave-collapses). Empty writes don't count —
            // submit/clear set "" programmatically and mustn't read as typing.
            if !isRecallingText, !text.isEmpty { noteUserTyping() }
            scheduleDueDetection()
        }
    }

    /// An unsent idle draft parked at the last close so re-opening the notch can
    /// hand it back instead of dropping what the user was mid-way through typing.
    /// `fullClose` stashes `text` here (only when it's a non-empty idle draft —
    /// never a submitted-then-cleared line), and the closed→open edge in
    /// `openPanel` restores it into a fresh idle prompt. Explicit "start fresh"
    /// paths (`newChat`) never fill this, so backing out still lands on a blank
    /// prompt. Consumed on restore so it hands back exactly once.
    private var savedIdleDraft: String = ""

    // MARK: - Parked session (close = park, reopen soon = restore)

    /// The page the user was on when the panel last folded, parked so a return
    /// within `parkedSessionTTL` lands exactly where they left — the thread they
    /// were reading, the follow-up they'd half-typed, the settings page mid-key.
    /// The interaction rule this implements: **closing gestures navigate, they
    /// never destroy** — only ← / ⌘N (`newChat`) and time throw a session away.
    /// After the TTL the context has likely moved on, so a late reopen falls back
    /// to the fresh idle prompt (the conversation stays one tap away in Recent).
    private struct ParkedSession {
        var mode: Mode
        var turns: [Turn]
        var text: String
        var threadHistoryID: UUID
        var showSettings: Bool
        var showWhatsNew: Bool
        var showHistory: Bool
        var closedAt: Date
        /// The thread's measured intrinsic height at close time — see
        /// `lastMeasuredAnswerHeight`. Restored before the reopened panel mounts
        /// so the result view lands in the right (short vs clipped) layout on
        /// its very first frame.
        var measuredAnswerHeight: CGFloat
        /// Whether the thread was opened by a prompt shortcut — parked so a
        /// close+reopen lands back on the FOLDED follow-up (a header chip) instead
        /// of silently promoting the thread to a standing composer.
        var fromPromptShortcut: Bool
    }

    private var parkedSession: ParkedSession? = nil

    /// The answer thread's last measured intrinsic height, mirrored here live by
    /// NotchBody's `AnswerHeightKey` probe. A plain var, deliberately not
    /// @Published — it's layout telemetry for the next mount, never something a
    /// mounted view re-reads.
    ///
    /// Why it exists: NotchBody unmounts on every close (`if isOpen` in
    /// ContentView), which resets its measurement @State to 0 — so a hover-reopen
    /// into a parked answer always mounted in the WRONG layout first (unclipped,
    /// the whole thread at full intrinsic height) and flipped to the clipped
    /// scroller one preference pass later, mid-open-spring. That structural swap
    /// (new ScrollView, header → floating overlay, follow-up → float, scroll
    /// snapped to bottom) stacked onto the unfurl is exactly what made reopening
    /// an answer visibly rougher than opening the idle prompt. Parking the
    /// measurement with the session and seeding the next mount from it means the
    /// first frame is already the final layout, and the open rides one clean
    /// spring — same as idle. Zeroed on every close after parking, so only a
    /// genuine parked-session restore ever hands a seed to a fresh mount.
    var lastMeasuredAnswerHeight: CGFloat = 0

    /// How long a parked session stays restorable. "A few minutes" — long enough
    /// to answer a Slack message and come back, short enough that a reopen after
    /// real absence reads as a fresh start, not a haunting.
    static let parkedSessionTTL: TimeInterval = 300

    /// When the user last actually typed (prompt, follow-up, ⌘F filter, or a
    /// settings key field). This is the ONE exception to leave-collapses: while
    /// the keyboard is engaged, the pointer's position isn't an attention signal,
    /// so hover-leave defers folding until `typingGrace` after the last keystroke.
    private var lastEditAt: Date = .distantPast

    /// How long after the last keystroke the user still counts as "typing".
    static let typingGrace: TimeInterval = 3.0

    /// The armed "leave watch" — one small state machine covering every case
    /// where a fold is warranted but not NOW:
    ///   · the pointer left mid-typing → fold once the keystrokes stop;
    ///   · an exit event was spurious (pointer still on the island) → re-verify
    ///     after the animation settles;
    ///   · the island SHRANK away from a parked pointer (⌘N folding a tall
    ///     thread to the short idle prompt, a list collapsing…) → the user
    ///     didn't leave; fold only once the pointer genuinely moves off.
    /// It polls rather than waiting for events because AppKit's tracking state
    /// is desynced in exactly these situations — the event that would have
    /// told us may never come. Cancelled by every open path (a hover re-entry
    /// or keyboard summon supersedes any pending fold).
    private struct LeaveWatch {
        var display: CGDirectDisplayID?
        var sequenced: Bool
        /// Where the mouse was when the watch was armed. A boundary-shrink
        /// leave folds only after real displacement from here.
        var armedMouse: CGPoint
        /// True when the pointer genuinely crossed out (a moving-cursor exit):
        /// fold as soon as the typing grace clears, no displacement required.
        var movedOut: Bool
    }
    private var leaveWatch: LeaveWatch?
    private var leaveRecheckTask: Task<Void, Never>?

    private func cancelLeaveWatch() {
        leaveRecheckTask?.cancel()
        leaveRecheckTask = nil
        leaveWatch = nil
    }

    /// (Re-)arm the watch and schedule its next re-check.
    private func armLeaveWatch(_ watch: LeaveWatch, after delay: TimeInterval) {
        leaveWatch = watch
        leaveRecheckTask?.cancel()
        leaveRecheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000) + 50_000_000)
            guard !Task.isCancelled, let self else { return }
            self.recheckLeaveWatch()
        }
    }

    /// Mark the user as actively typing. Called from `text`/`historySearchQuery`
    /// didSets and from view-local fields (settings API keys) via their onChange.
    func noteUserTyping() {
        lastEditAt = Date()
    }

    // MARK: - Hover ground truth

    /// AppKit synthesizes tracking-area enter/exit events for a STATIONARY
    /// pointer whenever the tracked view's geometry changes underneath it — and
    /// the island's geometry animates on every open/close. Trusting those raw
    /// events produced a feedback loop: a spurious exit during the open spring
    /// folds the panel, the collapse sweeps the boundary back under the pointer
    /// and fires an enter, which re-opens it — the island visibly flaps. So
    /// hover events are treated as *hints* and verified against the pointer's
    /// real position before acting: `panelScreenFrames` (registered by
    /// AppDelegate, screen coords, bottom-left origin) plus `islandFrames`
    /// (published by the view, SwiftUI window space, top-left origin) locate
    /// the island on screen; `NSEvent.mouseLocation` is the ground truth.
    private var panelScreenFrames: [CGDirectDisplayID: CGRect] = [:]
    private var islandFrames: [CGDirectDisplayID: CGRect] = [:]
    /// Per-display resting-notch height (the screen's safe-area inset, or the
    /// menu-bar height on notch-less screens) — registered alongside the panel
    /// frame so the resting notch rect can be computed without live layout.
    private var restHeights: [CGDirectDisplayID: CGFloat] = [:]
    /// Per-display width of the REAL hardware notch (measured from the screen's
    /// auxiliary top areas), nil on screens that have none. The hover judgement
    /// is made against this, never against `Tokens.notchWidth`: the drawn island
    /// is deliberately a few points wider than the cutout so its black always
    /// covers the bezel, and those few points hang over live menu bar — hovering
    /// them must not open the panel.
    private var hardwareNotchWidths: [CGDirectDisplayID: CGFloat] = [:]

    func registerPanelFrame(_ frame: CGRect, restHeight: CGFloat,
                            hardwareNotchWidth: CGFloat?,
                            for display: CGDirectDisplayID) {
        panelScreenFrames[display] = frame
        restHeights[display] = restHeight
        hardwareNotchWidths[display] = hardwareNotchWidth
    }

    /// Deliberately a plain var write — this fires per frame during the island's
    /// springs, and publishing it would invalidate the whole tree each frame.
    func registerIslandFrame(_ frame: CGRect, for display: CGDirectDisplayID?) {
        guard let display else { return }
        islandFrames[display] = frame
    }

    /// The resting notch's current ear widths (busy verb/clock, finished badge,
    /// copy-sense hint), registered by `NotchIsland` so the resting-notch hover
    /// rect can include them without the model re-deriving measured text
    /// widths. Global, not per display: the collapsed ears render identically
    /// on every screen. Plain vars for the same reason as `islandFrames`.
    private var restingEarLeft: CGFloat = 0
    private var restingEarRight: CGFloat = 0

    func registerRestingEars(left: CGFloat, right: CGFloat) {
        restingEarLeft = left
        restingEarRight = right
    }

    /// Whether the pointer is really over `display`'s island right now.
    /// `slop` pads the test outward, absorbing measurement/animation slack.
    /// Returns nil when the geometry isn't known (yet) — callers then fall back
    /// to trusting the event, which is the pre-verification behavior.
    private func pointerInsideIsland(on display: CGDirectDisplayID?, slop: CGFloat) -> Bool? {
        guard let display,
              let panel = panelScreenFrames[display],
              let island = islandFrames[display] else { return nil }
        // SwiftUI global space (top-left origin, relative to the borderless
        // canvas window) → screen space (bottom-left origin).
        let screenIsland = CGRect(x: panel.minX + island.minX,
                                  y: panel.maxY - island.maxY,
                                  width: island.width, height: island.height)
        return screenIsland.insetBy(dx: -slop, dy: -slop).contains(NSEvent.mouseLocation)
    }

    /// Where the RESTING notch sits on `display`, in screen coordinates —
    /// computed from the registered canvas frame and rest height, NOT from the
    /// live layout, so it holds still while the island animates. This is the
    /// reference for enter events on a closed panel: during the collapse the
    /// live frame is mid-sweep and would validate exactly the synthetic enters
    /// the sweep generates.
    ///
    /// The width is the MEASURED hardware notch (`hardwareNotchWidths`), falling
    /// back to the drawn constant only on screens with no cutout to measure. The
    /// drawn island is 192pt against a ~185pt physical notch, so trusting the
    /// design constant here made ~3.5pt of live menu bar on each shoulder open
    /// the panel on contact.
    private func pointerInsideRestingNotch(on display: CGDirectDisplayID?, slop: CGFloat) -> Bool? {
        guard let display,
              let panel = panelScreenFrames[display],
              let restHeight = restHeights[display] else { return nil }
        let width = hardwareNotchWidths[display] ?? Tokens.notchWidth
        var rect = CGRect(x: panel.midX - width / 2,
                          y: panel.maxY - restHeight,
                          width: width,
                          height: restHeight)
        // While the resting notch is flexed into its ears — background work's
        // verb/clock, the finished-count badge, or the copy-sense hint — those
        // strips are hoverable too. Widths come from the view's registration
        // (measured content); both are zero on a bare notch.
        if !open {
            rect.origin.x -= restingEarLeft
            rect.size.width += restingEarLeft + restingEarRight
        }
        return rect.insetBy(dx: -slop, dy: -slop).contains(NSEvent.mouseLocation)
    }

    /// The hover-enter entry point (the view calls this, not `openPanel`,
    /// so keyboard summons and notification taps stay ungated): drop enters
    /// whose pointer isn't actually over the island — synthetic events fired
    /// by the animating boundary sweeping under a parked pointer.
    ///   · Panel closed → test against the STATIC resting-notch rect (the live
    ///     frame is mid-collapse and would validate its own sweep artifacts).
    ///   · Panel open → test against the live island frame with generous slop
    ///     (an honest re-entry during the close dissolve must still cancel it).
    /// Unknown geometry (nil) falls back to trusting the event.
    ///
    /// On the closed→open edge two further gates apply, both aimed at the same
    /// complaint: reaching for a menu bar item near the notch kept unfurling the
    /// panel over it. See `cursorReallyEntered` and `isMenuBarSweep`.
    func hoverEntered(on display: CGDirectDisplayID?, velocity: CGVector) {
        if open {
            if pointerInsideIsland(on: display, slop: 16) == false { return }
            openPanel(on: display, velocity: velocity)
            return
        }
        if pointerInsideRestingNotch(on: display, slop: 0) == false { return }
        let sensitivity = HoverSensitivity.current
        // The pointer has to have DONE the entering. A stationary cursor can be
        // handed a mouseEntered by AppKit whenever the tracked geometry moves
        // under it — and the resting notch's geometry moves on its own: the busy
        // verb/clock and the copy-sense hint flex the ears out by tens of points,
        // straight over the menu bar. That is the island arriving at the cursor,
        // not the cursor arriving at the island, and it must not open anything.
        // (`collapseOnLeave` has carried the mirror of this test for exits all
        // along; this is the missing half.)
        guard MouseVelocityTracker.shared.cursorMoved(within: 0.2) else { return }
        // The click level answers a hover with a gesture instead of an unfurl:
        // one haptic tap and a few points of outward flex (see `hoverPeek`), so
        // the notch is visibly awake and reachable while the panel stays folded
        // until the click. Nothing below this line runs — the vector gate and the
        // entry watch both exist to decide *when* to open on hover, and here the
        // answer is never.
        if sensitivity.opensOnClickOnly {
            beginHoverPeek(on: display)
            return
        }
        // A fast, near-horizontal crossing is someone travelling ALONG the menu
        // bar to a target on the other side of the notch — the single biggest
        // source of accidental unfurls, since the resting hover strip spans the
        // menu bar's full height. Don't open on contact; hand it to the entry
        // watch, which opens the moment that pointer actually settles here and
        // stays quiet if it just keeps going.
        if Self.isMenuBarSweep(velocity, at: sensitivity) {
            armEntryWatch(display: display)
            return
        }
        openPanel(on: display, velocity: velocity)
    }

    /// Whether this entry reads as travel ALONG the menu bar rather than an
    /// arrival at the notch — the shape of approach each sensitivity refuses to
    /// take at face value. Both levels that test anything key on the same two
    /// facts, just at different tolerances: how flat the approach was, and how
    /// fast. A normal approach comes up from the content below, so its vertical
    /// component keeps it out of the test at every level.
    ///
    /// The cone comes from `HoverSensitivity.blockedAngle` (degrees off
    /// horizontal); only the speed floor is tuning that lives here. The levels
    /// nest on both axes —
    /// `.low` takes the wider cone AND the lower floor — so lowering the setting
    /// can only ever defer more entries, never fewer.
    private static func isMenuBarSweep(_ v: CGVector, at sensitivity: HoverSensitivity) -> Bool {
        let minSpeed: CGFloat
        switch sensitivity {
        case .instant:  return false
        case .balanced: minSpeed = 900
        case .low:      minSpeed = 150
        // Unreachable — `hoverEntered` peels `.click` off before the gate — but
        // "every approach is refused" is the honest answer for the level, and it
        // keeps the nesting property true if another caller ever appears.
        case .click:    return true
        }
        let speed = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        guard speed >= minSpeed else { return false }
        // |dx| : |dy| beyond 1/tan(angle) ⇒ the approach came in flatter than
        // the cone's edge.
        let flatness = CGFloat(1 / tan(sensitivity.blockedAngle * .pi / 180))
        return abs(v.dx) > flatness * abs(v.dy)
    }

    /// Poll interval of the entry watch. Short enough that a sweep which does
    /// stop on the notch still feels like it opened on contact.
    private static let entryWatchTick: TimeInterval = 0.1
    private var entryWatchTask: Task<Void, Never>?

    private func cancelEntryWatch() {
        entryWatchTask?.cancel()
        entryWatchTask = nil
    }

    /// Watch a sweep that's currently over the resting notch: open if it settles
    /// here, dissolve if it leaves. Deliberately a poll rather than a fixed
    /// delay — at sweep speed the pointer is still inside the notch 150ms later,
    /// so "wait, then check once" would open on exactly the pass-throughs this
    /// is meant to ignore.
    private func armEntryWatch(display: CGDirectDisplayID?) {
        entryWatchTask?.cancel()
        entryWatchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(NotchModel.entryWatchTick * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.recheckEntryWatch(display: display)
        }
    }

    private func recheckEntryWatch(display: CGDirectDisplayID?) {
        entryWatchTask = nil
        guard !open else { return }
        // Gone — it really was a pass-through. No enter event is needed to end
        // the watch: leaving the rect is the answer.
        guard pointerInsideRestingNotch(on: display, slop: 0) != false else { return }
        // Still travelling. Keep watching: the sweep may yet stop here.
        if MouseVelocityTracker.shared.cursorMoved(within: 0.12, threshold: 12) {
            armEntryWatch(display: display)
            return
        }
        // Settled on the notch — that's an arrival, whatever the entry looked
        // like. It opens on the calm unfurl, which is what a stopped cursor
        // should get anyway.
        openPanel(on: display, velocity: MouseVelocityTracker.shared.entryVelocity())
    }

    // MARK: - Click to open (the `.click` sensitivity)

    /// How far the resting notch swells out under the pointer at the click level,
    /// and — the same number, deliberately — how far past the resting rect the
    /// pointer may drift before the swell drops. Small on purpose: the shape has
    /// to read as the notch *noticing* you, not as it opening. Anything bigger and
    /// it starts promising an unfurl it isn't going to deliver. `NotchIsland`
    /// turns it into the scale it renders.
    static let hoverPeekOut: CGFloat = 5

    /// Poll interval of the peek watch — the entry watch's cadence, for the same
    /// reason: short enough that the flex drops the moment the pointer is gone.
    private static let hoverPeekTick: TimeInterval = 0.1
    private var hoverPeekTask: Task<Void, Never>?

    /// Raise the acknowledgement flex, tap once, and watch for the pointer to go.
    ///
    /// The leave is POLLED against the static resting rect rather than driven by
    /// the island's `.onHover`, because the flex moves the island's own tracking
    /// boundary — precisely the geometry that synthesizes bogus enter/exit events
    /// (see `pointerInsideIsland`). Judging both edges against a rect the flex
    /// can't move, and releasing at the flex's own reach rather than at the rect's
    /// edge, gives the peek plain hysteresis: it cannot flap, and drifting onto
    /// the flexed shoulder doesn't cancel the very gesture that put it there.
    private func beginHoverPeek(on display: CGDirectDisplayID?) {
        // Geometry has to be known — the watch below is the only thing that ever
        // lowers the flex, and it can't answer against a rect it can't compute.
        guard let display,
              pointerInsideRestingNotch(on: display, slop: 0) == true else { return }
        if hoverPeek != display {
            hoverPeek = display
            // The same tap the open would have given, at the moment the notch
            // acknowledges the pointer. It IS the feedback here: with no unfurl
            // to watch, the flex alone is a very quiet "seen you".
            Haptics.alignment()
        }
        armHoverPeekWatch(display: display)
    }

    private func armHoverPeekWatch(display: CGDirectDisplayID?) {
        hoverPeekTask?.cancel()
        hoverPeekTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(NotchModel.hoverPeekTick * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.hoverPeekTask = nil
            guard self.hoverPeek != nil, !self.open else { return self.endHoverPeek() }
            guard self.pointerInsideRestingNotch(on: display,
                                                 slop: NotchModel.hoverPeekOut) == true
            else { return self.endHoverPeek() }
            self.armHoverPeekWatch(display: display)
        }
    }

    /// Drop the flex and stop watching. Idempotent — the open path, the level
    /// change and the watch itself all call it.
    func endHoverPeek() {
        hoverPeekTask?.cancel()
        hoverPeekTask = nil
        if hoverPeek != nil { hoverPeek = nil }
    }

    /// A click landed on the resting notch. Only the click level mounts the
    /// target (see `NotchIsland`), so a click arriving here is unambiguously the
    /// open gesture.
    ///
    /// It opens at ZERO velocity, deliberately. The entry vector exists to let a
    /// hover-open inherit the momentum of the approach that caused it — but a
    /// click has no approach: the pointer has been parked on the notch since the
    /// peek went up. Feeding it `entryVelocity()` anyway read the last 120ms of
    /// samples, which by then is nothing but the hand's final settle and the
    /// click's own jitter — a couple of points, but over a few milliseconds, so
    /// hundreds of points per second. Every click therefore unfurled with a
    /// sideways lean and shove it had no reason to have. A parked pointer gets
    /// the calm, centered bloom.
    func notchClicked(on display: CGDirectDisplayID?) {
        // The press fires this; the rest of that drag's ticks find it already
        // open and turn back.
        guard !open else { return }
        // The flex is NOT retired here. Dropping it in this call would put it in
        // the same transaction as `open`, and the island's own peek animation
        // would then govern the unfurl instead of the open spring. The rendered
        // swell already collapses on the open (see `NotchIsland.peekScaleX`); the
        // watch clears the flag a tick later, when nothing on screen depends on it.
        openPanel(on: display)
    }

    /// The one writer of the hover level: persists it and updates the observable
    /// shadow the island renders from, so switching away from `.click` retires a
    /// standing flex instead of leaving it stuck out.
    func applyHoverSensitivity(_ newValue: HoverSensitivity) {
        HoverSensitivity.current = newValue
        hoverSensitivity = newValue
        if !newValue.opensOnClickOnly { endHoverPeek() }
    }

    // MARK: - Detached session windows (tear-off / 分裂)

    /// The live tear-off drag, while the ghost card is still attached to the
    /// island: set by the header drag gesture (NotchBody), rendered as the ghost
    /// card + goo bridge by NotchIsland's overlay.
    struct DetachDrag: Equatable {
        var session: DetachedSession
        var face: DetachedCardFace
        /// Raw pointer translation since the grab, unclamped.
        var translation: CGSize = .zero
    }
    @Published var detachDrag: DetachDrag? = nil

    /// True while a settled detached window is being dragged over a resting
    /// notch — the island swells slightly to say "drop it here to take it back".
    @Published var detachMergeHint = false

    /// How far the grab must travel (raw, unclamped) before the panel tears
    /// free into its window. Short — the tear should feel immediate, the
    /// pre-phase is just accident insurance.
    static let detachThreshold: CGFloat = 60

    /// The attached phase's rubber band: the pull follows the hand with rising
    /// resistance, saturating at `limit` — the glass giving, not the panel
    /// escaping. tanh keeps the response smooth from the very first point.
    static func detachRubberized(_ t: CGSize, limit: CGFloat = 96) -> CGSize {
        let mag = (t.width * t.width + t.height * t.height).squareRoot()
        guard mag > 0.5 else { return .zero }
        let eff = limit * CGFloat(tanh(Double(mag / limit)))
        return CGSize(width: t.width * eff / mag, height: t.height * eff / mag)
    }

    /// 0…1 how close this pull is to the tear threshold.
    static func detachProgress(_ t: CGSize) -> CGFloat {
        min((t.width * t.width + t.height * t.height).squareRoot() / detachThreshold, 1)
    }

    /// True from the instant a drag hands off to the window until the SwiftUI
    /// gesture ends — its remaining onChanged ticks must not re-arm a drag.
    private var detachHandedOff = false

    /// What a tear-off from the current page would carry: the open agent-run
    /// detail if one is up, the on-screen thread next, and — with neither — the
    /// idle prompt itself, which tears out as a standalone composer (`.compose`).
    /// Nil only on the pages that own the whole body (settings, What's New),
    /// which have nothing to carry.
    var detachableSession: DetachedSession? {
        guard open, !showSettings, !showWhatsNew else { return nil }
        if let id = agentDetailTaskID { return .agentTask(id: id) }
        if mode != .idle, !turns.isEmpty, !showHistory {
            return .thread(id: threadHistoryID)
        }
        if mode == .idle, turns.isEmpty { return .compose }
        return nil
    }

    /// The face the tear-off card wears — computed at grab time so ghost and
    /// window render the same card.
    private func detachedFace(for session: DetachedSession) -> DetachedCardFace {
        switch session {
        case .compose:
            // A composer carries no session — the draft in the box is the only
            // thing it has to show for a face (empty on a bare prompt).
            return DetachedCardFace(
                title: text.replacingOccurrences(of: "\n", with: " "),
                subtitle: L("input.placeholder"),
                isAgent: agentComposeActive,
                running: false)
        case .shortcutComposer:
            return DetachedCardFace(
                title: L("shortcuts.promptAction.window.context"),
                subtitle: "", isAgent: false, running: false)
        case .agentTask(let id):
            if let task = AgentTaskManager.shared.tasks.first(where: { $0.id == id }) {
                return DetachedCardFace(
                    title: task.prompt.replacingOccurrences(of: "\n", with: " "),
                    subtitle: "\(task.engine.displayName) · \(task.folder.lastPathComponent)",
                    isAgent: true,
                    running: task.isRunning)
            }
            return DetachedCardFace(title: L("detached.task.gone"), subtitle: "",
                                    isAgent: true, running: false)
        case .thread:
            let q = turns.first(where: { $0.role == "user" })?.text ?? ""
            let streaming = turns.contains { $0.streaming }
            return DetachedCardFace(
                title: q.replacingOccurrences(of: "\n", with: " "),
                subtitle: streaming ? L("busy.writing") : L("detached.thread.subtitle"),
                isAgent: threadIsAgentRun,
                running: streaming)
        }
    }

    /// Drag tick from the header gesture. Arms the ghost on the first tick,
    /// stretches the membrane while attached, and fires the tear-off once the
    /// pull crosses the threshold.
    func detachDragChanged(_ translation: CGSize) {
        guard !detachHandedOff else { return }
        if detachDrag == nil {
            guard let session = detachableSession else { return }
            detachDrag = DetachDrag(session: session, face: detachedFace(for: session))
        }
        detachDrag?.translation = translation
        if Self.detachProgress(translation) >= 1 { tearOff() }
    }

    /// Release under the threshold: the membrane pulls the card home.
    func detachDragEnded() {
        detachHandedOff = false
        guard detachDrag != nil else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.68)) {
            detachDrag = nil
        }
    }

    /// The split: the COMPLETE window is born in place over the panel — same
    /// position, full session content, no thumbnail stage — and rides the mouse
    /// from here (the window controller owns the rest of the drag). The panel
    /// lets the session go and folds underneath it.
    private func tearOff() {
        guard let drag = detachDrag else { return }
        detachHandedOff = true
        Haptics.alignment()
        let session = drag.session
        let face = drag.face
        if let spawnRect = detachWindowSpawnRect() {
            DetachedSessionWindowController.beginDragDetach(
                session: session, face: face, model: self, spawnRect: spawnRect)
        } else {
            // Geometry unknown (shouldn't happen mid-drag) — still honor the
            // intent: open the window in place without the ride.
            DetachedSessionWindowController.present(
                session: session, face: face, model: self, from: nil)
        }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { detachDrag = nil }
        completeDetach(of: session)
    }

    /// V0 (no drag): the header button — the same full window, fading in right
    /// over the panel.
    func openDetachedWindow() {
        guard let session = detachableSession else { return }
        let face = detachedFace(for: session)
        DetachedSessionWindowController.present(
            session: session, face: face, model: self,
            from: detachWindowSpawnRect())
        completeDetach(of: session)
    }

    /// The session left for a window: clear it off the panel (stream keeps
    /// going detached, exactly like `newChat`) and fold the shell.
    private func completeDetach(of session: DetachedSession) {
        switch session {
        case .compose:
            // The draft left with the window (the controller took a copy at
            // birth) — clear it here so the folding panel doesn't park it as an
            // idle draft and hand the same line back on the next open.
            text = ""
            showHistory = false
            highlightedHistoryIndex = nil
        case .shortcutComposer:
            // Compact shortcut composers are born outside the panel and never
            // pass through this detach path.
            break
        case .agentTask:
            agentDetailTaskID = nil
        case .thread:
            task = nil          // detach, never cancel — the round streams on
            parkedSession = nil // the window owns the page now; nothing to restore
            turns = []
            text = ""
            mode = .idle
            isAnswerPinned = false
            fromPromptShortcut = false
        }
        beginClose()
    }

    /// A detached window is closing / merging home: put the session back on the
    /// panel. A still-streaming thread reattaches its live round; a settled one
    /// reopens from Recent; `snapshot` is the window's last view of a thread
    /// that never reached history (edge insurance, not the normal path).
    func reattachDetachedSession(_ session: DetachedSession, snapshot: [Turn]?,
                                 draft: String = "",
                                 on display: CGDirectDisplayID?) {
        openPanel(on: display ?? activeDisplay)
        switch session {
        case .compose:
            // Nothing to restore but the line being written — hand the window's
            // draft back to the prompt (written after `openPanel`, which may
            // have restored a parked draft of its own).
            if !draft.isEmpty { text = draft }
        case .shortcutComposer:
            // This transient face has no panel representation to reattach to.
            break
        case .agentTask(let id):
            if AgentTaskManager.shared.tasks.contains(where: { $0.id == id }) {
                agentDetailTaskID = id
            }
        case .thread(let id):
            if let round = inFlightRounds.first(where: { $0.threadID == id }) {
                attachInFlightRound(round)
            } else if let item = history.first(where: { $0.id == id }),
                      !item.pending, item.source.isThread {
                openHistory(item)
            } else if let snapshot,
                      snapshot.contains(where: { $0.role == "assistant" && !$0.text.isEmpty }) {
                var cleaned = snapshot
                for i in cleaned.indices {
                    cleaned[i].streaming = false
                    cleaned[i].toolActivity = nil
                }
                turns = cleaned
                threadHistoryID = id
                mode = .result
            }
        }
    }

    /// Live mirrors for detached thread windows, keyed by thread id — fed at
    /// streaming cadence from `syncInFlight` and settled by `persistThread`,
    /// so only the window observing a thread re-renders on its chunks.
    private var detachedThreadStores: [UUID: DetachedThreadStore] = [:]

    func adoptDetachedThread(_ threadID: UUID) -> DetachedThreadStore {
        if let existing = detachedThreadStores[threadID] { return existing }
        let historyItem = history.first(where: { $0.id == threadID })
        let seed: [Turn]
        if let round = inFlightRounds.first(where: { $0.threadID == threadID }) {
            seed = round.thread
        } else if threadHistoryID == threadID, !turns.isEmpty {
            seed = turns
        } else {
            seed = historyItem?.conversation ?? []
        }
        let isAgent = historyItem?.source == .agent
        let supportsImages: Bool
        if isAgent,
           let rawEngine = historyItem?.agentResume?.engine,
           let engine = AgentEngine(rawValue: rawEngine) {
            supportsImages = engine.supportsImageInput
        } else {
            supportsImages = activeModelSupportsVision
        }
        let store = DetachedThreadStore(
            threadID: threadID,
            turns: seed,
            agentFolderPath: isAgent ? historyItem?.link : nil,
            completedAt: isAgent ? historyItem?.t : nil,
            followUpSupportsImages: supportsImages)
        detachedThreadStores[threadID] = store
        return store
    }

    func releaseDetachedThread(_ threadID: UUID) {
        detachedThreadStores[threadID] = nil
    }

    /// A follow-up typed in a detached thread window. The round runs through
    /// the exact panel pipeline (`submit`) so tools, persistence, and Recent
    /// behave identically — borrowed headless: the thread is loaded into the
    /// panel state just long enough for `submit()` to arm the round, then
    /// everything is put back and the new round is left detached ("detach,
    /// never cancel" — the same hand-off as the tear-off itself). The round's
    /// snapshots reach the window via `syncInFlight` → `detachedThreadStores`.
    func submitDetachedFollowUp(threadID: UUID, question: String,
                                images: [NSImage] = []) {
        var q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            guard !images.isEmpty else { return }
            q = Self.agentImageOnlyPrompt(count: images.count)
        }
        // The panel is sitting on this very thread: an ordinary panel submit —
        // both surfaces hear every chunk.
        if threadHistoryID == threadID, !turns.isEmpty {
            text = q
            askComposeImages = images
            submit()
            return
        }
        runDetachedRound(threadID: threadID, seed: detachedSeed(for: threadID),
                         question: q, images: images)
    }

    /// Regenerate the last settled answer from a detached thread window — the
    /// window footer's ↻, mirroring `regenerateLastAnswer`: drop the newest
    /// Q/A pair from the seed and re-run the question, optionally pinned to a
    /// model for this one round (XII-135).
    func regenerateDetachedAnswer(threadID: UUID, model: String? = nil) {
        if threadHistoryID == threadID, !turns.isEmpty {
            regenerateLastAnswer(model: model)
            return
        }
        var seed = detachedSeed(for: threadID)
        guard let last = seed.last, last.role == "assistant", !last.streaming,
              !last.isAgent else { return }
        seed.removeLast()
        guard let questionTurn = seed.last, questionTurn.role == "user" else { return }
        seed.removeLast()
        let pin = model.map { ModelPin(provider: APIKeyStore.selectedProvider, model: $0) }
        runDetachedRound(threadID: threadID, seed: seed,
                         question: questionTurn.text, pin: pin)
    }

    /// The thread a detached-window round starts from: the window's live
    /// mirror, else the persisted row (mirror already released — shouldn't
    /// happen while the window is open, but never start from nothing).
    private func detachedSeed(for threadID: UUID) -> [Turn] {
        detachedThreadStores[threadID]?.turns
            ?? history.first(where: { $0.id == threadID })?.conversation
            ?? []
    }

    /// The headless borrow shared by the window's follow-up and regenerate:
    /// swap the thread into the panel state, let `submit()` arm the round
    /// (it captures its own snapshot + thread id immediately), then restore
    /// the panel exactly as it was and leave the round streaming detached.
    /// Returns the thread id the round actually landed on — the caller's id for
    /// a follow-up, a brand-new one when `submit()` treated the (empty) seed as
    /// a fresh thread. A compose window uses it to become that thread.
    @discardableResult
    private func runDetachedRound(threadID: UUID, seed: [Turn], question: String,
                                  hideUserBubble: Bool = false,
                                  trackCompactTask: Bool = false,
                                  pin: ModelPin? = nil,
                                  origin: HistoryItem.Origin? = nil,
                                  images: [NSImage] = []) -> UUID? {
        // Never stack rounds on one thread from the window: the tear-off
        // dropped the round's task handle, so a second submit couldn't
        // supersede-cancel the first. The field is disabled while streaming;
        // this is the backstop.
        guard !seed.contains(where: { $0.streaming }) else { return nil }
        // A detached round borrows the main submit pipeline, not the main
        // composer's transient state. Preserve every value submit mutates
        // synchronously, then give this round its own empty image payload and
        // one-shot model pin. Otherwise a Force Touch fired while the main box
        // holds pasted images or a pending regenerate choice can consume them.
        let highlightedID = highlightedHistoryIndex.flatMap { index in
            history.indices.contains(index) ? history[index].id : nil
        }
        let saved = (turns: turns, threadID: threadHistoryID, mode: mode,
                     text: text, task: task, pinned: isAnswerPinned,
                     error: askError, history: showHistory,
                     highlightedID: highlightedID,
                     fromPromptShortcut: fromPromptShortcut,
                     composeImages: askComposeImages,
                     regenModel: regenOverrideModel,
                     regenProvider: regenOverrideProvider)
        armModelPin(pin)
        askComposeImages = images
        task = nil                                    // detach, never cancel
        turns = seed
        threadHistoryID = threadID
        text = question
        submit(hideUserBubble: hideUserBubble)
        // A fresh submit synchronously parks its Recent placeholder. Stamp the
        // entry point before handing the round off; `persistThread` carries this
        // field forward when it replaces the placeholder with the settled row.
        if let origin,
           let index = history.firstIndex(where: { $0.id == threadHistoryID }) {
            history[index].origin = origin
        }
        // A regenerate that emptied the seed re-ids the thread (`submit`
        // treats it as fresh) — re-key the window's mirror so it keeps
        // hearing the round under the new id.
        if threadHistoryID != threadID, let store = detachedThreadStores[threadID] {
            detachedThreadStores.removeValue(forKey: threadID)
            store.threadID = threadHistoryID
            detachedThreadStores[threadHistoryID] = store
        }
        // Show the fresh question pair in the window right away — the first
        // `syncInFlight` only lands with the first token.
        if let store = detachedThreadStores[threadHistoryID] {
            store.turns = turns
        } else {
            // A compose window's FIRST question has no mirror yet: mint one here,
            // already holding the pair, so the window adopts a live thread rather
            // than an empty one waiting for the first token.
            detachedThreadStores[threadHistoryID] =
                DetachedThreadStore(threadID: threadHistoryID, turns: turns,
                                    followUpSupportsImages: activeModelSupportsVision)
        }
        let landedThreadID = threadHistoryID
        if trackCompactTask, let task {
            compactRoundTasks[landedThreadID] = task
        }
        // Hand the round off detached and put the panel back exactly as it was.
        task = saved.task
        turns = saved.turns
        threadHistoryID = saved.threadID
        mode = saved.mode
        text = saved.text
        isAnswerPinned = saved.pinned
        askError = saved.error
        showHistory = saved.history
        highlightedHistoryIndex = saved.highlightedID.flatMap { id in
            history.firstIndex(where: { $0.id == id })
        }
        fromPromptShortcut = saved.fromPromptShortcut
        askComposeImages = saved.composeImages
        regenOverrideModel = saved.regenModel
        regenOverrideProvider = saved.regenProvider
        return landedThreadID
    }

    /// Enter pressed in a detached compose window (the torn-out idle prompt).
    /// Routes exactly like the notch's own prompt — the window classified its
    /// own line and hands the destination in — but keeps everything headless:
    /// Note/Remind file through the identical services (their feedback lands on
    /// the model, which the window mirrors), an armed Agent bucket spawns its
    /// run, and an Ask runs the round detached and returns the thread id so the
    /// window can become that conversation in place.
    @discardableResult
    func submitDetachedCompose(_ line: String, destination: Panel) -> UUID? {
        let q = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        if agentComposeActive {
            borrowingText(q) { submitAgent() }
            return nil
        }
        switch destination {
        case .note:
            borrowingText(q) { submitNote() }
            return nil
        case .reminder:
            borrowingText(q) { submitReminder() }
            return nil
        case .chat:
            return runDetachedRound(threadID: UUID(), seed: [], question: q)
        }
    }

    /// Run a panel submit path against a line that isn't in the panel's box:
    /// park `text`, hand the borrowed line over, then put the panel's own draft
    /// back (every one of these paths clears `text` itself on the way through).
    private func borrowingText(_ line: String, _ body: () -> Void) {
        let saved = text
        text = line
        body()
        text = saved
    }

    /// Screens whose panels have registered geometry — the merge zones a
    /// detached window tests its drag against.
    var knownDisplays: [CGDirectDisplayID] { Array(panelScreenFrames.keys) }

    /// The island's current on-screen rect (bottom-left origin screen coords).
    func islandScreenRect(on display: CGDirectDisplayID?) -> CGRect? {
        guard let display,
              let panel = panelScreenFrames[display],
              let island = islandFrames[display] else { return nil }
        return CGRect(x: panel.minX + island.minX,
                      y: panel.maxY - island.maxY,
                      width: island.width, height: island.height)
    }

    /// The resting notch's on-screen rect — the merge drop zone.
    func restingNotchScreenRect(on display: CGDirectDisplayID?) -> CGRect? {
        guard let display,
              let panel = panelScreenFrames[display],
              let restHeight = restHeights[display] else { return nil }
        return CGRect(x: panel.midX - Tokens.notchWidth / 2,
                      y: panel.maxY - restHeight,
                      width: Tokens.notchWidth, height: restHeight)
    }

    /// Where a detached window is born: the panel's own glass body — same
    /// left/right edges, top just under the notch zone — so the tear reads as
    /// the panel itself coming off the bezel. Clamped to a usable session size
    /// (extending downward) and onto the screen.
    private func detachWindowSpawnRect() -> CGRect? {
        guard let display = activeDisplay,
              let island = islandScreenRect(on: display),
              let restHeight = restHeights[display] else { return nil }
        let minSize = CGSize(width: 560, height: 420)
        var rect = CGRect(x: island.minX,
                          y: island.minY,
                          width: island.width,
                          height: max(island.height - restHeight, 0))
        if rect.width < minSize.width {
            rect.origin.x -= (minSize.width - rect.width) / 2
            rect.size.width = minSize.width
        }
        if rect.height < minSize.height {
            rect.origin.y -= minSize.height - rect.height   // grow downward
            rect.size.height = minSize.height
        }
        if let screen = NSScreen.screens.first(where: { $0.displayID == display })?.visibleFrame {
            rect.origin.x = max(screen.minX + 8, min(rect.origin.x, screen.maxX - rect.width - 8))
            rect.origin.y = max(screen.minY + 8, min(rect.origin.y, screen.maxY - rect.height - 8))
        }
        return rect
    }

    /// In-flight date detection for the current text — superseded by every
    /// keystroke so only the read of what's actually in the box lands.
    private var dueTask: Task<Void, Never>?

    /// Recompute `detectedDue` off the main thread. `futureDate`/`recurrenceDate`
    /// run NSDataDetector + a handful of regexes; cheap per call, but synchronous
    /// in `text.didSet` they billed every keystroke to the main thread — visible
    /// jank during fast (IME) typing. Run them detached and publish back on the
    /// main actor, guarding that `text` is still the snapshot we read so a stale
    /// result can never land. Empty text resolves synchronously to nil so the hint
    /// clears instantly on delete-all.
    private func scheduleDueDetection() {
        dueTask?.cancel()
        let snapshot = text
        guard !snapshot.isEmpty else {
            detectedDue = nil
            return
        }
        dueTask = Task { [weak self] in
            let due = await Task.detached {
                RemindersService.futureDate(in: snapshot)
                    ?? RemindersService.recurrenceDate(in: snapshot)
            }.value
            guard !Task.isCancelled, let self, self.text == snapshot else { return }
            self.detectedDue = due
        }
    }

    /// The destination the user has pinned by hand — a typed `:`, Tab, or a `/`
    /// command. `nil` means Ask, the resting default; nothing reads the text to
    /// change that.
    ///
    /// It STAYS pinned. It used to be scoped to one line — cleared the moment the
    /// field emptied — so every capture bounced the pill back to Ask the instant
    /// it was filed, and a run of five notes meant re-pinning five times. A mode
    /// the user set by hand is a setting, not a gesture: it survives the submit,
    /// the panel closing, and the app quitting (`storedSubmitMode`), and only the
    /// same three doors that set it can change it back.
    @Published var manualPanelOverride: Panel? = NotchModel.startingSubmitMode

    /// The pin this launch opens with. Normally just what was stored — except on
    /// the FIRST launch after the Note/Remind → Capture merge, which resets it to
    /// Ask so the new single Capture door is read from the resting state rather
    /// than from a leftover pinned Note/Remind. Runs once.
    static var startingSubmitMode: Panel? {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: captureMergeResetKey) {
            defaults.set(true, forKey: captureMergeResetKey)
            storedSubmitMode = nil
        }
        return storedSubmitMode
    }
    private static let captureMergeResetKey = "captureMergeModeReset"

    /// The pinned destination as it survives a relaunch. Written only by the
    /// explicit doors (Tab, `/`, a typed `:`) — never by the transient nils the
    /// agent compose and image attach set on the live property, which are about
    /// this line and shouldn't rewrite what the user chose.
    static var storedSubmitMode: Panel? {
        get { (UserDefaults.standard.string(forKey: submitModeKey)).flatMap(Panel.init(rawValue:)) }
        set {
            let defaults = UserDefaults.standard
            if let newValue { defaults.set(newValue.rawValue, forKey: submitModeKey) }
            else { defaults.removeObject(forKey: submitModeKey) }
        }
    }
    private static let submitModeKey = "pinnedSubmitMode"

    /// Pin a destination through one of the explicit doors: set it live AND
    /// remember it. The one funnel, so a door can't be added later that changes
    /// the mode without making it stick.
    func pinSubmitPanel(_ panel: Panel?) {
        manualPanelOverride = panel
        Self.storedSubmitMode = panel
    }

    /// True only for Note mode entered by typing its punctuation prefix. It
    /// drives the temporary explanation beside the caret and clears when that
    /// exact first glyph is removed.
    @Published private(set) var typedNoteModeActive = false
    private var typedNoteTriggerPrefix: String?

    func activateTypedNoteMode(trigger: Character) {
        setAgentBucket(false)
        promptShortcutMode = nil
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            typedNoteTriggerPrefix = String(trigger)
            typedNoteModeActive = true
            pinSubmitPanel(.note)
        }
    }

    /// The first *future* moment the current text names (NSDataDetector, sub-ms,
    /// recomputed off `text.didSet`). This is what splits a capture between Notes
    /// and Reminders — a structural fact, not a guess, and the only thing left
    /// that reads the line at all. The same date becomes the due date
    /// `submitReminder()` files, so the split and the alarm can never disagree.
    /// It changes nothing on screen: Capture says Capture either way.
    @Published private(set) var detectedDue: Date? = nil

    /// Where pressing Enter on the *current* text will actually land. Nothing
    /// here reads the text: the destination is Ask until the USER says otherwise
    /// (a typed `:`, Tab, or a `/` command), and it stays put until they say so
    /// again. The classifier used to get a vote here and could flip the
    /// destination out from under a half-typed line; a wrong guess silently filed
    /// a question into Notes, and a right one still made the word beside the
    /// caret jitter while you typed. Guessing is not worth either.
    ///
    /// The engine itself is still around — the ⌘C clipboard hint runs on it
    /// (`senseClassify`), where an unsure read costs nothing because the user has
    /// to confirm the hint anyway.
    var effectiveSubmitPanel: Panel {
        guard turns.isEmpty else { return .chat }
        let resolved = manualPanelOverride ?? .chat
        // Capture names the BUCKET, not which of its two leaves the line lands
        // in: a captured line that names a time is filed in Reminders, everything
        // else in Notes. This is invisible — nothing in the UI switches on it —
        // it only picks which service `submitCurrent` hands the line to.
        // `/remind` is the one thing that pins a leaf, so an explicit `.reminder`
        // override (a dateless reminder) is left alone here.
        if resolved == .note, detectedDue != nil { return .reminder }
        return resolved
    }

    /// True while a typed-`:` capture line is still nothing but its trigger
    /// glyph — the one moment the little explanation beside the caret is for.
    /// The instant real text lands, that slot belongs to `captureLeaf`, which
    /// says the thing the explanation can't: where *this* line is going.
    var typedNoteHintOnly: Bool {
        guard typedNoteModeActive, let trigger = typedNoteTriggerPrefix else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == trigger
    }

    /// Which leaf of Capture the line in the box is heading for — `.note` or
    /// `.reminder` — or nil when the panel isn't capturing, or has nothing to
    /// capture yet. The split is `effectiveSubmitPanel`'s own, driven by
    /// `detectedDue` and recomputed off every keystroke; this only surfaces it.
    /// Capture used to make that call in silence, so a line naming a time filed
    /// itself into Reminders with nothing on screen having said so.
    var captureLeaf: Panel? {
        guard turns.isEmpty, !submitGoesToAgent, hasText, !typedNoteHintOnly else { return nil }
        switch effectiveSubmitPanel {
        case .chat:              return nil
        case .note, .reminder:   return effectiveSubmitPanel
        }
    }

    /// The word for `captureLeaf`, in the app's own destination vocabulary.
    var captureLeafLabel: String? {
        switch captureLeaf {
        case .note:     return L("hint.note")
        case .reminder: return L("hint.remind")
        default:        return nil
        }
    }

    /// Tab in the idle prompt: step where Enter will send the current line
    /// (Ask → Note → Remind → Ask…), overriding the classifier. Steps from
    /// whatever the *effective* destination is right now — including a prior
    /// override — so each press reads as "the next one", exactly what the cycled
    /// inline hint shows. The cycle stays INSIDE the Ask bucket: Agent is not a
    /// stop — it's the bucket pill's job (`setAgentBucket`). Keeping the
    /// heavyweight mode off an ambient navigation key is what makes mashing Tab
    /// through a wrong note/remind guess safe; a misrouted note costs nothing,
    /// a misrouted agent arm is a surprise. Tab while armed is inert: stepping
    /// off the Agent bucket is Shift-Tab's job (or the pill's Ask half).
    ///
    /// It also works on the EMPTY prompt, where there is no "current line" yet:
    /// the press arms a destination for the line about to be typed, the same pin
    /// a `/` command sets, and `idlePlaceholderKey` shows which one is armed.
    /// Since the pin only lifts when the field EMPTIES (`text.didSet`), one armed
    /// on an already-empty field survives right through the typing that follows.
    func toggleSubmitPanel() {
        // Armed on Agent, plain Tab does NOTHING. The Ask → Note → Remind cycle
        // is a *within-bucket* correction, and the agent compose isn't in that
        // bucket — a stray Tab there used to tear the whole compose down (folder,
        // chips, typed task) as a side effect of a key people mash. Leaving the
        // bucket is Shift-Tab's job (`toggleAgentBucket`) or the pill's Ask half.
        guard !agentComposeActive else { return }
        // One spring for the whole switch. The four call sites (Tab in the panel,
        // Tab in the detached window, and both ⌘-cycle paths) all called this
        // bare, so the pill's word, the pill's WIDTH, and the model chip that
        // only Ask carries each snapped to their new state in a single frame.
        // Animating here rather than at the call sites means they can't drift
        // apart again.
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            typedNoteTriggerPrefix = nil
            typedNoteModeActive = false
            switch effectiveSubmitPanel {
            case .chat:              pinSubmitPanel(.note)
            case .note, .reminder:   pinSubmitPanel(nil)
            }
        }
    }

    /// Whether any local agent CLI is installed + signed in — gates the bucket
    /// pill. Cheap after the launch `warmUp()`: binary resolution is cached and
    /// the sign-in probe is a file-exists.
    var agentAvailable: Bool { !AgentEngine.available.isEmpty }

    /// The bucket pill's two taps — an idempotent "set", not a toggle, so
    /// clicking the word that's already active is a no-op instead of a surprise
    /// flip. Ask restores the lightweight bucket with the classifier back in
    /// charge (no manual override — the pill picks a bucket, not a destination
    /// within one); Agent arms the compose exactly like the folder-drop path,
    /// seeded with the remembered project folder when there is one. Arming is
    /// deliberately cheap and reversible: it only unfurls the chips row — a run
    /// still needs a folder, a typed task, and an explicit Enter.
    func setAgentBucket(_ armed: Bool) {
        if armed {
            guard !agentComposeActive else { return }
            enterAgentCompose()
        } else {
            guard agentComposeActive else { return }
            // Restore the pinned destination BEFORE Agent switches off. Otherwise
            // `effectiveSubmitPanel` renders one transient Ask frame (the live
            // override is nil while Agent is armed) and only then becomes Capture,
            // making the destination half visibly jump on the way back.
            manualPanelOverride = Self.storedSubmitMode
            exitAgentCompose()
        }
    }

    /// Shift-Tab in the idle prompt: flip the bucket between Ask and Agent — the
    /// keyboard twin of tapping the `BucketTogglePill`. Kept off the plain-Tab
    /// cycle on purpose: Tab stays inside the lightweight Ask bucket (Ask → Note
    /// → Remind), so mashing it through a wrong note/remind guess can never
    /// surprise you into arming the heavyweight agent mode — that gets its own
    /// key. A no-op that stays on Ask when no agent CLI is installed, since
    /// `setAgentBucket` → `enterAgentCompose` already guards on availability.
    func toggleAgentBucket() {
        setAgentBucket(!agentComposeActive)
    }

    // MARK: - Prompt shortcut naming

    /// Give a ready prompt shortcut an AI-generated display name, if it doesn't
    /// have one yet. Called when a prompt first settles into a ready row (the
    /// Settings editor's save path and the chat-driven create path both funnel
    /// here) — NOT while the user is still typing: a name is generated once per
    /// prompt, silently, and never overwrites an existing one. `displayName`
    /// falls back to the prompt meanwhile, so old shortcuts render fine even
    /// before their naming pass completes.
    ///
    /// The name is written straight back into the persisted store (and broadcast
    /// via `.promptShortcutsChanged`), so the `/` menu and the settings row both
    /// pick it up without a relaunch. Runs detached — naming must never block a
    /// keystroke or a submit — and tolerates every failure (no key, a dead
    /// network, a stub service) by simply leaving the shortcut unnamed.
    func ensurePromptShortcutName(_ shortcut: PromptShortcut) {
        let instruction = shortcut.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty,
              shortcut.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        else { return }
        let id = shortcut.id
        Task { [weak self] in
            guard let self else { return }
            let name: String
            do {
                name = try await self.ai.complete(prompt: """
                Give this prompt shortcut a short, single-phrase display name for a \
                command menu. Reply with ONLY the name — no quotes, no prefix, no \
                explanation, under 4 words. Prompt: \(instruction)
                """)
            } catch { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’"))
            guard !trimmed.isEmpty else { return }
            let capped = trimmed.count > 24 ? String(trimmed.prefix(24)) : trimmed
            var shortcuts = PromptShortcutStore.current
            guard let index = shortcuts.firstIndex(where: { $0.id == id }),
                  shortcuts[index].name == nil else { return }
            shortcuts[index].name = capped
            PromptShortcutStore.save(shortcuts)
            NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
        }
    }

    // MARK: - The `/` command menu

    /// One row of the `/` menu. The menu's original four rows are *modes* — a
    /// `/` on the fresh prompt pins the next line's destination, exactly what the
    /// pill and the Tab cycle already reach. A user-defined prompt shortcut is a
    /// second kind of row with the same shape: pin it and Enter runs the input
    /// through that shortcut's instruction. Codex skills are the third kind: they
    /// arm Agent and leave their explicit `$name` invocation in the input.
    enum SlashMatch: Identifiable {
        case mode(SlashCommand)
        case shortcut(PromptShortcut)
        case skill(CodexCLIService.Skill)

        var id: String {
            switch self {
            case .mode(let command): return "mode." + command.rawValue
            case .shortcut(let shortcut): return "shortcut." + shortcut.id.uuidString
            case .skill(let skill): return "skill." + skill.name
            }
        }
    }

    /// The four modes a `/` on the empty prompt can pin the next line to. The set
    /// the pill (Ask ⇄ Agent) and the Tab cycle (Ask → Note → Remind) already
    /// reach between them — this is the one surface that names all four at once,
    /// for the people who'd rather type the destination than learn two keys.
    enum SlashCommand: String, CaseIterable, Identifiable {
        case ask, capture, remind, agent

        var id: String { rawValue }

        /// The destination word — the SAME string the inline ghost and the bucket
        /// pill show, so `/note` and the hint beside the caret can't disagree.
        var title: String { L("hint." + rawValue) }

        /// What the text after the slash matches on: the English command word
        /// (stable in every UI language — `/note` works on a Chinese interface),
        /// a couple of natural aliases, and the localized title, so `/记` finds
        /// 记录 too.
        var keywords: [String] {
            let base: [String]
            switch self {
            case .ask:    base = ["ask", "chat"]
            case .capture: base = ["capture", "note", "notes", "memo"]
            case .remind: base = ["remind", "reminder", "todo"]
            case .agent:  base = ["agent", "code", "task"]
            }
            return base + [title.lowercased()]
        }
    }

    /// Which row of the `/` menu the keyboard is on. Kept pinned to the top
    /// whenever the menu is shut (`text.didSet`), so a reopened menu never
    /// inherits a stale highlight.
    @Published var slashHighlight: Int = 0

    /// Is the `/` menu on screen? Only on a FRESH prompt (with a thread up, every
    /// line is a follow-up), only while the text IS the command — a leading `/`
    /// with no whitespace after it — and only while something still matches. That
    /// last clause is what keeps a real line that happens to open with a path
    /// ("/usr/local, what lives there?") from having its keys eaten: the menu
    /// drops away the moment the query stops naming a mode.
    var slashMenuOpen: Bool {
        guard turns.isEmpty, text.hasPrefix("/") else { return false }
        guard !text.dropFirst().contains(where: { $0.isWhitespace || $0.isNewline })
        else { return false }
        return !slashMatches.isEmpty
    }

    /// The rows the current query leaves standing: the four modes (in the enum's
    /// declared order so the list never reshuffles under the highlight as you
    /// type), then every *ready* prompt shortcut and enabled Codex skill after
    /// them. A bare `/` matches all of them. Agent is offered only when a local
    /// agent CLI is actually installed — the same gate the bucket pill runs on.
    /// Prompt shortcuts match on name and prompt; skills match on invocation and
    /// display name.
    var slashMatches: [SlashMatch] {
        let query = text.hasPrefix("/") ? String(text.dropFirst()).lowercased() : ""
        let modes: [SlashMatch] = SlashCommand.allCases.compactMap { command in
            guard command != .agent || agentAvailable else { return nil }
            guard query.isEmpty || command.keywords.contains(where: { $0.hasPrefix(query) })
            else { return nil }
            return .mode(command)
        }
        let shortcuts: [SlashMatch] = PromptShortcutStore.current.compactMap { shortcut in
            guard shortcut.isReady else { return nil }
            guard query.isEmpty
                  || shortcut.name?.lowercased().hasPrefix(query) == true
                  || shortcut.prompt.lowercased().hasPrefix(query) else { return nil }
            return .shortcut(shortcut)
        }
        let skills: [SlashMatch] = agentSkills.compactMap { skill in
            guard AgentEngine.codex.isAvailable else { return nil }
            guard query.isEmpty
                    || skill.name.lowercased().hasPrefix(query)
                    || skill.displayName.lowercased().hasPrefix(query) else { return nil }
            return .skill(skill)
        }
        return modes + shortcuts + skills
    }

    /// Refresh on every fresh `/` so installing or editing a skill does not need an
    /// app relaunch. Repeated keystrokes share the same in-flight request.
    private func refreshAgentSkills(forceReload: Bool = false) {
        guard agentSkillsTask == nil else { return }
        let cwd = (agentComposeFolder ?? lastAgentFolder
                   ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)).path
        agentSkillsTask = Task { [weak self] in
            let loaded = await CodexCLIService.loadSkills(cwd: cwd,
                                                          forceReload: forceReload)
            guard !Task.isCancelled, let self else { return }
            // A transient app-server failure must not blank a previously good
            // menu. A successful Codex list always includes system skills, so an
            // empty response is safely treated as failure once we have a cache.
            if !loaded.isEmpty || self.agentSkills.isEmpty {
                self.agentSkills = loaded
            }
            self.agentSkillsTask = nil
            if self.slashHighlight >= self.slashMatches.count {
                self.slashHighlight = max(self.slashMatches.count - 1, 0)
            }
        }
    }

    /// ↓ / ↑ inside the menu, wrapping at both ends so the rows are a ring.
    /// Returns whether the key was consumed — `false` with no menu open, which is
    /// what lets ↑/↓ fall through to history recall exactly as before.
    func slashMenuStep(_ delta: Int) -> Bool {
        guard slashMenuOpen else { return false }
        let count = slashMatches.count
        guard count > 0 else { return false }
        slashHighlight = ((slashHighlight + delta) % count + count) % count
        return true
    }

    /// Enter / Tab on an open menu: apply the highlighted row instead of sending
    /// "/no" off to the AI.
    func confirmSlashCommand() -> Bool {
        guard slashMenuOpen else { return false }
        let matches = slashMatches
        guard matches.indices.contains(slashHighlight) else { return false }
        applySlashCommand(matches[slashHighlight])
        return true
    }

    /// Esc on an open menu: drop the command word, and the menu with it, back to
    /// the blank prompt — one step out, not a panel close.
    func dismissSlashMenu() -> Bool {
        guard slashMenuOpen else { return false }
        text = ""
        return true
    }

    /// A prompt shortcut pinned as the current line's mode. When set, Enter on
    /// the idle prompt runs the input through that shortcut's instruction instead
    /// of the ordinary Ask/Note/Remind routing — the shortcut behaves as a named,
    /// switchable mode. Scope mirrors `manualPanelOverride`: it lifts the moment
    /// the field empties (submit, delete-all, close), so every fresh line starts
    /// on the classifier again.
    @Published var promptShortcutMode: PromptShortcut? = nil

    /// Land on a row. Clear the command word FIRST (the field is now empty and
    /// ready for the real line), then pin where Enter will send it — that order
    /// matters, since emptying the field is exactly what clears
    /// `manualPanelOverride` and `promptShortcutMode`. The pin then behaves like
    /// a Tab override that was pressed a keystroke early: it holds through the
    /// whole line and lifts on submit. Note/Remind announce themselves through
    /// the prompt's placeholder until there's text for the inline ghost to trail;
    /// Agent flips the pill; a prompt shortcut names itself in the hint; a skill
    /// arms Codex Agent — keeping the armed model — and leaves its explicit
    /// invocation ready to extend.
    func applySlashCommand(_ match: SlashMatch) {
        text = ""
        slashHighlight = 0
        switch match {
        case .mode(let command):
            switch command {
            case .ask:
                setAgentBucket(false)
                promptShortcutMode = nil
                pinSubmitPanel(nil)
            case .capture:
                setAgentBucket(false)
                promptShortcutMode = nil
                pinSubmitPanel(.note)
            case .remind:
                setAgentBucket(false)
                promptShortcutMode = nil
                pinSubmitPanel(.reminder)
            case .agent:
                promptShortcutMode = nil
                manualPanelOverride = nil
                setAgentBucket(true)
            }
        case .shortcut(let shortcut):
            setAgentBucket(false)
            manualPanelOverride = nil
            promptShortcutMode = shortcut
        case .skill(let skill):
            promptShortcutMode = nil
            manualPanelOverride = nil
            setAgentBucket(true)
            armCodexForSkill()
            text = "$\(skill.name) "
        }
    }

    /// A skill has to run on Codex — the list comes from Codex's app-server and
    /// `$name` is its invocation syntax — so picking one arms Codex. What it must
    /// NOT do is cost the user their model: this used to blank `agentModelID`
    /// unconditionally, which dropped the chip from "GPT-5.2 high" to a bare
    /// "Codex high" AND persisted that loss to the remembered pick. Already on
    /// Codex, nothing moves. Coming from another engine, the armed model belongs
    /// to that engine, so it can't carry over — restore Codex's own last-used
    /// pick instead of falling to the CLI default.
    private func armCodexForSkill() {
        guard agentArmedEngine != .codex else { return }
        if let id = AgentModelMRU.entries(for: .codex).first?.model,
           let choice = AgentEngine.codex.modelChoices.first(where: { $0.id == id }) {
            selectAgentModel(choice)
        } else {
            agentArmedEngine = .codex
            agentModelID = nil
        }
    }

    /// The idle prompt's placeholder key. A mode pinned by `/` (or by Tab on a
    /// line since deleted) has nothing else to show on an empty field — the
    /// inline ghost only exists beside typed glyphs — so the placeholder carries
    /// it: "Write a note…", "Remind me to…". A pinned prompt shortcut shows its
    /// name in place of the key. Agent compose keeps its own.
    var idlePlaceholderKey: String {
        if agentComposeActive { return "agent.placeholder" }
        if let shortcut = promptShortcutMode { return shortcut.displayName }
        switch manualPanelOverride {
        case .note:     return "note.placeholder"
        case .reminder: return "remind.placeholder"
        default:        return "input.placeholder"
        }
    }

    /// True when Enter on the current input goes to an agent CLI: an armed
    /// compose on the idle prompt, or a follow-up on an agent thread whose
    /// session is resumable (`submit` hands that line to `continueAgentThread`).
    /// With a thread on screen the THREAD decides — an ask thread's follow-up
    /// goes to the chat model even while the Agent bucket sits armed underneath,
    /// and an agent thread's goes to its agent regardless of the bucket. The
    /// ghost hint, its colours, and `submitCurrent` all read this one switch, so
    /// the word beside the caret can never disagree with where the line lands.
    var submitGoesToAgent: Bool {
        if !turns.isEmpty { return agentThreadContinuation != nil }
        return agentComposeActive
    }

    /// The word in the inline hint — the destination spelled out: "Note" when this
    /// line will be saved to Apple Notes, "Remind" when it'll be filed in Apple
    /// Reminders, "Ask" when it'll go to the AI. Flips live with the classifier as
    /// the text crosses intents, so the hint beside the caret literally says where
    /// Enter sends the line.
    var submitLabel: String {
        // Agent-bound input (armed compose, or an agent thread's follow-up)
        // owns the hint: Enter sends the line to the agent CLI.
        if submitGoesToAgent { return L("hint.agent") }
        switch effectiveSubmitPanel {
        case .chat:              return L("hint.ask")
        // Note and Remind are ONE destination wearing two faces: the word is the
        // same "Capture" for both, and which leaf it lands in rides the dimmer
        // suffix (`submitLabelSuffix`). Two peer words with two marks read as two
        // modes to choose between — which is the choice the date detector already
        // makes for you.
        case .note, .reminder:   return L("hint.capture")
        }
    }

    /// The dimmer trailing detail rendered after `submitLabel` — the Remind
    /// recurrence ("Remind · Daily"), or nothing for Ask/Note. Ask deliberately
    /// carries no model name here: the model is already named in the pill row
    /// below the field, and repeating it in the ghost read as clutter. Kept
    /// separate from the destination word so the inline hint can paint it a shade
    /// lighter than the word: the word answers "where does Enter send this", the
    /// suffix is the softer footnote "…how often".
    var submitLabelSuffix: String {
        // The agent hint names the runner, not a chat model: "Agent Codex" /
        // "Agent Claude" — the thread's own engine on a follow-up, the armed
        // one in a compose.
        if submitGoesToAgent {
            return " " + (agentThreadContinuation ?? agentArmedEngine).displayName
        }
        switch effectiveSubmitPanel {
        case .chat:     return ""
        case .note:     return ""
        case .reminder: return submitHintSuffix
        }
    }

    /// Present-progressive "thinking" words shown beside the dots while the AI is
    /// still composing and no token has landed yet — the bare pre-stream wait. Picked
    /// at random per question so the moment of thought reads with a little mood
    /// instead of a fixed "Thinking…". Drawn from the Orange Moon imagery.
    static let thinkingWords = [
        "Gazing...", "Glowing...", "Drifting...", "Imagining...", "Whispering...",
        "Hoping...", "Waiting...", "Wandering...", "Lingering...",
        "Floating...", "Shimmering...", "Musing...", "Pondering...", "Yearning...",
        "Reminiscing...", "Fading...", "Echoing...", "Searching...", "Wondering...",
    ]

    /// The handful of rounds that already name their own job: a translation that
    /// says "Whispering…" is hiding what it is plainly doing. These are the verbs
    /// people fire at a selection — the prompt-shortcut work — so the wait word
    /// says the work instead of a mood, pinned for the whole round (no rotation).
    ///
    /// Cues are imperative verbs in the languages the app ships in (EN / 简 / 繁 /
    /// 日 / 한 / ES), matched anywhere in the line: the instruction can sit either
    /// side of the quoted text ("翻译一下：…", "… translate to Japanese"). Verbs
    /// only, on purpose — a question *about* a translation ("who did the best
    /// translation of Dante") keeps the mood rotation. Order is priority, so
    /// "translate and summarize this" reads "Translating…".
    ///
    /// Deliberately NOT here: write / draft / plan / brainstorm and the rest of
    /// the generation asks. Those are the ordinary conversation, and pinning every
    /// one of them to a literal verb would retire the mood words entirely.
    static let taskWords: [(word: String, orb: OrbState, cues: [String])] = [
        ("Translating...", .connecting, [
            "translate", "translating",
            "翻译", "翻譯", "译成", "譯成", "译为", "譯為", "转译", "轉譯",
            "翻訳", "번역",
            "traduce", "tradúce", "traducir", "traduzca",
        ]),
        // "summar" on purpose: covers summarize / summarise / summary / summaries
        // in one cue. Spanish keeps the verb forms only — bare "resume" is the
        // English noun ("review my resume"), which is not a summary request.
        ("Summarizing...", .composing, [
            "summar", "tl;dr", "tldr", "recap",
            "总结", "總結", "摘要", "概括", "归纳", "歸納",
            "要約", "요약",
            "resumir", "resumen",
        ]),
        ("Proofreading...", .composing, [
            "proofread", "typos",
            "校对", "校對", "校正", "纠错", "糾錯", "错别字", "錯別字",
            "誤字", "교정",
            "corrige los errores",
        ]),
        ("Rewriting...", .composing, [
            "rewrite", "reword", "rephrase", "paraphrase",
            "改写", "改寫", "重写", "重寫", "润色", "潤色", "改一下措辞",
            "書き直", "다시 써",
            "reescribe", "reescribir", "reformula",
        ]),
        ("Explaining...", .composing, [
            "explain", "eli5",
            "解释", "解釋", "讲解", "講解", "说明一下", "說明一下",
            "解説", "설명",
            "explica", "explique",
        ]),
    ]

    /// The pinned wait word for this question, or nil when it's an ordinary round
    /// that should roll a mood word.
    static func taskStyle(for question: String) -> (word: String, orb: OrbState)? {
        let q = question.lowercased()
        guard let match = taskWords.first(where: { entry in entry.cues.contains { q.contains($0) } })
        else { return nil }
        return (match.word, match.orb)
    }

    /// Text-only convenience for compact shortcut presentation, which shares
    /// the same task classifier but does not render an orb itself.
    static func taskWord(for question: String) -> String? {
        taskStyle(for: question)?.word
    }

    /// Non-nil while this round's wait word is pinned to a task word (see
    /// `taskWords`) — the reroll returns it unchanged and the rotation timer
    /// never starts. Cleared when the round ends.
    private var pinnedThinkingWord: String? = nil
    /// Semantic orb paired with the pinned task word. Translation connects
    /// languages; the other literal task labels retain the composing ribbon.
    private var pinnedThinkingOrb: OrbState = .composing

    /// The current rotating thinking word. Re-rolled at the start of each answer and
    /// every `thinkingWordInterval` while the wait is on screen, avoiding an immediate
    /// repeat. This is the *mood word only* — it is NOT the thing the UI displays
    /// directly. The UI reads `thinkingStatus`, which decides between this word and a
    /// live tool-activity line so the two can never both show at once.
    @Published private var thinkingWord: String = NotchModel.thinkingWords.randomElement() ?? "drifting"

    /// A live tool-activity line ("Searching the web…", "Reading the results…") when a
    /// tool is running, else nil. Set by the harness via `updateActivity`.
    @Published private var thinkingActivity: String? = nil

    /// The thinking orb's mode riding the live activity line — set by the SAME
    /// harness call that sets the label (the harness knows which tool it just
    /// launched; see `AgentHarness.orbState(for:)`), so the orb is never guessed
    /// back out of a localized string. Meaningful only while `thinkingActivity`
    /// is non-nil; the exposure below falls back to the calm thinking ribbon.
    @Published private var thinkingActivityOrb: OrbState = .composing

    /// What the wait line's orb should wear right now: the activity's semantic
    /// mode while a tool runs, else the pinned task's own mode. Ordinary mood
    /// words and bare waits keep the reference "Thinking…." ribbon.
    var thinkingOrbState: OrbState {
        thinkingActivity != nil ? thinkingActivityOrb : pinnedThinkingOrb
    }

    /// When the current round's pre-stream wait began — the anchor for the quiet
    /// "· 12s" elapsed suffix on the wait line (see `WaitElapsedSuffix`). Set when
    /// the wait starts, cleared when the first token lands or the round ends, so
    /// the timer can never tick over a streaming answer.
    @Published private(set) var thinkingStartedAt: Date? = nil

    /// Latched true the first time a tool runs this round. Before any tool, the wait is
    /// the bare three dots (no word). Once the round has touched a tool, it stays in
    /// "word mode" for the rest of the wait — the activity line while a tool runs, then
    /// the rotating mood word through the compose gap. Reset at the start of each round.
    @Published private var hasUsedToolThisRound = false

    /// The single source of truth for the pre-stream status line beside the dots:
    ///   • before any tool runs → empty (the wait is pure dots, no word);
    ///   • while a tool runs     → the live activity line ("Searching the web…");
    ///   • after a tool, no tool currently running → the rotating mood word.
    /// One value, so a word and an activity line can never show at once.
    var thinkingStatus: String {
        if let thinkingActivity { return thinkingActivity }
        return hasUsedToolThisRound ? thinkingWord : ""
    }

    /// The live tool-activity line on its own, exposed read-only so the streaming
    /// turn can render it as an INDEPENDENT row (under the growing answer — see
    /// `AssistantTurnView.showActivityRow`) rather than folding it into the
    /// dots/answer cross-fade. Non-nil exactly while a tool is running ("Searching
    /// the web…", "Reading the results…"); nil otherwise. Kept separate from
    /// `thinkingStatus` because the activity line must stay visible even after the
    /// model has emitted a preface — sharing the dots' `hasText` gate is what hid
    /// it mid-search.
    var currentActivity: String? { thinkingActivity }

    /// The rotating mood word on its own (no activity merged in), exposed read-only
    /// so `StreamingTurnContent`'s dots row shows *only* the mood word — never the
    /// activity label, which now lives in its own row.
    var currentThinkingWord: String { thinkingWord }

    /// Pick a fresh thinking word, avoiding an immediate repeat. A pinned task word
    /// wins outright — the round says what it's doing and never drifts off it.
    private func rerollThinkingWord(for answerID: UUID? = nil) {
        if let pinnedThinkingWord {
            thinkingWord = pinnedThinkingWord
            if let answerID { mirrorThinkingWord(for: answerID) }
            return
        }
        let pool = NotchModel.thinkingWords.filter { $0 != thinkingWord }
        thinkingWord = pool.randomElement() ?? NotchModel.thinkingWords.randomElement() ?? thinkingWord
        if let answerID { mirrorThinkingWord(for: answerID) }
    }

    /// How long each mood word lingers before rotating to the next. Slow enough to
    /// read as a settling mood, not a ticker.
    private static let thinkingWordInterval: TimeInterval = 4.0

    /// Slowly rotates the mood word while the pre-stream wait is on screen, so a long
    /// search/compose round (10s+ across several tool rounds) breathes instead of
    /// freezing on one word. Scheduled in `.common` mode so it keeps firing during the
    /// panel's animations/tracking. Started when `.load` begins, stopped the moment the
    /// first token lands or the round ends.
    private var thinkingWordTimer: Timer? = nil

    /// `question` is the line this round is answering: a task-shaped one (translate,
    /// summarize, …) pins the wait word to that job instead of rolling a mood word.
    func startThinkingWordRotation(for question: String = "", answerID: UUID) {
        thinkingWordTimer?.invalidate()
        thinkingActivity = nil
        thinkingStartedAt = Date()
        // Each round starts in pure-dots mode; only a tool flips it into word mode.
        hasUsedToolThisRound = false
        if let taskStyle = Self.taskStyle(for: question) {
            pinnedThinkingWord = taskStyle.word
            pinnedThinkingOrb = taskStyle.orb
        } else {
            pinnedThinkingWord = nil
            pinnedThinkingOrb = .composing
        }
        rerollThinkingWord(for: answerID)
        mirrorThinkingState(for: answerID)
        // A pinned word is the whole round's word — nothing to rotate.
        guard pinnedThinkingWord == nil else {
            thinkingWordTimer = nil
            return
        }
        let t = Timer(timeInterval: NotchModel.thinkingWordInterval, repeats: true) { [weak self] _ in
            self?.rerollThinkingWord(for: answerID)
        }
        t.tolerance = 0.4
        RunLoop.main.add(t, forMode: .common)
        thinkingWordTimer = t
    }

    func stopThinkingWordRotation(for answerID: UUID) {
        clearRuntimeThinkingState(for: answerID)
        guard thinkingAnswerID == answerID else { return }
        thinkingWordTimer?.invalidate()
        thinkingWordTimer = nil
        thinkingActivity = nil
        thinkingStartedAt = nil
        hasUsedToolThisRound = false
        pinnedThinkingWord = nil
        pinnedThinkingOrb = .composing
    }

    /// The first-token freeze: stop the mood-word rotation (the pre-stream wait
    /// is over) but leave `thinkingActivity` and the elapsed clock ALONE. This is
    /// what the reveal flush calls — it fires on every flush, which can happen
    /// while a tool from the same round is still running (the model spoke a
    /// preface before searching), and clearing the activity there is exactly what
    /// used to kill the "Searching the web…" line the moment any text landed.
    /// Terminal paths (finish/error/stop) use `stopThinkingWordRotation(for:)`, which
    /// clears everything.
    func freezeThinkingWord(for answerID: UUID) {
        guard thinkingAnswerID == answerID else { return }
        thinkingWordTimer?.invalidate()
        thinkingWordTimer = nil
    }

    /// Funnel the harness's activity label into the single `thinkingStatus` value. A
    /// non-nil label means a tool is running — which also latches the round into "word
    /// mode" so that after the tool clears, the wait shows the mood word (not back to
    /// bare dots). `nil` clears the live line, falling back to the mood word.
    func setThinkingActivity(_ label: String?, orb: OrbState = .composing) {
        if label != nil { hasUsedToolThisRound = true }
        thinkingActivity = label
        thinkingActivityOrb = orb
        if let thinkingAnswerID { mirrorThinkingState(for: thinkingAnswerID) }
    }

    /// Copy the panel's live wait state onto the answer turn itself. The turn is
    /// the unit mirrored into a detached window, so both surfaces consume the
    /// same values instead of the window inventing its own fallback state.
    private func mirrorThinkingState(for answerID: UUID) {
        updateRuntimeTurn(answerID) { turn in
            turn.thinkingWord = thinkingWord
            turn.toolActivity = thinkingActivity
            turn.thinkingOrbState = thinkingOrbState
            turn.thinkingStartedAt = thinkingStartedAt
        }
    }

    /// Word rotation must not overwrite a detached tool's semantic orb. The
    /// detached harness mirrors that orb directly; only the word changes on this
    /// timer tick.
    private func mirrorThinkingWord(for answerID: UUID) {
        updateRuntimeTurn(answerID) { $0.thinkingWord = thinkingWord }
    }

    private func clearRuntimeThinkingState(for answerID: UUID) {
        updateRuntimeTurn(answerID) { turn in
            turn.thinkingStartedAt = nil
            turn.pendingQuestion = nil
        }
    }

    /// Mutate runtime-only presentation state everywhere this answer may live:
    /// the panel, its in-flight snapshot, and the detached window mirror.
    private func updateRuntimeTurn(_ answerID: UUID,
                                   _ update: (inout Turn) -> Void) {
        if let i = turns.firstIndex(where: { $0.id == answerID }) {
            update(&turns[i])
        }
        guard let roundIndex = inFlightRounds.firstIndex(where: { $0.answerID == answerID }),
              let turnIndex = inFlightRounds[roundIndex].thread.firstIndex(where: {
                  $0.id == answerID
              }) else { return }
        update(&inFlightRounds[roundIndex].thread[turnIndex])
        let round = inFlightRounds[roundIndex]
        detachedThreadStores[round.threadID]?.turns = round.thread
    }

    // MARK: - Natural-language app settings

    /// A validated setting update. Validation happens for the whole batch before
    /// the confirmation card appears, so the card never promises a change that we
    /// already know is malformed. The payload retains typed values for the commit;
    /// `summary` is deliberately safe to show (API keys are never echoed).
    private struct PreparedAppSettingChange {
        enum Payload {
            case language(AppLanguage)
            case dockIcon(DockIconVisibility)
            case menuBarIcon(MenuBarIconVisibility)
            case launchAtLogin(Bool)
            case placement(DisplayPlacement)
            case hideInFullscreen(Bool)
            case liveActivity(Bool)
            case hoverSensitivity(HoverSensitivity)
            case noteDestination(NoteDestination)
            case notesFolder(String)
            case copySense(Bool)
            case shortcut(SummonHotKey)
            /// `nil` chord ⇒ restore the shipped default for that action.
            case actionShortcut(AppShortcutAction, ShortcutChord?)
            /// The whole resulting row — new binding or edited existing one.
            case promptShortcut(PromptShortcut)
            case promptShortcutRemoval(UUID)
            case customInstructions(String)
            case proxy(String)
            case aiProvider(Provider)
            case aiModel(Provider, String)
            case apiKey(Provider, String)
            case searchBackend(APIKeyStore.SearchBackend?)
            case searchAPIKey(APIKeyStore.SearchBackend, String)
            case customProviderName(String)
            case customProviderURL(String)
            case customProviderModel(String)
        }

        let key: String
        let summary: String
        let payload: Payload
        let isNoOp: Bool
    }

    private enum AppSettingValidationError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let message) = self { return message }
            return nil
        }
    }

    /// At most one settings write can own a round's confirmation card. Models are
    /// instructed to batch, but this runtime gate keeps a malformed multi-call
    /// turn from showing two confirmations or racing two writes anyway.
    private var settingsConfirmationAnswers: Set<UUID> = []

    /// Entry point injected into `ManageAppSettingsTool` for this answer round.
    /// Listing is read-only and returns immediately. Every update — including a
    /// multi-setting batch — suspends on the same in-answer choice card used by
    /// `ask_user`, then commits only when the positive option is tapped.
    func handleAppSettingsRequest(answerID: UUID,
                                  request: AppSettingsRequest) async throws -> String {
        if request.action == .list { return appSettingsSnapshot() }
        if request.action == .shortcuts { return appShortcutSnapshot() }
        if request.action == .open {
            guard let requested = request.section,
                  openAppSettingsSection(requested) else {
                return "Error: section must be model, search, notes, general, appearance, shortcuts, or about."
            }
            return "Opened the \(requested) settings page so the user can review the available choices."
        }

        guard settingsConfirmationAnswers.insert(answerID).inserted else {
            return "Error: another settings update is already awaiting confirmation in this answer. Combine all requested changes into one manage_app_settings call."
        }
        defer { settingsConfirmationAnswers.remove(answerID) }

        var prepared: [PreparedAppSettingChange] = []
        var seen = Set<String>()
        let batchProvider = request.changes
            .first { Self.settingToken($0.setting) == "ai_provider" }
            .flatMap { Self.parseProvider($0.value) }
            ?? APIKeyStore.selectedProvider
        for raw in request.changes {
            let change: PreparedAppSettingChange
            do {
                change = try prepareAppSettingChange(raw, defaultProvider: batchProvider)
            } catch {
                // An unsupported value is most useful when it lands the user on
                // the actual control and its real choices. This also catches a
                // model that attempted `update` instead of the advertised `open`
                // fallback, so the UX does not depend on perfect tool selection.
                if let section = Self.appSettingsSection(for: raw.setting) {
                    _ = openAppSettingsSection(section)
                    return "\(error.localizedDescription) Opened the \(section) settings page so the user can review the available choices."
                }
                throw error
            }
            guard seen.insert(change.key).inserted else {
                throw AppSettingValidationError.message(
                    "The same setting appears more than once in this update: \(change.key).")
            }
            prepared.append(change)
        }

        let effective = prepared.filter { !$0.isNoOp }
        guard !effective.isEmpty else {
            return "No change was needed; those settings already have the requested values."
        }

        let copy = appSettingsConfirmationCopy()
        let lines = effective.map(\.summary).joined(separator: "\n")
        let choice = try await awaitUserChoice(
            answerID: answerID,
            question: copy.question + "\n" + lines,
            options: [copy.cancel, copy.confirm],
            inlineOptions: true)
        guard choice == "The user chose: \"\(copy.confirm)\"" else {
            return "Cancelled. No settings were changed."
        }

        // Login-item registration is the only commit that can fail. Do it before
        // the infallible UserDefaults writes so a refusal cannot leave half a batch
        // applied after the user approved the whole summary.
        for change in effective {
            if case .launchAtLogin(let enabled) = change.payload {
                try LaunchAtLogin.setEnabled(enabled)
            }
        }

        var refreshAI = false
        for change in effective {
            switch change.payload {
            case .language(let value):
                Localization.shared.language = value
            case .dockIcon(let value):
                DockIconVisibility.current = value
                NotificationCenter.default.post(name: .dockIconVisibilityChanged, object: nil)
            case .menuBarIcon(let value):
                MenuBarIconVisibility.current = value
                NotificationCenter.default.post(name: .menuBarIconVisibilityChanged, object: nil)
            case .launchAtLogin:
                break // committed first because this one can throw
            case .placement(let value):
                DisplayPlacement.current = value
                NotificationCenter.default.post(name: .displayPlacementChanged, object: nil)
            case .hideInFullscreen(let enabled):
                HideNotchInFullscreen.isEnabled = enabled
                NotificationCenter.default.post(name: .hideNotchInFullscreenChanged, object: nil)
            case .liveActivity(let enabled):
                liveActivityEnabled = enabled
            case .hoverSensitivity(let value):
                applyHoverSensitivity(value)
            case .noteDestination(let value):
                NoteDestination.current = value
            case .notesFolder(let path):
                FileNotesService.folderPath = path
            case .copySense(let enabled):
                copySenseEnabled = enabled
            case .shortcut(let value):
                SummonHotKey.current = value
                NotificationCenter.default.post(name: .summonHotKeyChanged, object: nil)
            case .actionShortcut(let action, let chord):
                if let chord {
                    AppShortcutStore.set(chord, for: action)
                } else {
                    AppShortcutStore.reset(action)
                }
                NotificationCenter.default.post(name: .appShortcutsChanged, object: nil)
            case .promptShortcut(let binding):
                // Re-read the list per change: a batch may touch several rows, and
                // each write must land on the state its predecessors left behind.
                var list = PromptShortcutStore.current
                if let index = list.firstIndex(where: { $0.id == binding.id }) {
                    list[index] = binding
                } else {
                    list.append(binding)
                }
                PromptShortcutStore.save(list)
                NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
                // A freshly-settled prompt (created or edited here, or in Settings)
                // earns its AI display name once — `ensurePromptShortcutName` only
                // writes when a name is still missing.
                if binding.isReady { ensurePromptShortcutName(binding) }
            case .promptShortcutRemoval(let id):
                var list = PromptShortcutStore.current
                list.removeAll { $0.id == id }
                PromptShortcutStore.save(list)
                NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
            case .customInstructions(let value):
                customInstructions = value
            case .proxy(let value):
                proxyURL = value
            case .aiProvider(let provider):
                APIKeyStore.selectedProvider = provider
                refreshAI = true
            case .aiModel(let provider, let modelID):
                APIKeyStore.saveModel(modelID, for: provider)
                if !modelID.isEmpty { AskModelMRU.record(provider: provider, model: modelID) }
                refreshAI = true
            case .apiKey(let provider, let key):
                APIKeyStore.save(key, for: provider)
                refreshAI = true
            case .searchBackend(let backend):
                APIKeyStore.preferredSearchBackend = backend
                refreshAI = true
            case .searchAPIKey(let backend, let key):
                switch backend {
                case .exa:      APIKeyStore.saveExaKey(key)
                case .keenable: APIKeyStore.saveKeenableKey(key)
                case .anysearch: APIKeyStore.saveAnySearchKey(key)
                }
                refreshAI = true
            case .customProviderName(let value):
                CustomProvider.name = value
                refreshAI = true
            case .customProviderURL(let value):
                CustomProvider.baseURL = value
                refreshAI = true
            case .customProviderModel(let value):
                CustomProvider.model = value
                refreshAI = true
            }
        }
        if refreshAI {
            NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
        }
        return "Settings updated after confirmation: "
            + effective.map(\.summary).joined(separator: "; ") + "."
    }

    // MARK: - Notes & reminders (create_note / create_reminder)

    /// At most one capture can own a round's confirmation card. The harness runs a
    /// turn's tool calls concurrently, so two `create_note` calls in one turn would
    /// otherwise race two cards onto the same answer; the loser is told to file
    /// them one at a time and simply calls again next round.
    private var captureConfirmationAnswers: Set<UUID> = []

    /// Entry point injected into `CreateNoteTool` / `CreateReminderTool` for this
    /// answer round. Nothing is ever written on the model's say-so alone: the same
    /// in-answer card `ask_user` and `manage_app_settings` use shows the exact text
    /// (and, for a reminder, the exact due time) and only Confirm commits. The write
    /// itself then goes through the same services — and the same Recent row — as a
    /// hand-typed capture, so a note filed from chat is indistinguishable from one
    /// jotted into the notch.
    func handleCaptureRequest(answerID: UUID, request: CaptureRequest) async throws -> String {
        let line = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return "Error: there was no text to save." }
        guard line.count <= 4000 else {
            return "Error: that is too long to file. Keep it under 4000 characters."
        }

        // Resolve the due date BEFORE the card, so what the user approves is the
        // moment that will actually be filed — the card and the alarm can never
        // disagree. An explicit `due` wins; without one we fall back to the same
        // parsers a typed line goes through, so "每周一交周报" still repeats.
        var due: Date?
        if request.kind == .reminder {
            if let raw = request.due {
                guard let parsed = Self.parseCaptureDue(raw) else {
                    return "Error: could not read due=\"\(raw)\". Give the user's local time as YYYY-MM-DDTHH:MM."
                }
                guard parsed > Date() else {
                    return "Error: that due time is already past. Call current_datetime and pass a future local time."
                }
                due = parsed
            } else {
                due = RemindersService.futureDate(in: line)
                    ?? RemindersService.recurrenceDate(in: line)
            }
        }

        guard captureConfirmationAnswers.insert(answerID).inserted else {
            return "Error: another note or reminder is already awaiting confirmation in this answer. File them one at a time."
        }
        defer { captureConfirmationAnswers.remove(answerID) }

        let copy = captureConfirmationCopy(kind: request.kind, due: due)
        let choice = try await awaitUserChoice(
            answerID: answerID,
            question: copy.question + "\n" + line,
            options: [copy.cancel, copy.confirm],
            inlineOptions: true)
        guard choice == "The user chose: \"\(copy.confirm)\"" else {
            return "Cancelled. Nothing was saved."
        }

        switch request.kind {
        case .note:
            return await commitNoteCapture(line)
        case .reminder:
            return await commitReminderCapture(line, due: due)
        }
    }

    /// The confirmed note write, on whichever destination the user picked — Apple
    /// Notes or their Markdown folder. Same services, same Recent row as `submitNote`.
    private func commitNoteCapture(_ line: String) async -> String {
        if NoteDestination.current == .markdownFolder {
            let result: Result<String?, FileNotesError> = await withCheckedContinuation { cont in
                FileNotesService.writeNote(line) { cont.resume(returning: $0) }
            }
            switch result {
            case .success(let path):
                persistCapture(line, source: .note, link: path)
                return "Saved. The note was appended to the user's Markdown notes folder."
            case .failure(let err):
                return "Error: \(err.errorDescription ?? "couldn't write the note file.")"
            }
        }
        let result: Result<String?, NotesError> = await withCheckedContinuation { cont in
            NotesService.writeNote(line) { cont.resume(returning: $0) }
        }
        switch result {
        case .success(let noteID):
            persistCapture(line, source: .note, link: noteID)
            return "Saved. The note is now in the user's Apple Notes."
        case .failure(let err):
            return "Error: \(err.errorDescription ?? "couldn't save to Apple Notes.")"
        }
    }

    /// The confirmed reminder write. A `nil` due files a dateless reminder — it
    /// shows in the list without ringing, which is honest and better than refusing.
    private func commitReminderCapture(_ line: String, due: Date?) async -> String {
        let result: Result<String?, RemindersError> = await withCheckedContinuation { cont in
            RemindersService.createReminder(line, due: due) { cont.resume(returning: $0) }
        }
        switch result {
        case .success(let link):
            persistCapture(line, source: .reminder, link: link)
            guard let due else {
                return "Saved. The reminder is in the user's Reminders app, with no alarm time."
            }
            return "Saved. The reminder is in the user's Reminders app, due \(Self.captureDueDescription(due))."
        case .failure(let err):
            return "Error: \(err.errorDescription ?? "couldn't create the reminder.")"
        }
    }

    /// Parse the `due` the model wrote. Local wall-clock forms first (`2026-08-20T15:00`,
    /// `2026-08-20 15:00`, a bare day) — that is what the tool asks for and what a
    /// user means by "3pm" — then a full ISO-8601 stamp for models that insist on
    /// sending an offset. A bare day anchors to 9am, matching `recurrenceDate`.
    private static func parseCaptureDue(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let local = DateFormatter()
        local.locale = Foundation.Locale(identifier: "en_US_POSIX")
        local.timeZone = TimeZone.current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
                       "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        local.dateFormat = "yyyy-MM-dd"
        if let day = local.date(from: text) {
            return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: text)
    }

    /// The due time as the tool result states it back to the model — the user's
    /// locale and timezone, so a follow-up sentence quotes the same moment the
    /// card showed.
    private static func captureDueDescription(_ due: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        fmt.locale = localeForInterfaceLanguage()
        return fmt.string(from: due)
    }

    /// The interface language as a `Locale`, for the date strings this file shows
    /// the user (and states back to the model).
    private static func localeForInterfaceLanguage() -> Foundation.Locale {
        switch Localization.shared.language.resolved {
        case .en:     return Foundation.Locale(identifier: "en_US")
        case .zhHans: return Foundation.Locale(identifier: "zh_Hans")
        case .zhHant: return Foundation.Locale(identifier: "zh_Hant")
        case .ja:     return Foundation.Locale(identifier: "ja_JP")
        case .ko:     return Foundation.Locale(identifier: "ko_KR")
        case .fr:     return Foundation.Locale(identifier: "fr_FR")
        case .es:     return Foundation.Locale(identifier: "es_ES")
        }
    }

    /// Card copy for a capture confirmation, in the interface language. A reminder
    /// with a resolved time names it in the question, so the user approves the
    /// alarm and not just the words.
    private func captureConfirmationCopy(kind: CaptureRequest.Kind,
                                         due: Date?) -> (question: String, confirm: String, cancel: String) {
        let when = due.map { Self.captureDueDescription($0) }
        switch Localization.shared.language.resolved {
        case .zhHans:
            let q = kind == .note ? "保存这条备忘录？"
                : (when.map { "创建提醒，\($0) 提醒你？" } ?? "创建这条提醒？")
            return (q, "保存", "取消")
        case .zhHant:
            let q = kind == .note ? "儲存這則備忘錄？"
                : (when.map { "建立提醒，\($0) 提醒你？" } ?? "建立這則提醒？")
            return (q, "儲存", "取消")
        case .ja:
            let q = kind == .note ? "このメモを保存しますか？"
                : (when.map { "\($0) にリマインドしますか？" } ?? "このリマインダーを作成しますか？")
            return (q, "保存", "キャンセル")
        case .ko:
            let q = kind == .note ? "이 메모를 저장할까요?"
                : (when.map { "\($0)에 알릴까요?" } ?? "이 미리 알림을 만들까요?")
            return (q, "저장", "취소")
        case .fr:
            let q = kind == .note ? "Enregistrer cette note ?"
                : (when.map { "Créer un rappel pour le \($0) ?" } ?? "Créer ce rappel ?")
            return (q, "Enregistrer", "Annuler")
        case .es:
            let q = kind == .note ? "¿Guardar esta nota?"
                : (when.map { "¿Crear un recordatorio para el \($0)?" } ?? "¿Crear este recordatorio?")
            return (q, "Guardar", "Cancelar")
        case .en:
            let q = kind == .note ? "Save this note?"
                : (when.map { "Create a reminder for \($0)?" } ?? "Create this reminder?")
            return (q, "Save", "Cancel")
        }
    }

    /// Route canonical setting ids onto the category that owns their UI control.
    /// Kept beside the tool handler so adding a setting means adding its write and
    /// fallback destination in the same place.
    private static func appSettingsSection(for setting: String) -> String? {
        switch settingToken(setting) {
        case "model", "ai_provider", "ai_model", "api_key",
             "custom_provider_name", "custom_provider_url", "custom_provider_model",
             "custom_instructions":
            return "model"
        case "search", "search_backend", "search_api_key":
            // Search lives inside Model now — its rows are a group on that pane.
            return "model"
        case "capture", "notes", "note_destination", "notes_folder", "copy_sense",
             "selection_context":
            return "capture"
        case "general", "app_language", "launch_at_login", "dock_icon", "menu_bar_icon",
             "proxy":
            return "general"
        case "shortcuts", "summon_shortcut", "action_shortcut", "prompt_shortcut":
            return "shortcuts"
        case "appearance", "display_placement", "hide_in_fullscreen", "live_activity",
             "hover_sensitivity", "force_click":
            return "appearance"
        case "stats", "usage", "statistics":
            return "stats"
        case "about":
            return "about"
        default:
            return nil
        }
    }

    /// Open the inline Settings surface directly on one category. This is a
    /// navigation-only capability: it writes no preference and therefore never
    /// enters the confirmation path.
    @discardableResult
    private func openAppSettingsSection(_ requested: String) -> Bool {
        let section: InlineSettingsView.Section
        switch Self.settingToken(requested) {
        case "model":      section = .model
        case "capture":    section = .capture
        case "general":    section = .general
        case "appearance": section = .appearance
        case "shortcuts":  section = .shortcuts
        case "stats":      section = .stats
        case "about":      section = .about
        default: return false
        }
        settingsSection = section.rawValue
        openSettings()
        return true
    }

    /// A complete, secret-safe snapshot for questions such as "what are my app
    /// settings?". Stable ids and canonical values make it easy for the model to
    /// answer in the user's language without guessing how a localized UI label
    /// maps back onto a future update call.
    private func appSettingsSnapshot() -> String {
        let provider = APIKeyStore.selectedProvider
        let modelID = APIKeyStore.storedModel(for: provider)
        let shortcut = SummonHotKey.current
        let backend = APIKeyStore.preferredSearchBackend?.rawValue ?? "native"
        let providerKey = APIKeyStore.current(for: provider) == nil ? "not_configured" : "configured"
        let exaKey = APIKeyStore.currentExaKey() == nil ? "not_configured" : "configured"
        let keenableKey = APIKeyStore.currentKeenableKey() == nil ? "not_configured" : "configured"
        let anySearchKey = APIKeyStore.currentAnySearchKey() == nil ? "not_configured" : "configured"
        // Both shortcut families are scoped lists rather than scalars, so they
        // read the same way api_key/ai_model do: one line per addressable target.
        let actionShortcuts = AppShortcutAction.allCases.map {
            "action_shortcut[\($0.token)]=\(AppShortcutStore.chord(for: $0).displayString)"
        }
        let promptShortcuts = PromptShortcutStore.current.map { binding in
            let chord = binding.shortcut?.displayString ?? "unassigned"
            return "prompt_shortcut[\(chord)]=\(binding.prompt)"
        }
        return [
            "app_language=\(Self.languageToken(AppLanguage.current))",
            "dock_icon=\(DockIconVisibility.current.rawValue)",
            "menu_bar_icon=\(MenuBarIconVisibility.current.rawValue)",
            "launch_at_login=\(LaunchAtLogin.isEnabled)",
            "display_placement=\(Self.placementToken(DisplayPlacement.current))",
            "hide_in_fullscreen=\(HideNotchInFullscreen.isEnabled)",
            "live_activity=\(liveActivityEnabled)",
            "hover_sensitivity=\(HoverSensitivity.current.rawValue)",
            "note_destination=\(Self.noteDestinationToken(NoteDestination.current))",
            "notes_folder=\(FileNotesService.folderPath)",
            "copy_sense=\(copySenseEnabled)",
            "summon_shortcut=\(shortcut.enabled ? shortcut.displayString : "disabled")",
            "custom_instructions=\(customInstructions.isEmpty ? "(empty)" : customInstructions)",
            "proxy=\(proxyURL.isEmpty ? "auto" : proxyURL)",
            "ai_provider=\(Self.providerToken(provider))",
            "ai_model=\(modelID.isEmpty ? "default" : modelID)",
            "api_key[\(Self.providerToken(provider))]=\(providerKey)",
            "search_backend=\(backend)",
            "search_api_key[exa]=\(exaKey)",
            "search_api_key[keenable]=\(keenableKey)",
            "search_api_key[anysearch]=\(anySearchKey)",
            "custom_provider_name=\(CustomProvider.name.isEmpty ? "(empty)" : CustomProvider.name)",
            "custom_provider_url=\(CustomProvider.baseURL.isEmpty ? "(empty)" : CustomProvider.baseURL)",
            "custom_provider_model=\(CustomProvider.model.isEmpty ? "(empty)" : CustomProvider.model)",
        ].joined(separator: "\n")
        + "\n" + (actionShortcuts + promptShortcuts).joined(separator: "\n")
    }

    /// A localized, live reference for shortcut questions asked in chat. It is
    /// derived from the exact catalog rendered by Settings, so the model never
    /// needs to remember key combinations and the configurable summon chord is
    /// always the one the user currently has selected.
    private func appShortcutSnapshot() -> String {
        let reference = AppShortcutReference.groups().map { group in
            let entries = group.entries.map { entry in
                let binding = entry.chords.isEmpty
                    ? (entry.note ?? L("general.shortcut.off"))
                    : entry.chords.joined(separator: " \(L("shortcuts.or")) ")
                // Editable rows carry the id an update has to scope to; a fixed
                // row carries none, which is exactly what "not editable" means.
                let scope: String
                switch entry.editable {
                case .summon: scope = " [setting=summon_shortcut]"
                case .action(let action): scope = " [setting=action_shortcut scope=\(action.token)]"
                case .prompt, nil: scope = ""
                }
                return "- \(entry.label): \(binding)\(scope)"
            }
            return (["\(group.title):"] + entries).joined(separator: "\n")
        }.joined(separator: "\n\n")

        let prompts = PromptShortcutStore.current
        let promptLines: [String] = prompts.isEmpty
            ? ["(none)"]
            : prompts.map { binding in
                let chord = binding.shortcut?.displayString ?? L("general.shortcut.off")
                return "- \(chord): \(binding.prompt) [setting=prompt_shortcut scope=\(chord)]"
            }
        return reference + "\n\n"
            + (["\(L("shortcuts.promptAction")):"] + promptLines).joined(separator: "\n")
    }

    private func prepareAppSettingChange(
        _ raw: AppSettingsRequest.Change,
        defaultProvider: Provider
    ) throws -> PreparedAppSettingChange {
        let setting = Self.settingToken(raw.setting)
        let value = raw.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = raw.scope?.trimmingCharacters(in: .whitespacesAndNewlines)

        /// Each change is one plain sentence the user can read straight through —
        /// "Dock icon will change to Hidden" — not a `Label → value` pair. A `nil`
        /// display value means the field is being emptied, which is its own
        /// sentence: "will change to Clear" isn't a thing anyone says.
        func made(_ key: String, _ label: String, _ displayValue: String?,
                  _ payload: PreparedAppSettingChange.Payload,
                  noOp: Bool) -> PreparedAppSettingChange {
            let summary = displayValue.map { changeSentence(label, confirmationDisplay($0)) }
                ?? clearedSentence(label)
            return .init(key: key, summary: summary, payload: payload, isNoOp: noOp)
        }

        switch setting {
        case "app_language":
            guard let newValue = Self.parseLanguage(value) else {
                throw invalidValue(setting, "system, english, chinese_simplified, chinese_traditional, japanese, korean, french, or spanish")
            }
            return made(setting, L("general.appLanguage"), newValue.label,
                        .language(newValue), noOp: newValue == AppLanguage.current)

        case "dock_icon":
            guard let newValue = Self.parseDockVisibility(value) else {
                throw invalidValue(setting, "shown or hidden")
            }
            return made(setting, L("general.dockIcon"), newValue.label,
                        .dockIcon(newValue), noOp: newValue == DockIconVisibility.current)

        case "menu_bar_icon":
            guard let newValue = Self.parseMenuBarVisibility(value) else {
                throw invalidValue(setting, "shown or hidden")
            }
            return made(setting, L("general.menuBarIcon"), newValue.label,
                        .menuBarIcon(newValue), noOp: newValue == MenuBarIconVisibility.current)

        case "launch_at_login":
            guard let enabled = Self.parseBoolean(value) else { throw invalidBoolean(setting) }
            return made(setting, L("general.launchAtLogin"), localizedToggle(enabled),
                        .launchAtLogin(enabled), noOp: enabled == LaunchAtLogin.isEnabled)

        case "display_placement":
            guard let newValue = Self.parsePlacement(value) else {
                throw invalidValue(setting, "all or built_in")
            }
            return made(setting, L("general.showOn"), newValue.label,
                        .placement(newValue), noOp: newValue == DisplayPlacement.current)

        case "hide_in_fullscreen":
            guard let enabled = Self.parseBoolean(value) else { throw invalidBoolean(setting) }
            return made(setting, L("general.fullscreenAutoHide"), localizedToggle(enabled),
                        .hideInFullscreen(enabled), noOp: enabled == HideNotchInFullscreen.isEnabled)

        case "live_activity":
            guard let enabled = Self.parseBoolean(value) else { throw invalidBoolean(setting) }
            return made(setting, L("appearance.liveActivity"), localizedToggle(enabled),
                        .liveActivity(enabled), noOp: enabled == liveActivityEnabled)

        case "hover_sensitivity":
            guard let newValue = HoverSensitivity(rawValue: Self.settingToken(value)) else {
                throw invalidValue(setting, "low, balanced, or instant")
            }
            return made(setting, L("general.hoverSensitivity"), newValue.label,
                        .hoverSensitivity(newValue), noOp: newValue == HoverSensitivity.current)

        case "note_destination":
            guard let newValue = Self.parseNoteDestination(value) else {
                throw invalidValue(setting, "apple_notes or markdown_folder")
            }
            return made(setting, L("general.noteDestination"), newValue.label,
                        .noteDestination(newValue), noOp: newValue == NoteDestination.current)

        case "notes_folder":
            let path = (value as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else {
                throw AppSettingValidationError.message("notes_folder must be an absolute path.")
            }
            return made(setting, "Notes folder", (path as NSString).abbreviatingWithTildeInPath,
                        .notesFolder(path), noOp: path == FileNotesService.folderPath)

        case "copy_sense":
            guard let enabled = Self.parseBoolean(value) else { throw invalidBoolean(setting) }
            return made(setting, L("general.copySense"), localizedToggle(enabled),
                        .copySense(enabled), noOp: enabled == copySenseEnabled)

        case "summon_shortcut":
            guard let shortcut = Self.parseShortcut(value) else {
                throw invalidValue(setting, "disabled, default, double_option, double_command, double_control, double_shift, or a chord like command+shift+k")
            }
            return made(setting, L("general.shortcut"),
                        shortcut.enabled ? shortcut.displayString : L("general.shortcut.off"),
                        .shortcut(shortcut), noOp: shortcut == SummonHotKey.current)

        case "action_shortcut":
            guard let scoped, let action = AppShortcutAction.parse(scoped) else {
                throw AppSettingValidationError.message(
                    "action_shortcut requires scope=copy_answer, regenerate, pin, new_chat, filter, picker, or detach.")
            }
            if ["default", "reset", "restore"].contains(Self.settingToken(value)) {
                return made("\(setting)[\(action.token)]", action.label,
                            action.defaultChord.displayString, .actionShortcut(action, nil),
                            noOp: AppShortcutStore.chord(for: action) == action.defaultChord)
            }
            guard let chord = Self.parseChord(value) else {
                throw invalidValue(setting, "default or a chord like command+shift+c")
            }
            // The same validator the Shortcuts pane runs, so a chord the recorder
            // would reject can't slip in through chat instead.
            if let owner = AppShortcutStore.conflictOwner(for: chord, editingAction: action) {
                throw AppSettingValidationError.message(
                    "\(chord.displayString) is already used by \(owner).")
            }
            if let owner = Self.promptShortcutOwner(for: chord) {
                throw AppSettingValidationError.message(
                    "\(chord.displayString) is already used by the prompt shortcut “\(owner)”.")
            }
            return made("\(setting)[\(action.token)]", action.label, chord.displayString,
                        .actionShortcut(action, chord),
                        noOp: AppShortcutStore.chord(for: action) == chord)

        case "prompt_shortcut":
            return try preparePromptShortcut(value: value, scope: scoped, prompt: raw.prompt)

        case "custom_instructions":
            guard value.count <= Self.customInstructionsLimit else {
                throw AppSettingValidationError.message(
                    "custom_instructions is limited to \(Self.customInstructionsLimit) characters.")
            }
            return made(setting, L("general.customInstructions"), value.isEmpty ? nil : value,
                        .customInstructions(value), noOp: value == customInstructions)

        case "proxy":
            let cleared = ["", "auto", "automatic", "system", "default"].contains(Self.settingToken(value))
            guard cleared || ProxyConfig.normalize(value) != nil else {
                throw AppSettingValidationError.message(
                    "proxy must be auto or a valid HTTP/HTTPS/SOCKS proxy host or URL.")
            }
            let proxy = cleared ? "" : value
            return made(setting, L("network.proxy"), proxy.isEmpty ? "Auto" : proxy,
                        .proxy(proxy), noOp: proxy == proxyURL)

        case "ai_provider":
            guard let provider = Self.parseProvider(value) else {
                throw invalidValue(setting, "a supported provider id")
            }
            return made(setting, L("model.provider"), provider.displayName,
                        .aiProvider(provider), noOp: provider == APIKeyStore.selectedProvider)

        case "ai_model":
            let provider = try scopedProvider(scoped, defaultProvider: defaultProvider)
            let modelID = ["", "default", "automatic", "auto"].contains(Self.settingToken(value)) ? "" : value
            let shown = modelID.isEmpty ? "Default (\(provider.defaultModel))" : modelID
            return made("\(setting)[\(provider.rawValue)]", L("model.label"), shown,
                        .aiModel(provider, modelID),
                        noOp: modelID == APIKeyStore.storedModel(for: provider))

        case "api_key":
            let provider = try scopedProvider(scoped, defaultProvider: defaultProvider)
            guard !provider.isCLI else {
                throw AppSettingValidationError.message(
                    "\(provider.displayName) uses its signed-in CLI account, not an API key setting.")
            }
            guard !APIKeyStore.hasEnvOverride(for: provider) else {
                throw AppSettingValidationError.message(
                    "\(provider.displayName)'s API key is controlled by \(provider.envVarName), so the app setting cannot override it.")
            }
            let key = Self.isClearToken(value) ? "" : value
            let keyLabel = "\(provider.displayName) \(L("model.apiKey"))"
            // The key itself never appears in the confirmation, so a stored key
            // gets its own sentence rather than a value to "change to".
            return .init(key: "\(setting)[\(provider.rawValue)]",
                         summary: key.isEmpty ? clearedSentence(keyLabel) : keySetSentence(keyLabel),
                         payload: .apiKey(provider, key),
                         isNoOp: key == APIKeyStore.stored(for: provider))

        case "search_backend":
            guard let backend = Self.parseSearchBackend(value) else {
                throw invalidValue(setting, "native, keenable, exa, or anysearch")
            }
            let shown: String
            switch backend {
            case .exa:      shown = "Exa"
            case .keenable: shown = "Keenable"
            case .anysearch: shown = "AnySearch"
            case nil:       shown = L("search.backend.native")
            }
            return made(setting, L("search.backend"), shown, .searchBackend(backend),
                        noOp: backend == APIKeyStore.preferredSearchBackend)

        case "search_api_key":
            guard let backend = Self.parseConcreteSearchBackend(scoped ?? "") else {
                throw AppSettingValidationError.message(
                    "search_api_key requires scope=exa, scope=keenable, or scope=anysearch.")
            }
            let hasEnv: Bool
            switch backend {
            case .exa:       hasEnv = APIKeyStore.hasExaEnvOverride()
            case .keenable:  hasEnv = APIKeyStore.hasKeenableEnvOverride()
            case .anysearch: hasEnv = APIKeyStore.hasAnySearchEnvOverride()
            }
            guard !hasEnv else {
                throw AppSettingValidationError.message(
                    "The \(backend.rawValue) key is controlled by an environment variable, so the app setting cannot override it.")
            }
            let key = Self.isClearToken(value) ? "" : value
            let stored: String
            switch backend {
            case .exa:       stored = APIKeyStore.storedExaKey()
            case .keenable:  stored = APIKeyStore.storedKeenableKey()
            case .anysearch: stored = APIKeyStore.storedAnySearchKey()
            }
            let keyLabel = "\(backend.rawValue.capitalized) API key"
            return .init(key: "\(setting)[\(backend.rawValue)]",
                         summary: key.isEmpty ? clearedSentence(keyLabel) : keySetSentence(keyLabel),
                         payload: .searchAPIKey(backend, key), isNoOp: key == stored)

        case "custom_provider_name":
            return made(setting, L("model.custom.name"), value.isEmpty ? nil : value,
                        .customProviderName(value), noOp: value == CustomProvider.name)

        case "custom_provider_url":
            guard value.isEmpty || CustomProvider.normalized(value) != nil else {
                throw AppSettingValidationError.message("custom_provider_url is not a valid endpoint URL.")
            }
            return made(setting, L("model.custom.url"), value.isEmpty ? nil : value,
                        .customProviderURL(value), noOp: value == CustomProvider.baseURL)

        case "custom_provider_model":
            return made("ai_model[custom]", L("model.custom.model"), value.isEmpty ? nil : value,
                        .customProviderModel(value), noOp: value == CustomProvider.model)

        default:
            throw AppSettingValidationError.message("Unsupported app setting: \(raw.setting).")
        }
    }

    /// The one setting that carries two fields: a prompt shortcut is a chord
    /// *plus* the sentence it runs on the selection. Chat can create one, retarget
    /// an existing chord, rewrite its text, or delete it — every path lands on the
    /// same stored row the Shortcuts pane edits, and on the same validation.
    private func preparePromptShortcut(value: String, scope: String?,
                                       prompt: String?) throws -> PreparedAppSettingChange {
        let list = PromptShortcutStore.current
        let existing = try scope.map { try Self.resolvePromptShortcut($0, in: list) }
        let token = Self.settingToken(value)
        let label = L("shortcuts.promptAction")

        if ["remove", "delete", "off", "none", "clear"].contains(token) {
            guard let existing else {
                throw AppSettingValidationError.message(
                    "Removing a prompt shortcut needs scope set to its chord or a distinctive part of its prompt.")
            }
            let chord = existing.shortcut?.displayString ?? L("shortcuts.promptAction.set")
            return .init(key: "prompt_shortcut[\(existing.id)]",
                         summary: removedSentence("\(label) \(chord)"),
                         payload: .promptShortcutRemoval(existing.id), isNoOp: false)
        }

        var updated = existing ?? PromptShortcut()
        if !["keep", "same", "unchanged"].contains(token) {
            guard let chord = Self.parseChord(value) else {
                throw invalidValue("prompt_shortcut",
                                   "a chord like option+s, or keep, or remove")
            }
            if let owner = AppShortcutStore.conflictOwner(for: chord) {
                throw AppSettingValidationError.message(
                    "\(chord.displayString) is already used by \(owner).")
            }
            if let owner = Self.promptShortcutOwner(for: chord, excluding: updated.id) {
                throw AppSettingValidationError.message(
                    "\(chord.displayString) already runs the prompt shortcut \"\(owner)\".")
            }
            // A prompt shortcut is global, so the chord has to be one macOS will
            // actually hand over — the same probe the recorder runs.
            if existing?.shortcut != chord,
               !HotKey.isAvailable(keyCode: chord.keyCode, modifiers: chord.modifiers) {
                throw AppSettingValidationError.message(
                    "\(chord.displayString) is claimed by macOS or another app, so it cannot be registered.")
            }
            updated.shortcut = chord
        } else if existing == nil {
            throw AppSettingValidationError.message(
                "prompt_shortcut=keep only edits an existing binding; send a chord to create one.")
        }

        if let prompt { updated.prompt = prompt }
        guard !updated.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppSettingValidationError.message(
                "A new prompt shortcut needs `prompt`: the instruction the chord runs on the selected text.")
        }
        guard updated.prompt.count <= Self.customInstructionsLimit else {
            throw AppSettingValidationError.message(
                "A prompt shortcut is limited to \(Self.customInstructionsLimit) characters.")
        }
        let chord = updated.shortcut?.displayString ?? L("shortcuts.promptAction.set")
        return .init(key: "prompt_shortcut[\(updated.id)]",
                     summary: promptRunSentence("\(label) \(chord)",
                                                confirmationDisplay(updated.prompt)),
                     payload: .promptShortcut(updated), isNoOp: existing == updated)
    }

    private func scopedProvider(_ scope: String?, defaultProvider: Provider) throws -> Provider {
        guard let scope, !scope.isEmpty else { return defaultProvider }
        guard let provider = Self.parseProvider(scope) else {
            throw AppSettingValidationError.message("Unknown provider scope: \(scope).")
        }
        return provider
    }

    private func invalidValue(_ setting: String, _ expected: String) -> AppSettingValidationError {
        .message("Invalid value for \(setting); expected \(expected).")
    }

    private func invalidBoolean(_ setting: String) -> AppSettingValidationError {
        invalidValue(setting, "true or false")
    }

    /// User-provided free text belongs in the confirmation, but never as a
    /// multi-line pseudo-row that could visually impersonate another change.
    private func confirmationDisplay(_ raw: String) -> String {
        let singleLine = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard singleLine.count > 120 else { return singleLine }
        return String(singleLine.prefix(119)) + "…"
    }

    private func localizedToggle(_ enabled: Bool) -> String {
        switch Localization.shared.language.resolved {
        case .zhHans: return enabled ? "开启" : "关闭"
        case .zhHant: return enabled ? "開啟" : "關閉"
        case .ja:     return enabled ? "オン" : "オフ"
        case .ko:     return enabled ? "켬" : "끔"
        case .fr:     return enabled ? "Activé" : "Désactivé"
        case .es:     return enabled ? "Activado" : "Desactivado"
        case .en:     return enabled ? "On" : "Off"
        }
    }

    // MARK: - Confirmation sentences
    //
    // A pending change is written as one ordinary sentence — "Dock icon will
    // change to Hidden" — because the confirmation card reads as a question the
    // app is asking, not as a table of fields. Four shapes cover every setting:
    // a new value, an emptied field, a deleted binding, and a stored key (whose
    // value is never shown).

    private func changeSentence(_ label: String, _ value: String) -> String {
        switch Localization.shared.language.resolved {
        case .zhHans: return "\(label)将改为\(value)"
        case .zhHant: return "\(label)將改為\(value)"
        case .ja:     return "\(label)を\(value)に変更します"
        case .ko:     return "\(label)을 \(value)(으)로 변경합니다"
        case .fr:     return "\(label) passera à \(value)"
        case .es:     return "\(label) cambiará a \(value)"
        case .en:     return "\(label) will change to \(value)"
        }
    }

    private func clearedSentence(_ label: String) -> String {
        switch Localization.shared.language.resolved {
        case .zhHans: return "\(label)将被清空"
        case .zhHant: return "\(label)將被清空"
        case .ja:     return "\(label)を消去します"
        case .ko:     return "\(label)을 비웁니다"
        case .fr:     return "\(label) sera effacé"
        case .es:     return "\(label) se borrará"
        case .en:     return "\(label) will be cleared"
        }
    }

    private func removedSentence(_ label: String) -> String {
        switch Localization.shared.language.resolved {
        case .zhHans: return "\(label)将被删除"
        case .zhHant: return "\(label)將被刪除"
        case .ja:     return "\(label)を削除します"
        case .ko:     return "\(label)을 삭제합니다"
        case .fr:     return "\(label) sera supprimé"
        case .es:     return "\(label) se eliminará"
        case .en:     return "\(label) will be removed"
        }
    }

    private func keySetSentence(_ label: String) -> String {
        switch Localization.shared.language.resolved {
        case .zhHans: return "\(label)将被设置（密钥不会显示）"
        case .zhHant: return "\(label)將被設定（金鑰不會顯示）"
        case .ja:     return "\(label)を設定します（キーは表示しません）"
        case .ko:     return "\(label)을 설정합니다(키는 표시하지 않음)"
        case .fr:     return "\(label) sera enregistrée (clé masquée)"
        case .es:     return "\(label) se guardará (clave oculta)"
        case .en:     return "\(label) will be set (key hidden)"
        }
    }

    private func promptRunSentence(_ label: String, _ prompt: String) -> String {
        switch Localization.shared.language.resolved {
        case .zhHans: return "\(label) 将运行：\(prompt)"
        case .zhHant: return "\(label) 將執行：\(prompt)"
        case .ja:     return "\(label) は次を実行します：\(prompt)"
        case .ko:     return "\(label) 이(가) 다음을 실행합니다: \(prompt)"
        case .fr:     return "\(label) exécutera : \(prompt)"
        case .es:     return "\(label) ejecutará: \(prompt)"
        case .en:     return "\(label) will run: \(prompt)"
        }
    }

    private func appSettingsConfirmationCopy() -> (question: String, confirm: String, cancel: String) {
        switch Localization.shared.language.resolved {
        case .zhHans: return ("确认更改以下设置？", "确认", "取消")
        case .zhHant: return ("確認更改以下設定？", "確認", "取消")
        case .ja:     return ("次の設定を変更しますか？", "確認", "キャンセル")
        case .ko:     return ("다음 설정을 변경할까요?", "확인", "취소")
        case .fr:     return ("Confirmer ces changements ?", "Confirmer", "Annuler")
        case .es:     return ("¿Confirmar estos cambios?", "Confirmar", "Cancelar")
        case .en:     return ("Confirm these setting changes?", "Confirm", "Cancel")
        }
    }

    private static func settingToken(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func parseBoolean(_ raw: String) -> Bool? {
        switch settingToken(raw) {
        case "true", "on", "yes", "enabled", "enable", "show", "shown": return true
        case "false", "off", "no", "disabled", "disable", "hide", "hidden": return false
        default: return nil
        }
    }

    private static func parseLanguage(_ raw: String) -> AppLanguage? {
        switch settingToken(raw) {
        case "system", "auto", "default": return .system
        case "english", "en": return .english
        case "chinese_simplified", "simplified_chinese", "zh_hans": return .chineseSimplified
        case "chinese_traditional", "traditional_chinese", "zh_hant": return .chineseTraditional
        case "japanese", "ja": return .japanese
        case "korean", "ko": return .korean
        case "french", "fr": return .french
        case "spanish", "es": return .spanish
        default: return nil
        }
    }

    private static func languageToken(_ language: AppLanguage) -> String {
        switch language {
        case .system:             return "system"
        case .english:            return "english"
        case .chineseSimplified:  return "chinese_simplified"
        case .chineseTraditional: return "chinese_traditional"
        case .japanese:           return "japanese"
        case .korean:             return "korean"
        case .french:             return "french"
        case .spanish:            return "spanish"
        }
    }

    private static func parseDockVisibility(_ raw: String) -> DockIconVisibility? {
        switch settingToken(raw) {
        case "shown", "show", "visible", "on", "true": return .shown
        case "hidden", "hide", "invisible", "off", "false": return .hidden
        default: return nil
        }
    }

    private static func parseMenuBarVisibility(_ raw: String) -> MenuBarIconVisibility? {
        switch settingToken(raw) {
        case "shown", "show", "visible", "on", "true": return .shown
        case "hidden", "hide", "invisible", "off", "false": return .hidden
        default: return nil
        }
    }

    private static func parsePlacement(_ raw: String) -> DisplayPlacement? {
        switch settingToken(raw) {
        case "all", "all_screens", "every_screen": return .all
        case "built_in", "builtin", "main", "main_screen": return .builtIn
        default: return nil
        }
    }

    private static func placementToken(_ placement: DisplayPlacement) -> String {
        placement == .all ? "all" : "built_in"
    }

    private static func parseNoteDestination(_ raw: String) -> NoteDestination? {
        switch settingToken(raw) {
        case "apple_notes", "notes", "apple": return .appleNotes
        case "markdown_folder", "markdown", "folder", "files": return .markdownFolder
        default: return nil
        }
    }

    private static func noteDestinationToken(_ value: NoteDestination) -> String {
        value == .appleNotes ? "apple_notes" : "markdown_folder"
    }

    private static func parseProvider(_ raw: String) -> Provider? {
        switch settingToken(raw) {
        case "openrouter", "open_router": return .openrouter
        case "vercel": return .vercel
        case "openai", "open_ai": return .openai
        case "codex": return .codex
        case "claudecode", "claude_code": return .claudeCode
        case "grokcode", "grok_code": return .grokCode
        case "pi", "picode", "pi_code": return .piCode
        case "anthropic", "claude": return .anthropic
        case "gemini", "google": return .gemini
        case "deepseek", "deep_seek": return .deepseek
        case "qwen": return .qwen
        case "glm", "zhipu": return .glm
        case "kimi", "moonshot": return .kimi
        case "minimax", "mini_max": return .minimax
        case "mimo", "xiaomi": return .mimo
        case "custom", "custom_provider": return .custom
        default: return nil
        }
    }

    private static func providerToken(_ provider: Provider) -> String {
        switch provider {
        case .claudeCode: return "claude_code"
        case .grokCode:   return "grok_code"
        case .piCode:     return "pi_code"
        case .commandCode: return "command_code"
        default:          return provider.rawValue
        }
    }

    /// Optional search backends need a nested optional: nil means a recognized
    /// `native` request, while an outer nil means the text was invalid.
    private static func parseSearchBackend(_ raw: String) -> APIKeyStore.SearchBackend?? {
        switch settingToken(raw) {
        case "native", "default", "provider", "auto": return .some(nil)
        case "exa": return .some(.exa)
        case "keenable": return .some(.keenable)
        case "anysearch", "any_search": return .some(.anysearch)
        default: return nil
        }
    }

    private static func parseConcreteSearchBackend(_ raw: String) -> APIKeyStore.SearchBackend? {
        switch settingToken(raw) {
        case "exa": return .exa
        case "keenable": return .keenable
        case "anysearch", "any_search": return .anysearch
        default: return nil
        }
    }

    private static func isClearToken(_ raw: String) -> Bool {
        let token = settingToken(raw)
        return token.isEmpty || ["clear", "remove", "delete", "none"].contains(token)
    }

    private static func parseShortcut(_ raw: String) -> SummonHotKey? {
        let token = settingToken(raw)
        if ["disabled", "disable", "off", "none"].contains(token) {
            var shortcut = SummonHotKey.current
            shortcut.enabled = false
            return shortcut
        }
        if ["default", "double_option", "double_alt", "option_option"].contains(token) {
            return .defaultConfig
        }
        let doubles: [String: UInt32] = [
            "double_command": UInt32(cmdKey), "double_cmd": UInt32(cmdKey),
            "double_control": UInt32(controlKey), "double_ctrl": UInt32(controlKey),
            "double_shift": UInt32(shiftKey),
        ]
        if let modifier = doubles[token] {
            return SummonHotKey(keyCode: 0, modifiers: 0,
                                doubleTapModifier: modifier, enabled: true)
        }

        guard let chord = parseChord(raw) else { return nil }
        guard AppShortcutStore.conflictOwner(for: chord, editingSummon: true) == nil else {
            return nil
        }
        return SummonHotKey(keyCode: chord.keyCode, modifiers: chord.modifiers,
                            doubleTapModifier: 0, enabled: true)
    }

    /// Written chord → the Carbon pair the recorder would have produced. Accepts
    /// glyphs (`⌘⇧K`), words (`command+shift+k`), spaces or dashes as separators.
    /// `nil` when it names no real key or carries no real modifier — the same
    /// floor the Shortcuts pane enforces, so both entry paths accept exactly the
    /// same set of chords.
    private static func parseChord(_ raw: String) -> ShortcutChord? {
        var chord = raw.lowercased()
        let replacements = [
            "⌘": "command+", "⌥": "option+", "⌃": "control+", "⇧": "shift+",
            "cmd": "command", "alt": "option", "ctrl": "control",
        ]
        for (from, to) in replacements { chord = chord.replacingOccurrences(of: from, with: to) }
        chord = chord.replacingOccurrences(of: "-", with: "+")
        chord = chord.replacingOccurrences(of: " ", with: "+")
        let parts = chord.split(separator: "+").map(String.init).filter { !$0.isEmpty }
        guard let keyName = parts.last, let keyCode = shortcutKeyCode(keyName) else { return nil }
        var modifiers: UInt32 = 0
        for part in parts.dropLast() {
            switch part {
            case "command": modifiers |= UInt32(cmdKey)
            case "option":  modifiers |= UInt32(optionKey)
            case "control": modifiers |= UInt32(controlKey)
            case "shift":   modifiers |= UInt32(shiftKey)
            default: return nil
            }
        }
        let real = UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
        guard modifiers & real != 0 else { return nil }
        return ShortcutChord(keyCode: keyCode, modifiers: modifiers)
    }

    /// The prompt a chord is already bound to, if any — prompt shortcuts live in
    /// their own list, so `AppShortcutStore.conflictOwner` cannot see them.
    private static func promptShortcutOwner(for chord: ShortcutChord,
                                            excluding id: UUID? = nil) -> String? {
        PromptShortcutStore.current
            .first { $0.id != id && $0.shortcut == chord }
            .map { $0.prompt.isEmpty ? L("shortcuts.promptAction") : $0.prompt }
            .map { $0.count > 40 ? String($0.prefix(39)) + "…" : $0 }
    }

    /// Find the binding a `scope` selector points at: its id, its current chord,
    /// or a distinctive part of its prompt. Ambiguity throws rather than guessing
    /// which of the user's bindings to overwrite.
    private static func resolvePromptShortcut(_ selector: String,
                                              in list: [PromptShortcut]) throws -> PromptShortcut {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: trimmed), let hit = list.first(where: { $0.id == id }) {
            return hit
        }
        if let chord = parseChord(trimmed), let hit = list.first(where: { $0.shortcut == chord }) {
            return hit
        }
        let needle = trimmed.lowercased()
        let matches = list.filter { $0.prompt.lowercased().contains(needle) }
        if let only = matches.first, matches.count == 1 { return only }
        if matches.count > 1 {
            throw AppSettingValidationError.message(
                "scope \"\(trimmed)\" matches \(matches.count) prompt shortcuts; use the chord of the one you mean.")
        }
        throw AppSettingValidationError.message(
            "No prompt shortcut matches scope \"\(trimmed)\". Call action=shortcuts to see the existing ones.")
    }

    private static func shortcutKeyCode(_ raw: String) -> UInt32? {
        let named: [String: Int] = [
            "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return,
            "tab": kVK_Tab, "escape": kVK_Escape, "esc": kVK_Escape,
            "delete": kVK_Delete, "backspace": kVK_Delete,
            "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "up": kVK_UpArrow, "down": kVK_DownArrow,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4,
            "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
            "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        ]
        if let code = named[raw] { return UInt32(code) }
        let ansi: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, "[": kVK_ANSI_LeftBracket,
            "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "`": kVK_ANSI_Grave,
        ]
        return ansi[raw].map(UInt32.init)
    }

    // MARK: - Ask-the-user questions (the `ask_user` tool)

    /// One clarifying question the model posed mid-answer via the `ask_user` tool,
    /// waiting on the user to pick an option. Rendered as an option card under the
    /// streaming assistant turn it belongs to. Runtime-only — never persisted, so
    /// a saved conversation can't reopen onto a dead question.
    struct PendingUserQuestion: Identifiable, Equatable {
        let id: UUID
        /// The assistant turn (answer) this question interrupts — the card shows
        /// under that turn while it streams.
        let answerID: UUID
        let question: String
        let options: [String]
        /// Confirmation actions are compact peers and sit side by side. Ordinary
        /// clarifying answers can be longer, so they keep the stacked layout.
        let inlineOptions: Bool
    }

    /// Questions currently awaiting an answer, oldest first. Almost always 0 or 1
    /// (the tool is told to ask at most one per answer), but a detached round's
    /// unanswered question can coexist with a newer round's.
    @Published private(set) var pendingUserQuestions: [PendingUserQuestion] = []

    /// The suspended `ask_user` tool calls, keyed by question id. Resuming each
    /// exactly once is `resolveUserQuestion`'s job — every exit path (tap, timeout,
    /// round cancellation) funnels through it, and later calls for an already-
    /// resolved id are no-ops.
    private var userChoiceContinuations: [UUID: CheckedContinuation<String, Error>] = [:]

    /// How long an unanswered question waits before the round moves on without one.
    /// Long enough to answer at leisure (or hover a folded panel back open — the
    /// card survives reattach), short enough that a walked-away round still
    /// finishes, lands in Recent, and fires its notification.
    private static let userChoiceTimeout: TimeInterval = 120

    /// The question card to show under a streaming assistant turn, if any.
    func pendingQuestion(for answerID: UUID) -> PendingUserQuestion? {
        pendingUserQuestions.first { $0.answerID == answerID }
    }

    /// The user tapped an option on the card: feed it back as the tool result and
    /// let the suspended round continue.
    func chooseUserOption(_ option: String, questionID: UUID) {
        resolveUserQuestion(questionID, with: .success("The user chose: \"\(option)\""))
    }

    /// Suspend an `ask_user` tool call until the user picks an option. Publishes
    /// the question for the UI, parks the continuation, and arms the timeout; the
    /// user's tap, the timeout, or the round's cancellation resumes it — whichever
    /// comes first. Main-actor isolated (with the resolution paths), so the park
    /// and every resume are serialized and none can be lost.
    func awaitUserChoice(answerID: UUID, question: String, options: [String],
                         inlineOptions: Bool = false) async throws -> String {
        let questionID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                // Cancelled before we even parked (superseded while the tool call
                // was dispatched): don't surface a dead card.
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                userChoiceContinuations[questionID] = cont
                let pending = PendingUserQuestion(
                    id: questionID, answerID: answerID,
                    question: question, options: options,
                    inlineOptions: inlineOptions)
                pendingUserQuestions.append(pending)
                updateRuntimeTurn(answerID) { $0.pendingQuestion = pending }
                // Timeout backstop: an unanswered question (user walked away, panel
                // stayed closed) must not hang the round forever — resolve with an
                // explicit "no answer" the model is told to proceed on. Unstructured
                // on purpose: it must fire even after the round detaches, and it's a
                // no-op when the question resolved some other way first.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(Self.userChoiceTimeout * 1_000_000_000))
                    self?.resolveUserQuestion(questionID, with: .success(
                        "The user did not answer. Proceed with your best judgment and state the assumption you made."))
                }
            }
        } onCancel: {
            // Round superseded/cancelled while waiting — release the harness so its
            // own cancellation handling runs. Hop to the main actor; idempotent, so
            // racing a simultaneous tap or timeout is safe.
            Task { @MainActor [weak self] in
                self?.resolveUserQuestion(questionID, with: .failure(CancellationError()))
            }
        }
    }

    /// Resume a parked question exactly once and drop its card. Safe to call from
    /// every path (tap, timeout, cancel) — a second call for the same id finds no
    /// continuation and does nothing.
    private func resolveUserQuestion(_ questionID: UUID, with result: Result<String, Error>) {
        guard let cont = userChoiceContinuations.removeValue(forKey: questionID) else { return }
        let answerID = pendingUserQuestions.first(where: { $0.id == questionID })?.answerID
        pendingUserQuestions.removeAll { $0.id == questionID }
        if let answerID {
            updateRuntimeTurn(answerID) { $0.pendingQuestion = nil }
        }
        cont.resume(with: result)
    }

    /// The recurrence suffix shown live in the Remind hint *before* Enter (" \u{00B7} Daily"
    /// / " \u{00B7} Weekly \u{00B7} Mon" / " \u{00B7} Monthly"), so the user sees the recurrence
    /// was parsed while they can still correct it — anticipatory, not retrospective. Reads
    /// the same `recurrenceKind(in:)` the post-submit toast uses, off the live `text`.
    ///
    /// Gated on `effectiveSubmitPanel == .reminder` (so a Tab-override to Note/Ask drops
    /// it immediately) — and therefore only meaningful once the classifier has fired
    /// (~140ms after the keystroke). Empty for one-shot lines and non-reminders.
    ///
    /// NOTE: bare "weekly" (no named day) intentionally shows just " \u{00B7} Weekly" here —
    /// the repeat day is only resolved from the due date at file time, which the pre-Enter
    /// text alone can't know. The toast (which *has* the resolved `due`) shows the concrete
    /// day; the two diverge by design only in that one case.
    var submitHintSuffix: String {
        guard effectiveSubmitPanel == .reminder else { return "" }
        switch RemindersService.recurrenceKind(in: text) {
        case .daily:
            return L("recur.daily")
        case .weekly(let ekDay):
            if let ekDay {
                let dayIdx = ekDay.rawValue - 1   // EKWeekday 1-Sun…7-Sat \u{2192} 0-based
                return L("recur.weeklyOn", Calendar.current.shortWeekdaySymbols[dayIdx % 7])
            }
            return L("recur.weekly")
        case .monthly:
            return L("recur.monthly")
        case nil:
            return ""
        }
    }

    /// One past line written to Notes/Reminders this session, kept only to flash a
    /// brief confirmation under the record input. `nil` clears the cue.
    /// Not persisted — Notes/Reminders are the store of record; this is feedback.
    @Published var lastSavedNote: String? = nil
    /// Which app the flashed cue's line landed in, so the cue can say "Added to
    /// Reminders" vs "Added to Notes". Only meaningful while `lastSavedNote` is set.
    @Published var lastSavedToReminders = false
    /// Set when a note write fails (e.g. Automation permission not granted), so the
    /// record view can surface the recovery hint instead of silently dropping the
    /// line. Cleared on the next successful write or when the user edits the field.
    @Published var noteError: String? = nil
    /// True while a note write is in flight (the AppleScript runs off-thread and
    /// the first one waits on the TCC prompt), so the record view can show a quiet
    /// "Saving…" cue instead of looking like nothing happened on Enter.
    @Published var noteSaving = false

    /// Monotonic id for the *current* capture write (XII-117). `submitNote` /
    /// `submitReminder` bump this and capture the new value; their async callback
    /// only owns the shared UI state (`noteSaving`, `text`, `lastSavedNote`,
    /// `noteError`, the cue) when its captured id still equals this — i.e. it's
    /// the write that's actually in flight. A second capture fired inside the
    /// first's ~600ms AppleScript retry window supersedes it, so the first's
    /// late-arriving callback no longer clears the gate early, nor overwrites the
    /// second's success with its own (possibly failed) outcome, nor bounces an
    /// already-filed line back into the input via `reportCaptureFailure`. The
    /// superseded callback still persists its OWN Recent row (idempotent, its own
    /// data), so a successful write is never lost — only the shared cue is ceded.
    private var captureToken = 0

    /// A failed Ask, surfaced as an actionable error state instead of a blank spinner
    /// or a generic line (XII-85). Carries the real, human-readable reason (e.g.
    /// "Anthropic · HTTP 401") and whether the likely fix is to set up a key (no key
    /// configured) versus retry (transient/network). `nil` when there's no error.
    ///
    /// **Never read this directly for rendering or acting — use `visibleAskError`.**
    /// This is raw storage for the round that failed, and it outlives that round's
    /// time on screen (nothing clears it on `newChat` / `openHistory` /
    /// `attachInFlightRound` / a reopened parked session). Read unscoped, a failure
    /// in one conversation followed the user into every *other* conversation they
    /// opened: the stale "Try again" capsule took the place of that thread's
    /// follow-up input, and tapping it re-ran the innocent thread's last question.
    @Published var askError: AskError? = nil

    /// The shape of an Ask failure the result view renders into a capsule action.
    struct AskError: Equatable {
        /// The real reason, passed through from the service layer (not a generic
        /// string) so the user sees what actually happened.
        let message: String
        /// True when no model/key is configured — the action should be "open
        /// Settings" rather than "retry" (retrying without a key can't succeed).
        let needsSetup: Bool
        /// The assistant turn this failure belongs to — the round's own error
        /// bubble. What binds the error state to ONE conversation: the capsule only
        /// renders while that exact turn is the on-screen thread's (see
        /// `visibleAskError`), so switching threads leaves it behind.
        let answerID: UUID
    }

    /// The failure the result view may act on: `askError`, but only while the turn
    /// it belongs to is still the one on screen. Every navigation away (a new chat,
    /// reopening another Recent row, reattaching a detached round, restoring a
    /// parked session) swaps `turns`, so the id stops matching and the capsule
    /// disappears with the conversation that earned it — the follow-up input comes
    /// back for the thread the user is actually looking at. Reopening the failed
    /// thread brings it back (the error turn persists with its id), which is right:
    /// the retry belongs to that round.
    var visibleAskError: AskError? {
        guard let error = askError, isOnScreen(answerID: error.answerID) else { return nil }
        return error
    }

    /// The pasteboard's `changeCount` as of the last moment the notch was *resting*
    /// (closed, or a fresh chat) — i.e. the value from *before* the current open. An
    /// Ask injects the clipboard when the live count has moved past this baseline,
    /// which is the signal that the user copied something for *this* session and a
    /// referential query ("summarize this") is about the thing they just copied.
    ///
    /// Crucially this is the *pre-open* value, NOT the count at the instant the panel
    /// opened: the user's intended flow is copy-THEN-open, so by open time the copy
    /// has already bumped the count. Baselining at open would swallow exactly the copy
    /// we want to catch. Instead we carry forward the resting count (see
    /// `pasteboardChangeCountAtRest`), so a copy made while the notch was closed still
    /// reads as "new" once it opens. A count that hasn't moved since rest means the
    /// clipboard is stale relative to this session, so we leave it alone. Re-baselined
    /// on a new chat so our own handoff write can't leak back in.
    private var pasteboardChangeCountAtOpen = NSPasteboard.general.changeCount

    /// The pasteboard's `changeCount` while the notch is *resting* — refreshed every
    /// time it fully closes, so the next open can baseline against the count from
    /// before the user's copy-then-open. Seeded at construction so the very first
    /// open (copy → open, no prior close) still has a sane pre-copy reference: the
    /// count as of app launch. `openPanel` copies this into `pasteboardChangeCountAtOpen`
    /// on the closed→open edge.
    private var pasteboardChangeCountAtRest = NSPasteboard.general.changeCount

    /// The encoded images riding the current thread, so follow-ups still see every
    /// screenshot from the opening question. Keyed by thread id so attachments
    /// never leak across conversations.
    private var threadImages: (threadID: UUID, images: [ChatImage])? = nil

    /// The live conversation rendered in the result view — alternating user and
    /// assistant `Turn`s. A follow-up appends to this rather than replacing it, so
    /// the whole thread stays on screen and (via `submit`) in the model's context.
    /// Empty while idle; the first submit seeds the first user + assistant turns.
    /// Backed by `conversation` (see `ConversationStore`): streaming writes
    /// publish through the store, never through the model's `objectWillChange`,
    /// so surfaces that don't render the thread are never invalidated by a chunk.
    let conversation = ConversationStore()
    var turns: [Turn] {
        get { conversation.turns }
        set { conversation.turns = newValue }
    }

    /// The question shown in the result header — the *first* question of the
    /// thread, so the header labels the conversation as a whole. Empty when there's
    /// no conversation yet.
    var question: String { turns.first(where: { $0.role == "user" })?.text ?? "" }

    /// Whether a live backend is wired up (an API key is available for the
    /// selected provider). `false` means we're on the offline stub, in which case
    /// a follow-up can only ever return another placeholder — so the result view
    /// swaps the follow-up field for a "set up your model" call to action instead.
    /// Kept in sync by `AppDelegate` alongside `setService`.
    @Published var isConfigured = false

    @Published var showHistory = false {
        // Closing the recent list (from ANY of its 11+ callsites — fullClose,
        // newChat, collapseHistory, openHistory, settings, submit/submitNote/
        // submitReminder, …) drops any active filter, so reopening always starts on
        // the full unfiltered list. One didSet covers every path atomically.
        didSet {
            if !showHistory {
                historySearchQuery = ""
                showHistoryFilter = false
                historySourceFilter = nil
            }
        }
    }
    /// Whether the compact filter field is expanded below the RECENT header.
    /// Hidden by default so the list stays minimal; toggled from the filter icon.
    /// Cleared automatically when the list closes (see `showHistory`).
    @Published var showHistoryFilter = false
    /// Live substring filter for the recent list. Empty = show everything. Set by the
    /// `HistorySearchField` that appears above the rows once the list is long enough
    /// to need it; cleared automatically when the list closes (see `showHistory`).
    @Published var historySearchQuery = "" {
        // Filtering reshuffles which rows exist, so a stale keyboard highlight could
        // point at a now-hidden (or shifted) row. Release it on every query change;
        // the next ↓ re-selects row 0 of the freshly filtered slice.
        didSet {
            if historySearchQuery != oldValue { highlightedHistoryIndex = nil }
            if !historySearchQuery.isEmpty { noteUserTyping() }
            filteredHistoryCache = nil
            agentFilteredHistoryCache = nil
        }
    }
    /// Source filter for the recent list — `nil` shows everything. Set from the
    /// manage menu's filter chips (Note / Remind / Ask); cleared automatically
    /// when the list closes (see `showHistory`).
    @Published var historySourceFilter: HistoryItem.Source? = nil {
        // Same reasoning as `historySearchQuery`: filtering reshuffles which rows
        // exist, so a stale keyboard highlight could point at a hidden row.
        didSet {
            if historySourceFilter != oldValue { highlightedHistoryIndex = nil }
            filteredHistoryCache = nil
        }
    }
    /// Whether the inline settings panel is showing in place of the recent list.
    /// Replaces the old native Settings window — the gear (and ⌘,) flip this, and
    /// the idle view swaps the RECENT block for the settings form when it's true.
    @Published var showSettings = false
    /// The "What's New" release-notes panel — ⌘↵ (and the input-row cue) flip this.
    /// Like settings, it owns the whole idle body when true and the back chevron /
    /// Esc returns to the prompt. Mutually exclusive with `showSettings`.
    @Published var showWhatsNew = false
    /// Arms the destructive "Clear recent history?" confirmation. Lives on the
    /// model (not the view) so the Clear pill can raise it while the centered
    /// confirmation card is mounted on the *island* — so it sits in the middle of
    /// the whole glass panel rather than anchored under the pill near the bottom.
    @Published var confirmingClear = false
    /// The Force Click rung the user picked while macOS's own force-click lookup
    /// is still armed — held here, unapplied, until `ForceClickLookupDialog`
    /// gets an answer. Lives on the model (not `InlineSettingsView`) for the same
    /// reason `confirmingClear` does: the card is mounted on the *island*, so its
    /// scrim covers the whole glass panel instead of stopping at the settings
    /// body's bounds and leaving the panel's padding uncovered.
    @Published var forceClickLookupConflict: ForceClickPressure?
    /// The armed Force Click rung, mirrored so the Settings slider and the dialog
    /// (which now lives outside Settings) read and write one value.
    @Published var forceClickPressure: ForceClickPressure = .current

    /// Arm a rung, or hold it back. macOS's own force-click lookup listens for the
    /// very same press, so with both live a hard click opens the system's
    /// dictionary panel over ours — and there is no API to clear that preference,
    /// only to read it. So when it is on, the rung is held (the slider stays put)
    /// and `ForceClickLookupDialog` hands the user over to System Settings; every
    /// other case applies straight away.
    func selectForceClickPressure(_ newValue: ForceClickPressure) {
        guard newValue != forceClickPressure else { return }
        if newValue.isEnabled, SystemLookupGesture.usesForceClick {
            forceClickLookupConflict = newValue
            return
        }
        applyForceClickPressure(newValue)
    }

    func applyForceClickPressure(_ newValue: ForceClickPressure) {
        forceClickPressure = newValue
        ForceClickPressure.current = newValue
    }
    /// Armed for the length of a confirmed Clear, and read by the recent rows to
    /// pick their removal transition. A single right-click → Delete slides *one*
    /// row out sideways, which reads as "that one, gone"; the same motion played
    /// by five or twelve rows at once reads as a curtain wipe. So a bulk clear
    /// dissolves its rows in place instead and lets the gap close on the spring.
    ///
    /// It has to be a separate beat from the removal: SwiftUI takes a removal
    /// transition from the view's LAST render before it disappears, so setting
    /// this in the same transaction that empties the array would still play the
    /// single-delete slide.
    @Published var bulkClearing = false
    /// The open settings category (raw value of `InlineSettingsView.Section`),
    /// held here rather than as view-local `@State` so it survives the panel
    /// subtree rebuild an App Language switch triggers (root `.id(loc.language)`).
    /// Without this, switching language while in General would snap back to Model.
    @Published var settingsSection: String = "Model"
    /// Which recent row the keyboard has highlighted while navigating the list
    /// with ↑/↓. `nil` means nothing is highlighted yet — the list may be open
    /// (revealed by mouse) but the caret is still in the input. The first ↓
    /// promotes this to `0`. Indexes into the *visible* slice (`recentVisible`).
    @Published var highlightedHistoryIndex: Int? = nil
    @Published private(set) var history: [HistoryItem] = [] {
        // The archive is one of the three inputs of `filteredHistory` — see the
        // cache note there.
        didSet {
            filteredHistoryCache = nil
            agentFilteredHistoryCache = nil
        }
    }

    /// Shell-style ↑/↓ history recall cursor for the idle prompt. `nil` means no
    /// recall session is in flight (the user is editing normally). Once ↑ pulls a
    /// past question into the box this holds the index into `recallQuestions` (the
    /// dedup'd list, NOT raw `history`) that's shown, so a further ↑ steps older and
    /// ↓ steps newer. Any real keystroke resets it to `nil` (see `text.didSet`), so
    /// recall never fights live editing.
    private var historyRecallIndex: Int? = nil

    /// The question strings ↑/↓ recall walks, newest first — the active bucket's
    /// `history` values with **adjacent duplicates collapsed** (bash `ignoredups`). Asking the
    /// same thing twice in a row leaves one entry here, so ↑ never fills the same
    /// line twice running and the "x / total" counter counts distinct consecutive
    /// questions. Non-adjacent repeats (asked A, then B, then A again) are kept —
    /// only *consecutive* duplicates fold, matching "连续两条相同" exactly.
    private var recallQuestions: [String] {
        var out: [String] = []
        for item in history where
            (agentComposeActive ? item.source == .agent : item.source != .agent) {
            // `history` is newest-first; recall stays inside the active bucket.
            if out.last != item.q { out.append(item.q) }
        }
        return out
    }
    /// Set while `recallPreviousQuestion`/`recallNextQuestion` write `text`
    /// themselves, so the `text.didSet` reset doesn't mistake the recall's own fill
    /// for the user typing and immediately cancel the session.
    private var isRecallingText = false
    /// Whether a ↑/↓ recall session is currently active — the idle prompt's
    /// `PromptField` uses this to keep routing ↑/↓ to recall even after the box is
    /// no longer empty (so "press ↑ again to go further back" works).
    var isRecallingHistory: Bool { historyRecallIndex != nil }

    /// Where the ↑/↓ recall cursor currently sits, for the little "3 / 12" counter
    /// the idle prompt shows in place of the clipboard quote while recalling.
    /// `pos` is 1-based (newest = 1); `total` is the history depth, both capped at
    /// 99 so the readout never overflows its slot. `nil` when no recall is active.
    var recallPosition: (pos: Int, total: Int)? {
        guard let i = historyRecallIndex else { return nil }
        return (min(i + 1, 99), min(recallQuestions.count, 99))
    }

    /// A tick that bumps on every successful ↑/↓ recall step, carrying the step's
    /// direction. The idle input row observes it to fire a small directional
    /// slide-in as the recalled question swaps in: `.older` (↑) slides down from
    /// above, `.newer` (↓) slides up from below. Purely a view cue — never
    /// persisted, and it doesn't gate any behaviour.
    enum RecallDirection { case older, newer }
    @Published private(set) var recallPulse: (n: Int, dir: RecallDirection) = (0, .older)
    private func pulseRecall(_ dir: RecallDirection) {
        recallPulse = (recallPulse.n + 1, dir)
    }

    /// How many recent rows the *notch* list keeps — the compact quick-access slice.
    /// The full archive is retained on disk without limit (see `saveHistory`); the
    /// notch stays light by rendering only the newest `notchRecentCap`. Everything
    /// older is one click away in the standalone History window (`archiveVisible`).
    static let notchRecentCap = 100

    /// The recent items rendered in the *notch* list — the newest `notchRecentCap`
    /// of the (filtered) history, not the whole archive. The list scrolls, and
    /// keyboard nav auto-scrolls the highlight into view, so every visible item is
    /// reachable. Keyboard navigation indexes into THIS, so highlight bounds and the
    /// rendered rows can never drift apart. Older items live in the History window.
    ///
    /// A run whose task is still in the agent tray is already on screen as its
    /// status row (settled card, or a live re-run), directly above this list —
    /// so its filed record is held back here rather than stacking the same title
    /// twice. Dismissing the card reveals the record row; the archive window
    /// (`archiveVisible`) never hides it. (Freshness rides on views also
    /// observing `AgentTaskManager`, whose task changes re-render them.)
    var recentVisible: [HistoryItem] {
        let trayIDs = Set(AgentTaskManager.shared.tasks.map(\.id))
        guard !trayIDs.isEmpty else {
            return Array(recentFilteredHistory.prefix(NotchModel.notchRecentCap))
        }
        return Array(recentFilteredHistory.lazy.filter { !trayIDs.contains($0.id) }
            .prefix(NotchModel.notchRecentCap))
    }

    /// The FULL filtered history, newest-first — every retained item, uncapped.
    /// Backs the standalone History window so nothing captured is ever out of reach.
    var archiveVisible: [HistoryItem] { filteredHistory }

    /// Settled conversations created by the Force Touch popup, newest first.
    /// This is the popup's private drawer rather than another Chat/Agent bucket,
    /// so it never inherits those surfaces' search or source filters.
    var forceTouchHistory: [HistoryItem] {
        history.filter { $0.origin == .forceTouch && !$0.pending && $0.source.isThread }
    }

    /// The unsearched size of the bucket currently owning Recent. Agent compose
    /// sees only agent conversations; Chat owns Ask / Notes / Reminders.
    /// Footer affordances use this instead of the global archive count so an Agent
    /// list never advertises rows that are outside its scope.
    var recentScopeHistoryCount: Int {
        history.lazy.filter { item in
            self.agentComposeActive ? item.source == .agent : item.source != .agent
        }.count
    }

    /// Memoized `filteredHistory`, invalidated by the didSets of its only three
    /// inputs (`history`, `historySourceFilter`, `historySearchQuery`). The filter
    /// walks the whole archive — which is unbounded and grows with months of use —
    /// while `recentVisible` is read several times per NotchBody body evaluation,
    /// so without the memo every unrelated re-render re-filtered the full archive.
    private var filteredHistoryCache: [HistoryItem]? = nil

    /// Separate because Agent ignores the Ask-side source filter while sharing its
    /// text query. Keeping two caches prevents the standalone archive / Ask ledger
    /// from inheriting Agent's implicit source scope.
    private var agentFilteredHistoryCache: [HistoryItem]? = nil

    private var recentFilteredHistory: [HistoryItem] {
        if agentComposeActive {
            if let cached = agentFilteredHistoryCache { return cached }
            var items = history.filter { $0.source == .agent }
            if !historySearchQuery.isEmpty {
                items = items.filter {
                    $0.displayTitle.localizedCaseInsensitiveContains(historySearchQuery)
                }
            }
            agentFilteredHistoryCache = items
            return items
        }

        // Chat is a sibling bucket, not the old all-source ledger: Agent rows
        // never bleed into it. The optional source filter can only narrow within
        // Ask / Notes / Reminders.
        return filteredHistory.filter { $0.source != .agent }
    }

    /// The global filter pipeline retained for the standalone all-history archive.
    /// The notch's two bucket scopes live in `recentFilteredHistory`.
    private var filteredHistory: [HistoryItem] {
        if let cached = filteredHistoryCache { return cached }
        var items = history
        if let source = historySourceFilter {
            items = items.filter { $0.source == source }
        }
        if !historySearchQuery.isEmpty {
            items = items.filter {
                $0.displayTitle.localizedCaseInsensitiveContains(historySearchQuery)
            }
        }
        filteredHistoryCache = items
        return items
    }

    // MARK: - Archive as context (search_history)

    /// Answer one `search_history` call: the slice of the user's own archive the
    /// model asked for, flattened to the digest rows it actually reads.
    ///
    /// Deliberately NOT `filteredHistory`: that pipeline serves the on-screen list
    /// (its inputs are the UI's own filter chips, and its text match only looks at
    /// `displayTitle`, so a keyword that appears in the body of a note finds
    /// nothing). This one is a real content search over the whole row, and it must
    /// never be perturbed by — or perturb — whatever the user has typed into the
    /// Recent filter field.
    ///
    /// Two rows are always withheld:
    ///  • **`pending`** — the question being answered right now is parked in
    ///    `history` the instant it's submitted (`parkPending`), so without this the
    ///    model would find the very question it is currently answering and report
    ///    it back as a past activity.
    ///  • **the thread on screen** — already in the wire context verbatim; the tool
    ///    exists for what's *outside* the current conversation.
    func searchArchive(_ query: HistoryQuery) -> HistoryDigest {
        Self.archiveDigest(query, in: history, currentThread: threadHistoryID)
    }

    /// The query itself, as a pure function of (request, rows) — so it can be
    /// exercised against fixtures and against a real `history.json` without
    /// standing up a `NotchModel` (see `scripts/history_eval`). `nonisolated`
    /// because nothing here touches this object's state: the two rows the instance
    /// method withholds are passed in, not read.
    nonisolated static func archiveDigest(_ query: HistoryQuery,
                                          in items: [HistoryItem],
                                          currentThread: UUID?) -> HistoryDigest {
        let cal = Calendar.current
        // `until` names a whole day, so the bound is the START of the following day
        // and the comparison is strictly-less — otherwise "until today" would drop
        // everything after 00:00 today, i.e. all of today.
        let lowerBound = query.since.map { cal.startOfDay(for: $0) }
        let upperBound = query.until
            .flatMap { cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: $0)) }

        let matches = items.lazy.filter { item in
            guard !item.pending else { return false }
            guard item.id != currentThread else { return false }
            if let kind = query.kind, item.source.rawValue != kind { return false }
            if let lower = lowerBound, item.t < lower { return false }
            if let upper = upperBound, item.t >= upper { return false }
            guard let needle = query.text, !needle.isEmpty else { return true }
            return item.matchesArchiveSearch(needle)
        }

        // `history` is maintained newest-first (every write inserts at 0), but sort
        // explicitly rather than lean on that — the digest states "newest first" to
        // the model, and a row that ever lands out of order would make it misread
        // the chronology it's summarizing.
        let ordered = matches.sorted { $0.t > $1.t }
        // The full match count rides along, not just the capped slice: it's what
        // lets the digest admit it was truncated (see `HistoryDigest`).
        return HistoryDigest(rows: ordered.prefix(query.limit).map(\.digestRow),
                             totalMatches: ordered.count)
    }

    private var ai: AIService
    private var task: Task<Void, Never>?
    /// Detached prompt-shortcut rounds leave the panel's `task` slot so they can
    /// stream headlessly. Keep their handles by thread id so a repeated shortcut
    /// can supersede its previous translation in the same compact window.
    private var compactRoundTasks: [UUID: Task<Void, Never>] = [:]
    /// Holds the auto-dismiss timer for the "Saved to Notes" cue so a rapid second
    /// save cancels the first one's fade rather than letting them overlap.
    private var noteCueTask: Task<Void, Never>?
    /// The legacy UserDefaults key the archive used to live under. Only read for
    /// the one-time migration to the archive file (see `readHistoryFromDisk`);
    /// never written anymore.
    private static let historyKey = "notch_history"

    /// Stable id for the conversation currently on screen, so a follow-up updates
    /// the *same* recent-list row instead of inserting a new one each turn. Reset
    /// whenever a fresh thread begins (first question, new chat, reopened item).
    private var threadHistoryID = UUID()

    init(ai: AIService = StubAIService()) {
        self.ai = ai
        loadHistoryAsync()
        startClipboardSense()
        refreshAgentSkills()
        // A debounced archive write may still be pending when the user quits;
        // flush it synchronously so a ⌘Q moments after an answer can't lose the
        // newest row.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushHistorySave() }
        }
        // The other half of `rearmPersistedAgentBucket`'s "not yet" rule: it declines
        // to judge a restored bucket while the CLI probes are still in flight, so the
        // moment they land it has to be asked again — otherwise an engine that really
        // did go away would stay armed for the whole session.
        NotificationCenter.default.addObserver(
            forName: .cliAvailabilityResolved, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rearmPersistedAgentBucket() }
        }
    }

    deinit {
        senseTimer?.invalidate()
        agentSkillsTask?.cancel()
    }

    /// Swap the backend at runtime — used when the user saves an API key in
    /// Settings, so the next question goes live without an app restart.
    func setService(_ service: AIService) {
        ai = service
    }

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - Handoff

    /// Compress the on-screen conversation into a single portable block the user can
    /// paste into a full chat (ChatGPT, Claude, …) to pick up exactly where the
    /// notch left off — copied to the clipboard so the handoff is one click. Plain
    /// Q/A transcript with a short framing line; no app-specific markup so it drops
    /// cleanly into any assistant.
    @discardableResult
    func copyHandoffContext() -> String {
        var lines = ["Here's a conversation I'd like to continue. Please pick up from the last answer.\n"]
        var round = 0
        for turn in turns {
            let body = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            if turn.role == "user" {
                round += 1
                lines.append("Q\(round): \(body)")
            } else {
                lines.append("A\(round): \(body)\n")
            }
        }
        let text = lines.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return text
    }

    /// Re-sync the clipboard baseline after Notch itself wrote to the pasteboard
    /// from *within* an open panel — e.g. the per-code-block copy button. Without
    /// this, that in-app write bumps `changeCount` past `pasteboardChangeCountAtOpen`,
    /// and `clipboardContextIfEligible()` would then mistake the user's own just-copied
    /// code for "something they copied to ask about" and silently inject it into the
    /// next Ask. Same one-line re-baseline `newChat()` uses after a handoff copy.
    func rebaselineClipboardAfterInAppWrite() {
        pasteboardChangeCountAtOpen = NSPasteboard.general.changeCount
        senseLastChangeCount = pasteboardChangeCountAtOpen
    }

    // MARK: - Clipboard sense (copy → hint on the resting notch → ⌘C again to file)

    /// The copy-sense lifecycle, rendered by the resting notch's left extension
    /// (the same strip the busy dots use). `hinting` = the copied text read as a
    /// note/reminder and the notch is offering it — press ⌘C again to file it.
    /// `saving`/`saved`/`failed` narrate the write after a confirm. Every stage is
    /// only *visible* while the panel is closed; opening the panel hands the same
    /// clip to the in-panel capture chip instead.
    enum ClipboardSense: Equatable {
        case idle
        case hinting(panel: Panel)
        case saving(panel: Panel)
        case saved(panel: Panel)
        case failed
    }
    @Published private(set) var clipboardSense: ClipboardSense = .idle

    /// Whether the resting notch watches the clipboard at all (Settings → Tools).
    /// On by default; turning it off tears down any visible hint immediately. The
    /// in-panel capture chip is unaffected — this only governs the closed-notch
    /// pre-sensing.
    @Published var copySenseEnabled: Bool =
        UserDefaults.standard.object(forKey: NotchModel.copySenseKey) as? Bool ?? true
    {
        didSet {
            UserDefaults.standard.set(copySenseEnabled, forKey: NotchModel.copySenseKey)
            if !copySenseEnabled { senseReset() }
        }
    }
    private static let copySenseKey = "copySenseEnabled"

    /// Whether background work drives the RESTING notch's busy ears (Settings →
    /// Appearance, "Live activity"). Agent runs are minutes long, so the
    /// verb-and-clock flex is the one background readout that stays on screen
    /// while you work in another app — some people want the notch to hold still
    /// instead. One global switch for everything live: off keeps the closed notch
    /// flat for agent runs AND detached Ask rounds alike. The finished-count
    /// badge, the agent card and the completion notification are all unaffected.
    @Published var liveActivityEnabled: Bool =
        UserDefaults.standard.object(forKey: NotchModel.liveActivityKey) as? Bool ?? true
    {
        didSet {
            UserDefaults.standard.set(liveActivityEnabled,
                                      forKey: NotchModel.liveActivityKey)
        }
    }
    /// Legacy key name, kept so the setting survives the agent-only → global move.
    private static let liveActivityKey = "agentNotchActivityEnabled"

    /// Whether the assistant's answers are written by hand instead of typeset
    /// (Settings → Appearance, "Handwritten answers"). Off by default — the
    /// printed voice stays the thing you get without asking.
    ///
    /// Scope is deliberately narrow: the assistant's own prose, and nothing else.
    /// The question you typed, the interface around it, notes, code blocks and
    /// every copied string are untouched, so the mode changes how the answer
    /// *reads* and never what it *is*. See `Handwriting`.
    @Published var handwrittenAnswers: Bool =
        UserDefaults.standard.bool(forKey: Handwriting.defaultsKey)
    {
        didSet {
            UserDefaults.standard.set(handwrittenAnswers, forKey: Handwriting.defaultsKey)
        }
    }

    /// The proxy Notch connects through (Settings → General) — the app's own
    /// requests and the spawned agent CLIs alike. Empty means auto — the app
    /// follows the system proxy natively, and `ProxyConfig` walks the CLIs through
    /// the inherited env, the system proxy, then the login shell. Storage and
    /// resolution live in `ProxyConfig`; this only publishes the field the
    /// settings row binds to.
    @Published var proxyURL: String = ProxyConfig.manual {
        didSet { ProxyConfig.manual = proxyURL }
    }

    /// A one-line personal preference the user set in Settings (XII-137), appended
    /// after the built-in persona on the Ask path — "always answer in English",
    /// "I'm a developer, prefer code", "use metric units". Empty = zero behaviour
    /// change (the default). Capped at `customInstructionsLimit` chars so it can't
    /// bloat the prompt and slow first token. Persisted in UserDefaults.
    static let customInstructionsLimit = 200
    @Published var customInstructions: String =
        UserDefaults.standard.string(forKey: NotchModel.customInstructionsKey) ?? ""
    {
        didSet {
            // Enforce the cap defensively (the field also limits input) and persist.
            if customInstructions.count > NotchModel.customInstructionsLimit {
                customInstructions = String(customInstructions.prefix(NotchModel.customInstructionsLimit))
                return   // the reassignment re-enters didSet, which persists
            }
            UserDefaults.standard.set(customInstructions, forKey: NotchModel.customInstructionsKey)
        }
    }
    private static let customInstructionsKey = "customInstructions"

    /// Background sensing must earn its interruption: it is now the only place
    /// the engine gets a say at all, and a hint that lights up the closed notch on
    /// every copy needs a strong read. Below this the background default is
    /// *nothing* — and even above it the hint only offers; the user still presses
    /// ⌘C again to file. Nothing is ever routed on a guess.
    static let senseActionFloor = 0.55

    /// How long a hint stays up with no response before it fades on its own.
    private static let senseHintTimeout: TimeInterval = 5.0

    /// The minimum gap between the hint appearing and a re-copy that counts as a
    /// confirm. People habitually double-tap ⌘C "to make sure it copied" — those
    /// land well under this; a real "saw the hint, pressed again" can't. A re-copy
    /// faster than this refreshes the hint instead of firing it.
    private static let senseMinReaction: TimeInterval = 0.6

    /// Poll cadence for the resting watcher. Each tick is one `changeCount` read
    /// (an Int, no content access) unless the count actually moved.
    private static let senseTickInterval: TimeInterval = 0.3

    private var senseTimer: Timer?
    /// The last `changeCount` the watcher has accounted for. While the panel is
    /// open every tick just re-syncs this, so copies made in-session (including
    /// Notch's own pasteboard writes) can never read as new once the panel closes.
    private var senseLastChangeCount = NSPasteboard.general.changeCount
    /// The clip the current hint is about — a re-copy must match it exactly.
    private var senseClip: String?
    /// When the current hint appeared (the `senseMinReaction` anchor).
    private var senseHintShownAt: Date?
    /// The clip a sense confirm has (or is currently) filing — suppresses both a
    /// re-hint and the in-panel capture chip for the same text, so one copied line
    /// can't be filed twice. Cleared if the write fails (the chip then returns as
    /// the retry path — the text is still safe in the clipboard).
    private var senseCapturedClip: String?
    /// True once a read was attempted while the system's pasteboard-privacy state
    /// is `ask`/`default` (macOS 15.4+). One attempt lets the system surface its
    /// access alert so the user can decide; after that the watcher stays quiet
    /// until Settings says always-allow, instead of prompting on every copy.
    private var senseAskAttempted = false
    private var senseClassifyTask: Task<Void, Never>?
    private var senseDismissTask: Task<Void, Never>?

    /// Start the resting watcher (called once from `init`). `.common` mode so a
    /// tracked menu or drag doesn't starve the tick; generous tolerance because
    /// nothing here needs frame accuracy.
    private func startClipboardSense() {
        let t = Timer(timeInterval: Self.senseTickInterval, repeats: true) { [weak self] _ in
            // Scheduled on RunLoop.main, so the fire is always on the main
            // thread — assume (not hop to) the actor to keep the tick synchronous.
            MainActor.assumeIsolated { self?.senseTick() }
        }
        t.tolerance = Self.senseTickInterval / 2
        RunLoop.main.add(t, forMode: .common)
        senseTimer = t
    }

    private func senseTick() {
        let pb = NSPasteboard.general
        // Panel open: the in-panel clipboard flow owns the pasteboard. Track the
        // count so nothing copied (or written by us) in-session triggers a hint
        // after close.
        guard !open else {
            senseLastChangeCount = pb.changeCount
            return
        }
        // Disabled still tracks the count, so re-enabling can't hint on some
        // long-stale copy made while the switch was off.
        guard copySenseEnabled else {
            senseLastChangeCount = pb.changeCount
            return
        }
        let count = pb.changeCount
        guard count != senseLastChangeCount else {
            senseExpireHintIfStale()
            return
        }
        senseLastChangeCount = count

        guard let clip = senseReadClipboard() else {
            // The clipboard moved to something we won't touch (empty, oversized,
            // concealed, denied…) — any hint about the previous clip is stale.
            senseCancelHint()
            return
        }
        // A write is narrating (saving/saved/failed) — the strip is spoken for.
        // New copies during that beat just pass through unsensed.
        switch clipboardSense {
        case .saving, .saved, .failed:
            return
        case .hinting(let panel) where clip == senseClip:
            // The same text copied again while its hint is up. Fast enough to be a
            // habitual double-tap → refresh the hint; a beat later → the confirm.
            if let shown = senseHintShownAt,
               Date().timeIntervalSince(shown) >= Self.senseMinReaction {
                senseConfirm(clip: clip, panel: panel)
            } else {
                senseHintShownAt = Date()
            }
        default:
            senseClassify(clip)
        }
    }

    /// Read the pasteboard for sensing, or `nil` for anything the background
    /// watcher must not touch. Stricter than `clipboardContextIfEligible`: only a
    /// plain string (a bare URL or file path is never a note), never anything a
    /// password manager marked concealed/transient, and never while the system's
    /// pasteboard-privacy setting denies programmatic reads.
    private func senseReadClipboard() -> String? {
        guard senseClipboardAccessAllowed() else { return nil }
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        let offLimits = ["org.nspasteboard.ConcealedType",
                         "org.nspasteboard.TransientType",
                         "org.nspasteboard.AutoGeneratedType"]
        guard !offLimits.contains(where: { types.contains(NSPasteboard.PasteboardType($0)) })
        else { return nil }
        guard let raw = pb.string(forType: .string) else { return nil }
        let clip = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clip.count >= 2, clip.count <= 1500 else { return nil }
        // Text this app itself produced (a parked draft, a copied answer) is not
        // a jot the user wants filed back at them.
        guard !isCurrentSessionText(clip) else { return nil }
        return clip
    }

    /// Gate content reads on the system pasteboard-privacy state (macOS 15.4+).
    /// `alwaysAllow` senses freely; `alwaysDeny` never reads; `ask`/`default` get
    /// exactly one attempt per app session — enough for the system to show its
    /// consent alert once, never a prompt-per-copy drip.
    private func senseClipboardAccessAllowed() -> Bool {
        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow:
                return true
            case .alwaysDeny:
                return false
            case .default, .ask:
                if senseAskAttempted { return false }
                senseAskAttempted = true
                return true
            @unknown default:
                return false
            }
        }
        return true
    }

    /// Classify a fresh copy and raise (or decline to raise) the hint. Same
    /// engine and note→reminder split as the in-panel chip, but at the higher
    /// `senseActionFloor` — an unsure read means no hint, not a default.
    private func senseClassify(_ clip: String) {
        guard clip != senseCapturedClip else { return }   // already filed this text
        // The busy dots own the strip while a detached answer streams; a hint on
        // top would be two voices in one mouth. The copy simply goes unsensed.
        guard roundsInFlight == 0, !noteSaving else { return }
        senseClassifyTask?.cancel()
        senseClassifyTask = Task { [weak self] in
            let reading = await IntentEngine.shared.classify(clip)
            guard !Task.isCancelled, let self, !self.open, self.copySenseEnabled else { return }
            guard reading.intent == .note, reading.confidence >= Self.senseActionFloor else {
                self.senseCancelHint()
                return
            }
            let due = RemindersService.futureDate(in: clip)
                ?? RemindersService.recurrenceDate(in: clip)
            self.senseClip = clip
            self.senseHintShownAt = Date()
            self.clipboardSense = .hinting(panel: due != nil ? .reminder : .note)
        }
    }

    /// The confirm: file the clip where the hint said it would go, narrating
    /// saving → saved (or failed) in the strip. Writes go straight to the
    /// services — the submit-path plumbing (input-box state, saved cues) belongs
    /// to the open panel. The Recent row still lands via `persistCapture`, so a
    /// background capture shows up in history exactly like a chip capture.
    private func senseConfirm(clip: String, panel: Panel) {
        senseClassifyTask?.cancel()
        senseHintShownAt = nil
        // Claim the clip now, not on success — an open-panel chip tapped during
        // the in-flight write must not file a duplicate. Released on failure.
        senseCapturedClip = clip
        clipboardSense = .saving(panel: panel)
        switch panel {
        case .reminder:
            // Same past-due guard as `submitReminder`: better a reminder with no
            // time than one that silently never rings.
            var due = RemindersService.futureDate(in: clip)
                ?? RemindersService.recurrenceDate(in: clip)
            if let d = due, d <= Date() { due = nil }
            RemindersService.createReminder(clip, due: due) { [weak self] result in
                switch result {
                case .success(let link):
                    self?.senseWriteLanded(clip: clip, panel: panel, source: .reminder, link: link)
                case .failure:
                    self?.senseWriteFailed()
                }
            }
        case .note, .chat:
            // Honor the note destination here too — a closed-notch capture is the
            // same jot as a typed one, so it files to the same place.
            if NoteDestination.current == .markdownFolder {
                FileNotesService.writeNote(clip) { [weak self] result in
                    switch result {
                    case .success(let path):
                        self?.senseWriteLanded(clip: clip, panel: panel, source: .note, link: path)
                    case .failure:
                        self?.senseWriteFailed()
                    }
                }
            } else {
                NotesService.writeNote(clip) { [weak self] result in
                    switch result {
                    case .success(let noteID):
                        self?.senseWriteLanded(clip: clip, panel: panel, source: .note, link: noteID)
                    case .failure:
                        self?.senseWriteFailed()
                    }
                }
            }
        }
    }

    private func senseWriteLanded(clip: String, panel: Panel, source: HistoryItem.Source, link: String?) {
        persistCapture(clip, source: source, link: link)
        senseClip = nil
        // If the switch was flipped off while the write was in flight, the work
        // still landed (and Recent shows it) — just skip the cue.
        clipboardSense = copySenseEnabled ? .saved(panel: panel) : .idle
        senseDismiss(after: 1.4)
    }

    private func senseWriteFailed() {
        // Release the claim: the text is still safe in the clipboard, and the
        // in-panel capture chip becomes the retry path.
        senseCapturedClip = nil
        senseClip = nil
        clipboardSense = copySenseEnabled ? .failed : .idle
        senseDismiss(after: 2.4)
    }

    /// Retract the strip after a terminal cue has had its beat.
    private func senseDismiss(after seconds: TimeInterval) {
        senseDismissTask?.cancel()
        senseDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            switch self.clipboardSense {
            case .saved, .failed: self.clipboardSense = .idle
            default: break
            }
        }
    }

    /// Fade an unanswered hint once it has outstayed `senseHintTimeout`.
    private func senseExpireHintIfStale() {
        guard case .hinting = clipboardSense, let shown = senseHintShownAt,
              Date().timeIntervalSince(shown) > Self.senseHintTimeout else { return }
        senseCancelHint()
    }

    /// Drop a visible hint (never a saving/saved narration — those settle on
    /// their own via `senseDismiss`).
    private func senseCancelHint() {
        senseClassifyTask?.cancel()
        if case .hinting = clipboardSense { clipboardSense = .idle }
        senseClip = nil
        senseHintShownAt = nil
    }

    /// Tear the whole sense state down (setting toggled off, panel opened).
    private func senseReset() {
        senseClassifyTask?.cancel()
        senseDismissTask?.cancel()
        clipboardSense = .idle
        senseClip = nil
        senseHintShownAt = nil
    }

    // MARK: - Open / collapse

    /// Whether the island on `display` should render expanded. A `nil` active
    /// display means "no specific screen claimed the panel" (debug launch paths
    /// set `open` directly) and unfurls everywhere; otherwise only the claiming
    /// screen expands.
    func isOpen(on display: CGDirectDisplayID?) -> Bool {
        open && (activeDisplay == nil || display == nil || activeDisplay == display)
    }

    /// Open (or migrate) the panel on the given screen. Hovering another screen's
    /// resting notch while the panel is open elsewhere moves the whole island —
    /// conversation and all — to where the user actually is. `activeDisplay` is
    /// set BEFORE `open` so AppDelegate's combined observer keys the right panel.
    /// `velocity` is the cursor's approach vector (zero for non-hover opens);
    /// it must land before `open` so the island's animation reads it fresh.
    func openPanel(on display: CGDirectDisplayID?, velocity: CGVector = .zero) {
        if let display { activeDisplay = display }
        // Only the *closed→open* edge sets the clipboard baseline. Hover fires
        // `openPanel` again on every re-enter and on display migration while already
        // open — re-baselining there would clobber a copy the user made mid-session.
        // The baseline is the count from when the notch was last *resting* (before
        // this open), NOT the count right now: the user copies first and opens
        // second, so by now the copy has already bumped the live count. Carrying the
        // pre-open resting value forward is what lets that copy-then-open read as
        // fresh in `clipboardContextIfEligible`.
        if !open {
            // The entry vector belongs to the closed→open EDGE and nowhere else.
            // Setting it on every call meant the synthetic enter that the unfurling
            // island fires at its own parked pointer — the island arriving at the
            // cursor, which `hoverEntered` forwards straight back here — overwrote
            // the real approach with whatever the last 120ms held. On a click open
            // that is the press's own jitter: a couple of points over a few
            // milliseconds, i.e. hundreds of points per second, pointing wherever
            // the hand happened to twitch. `applyEntryKick` then read it off the
            // `isOpen` edge and shoved the panel sideways on every single open.
            entryVelocity = velocity
            // Seed the hover flag from where the pointer really is: a hover-open
            // already had `.onHover` set it, but a hot-key summon under a resting
            // cursor gets no fresh enter event, and its chips would stay hidden
            // with the pointer sitting right on them. Unknown geometry falls back
            // to "shown" — the pre-hide behaviour.
            pointerInside = pointerInsideIsland(on: display, slop: 16) ?? true
            // One trackpad tap on the closed→open edge only — hover re-enters and
            // display migrations while already open stay silent, as do the
            // programmatic opens (settings / What's New), which can
            // fire without the cursor on the island.
            Haptics.alignment()
            pasteboardChangeCountAtOpen = pasteboardChangeCountAtRest
            if mode == .idle, turns.isEmpty, let round = inFlightRounds.last {
                // A round is still streaming in the background — the busy
                // extension is out, and hovering the working notch should land
                // on the answer being written, not on the idle prompt with the
                // work hidden behind a Recent row. Newest round wins when
                // several are in flight (older ones stay reachable through
                // their pending Recent rows). The parked idle draft is
                // deliberately NOT consumed on this path: it stays parked and
                // hands back on the next plain idle open. Any parked page IS
                // dropped: the live round is newer activity than the snapshot.
                attachInFlightRound(round)
                parkedSession = nil
            } else {
                // A return within the TTL lands back on the parked page — the
                // thread being read, the half-typed follow-up, the settings form.
                // Past the TTL the snapshot is stale context: drop it and open
                // fresh (the conversation is still one tap away in Recent).
                if let parked = parkedSession,
                   Date().timeIntervalSince(parked.closedAt) <= Self.parkedSessionTTL {
                    restoreParkedSession(parked)
                }
                parkedSession = nil
                // Hand back an unsent idle draft parked at the last close, so folding
                // the notch away and re-opening it doesn't drop what the user was
                // typing. Only into a fresh, empty idle prompt — never clobber a line
                // already in the box (e.g. one restored with the panel). Consumed here
                // so it's handed back exactly once. Runs on the closed→open edge only:
                // hover re-enters and display migrations keep `open` true and skip it.
                if mode == .idle, !hasText, !savedIdleDraft.isEmpty {
                    text = savedIdleDraft
                }
                savedIdleDraft = ""
            }
            // Opening the panel is the app being *used*, which is the moment the
            // curated shortlists want to be current — launch alone misses a Mac
            // that stays up for a week. A cheap no-op inside the manifest's TTL.
            Task.detached(priority: .background) { await RemoteModelManifest.refreshIfDue() }
        }
        // A hover re-entry supersedes any pending leave watch — and any pending
        // entry watch has just been answered (by itself or by another route in).
        cancelLeaveWatch()
        cancelEntryWatch()
        // Re-entering during the close dissolve cancels it: clear the flag so the
        // content (held mounted while `open` is true) springs back to full opacity
        // instead of completing its fade, and the pending `beginClose` timer no-ops.
        closing = false
        open = true
        // An open retires a visible sense hint (the panel takes over the screen),
        // while a saving/saved narration settles on its own timer, just unseen.
        if case .hinting = clipboardSense { senseCancelHint() }
    }

    /// Toggle the panel from a global hot key: open it on `display` if resting,
    /// or close it if it's already showing. Summoned by keyboard, so it routes
    /// through `openPanel` (idle prompt, clipboard baseline preserved) on the open
    /// edge and a hard `fullClose` on the close edge — no hover required.
    func toggleSummon(on display: CGDirectDisplayID?) {
        if open {
            fullClose()
        } else {
            mode = .idle
            openPanel(on: display)
        }
    }

    /// Toggle the inline settings panel. Opening it folds the recent list away
    /// (they share the same slot below the prompt) and drops any keyboard
    /// highlight; closing returns to the bare idle prompt.
    func toggleSettings() {
        showSettings.toggle()
        if showSettings {
            showWhatsNew = false
            showHistory = false
            highlightedHistoryIndex = nil
        }
    }

    /// Open the panel straight into settings — the path the gear and ⌘, take.
    /// Works whether the panel was resting or already open on some other view.
    /// `display` says which screen should host it (AppDelegate passes the screen
    /// under the mouse when ⌘, fires from anywhere); nil keeps the current one.
    func openSettings(on display: CGDirectDisplayID? = nil) {
        // Summoned by keyboard, not approached by mouse — a stale entry vector
        // from an earlier hover must not kick the settings unfurl sideways.
        entryVelocity = .zero
        if let display { activeDisplay = display }
        // Same closed→open-edge rule as openPanel: adopt the pre-open resting
        // baseline so a copy-then-⌘, still leaves the clipboard eligible for the
        // first Ask, and a re-open while already open doesn't clobber it.
        if !open {
            pasteboardChangeCountAtOpen = pasteboardChangeCountAtRest
        }
        // Cancel any in-flight close dissolve (see `openPanel`), and any pending
        // leave watch — this keyboard summon supersedes it.
        closing = false
        cancelLeaveWatch()
        open = true
        mode = .idle
        showSettings = true
        showWhatsNew = false
        showHistory = false
        highlightedHistoryIndex = nil
    }

    /// Leave settings and return to the idle prompt (panel stays open).
    func closeSettings() {
        showSettings = false
    }

    /// Open the panel straight into the "What's New" release notes — the path ⌘↵,
    /// the input-row cue, and the once-per-version auto-show all take. Mirrors
    /// `openSettings`: works whether the panel was resting or already open, clears
    /// any stale entry vector so the keyboard summon doesn't kick the unfurl, and
    /// folds the recent list / settings away (they share the same body slot).
    /// Marks the running version as seen so the cue and auto-show don't re-fire.
    func openWhatsNew(on display: CGDirectDisplayID? = nil) {
        entryVelocity = .zero
        if let display { activeDisplay = display }
        if !open {
            pasteboardChangeCountAtOpen = pasteboardChangeCountAtRest
        }
        // Cancel any in-flight close dissolve (see `openPanel`), and any pending
        // leave watch — this keyboard summon supersedes it.
        closing = false
        cancelLeaveWatch()
        open = true
        mode = .idle
        showWhatsNew = true
        showSettings = false
        showHistory = false
        highlightedHistoryIndex = nil
        WhatsNewService.shared.markSeen()
    }

    /// Leave What's New and return to the idle prompt (panel stays open).
    func closeWhatsNew() {
        showWhatsNew = false
    }

    /// Toggle the pin on the answer currently on screen. Pinned → the pointer can
    /// leave without folding the panel (see `collapseOnLeave`). Unpinning while the
    /// pointer is already off the island re-arms the normal leave-fold immediately,
    /// so an un-pin doesn't strand a panel open until the next hover.
    func toggleAnswerPin() {
        isAnswerPinned.toggle()
        if !isAnswerPinned { collapseOnLeave(from: activeDisplay) }
    }

    /// Auto-retract once the pointer leaves — for EVERY page (the rule the user
    /// settled on: leave = fold, always). Closing is cheap now: the page is
    /// parked by `fullClose` and a hover within `parkedSessionTTL` restores it
    /// exactly, so the panel no longer needs to cling open to protect content.
    ///
    /// The single exception: **actively typing**. While the keyboard is engaged
    /// the pointer isn't an attention signal — folding mid-keystroke would yank
    /// focus, a real interruption no restore compensates. So a leave during
    /// typing defers the fold until `typingGrace` after the last keystroke
    /// (the deferred fold re-checks, so continued typing keeps deferring; a
    /// hover re-entry or keyboard summon cancels it via `leaveRecheckTask`).
    func collapseOnLeave(from display: CGDirectDisplayID? = nil, sequenced: Bool = true) {
        // The pointer left: a sweep being watched for a possible arrival has its
        // answer. Cleared before the `open` guard — the watch only ever exists
        // while the panel is CLOSED, so leaving it to the guard would strand it.
        cancelEntryWatch()
        // Nothing to fold on a resting notch — and a stale deferred fold must
        // never fire `fullClose` on an already-closed panel (that would wipe a
        // freshly parked session).
        guard open else { return }
        // The user pinned this answer: leaving is no longer a fold signal. Drop any
        // watch that was already armed (a leave-during-typing may have scheduled
        // one before the pin) so it can't fire behind the pin's back.
        //
        // The open `/` menu joins the pickers here for the same reason: its card
        // hangs BELOW the island in its own window, so reaching down to the lower
        // rows reads as "left the island" and would fold the panel out from under
        // the menu being read. Ordinary leave-folding resumes the moment the menu
        // is gone (a picked row, a keystroke past the command word, Esc).
        if isAnswerPinned || isModelPickerOpen || isFolderPickerOpen
            || isResultMetadataMenuOpen || slashMenuOpen || detachDrag != nil {
            cancelLeaveWatch()
            return
        }
        // The pointer leaving a *resting* notch on a screen that isn't hosting
        // the open panel has nothing to fold — and must never close the island
        // that's actually in use on another display.
        if let display, let active = activeDisplay, display != active { return }
        // Verify the exit against the pointer's real position: the open/close
        // springs update the tracking area per frame, and AppKit synthesizes
        // exit events for a stationary pointer when the boundary moves under
        // it. Folding on those made the island flap (see `pointerInsideIsland`).
        // Tight slop: a real leave should fold even from just past the edge.
        let mouse = NSEvent.mouseLocation
        let inside = pointerInsideIsland(on: display ?? activeDisplay, slop: 2)
        if inside == true {
            armLeaveWatch(LeaveWatch(display: display, sequenced: sequenced,
                                     armedMouse: mouse, movedOut: false), after: 0.35)
            return
        }
        // The pointer really is outside. But WHY: did it cross the boundary, or
        // did the boundary shrink away from a parked pointer (⌘N folding a tall
        // thread to the short idle prompt, a list collapsing)? A genuine leave
        // has the cursor in motion; a UI shrink arrives with a cursor that
        // hasn't moved at all — that one is NOT the user leaving, so hold the
        // panel and fold only once the pointer really moves off (the watch).
        // Unknown geometry (nil) falls back to trusting the event, as before.
        let movedOut = inside == nil
            || MouseVelocityTracker.shared.cursorMoved(within: 0.25)
        if !movedOut {
            armLeaveWatch(LeaveWatch(display: display, sequenced: sequenced,
                                     armedMouse: mouse, movedOut: false), after: 0.35)
            return
        }
        let sinceEdit = Date().timeIntervalSince(lastEditAt)
        if sinceEdit < Self.typingGrace {
            armLeaveWatch(LeaveWatch(display: display, sequenced: sequenced,
                                     armedMouse: mouse, movedOut: true),
                          after: Self.typingGrace - sinceEdit)
            return
        }
        // Route through the two-beat dissolve so the content fades before the
        // shell retracts, matching Esc.
        beginClose(sequenced: sequenced)
    }

    /// One poll tick of the armed leave watch. Ends in exactly one of: fold
    /// (pointer verifiably off the island, displaced or genuinely crossed out,
    /// keyboard quiet), re-arm (still undecided), or dissolve (panel no longer
    /// open / answer pinned / watch cancelled elsewhere).
    private func recheckLeaveWatch() {
        guard let watch = leaveWatch else { return }
        guard open else { leaveWatch = nil; return }
        if isAnswerPinned || isModelPickerOpen || isFolderPickerOpen
            || isResultMetadataMenuOpen || slashMenuOpen {
            cancelLeaveWatch(); return
        }
        // Parked back over (or still over) the island: nothing to fold, but keep
        // watching — AppKit's tracking state may be desynced, so the exit that
        // would restart this conversation might never arrive.
        if pointerInsideIsland(on: watch.display ?? activeDisplay, slop: 2) == true {
            armLeaveWatch(watch, after: 0.35)
            return
        }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - watch.armedMouse.x
        let dy = mouse.y - watch.armedMouse.y
        let displaced = (dx * dx + dy * dy).squareRoot() > 6
        // A boundary-shrink leave holds until the pointer actually goes
        // somewhere. Displacement is measured against the ORIGINAL armed
        // position, so slow drift accumulates instead of resetting each tick.
        if !watch.movedOut, !displaced {
            armLeaveWatch(watch, after: 0.35)
            return
        }
        let sinceEdit = Date().timeIntervalSince(lastEditAt)
        if sinceEdit < Self.typingGrace {
            var held = watch
            held.movedOut = true
            armLeaveWatch(held, after: Self.typingGrace - sinceEdit)
            return
        }
        leaveWatch = nil
        beginClose(sequenced: watch.sequenced)
    }

    /// How long the content lingers, fading, before the shell retracts. Kept short
    /// — this is a dissolve to soften the snap, not a second animation the user
    /// waits through; the shell's own retract spring picks up right after. Paced
    /// with the calmer `closeSpring` so the two beats read as one motion.
    static let closeContentFade: TimeInterval = 0.16

    /// The two-beat close. The first beat fades the content out while the shell
    /// holds its expanded size (`closing = true`, `open` still true); the second,
    /// once the content is gone, drops `open` so the shell retracts. This makes the
    /// close symmetric with the open — content and shell move in sequence rather
    /// than clamping shut on one transaction.
    ///
    /// `sequenced` is the caller's reduce-motion gate (the views own that
    /// environment value): when motion is reduced — or when there's nothing to fade
    /// because the panel is already resting — it collapses straight away. Re-entrancy
    /// is safe: a second close request while already `closing` is a no-op, and any
    /// open (`openPanel`/`openSettings`/…) clears `closing` so an interrupted close
    /// that reopens starts clean.
    func beginClose(sequenced: Bool = true) {
        guard open, sequenced else { fullClose(); return }
        guard !closing else { return }
        closing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchModel.closeContentFade) { [weak self] in
            // The close may have been overtaken — a hover re-opened the island, or a
            // full close already fired — in which case `closing` was cleared and this
            // stale beat must not yank the panel shut.
            guard let self, self.closing else { return }
            self.fullClose()
        }
    }

    /// Hard close from Esc / click-outside — always collapses regardless of mode,
    /// including mid-request: an answer still in flight is detached, not cancelled.
    /// The task keeps streaming on its own snapshot (see `submit`) and files the
    /// finished round into Recent, so closing never loses a conversation.
    func fullClose() {
        // A pending leave watch is moot once the panel actually closes.
        cancelLeaveWatch()
        // Park the page the user was on, so a reopen within the TTL lands right
        // back here (closing gestures navigate, they never destroy). A bare idle
        // prompt has nothing worth parking — its unsent draft rides the separate,
        // un-expiring `savedIdleDraft` below. Unconditional overwrite is safe:
        // every close is preceded by an open, and every open consumed or cleared
        // the previous snapshot.
        parkedSession = (mode != .idle || showSettings || showWhatsNew || showHistory)
            ? ParkedSession(mode: mode, turns: turns, text: text,
                            threadHistoryID: threadHistoryID,
                            showSettings: showSettings, showWhatsNew: showWhatsNew,
                            showHistory: showHistory, closedAt: Date(),
                            measuredAnswerHeight: lastMeasuredAnswerHeight,
                            fromPromptShortcut: fromPromptShortcut)
            : nil
        // The measurement now lives in the park (if any). Zero the live mirror so
        // every non-restore open (fresh idle, settings, a different thread) seeds
        // the next NotchBody mount with "unmeasured", exactly as before.
        lastMeasuredAnswerHeight = 0
        // Detach, don't cancel: dropping the reference leaves the Task running
        // (deinit doesn't cancel it) and frees the slot so the next submit's
        // supersede-cancel can't reach the detached round.
        task = nil
        open = false
        // The two-beat close has landed (or this was a direct hard close): the shell
        // is retracting now, so drop the dissolve flag. Clearing it here also disarms
        // any in-flight `beginClose` timer — its `guard self.closing` then no-ops.
        closing = false
        activeDisplay = nil
        // Park an unsent idle draft so the next open can restore it — but only a
        // genuine idle draft: never a follow-up typed on top of an answer
        // (`.result`), and never an empty line. A submit already cleared `text`
        // before any close, so a sent line stashes nothing. `newChat` clears
        // without routing through here, so "start fresh" still lands blank.
        savedIdleDraft = (mode == .idle && hasText) ? text : ""
        mode = .idle
        isAnswerPinned = false
        fromPromptShortcut = false
        promptShortcutContext = nil
        clearSelectionContext()
        isModelPickerOpen = false
        isFolderPickerOpen = false
        showModelPicker = false
        showAgentPicker = false
        showAskModelPicker = false
        showAgentFolderPicker = false
        isResultMetadataMenuOpen = false
        text = ""; turns = []
        showHistory = false
        showSettings = false
        showWhatsNew = false
        confirmingClear = false
        highlightedHistoryIndex = nil
        // Drop any lingering note-save feedback so a fresh open starts clean.
        noteCueTask?.cancel()
        lastSavedNote = nil
        noteError = nil
        noteSaving = false
        // Retire any in-flight capture write's claim (XII-117): bumping the token
        // means a late callback from a write still in its AppleScript retry window
        // won't touch the state we just reset (it still saves its own Recent row).
        captureToken += 1
        // Snapshot the resting clipboard count: the next open baselines against this
        // (the count from *before* the user's next copy-then-open), so a copy made
        // while the notch is closed still reads as fresh context on the next Ask.
        pasteboardChangeCountAtRest = NSPasteboard.general.changeCount
        // The sense watcher resumes from here too: anything written or copied
        // during the session (handoff copy, code-block copy, in-panel ⌘C) is
        // already accounted for and can never hint on the way out.
        senseLastChangeCount = pasteboardChangeCountAtRest
    }

    /// "Back" / start a new conversation: drop the current Q&A from the screen and
    /// return to the idle input — but stay OPEN, so the user lands straight on a
    /// fresh prompt instead of the panel collapsing. Triggered by the back button
    /// in a result view and by the ← arrow key. Like `fullClose`, an answer still
    /// in flight is detached rather than cancelled — it finishes in the background
    /// and lands in Recent, so backing out while waiting never loses the round.
    func newChat() {
        task = nil
        // ← / ⌘N is the one gesture that DESTROYS a session (closing only parks).
        // Drop any parked page too, so "start fresh" can't be haunted by a
        // snapshot from before the reset.
        parkedSession = nil
        // The park is gone; so must the parked height measurement. Left in place,
        // a long thread's >300pt value would seed the next NotchBody mount into
        // the clipped full-height layout for a brand-new short chat. NotchBody
        // zeroes its live @State when `turns` empties below — this covers the
        // mirror when the body isn't mounted to see that change.
        lastMeasuredAnswerHeight = 0
        mode = .idle
        isAnswerPinned = false
        fromPromptShortcut = false
        promptShortcutContext = nil
        clearSelectionContext()
        agentDetailTaskID = nil
        text = ""; turns = []
        showHistory = false
        showSettings = false
        highlightedHistoryIndex = nil
        // Clear the note/reminder-save state, exactly like `fullClose` does (XII-86).
        // Backing out with Back while a Note/Reminder write is still in flight (e.g.
        // an AppleScript retry) used to leave `noteSaving` stuck true here. Resetting
        // it (plus the cue task and feedback fields) keeps the next session clean.
        noteCueTask?.cancel()
        lastSavedNote = nil
        noteError = nil
        noteSaving = false
        // Retire any in-flight capture write's claim (XII-117) — see fullClose.
        captureToken += 1
        // Re-baseline the clipboard against NOW. The handoff-copy button writes the
        // transcript to the pasteboard (bumping changeCount past the open baseline);
        // without this reset, the next first-turn Ask would mistake our own handoff
        // text for "something the user copied to ask about" and inject it.
        pasteboardChangeCountAtOpen = NSPasteboard.general.changeCount
    }

    // MARK: - Submit

    /// A user-defined global prompt shortcut: open on the requested display,
    /// discard any page the panel happened to be showing, and submit the bound
    /// instruction against the already-captured outside selection immediately.
    /// `openPanel` comes first so its reattach-on-open behavior can settle; the
    /// following `newChat` then guarantees this action starts its own conversation.
    func runPromptShortcut(prompt: String, selectedText: String,
                           pin: ModelPin? = nil,
                           on display: CGDirectDisplayID?) {
        let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        mode = .idle
        openPanel(on: display)
        newChat()
        text = """
        \(instruction)

        <selected_text>
        \(selectedText)
        </selected_text>
        """
        // Mark the thread as shortcut-driven BEFORE submitting: the result view
        // reads this to collapse its follow-up input into a floating button.
        fromPromptShortcut = true
        armModelPin(pin)
        submit(hideUserBubble: true)
    }

    /// Arm the next `submit()` with a shortcut's pinned backend. Once saved, that
    /// provider/model pair is authoritative: losing its key or CLI session should
    /// surface that backend's error, never silently reroute the shortcut through
    /// the app's current default.
    private func armModelPin(_ pin: ModelPin?) {
        guard let pin else {
            regenOverrideModel = nil
            regenOverrideProvider = nil
            return
        }
        regenOverrideModel = pin.model
        regenOverrideProvider = pin.provider
    }

    /// The empty form of a prompt shortcut, targeted at the notch. Open a fresh
    /// idle surface and retain the captured selection out of sight; the field is
    /// only for the instruction the user wants to apply to it.
    func openPromptShortcutComposer(selectedText: String,
                                    on display: CGDirectDisplayID?) {
        let context = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        mode = .idle
        openPanel(on: display)
        newChat()
        // Nothing was selected: this is the plain idle prompt, opened by the
        // gesture. The context stays nil so no badge claims a selection that
        // isn't there — the gesture still gets the user somewhere to type.
        promptShortcutContext = context.isEmpty ? nil : selectedText
    }

    // MARK: - The selection the user came in with

    /// Whether an ambient selection belongs on what the panel is currently
    /// showing: the plain idle prompt, and nothing else. A thread on screen, an
    /// agent task being written, settings, What's New, or a shortcut that already
    /// captured its own selection each own the surface — dropping a second
    /// context badge onto any of them would be noise at best.
    var acceptsSelectionContext: Bool {
        selectionContextEnabled
            && mode == .idle && turns.isEmpty
            && !showSettings && !showWhatsNew
            && !agentComposeActive
            && promptShortcutContext == nil
    }

    /// Carry the selection read at the open edge into the idle prompt. Silent
    /// no-op for everything that isn't worth carrying — an empty read, a surface
    /// that doesn't accept one, or the exact text the user already said no to.
    func attachSelectionContext(_ selected: String, from app: String?) {
        let body = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, acceptsSelectionContext, body != dismissedSelection else { return }
        selectionContext = selected
        selectionContextSource = app
    }

    /// The × on the badge: this answer is not about that. Remembered, so the next
    /// summon over the same untouched selection doesn't re-attach it.
    func dropSelectionContext() {
        dismissedSelection = selectionContext?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        selectionContext = nil
        selectionContextSource = nil
        // The × is the first moment we can be sure the user has both noticed the
        // feature and wanted it gone — so it is the one moment worth spending on
        // telling them where the switch lives. Once ever, then never again: a
        // reminder that repeats is nagging about a thing they already handled.
        guard !UserDefaults.standard.bool(forKey: Self.selectionContextHintSeenKey)
        else { return }
        UserDefaults.standard.set(true, forKey: Self.selectionContextHintSeenKey)
        selectionContextHintTask?.cancel()
        selectionContextHintShown = true
        selectionContextHintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                self?.selectionContextHintShown = false
            }
        }
    }

    /// Take the one-time hint off screen early — the user followed it into
    /// Settings, or the page moved on underneath it.
    func retireSelectionContextHint() {
        selectionContextHintTask?.cancel()
        selectionContextHintShown = false
    }

    /// Drop the carried selection because the page changed under it (a new chat,
    /// a close, a line that went somewhere else). Unlike `dropSelectionContext`
    /// this is not a refusal, so it arms no memory — the next open reads the
    /// selection fresh.
    private func clearSelectionContext() {
        selectionContext = nil
        selectionContextSource = nil
        retireSelectionContextHint()
    }

    /// A prompt shortcut whose presentation is a compact pointer-side window.
    /// The round starts headlessly, preserving whatever the notch is currently
    /// showing, then its live mirror is handed directly to the window.
    func runPromptShortcutInWindow(shortcutID: UUID, prompt: String, selectedText: String,
                                   pin: ModelPin? = nil,
                                   title: String, near pointer: NSPoint,
                                   sourceApplication: NSRunningApplication?) {
        guard let threadID = startPromptShortcutRound(
            prompt: prompt, selectedText: selectedText, pin: pin)
        else { return }
        DetachedSessionWindowController.presentCompactShortcut(
            shortcutID: shortcutID, threadID: threadID,
            title: title, model: self, near: pointer,
            sourceApplication: sourceApplication)
    }

    /// Start the headless round shared by saved prompt shortcuts and the compact
    /// one-off composer. Keeping construction here guarantees both paths wrap the
    /// captured selection identically and both remain invisible to panel state.
    @discardableResult
    func startPromptShortcutRound(prompt: String, selectedText: String,
                                  pin: ModelPin? = nil,
                                  origin: HistoryItem.Origin? = nil) -> UUID? {
        let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return nil }

        // The one-off composer can DROP its captured selection (the × on the
        // "Using copied text" badge) — the line then stands on its own and asks
        // exactly what was typed.
        let question = context.isEmpty ? instruction : """
        \(instruction)

        <selected_text>
        \(selectedText)
        </selected_text>
        """
        return runDetachedRound(
            threadID: UUID(), seed: [], question: question,
            hideUserBubble: true, trackCompactTask: true, pin: pin,
            origin: origin)
    }

    /// Supersede a compact shortcut's previous headless round. This is a replace,
    /// not a visible stop: discard its unfinished Recent placeholder while the
    /// existing window immediately adopts the newer translation.
    func cancelCompactRound(threadID: UUID) {
        compactRoundTasks.removeValue(forKey: threadID)?.cancel()
        settlePending(threadID)
    }

    /// Leaving or replacing a Force Touch result is a presentation detach, like
    /// folding the main panel: relinquish the handle that can supersede the round
    /// without cancelling the unstructured task itself. Its in-flight snapshot
    /// keeps streaming and persists the finished thread into Recent.
    func detachCompactRound(threadID: UUID) {
        compactRoundTasks.removeValue(forKey: threadID)
    }

    /// The single Enter entry point the input field calls. There's only one surface
    /// — the chat input — so this never changes what the panel looks like; it just
    /// routes the line by **intent**:
    ///   · note naming a future time → file it in Apple Reminders (alarm at that time)
    ///   · note                      → write it to Apple Notes (feedback shows inline)
    ///   · ask, or ambiguous         → send it to the AI
    /// Ambiguity falls to ask (`effectiveSubmitPanel` resolves `nil` → `.chat`), so an
    /// unsure line on a fresh prompt asks the AI — the agreed "ambiguous → ask" rule.
    /// This matches `submitLabel` exactly, so the inline "Ask"/"Note"/"Remind" hint
    /// always names where the line actually went.
    func submitCurrent() {
        // A thread on screen routes by the THREAD, not the armed bucket:
        // `submit()` continues the conversation (its agent session when
        // resumable, else the chat model), so a persisted Agent bucket can
        // never hijack an ask thread's follow-up into a fresh agent task.
        if !turns.isEmpty { submit(); return }
        // An empty prompt shortcut has already supplied the object of the ask.
        // Whatever is typed now is the one-off instruction, regardless of intent
        // classification or which bucket was previously armed.
        if let selectedText = promptShortcutContext {
            let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { return }
            promptShortcutContext = nil
            text = """
            \(instruction)

            <selected_text>
            \(selectedText)
            </selected_text>
            """
            fromPromptShortcut = true
            submit(hideUserBubble: true)
            return
        }
        // An active agent compose sends the line to the agent CLI, not the
        // chat model — regardless of what the classifier reads.
        if agentComposeActive { submitAgent(); return }
        // A `/`-pinned prompt shortcut acts as the line's mode: wrap the input
        // in that shortcut's instruction and ask — the same intent the chord
        // path fires with captured selection, just against what was typed.
        if let shortcut = promptShortcutMode {
            let instruction = shortcut.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { return }
            text = """
            \(instruction)

            <selected_text>
            \(text)
            </selected_text>
            """
            promptShortcutMode = nil
            // Same shortcut, same pin: a `/`-driven run is the chord's twin, so it
            // runs on the backend that shortcut names.
            armModelPin(shortcut.pin)
            submit()
            return
        }
        // The selection carried in from the app the user came from rides along
        // with an ASK — "translate this" is about the thing they had highlighted,
        // which is the entire reason it was picked up. Note and Remind route on
        // their own words alone ("call mom tomorrow", typed over some paragraph
        // still selected in another window, is a reminder and nothing else), so
        // there the context is dropped rather than folded in. Either way it is
        // consumed here: it belonged to this line.
        if let selection = selectionContext {
            clearSelectionContext()
            let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if effectiveSubmitPanel == .chat, !instruction.isEmpty {
                text = """
                \(instruction)

                <selected_text>
                \(selection)
                </selected_text>
                """
                // Same shape as the prompt-shortcut path above: the wrapped
                // payload is wire context, not something to render back at the
                // user as their own bubble.
                submit(hideUserBubble: true)
                return
            }
        }
        switch effectiveSubmitPanel {
        case .chat:     submit()
        case .note:
            askComposeImages = []
            submitNote()
        case .reminder:
            askComposeImages = []
            submitReminder()
        }
    }

    // MARK: - Agent to Codex (XII: agent-to-Codex)

    /// Enter the agent compose: unfurl the chip row and point the hint at the
    /// agent CLI. With a `folder` (the drop path) that folder is the compose's;
    /// without one (the pill path) the remembered last project seeds it — possibly
    /// nothing, in which case the folder chip says "choose" and Enter opens the
    /// picker. Animated here because both entries (a pill tap, a drop) land
    /// outside any withAnimation context.
    func enterAgentCompose(folder: URL? = nil) {
        guard !AgentEngine.available.isEmpty else { return }
        // A task for the agent is written against a project on disk, not against
        // whatever was highlighted in another window — and `submitAgent` never
        // reads the carried selection, so leaving the chip up would be the panel
        // claiming a context it isn't going to send.
        clearSelectionContext()
        withAnimation(.smooth(duration: 0.3)) {
            if let folder {
                lastAgentFolder = folder
                AgentFolderMRU.record(folder)
                agentComposeFolder = folder
            } else if agentComposeFolder == nil {
                agentComposeFolder = lastAgentFolder
            }
            agentComposeActive = true
            manualPanelOverride = nil
        }
        // The remembered engine may have been uninstalled / signed out since it
        // was last used — fall back to whichever is live, and drop the model
        // pick with it (it named the dead engine's model). Gated on KNOWN dead,
        // never on a probe that simply hasn't landed (see `isKnownUnavailable`).
        if agentArmedEngine.isKnownUnavailable,
           let fallback = AgentEngine.available.first {
            agentArmedEngine = fallback
            agentModelID = nil
        }
    }

    /// The persisted-bucket twin of `enterAgentCompose`: a bucket restored from the
    /// last launch is armed without ever having been *entered* this run, so nothing
    /// seeded it. Run on open — seed the remembered project, and repoint a stale
    /// engine (uninstalled / signed out since it was last used), dropping its model
    /// pick with it. No agent CLI survives at all → fall back to Ask rather than
    /// unfurl a compose row that can't run.
    ///
    /// **Only a KNOWN-dead engine is repointed.** This runs on the first open, which
    /// after a relaunch can land inside the launch probe's window — and there every
    /// engine reads unavailable. Repointing on that made a relaunch quietly reset the
    /// armed model: Command Code + Deepseek came back as Codex on the CLI default,
    /// and because both writes persist through `didSet`, the pick wasn't just drawn
    /// wrong, it was gone. A pick that can't be judged yet is left exactly as it is;
    /// `.cliAvailabilityResolved` runs this again once the probe has an answer.
    private func rearmPersistedAgentBucket() {
        guard agentComposeActive else { return }
        // Same "not yet" caution one level up: `agentAvailable` is false during the
        // probe window too, and closing the bucket there would drop the user out of
        // a mode they're still in.
        guard AgentEngine.offered.allSatisfy(\.isAvailabilityResolved) else { return }
        guard agentAvailable else {
            agentComposeActive = false
            return
        }
        if agentComposeFolder == nil { agentComposeFolder = lastAgentFolder }
        if agentArmedEngine.isKnownUnavailable, let fallback = AgentEngine.available.first {
            agentArmedEngine = fallback
            agentModelID = nil
        }
    }

    /// Exit the compose (Shift-Tab, Tab, or the pill's Ask half — NOT a submit; the
    /// bucket outlives the task it sent). Keeps the folder memory — re-entering
    /// lands on the same project; the attached images don't (they belonged to the
    /// task that was being written).
    func exitAgentCompose() {
        withAnimation(.smooth(duration: 0.3)) {
            agentComposeActive = false
            agentComposeImages = []
        }
    }

    /// ⌘V in the prompt attaches a clipboard image to the active compose. Ask and
    /// Agent keep separate attachment sets, but share the same explicit-paste,
    /// append, cap, and delete interaction. Text-only clipboards fall through to
    /// the editor's ordinary paste behavior.
    func handleComposePasteImage() -> Bool {
        guard let image = Self.pasteboardImage() else { return false }
        if agentComposeActive {
            guard agentComposeImages.count < Self.composeImageLimit else { return true }
        } else {
            if let engine = agentThreadContinuation {
                guard engine.supportsImageInput else { return false }
            } else {
                guard activeModelSupportsVision else { return false }
            }
            guard askComposeImages.count < Self.composeImageLimit else { return true }
        }
        // A pasted image is real input, exactly like typed text — so fold the
        // Recent list the same way the `text` setter does. Without this the
        // list lingers open over the compose until the user also types
        // something (the bug: "粘贴图片时没有自动收起历史记录，必须要打字").
        collapseHistory()
        noteUserTyping()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            if agentComposeActive {
                agentComposeImages.append(image)
            } else {
                // An image attachment is an explicit Ask intent; don't let a short
                // caption such as "save this" silently route the pixels to Notes.
                manualPanelOverride = .chat
                askComposeImages.append(image)
            }
        }
        return true
    }

    /// The stand-in instruction an image-only send carries: the CLIs read the
    /// prompt from stdin/args, so "no text" still has to say *something* — and
    /// what it should say is "the images are the task".
    static func agentImageOnlyPrompt(count: Int) -> String {
        count > 1
            ? "See the attached images — they describe the task."
            : "See the attached image — it describes the task."
    }

    /// The image on the clipboard, or `nil` if it doesn't carry one. Keyed on the
    /// pasteboard actually declaring an IMAGE payload — not on "it has no text".
    /// The distinction is the whole feature: most apps that copy an image put a
    /// string alongside the pixels (a source URL, an alt text, a file path), so a
    /// "text ⇒ not an image" rule only ever recognizes a bare ⌃⇧⌘4 screenshot and
    /// pastes that URL as text everywhere else. Two shapes count:
    ///   · pixels on the board (screenshot, in-app image copy) — text riding along
    ///     is metadata about the image, so the image still wins;
    ///   · an image FILE copied in Finder, which puts a file URL and no pixels.
    /// Anything else (plain text, RTF/HTML from a doc, a non-image file) returns
    /// `nil` and pastes as text.
    static func pasteboardImage() -> NSImage? {
        let pb = NSPasteboard.general
        if pb.availableType(from: [.png, .tiff]) != nil,
           let image = NSImage(pasteboard: pb), image.isValid {
            return image
        }
        if let url = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first,
           let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let image = NSImage(contentsOf: url), image.isValid {
            return image
        }
        return nil
    }

    /// A thumbnail's × in the attached-images strip — drop that one, keep the
    /// rest and keep composing.
    func removeAgentComposeImage(at index: Int) {
        guard agentComposeImages.indices.contains(index) else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            agentComposeImages.remove(at: index)
        }
    }

    func removeAskComposeImage(at index: Int) {
        guard askComposeImages.indices.contains(index) else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            askComposeImages.remove(at: index)
        }
    }

    /// A project folder dropped on the island — the compose's second doorway.
    /// The folder is exactly the argument the mode is missing, so one drop both
    /// enters the compose and answers "where". Wherever the panel was (a thread,
    /// settings), the drop lands it on the idle prompt — that's where the task
    /// gets written; a thread on screen files into Recent like ⌘N.
    func handleAgentFolderDrop(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        // The drop landing — the trackpad answers the release like Finder's snap.
        Haptics.alignment()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
            if showSettings { showSettings = false }
            if showWhatsNew { showWhatsNew = false }
            if mode != .idle { newChat() }
        }
        enterAgentCompose(folder: url)
    }

    /// Pick (or change) the compose's folder. The picker is a separate window,
    /// so `isFolderPickerOpen` holds the island open while it's up (same trick
    /// as the model picker popover). `then` runs on a successful pick — the
    /// no-remembered-folder Enter path uses it to fire the run straight from
    /// the picker's OK, making the picker the first run's confirmation gate.
    func pickAgentFolder(then completion: ((URL) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L("agent.pick.message")
        // Reopen at the user's last project when selecting a different agent folder.
        panel.directoryURL = lastAgentFolder
        isFolderPickerOpen = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.isFolderPickerOpen = false
                if response == .OK, let url = panel.url {
                    self.selectAgentFolder(url)
                    completion?(url)
                }
            }
        }
    }

    /// Point the compose at `url` — the one path every folder change goes through
    /// (the file panel's OK, and the chip menu's recent rows), so the remembered
    /// project and the recents list can never drift from what the chip shows.
    func selectAgentFolder(_ url: URL) {
        lastAgentFolder = url
        AgentFolderMRU.record(url)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            agentComposeFolder = url
        }
        refreshAgentSkills(forceReload: true)
    }

    /// The compose row's model menu: picking a model picks its engine with it
    /// (the menu mixes every available engine's entries into one list).
    func selectAgentModel(_ choice: AgentModelChoice) {
        agentArmedEngine = choice.engine
        agentModelID = choice.id
        // Drop an effort the new model doesn't take. The run already clamps this
        // at spawn (see `startAgentRun`), but leaving it armed made the chip read
        // "Kimi K3 max" for a model with no adjustable effort at all — a level the
        // run would silently discard. The chip should never name a dial that isn't
        // connected to anything.
        if let effort = agentEffort,
           !choice.engine.effortChoices(forModelID: choice.id).contains(effort) {
            agentEffort = nil
        }
        // An explicit pick counts as "recently used" right away, so the picker's
        // top section reflects it on the next open even before a run goes out —
        // the same rule the Ask chip's recents follow.
        AgentModelMRU.record(engine: choice.engine, model: choice.id)
    }

    /// Enter on a composed line: start the agent run. With no folder yet
    /// (first-ever agent) the picker opens and its OK starts the run — the
    /// natural confirmation gate; nothing ever launches silently. The run is
    /// owned by the manager — closing the panel doesn't touch it; a notification
    /// announces the finish. Submitting does NOT end the compose: the bucket is a
    /// mode you stay in, so the next task starts armed on the same project.
    /// The Agent-bucket meaning of Command-Return: start this task and follow it
    /// straight into its live detail page. Kept separate from plain Return, which
    /// deliberately leaves the compose bucket visible for quickly starting more
    /// independent tasks.
    @discardableResult
    func submitAgentAndOpenDetail() -> Bool {
        guard agentComposeActive else { return false }
        return submitAgent(openDetail: true)
    }

    @discardableResult
    private func submitAgent(openDetail: Bool = false) -> Bool {
        var prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Attached images alone are a valid task — a screenshot of the bug IS
        // the description. The CLIs still need some text next to the pixels, so
        // a wordless send rides a minimal stand-in instruction.
        if prompt.isEmpty {
            guard !agentComposeImages.isEmpty else { return false }
            prompt = Self.agentImageOnlyPrompt(count: agentComposeImages.count)
        }
        // No single-task gate: tasks run in parallel — a submit while others
        // are working just spawns another run.
        if let folder = agentComposeFolder {
            startAgentRun(folder: folder, prompt: prompt, openDetail: openDetail)
        } else {
            pickAgentFolder { [weak self] folder in
                self?.startAgentRun(folder: folder, prompt: prompt,
                                    openDetail: openDetail)
            }
        }
        return true
    }

    private func startAgentRun(folder: URL, prompt: String,
                               openDetail: Bool = false) {
        // Pass the model pick only if it still belongs to the armed engine —
        // a stale cross-engine leftover would 404 the run.
        let engine = agentArmedEngine
        let model = engine.modelChoices.contains { $0.id == agentModelID }
            ? agentModelID : nil
        // Same staleness rule for the effort: a level the picked engine+model
        // doesn't offer (e.g. ultra left over from another model) drops to the
        // CLI default rather than erroring the run.
        let effort = agentEffort.flatMap {
            engine.effortChoices(forModelID: model).contains($0) ? $0 : nil
        }
        // What actually ran is the truest "recent" signal there is — including the
        // CLI-default pick (`model == nil`), which is a choice like any other.
        AgentModelMRU.record(engine: engine, model: model)
        // Captured before the send clears them. Encoding a Retina
        // screenshot (downscale + JPEG) is real CPU — and there may now be
        // several — so it runs off-main, same as the chat path: the spawn waits
        // a beat but ⏎ stays instant. An image that fails to encode is dropped,
        // not fatal to the run.
        let images = agentComposeImages
        Task {
            var jpegs: [Data] = []
            if !images.isEmpty {
                jpegs = await Task.detached(priority: .userInitiated) {
                    images.compactMap { Self.encodeJPEGForVision($0) }
                }.value
            }
            if let taskID = AgentTaskManager.shared.start(
                folder: folder, prompt: prompt, engine: engine, model: model,
                effort: effort, imagesJPEG: jpegs
            ), openDetail {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    self.agentDetailTaskID = taskID
                }
            }
        }
        text = ""
        // The bucket survives its own send: sending a task doesn't mean you're done
        // sending tasks, so the compose stays armed on the same project and engine.
        // Only the attachments go — they belonged to the task just sent.
        withAnimation(.smooth(duration: 0.3)) { agentComposeImages = [] }
    }

    /// File a settled agent run into Recent as an ask-shaped record — the
    /// task description as the user turn, Codex's report as the answer — so the
    /// result outlives the card (dismiss, app restart) and reopens like any
    /// conversation. The answer footer carries "Codex · <folder>" so the row's
    /// thread reads as what it is. Keyed by the task id, so the finished banner's
    /// tap can route straight to this row. Reopening also makes the result
    /// follow-up-able: questions about it go to the chat model with the report
    /// in context.
    func recordAgentHistory(_ task: AgentTaskManager.AgentTask) {
        // Every settled round is an exchange — cancels and interrupted runs
        // included, so a run that ended badly still leaves a record; a follow-up
        // settles the same task id again with a longer thread, replacing the
        // previous record in place.
        guard let last = task.exchanges.last else { return }
        let footer = "\(task.engine.displayName) · \(task.folder.lastPathComponent)"
        var thread: [Turn] = []
        for exchange in task.exchanges {
            var promptTurn = Turn(role: "user", text: exchange.prompt)
            // The screenshots pasted into this round — often the whole task ("fix
            // this"), so the record is unreadable without them.
            promptTurn.imageFiles = exchange.imageFiles
            promptTurn.isAgent = true
            thread.append(promptTurn)
            var answerTurn = Turn(role: "assistant", text: exchange.answer)
            answerTurn.answerModel = footer
            // Marked as the agent's turn so the reopened thread knows what it is:
            // no regenerate on the report (the chat model can't redo the run),
            // and the follow-up field says who a question actually goes to.
            answerTurn.isAgent = true
            // The round's work trail rides the record, so the reopened thread
            // shows the same tool rows the live detail page does — patches and
            // plans included, hence `kind`. Trimmed on the way in: the archive is
            // one JSON file rewritten after every answer, so a marathon round
            // keeps its newest 200 steps and each captured output its first
            // 1200 chars (a patch needs more room than a command's tail did).
            if !exchange.log.isEmpty {
                answerTurn.agentLog = exchange.log.suffix(200).map {
                    AgentLogEntry(id: $0.id, title: $0.title, mono: $0.mono,
                                  detail: $0.detail.map { String($0.prefix(1200)) },
                                  kind: $0.kind)
                }
            }
            thread.append(answerTurn)
        }
        var item = HistoryItem(id: task.id, q: task.prompt, a: last.answer,
                               t: Date(), turns: thread, source: .agent)
        // The run's working folder, full path — what the reopened thread's and the
        // archive's open-folder buttons jump to. (The footer string above only
        // carries the last path component, for reading.)
        item.link = task.folder.path
        switch task.outcome {
        case .success:   item.agentOutcome = "success"
        case .failure:   item.agentOutcome = "failure"
        case .cancelled: item.agentOutcome = "cancelled"
        case nil:        break   // unreachable: only settled tasks are filed
        }
        // The CLI session handle rides EVERY settled row that has one — it's what
        // lets the reopened thread's follow-up go back to the agent, resuming the
        // run in place (`continueAgentThread`). `agentInterrupted` marks the rows
        // whose run the app died during; only those grow the explicit resume
        // button (`openAgentResume`).
        if let session = task.sessionID {
            item.agentResume = .init(engine: task.engine.rawValue,
                                     folderPath: task.folder.path,
                                     session: session)
        }
        item.agentInterrupted = task.interrupted
        history.removeAll { $0.id == task.id }
        history.insert(item, at: 0)
        // Straight to disk — NOT through the 0.4s save debounce — and the run's
        // in-flight crash marker clears only once the row is written. The
        // debounced path left a window (marker already cleared at settle, row
        // not yet on disk) where a crash erased the run without a trace.
        let settledTaskID = task.id
        saveHistoryNow { AgentTaskManager.clearInFlight(taskID: settledTaskID) }
    }

    /// Whether the on-screen thread is (or grew out of) an agent run's record.
    /// Drives the affordances that must read differently there: the follow-up
    /// placeholder names the chat model as the answerer, and the result header
    /// grows an open-folder button.
    var threadIsAgentRun: Bool { turns.contains { $0.isAgent } }

    /// The working folder of the agent run behind the on-screen thread — non-nil
    /// only for a reopened `.agent` row that kept its folder path. Drives the
    /// result header's open-folder button (parity with the live card's footer).
    var currentThreadAgentFolder: String? {
        guard threadIsAgentRun,
              let item = history.first(where: { $0.id == threadHistoryID }),
              item.source == .agent, let path = item.link, !path.isEmpty else { return nil }
        return path
    }

    /// When the agent run behind the on-screen thread finished — the reopened
    /// record's own timestamp (`recordAgentHistory` stamps it at settle). Drives
    /// the settled report footer's completion stamp. `nil` for non-agent threads
    /// and threads not backed by a saved record.
    var currentThreadCompletedAt: Date? {
        guard threadIsAgentRun,
              let item = history.first(where: { $0.id == threadHistoryID }),
              item.source == .agent else { return nil }
        return item.t
    }

    /// Jump to the reopened run's working folder in Finder — the result header's
    /// folder button. Deliberate app-leave, same as the capture jumps.
    func openThreadAgentFolder() {
        guard let path = currentThreadAgentFolder else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// The interrupted agent run behind the thread that's open right now, if any.
    /// Drives the result view's resume row: the open Recent row still holds the CLI
    /// session its run was killed in, so the answer can carry a button that picks it
    /// back up — no terminal, no copied command. `nil` for every other thread.
    var openAgentResume: (engine: AgentEngine, resume: HistoryItem.AgentResume)? {
        guard let item = history.first(where: { $0.id == threadHistoryID }),
              item.agentInterrupted,
              let resume = item.agentResume,
              let engine = AgentEngine(rawValue: resume.engine) else { return nil }
        return (engine, resume)
    }

    /// Re-issue the round the interruption cut off, in the CLI session it left
    /// behind — the button under an interrupted run's answer, and the GUI half of
    /// `AgentEngine.resumeCommand`. The task revives under this row's own id, so
    /// when it settles it re-files the SAME Recent row (interrupted marker and all
    /// replaced) instead of forking a second copy of the conversation. The panel
    /// drops back to idle, where the revived run rides the bucket row's badge like
    /// any other working task.
    func resumeAgentThread() {
        guard let item = history.first(where: { $0.id == threadHistoryID }),
              let resume = item.agentResume,
              let engine = AgentEngine(rawValue: resume.engine) else { return }

        // Rebuild the rounds from the saved thread. Everything before the last one
        // settled normally and stays in the transcript; the last IS the interrupted
        // round (its answer is the "Task interrupted" notice) — its prompt is what
        // goes back to the CLI, so the work resumes where it was cut off.
        var rounds: [AgentTaskManager.AgentExchange] = []
        var askedTurn: Turn? = nil
        for turn in item.conversation {
            if turn.role == "user" {
                askedTurn = turn
            } else if let asked = askedTurn {
                rounds.append(.init(prompt: asked.text, answer: turn.text,
                                    imageFiles: asked.imageFiles,
                                    log: turn.agentLog ?? []))
                askedTurn = nil
            }
        }
        guard let cut = rounds.popLast() else { return }
        // The screenshots that round rode in on go back out with it — they were
        // often the whole task ("fix this").
        let jpegs = cut.imageFiles.compactMap { try? Data(contentsOf: Self.historyImageURL($0)) }

        AgentTaskManager.shared.resume(taskID: item.id, engine: engine,
                                       folder: URL(fileURLWithPath: resume.folderPath),
                                       headline: item.q, session: resume.session,
                                       priorRounds: rounds, prompt: cut.prompt,
                                       imagesJPEG: jpegs)
        newChat()
    }

    /// The engine that can pick the on-screen agent thread's CLI session back up
    /// for a follow-up — non-nil only when the thread's record kept its session
    /// handle and that engine is still installed. Drives the follow-up routing
    /// (`submit` hands such a line to `continueAgentThread`) and the placeholder
    /// that says who answers.
    var agentThreadContinuation: AgentEngine? {
        guard threadIsAgentRun,
              let item = history.first(where: { $0.id == threadHistoryID }),
              let resume = item.agentResume,
              let engine = AgentEngine(rawValue: resume.engine),
              engine.isAvailable else { return nil }
        return engine
    }

    /// True while the on-screen agent thread's task is running a round right
    /// now (a follow-up already dispatched from this thread, or the settled
    /// tray card re-opened mid-round). Enter still routes to
    /// `continueAgentThread` — the manager queues the line for the next round —
    /// so the follow-up placeholder says "queued" instead of promising an
    /// immediate continue. (Freshness rides on views also observing
    /// `AgentTaskManager`, whose task changes re-render them.)
    var agentThreadTaskRunning: Bool {
        guard threadIsAgentRun else { return false }
        return AgentTaskManager.shared.tasks
            .first { $0.id == threadHistoryID }?.isRunning == true
    }

    /// Route a result-view follow-up back into the run's CLI session. The record
    /// in Recent IS the run's conversation now, so Enter on its thread means
    /// "next instruction to the agent", not "ask the chat model about this". The
    /// round then runs like any background task — the panel drops to idle, the
    /// status row carries the live activity — and on settle it re-files the SAME
    /// Recent row (task id == row id), so reopening lands on the grown thread.
    func continueAgentThread(prompt: String, images: [NSImage] = []) {
        guard let item = history.first(where: { $0.id == threadHistoryID }),
              let resume = item.agentResume,
              let engine = AgentEngine(rawValue: resume.engine) else { return }
        let dispatch: ([Data]) -> Void = { jpegs in
            let manager = AgentTaskManager.shared
            if manager.tasks.contains(where: { $0.id == item.id }) {
                // The run's task is still in the tray (its status row not yet
                // dismissed) — a plain follow-up round on it. Settled → spawns
                // now; still running → the manager queues it for the next round,
                // so a line typed mid-run is never dropped.
                manager.followUp(taskID: item.id, prompt: prompt, imagesJPEG: jpegs)
            } else {
                // The task is gone (row dismissed, or the app relaunched since):
                // rebuild the prior rounds from the record and spawn a resumed run
                // under the row's own id.
                var rounds: [AgentTaskManager.AgentExchange] = []
                var askedTurn: Turn? = nil
                for turn in item.conversation {
                    if turn.role == "user" {
                        askedTurn = turn
                    } else if let asked = askedTurn {
                        rounds.append(.init(prompt: asked.text, answer: turn.text,
                                            imageFiles: asked.imageFiles,
                                            log: turn.agentLog ?? []))
                        askedTurn = nil
                    }
                }
                manager.resume(taskID: item.id, engine: engine,
                               folder: URL(fileURLWithPath: resume.folderPath),
                               headline: item.q, session: resume.session,
                               priorRounds: rounds, prompt: prompt,
                               imagesJPEG: jpegs)
            }
        }
        if images.isEmpty {
            dispatch([])
        } else {
            Task {
                let jpegs = await Task.detached(priority: .userInitiated) {
                    images.compactMap { Self.encodeJPEGForVision($0) }
                }.value
                dispatch(jpegs)
            }
        }
        newChat()
    }

    /// "42s" / "12m 05s" — the one elapsed format for background work: the
    /// agent card, the no-report fallback answer, and the resting notch's
    /// busy ear all read the same clock.
    static func formatAgentElapsed(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s < 60 ? "\(s)s" : String(format: "%dm %02ds", s / 60, s % 60)
    }

    /// ⌘↵: submit the current line to the *other family* — the one-key flip for
    /// when the effective destination reads the line wrong. There are two families:
    /// **Ask** (send to the AI) and **Capture** (keep for yourself). Flipping
    /// ask→capture picks the leaf by the same structural rule auto-routing uses —
    /// a named future time makes it a Reminder, otherwise a Note — so a manual
    /// flip can never file differently than the classifier would have. Either
    /// capture leaf flips back to Ask. Tab stays the precise three-way pick
    /// (`toggleSubmitPanel`); this is the coarse, no-look correction.
    func submitOtherFamily() {
        switch effectiveSubmitPanel {
        case .chat:
            if detectedDue != nil { submitReminder() } else { submitNote() }
        case .note, .reminder:
            submit()
        }
    }

    /// The clipboard string that's *available* as fresh outside context, or `nil`
    /// when the clipboard itself isn't a candidate. Used by deictic note capture
    /// ("save this" folds the copied URL/snippet into the note body). Available
    /// means: the user copied for *this*
    /// session — the `changeCount` has moved past its pre-open resting baseline, which
    /// covers the intended copy-THEN-open flow (the baseline is the count from before
    /// the open; see `pasteboardChangeCountAtOpen`) as well as a copy made while the
    /// panel is open; the clipboard holds a non-empty string, URL, or file URL; and
    /// it's short enough (≤ 1500 chars) to inject without blowing up the prompt;
    /// and it isn't text this session is itself displaying (see
    /// `isCurrentSessionText` — an in-panel copy never counts as outside context).
    /// Anything longer than 1500 chars, an image, or a stale clipboard returns nil.
    /// Never mutates the pasteboard.
    private func clipboardContextIfEligible() -> String? {
        let pb = NSPasteboard.general
        guard pb.changeCount != pasteboardChangeCountAtOpen else { return nil }
        // Read priority: plain string (the common case) → "Copy Link" URL → Finder
        // file path. Safari/Chrome's right-click "Copy Link" writes `.URL` with no
        // `.string` companion, so a copied link would otherwise read as nil and inject
        // nothing on "summarize this link"; a Cmd-C from the address bar DOES write
        // `.string`, so it resolves in the first arm. Finder file copies write
        // `.fileURL` (a file:// URI) with no `.string`. First non-nil arm wins, so
        // plain-text copies are completely unaffected.
        let raw = pb.string(forType: .string)
               ?? pb.string(forType: .URL)
               ?? pb.string(forType: .fileURL)
        guard let s = raw else { return nil }
        let clip = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clip.isEmpty, clip.count <= 1500 else { return nil }
        // Text already visible inside this session is an *in-app* copy, not outside
        // context — quoting it back adds nothing. This catches the copies our code
        // never sees (⌘C in the input field, selecting answer text), which bypass
        // `rebaselineClipboardAfterInAppWrite` because the system performs them.
        guard !isCurrentSessionText(clip) else { return nil }
        return clip
    }

    /// True when `clip` (already trimmed) is text the current session itself is
    /// showing: the input-box draft, the parked idle draft, or a turn of the
    /// on-screen conversation. Turns also match on *containment* for clips of
    /// ≥ 40 chars, so a partial selection copied out of an answer still counts as
    /// in-app; short clips must match a whole turn exactly, so a word copied from
    /// another app that merely appears somewhere in the answer isn't swallowed.
    private func isCurrentSessionText(_ clip: String) -> Bool {
        func matches(_ s: String) -> Bool {
            let body = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return clip == body || (clip.count >= 40 && body.contains(clip))
        }
        return matches(text) || matches(savedIdleDraft) || turns.contains { matches($0.text) }
    }

    /// The clipboard image available to attach to an Ask (XII-121), or `nil`.
    /// Gated on the ACTIVE MODEL first: only a model known to read images (see
    /// `Provider.modelSupportsVision`) gets the thumbnail at all — a text-only
    /// model shows no preview rather than promising an attach that would fail.
    /// Then the same freshness gate as the text path (the changeCount must have
    /// moved past the pre-open baseline), and only consulted when NO eligible
    /// text clip exists — a copied string always wins, so nothing about the text
    /// flow changes. `NSImage(pasteboard:)` reads PNG/TIFF (the screenshot
    /// formats) and returns nil for a text-only pasteboard.
    /// Can the model an Ask would go to right now actually read an image? Gates both
    /// the clipboard thumbnail below and the re-attach of a reopened thread's saved
    /// image — nothing offers or sends pixels a text-only model would choke on.
    /// Codex / Claude Code / Grok (CLI backends) count as text-only here: their
    /// models report as vision-capable by id, but the chat path doesn't forward
    /// images to the subprocess, so an attach there would be silently dropped.
    private var activeModelSupportsVision: Bool {
        let provider = APIKeyStore.selectedProvider
        let model = APIKeyStore.effectiveModel(for: provider) ?? provider.defaultModel
        guard provider != .codex, provider != .claudeCode, provider != .grokCode,
              provider != .piCode else { return false }
        return Provider.modelSupportsVision(model)
    }

    /// Downsample + encode an attached image (XII-121): long side capped at 1568px
    /// (Anthropic's documented vision sweet spot; also keeps any provider's payload
    /// sane), JPEG at 0.82 — a full-screen Retina screenshot lands in the
    /// hundreds-of-KB range instead of many MB. Returns `nil` when the bitmap can't
    /// be read or encoded, in which case the turn just goes out as plain text.
    /// Every consumer takes these same bytes: the chat wraps them as a base64
    /// `ChatImage`, the agent hands them to its CLI (a temp file for codex's
    /// `exec -i`, a base64 vision block for claude's stream-json stdin), and the
    /// history store keeps them as the saved thumbnail.
    /// `nonisolated`: the downscale + JPEG of a Retina screenshot is real CPU, so
    /// callers run it on a detached task (see the encode step at the top of the
    /// round's task) instead of on the main actor at the moment of ⏎. Everything
    /// here draws into an offscreen bitmap context, which is safe off the main thread.
    nonisolated static func encodeJPEGForVision(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0 else { return nil }
        let maxSide = 1568
        let scale = min(1.0, Double(maxSide) / Double(max(w, h)))
        let finalRep: NSBitmapImageRep
        if scale < 1.0 {
            let outW = max(1, Int(Double(w) * scale))
            let outH = max(1, Int(Double(h) * scale))
            guard let resized = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: outW, pixelsHigh: outH,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return nil }
            // Draw in pixel space: pin the rep's point size to its pixel size so
            // the NSImage draw isn't rescaled by a Retina points-vs-pixels factor.
            resized.size = NSSize(width: outW, height: outH)
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: resized) {
                NSGraphicsContext.current = ctx
                image.draw(in: NSRect(x: 0, y: 0, width: outW, height: outH),
                           from: .zero, operation: .copy, fraction: 1.0)
                ctx.flushGraphics()
            }
            NSGraphicsContext.restoreGraphicsState()
            finalRep = resized
        } else {
            finalRep = rep
        }
        return finalRep.representation(using: .jpeg,
                                       properties: [.compressionFactor: 0.82])
    }

    /// Whole-word containment for the Latin-script gates in `isDeicticNoteCapture` —
    /// avoids "it" firing inside "edit" or "this" inside "thistle". Loops over every
    /// occurrence so a non-boundary first hit doesn't mask a later word-boundary one.
    /// Builds a manual boundary test rather than dragging in NSRegularExpression.
    private func containsWord(_ word: String, in haystack: String) -> Bool {
        var start = haystack.startIndex
        while start < haystack.endIndex,
              let r = haystack.range(of: word, range: start..<haystack.endIndex) {
            let isBoundary: (Character?) -> Bool = { c in
                guard let c else { return true }            // string edge is a boundary
                return !(c.isLetter || c.isNumber)
            }
            let before = r.lowerBound > haystack.startIndex
                ? haystack[haystack.index(before: r.lowerBound)] : nil
            let after = r.upperBound < haystack.endIndex
                ? haystack[r.upperBound] : nil
            if isBoundary(before) && isBoundary(after) { return true }
            start = haystack.index(after: r.lowerBound)
        }
        return false
    }

    /// Rough char budget for the wired conversation history. A long thread grows
    /// unbounded turn by turn; left uncapped it eventually overruns the provider's
    /// context window, which comes back as a non-retryable 400 that kills the turn
    /// outright (not a graceful "too long"). We trim the OLDEST turns first, keeping
    /// the tail — the current question and its recent lead-up, which is what the
    /// answer actually depends on. ~48k characters is a conservative few-k-token
    /// slice that leaves ample room for the system prompt, tools, and the reply on
    /// every provider we ship, while still holding many turns of normal chat.
    private static let wireContextCharBudget = 48_000

    /// The wire copy of the thread for `submit()` (XII-88). Drops, besides the new
    /// round's placeholder, the assistant turns that never became a real answer:
    ///   - an *empty* turn left behind when a follow-up superseded a round before
    ///     its first token (Anthropic 400s on empty assistant content);
    ///   - an *error* turn holding the failure reason the XII-85 card wrote (the
    ///     model would read "Anthropic · HTTP 401" as its own prior reply).
    /// Dropping a turn can leave two user messages adjacent, which Anthropic also
    /// rejects (roles must alternate) — so consecutive same-role messages are
    /// merged. Only this wire copy is filtered; the visible thread keeps every turn.
    /// Also trims the oldest turns past `wireContextCharBudget` — see there.
    private static func wireContext(from turns: [Turn], excluding answerID: UUID)
        -> [ChatMessage]
    {
        // Keep only the turns that will actually be wired (same hygiene filter as
        // below), then walk from the newest backwards, admitting turns until the
        // char budget is spent. The current question is the last kept turn, so it is
        // always admitted first — a single turn is never dropped for being too big,
        // it's just the only one that fits. Older turns beyond the budget fall off.
        let wirable = turns.filter { turn in
            if turn.id == answerID { return false }
            if turn.role == "assistant" {
                let body = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty || turn.isError { return false }
            }
            return true
        }
        var kept: [Turn] = []
        var used = 0
        for turn in wirable.reversed() {
            // Admit the newest turn unconditionally; after that, stop once adding the
            // next-older turn would blow the budget (older history just drops off).
            if !kept.isEmpty && used + turn.text.count > wireContextCharBudget { break }
            used += turn.text.count
            kept.insert(turn, at: 0)
        }
        // The untrimmed list always opened with the thread's first user question;
        // the budget cut can land between a question and its answer, leaving an
        // assistant turn first — which Anthropic rejects (the conversation must
        // open with a user turn). Drop any leading assistant turns so the trimmed
        // window still starts on a user message.
        while kept.first?.role == "assistant" { kept.removeFirst() }

        var messages: [ChatMessage] = []
        for turn in kept {
            if let last = messages.last, last.role == turn.role {
                messages[messages.count - 1] = ChatMessage(
                    role: turn.role, content: last.content + "\n\n" + turn.text)
            } else {
                messages.append(ChatMessage(role: turn.role, content: turn.text))
            }
        }
        return messages
    }

    func submit(hideUserBubble: Bool = false) {
        // A line the user actually typed ends the shortcut's one-shot character —
        // from here the thread is an ordinary conversation, so the follow-up input
        // goes back to being a full field instead of a collapsed button.
        if !hideUserBubble { fromPromptShortcut = false }
        var q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pastedImages = askComposeImages
        if q.isEmpty {
            guard !pastedImages.isEmpty else { return }
            q = Self.agentImageOnlyPrompt(count: pastedImages.count)
        }
        // A follow-up on an agent thread whose CLI session is still resumable
        // goes back to the AGENT, not the chat model: the result view is the
        // run's conversation, so Enter there means "next instruction". Only
        // when the session is gone (no handle on record / engine uninstalled)
        // does the line fall through to the chat model, report as context.
        if agentThreadContinuation != nil {
            text = ""
            askComposeImages = []
            continueAgentThread(prompt: q, images: pastedImages)
            return
        }
        // Clear any prior error state — this attempt replaces it (XII-85).
        askError = nil
        // One-shot regenerate-with-model override (XII-135): build a service pinned
        // to the picked model for THIS turn only, without touching the saved
        // default. Consumed + cleared here. `regenModel` is stamped onto the answer
        // turn below so the result shows which model produced it.
        let overrideModel = regenOverrideModel
        let overrideProvider = regenOverrideProvider
        regenOverrideModel = nil
        regenOverrideProvider = nil
        // A prompt shortcut can pin a backend other than the selected one, so the
        // override builds against ITS provider.
        let pinnedProvider = overrideProvider ?? APIKeyStore.selectedProvider
        let overrideService: AIService? = overrideModel.flatMap { m in
            // Build the explicitly selected backend even if its credentials have
            // since disappeared. The resulting request will surface that setup
            // error instead of falling back to an unrelated default provider.
            return AppDelegate.makeService(provider: pinnedProvider,
                                           apiKey: APIKeyStore.keyOrEmpty(for: pinnedProvider),
                                           model: m)
        }
        // The provider this round actually streams from — the pin only counts once
        // its service exists. Everything provider-scoped below (tool registry, tool
        // support, recents) follows the service, never the setting behind it.
        let runProvider = overrideService == nil ? APIKeyStore.selectedProvider : pinnedProvider
        // This ask "uses" the model it will stream from — feed the chip menu's
        // recents (the one-shot regenerate override counts as the model used).
        let askProvider = runProvider
        AskModelMRU.record(provider: askProvider,
                           model: overrideModel
                               ?? APIKeyStore.effectiveModel(for: askProvider)
                               ?? askProvider.defaultModel)
        text = ""
        askComposeImages = []
        showHistory = false
        highlightedHistoryIndex = nil

        // A first question starts a fresh thread: give it a new history id so it
        // becomes its own recent row. A follow-up keeps the existing id, so the
        // whole conversation stays one row, updated in place. Captured before the
        // append below empties this out — clipboard injection keys off it too
        // (only a first turn pulls in the clipboard).
        let firstTurn = turns.isEmpty
        if firstTurn { threadHistoryID = UUID() }
        // Submitting never touches the pin. A follow-up keeps the pin the user set
        // to read the thread (asking on doesn't fold it), and a first question keeps
        // the pin set on the idle prompt — the only way one can be armed here, since
        // `newChat` / `fullClose` both clear it as they empty `turns`. Dropping it on
        // a first turn would fold the panel on leave exactly when the answer arrives.

        // A follow-up sent while the previous answer is still streaming supersedes
        // it: settle any stale streaming flag now, because the superseded task is
        // cancelled below and will never settle it itself.
        for i in turns.indices where turns[i].streaming { turns[i].streaming = false }

        // Append this question and an empty assistant turn it'll stream into. On a
        // first question `turns` is empty (fresh thread); on a follow-up the prior
        // turns are already here, so the new pair just extends the conversation.
        let questionTurn = Turn(role: "user", text: q,
                                hidesUserBubble: hideUserBubble)
        // Held so the deferred image encode below can find this exact turn again —
        // by id, never by index, since the thread on screen may have moved on (a new
        // chat, a reopened row) by the time the JPEG lands.
        let questionID = questionTurn.id
        turns.append(questionTurn)
        let answerID = UUID()
        var answerTurn = Turn(id: answerID, role: "assistant", text: "", streaming: true)
        // Stamp the one-shot regenerate model (XII-135) so the answer shows which
        // model produced it; rides into the saved snapshot below.
        answerTurn.regenModel = overrideModel
        turns.append(answerTurn)

        // The history sent to the model: every completed turn, plus the new
        // question — but NOT the empty assistant placeholder we just appended,
        // and minus the hygiene cases `wireContext` filters (XII-88): a superseded
        // round's still-empty assistant turn and an error card's reason text, both
        // of which providers either reject outright or misread as model speech.
        var context: [ChatMessage] = Self.wireContext(from: turns, excluding: answerID)

        let system = notchSystemPromptDated(customInstructions: customInstructions)

        // Explicitly pasted images attach to the newest wire message. The encoded
        // set is also parked on the thread so follow-ups still see every image.
        // Image rounds skip the agent harness (its tool wire has no image blocks).
        var imageAttached = false
        let pendingVisionImages = pastedImages
        if !pendingVisionImages.isEmpty {
            imageAttached = true
            if turns.count >= 2 { turns[turns.count - 2].usedClipboard = true }
        } else if !firstTurn, let parked = threadImages, parked.threadID == threadHistoryID,
                  let firstUser = context.firstIndex(where: { $0.role == "user" }) {
            context[firstUser].images = parked.images
            imageAttached = true
        }

        // Fresh thinking word for this answer's pre-stream wait, rotating slowly
        // while we wait so a long search/compose round doesn't freeze on one word.
        // Light the thinking dots for this round (cleared on the first token or when
        // the round ends) — they ride beside the notch even if the panel folds away.
        thinking = true
        thinkingAnswerID = answerID
        startThinkingWordRotation(for: q, answerID: answerID)
        mode = .load

        // The task owns a value-type snapshot of the thread it's answering, plus
        // the thread id captured here. Backing out (`newChat`) or closing the panel
        // (`fullClose`) only detaches the screen — the task keeps streaming into
        // its snapshot and persists the finished round to Recent, so an in-flight
        // round is never lost. The snapshot is also what gets saved, so whatever
        // `turns` shows by completion time (a new chat, a reopened history item,
        // nothing at all) can never leak into this thread's history row.
        let threadID = threadHistoryID
        let seedThread = turns

        // A first question parks a placeholder row in Recent right now, so leaving
        // the conversation mid-answer (collapse / newChat / close) shows the
        // question with a three-dot "answering…" marker instead of an empty list
        // that only fills in once the answer finishes. Follow-ups stream into the
        // row their first turn already created. The same-id row is replaced in
        // place by `persistThread` on completion, or removed by `settlePending` if
        // the round yields nothing.
        if firstTurn { parkPending(threadID: threadID, question: q) }

        // Cancelling here only ever supersedes within the SAME on-screen round (a
        // follow-up sent while the previous answer streams): detached tasks have
        // already cleared this slot, so they're out of reach.
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            // Count this round in flight for the resting notch's background
            // indicator, and park its live mirror for reattach-on-open; the
            // defer pairs the teardown with every way out of this task —
            // finish, error, and supersede-cancel alike.
            self.roundsInFlight += 1
            // A round starting from idle owns the busy ear's phase from scratch.
            if self.inFlightRounds.isEmpty { self.backgroundWriting = false }
            self.inFlightRounds.append(
                InFlightRound(answerID: answerID, threadID: threadID, thread: seedThread))
            defer {
                self.roundsInFlight -= 1
                self.inFlightRounds.removeAll { $0.answerID == answerID }
                self.compactRoundTasks[threadID] = nil
                // Don't let the last round's tool label / write phase outlive
                // it on the collapsed notch's busy ear.
                if self.inFlightRounds.isEmpty {
                    self.backgroundActivity = nil
                    self.backgroundWriting = false
                }
                // A question can't normally outlive its round (cancellation and the
                // timeout both resolve it), but never strand a card on screen — or a
                // parked continuation — if one somehow does.
                for q in self.pendingUserQuestions where q.answerID == answerID {
                    self.resolveUserQuestion(q.id, with: .failure(CancellationError()))
                }
            }
            // The deferred vision encode (see `pendingVisionImage` above): produce
            // the wire bytes off the main actor, then attach them to the outgoing
            // context — nothing reads `context` until the stream starts below, so
            // the suspension is invisible beyond the thinking dots it happens under.
            // The same bytes are parked in the image store, so the row this round
            // settles into keeps the picture it was asked about.
            var savedImageFiles: [String] = []
            if !pendingVisionImages.isEmpty {
                let jpegs = await Task.detached(priority: .userInitiated) {
                    pendingVisionImages.compactMap { Self.encodeJPEGForVision($0) }
                }.value
                let encoded = jpegs.map {
                    ChatImage(base64: $0.base64EncodedString(), mediaType: "image/jpeg")
                }
                if !encoded.isEmpty {
                    context[context.count - 1].images = encoded
                    self.threadImages = (threadID: threadID, images: encoded)
                    savedImageFiles = await Task.detached(priority: .utility) {
                        jpegs.compactMap { Self.storeHistoryImage($0) }
                    }.value
                    if let i = self.turns.firstIndex(where: { $0.id == questionID }) {
                        self.turns[i].imageFiles = savedImageFiles
                    }
                }
            }
            var thread = seedThread
            // …and on the snapshot that actually gets persisted — `seedThread` was
            // captured before the encode finished, so it still has the bare question.
            if !savedImageFiles.isEmpty,
               let i = thread.firstIndex(where: { $0.id == questionID }) {
                thread[i].imageFiles = savedImageFiles
            }
            // Hoisted out of `do` so the error `catch` can read whatever streamed
            // before the failure — a mid-stream drop that already produced text must
            // persist that partial round, not discard it (see the catch below).
            var acc = ""
            // Throttle + pacing state for the streamed-text sink below. Providers
            // deliver deltas far faster than the display refreshes (some near
            // per-character) and in uneven bursts (a stall, then a slab), and
            // every write to `turns` re-evaluates NotchBody's whole tree (via
            // `ConversationStore`) and re-parses the growing tail's markdown — so
            // the per-chunk work is limited to accumulating into `acc`, and one
            // shared flush loop reveals the text at most ~30 times a second AND
            // at a smoothed rate: a burst is smeared across up to `paceMaxLag`
            // seconds instead of slamming in as one frame's slab.
            // Hoisted with `acc` so the catch paths can settle the throttle (a
            // trailing scheduled flush must never overwrite their final text).
            var pendingFlush: DispatchWorkItem? = nil
            var lastFlushAt: TimeInterval = 0
            var streamSettled = false
            // Pacing: how many characters of `acc` the UI currently shows, plus
            // the fractional remainder the integer step leaves behind each tick.
            var released = 0
            var releaseBudget: Double = 0
            do {
                // Push the PACED prefix of what's accumulated into the model/UI —
                // the one place the streamed text performs @Published writes.
                // Shared by the plain and agent paths so the snapshot threading,
                // first-chunk mode-flip, and on-screen guard live in exactly one
                // place. Main-actor (the task inherits it), so it can mutate the
                // task-local `acc`/`thread` and touch UI directly. `[weak self]`
                // mirrors the task; on a detached round `self` is gone and the
                // closure is a no-op.
                let flushInterval: TimeInterval = 1.0 / 30.0
                // The reveal rate self-regulates around one invariant: the display
                // never trails what has arrived by more than `paceMaxLag` seconds
                // (rate = backlog / maxLag, floored at `paceMinRate` so a trickle
                // still types along). Small bursts get smeared into a calm walk;
                // a giant slab still clears quickly — just smoothly.
                let paceMaxLag: TimeInterval = 1.2
                let paceMinRate: Double = 40   // characters per second
                // How long the close-out below is allowed to take. Short enough
                // that the settled footer reads as arriving WITH the last words,
                // long enough that a big remaining backlog still ramps out instead
                // of landing as one frame's slab — the very thing the pacing above
                // exists to prevent.
                let drainWindow: TimeInterval = 0.25
                // Non-nil once arrival has finished: the flat characters-per-second
                // that empties whatever is still buffered within `drainWindow`,
                // computed ONCE at that moment (see the close-out below). While it
                // is nil the live rate law above applies.
                //
                // Why the live law must not keep running past the end of the
                // stream: `rate = backlog / paceMaxLag` is derived from an
                // invariant about a LIVE stream — "the display never trails what
                // has arrived by more than 1.2s". Once nothing more is arriving
                // there is nothing left to smooth against, and the law decays
                // exponentially (τ = paceMaxLag) into the `paceMinRate` floor, so
                // the tail crawls exactly where the reader has already caught up:
                // a 240-character backlog took ~3s to finish, a short answer paid
                // 40 c/s all the way out. Nothing downstream can settle until it
                // does — `streaming` (and with it the answer's footer) flips only
                // after this drains — so that crawl was read as the footer lagging
                // the answer.
                var closeOutRate: Double? = nil
                var flushChunks: @MainActor () -> Void = {}
                flushChunks = { [weak self] in
                    guard let self, !streamSettled else { return }
                    pendingFlush?.cancel()
                    pendingFlush = nil
                    let now = ProcessInfo.processInfo.systemUptime
                    // First tick (lastFlushAt == 0) counts as one interval, so the
                    // very first characters paint immediately — time-to-first-paint
                    // is untouched by pacing.
                    let dt = lastFlushAt == 0 ? flushInterval : min(now - lastFlushAt, 0.25)
                    lastFlushAt = now
                    let backlog = acc.count - released
                    if backlog > 0 {
                        // Closing out (arrival done) → the flat rate fixed at that
                        // moment; still streaming → the live self-regulating law.
                        let rate = closeOutRate
                            ?? max(paceMinRate, Double(backlog) / paceMaxLag)
                        releaseBudget += rate * dt
                        let step = min(backlog, Int(releaseBudget))
                        if step > 0 {
                            releaseBudget -= Double(step)
                            released += step
                        }
                    }
                    let shown = released >= acc.count ? acc : String(acc.prefix(released))
                    if let i = thread.firstIndex(where: { $0.id == answerID }) {
                        thread[i].text = shown
                    }
                    // Keep the reattach mirror current, so an open mid-stream
                    // restores everything revealed so far, not a stale snapshot.
                    self.syncInFlight(answerID, thread)
                    // The on-screen turn must still be live: a stop (Esc) settles
                    // it synchronously while this task is still being cancelled,
                    // and a trailing scheduled flush must not grow a turn the
                    // user already froze (what they saw at stop is what persists).
                    if self.isOnScreen(answerID: answerID),
                       self.turns.first(where: { $0.id == answerID })?.streaming == true {
                        // First real token ends the pre-stream wait: freeze the
                        // rotating thinking word (the dots/word fade out now anyway).
                        // Freeze ONLY — a full stop would also clear the tool
                        // activity, and a tool can still be running under this very
                        // text (a preface before a search): its line must survive.
                        self.freezeThinkingWord(for: answerID)
                        // First chunk: flip to the result view so the answer appears
                        // to grow in place out of the thinking state.
                        if self.mode == .load { self.mode = .result }
                        self.updateAnswer(id: answerID, text: shown)
                    }
                    // Keep draining: while revealed text still trails what has
                    // arrived, the loop schedules its own next tick — a stall in
                    // ARRIVALS must not stall the reveal (the old throttle only
                    // ticked when chunks landed, which is exactly what let a
                    // burst's slab sit until the next burst).
                    if released < acc.count, pendingFlush == nil {
                        let work = DispatchWorkItem { MainActor.assumeIsolated { flushChunks() } }
                        pendingFlush = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + flushInterval, execute: work)
                    }
                }
                // The per-chunk sink: accumulate, then tick now if the throttle
                // window has passed (the first chunk always has — `lastFlushAt`
                // starts at 0 — so time-to-first-paint is untouched), else make
                // sure ONE trailing tick is scheduled for the window's end; from
                // there the flush loop keeps itself alive until drained.
                let appendChunk: @MainActor (String) -> Void = { [weak self] piece in
                    guard let self else { return }
                    acc += piece
                    // First real text for this round ends the thinking phase — clear the
                    // dots even if the panel folded away (the round is detached but still
                    // ours). Idempotent: only the round that owns the flag clears it.
                    self.endThinking(for: answerID)
                    // Mark the write phase for the collapsed busy ear — guarded
                    // so it publishes once per round, never per chunk.
                    if !self.backgroundWriting { self.backgroundWriting = true }
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastFlushAt >= flushInterval {
                        flushChunks()
                    } else if pendingFlush == nil {
                        let work = DispatchWorkItem { MainActor.assumeIsolated { flushChunks() } }
                        pendingFlush = work
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + (flushInterval - (now - lastFlushAt)),
                            execute: work)
                    }
                }

                // Agent path when the backend can drive tools AND there are tools to
                // offer; otherwise the plain single-shot stream. The harness reads
                // tool calls, runs them, and threads the results back over several
                // turns — but to the UI it's the same growing answer. Any provider
                // that can't do tools, or a turn with an empty registry, falls
                // straight back to the existing behavior: nothing about plain Q&A
                // changes.
                // The standard tool set, plus the two tools that can't live in
                // `ToolRegistry.standard(for:)` because they need the live model:
                //  · `ask_user` — its suspension is owned by the model
                //    (`awaitUserChoice`), keyed to THIS round's answer turn so the
                //    question card renders under the answer it interrupts;
                //  · `manage_app_settings` — reads the live model-backed preferences
                //    and reuses this round's question card as its mandatory write
                //    confirmation gate;
                //  · `search_history` — reads the archive off `history`, which is
                //    main-actor state on this object;
                //  · `create_note` / `create_reminder` — the second write surface,
                //    gated on the same in-answer confirmation card and filing their
                //    Recent row through the model that owns `history`.
                var agentTools = ToolRegistry.standard(for: runProvider).tools
                agentTools.append(ManageAppSettingsTool { [weak self] request in
                    guard let self else { throw CancellationError() }
                    return try await self.handleAppSettingsRequest(answerID: answerID,
                                                                   request: request)
                })
                agentTools.append(AskUserTool { [weak self] question, options in
                    guard let self else { throw CancellationError() }
                    return try await self.awaitUserChoice(answerID: answerID,
                                                          question: question,
                                                          options: options)
                })
                agentTools.append(CreateNoteTool { [weak self] request in
                    guard let self else { throw CancellationError() }
                    return try await self.handleCaptureRequest(answerID: answerID,
                                                               request: request)
                })
                agentTools.append(CreateReminderTool { [weak self] request in
                    guard let self else { throw CancellationError() }
                    return try await self.handleCaptureRequest(answerID: answerID,
                                                               request: request)
                })
                agentTools.append(SearchHistoryTool { [weak self] query in
                    // A round whose model went away has no archive to read; an empty
                    // digest renders as "nothing recorded", which is honest.
                    guard let self else { return .empty }
                    return await MainActor.run { self.searchArchive(query) }
                })
                let registry = ToolRegistry(agentTools)
                // The service for THIS turn: a one-shot regenerate override (XII-135)
                // wins, else the main service. An upgraded model still gets the tool
                // harness below (search etc.), so the override rides both paths.
                let askService: AIService = overrideService ?? self.ai
                if !imageAttached,
                   let agent = askService as? AgentCapableService,
                   runProvider.supportsTools,
                   !registry.isEmpty {
                    let harness = AgentHarness(service: agent, registry: registry)
                    let agentMessages = context.map {
                        AgentMessage(kind: .text(role: $0.role, text: $0.content))
                    }
                    try await harness.run(
                        system: system,
                        messages: agentMessages,
                        onText: appendChunk,
                        onActivity: { [weak self] label, orb in
                            guard let self else { return }
                            // Every round feeds the background slot, on screen
                            // or detached — the collapsed notch's busy ear shows
                            // the same live line the panel would ("Searching the
                            // web…", "Reading github.com…"). This must sit BEFORE
                            // the isOnScreen gate: a detached round is exactly
                            // the one the resting notch is reporting on.
                            self.backgroundActivity = label
                            // The detached thread mirror needs the same live state:
                            // its header and answer wait row must say Search / Read /
                            // Calculate rather than falling back to a hard-coded verb.
                            if let i = thread.firstIndex(where: { $0.id == answerID }) {
                                thread[i].toolActivity = label
                                thread[i].thinkingOrbState = label == nil
                                    ? (Self.taskStyle(for: q)?.orb ?? .composing)
                                    : orb
                                self.syncInFlight(answerID, thread)
                            }
                            // The activity line only shows on a still-on-screen
                            // round; a detached harness silently ignores it.
                            if self.isOnScreen(answerID: answerID) {
                                if self.mode == .load { self.mode = .result }
                                self.updateActivity(id: answerID, label: label, orb: orb)
                            }
                        },
                        onSources: { [weak self] roundSources in
                            guard let self else { return }
                            if !roundSources.isEmpty {
                            }
                            // Accumulate sources across rounds onto the snapshot
                            // (so they persist with the thread) and, when on screen,
                            // the live turn (so the badge appears). Deduped by URL.
                            if let i = thread.firstIndex(where: { $0.id == answerID }) {
                                thread[i].sources = Self.mergedSources(thread[i].sources, roundSources)
                                self.syncInFlight(answerID, thread)
                            }
                            if self.isOnScreen(answerID: answerID) {
                                self.appendSources(id: answerID, roundSources)
                            }
                        },
                        onModel: { [weak self] ran in
                            guard let self else { return }
                            // Stamp the concrete model on both the persisted snapshot
                            // and the on-screen turn, mirroring `onSources`, so the
                            // footer shows which model actually replied.
                            if let i = thread.firstIndex(where: { $0.id == answerID }) {
                                thread[i].answerModel = ran
                                self.syncInFlight(answerID, thread)
                            }
                            if self.isOnScreen(answerID: answerID),
                               let i = self.turns.firstIndex(where: { $0.id == answerID }) {
                                self.turns[i].answerModel = ran
                            }
                        })
                } else {
                    // A regenerate override (XII-135) streams from its pinned
                    // service; everything else uses the main model.
                    let service = askService
                    // Stamp the model that answered, so the reply footer shows it. The
                    // harness path does this via `onModel`; this plain-stream path
                    // (Codex and other non-tool turns) otherwise left the footer blank.
                    let ranModel = overrideModel
                        ?? APIKeyStore.effectiveModel(for: runProvider)
                        ?? runProvider.defaultModel
                    if let i = thread.firstIndex(where: { $0.id == answerID }) {
                        thread[i].answerModel = ranModel
                        self.syncInFlight(answerID, thread)
                    }
                    if self.isOnScreen(answerID: answerID),
                       let i = self.turns.firstIndex(where: { $0.id == answerID }) {
                        self.turns[i].answerModel = ranModel
                    }
                    for try await chunk in service.stream(system: system, messages: context) {
                        if Task.isCancelled { return }
                        appendChunk(chunk)
                    }
                }
                if Task.isCancelled { return }
                // Arrival is over. Switch the throttle to close-out: one flat rate,
                // fixed here, that empties whatever is still buffered in
                // `drainWindow` — a short linear ramp instead of the live law's
                // long exponential tail (see `closeOutRate`). The floor still
                // applies so a couple of trailing characters don't crawl.
                closeOutRate = max(paceMinRate,
                                   Double(acc.count - released) / drainWindow)
                // Let that close-out finish walking what's still buffered before
                // settling, so the tail ramps out instead of snapping in. Bounded
                // twice over: the flat rate empties the backlog in `drainWindow`,
                // and a hard deadline covers any stall.
                // Cancellation (Esc / superseded) breaks out — the catch paths
                // settle instantly, and what the user saw at stop is what persists.
                let drainDeadline = ProcessInfo.processInfo.systemUptime + 3
                while released < acc.count, !Task.isCancelled,
                      ProcessInfo.processInfo.systemUptime < drainDeadline {
                    try? await Task.sleep(nanoseconds: 33_000_000)
                }
                if Task.isCancelled { return }
                // Final flush: the terminal writes below must see the complete
                // text (pieces may still be buffered inside the throttle window,
                // or left by the drain deadline), and settling the flag keeps a
                // trailing scheduled flush from firing after them.
                released = acc.count
                flushChunks()
                streamSettled = true
                self.stopThinkingWordRotation(for: answerID)
                self.endThinking(for: answerID)
                if let i = thread.firstIndex(where: { $0.id == answerID }) {
                    thread[i].streaming = false
                }
                // Captured BEFORE persist: whether this round finished detached —
                // the user walked away while it streamed, so the panel folded back
                // to the resting notch (the three dots). When so, fire a native
                // banner so the finished answer doesn't just quietly go out.
                let walkedAway = !self.isPresented(answerID: answerID)
                self.markFinished(id: answerID)   // no-op when detached
                self.persistThread(thread, threadID: threadID, answer: acc)
                if walkedAway {
                    self.notifyAnswerReady(threadID: threadID, question: q, answer: acc)
                }
            } catch is CancellationError {
                // superseded by a newer round on the same screen; nothing to persist
                pendingFlush?.cancel()
                streamSettled = true
            } catch {
                if Task.isCancelled { return }
                // Settle the throttle before the terminal writes below: they own
                // the final text (partial + interrupted suffix, or the error
                // reason), and a trailing scheduled flush firing after them would
                // overwrite it with the bare partial.
                pendingFlush?.cancel()
                streamSettled = true
                self.stopThinkingWordRotation(for: answerID)
                self.endThinking(for: answerID)
                let partial = acc.trimmingCharacters(in: .whitespacesAndNewlines)
                if !partial.isEmpty {
                    // A mid-stream drop *after* the first chunk: we already have a real
                    // partial answer. Persist it to Recent exactly like a completed
                    // round — crucially this runs whether or not the thread is still on
                    // screen, so backing out / closing mid-answer over a flaky network
                    // no longer makes the question vanish from Recent. Settle the
                    // snapshot's streaming flag and tag the saved answer as interrupted,
                    // in both the assistant turn and the answer field so the reopened
                    // thread and the collapsed row agree.
                    let saved = acc + L("error.interrupted")
                    if let i = thread.firstIndex(where: { $0.id == answerID }) {
                        thread[i].text = saved
                        thread[i].streaming = false
                    }
                    let walkedAway = !self.isPresented(answerID: answerID)
                    self.persistThread(thread, threadID: threadID, answer: saved)
                    // Only touch the screen when this round still owns it.
                    if self.isOnScreen(answerID: answerID) {
                        self.updateAnswer(id: answerID, text: saved)
                        self.markFinished(id: answerID)
                        self.mode = .result
                    } else if walkedAway {
                        // Interrupted but salvaged a partial answer, and the user had
                        // already walked away — still notify, same as a clean finish.
                        self.notifyAnswerReady(threadID: threadID, question: q, answer: saved)
                    }
                } else {
                    // Failed before any text arrived (refused connection, bad key):
                    // there's no answer to keep — but the QUESTION is the user's and
                    // must survive. File the row marked failed, carrying the real
                    // reason, instead of deleting it: a round that fails should leave
                    // a trace you can reopen and re-ask, not erase itself from Recent.
                    // `persistThread` also settles any detached mirror on this same
                    // text, so a mirroring window never sits on a spinner.
                    if let i = thread.firstIndex(where: { $0.id == answerID }) {
                        thread[i].text = error.localizedDescription
                        thread[i].isError = true
                        thread[i].streaming = false
                    }
                    self.persistThread(thread, threadID: threadID, answer: "")
                    if self.isOnScreen(answerID: answerID) {
                        // Surface the REAL reason (XII-85) — `ServiceError` already
                        // localizes to e.g. "Anthropic · HTTP 401" — and raise an
                        // actionable error state (retry, or open Settings when no key
                        // is set) instead of a dead generic line. An image round adds
                        // the vision hint (XII-121): the most likely cause of a
                        // rejected image payload is a model without vision support,
                        // and the raw provider error rarely says so legibly.
                        let reason = error.localizedDescription
                            + (imageAttached ? "\n" + L("ask.visionHint") : "")
                        self.updateAnswer(id: answerID, text: reason)
                        // Flag the turn so `wireContext` keeps this reason out of the
                        // next round's wire copy — a follow-up typed instead of a
                        // retry must not send the error text as model speech (XII-88).
                        self.markTurnError(id: answerID)
                        self.markFinished(id: answerID)
                        self.askError = AskError(message: reason,
                                                 needsSetup: !self.isConfigured,
                                                 answerID: answerID)
                        self.mode = .result
                    }
                    // Metadata-only breadcrumb (no prompt/answer/key) — failures
                    // go through the same diagnostics path whether the round is in
                    // the main panel, a Force Touch window, or already detached.
                    DiagnosticsLog.shared.record(
                        provider: runProvider.displayName,
                        status: Self.httpStatus(from: error),
                        error: error)
                }
            }
        }
    }

    /// The HTTP status carried by a service error, if any — for the diagnostics
    /// breadcrumb only. Pulls it from `ServiceError.http` without ever touching the
    /// response body. Nil for non-HTTP failures (timeout, offline, malformed).
    private static func httpStatus(from error: Error) -> Int? {
        (error as? OpenAICompatAIService.ServiceError)?.httpStatus
    }

    /// True while an ask round is streaming on THIS screen — the stop
    /// affordance's gate (XII-122). A round detached by `newChat`/`fullClose`
    /// keeps streaming into its snapshot but is no longer on-screen, so it
    /// doesn't count (there's nothing visible to stop).
    var isStreaming: Bool { turns.contains { $0.streaming } }

    /// Stop the in-flight ask (XII-122) — the streaming answer's stop button and
    /// Esc both land here. Cancels the current task but KEEPS whatever already
    /// streamed: a partial answer settles in place (and persists to Recent, like
    /// the mid-stream-drop path) so the thread stays followable and follow-ups
    /// work on it. A stop before the first token has nothing to keep — the empty
    /// pair is dropped and the question lifted back into the input instead, so
    /// the words aren't lost either way. No-op when nothing is streaming.
    func stopStreaming() {
        guard isStreaming else { return }
        task?.cancel()
        task = nil
        let activeAnswerIDs = turns.filter { $0.role == "assistant" && $0.streaming }.map(\.id)
        for answerID in activeAnswerIDs {
            stopThinkingWordRotation(for: answerID)
        }
        thinking = false
        thinkingAnswerID = nil
        // Settle the on-screen streaming flag(s), reading back the partial text.
        var partial = ""
        for i in turns.indices where turns[i].streaming {
            turns[i].streaming = false
            if turns[i].role == "assistant" { partial = turns[i].text }
        }
        if partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Nothing streamed yet: an empty assistant bubble is dead weight —
            // drop the pair, put the question back (ready to edit or resend), and
            // clear the parked "answering…" placeholder from Recent.
            if let lastUser = turns.last(where: { $0.role == "user" }) {
                let question = lastUser.text
                if turns.last?.role == "assistant" { turns.removeLast() }
                if turns.last?.role == "user" { turns.removeLast() }
                if text.isEmpty { text = question }
            }
            settlePending(threadHistoryID)
            mode = turns.isEmpty ? .idle : .result
        } else {
            mode = .result
            persistThread(turns, threadID: threadHistoryID, answer: partial)
        }
    }

    /// Retry the Ask that just failed (XII-85). The failed turn pair (the question
    /// plus its empty/error assistant turn) is still on screen; drop the assistant
    /// half and the question turn, lift the question back into the input, and re-run
    /// `submit()` so it streams a fresh answer into a clean pair. No-op when there's
    /// nothing to retry.
    func retryLastAsk() {
        // Gated on the *visible* error: a retry may only ever re-run the round that
        // actually failed on this screen, never the last question of whatever
        // conversation the user has since opened.
        guard visibleAskError != nil else { return }
        askError = nil
        resubmitLastQuestion()
    }

    /// The newest SETTLED assistant answer's text, trimmed — the target of the
    /// keyboard copy/save actions (XII-131). `nil` when there's no answer or the
    /// last one is still streaming (nothing final to act on yet).
    var lastAnswerText: String? {
        guard let last = turns.last, last.role == "assistant", !last.streaming else { return nil }
        let text = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }


    /// Re-run the newest settled answer's question for a fresh take — the answer
    /// footer's regenerate button. Same drop-and-resubmit dance as `retryLastAsk`,
    /// but for a turn that *succeeded*: only ever offered on the last assistant
    /// turn (regenerating mid-thread would orphan everything after it), and gated
    /// on the stream being settled so a tap can't tear down an answer mid-flight.
    func regenerateLastAnswer(model: String? = nil) {
        // Never on an agent run's report (footer button and ⌘R alike): the chat
        // model can't re-run a task in the run's folder — it would just hallucinate
        // a "completed" report over the real one.
        guard let last = turns.last, last.role == "assistant", !last.streaming,
              !last.isAgent else { return }
        resubmitLastQuestion(model: model)
    }

    /// The models offered by the "regenerate with…" menu (XII-135): the current
    /// provider's available models, with the one currently in effect flagged so the
    /// menu can grey it out ("current"). Only meaningful when configured (a live
    /// backend); empty for the stub so the menu simply doesn't appear.
    var regenerateModelOptions: [(model: String, isCurrent: Bool)] {
        guard !(ai is StubAIService) else { return [] }
        let provider = APIKeyStore.selectedProvider
        let current = APIKeyStore.effectiveModel(for: provider) ?? provider.defaultModel
        return provider.availableModels.map { ($0, $0 == current) }
    }

    /// One-shot model override for the NEXT `submit()` (XII-135): a "regenerate
    /// with X" pick sets this, `submit()` reads and clears it, builds a service
    /// pinned to X for just that turn, and stamps the answer with X — without ever
    /// touching the user's saved default. Nil for every normal submit.
    private var regenOverrideModel: String?

    /// The provider half of that override, set only when the pick names a backend
    /// other than the selected one (a prompt shortcut's cross-provider pin). Nil
    /// means "the selected provider", which is every regenerate-with pick.
    private var regenOverrideProvider: Provider?

    /// Shared tail of retry/regenerate: drop the newest Q/A pair, lift the question
    /// back into the input, and re-run `submit()` so a fresh answer streams into a
    /// clean pair. No-op when there's no question to re-run. A non-nil `model` runs
    /// this one regeneration on that model only (XII-135).
    private func resubmitLastQuestion(model: String? = nil) {
        guard let lastUser = turns.last(where: { $0.role == "user" }) else { return }
        let question = lastUser.text
        if turns.last?.role == "assistant" { turns.removeLast() }
        if turns.last?.role == "user" { turns.removeLast() }
        regenOverrideModel = model
        text = question
        submit()
    }

    /// Does this *note* line point at something on the clipboard rather than carry
    /// its own content? Calibrated for **note-filing**: the
    /// verbs are save/keep/bookmark/file, and the useful payload is the copied
    /// URL/snippet, not the directive phrase. "Add this to my reading list" should
    /// file the link, not the literal sentence. Two signals, either is enough:
    ///   1. A note-filing verb paired with a deictic ("save **this**", "收藏**这个**").
    ///   2. A very short line that is essentially a bare deictic ("this", "这个") —
    ///      <=5 words / a lone CJK deictic, with nothing else to file.
    /// Conservative by design: a self-contained jot ("buy milk", "dentist tue 3pm")
    /// matches neither and is filed verbatim as today. Lexical only; no model call.
    private func isDeicticNoteCapture(_ line: String) -> Bool {
        let q = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return false }

        // Discourse markers that merely *contain* a deictic word — never captures.
        let discourseMarkers = ["that said", "that is to say", "that being said",
                                "it depends", "it is what it is"]
        if discourseMarkers.contains(where: { q.contains($0) }) { return false }

        let enDeictics = ["this", "that", "these", "those", "it"]
        let cjkDeictics = ["这个", "这段", "这些", "这条", "这句", "这篇", "它"]
        let hasEnDeictic = enDeictics.contains { containsWord($0, in: q) }
        let hasCjkDeictic = cjkDeictics.contains { q.contains($0) }
        let hasDeictic = hasEnDeictic || hasCjkDeictic
        guard hasDeictic else { return false }

        // 1. Note-filing verb + deictic → capture (the verb's object is the clip).
        let enFileVerbs = ["save", "add", "bookmark", "keep", "file", "store",
                           "note", "jot", "log", "put", "record", "capture"]
        let cjkFileVerbs = ["保存", "收藏", "记下", "记录", "存", "加到", "添加", "留着"]
        let hasFileVerb = enFileVerbs.contains { containsWord($0, in: q) }
            || cjkFileVerbs.contains { q.contains($0) }
        if hasFileVerb { return true }

        // 2. Essentially a bare deictic — nothing else of substance to file.
        let words = q.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        if hasEnDeictic && words <= 5 { return true }
        if hasCjkDeictic && q.count <= 6 { return true }

        return false
    }

    // MARK: - Note submit

    /// Route a note-classified line into Apple Notes as a new note. The surface never
    /// changes — the user stays on the same "Type anything…" input and can keep
    /// jotting (or asking) right after; the only sign it went to Notes is the quiet
    /// "Added to Notes" line that flashes below the input.
    ///
    /// The write runs **off the main thread** (see `NotesService`) so the first-run
    /// TCC permission prompt doesn't deadlock the UI. We optimistically clear the
    /// field right away and show a quiet "Saving…" cue; the main-thread callback
    /// then either confirms "Saved" or — on failure (most often permission not yet
    /// granted, or the user clicking "Don't Allow") — **restores the exact line** so
    /// nothing typed is lost, and surfaces the recovery hint.
    func submitNote() {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        // A deictic note ("save this", "收藏这个") points at the clipboard, not at
        // itself — fold the copied URL/snippet into the note body so what gets filed
        // is the *referent*, not a useless directive phrase. The raw `line` is still
        // what we persist to Recent and restore on failure; only the Notes payload
        // is the compound. Self-contained jots take the plain path unchanged.
        let clip = isDeicticNoteCapture(line) ? clipboardContextIfEligible() : nil
        let noteBody = clip.map { "\(line)\n\n\($0)" } ?? line
        let usedClip = clip != nil

        // Optimistic: free the field for the next jot immediately, show progress.
        // Collapse the recent list too — clearing the text would otherwise let a
        // still-true `showHistory` pop it right back open under the saved cue.
        text = ""
        showHistory = false
        highlightedHistoryIndex = nil
        noteError = nil
        noteCueTask?.cancel()
        lastSavedNote = nil
        noteSaving = true
        // Claim the in-flight slot for THIS write (XII-117), so a later capture
        // fired inside our AppleScript retry window can supersede us.
        captureToken += 1
        let token = captureToken

        // Same optimistic contract on both destinations; only the writer (and the
        // cue wording) differs. The Markdown path appends to today's file in the
        // user's folder — no TCC prompt, no AppleScript — and its `link` is the
        // day file's path instead of an `x-coredata://` id (see `openCapture`).
        if NoteDestination.current == .markdownFolder {
            FileNotesService.writeNote(noteBody) { [weak self] result in
                guard let self else { return }
                let current = self.captureToken == token
                if current { self.noteSaving = false }
                switch result {
                case .success(let path):
                    if current { self.lastSavedToReminders = false }
                    self.persistCapture(line, source: .note, link: path)
                    if current {
                        self.flashSavedCue(usedClip ? L("feedback.addedFileClip") : L("feedback.addedFile"))
                    }
                case .failure(let err):
                    if current {
                        self.reportCaptureFailure(line, message: err.errorDescription ?? L("feedback.fileFailed"))
                    }
                }
            }
            return
        }

        NotesService.writeNote(noteBody) { [weak self] result in
            guard let self else { return }
            // This write always persists its own Recent row (idempotent, its own
            // data) so a success is never dropped. But the shared UI state is only
            // ours to touch while we're still the current in-flight write — a newer
            // capture that superseded us owns the gate and cue now.
            let current = self.captureToken == token
            if current { self.noteSaving = false }
            switch result {
            case .success(let noteID):
                if current { self.lastSavedToReminders = false }
                self.persistCapture(line, source: .note, link: noteID)
                if current {
                    self.flashSavedCue(usedClip ? L("feedback.addedNotesClip") : L("feedback.addedNotes"))
                }
            case .failure(let err):
                // Only bounce the line back into the input / raise the error when
                // we still own the shared state; a superseded failure must not
                // clobber the newer write's success or restore an already-filed line.
                if current {
                    self.reportCaptureFailure(line, message: err.errorDescription ?? L("feedback.notesFailed"))
                }
            }
        }
    }

    // MARK: - Reminder submit

    /// Route a time-bound line into Apple Reminders, due (and ringing) at the
    /// moment the text names. Same optimistic shape as `submitNote`: clear the
    /// field immediately, show "Saving…", and on failure (usually the Reminders
    /// permission not yet granted) restore the exact line so nothing is lost.
    ///
    /// The due date is captured **before** clearing the field — `text.didSet`
    /// recomputes `detectedDue` to nil on the clear, so reading it after would
    /// file a dateless reminder.
    func submitReminder() {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        // `detectedDue` is computed asynchronously (off-main Task). On the clipboard
        // path the submit can run in the same call stack that just kicked that Task
        // off, so it can still be nil here even though the line names a time (XII-97).
        // Fall back to a synchronous parse so a timed reminder never silently lands
        // with no due date. A line with no parseable time (incl. a pure "every day"
        // recurring reminder) legitimately stays nil — EventKit's repeat rule carries
        // it — so we don't force a date on those.
        var due = detectedDue
            ?? RemindersService.futureDate(in: line)
            ?? RemindersService.recurrenceDate(in: line)
        // Guard against a due that resolves into the PAST (a stale async value, or a
        // DST/clock-skew edge in the synthesized recurrence date): EventKit accepts it
        // but the reminder would never fire. Drop it to nil rather than file a dead
        // reminder — better a reminder with no time than one that silently never rings.
        if let d = due, d <= Date() { due = nil }

        text = ""
        showHistory = false
        highlightedHistoryIndex = nil
        noteError = nil
        noteCueTask?.cancel()
        lastSavedNote = nil
        noteSaving = true
        // Claim the in-flight slot for THIS write (XII-117) — see submitNote.
        captureToken += 1
        let token = captureToken

        RemindersService.createReminder(line, due: due) { [weak self] result in
            guard let self else { return }
            // Shared UI state is only ours while we're still the current write;
            // the Recent row always persists (its own data). See submitNote.
            let current = self.captureToken == token
            if current { self.noteSaving = false }
            switch result {
            case .success(let link):
                if current { self.lastSavedToReminders = true }
                self.persistCapture(line, source: .reminder, link: link)
                // Echo the recurrence kind write() applied, resolving a bare
                // "weekly" line's day from `due` exactly as write() does so the
                // displayed weekday matches what EventKit actually filed.
                let suffix: String
                switch RemindersService.recurrenceKind(in: line) {
                case .daily:
                    suffix = L("recur.daily")
                case .weekly(let ekDay):
                    let dayIdx: Int
                    if let ekDay {
                        dayIdx = ekDay.rawValue - 1   // EKWeekday 1-Sun…7-Sat \u{2192} 0-based
                    } else if let due {
                        dayIdx = Calendar.current.component(.weekday, from: due) - 1
                    } else {
                        dayIdx = -1
                    }
                    if dayIdx >= 0 {
                        let abbr = Calendar.current.shortWeekdaySymbols[dayIdx % 7]
                        suffix = L("recur.weeklyOn", abbr)
                    } else {
                        suffix = L("recur.weekly")
                    }
                case .monthly:
                    suffix = L("recur.monthly")
                case nil:
                    suffix = ""
                }
                if current { self.flashSavedCue(L("feedback.addedReminders", suffix)) }
            case .failure(let err):
                // Only bounce the line back / raise the error when we still own the
                // shared state — a superseded failure must not clobber the newer
                // write's success or restore an already-filed line (XII-117).
                if current {
                    self.reportCaptureFailure(line, message: err.errorDescription ?? L("feedback.remindersFailed"))
                }
            }
        }
    }

    /// Surface a Note/Reminder save failure without ever silently dropping the
    /// user's words. If the input is still empty we put the exact line back so a
    /// retry is one keypress away. But if they've already started the next jot,
    /// clobbering that draft would be its own data loss — so instead we fold the
    /// failed line into the inline error, where it stays visible and copyable
    /// rather than vanishing with no trace.
    private func reportCaptureFailure(_ line: String, message: String) {
        if text.isEmpty {
            text = line
            noteError = message
        } else {
            noteError = L("feedback.savePreservedLine", message, line)
        }
    }

    /// File a successful Note/Reminder capture into the same Recent history the AI
    /// Q&A uses, so a jotted line leaves a visible trace instead of vanishing with
    /// the 1.7s toast. Stored with its `source` (→ Notes / → Reminders tag), the
    /// `link` back to the exact note/reminder the row's trailing button jumps to,
    /// and an explicit empty `turns`, so reopening it can never synthesize a ghost
    /// answer bubble — a capture has no thread to reopen.
    private func persistCapture(_ line: String, source: HistoryItem.Source, link: String?) {
        var item = HistoryItem(q: line, a: "", t: Date(), turns: [])
        item.source = source
        item.link = link
        history.insert(item, at: 0)
        // No cap: the full archive is retained (the notch list shows only the
        // newest `notchRecentCap`; the History window shows everything).
        saveHistory()
    }

    /// Briefly show "Saved to Notes" under the record input, then fade it. A new
    /// save resets the timer so back-to-back jots don't flicker.
    private func flashSavedCue(_ line: String) {
        noteCueTask?.cancel()
        lastSavedNote = line
        noteCueTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            guard !Task.isCancelled else { return }
            // Clear the cue on the SAME spring the record view and the island both
            // use for this state (response 0.42, damping 0.82). Driving it explicitly
            // — rather than leaning on the implicit `.animation(value:)` modifiers —
            // puts the inner line's fade and the outer island's height collapse on
            // one shared transaction, so they can't be scheduled apart and the panel
            // draws up as a single smooth motion instead of a two-step settle.
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                self?.lastSavedNote = nil
            }
        }
    }

    /// Whether the round identified by its answer placeholder is still the one on
    /// screen. Once `newChat`/`fullClose` (or opening another thread) detaches it,
    /// the screen is no longer the task's to touch — only its snapshot (and, at
    /// the end, history) hears about the stream.
    private func isOnScreen(answerID: UUID) -> Bool {
        turns.contains { $0.id == answerID }
    }

    /// Whether the answer is visibly mounted anywhere. Completion notifications
    /// are only for a round the user actually left; a Force Touch window watching
    /// its detached mirror is still a live presentation, even though it is not in
    /// the main panel's `turns` array.
    private func isPresented(answerID: UUID) -> Bool {
        isOnScreen(answerID: answerID)
            || detachedThreadStores.values.contains { store in
                store.turns.contains { $0.id == answerID }
            }
    }

    /// Refresh a still-streaming round's reattach mirror with its task's current
    /// snapshot. No-op once the round has settled (its defer removed the entry).
    private func syncInFlight(_ answerID: UUID, _ incoming: [Turn]) {
        guard let i = inFlightRounds.firstIndex(where: { $0.answerID == answerID }) else { return }
        var thread = incoming
        // Streaming callbacks own their value-type transcript, while presentation
        // changes (word rotation and ask-user cards) update the in-flight mirror.
        // Merge those runtime-only fields back before a text chunk publishes so a
        // later chunk cannot overwrite the shared state with its older snapshot.
        if let prior = inFlightRounds[i].thread.first(where: { $0.id == answerID }),
           let j = thread.firstIndex(where: { $0.id == answerID }) {
            if thread[j].thinkingWord == nil { thread[j].thinkingWord = prior.thinkingWord }
            if thread[j].thinkingOrbState == nil {
                thread[j].thinkingOrbState = prior.thinkingOrbState
            }
            if thread[j].thinkingStartedAt == nil {
                thread[j].thinkingStartedAt = prior.thinkingStartedAt
            }
            if thread[j].pendingQuestion == nil {
                thread[j].pendingQuestion = prior.pendingQuestion
            }
        }
        inFlightRounds[i].thread = thread
        // A detached window following this thread hears every snapshot too.
        detachedThreadStores[inFlightRounds[i].threadID]?.turns = thread
    }

    /// Put a still-streaming round back on screen: restore its live snapshot to
    /// `turns`, adopt its thread id (so follow-ups keep updating the same Recent
    /// row), and pick `.load` vs `.result` by whether any answer text has landed
    /// yet (`.load` re-enters the thinking dots + rotating word, which a
    /// pre-token detached round still owns). From this instant
    /// `isOnScreen(answerID:)` is true again, so every subsequent chunk, source,
    /// and activity label flows straight to the panel — the same wiring as a
    /// round that never left the screen.
    private func attachInFlightRound(_ round: InFlightRound) {
        text = ""
        turns = round.thread
        threadHistoryID = round.threadID
        let hasAnswer = round.thread.contains { $0.id == round.answerID && !$0.text.isEmpty }
        mode = hasAnswer ? .result : .load
    }

    /// Land a reopening panel back on the page parked at the last close. Page
    /// flags restore verbatim; the thread needs care, because a round that was
    /// still streaming when the panel folded has since finished (or died)
    /// detached — a live one never reaches here, `attachInFlightRound` wins
    /// first. So for a non-idle snapshot: prefer the thread persisted to
    /// history under the same id (it carries the completed answer), fall back
    /// to the snapshot's own turns if they contain readable answer text, and
    /// give up to the idle prompt when the round died wordless — never restore
    /// `.load`, nothing would ever feed those thinking dots again.
    private func restoreParkedSession(_ parked: ParkedSession) {
        showSettings = parked.showSettings
        showWhatsNew = parked.showWhatsNew
        showHistory = parked.showHistory
        guard parked.mode != .idle else {
            text = parked.text
            return
        }
        let persisted = history.first(where: { $0.id == parked.threadHistoryID })?.turns
        var restored: [Turn]
        if let persisted, !persisted.isEmpty {
            restored = persisted
        } else if parked.turns.contains(where: { $0.role == "assistant" && !$0.text.isEmpty }) {
            restored = parked.turns
        } else {
            text = parked.text
            return
        }
        // A snapshot taken mid-stream may carry live-only flags; the stream is
        // over now, so a restored turn must not show a frozen caret or a stale
        // "searching…" line.
        for i in restored.indices {
            restored[i].streaming = false
            restored[i].toolActivity = nil
        }
        turns = restored
        threadHistoryID = parked.threadHistoryID
        text = parked.text
        // Restore the shortcut origin with the thread: `fullClose` cleared it, and
        // without handing it back the reopened answer would come up with a full
        // follow-up field where the user left a folded chip.
        fromPromptShortcut = parked.fromPromptShortcut
        // Hand the parked height measurement back BEFORE `open` flips and the
        // body mounts, so NotchBody's first frame already renders the correct
        // short-vs-clipped layout (see `lastMeasuredAnswerHeight`). A thread that
        // grew while closed (a detached round finishing) may exceed the parked
        // value — harmless: clipping is monotonic with height, so a parked
        // "clipped" stays clipped, and the rare short→long race just re-measures
        // one pass later, exactly like today.
        lastMeasuredAnswerHeight = parked.measuredAnswerHeight
        mode = .result
    }

    /// Replace the streaming assistant turn's text as chunks arrive. Looked up by
    /// id so an out-of-order or post-`newChat` chunk can't write into the wrong row.
    private func updateAnswer(id: UUID, text: String) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[i].text = text
    }

    /// Mark a turn as holding an error reason rather than model output, so
    /// `wireContext` filters it from every later request (XII-88).
    private func markTurnError(id: UUID) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[i].isError = true
    }

    /// End the thinking-dots phase for `id` — but only if `id` is the round that
    /// currently owns the flag, so a superseded round finishing can't switch the dots
    /// off under a newer one. Called on the first token and at every round terminus
    /// (success, cancel, error), so the dots clear exactly when this round stops
    /// thinking, whether or not its panel is still on screen.
    private func endThinking(for id: UUID) {
        guard thinkingAnswerID == id else { return }
        thinking = false
        thinkingAnswerID = nil
    }

    /// Clear the `streaming` flag on the assistant turn (its caret/typing cue can
    /// stop) without otherwise touching it. Also clears any lingering tool-activity
    /// line so a finished turn never shows "searching…".
    private func markFinished(id: UUID) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[i].streaming = false
        setThinkingActivity(nil)
    }

    /// Funnel the harness's transient tool-activity label (e.g. "Searching the web…")
    /// into the single `thinkingStatus` value so it *replaces* the rotating mood word
    /// rather than rendering as a second, parallel line. `nil` falls back to the word.
    private func updateActivity(id: UUID, label: String?, orb: OrbState) {
        guard isOnScreen(answerID: id) else { return }
        setThinkingActivity(label, orb: orb)
    }

    /// Append a search round's sources to the on-screen assistant turn (deduped by
    /// URL), so the source badge under the answer reflects every round.
    private func appendSources(id: UUID, _ newSources: [WebSource]) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[i].sources = Self.mergedSources(turns[i].sources, newSources)
    }

    /// Merge two source lists preserving order and dropping URL duplicates — the
    /// same dedup the snapshot and the on-screen turn both use so they agree.
    static func mergedSources(_ existing: [WebSource], _ incoming: [WebSource]) -> [WebSource] {
        var seen = Set(existing.map(\.url))
        var out = existing
        for s in incoming where !seen.contains(s.url) {
            seen.insert(s.url)
            out.append(s)
        }
        return out
    }

    /// Park a placeholder row for a brand-new thread the instant its question is
    /// submitted, so Recent shows the question (with a three-dot "answering…"
    /// marker) immediately instead of staying blank until the answer lands. Only
    /// the FIRST turn parks one — a follow-up streams into an already-present row.
    /// `persistThread` later replaces this same-id row in place with the finished
    /// item; `settlePending` removes it if the round produces nothing.
    private func parkPending(threadID: UUID, question: String) {
        // Already have a row for this thread (shouldn't happen on a first turn, but
        // be safe): just flag it pending rather than inserting a duplicate.
        if let i = history.firstIndex(where: { $0.id == threadID }) {
            history[i].pending = true
            return
        }
        var item = HistoryItem(id: threadID, q: question, a: "", t: Date())
        item.pending = true
        history.insert(item, at: 0)
        // Not saved to disk — a pending row carries no answer and must never
        // survive a relaunch. `persistThread` is what writes the settled row.
    }

    /// Drop a still-pending placeholder for a thread that ended with nothing to
    /// keep (pre-text failure / cancellation). A row that already settled into a
    /// real answer is left untouched — only an unfinished placeholder is removed.
    private func settlePending(_ threadID: UUID) {
        guard let i = history.firstIndex(where: { $0.id == threadID }), history[i].pending
        else { return }
        history.remove(at: i)
    }

    /// Called once a stream completes: persist the task's snapshot of the thread
    /// to history (one recent item per thread, updated in place as it grows).
    /// Runs whether or not the thread is still on screen — a round detached by
    /// `newChat`/`fullClose` lands here all the same, which is what makes backing
    /// out mid-answer safe. Built from the snapshot rather than the live `turns`,
    /// so whatever the screen shows by completion time can't cross into this
    /// thread's row. Skips empty results (e.g. a stream that errored before any
    /// text). The recent row shows the first question + latest answer; reopening
    /// it restores every turn.
    private func persistThread(_ thread: [Turn], threadID: UUID, answer ans: String) {
        var thread = thread
        let trimmed = ans.trimmingCharacters(in: .whitespacesAndNewlines)
        // No answer came back — the model returned nothing (a leaked tool call the
        // harness couldn't recover, an empty completion) or the stream died before
        // the first token. This used to DELETE the row, which took the user's
        // question with it: the thread vanished from Recent and, once the app quit,
        // there was no trace it had ever been asked. Keep the row and mark it
        // failed instead. The body is whatever reason the answer turn already
        // holds (the XII-85 error text), else a plain "no answer" line.
        let failed = trimmed.isEmpty
        var body = trimmed
        if failed {
            let reason = thread.last(where: { $0.role == "assistant" })?.text
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            body = reason.isEmpty ? L("error.noAnswer") : reason
            // Settle the snapshot too, so reopening the row shows the same reason
            // rather than an empty bubble — and flag it `isError` so `wireContext`
            // keeps it out of the next round's wire copy (the model must never see
            // a failure line as something it once said).
            if let i = thread.lastIndex(where: { $0.role == "assistant" }) {
                if thread[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    thread[i].text = body
                }
                thread[i].isError = true
                thread[i].streaming = false
            }
        }
        // A detached window following this thread freezes on the final state —
        // caret gone, no stale activity line — whatever happens below. Settled
        // after the patch above so a failed round mirrors the reason, not a blank.
        detachedThreadStores[threadID]?.settle(with: thread)

        let firstQ = thread.first(where: { $0.role == "user" })?.text ?? ""
        // One history entry per conversation: if this thread already has a row
        // (a follow-up), update it in place instead of inserting a duplicate, so
        // a long chat is a single recent row, not one per turn. Carry over any
        // previously generated title so follow-ups don't wipe it.
        let existing = history.first(where: { $0.id == threadID })
        let existingTitle = existing?.title
        var item = HistoryItem(id: threadID, q: firstQ, a: body, t: Date(), turns: thread)
        item.title = existingTitle
        item.failed = failed
        // A chat follow-up on a reopened agent thread updates the SAME row — it
        // must keep the row's agent identity (source, folder link, outcome,
        // resume handle) rather than silently demoting it to a plain `.ask`.
        if let existing {
            item.source = existing.source
            item.origin = existing.origin
            item.link = existing.link
            item.agentOutcome = existing.agentOutcome
            item.agentResume = existing.agentResume
        }
        if let i = history.firstIndex(where: { $0.id == threadID }) {
            history.remove(at: i)
        }
        history.insert(item, at: 0)
        if item.source == .agent, let store = detachedThreadStores[threadID] {
            store.agentFolderPath = item.link
            store.completedAt = item.t
        }
        // No cap: the full archive is retained (see `persistCapture`).
        saveHistory()

        // Derive a title from the actual conversation content so the recent list
        // doesn't just display the first user message — prompts like "总结一下"
        // would make many rows look identical. Runs detached so the UI is never
        // blocked; if it fails (offline, no key, timeout) the row falls back to
        // the first question.
        //
        // Regenerate as the thread drifts, but only at milestone rounds (every
        // other round, XII-88) — re-titling on EVERY follow-up fired one extra
        // full request per round, which doubles traffic on low-RPM free tiers
        // (Kimi/GLM/MiniMax) and can 429 the next real answer. A thread that
        // drifts to a new topic still gets re-titled within a round or two;
        // a missing title is always generated regardless of round parity.
        // A failed round has no answer to summarize, and spending a whole extra
        // request on the round that just failed is the wrong moment for it — the
        // row falls back to the question, which is exactly what it should show.
        let atMilestone = thread.count > 2 && thread.count % 4 == 0
        if !failed, existingTitle == nil || atMilestone {
            Task { [weak self] in
                guard let self, let title = await self.generateTitle(for: thread) else { return }
                await MainActor.run {
                    guard let index = self.history.firstIndex(where: { $0.id == threadID }) else { return }
                    self.history[index].title = title
                    self.saveHistory()
                }
            }
        }
    }

    /// Fire the native "answer ready" banner for a round that finished detached
    /// (the user walked away — see the `walkedAway` gate at the call sites). Pulls
    /// whatever title `persistThread` already has for this thread (a follow-up
    /// carries one; a fresh thread's title is still generating, so it falls back to
    /// the question inside `NotificationService`). The tap reopens this thread.
    private func notifyAnswerReady(threadID: UUID, question: String, answer: String) {
        // Nothing was actually saved (empty answer) → no row to reopen, no banner.
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let title = history.first(where: { $0.id == threadID })?.title
        NotificationService.shared.postAnswerReady(
            threadID: threadID, title: title, question: question)
    }

    /// Ask the configured model to summarize the conversation into a short title.
    /// Returns `nil` when offline (stub), unconfigured, or the request fails, so
    /// the UI can always fall back to the first user message.
    private func generateTitle(for thread: [Turn]) async -> String? {
        guard !(ai is StubAIService) else { return nil }

        // Only the tail of the conversation, size-capped (XII-88): a title should
        // reflect where the chat *went*, so the last few rounds are the right
        // input anyway — and the cap keeps a long thread from ballooning this
        // side request. Skips turns that never became real answers (a superseded
        // round's empty turn, an error card's reason text).
        var transcript = ""
        for turn in thread.suffix(6) {
            let body = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty || turn.isError { continue }
            let label = turn.role == "user" ? "User" : "Assistant"
            transcript += "\(label): \(body)\n"
        }
        let prompt = String(transcript.suffix(4000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }

        let service = ai
        do {
            var title = ""
            for try await chunk in service.stream(
                system: titleSystemPrompt,
                messages: [ChatMessage(role: "user", content: prompt)]
            ) {
                title += chunk
            }
            let cleaned = title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "^[\"']+|[\"']+$", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\n", with: " ")
            guard !cleaned.isEmpty else { return nil }
            return cleaned
        } catch {
            return nil
        }
    }

    /// Debug-only: drop a finished Q/A onto the screen as a one-exchange thread,
    /// so the result view (and its markdown renderer) can be inspected at launch
    /// without a live backend. `sources` decorates the answer with citation chips
    /// and `usedClipboard` marks the question as clipboard-enriched, so those
    /// real states can be screenshotted too. Used by the `NOTCH_DEMO` env path
    /// in `AppDelegate`.
    func seedDemo(question: String, answer: String,
                  sources: [WebSource] = [], usedClipboard: Bool = false) {
        var user = Turn(role: "user", text: question)
        user.usedClipboard = usedClipboard
        var ai = Turn(role: "assistant", text: answer)
        ai.sources = sources
        turns = [user, ai]
        mode = .result
    }

    /// Debug-only: put a line into the idle input exactly as if typed, so the
    /// destination pill ("Ask" / "Note" / "Remind") shows the routing for
    /// screenshots. `route` pins the destination via the same override Tab uses,
    /// so the pill reads the intended verb regardless of the classifier's take.
    /// The set is delayed a beat so the prompt field is mounted when the text
    /// lands. Used by the `NOTCH_DEMO_INPUT` env path.
    func seedDemoInput(_ line: String, route: Panel? = nil) {
        mode = .idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.text = line
            if let route { self?.manualPanelOverride = route }
            // A programmatic set while the field has focus leaves the whole line
            // selected; park the caret at the end so the shot reads mid-typing.
            DispatchQueue.main.async {
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                    editor.setSelectedRange(NSRange(location: (line as NSString).length, length: 0))
                }
            }
        }
    }

    /// Debug-only: park a finished exchange where `adoptDetachedThread` will find
    /// it and hand back its thread id, so a pointer window can be posed on a real
    /// answer without a live backend. Used by the `NOTCH_DEMO_FORCE=answer` env
    /// path in `AppDelegate`.
    func seedDemoDetachedThread(question: String, answer: String) -> UUID {
        let id = UUID()
        var seeded = [Turn(role: "user", text: question)]
        // An empty answer is the "still thinking" pose — the card stands with the
        // question attached and nothing under it yet.
        if !answer.isEmpty { seeded.append(Turn(role: "assistant", text: answer)) }
        turns = seeded
        threadHistoryID = id
        mode = .result
        return id
    }

    /// Debug-only: show the "Added to Notes/Reminders" capture cue WITHOUT the
    /// 1.7s auto-clear, so the post-capture state holds still for screenshots.
    /// Used by the `NOTCH_DEMO_SAVED` env path.
    func seedDemoSaved(toReminders: Bool) {
        lastSavedToReminders = toReminders
        lastSavedNote = toReminders ? L("feedback.addedReminders", "") : L("feedback.addedNotes")
    }

    /// Debug-only: seed a long multi-turn thread so the result view's scrolling and
    /// edge fades can be inspected at launch without clicking. Used by the
    /// `NOTCH_DEMO_THREAD` env path in `AppDelegate`.
    func seedDemoThread() {
        turns = [
            Turn(role: "user", text: "小米 ceo 是谁"),
            Turn(role: "assistant", text: "小米公司的创始人兼首席执行官（CEO）是**雷军**。他自 2010 年公司创立起便担任这一职务，并持续领导小米的发展。"),
            Turn(role: "user", text: "cfo 呢"),
            Turn(role: "assistant", text: "小米集团首席财务官（CFO）是**林世伟**。他于 2020 年加入小米，此前曾在金融机构有丰富的工作经验。"),
            Turn(role: "user", text: "其他高管呢"),
            Turn(role: "assistant", text: "小米其他主要高管包括：\n\n- **卢伟冰**：集团总裁，兼任国际业务部总裁、分管手机部、生态链部等多个关键部门。\n- **曾学忠**：集团高级副总裁，兼任手机部总裁。\n- **王翔**：高级顾问，前集团总裁。\n- **颜克胜**：集团副总裁，负责质量委员会和采购委员会。\n\n这些高管共同组成了小米的管理层核心。"),
            Turn(role: "user", text: "雷军是哪里人"),
            Turn(role: "assistant", text: "雷军出生于**湖北省仙桃市**，1969 年出生。他毕业于武汉大学计算机系。"),
            Turn(role: "user", text: "他还创办过别的公司吗"),
            Turn(role: "assistant", text: "是的。雷军在创办小米之前，曾长期担任**金山软件**的高管乃至 CEO，并参与创办了**卓越网**（后被亚马逊收购）。他也是知名的天使投资人，通过**顺为资本**投资了大量科技公司。"),
        ]
        mode = .result
    }

    // MARK: - History

    /// Reopen a conversation by its history id — the path a tapped answer
    /// notification takes. Finds the matching (settled) Recent row and routes it
    /// through `openHistory`, so the panel lands straight on that thread's detail
    /// view. No-op if the row is gone or still pending. The caller (AppDelegate)
    /// must already have summoned the panel open on a screen.
    func openThread(id: UUID) {
        guard let item = history.first(where: { $0.id == id }), !item.pending else { return }
        openHistory(item)
    }

    func openHistory(_ item: HistoryItem) {
        // Opening a saved thread replaces the idle draft; its unsent attachments
        // must not hide off-screen and ride the next follow-up by surprise.
        askComposeImages = []
        // Still answering: this row is a placeholder whose live stream runs
        // detached — reattach the stream to the screen (the same move as
        // hovering the busy notch) so tapping the row lands on the answer as
        // it writes; the `inFlightRounds` mirror carries everything streamed so
        // far. A pending row with no live round behind it (the round is settling
        // this very instant) stays a no-op; it becomes a normal row momentarily.
        if item.pending {
            guard let round = inFlightRounds.first(where: { $0.threadID == item.id }) else { return }
            showHistory = false
            highlightedHistoryIndex = nil
            attachInFlightRound(round)
            return
        }

        // A Note/Reminder capture has no AI answer to reopen — it lives in Apple
        // Notes/Reminders. Tapping the ROW body must NOT switch the user out to
        // another app: they opened the notch expecting to stay here, and a silent
        // jump to Notes/Reminders yanks them somewhere they didn't ask to go. The
        // jump lives on a dedicated trailing button instead (`openCaptureInApp`),
        // so leaving the app is always a deliberate, separate tap. Here the row
        // body is a no-op for captures — the list stays open, nothing switches.
        guard item.source.isThread else { return }

        showHistory = false
        highlightedHistoryIndex = nil

        text = ""
        // Restore the whole thread, and adopt this item's id so a follow-up on the
        // reopened conversation updates the same recent row rather than forking a
        // new one. (Legacy single-Q/A items rebuild a two-turn thread.)
        turns = item.conversation
        threadHistoryID = item.id
        // A reopened thread that rode an image puts it back on the wire, so a
        // follow-up ("so how do I fix it?") still sees the screenshot the thread
        // started from instead of asking about nothing. The saved JPEG is already
        // the downsampled one that went out the first time. Only when the model on
        // duty now reads images at all — a text-only model gets the thread's text.
        threadImages = activeModelSupportsVision ? Self.parkedImages(for: item) : nil
        mode = .result
    }

    /// Images a saved thread carries, rebuilt from the history image store.
    private static func parkedImages(for item: HistoryItem)
        -> (threadID: UUID, images: [ChatImage])?
    {
        let files = item.conversation.first(where: { $0.role == "user" })?.imageFiles ?? []
        let images = files.compactMap { file -> ChatImage? in
            guard let jpeg = try? Data(contentsOf: historyImageURL(file)) else { return nil }
            return ChatImage(base64: jpeg.base64EncodedString(), mediaType: "image/jpeg")
        }
        guard !images.isEmpty else { return nil }
        return (threadID: item.id, images: images)
    }

    /// Jump a Note/Reminder capture out to its app — the DELIBERATE exit, fired
    /// only by the row's trailing "open in app" button, never by tapping the row
    /// body (which stays put; see `openHistory`). Switching apps is a decision the
    /// user makes on purpose, so it has its own control. No-op for `.ask` rows.
    func openCaptureInApp(_ item: HistoryItem) {
        guard !item.source.isThread else { return }
        openCapture(item)
        // Attention is moving to Notes/Reminders — hard-close the panel behind it
        // so the notch doesn't hang unfurled over the app the user just jumped to.
        fullClose()
    }

    /// Jump from a Recent row straight to the note/reminder it created.
    ///
    /// Two tiers, so a jump never dead-ends:
    ///   1. With a stored `link`, open that exact item — Notes via AppleScript
    ///      `show` (the `link` is the note's `x-coredata://` id), Reminders via
    ///      the `x-apple-reminderkit://` URL. A stale link (item deleted in the
    ///      app, or the undocumented Reminders scheme stops resolving) fails
    ///      quietly *inside* the app and lands the user on its current view.
    ///   2. Without a link — captures saved before this feature shipped, or a
    ///      save that returned no identifier — just bring the destination app
    ///      forward by its bundle id, so an old row still goes *somewhere* useful
    ///      rather than doing nothing.
    private func openCapture(_ item: HistoryItem) {
        switch item.source {
        case .note:
            if let id = item.link, !id.isEmpty {
                if id.hasPrefix("x-coredata://") {
                    // Apple Notes capture. `show` can fail on a stale id (note
                    // deleted, or a Core Data id synced from another device) or
                    // revoked Automation access — when it does, don't dead-end:
                    // fall back to Notes' main window so the tap still lands the
                    // user *somewhere*.
                    NotesService.showNote(id: id) { [weak self] ok in
                        if !ok { self?.openApp(bundleID: "com.apple.Notes") }
                    }
                } else {
                    // Markdown capture: the link is the day file's absolute path.
                    // Open it in the default editor; if the file has been moved or
                    // deleted, reveal the folder instead so the jump still lands.
                    if FileManager.default.fileExists(atPath: id) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: id))
                    } else {
                        FileNotesService.revealFolder()
                    }
                }
            } else {
                // Link-less legacy row: no way to know which destination filed it,
                // so land on wherever notes go *now* — the least surprising target.
                switch NoteDestination.current {
                case .appleNotes:     openApp(bundleID: "com.apple.Notes")
                case .markdownFolder: FileNotesService.revealFolder()
                }
            }
        case .reminder:
            if let link = item.link, let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            } else {
                openApp(bundleID: "com.apple.reminders")
            }
        case .ask, .agent:
            break   // threads — handled by openHistory; never reached here
        }
    }

    /// Bring an app forward by bundle id — the no-deep-link fallback. Uses the
    /// modern `openApplication(at:configuration:)` since `launchApplication` is
    /// deprecated; resolving the URL first keeps it a no-op if the app is missing.
    private func openApp(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Shell-style history recall (↑/↓ fill the input)

    /// ↑ on the idle prompt: pull the previous question straight into the input,
    /// the way a shell's up-arrow recalls the last command. The first press (from
    /// an empty box) fills the most recent question; each further ↑ steps one item
    /// older, clamping at the oldest. Returns `true` when it filled the box, so the
    /// field swallows the key; `false` (no history, or already at the oldest) lets
    /// ↑ do its usual thing.
    @discardableResult
    func recallPreviousQuestion() -> Bool {
        let questions = recallQuestions
        guard !questions.isEmpty else { return false }
        // Clamp the resume point in case `history` shrank since the last step, then
        // advance one older. `guard` catches "already at the oldest" (no-op).
        let current = min(historyRecallIndex ?? -1, questions.count - 1)
        let next = current + 1
        guard next < questions.count else { return false }   // already at the oldest
        fillRecall(at: next, in: questions)
        pulseRecall(.older)
        return true
    }

    /// ↓ while recalling: step back toward the newest question. Stepping past the
    /// newest clears the box (back to where the user started), ending the session.
    /// Returns `true` while a recall session is live so ↓ stays owned by recall;
    /// `false` when there's nothing being recalled, so ↓ falls through to its
    /// normal duty (opening / stepping the recent list).
    @discardableResult
    func recallNextQuestion() -> Bool {
        guard let current = historyRecallIndex else { return false }
        if current <= 0 {
            // Past the newest — clear back to an empty box and end recall.
            historyRecallIndex = nil
            setRecallText("")
        } else {
            let questions = recallQuestions
            guard !questions.isEmpty else {
                // History emptied out from under us mid-recall — end the session.
                historyRecallIndex = nil
                setRecallText("")
                pulseRecall(.newer)
                return true
            }
            // Clamp defensively: `history` can shrink mid-recall (a row deleted),
            // so the cursor might now point past the end.
            fillRecall(at: min(current - 1, questions.count - 1), in: questions)
        }
        pulseRecall(.newer)
        return true
    }

    /// Move the recall cursor to `index` in the dedup'd `questions` and drop that
    /// question into the box.
    private func fillRecall(at index: Int, in questions: [String]) {
        historyRecallIndex = index
        setRecallText(questions[index])
    }

    /// Write `text` as part of a recall step — flagged so `text.didSet` doesn't
    /// read the fill as the user typing and cancel the session.
    private func setRecallText(_ value: String) {
        isRecallingText = true
        text = value
        isRecallingText = false
    }

    // MARK: - History keyboard navigation

    /// ↓ in the empty idle prompt: open the recent list (if any) and highlight
    /// the next row. The first press both reveals the list and lands on row 0;
    /// each subsequent press steps down, clamping at the last row. Returns
    /// `false` when there's nothing to navigate (no history), so the caller can
    /// let the keystroke fall through to its default behaviour.
    @discardableResult
    func historyNavigateDown() -> Bool {
        let items = recentVisible
        guard !items.isEmpty else { return false }
        if !showHistory { showHistory = true }
        let next = (highlightedHistoryIndex ?? -1) + 1
        highlightedHistoryIndex = min(next, items.count - 1)
        return true
    }

    /// ↑ while navigating the recent list: step the highlight up. Moving up past
    /// the first row collapses the list and returns the caret to the input — the
    /// inverse of the ↓ that opened it. Returns `false` when the list isn't open
    /// / nothing is highlighted, so ↑ behaves normally in the field otherwise.
    @discardableResult
    func historyNavigateUp() -> Bool {
        guard showHistory, let current = highlightedHistoryIndex else { return false }
        if current <= 0 {
            // Past the top — fold the list back up and release the highlight.
            highlightedHistoryIndex = nil
            showHistory = false
        } else {
            highlightedHistoryIndex = current - 1
        }
        return true
    }

    /// Enter while a recent row is highlighted: open it. Returns `false` when
    /// nothing is highlighted, so a normal Enter still submits the prompt. Also
    /// bails whenever the box has text — visible text always owns Enter, so a
    /// stale highlight can never swallow a real submit (backstop to
    /// `text.didSet`, which already closes the list the moment text arrives).
    @discardableResult
    func historyConfirmHighlighted() -> Bool {
        guard !hasText, showHistory, let i = highlightedHistoryIndex else { return false }
        let items = recentVisible
        guard items.indices.contains(i) else { return false }
        let item = items[i]
        // Enter is a deliberate confirm, not an accidental body tap — so on a
        // highlighted capture it fires the jump (the keyboard twin of clicking the
        // trailing button), while a mouse click on the row body stays put. Ask
        // rows reopen the thread as before.
        if item.source.isThread {
            openHistory(item)
        } else {
            openCaptureInApp(item)
        }
        return true
    }

    /// Esc / outside-collapse for the list alone: fold it back to the input
    /// without closing the whole panel. Returns `false` when the list isn't
    /// open, letting Esc fall through to its usual full-close.
    @discardableResult
    func collapseHistory() -> Bool {
        guard showHistory else { return false }
        showHistory = false
        highlightedHistoryIndex = nil
        return true
    }

    /// How much of the archive a Clear wipes. The confirmation only offers the
    /// choice when the narrow scope is actually narrower — see
    /// `historyCountWithinLastDay`.
    enum HistoryClearScope: Equatable {
        /// Chat / Notes / Reminders filed in the last 24 hours; older rows and
        /// every Agent conversation stay.
        case lastDay
        /// Every Chat / Notes / Reminders row, leaving Agent untouched.
        case chat
        /// Every Agent conversation, leaving Ask / Notes / Reminders untouched.
        case agent
    }

    /// The window `.lastDay` wipes.
    static let historyLastDayWindow: TimeInterval = 24 * 60 * 60

    /// Rows filed within `historyLastDayWindow` — the size of the narrow scope,
    /// and what tells the confirmation whether there's a choice worth offering.
    var historyCountWithinLastDay: Int {
        let cutoff = Date().addingTimeInterval(-Self.historyLastDayWindow)
        return history.lazy.filter {
            $0.t >= cutoff
                && (self.agentComposeActive ? $0.source == .agent : $0.source != .agent)
        }.count
    }

    /// Total represented by the active Clear confirmation. Agent's confirmation
    /// counts only the rows it can remove; Chat counts Ask / Notes / Reminders.
    var historyClearTotalCount: Int { recentScopeHistoryCount }

    func clearHistory(scope: HistoryClearScope = .chat) {
        // Everything filed at/after this instant goes. A full clear reaches all the
        // way back, which is just `.distantPast` — so both scopes are one cutoff and
        // one code path.
        let cutoff: Date = switch scope {
        case .chat, .agent: .distantPast
        case .lastDay: Date().addingTimeInterval(-Self.historyLastDayWindow)
        }
        // Clearing before the launch load lands must also reach the rows the read
        // hasn't handed over yet, or the wiped window pops back once it finishes.
        if scope == .agent {
            armAgentClearBeforeLoad()
        } else {
            armChatClearBeforeLoad(cutoff)
        }

        let doomed = history.filter {
            $0.t >= cutoff && (scope == .agent ? $0.source == .agent : $0.source != .agent)
        }
        guard !doomed.isEmpty || !historyLoaded || scope == .chat || scope == .agent else { return }
        // The rows go, so their attachments go with them. (A clear that lands before
        // the load only sees what's in memory; the rest of the store is swept by the
        // prune in `mergeLoadedHistory`, which then finds nothing referencing it.)
        Self.deleteHistoryImages(doomed.flatMap(\.imageFiles))
        history.removeAll {
            $0.t >= cutoff && (scope == .agent ? $0.source == .agent : $0.source != .agent)
        }
        saveHistory()

        // The keyboard highlight indexes into the *visible* slice, and a partial
        // clear pulls rows out from the TOP of it — so a stale index would leave
        // the selection sitting on a completely different row (it looked like the
        // highlight teleported down the list as the rows above it vanished), or
        // past the end entirely. Nothing survives a Clear as "the selected row",
        // so release it — and fold the list once it's empty, like `deleteHistory`.
        highlightedHistoryIndex = nil
        if recentVisible.isEmpty { showHistory = false }
    }

    /// Drop a single recent item by id (right-click → Delete on its row). Keeps the
    /// keyboard highlight valid: removing a row at/above the highlighted index would
    /// otherwise leave the caret pointing past the end or at the wrong row, so we
    /// recompute it against the shortened visible slice — clamping to the last row,
    /// or releasing the highlight (and folding the list) once it's empty.
    func deleteHistory(id: UUID) {
        guard let removedVisibleIndex = recentVisible.firstIndex(where: { $0.id == id }) else { return }
        Self.deleteHistoryImages(history.first(where: { $0.id == id })?.imageFiles ?? [])
        history.removeAll { $0.id == id }
        saveHistory()

        guard let current = highlightedHistoryIndex else { return }
        let remaining = recentVisible.count
        if remaining == 0 {
            highlightedHistoryIndex = nil
            showHistory = false
        } else if removedVisibleIndex <= current {
            highlightedHistoryIndex = min(current, remaining - 1)
        }
    }

    // MARK: - History persistence
    //
    // The archive is unbounded (every retained item, full transcripts included),
    // so both halves of its persistence are kept off the main actor:
    //   • it lives in its own file under Application Support, not in UserDefaults
    //     — a multi-MB blob in the defaults plist rides along on every cfprefsd
    //     round-trip for the whole domain, and `set(_:forKey:)` of the full
    //     archive ran synchronously on the main thread after EVERY answer;
    //   • loads decode on a background task at launch (the archive merges in a
    //     beat later), and saves encode+write on a serial utility queue behind a
    //     short debounce (a finished answer saves once immediately and again when
    //     its generated title lands — the debounce folds those into one write).

    /// Serial queue that owns every write of the archive file, so two debounced
    /// snapshots can never interleave their bytes.
    private static let historyIO = DispatchQueue(label: "com.lofilab.notch.history-io",
                                                 qos: .utility)

    nonisolated private static var historyFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("Notch", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    // MARK: - History images
    //
    // An attached image is kept as its own JPEG beside the archive, and the turn
    // that carried it references it by filename (`Turn.imageFiles`). The bytes are
    // the ones already downsampled for the wire (`encodeJPEGForVision` — long side
    // ≤1568px), so a saved thumbnail costs a couple hundred KB, not the multi-MB
    // Retina original. Files are removed with the rows that reference them
    // (`deleteHistory` / `clearHistory`), and anything orphaned by a crash is swept
    // at the next launch (`pruneHistoryImages`).

    nonisolated static var historyImagesDirectory: URL {
        historyFileURL.deletingLastPathComponent()
            .appendingPathComponent("HistoryImages", isDirectory: true)
    }

    nonisolated static func historyImageURL(_ name: String) -> URL {
        historyImagesDirectory.appendingPathComponent(name)
    }

    /// Park one already-encoded JPEG in the store. Returns the filename to stamp on
    /// the turn, or `nil` if the write failed — in which case the turn simply keeps
    /// no attachment, exactly as it did before this existed.
    nonisolated static func storeHistoryImage(_ jpeg: Data) -> String? {
        let dir = historyImagesDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".jpg"
        guard (try? jpeg.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil
        else { return nil }
        return name
    }

    /// The image behind a saved filename, or `nil` if the file is gone (a wiped store,
    /// a hand-deleted file). Views render nothing in that case rather than a broken box.
    /// Decoded once per file per launch (see `historyImageCache`): the Recent list and
    /// the archive rebuild on every keystroke in their search field, and re-decoding a
    /// JPEG on each pass would show as jank.
    nonisolated static func historyImage(named name: String) -> NSImage? {
        if let cached = historyImageCache.object(forKey: name as NSString) { return cached }
        guard let image = NSImage(contentsOf: historyImageURL(name)), image.isValid else { return nil }
        historyImageCache.setObject(image, forKey: name as NSString)
        return image
    }

    nonisolated static func deleteHistoryImages(_ names: [String]) {
        guard !names.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for name in names {
                historyImageCache.removeObject(forKey: name as NSString)
                try? FileManager.default.removeItem(at: historyImageURL(name))
            }
        }
    }

    /// Sweep images no saved row references any more — the residue of a crash between
    /// writing the file and persisting the row that names it. A file young enough to
    /// belong to a round still in flight (its row lands in the archive only once the
    /// answer does) is left alone, so this can never delete an attachment out from
    /// under a live conversation.
    nonisolated private static func pruneHistoryImages(keeping referenced: Set<String>) {
        let dir = historyImagesDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for name in names where !referenced.contains(name) {
            let url = dir.appendingPathComponent(name)
            let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let written, written > cutoff { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// True once the launch load has merged the on-disk archive into `history`.
    /// Saves that fire before that (a capture seconds into a launch) are deferred:
    /// writing then would snapshot ONLY the new items, and a crash before the
    /// merge would replace the whole archive with them.
    private var historyLoaded = false
    private var historySaveDeferred = false
    /// A Chat clear can race the launch-time history read. Once armed, it owns only
    /// Ask / Notes / Reminders rows at or after its cutoff; Agent remains intact.
    private var chatHistoryClearedBeforeLoad: Date?
    /// Agent counterpart to `chatHistoryClearedBeforeLoad`.
    private var agentHistoryClearedBeforeLoad = false

    /// Records a pre-load Chat clear's reach. Two clears keep the earlier cutoff —
    /// it removes more, while still never crossing into Agent.
    private func armChatClearBeforeLoad(_ cutoff: Date) {
        guard !historyLoaded else { return }
        chatHistoryClearedBeforeLoad = min(
            chatHistoryClearedBeforeLoad ?? .distantFuture, cutoff)
    }

    private func armAgentClearBeforeLoad() {
        guard !historyLoaded else { return }
        agentHistoryClearedBeforeLoad = true
    }
    /// The debounced pending save, so a burst of saves collapses to one write and
    /// the terminate flush can run it early.
    private var pendingHistorySave: DispatchWorkItem?

    private func loadHistoryAsync() {
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = Self.readHistoryFromDisk()
            await MainActor.run { [weak self] in
                self?.mergeLoadedHistory(loaded)
            }
        }
    }

    private func mergeLoadedHistory(_ loaded: [HistoryItem]) {
        defer {
            historyLoaded = true
            if historySaveDeferred {
                historySaveDeferred = false
                saveHistory()
            }
            // The archive is now whole, so anything in the image store it doesn't
            // reference is residue (a crash between writing the JPEG and persisting
            // the row, a Clear that landed before the load) — sweep it.
            let referenced = Set(history.flatMap(\.imageFiles))
            DispatchQueue.global(qos: .utility).async {
                Self.pruneHistoryImages(keeping: referenced)
            }
        }
        guard !loaded.isEmpty else { return }
        // A clear that landed before this read finished also owns the matching
        // bucket's rows it never got to see. Apply both scopes independently so
        // neither clear can erase the sibling bucket.
        var surviving = chatHistoryClearedBeforeLoad.map { cutoff in
            loaded.filter { $0.source == .agent || $0.t < cutoff }
        } ?? loaded
        if agentHistoryClearedBeforeLoad {
            surviving.removeAll { $0.source == .agent }
        }
        guard !surviving.isEmpty else { return }
        // Anything already in `history` arrived after launch — newer than
        // everything on disk — so it stays in front (the list is newest-first).
        //
        // De-duped BY ID, in-memory wins. A run can settle before this merge lands
        // (an agent run resumed at launch files its record right away), and
        // `recordAgentHistory`'s "replace the row for this task id" only sees the
        // in-memory half — the disk copy of that same id hasn't arrived yet. A raw
        // concat then leaves two rows carrying the SAME id, which the Recent list's
        // `ForEach(id: \.element.id)` renders as undefined results: one of the two
        // draws as a blank row. Keeping the first occurrence of each id also heals
        // an archive that already picked up such a pair on an earlier launch.
        history = Self.dedupedByID(history + surviving)
    }

    /// Newest-first list with each `id` kept once, at its earliest (newest) position.
    /// `history` must never hold two items sharing an id: rows are keyed by it in
    /// every list, and `deleteHistory`/`openHistory` look items up by it.
    private static func dedupedByID(_ items: [HistoryItem]) -> [HistoryItem] {
        var seen = Set<UUID>()
        return items.filter { seen.insert($0.id).inserted }
    }

    nonisolated private static func readHistoryFromDisk() -> [HistoryItem] {
        if let data = try? Data(contentsOf: historyFileURL) {
            return decodeHistory(data)
        }
        // No archive file yet: migrate the legacy UserDefaults blob (where the
        // archive lived through 0.1.13) into the file, and only then drop the
        // defaults copy so the plist shrinks back to settings-sized. If the file
        // write fails the blob stays put and the next launch retries.
        guard let data = UserDefaults.standard.data(forKey: historyKey) else { return [] }
        let items = decodeHistory(data)
        if writeHistoryToDisk(items) {
            UserDefaults.standard.removeObject(forKey: historyKey)
        }
        return items
    }

    nonisolated private static func decodeHistory(_ data: Data) -> [HistoryItem] {
        let decoder = JSONDecoder()
        // Decode item-by-item rather than `decode([HistoryItem].self …)`. The array
        // decode is all-or-nothing — one element that throws (a corrupt blob, or a
        // field that becomes required in a future build) drops the WHOLE list and
        // every Recent row vanishes. `LossyArray` decodes each element in isolation
        // and skips the failures, so one bad item costs only itself.
        if let lossy = try? decoder.decode(LossyArray<HistoryItem>.self, from: data) {
            return lossy.elements
        }
        // Fall back to the strict decode only if even the lossy pass can't open the
        // top-level array (e.g. the blob isn't a JSON array at all).
        return (try? decoder.decode([HistoryItem].self, from: data)) ?? []
    }

    @discardableResult
    nonisolated private static func writeHistoryToDisk(_ items: [HistoryItem]) -> Bool {
        guard let data = try? JSONEncoder().encode(items) else { return false }
        let url = historyFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Atomic, so a crash mid-write can never leave a truncated archive.
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    private func saveHistory() {
        guard historyLoaded else { historySaveDeferred = true; return }
        pendingHistorySave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingHistorySave = nil
                // Value-type snapshot on the main actor; the encode + write of the
                // full archive happens on the utility queue.
                let snapshot = self.history
                Self.historyIO.async { Self.writeHistoryToDisk(snapshot) }
            }
        }
        pendingHistorySave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Immediate, non-debounced archive write for rows that must not sit in the
    /// debounce window. `then` runs after the write lands (on the IO queue) —
    /// the agent path uses it to clear its crash-recovery marker only once the
    /// row is safely on disk. Pre-load (launch recovery, whose marker is
    /// already consumed) it falls back to the deferred-save path and runs the
    /// completion immediately.
    private func saveHistoryNow(then completion: @escaping @Sendable () -> Void) {
        guard historyLoaded else {
            historySaveDeferred = true
            completion()
            return
        }
        pendingHistorySave?.cancel()
        pendingHistorySave = nil
        let snapshot = history
        Self.historyIO.async {
            Self.writeHistoryToDisk(snapshot)
            completion()
        }
    }

    /// Quit-time flush: run the debounced save NOW (synchronously through the IO
    /// queue) so the newest rows survive a ⌘Q inside the debounce window.
    private func flushHistorySave() {
        guard pendingHistorySave != nil else { return }
        pendingHistorySave?.cancel()
        pendingHistorySave = nil
        guard historyLoaded else { return }
        let snapshot = history
        Self.historyIO.sync { Self.writeHistoryToDisk(snapshot) }
    }

    // MARK: - Open width per state (matches the prototype's s-* widths)

    var openWidth: CGFloat {
        // Settings needs a touch more room for the provider/model rows; it only
        // ever shows over the idle view, so it wins regardless of `mode`.
        if showSettings { return Tokens.openWidthSettings }
        // What's New is a reading surface — give it the same comfortable column
        // as the result view. Also shows only over idle, so it wins like settings.
        if showWhatsNew { return Tokens.openWidthWhatsNew }
        switch mode {
        case .result: return Tokens.openWidthResult
        // A follow-up loads with the thread already on screen (shown via the result
        // view), so it must keep the result width — only the first question, with
        // nothing on screen yet, uses the narrower load width.
        case .load:   return turns.isEmpty ? Tokens.openWidthLoad : Tokens.openWidthResult
        case .idle:   return hasText ? Tokens.openWidthIdle : Tokens.openWidthIdle
        }
    }
}

/// Relative time strings ("just now", "12m ago"…) matching the prototype.
func relativeTime(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return L("time.justNow") }
    if s < 3600 { return L("time.minutesAgo", s / 60) }
    if s < 86400 { return L("time.hoursAgo", s / 3600) }
    return L("time.daysAgo", s / 86400)
}

/// A settled record's wall-clock completion stamp for the answer footer — the
/// time on its own when it finished today, month·day·time once it's older (year
/// dropped either way). Locale-aware (24h vs AM/PM follows the system), kept short
/// so it sits in the footer's quiet toolbar. The full date lives in the tooltip.
func completionStamp(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) {
        return date.formatted(date: .omitted, time: .shortened)
    }
    return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
}
