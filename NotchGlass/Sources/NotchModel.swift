import SwiftUI
import Combine
import AppKit   // NSWorkspace — opening Notes/Reminders for a Recent capture

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

/// The notch's interaction state. Mirrors the prototype's `mode` plus the
/// open/closed state, and owns the history list + AI calls.
@MainActor
final class NotchModel: ObservableObject {
    enum Mode: Equatable {
        case idle      // resting input, may show "Recent"
        case load      // waiting on the AI
        case result    // showing an answer
    }

    /// Where pressing Enter on the current line will *send* it — decided live by the
    /// intent classifier as you type. This is a routing destination, NOT a rendered
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

        init(id: UUID = UUID(), role: String, text: String,
             streaming: Bool = false, usedClipboard: Bool = false) {
            self.id = id; self.role = role; self.text = text
            self.streaming = streaming; self.usedClipboard = usedClipboard
        }

        // Same defensive decode as `HistoryItem` (see the long note there): turns
        // are persisted inside a saved thread, and the whole history list is
        // decoded in one `try?` — so a turn saved before `usedClipboard`/`streaming`
        // existed must NOT throw `keyNotFound` and take the entire list down with
        // it. `decodeIfPresent` + defaults is what keeps old saved conversations
        // loadable. `role`/`text` are required — every saved turn has them.
        // `toolActivity` is deliberately absent: it's runtime-only UI state.
        enum CodingKeys: String, CodingKey { case id, role, text, streaming, usedClipboard, sources, isError, regenModel }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id           = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            role         = try c.decode(String.self, forKey: .role)
            text         = try c.decode(String.self, forKey: .text)
            streaming    = try c.decodeIfPresent(Bool.self, forKey: .streaming) ?? false
            usedClipboard = try c.decodeIfPresent(Bool.self, forKey: .usedClipboard) ?? false
            sources      = try c.decodeIfPresent([WebSource].self, forKey: .sources) ?? []
            isError      = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            regenModel   = try c.decodeIfPresent(String.self, forKey: .regenModel)
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

        /// Where this captured line actually went. `.ask` is an AI Q&A (reopens the
        /// conversation); `.note`/`.reminder` are captures filed into Apple
        /// Notes/Reminders — they keep a trace in Recent but have no answer to
        /// reopen, so tapping one jumps to that note/reminder in its app instead.
        /// Defaults to `.ask`; decoded with `decodeIfPresent` (see `init(from:)`)
        /// so items saved before this field decode as `.ask`, not a hard failure.
        enum Source: String, Codable { case ask, note, reminder }
        var source: Source = .ask

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

        /// Transient: true while the first answer for this thread is still
        /// streaming. Set when the question is submitted so the row appears in
        /// Recent immediately (showing the question, with a three-dot placeholder
        /// where the timestamp goes), cleared once the answer lands (`persistThread`)
        /// or the round fails with nothing to keep (`settlePending`). Never encoded
        /// (absent from `CodingKeys`) — a reloaded item is always settled, so a row
        /// can't come back from disk stuck mid-answer.
        var pending: Bool = false

        /// The turns to restore on reopen: the saved thread when present, else a
        /// two-turn thread rebuilt from the legacy `q`/`a` fields. A note/reminder
        /// capture has no conversation at all — never synthesize a ghost assistant
        /// bubble for it.
        var conversation: [Turn] {
            guard source == .ask else { return [] }
            return turns ?? [
                Turn(role: "user", text: q),
                Turn(role: "assistant", text: a),
            ]
        }

        init(id: UUID = UUID(), q: String, a: String, t: Date,
             turns: [Turn]? = nil, title: String? = nil,
             source: Source = .ask, link: String? = nil) {
            self.id = id; self.q = q; self.a = a; self.t = t
            self.turns = turns; self.title = title
            self.source = source; self.link = link
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
        enum CodingKeys: String, CodingKey { case id, q, a, t, turns, title, source, link }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id     = try c.decode(UUID.self,   forKey: .id)
            q      = try c.decode(String.self, forKey: .q)
            a      = try c.decode(String.self, forKey: .a)
            t      = try c.decode(Date.self,   forKey: .t)
            turns  = try c.decodeIfPresent([Turn].self,  forKey: .turns)
            title  = try c.decodeIfPresent(String.self,  forKey: .title)
            source = try c.decodeIfPresent(Source.self,  forKey: .source) ?? .ask
            link   = try c.decodeIfPresent(String.self,  forKey: .link)
        }
    }

    // Open / closed drives the grow-out-of-the-notch animation.
    @Published var open = false
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
    /// streaming in the background, and the resting notch grows its small
    /// left-side extension with the waving dots (see `NotchIsland`) so the work
    /// stays visible in the meanwhile; the walk-away notification and the Recent
    /// row cover the *result*. Unlike `thinking` (pre-stream wait only), this
    /// spans the whole round: incremented when a round's task starts, decremented
    /// on every exit path (clean finish, mid-stream error, supersede-cancel), so
    /// the indicator can never stick on after the last round settles.
    @Published private(set) var roundsInFlight = 0

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
            // A Tab override is scoped to the line it was pressed on. The field
            // emptying — submit cleared it, or the user deleted everything — ends
            // that line, so the next one starts back on auto-classification.
            if manualPanelOverride != nil,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                manualPanelOverride = nil
            }
            // Any real edit ends an ↑/↓ recall session, so the next ↑ starts fresh
            // from the newest item. `isRecallingText` shields the recall's own
            // fill from tripping this (it writes `text` too).
            if !isRecallingText { historyRecallIndex = nil }
            // The recent list only renders over an empty prompt, so text arriving
            // — typed OR an ↑ recall fill — folds it visually. Close it for REAL
            // (state, not just the render gate): a hidden-but-true `showHistory`
            // with a stale highlight would otherwise steal Enter from the visible
            // text (`historyConfirmHighlighted`) and pop the list back open,
            // highlight intact, the moment the box empties again.
            if showHistory, hasText {
                showHistory = false
                highlightedHistoryIndex = nil
            }
            // Feed the "actively typing" signal that holds off hover-leave folding
            // (the one exception to leave-collapses). Empty writes don't count —
            // submit/clear set "" programmatically and mustn't read as typing.
            if !isRecallingText, !text.isEmpty { noteUserTyping() }
            scheduleDueDetection()
            scheduleClassification()
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

    func registerPanelFrame(_ frame: CGRect, restHeight: CGFloat, for display: CGDirectDisplayID) {
        panelScreenFrames[display] = frame
        restHeights[display] = restHeight
    }

    /// Deliberately a plain var write — this fires per frame during the island's
    /// springs, and publishing it would invalidate the whole tree each frame.
    func registerIslandFrame(_ frame: CGRect, for display: CGDirectDisplayID?) {
        guard let display else { return }
        islandFrames[display] = frame
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
    private func pointerInsideRestingNotch(on display: CGDirectDisplayID?, slop: CGFloat) -> Bool? {
        guard let display,
              let panel = panelScreenFrames[display],
              let restHeight = restHeights[display] else { return nil }
        var rect = CGRect(x: panel.midX - Tokens.notchWidth / 2,
                          y: panel.maxY - restHeight,
                          width: Tokens.notchWidth,
                          height: restHeight)
        // While a detached round streams, the resting notch flexes 48pt left
        // (the busy extension) — that strip is hoverable too.
        if !open, roundsInFlight > 0 {
            rect.origin.x -= 48
            rect.size.width += 48
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
    func hoverEntered(on display: CGDirectDisplayID?, velocity: CGVector) {
        let inside = open ? pointerInsideIsland(on: display, slop: 16)
                          : pointerInsideRestingNotch(on: display, slop: 8)
        if inside == false { return }
        openPanel(on: display, velocity: velocity)
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

    /// Destination forced by pressing Tab — the manual escape hatch for when the
    /// classifier reads the line wrong. `nil` means no override: route by the
    /// classifier as usual. Wins over `suggestedPanel` while set, and is scoped to
    /// the current line: cleared the moment the field empties (submit, delete-all,
    /// close), so the next line is auto-classified again. See `toggleSubmitPanel`.
    @Published var manualPanelOverride: Panel? = nil

    /// Confidence the classifier must clear before we'll act on it — both to route
    /// Enter to the other surface AND to label the send button with that destination.
    /// One shared floor on purpose: we never switch surfaces *more* eagerly than the
    /// button is willing to say we will. Below it, the read is treated as unsure and
    /// the current surface (→ ask, by the resting default) handles the line. Tuned
    /// against the embedding engine's calibration (confidence = |2p−1|): on held-out
    /// data 0.4 keeps ~3% confident-and-wrong while still routing ~70% of clear
    /// lines; everything below falls to the ask default (or the LLM second opinion
    /// on Apple Intelligence machines — see `scheduleClassification`).
    static let intentActionFloor = 0.4

    /// The engine's latest read of `text` — published asynchronously by
    /// `scheduleClassification()` after a short debounce, since classification runs
    /// off the main actor (embedding lookup ~10ms on the engine's actor). `.empty`
    /// while the field is empty or a read is still in flight, which resolves to the
    /// ask default everywhere it's consumed.
    @Published private(set) var liveIntent: IntentEngine.Reading = .empty

    /// The first *future* moment the current text names (NSDataDetector, sub-ms,
    /// recomputed synchronously in `text.didSet`). This is what splits the note
    /// branch: the engine only reads ask-vs-note semantically; a note that names a
    /// future time is a **reminder** — a structural fact, not a semantic one. The
    /// same date routes the hint and becomes the due date `submitReminder()` files,
    /// so the "Remind" label and the alarm can never disagree.
    @Published private(set) var detectedDue: Date? = nil

    /// In-flight classification for the current text — superseded (cancelled) by
    /// every keystroke, so only the read of what's actually in the box lands.
    private var classifyTask: Task<Void, Never>?

    /// Debounced re-classification of `text`, called from its `didSet`. Two stages:
    ///   1. ~140ms after the last keystroke: embedding classify (fast, every Mac).
    ///   2. If that read is *unsure* (< 0.5): wait for a real pause (~350ms more),
    ///      then ask the on-device LLM for a second opinion — only exists on Apple
    ///      Intelligence machines; `refine` returns nil everywhere else.
    /// Each publish re-checks that `text` is still the snapshot it classified, so a
    /// stale read can never label (or route) a line it wasn't computed from.
    private func scheduleClassification() {
        classifyTask?.cancel()
        let snapshot = text
        guard !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            liveIntent = .empty
            return
        }
        classifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, let self, self.text == snapshot else { return }
            let reading = await IntentEngine.shared.classify(snapshot)
            guard !Task.isCancelled, self.text == snapshot else { return }
            self.liveIntent = reading

            guard reading.confidence < 0.5 else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, self.text == snapshot else { return }
            guard let refined = await IntentEngine.shared.refine(snapshot),
                  !Task.isCancelled, self.text == snapshot else { return }
            self.liveIntent = refined
        }
    }

    /// Which destination the text *confidently* wants, or `nil` when there's no
    /// clear, confident lean (ambiguous, weak, or empty). Routing and the inline hint
    /// both read this, so they can never disagree — if it's not sure enough to name a
    /// destination, it's not sure enough to route there either. There is only ever one
    /// rendered surface (the chat input); this just decides where Enter *sends* the
    /// line, not what the panel looks like. The "ambiguous → ask" default is applied
    /// at submit time by falling back to `.chat`, not here.
    var suggestedPanel: Panel? {
        guard liveIntent.confidence >= Self.intentActionFloor else { return nil }
        switch liveIntent.intent {
        case .ask:       return .chat
        // Within the note branch, naming a future time upgrades the line to a
        // reminder (a date on an *ask* changes nothing — "明天天气怎么样" still asks).
        case .note:      return detectedDue != nil ? .reminder : .note
        case .ambiguous: return nil
        }
    }

    /// Where pressing Enter on the *current* text will actually land. Resolution
    /// order: once a conversation is on screen every line is a follow-up question, so
    /// it's always Ask — intent routing (Note/Remind) only applies to a *fresh* prompt
    /// (XII-119). On a fresh prompt: a Tab override (the user said so explicitly) beats
    /// the classifier's confident read, which beats `.chat` (the resting "ambiguous →
    /// ask" default). This is exactly the resolution `submitCurrent()` uses, so the
    /// inline hint can show its destination and never lie about it.
    var effectiveSubmitPanel: Panel {
        guard turns.isEmpty else { return .chat }
        return manualPanelOverride ?? suggestedPanel ?? .chat
    }

    /// Tab in the idle prompt: step where Enter will send the current line
    /// (Ask → Note → Remind → Ask…), overriding the classifier. Steps from whatever
    /// the *effective* destination is right now — including a prior override — so
    /// each press reads as "the next one", exactly what the cycled inline hint shows.
    func toggleSubmitPanel() {
        switch effectiveSubmitPanel {
        case .chat:     manualPanelOverride = .note
        case .note:     manualPanelOverride = .reminder
        case .reminder: manualPanelOverride = .chat
        }
    }

    /// The word in the inline hint — the destination spelled out: "Note" when this
    /// line will be saved to Apple Notes, "Remind" when it'll be filed in Apple
    /// Reminders, "Ask" when it'll go to the AI. Flips live with the classifier as
    /// the text crosses intents, so the hint beside the caret literally says where
    /// Enter sends the line.
    var submitLabel: String {
        switch effectiveSubmitPanel {
        case .chat:     return L("hint.ask")
        case .note:     return L("hint.note")
        case .reminder: return L("hint.remind") + submitHintSuffix
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

    /// The current rotating thinking word. Re-rolled at the start of each answer and
    /// every `thinkingWordInterval` while the wait is on screen, avoiding an immediate
    /// repeat. This is the *mood word only* — it is NOT the thing the UI displays
    /// directly. The UI reads `thinkingStatus`, which decides between this word and a
    /// live tool-activity line so the two can never both show at once.
    @Published private var thinkingWord: String = NotchModel.thinkingWords.randomElement() ?? "drifting"

    /// A live tool-activity line ("Searching the web…", "Reading the results…") when a
    /// tool is running, else nil. Set by the harness via `updateActivity`.
    @Published private var thinkingActivity: String? = nil

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
    /// turn can render it as an INDEPENDENT row (above the answer) rather than
    /// folding it into the dots/answer cross-fade. Non-nil exactly while a tool is
    /// running ("Searching the web…", "Reading the results…"); nil otherwise. Kept
    /// separate from `thinkingStatus` because the activity line must stay visible
    /// even after the model has emitted a leading-whitespace preface — sharing the
    /// dots' `hasText` gate is what hid it mid-search.
    var currentActivity: String? { thinkingActivity }

    /// The rotating mood word on its own (no activity merged in), exposed read-only
    /// so `StreamingTurnContent`'s dots row shows *only* the mood word — never the
    /// activity label, which now lives in its own row.
    var currentThinkingWord: String { thinkingWord }

    /// Pick a fresh thinking word, avoiding an immediate repeat.
    private func rerollThinkingWord() {
        let pool = NotchModel.thinkingWords.filter { $0 != thinkingWord }
        thinkingWord = pool.randomElement() ?? NotchModel.thinkingWords.randomElement() ?? thinkingWord
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

    func startThinkingWordRotation() {
        thinkingWordTimer?.invalidate()
        thinkingActivity = nil
        // Each round starts in pure-dots mode; only a tool flips it into word mode.
        hasUsedToolThisRound = false
        rerollThinkingWord()
        let t = Timer(timeInterval: NotchModel.thinkingWordInterval, repeats: true) { [weak self] _ in
            self?.rerollThinkingWord()
        }
        t.tolerance = 0.4
        RunLoop.main.add(t, forMode: .common)
        thinkingWordTimer = t
    }

    func stopThinkingWordRotation() {
        thinkingWordTimer?.invalidate()
        thinkingWordTimer = nil
        thinkingActivity = nil
        hasUsedToolThisRound = false
    }

    /// Funnel the harness's activity label into the single `thinkingStatus` value. A
    /// non-nil label means a tool is running — which also latches the round into "word
    /// mode" so that after the tool clears, the wait shows the mood word (not back to
    /// bare dots). `nil` clears the live line, falling back to the mood word.
    func setThinkingActivity(_ label: String?) {
        if label != nil { hasUsedToolThisRound = true }
        thinkingActivity = label
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
    func awaitUserChoice(answerID: UUID, question: String, options: [String]) async throws -> String {
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
                pendingUserQuestions.append(PendingUserQuestion(
                    id: questionID, answerID: answerID,
                    question: question, options: options))
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
        pendingUserQuestions.removeAll { $0.id == questionID }
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
    @Published var askError: AskError? = nil

    /// The shape of an Ask failure the result view renders into a capsule action.
    struct AskError: Equatable {
        /// The real reason, passed through from the service layer (not a generic
        /// string) so the user sees what actually happened.
        let message: String
        /// True when no model/key is configured — the action should be "open
        /// Settings" rather than "retry" (retrying without a key can't succeed).
        let needsSetup: Bool
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

    /// The clipboard content that's currently available to be folded into an Ask
    /// if the user's question refers to it ("summarize this", "翻译这段", etc.).
    /// Surfaced in the idle UI so the user sees what a referential query would
    /// actually point at. `nil` when the clipboard is stale, empty, oversized, or
    /// an unsupported type.
    @Published var pendingClipboard: String? = nil

    /// The clipboard IMAGE available to attach to an Ask (XII-121) — a screenshot
    /// (⇧⌘⌃4) or any copied bitmap. Non-nil only when the ACTIVE MODEL reads
    /// images (`Provider.modelSupportsVision` — a text-only model never shows the
    /// thumbnail), the clipboard is fresh (same changeCount gate as the text
    /// path), and it holds NO eligible text — a copied string keeps today's text
    /// behaviour untouched. Drives the thumbnail preview above the idle prompt;
    /// the first-turn submit re-reads the pasteboard itself.
    @Published var pendingClipboardImage: NSImage? = nil

    /// The encoded image riding the current thread (XII-121), so follow-ups
    /// re-attach it and "how do I fix it?" still sees the screenshot the thread
    /// started from. Keyed by thread id — a new chat's fresh id simply stops
    /// matching, so this never leaks across conversations. Session-only (not
    /// persisted with history).
    private var threadImage: (threadID: UUID, image: ChatImage)? = nil

    /// What the *copied text itself* reads as, when it leans note/reminder rather than
    /// something to ask about — `.note` or `.reminder`, never `.chat`, and `nil` while
    /// it reads as an Ask, is ambiguous, or the classifier hasn't landed yet. Computed
    /// off the same engine the input box uses, but on the clipboard's text instead of
    /// the prompt's, and published asynchronously by `classifyPendingClipboard()` when
    /// a new clip becomes pending. Drives a leading "Note"/"Remind" capture chip in the
    /// preset row so a copied jot can be filed in one tap, ahead of the Ask presets.
    @Published private(set) var pendingClipboardCapture: Panel? = nil

    /// In-flight clipboard classification — superseded (cancelled) when a new clip
    /// becomes pending, so only the read of what's actually copied lands.
    private var clipboardClassifyTask: Task<Void, Never>?

    /// Set for exactly one `submit()` when a clipboard preset chip is fired, so that
    /// turn folds in the copied text *unconditionally* — skipping the `isReferentialQuery`
    /// re-classification a typed query is gated on. A chip is only ever rendered when
    /// clipboard content exists and its whole purpose is to act on that content, so the
    /// intent isn't in doubt; routing it through the lexical gate just risked a preset
    /// whose phrase happens not to read as referential (e.g. "List the key points of
    /// this") silently running with no copied text. `submit()` reads this once and
    /// clears it, so it never leaks into a follow-up.
    private var forceClipboardInjection = false

    /// Set for exactly one `submit()` when a light-task preset chip fires
    /// (translate/summarize/…), so that turn routes to the provider's lightweight
    /// model and takes the plain single-shot stream (no agent/tool harness — a
    /// mechanical transform never needs web search). Read once and cleared in
    /// `submit()`, so it can never carry into a later typed Ask (XII-132).
    private var presetLightTask = false

    /// When a chip's on-screen wording differs from the instruction sent to the
    /// model (currently only Translate, whose verbose detect-and-route rule must
    /// not leak into the "You" bubble), `runClipboardPreset` stashes the full
    /// instruction here while the visible turn carries the short display phrase.
    /// `submit()` consumes it once for the wire copy, then clears it so it can
    /// never carry into a later typed turn.
    private var forcedWirePhrase: String?

    /// The live conversation rendered in the result view — alternating user and
    /// assistant `Turn`s. A follow-up appends to this rather than replacing it, so
    /// the whole thread stays on screen and (via `submit`) in the model's context.
    /// Empty while idle; the first submit seeds the first user + assistant turns.
    @Published var turns: [Turn] = []

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
    /// The guided first-run flow — opens automatically the first time the panel
    /// opens on a fresh install (see `OnboardingService`). Like settings and What's
    /// New, it owns the whole idle body while true; `OnboardingService.finishGuide()`
    /// clears it. Mutually exclusive with the other body modules.
    @Published var showOnboarding = false
    /// Arms the destructive "Clear recent history?" confirmation. Lives on the
    /// model (not the view) so the Clear pill can raise it while the centered
    /// confirmation card is mounted on the *island* — so it sits in the middle of
    /// the whole glass panel rather than anchored under the pill near the bottom.
    @Published var confirmingClear = false
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
    @Published private(set) var history: [HistoryItem] = []

    /// Shell-style ↑/↓ history recall cursor for the idle prompt. `nil` means no
    /// recall session is in flight (the user is editing normally). Once ↑ pulls a
    /// past question into the box this holds the index into `recallQuestions` (the
    /// dedup'd list, NOT raw `history`) that's shown, so a further ↑ steps older and
    /// ↓ steps newer. Any real keystroke resets it to `nil` (see `text.didSet`), so
    /// recall never fights live editing.
    private var historyRecallIndex: Int? = nil

    /// The question strings ↑/↓ recall walks, newest first — the raw `history` `q`
    /// values with **adjacent duplicates collapsed** (bash `ignoredups`). Asking the
    /// same thing twice in a row leaves one entry here, so ↑ never fills the same
    /// line twice running and the "x / total" counter counts distinct consecutive
    /// questions. Non-adjacent repeats (asked A, then B, then A again) are kept —
    /// only *consecutive* duplicates fold, matching "连续两条相同" exactly.
    private var recallQuestions: [String] {
        var out: [String] = []
        for item in history {           // history is newest-first
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

    /// The recent items rendered in the list — now the FULL stored history (up to
    /// the 50-item persistence cap), not a clipped top-8. The list scrolls, and
    /// keyboard nav auto-scrolls the highlight into view, so every captured item
    /// is reachable. Keyboard navigation indexes into THIS, so highlight bounds and
    /// the rendered rows can never drift apart.
    var recentVisible: [HistoryItem] {
        // Source filter (from the manage menu) narrows first, then the live
        // substring search refines within that slice — the two compose.
        var items = history
        if let source = historySourceFilter {
            items = items.filter { $0.source == source }
        }
        guard !historySearchQuery.isEmpty else { return items }
        return items.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(historySearchQuery)
        }
    }

    private var ai: AIService
    private var task: Task<Void, Never>?
    /// Holds the auto-dismiss timer for the "Saved to Notes" cue so a rapid second
    /// save cancels the first one's fade rather than letting them overlap.
    private var noteCueTask: Task<Void, Never>?
    private let historyKey = "notch_history"

    /// Stable id for the conversation currently on screen, so a follow-up updates
    /// the *same* recent-list row instead of inserting a new one each turn. Reset
    /// whenever a fresh thread begins (first question, new chat, reopened item).
    private var threadHistoryID = UUID()

    init(ai: AIService = StubAIService()) {
        self.ai = ai
        history = loadHistory()
        startClipboardSense()
    }

    deinit {
        senseTimer?.invalidate()
    }

    /// Swap the backend at runtime — used when the user saves an API key in
    /// Settings, so the next question goes live without an app restart.
    func setService(_ service: AIService) {
        ai = service
        // The light-task service is derived from the main provider/key; a provider
        // or key change invalidates it. Rebuilt lazily on next use (XII-132).
        cachedLightService = nil
    }

    /// A service pinned to the provider's lightweight model for mechanical tasks
    /// (translate/summarize chips, title generation) — XII-132. `nil` when routing
    /// is off, the provider has no distinct light tier, or the backend is the
    /// offline stub / unconfigured; callers then just use the main `ai`, so a task
    /// never fails for lack of a light model. Cached until `setService` swaps it.
    private var cachedLightService: AIService?
    private var lightService: AIService? {
        // Stub / unconfigured → no routing (the caller's own stub guards still fire).
        guard !(ai is StubAIService) else { return nil }
        if let cached = cachedLightService { return cached }
        let provider = APIKeyStore.selectedProvider
        guard let key = APIKeyStore.current(for: provider),
              let lightModel = APIKeyStore.lightTaskModel(for: provider) else { return nil }
        let service = AppDelegate.makeService(provider: provider, apiKey: key, model: lightModel)
        cachedLightService = service
        return service
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
        refreshPendingClipboard()
    }

    /// Read the current pasteboard and update `pendingClipboard` for the idle UI.
    /// Called on the closed→open edge and after any in-app pasteboard write, so the
    /// preview stays in sync with what's actually available. Respects the same
    /// eligibility rules as injection (fresh, non-empty, ≤1500 chars, supported type).
    func refreshPendingClipboard() {
        let next = clipboardContextIfEligible()
        if next != pendingClipboard {
            // A new (or cleared) clipboard always reopens the preset row collapsed, so
            // the panel never inherits a previous clip's expanded "⋯" state.
            clipboardPresetsExpanded = false
            // Drop the prior clip's verdict *synchronously* so its chip can't linger
            // over the new clip while the async re-classification is still in flight —
            // otherwise a "Note" chip from the old copy could briefly sit (and act) on
            // the new one. classifyPendingClipboard republishes once the read lands.
            pendingClipboardCapture = nil
            classifyPendingClipboard(next)
        }
        pendingClipboard = next
        // The image preview (XII-121) only exists when no text clip took the slot;
        // a stale/text clipboard clears it so a thumbnail never lingers.
        pendingClipboardImage = (next == nil) ? clipboardImageIfEligible() : nil
    }

    /// Read whether the *copied text* is itself a note/reminder, and publish the verdict
    /// to `pendingClipboardCapture`. Mirrors the input box's `scheduleClassification`,
    /// but on the clipboard string and with no debounce — a clipboard changes far less
    /// often than a keystroke, so we classify the one snapshot directly. Clears the
    /// capture immediately for an empty/stale clip so a leftover verdict can't linger.
    ///
    /// The note→reminder split is the same structural rule the prompt uses: a note that
    /// names a future time is a reminder. We compute that date here from the *clip*
    /// (not `detectedDue`, which tracks the input box) so the chip and the eventual
    /// write agree on what got copied.
    private func classifyPendingClipboard(_ clip: String?) {
        clipboardClassifyTask?.cancel()
        guard let clip, !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pendingClipboardCapture = nil
            return
        }
        // A clip the sense confirm already filed (or is filing right now) never
        // re-offers as a chip — tapping it would file the same text twice.
        guard clip != senseCapturedClip else {
            pendingClipboardCapture = nil
            return
        }
        clipboardClassifyTask = Task { [weak self] in
            let reading = await IntentEngine.shared.classify(clip)
            guard !Task.isCancelled, let self, self.pendingClipboard == clip else { return }
            // Only a confident *note* read earns a capture chip; an Ask (or anything
            // unsure) leaves the row as the existing preset-only Ask shortcuts.
            let verdict: Panel?
            if reading.confidence >= Self.intentActionFloor, reading.intent == .note {
                let due = RemindersService.futureDate(in: clip)
                    ?? RemindersService.recurrenceDate(in: clip)
                verdict = due != nil ? .reminder : .note
            } else {
                verdict = nil
            }
            // The read lands ~10-20ms after the preset row is already on screen. The
            // chip's appearance is animated by an `.animation(value:)` on the row itself
            // (see clipboardPresetChips) — keying the spring there, not here, keeps the
            // FlowLayout reflow and the chip's own transition on one transaction.
            self.pendingClipboardCapture = verdict
        }
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

    /// Whether mechanical side-tasks (translate/summarize chips, title generation)
    /// use the provider's lightweight model instead of the main Ask model (XII-132).
    /// Published mirror of `APIKeyStore.lightTasksEnabled` so the Settings toggle
    /// drives it live; a change invalidates the cached light service so the next
    /// task re-derives it (or falls back to main when turned off).
    @Published var lightTasksEnabled: Bool = APIKeyStore.lightTasksEnabled {
        didSet {
            APIKeyStore.lightTasksEnabled = lightTasksEnabled
            cachedLightService = nil
        }
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

    /// Background sensing must earn its interruption: the in-panel chip fires at
    /// `intentActionFloor` (the user is already looking at the panel), but a hint
    /// that lights up the closed notch on every copy needs a stronger read. Below
    /// this the background default is *nothing* — the opposite of the input box,
    /// whose default is Ask.
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
        entryVelocity = velocity
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
            pasteboardChangeCountAtOpen = pasteboardChangeCountAtRest
            if mode == .idle, turns.isEmpty, !showOnboarding, let round = inFlightRounds.last {
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
        }
        // A hover re-entry supersedes any pending leave watch.
        cancelLeaveWatch()
        // Re-entering during the close dissolve cancels it: clear the flag so the
        // content (held mounted while `open` is true) springs back to full opacity
        // instead of completing its fade, and the pending `beginClose` timer no-ops.
        closing = false
        open = true
        // An open hands the clipboard to the in-panel flow: a visible sense hint
        // retires (its clip re-surfaces as the capture chip via the refresh below),
        // while a saving/saved narration settles on its own timer, just unseen.
        if case .hinting = clipboardSense { senseCancelHint() }
        refreshPendingClipboard()
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
        } else {
            // The provider/model may have changed in there — recompute the
            // clipboard-image eligibility (XII-121) so the thumbnail appears or
            // disappears to match the model the next Ask will actually hit.
            refreshPendingClipboard()
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
        refreshPendingClipboard()
        mode = .idle
        showSettings = true
        showWhatsNew = false
        showHistory = false
        highlightedHistoryIndex = nil
    }

    /// Leave settings and return to the idle prompt (panel stays open).
    func closeSettings() {
        showSettings = false
        // Same model-gate recompute as `toggleSettings` (XII-121).
        refreshPendingClipboard()
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
        refreshPendingClipboard()
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

    /// Open the guided first-run flow in place of the prompt — the path the first
    /// panel-open takes on a fresh install. Mirrors `openWhatsNew`: it folds the
    /// other body modules away (they share the same slot) and keeps the panel open.
    func openOnboarding(on display: CGDirectDisplayID? = nil) {
        entryVelocity = .zero
        if let display { activeDisplay = display }
        if !open {
            pasteboardChangeCountAtOpen = pasteboardChangeCountAtRest
        }
        closing = false
        cancelLeaveWatch()
        open = true
        mode = .idle
        showOnboarding = true
        showWhatsNew = false
        showSettings = false
        showHistory = false
        highlightedHistoryIndex = nil
    }

    /// Leave the guide and return to the idle prompt (panel stays open). Records the
    /// guide as done so it never leads again.
    func closeOnboarding() {
        OnboardingService.shared.finishGuide()
        showOnboarding = false
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
        // Nothing to fold on a resting notch — and a stale deferred fold must
        // never fire `fullClose` on an already-closed panel (that would wipe a
        // freshly parked session).
        guard open else { return }
        // The user pinned this answer: leaving is no longer a fold signal. Drop any
        // watch that was already armed (a leave-during-typing may have scheduled
        // one before the pin) so it can't fire behind the pin's back.
        if isAnswerPinned {
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
        if isAnswerPinned { cancelLeaveWatch(); return }
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
                            measuredAnswerHeight: lastMeasuredAnswerHeight)
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
        // Drop the preview so the resting panel stays minimal; the next open will
        // re-evaluate and surface anything fresh.
        pendingClipboard = nil
        clipboardClassifyTask?.cancel()
        pendingClipboardCapture = nil
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
        mode = .idle
        isAnswerPinned = false
        text = ""; turns = []
        showHistory = false
        showSettings = false
        highlightedHistoryIndex = nil
        // Clear the note/reminder-save state, exactly like `fullClose` does (XII-86).
        // Backing out with Back while a Note/Reminder write is still in flight (e.g.
        // an AppleScript retry) used to leave `noteSaving` stuck true here — and the
        // `guard !noteSaving` in `runClipboardCapture` then permanently blocked every
        // clipboard-capture chip tap until the next full close. Resetting it (plus the
        // cue task and feedback fields) keeps the next session clean.
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
        switch effectiveSubmitPanel {
        case .chat:     submit()
        case .note:     submitNote()
        case .reminder: submitReminder()
        }
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

    /// The clipboard string that's *available* to fold into an Ask, or `nil` when
    /// the clipboard itself isn't a candidate. This is only the clipboard-state half
    /// of the gate — whether the *query* actually refers to it is `isReferentialQuery`,
    /// tested separately in `submit`. Available means: the user copied for *this*
    /// session — the `changeCount` has moved past its pre-open resting baseline, which
    /// covers the intended copy-THEN-open flow (the baseline is the count from before
    /// the open; see `pasteboardChangeCountAtOpen`) as well as a copy made while the
    /// panel is open; the clipboard holds a non-empty string, URL, or file URL; and
    /// it's short enough (≤ 1500 chars) to inject without blowing up the prompt;
    /// and it isn't text this session is itself displaying (see
    /// `isCurrentSessionText` — an in-panel copy never becomes a quote).
    /// Anything longer than 1500 chars, an image, or a stale clipboard returns nil.
    /// Read once per submit; never mutates the pasteboard.
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
    private func clipboardImageIfEligible() -> NSImage? {
        let provider = APIKeyStore.selectedProvider
        let model = APIKeyStore.effectiveModel(for: provider) ?? provider.defaultModel
        guard Provider.modelSupportsVision(model) else { return nil }
        let pb = NSPasteboard.general
        guard pb.changeCount != pasteboardChangeCountAtOpen else { return nil }
        guard clipboardContextIfEligible() == nil else { return nil }
        guard let image = NSImage(pasteboard: pb), image.isValid else { return nil }
        return image
    }

    /// Downsample + encode a clipboard image for the wire (XII-121): long side
    /// capped at 1568px (Anthropic's documented vision sweet spot; also keeps any
    /// provider's payload sane), JPEG at 0.82 — a full-screen Retina screenshot
    /// lands in the hundreds-of-KB range instead of many MB. Returns `nil` when
    /// the bitmap can't be read or encoded, in which case the turn just goes out
    /// as plain text.
    static func encodeForVision(_ image: NSImage) -> ChatImage? {
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
        guard let jpeg = finalRep.representation(using: .jpeg,
                                                 properties: [.compressionFactor: 0.82])
        else { return nil }
        return ChatImage(base64: jpeg.base64EncodedString(), mediaType: "image/jpeg")
    }

    /// Does this query *refer to* something the user has on hand — i.e. is it the
    /// kind of line where folding in the clipboard actually helps? This is the
    /// automatic gate that replaced the manual "attach" pill: a fresh copy alone
    /// isn't enough to inject (people copy things incidentally), so we only pull the
    /// clipboard in when the question reads as being *about* it. Two signals, either
    /// one is enough:
    ///   1. A deictic — a pointing word with no antecedent in the query itself
    ///      ("summarize **this**", "翻译**这段**", "what does **it** mean"). On a
    ///      first turn there's nothing on screen to point at, so the referent is
    ///      almost always what they just copied.
    ///   2. A bare content operation — a transform verb whose object is missing
    ///      ("summarize", "translate", "解释一下", "润色"). "Summarize the French
    ///      revolution" names its own object and is NOT referential; "Summarize" /
    ///      "Summarize this" leaves the object open, so the clipboard fills it.
    /// Deliberately conservative: a self-contained question ("what's the capital of
    /// France") matches neither and gets no clipboard, which is the safe default —
    /// a false negative just means the old no-context behaviour, a false positive
    /// silently pollutes an unrelated answer. Lexical only; no model call.
    private func isReferentialQuery(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return false }

        // --- Colon guard (ASCII + fullwidth): "translate: bonjour", "解释：光合作用",
        // "rewrite this sentence: the cat sat …". When a colon is followed by ≥2
        // non-blank chars the object is supplied inline — NOT referential, whatever
        // verb or deictic precedes it.
        if let colon = q.range(of: ":") ?? q.range(of: "：") {
            let after = q[colon.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if after.count >= 2 { return false }
        }

        // ── Chinese ───────────────────────────────────────────────────────────
        // Verbs first — a couple of CJK gates below key off whether one is present.
        // Bare transform verbs that imply "…this text". Length gate ≤15 (up from 8)
        // lets polite forms like "帮我总结一下重要内容" through; the named-object guard
        // keeps "总结法国史"/"翻译猫" out.
        let cjkContentOps = ["总结", "概括", "归纳", "摘要", "翻译", "翻", "解释",
                             "润色", "改写", "修改", "修正", "改", "扩写", "缩写",
                             "提炼", "分析", "点评", "校对", "整理", "检查", "查"]
        let hasCjkVerb = cjkContentOps.contains { q.contains($0) }

        // Specific content-deictics (point at a text object, not a place/time).
        // Excludes bare "这" (fires on "这里" = a location) and bare "其" (fires
        // inside discourse markers 其实/其次) — those were the worst false-positives.
        let cjkDeictics = ["这个", "这段", "这些", "这条", "这句", "这篇", "这里面",
                           "上面", "上述", "里面", "它"]
        if cjkDeictics.contains(where: { q.contains($0) }) {
            // CJK has no clean copula signal, so a deictic inside a plain *statement*
            // ("其实这个问题很简单", "Python很流行，它好学吗") still slips through the
            // deictic list. Cheap guard: if there's no content-op verb AND a degree/
            // copula cue is present (很/真/非常/就是…), read it as a statement, not a
            // request, and don't inject. Drops the worst remaining false-positives.
            let statementCues = ["很", "真", "挺", "非常", "特别", "太", "就是",
                                 "好用", "简单", "流行", "厉害"]
            let looksLikeStatement = !hasCjkVerb && statementCues.contains { q.contains($0) }
            if !looksLikeStatement { return true }
        }

        // "以上" points at copied text only in a *request* — not in a declarative
        // ("以上就是我的看法" = "that's my view", a statement).
        if q.contains("以上") {
            let after = q.components(separatedBy: "以上").dropFirst().joined()
            let declarative = ["是", "就是", "为", "就为"].contains { after.hasPrefix($0) }
            if !declarative { return true }
        }

        // "刚才"/"刚刚" point at the clipboard only when the referent is *content*;
        // when they refer to the ongoing chat ("总结一下刚才的对话") the query names
        // its own source and is self-contained.
        let chatReferents = ["对话", "聊", "说", "讲", "谈", "讨论", "交流", "的话"]
        for deictic in ["刚才", "刚刚"] where q.contains(deictic) {
            if !chatReferents.contains(where: { q.contains($0) }) { return true }
        }

        // Bare-verb path (verb list + flag hoisted above): referential only when the
        // line is essentially the verb plus filler — no self-supplied named object.
        if q.count <= 15, let verb = cjkContentOps.first(where: { q.contains($0) }) {
            if !cjkHasNamedObject(q, verb: verb) { return true }
        }

        // ── English ───────────────────────────────────────────────────────────
        // A deictic alone isn't enough — "this is great"/"it works" are statements.
        // Require an action signal (content-op verb or question word) alongside it,
        // and exclude fixed discourse markers that merely *contain* a deictic word.
        let enDeictics = ["this", "that", "these", "those", "it", "above", "the following", "the text"]
        if enDeictics.contains(where: { containsWord($0, in: q) }) {
            let discourseMarkers = ["that said", "that is to say", "that being said",
                                    "it depends", "it takes", "it is what it is",
                                    "above average", "above all"]
            if !discourseMarkers.contains(where: { q.contains($0) }) {
                let verbs = enContentOpVerbs
                let questionWords = ["what", "how", "why", "when", "where", "who",
                                     "which", "does", "do", "mean", "means", "meant"]
                let hasVerb = verbs.contains { containsWord($0, in: q) }
                let hasQuestion = questionWords.contains { containsWord($0, in: q) }
                // "the following"/"the text" are task-oriented even without a verb.
                let contentDeictic = containsWord("the following", in: q) || containsWord("the text", in: q)
                // "explain yourself" addresses the assistant, not copied text.
                let selfDirected = containsWord("yourself", in: q) && containsWord("explain", in: q)
                if (hasVerb || hasQuestion || contentDeictic) && !selfDirected { return true }
            }
        }

        // Bare content-op verb (no deictic): referential when the line is the verb
        // plus filler only. Word gate ≤7 (up from 3) admits "can you summarize for
        // me"; the named-object guard keeps "explain recursion"/"tldr on stoicism" out.
        let words = q.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        if words <= 7, enContentOpVerbs.contains(where: { containsWord($0, in: q) }) {
            if !enHasNamedObject(q) { return true }
        }

        return false
    }

    /// English transform verbs whose object can dangle onto the clipboard. Shared by
    /// the deictic-pairing check and the bare-verb path so the two never drift.
    private var enContentOpVerbs: [String] {
        ["summarize", "summarise", "translate", "explain", "paraphrase",
         "rephrase", "rewrite", "proofread", "tldr", "tl;dr", "simplify",
         "fix", "edit", "reword", "condense", "check", "improve",
         "clean", "correct", "tighten", "convert", "format", "compress",
         "shorten", "expand", "review", "analyze", "analyse"]
    }

    /// Filler *nouns* that name a generic facet of the copied text rather than a
    /// self-supplied subject — "总结一下主要**内容**" still dangles onto the clipboard,
    /// and grammar/spelling style nouns ("帮我改一下**语法**") are properties of the
    /// copied text, not new objects. Stripped alongside particles so they don't read
    /// as a named object and suppress injection.
    private let cjkFillerNouns = ["内容", "信息", "文字", "文本", "部分", "东西",
                                  "语法", "拼写", "标点", "措辞", "格式", "错误",
                                  "错别字", "病句", "用词"]

    /// True when a CJK query supplies its *own* named object (so the clipboard isn't
    /// needed). Strips the matched verb, polite prefixes, and filler particles; if any
    /// CJK char survives, it's a self-supplied subject ("翻译**猫**", "总结**法国史**").
    /// "翻译一下" / "帮我总结一下" / "总结一下主要内容" leave nothing → object is dangling.
    private func cjkHasNamedObject(_ q: String, verb: String) -> Bool {
        let fillers = ["一下", "一遍", "一次", "一番", "帮我", "帮忙", "请你", "你帮",
                       "给我", "给你", "我需要", "麻烦", "请", "帮",
                       "吧", "呢", "啊", "嘛", "吗", "哦", "哈", "好",
                       "主要", "重要", "关键", "重点"] + cjkFillerNouns
        var residual = q
        // Remove the longest matching verb first ("改写" before "改") so a short verb
        // doesn't leave its longer sibling's tail behind.
        let allVerbs = ["总结", "概括", "归纳", "摘要", "翻译", "解释", "润色", "改写",
                        "修改", "修正", "扩写", "缩写", "提炼", "分析", "点评", "校对",
                        "整理", "检查", "翻", "改", "查"].sorted { $0.count > $1.count }
        for v in allVerbs {
            if let r = residual.range(of: v) { residual.removeSubrange(r); break }
        }
        // Longest filler first ("错别字" before "错误"/"字") so a short noun doesn't
        // strand its longer sibling's tail.
        for filler in fillers.sorted(by: { $0.count > $1.count }) {
            residual = residual.replacingOccurrences(of: filler, with: "")
        }
        var maxRun = 0, run = 0
        for c in residual {
            let isHan = c.unicodeScalars.first.map { $0.value >= 0x4E00 && $0.value <= 0x9FFF } ?? false
            if isHan { run += 1; maxRun = max(maxRun, run) } else { run = 0 }
        }
        // Even one leftover Han char ("翻译猫" → "猫") is a self-supplied object.
        return maxRun >= 1
    }

    /// Attribute words that name a *property* of the copied text rather than a fresh
    /// subject — "fix the grammar", "check spelling", "any typos?" all operate on
    /// whatever was copied. Treated as fillers so they don't read as a named object
    /// and suppress injection.
    private let enAttributeWords: Set<String> = [
        "grammar", "spelling", "typo", "typos", "punctuation", "wording", "phrasing",
        "tone", "clarity", "writing", "text", "wordings", "mistakes", "errors",
        "mistake", "error", "sentence", "sentences", "paragraph", "wordiness",
    ]

    /// True when an English query supplies its own named object beyond language /
    /// direction words (so the clipboard isn't needed). Strips verbs, fillers, and
    /// target-language/style words; a substantive token left over is a named subject
    /// ("explain **recursion**", "tldr on **stoicism**"). "translate to french
    /// please" leaves only direction/filler → object dangles → referential.
    private func enHasNamedObject(_ q: String) -> Bool {
        let baseFillers: Set<String> = [
            "please", "pls", "plz", "can", "you", "me", "for", "a", "the", "i", "just",
            "quickly", "could", "would", "should", "will", "may", "might", "help",
            "to", "into", "from", "in", "on", "at", "of", "and", "or", "up",
            "my", "this", "that", "these", "those", "it", "all", "any", "some", "more",
            // target-language / style indicators name a TARGET, not the source object
            "english", "french", "spanish", "german", "italian", "portuguese",
            "chinese", "japanese", "korean", "arabic", "russian", "hindi",
            "formal", "informal", "simple", "simpler", "clearer", "shorter",
            "better", "bullet", "points", "tone", "style", "format",
        ]
        // Attribute words (grammar/spelling/…) operate on the copied text, not a new
        // object, so they count as fillers too.
        let fillers = baseFillers.union(enAttributeWords)
        let verbs = Set(enContentOpVerbs + ["give", "get", "make"])
        let substantive = q
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && !fillers.contains($0) && !verbs.contains($0) }
        return substantive.contains { $0.count >= 2 && ($0.first?.isLetter ?? false) }
    }

    /// Whole-word containment for the Latin-script gates above — avoids "it" firing
    /// inside "edit" or "this" inside "thistle". Loops over every occurrence so a
    /// non-boundary first hit doesn't mask a later word-boundary one. Builds a manual
    /// boundary test rather than dragging in NSRegularExpression for a few literals.
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

    // MARK: - Clipboard presets

    /// A one-tap action offered above the prompt when there's eligible clipboard
    /// content — the equivalent of Apple Writing Tools' Proofread / Rewrite / tone /
    /// Summarize / Key-Points chips, but routed through this app's existing pipeline.
    ///
    /// Each preset is just a *referential query* the chip authors into the prompt:
    /// the phrase ("Summarize this", "润色", …) is deliberately object-less so
    /// `isReferentialQuery` reads it as pointing at the copied text and `submit()`
    /// folds the clipboard in — no separate prompt plumbing, the same path a typed
    /// "summarize this" already takes. The cases mirror Apple's set; `phrase(cjk:)`
    /// returns the wording in the language of the copied text (we present the action
    /// in the script the user actually copied, matching the bilingual gates above).
    enum ClipboardPreset: String, CaseIterable, Identifiable {
        case summarize          // Apple: Summary
        case keyPoints          // Apple: Key Points
        case proofread          // Apple: Proofread
        case rewrite            // Apple: Rewrite
        case friendly           // Apple: Friendly tone
        case professional       // Apple: Professional tone
        case concise            // Apple: Concise tone
        case translate          // (Notch addition — common on copied text)

        var id: String { rawValue }

        /// The short chip label, in the app's interface language. (The *phrase*
        /// sent to the model still follows the copied text's script — see
        /// `phrase(cjk:)` — but the chip the user reads tracks the UI language.)
        var label: String {
            switch self {
            case .summarize:    return L("preset.summarize")
            case .keyPoints:    return L("preset.keyPoints")
            case .proofread:    return L("preset.proofread")
            case .rewrite:      return L("preset.rewrite")
            case .friendly:     return L("preset.friendly")
            case .professional: return L("preset.professional")
            case .concise:      return L("preset.concise")
            case .translate:    return L("preset.translate")
            }
        }

        /// The text shown in the on-screen "You" bubble for this chip — what the
        /// user *conceptually* asked, not the full instruction sent to the model.
        /// For most presets the wire phrase already reads naturally ("Summarize
        /// this"), so the display text *is* the phrase. Translate is the exception:
        /// its wire phrase is a verbose detect-and-route rule that must never leak
        /// on screen, so it gets a short stand-in. `submit()` shows this while
        /// sending the full `phrase(cjk:)` (plus the clipboard) to the model.
        func displayPhrase(cjk: Bool) -> String {
            switch self {
            case .translate: return cjk ? "翻译这段" : "Translate this"
            default:         return phrase(cjk: cjk)
            }
        }

        /// The referential query the chip drops into the prompt. Object-less by
        /// design so `isReferentialQuery` pairs it with the clipboard.
        func phrase(cjk: Bool) -> String {
            switch self {
            case .summarize:    return cjk ? "总结一下这段"           : "Summarize this"
            case .keyPoints:    return cjk ? "用要点列出这段的重点"     : "List the key points of this"
            case .proofread:    return cjk ? "校对这段，修正语法和拼写" : "Proofread this for grammar and spelling"
            case .rewrite:      return cjk ? "改写这段"               : "Rewrite this"
            case .friendly:     return cjk ? "把这段改得更友好一些"     : "Rewrite this to sound more friendly"
            case .professional: return cjk ? "把这段改得更正式一些"     : "Rewrite this to sound more professional"
            case .concise:      return cjk ? "把这段改得更精炼"         : "Rewrite this to be more concise"
            case .translate:
                // Dual-preference rule: detect the language of the pasted text,
                // then translate based on these three cases:
                //   1. Neither pref1 nor pref2 → translate into pref1
                //   2. Is pref1 → translate into pref2
                //   3. Is pref2 → translate into pref1
                // The AI does the language detection — no third-party library
                // is introduced. Phrase is object-less so `isReferentialQuery`
                // pairs it with the clipboard.
                let pref1 = TranslationLanguage.loadPref1()
                let pref2 = TranslationLanguage.loadPref2()
                // Guard the degenerate pref1 == pref2 case (XII-113): the user can set
                // both slots to the same language (Settings, or either chip context
                // submenu), and the three-way rule then collapses into "if it's X,
                // translate to X" — self-contradictory, so the model echoes the source
                // or flails, silently. Fall back to the old single-target rule: if the
                // clip is already that language, translate it back to its source
                // language; otherwise translate it into that language. Always a
                // meaningful direction, never a no-op.
                guard pref1 != pref2 else {
                    let only = pref1
                    if cjk {
                        return "把这段翻译一下：如果是\(only.cjkName)就翻译成它的原文语言，" +
                               "否则翻译成\(only.cjkName)。只输出译文，不加解释。"
                    } else {
                        return "Translate this: if it is in \(only.englishName), translate it to its " +
                               "original language; otherwise translate it into \(only.englishName). " +
                               "Output only the translation, no explanation."
                    }
                }
                if cjk {
                    return "判断这段文字是什么语言，然后按以下规则翻译：" +
                           "如果是\(pref1.cjkName)，翻译成\(pref2.cjkName)；" +
                           "如果是\(pref2.cjkName)，翻译成\(pref1.cjkName)；" +
                           "如果两者都不是，翻译成\(pref1.cjkName)。" +
                           "只输出译文，不加解释。"
                } else {
                    return "Detect the language of this text, then translate it: " +
                           "if it is \(pref1.englishName), translate into \(pref2.englishName); " +
                           "if it is \(pref2.englishName), translate into \(pref1.englishName); " +
                           "if it is neither, translate into \(pref1.englishName). " +
                           "Output only the translation, no explanation."
                }
            }
        }

        /// The default enabled set when the user has never customized it — every
        /// preset, in the canonical order. Customizing (XII-111) narrows this; the
        /// enabled set then drives the clipboard chip row (collapsed to a few behind
        /// a "⋯", unfurling on hover).
        static let defaultEnabled: [ClipboardPreset] = ClipboardPreset.allCases
    }

    /// Which clipboard presets the user has chosen to offer, in display order —

    // MARK: - Translation preferences

    /// Primary translation language (pref1). The chip translates into pref1
    /// when the copied text is pref2 or any other language. Published so the
    /// chip label re-renders immediately; `didSet` persists to UserDefaults.
    @Published var translationPref1: TranslationLanguage =
        TranslationLanguage.loadPref1() {
        didSet { TranslationLanguage.savePref1(translationPref1) }
    }

    /// Secondary translation language (pref2). The chip translates into pref2
    /// when the copied text is pref1. Published so the chip label re-renders
    /// immediately; `didSet` persists to UserDefaults.
    @Published var translationPref2: TranslationLanguage =
        TranslationLanguage.loadPref2() {
        didSet { TranslationLanguage.savePref2(translationPref2) }
    }

    /// The directional suffix for the Translate chip, resolved against the *pending
    /// clipboard* — only the target language is shown ("→dst", e.g. "→En"); the
    /// source is omitted so the chip stays compact. Recomputes whenever the
    /// clipboard or either pref changes (all are `@Published`).
    var translateChipDirection: String {
        let (_, target) = TranslationLanguage.resolveDirection(
            clip: pendingClipboard,
            pref1: translationPref1,
            pref2: translationPref2)
        return "→\(target.chipLabel)"
    }

    /// the "custom quick-tools" set (XII-111). Persisted as an ordered list of
    /// raw values in `UserDefaults`; defaults to every preset. The published
    /// property drives the chip row live, and its `didSet` writes through.
    @Published var enabledClipboardPresets: [ClipboardPreset] = NotchModel.loadEnabledPresets() {
        didSet { NotchModel.saveEnabledPresets(enabledClipboardPresets) }
    }

    private static let enabledPresetsKey = "clipboardPresets.enabled"

    private static func loadEnabledPresets() -> [ClipboardPreset] {
        guard let raw = UserDefaults.standard.array(forKey: enabledPresetsKey) as? [String] else {
            return ClipboardPreset.defaultEnabled
        }
        // Map stored raw values back to cases, dropping any unknown (e.g. a preset
        // removed in a later build). An empty/all-unknown result falls back to the
        // default so the row is never silently emptied by stale data.
        let restored = raw.compactMap { ClipboardPreset(rawValue: $0) }
        return restored.isEmpty ? ClipboardPreset.defaultEnabled : restored
    }

    private static func saveEnabledPresets(_ presets: [ClipboardPreset]) {
        UserDefaults.standard.set(presets.map(\.rawValue), forKey: enabledPresetsKey)
    }

    /// Toggle one preset on/off in the enabled set, preserving canonical order.
    /// Refuses to remove the last one — an empty row would strip the feature
    /// entirely with no way back from the chip UI.
    func setClipboardPreset(_ preset: ClipboardPreset, enabled: Bool) {
        if enabled {
            guard !enabledClipboardPresets.contains(preset) else { return }
            // Re-insert in canonical order so the row stays stably ordered.
            enabledClipboardPresets = ClipboardPreset.allCases.filter {
                $0 == preset || enabledClipboardPresets.contains($0)
            }
        } else {
            guard enabledClipboardPresets.count > 1 else { return }
            enabledClipboardPresets.removeAll { $0 == preset }
        }
    }

    /// The presets to offer for the currently-pending clipboard, or `[]` when there's
    /// nothing eligible. Honors the user's enabled set (XII-111); only the *script*
    /// of the labels/phrases follows the copied text (so a Chinese clipboard gets
    /// Chinese chips), ordered to read left-to-right by likelihood.
    var clipboardPresets: [ClipboardPreset] {
        guard pendingClipboard != nil else { return [] }
        return enabledClipboardPresets
    }

    /// How many enabled presets the collapsed row shows before the rest tuck behind
    /// the "⋯" chip. Keeps the resting row short in the narrow notch; the user's full
    /// enabled set unfurls on hover. (Unchecked presets never appear at all.)
    static let collapsedPresetCount = 3

    /// Whether the preset row is unfurled to show every enabled preset (true) or just
    /// the first `collapsedPresetCount` behind a "⋯" chip (false, the default). Resets
    /// to collapsed each time a new clipboard becomes pending so the row opens compact.
    @Published var clipboardPresetsExpanded = false

    /// The presets visible right now: the user's enabled set (XII-111), but collapsed
    /// to the first `collapsedPresetCount` until the row is hovered/expanded — the rest
    /// tuck behind a "⋯" chip rather than scrolling or wrapping. Unchecked presets are
    /// absent entirely. Empty when there's nothing eligible.
    var visibleClipboardPresets: [ClipboardPreset] {
        let all = clipboardPresets
        guard !all.isEmpty else { return [] }
        if clipboardPresetsExpanded { return all }
        return Array(all.prefix(NotchModel.collapsedPresetCount))
    }

    /// True when the pending clipboard is predominantly CJK text, so the preset chips
    /// speak the language the user copied. Counts Han characters against total letters;
    /// a short majority is enough (mixed clips lean to whichever script dominates).
    var pendingClipboardIsCJK: Bool {
        guard let clip = pendingClipboard else { return false }
        var han = 0, letters = 0
        for scalar in clip.unicodeScalars {
            if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF { han += 1; letters += 1 }
            else if CharacterSet.letters.contains(scalar) { letters += 1 }
        }
        guard letters > 0 else { return false }
        return Double(han) / Double(letters) >= 0.3
    }

    /// Fire a clipboard preset: author its referential phrase into the prompt and
    /// submit it. Going through `text` + `submitCurrent()` (rather than a bespoke
    /// path) means the existing clipboard-injection gate in `submit()` does the real
    /// work — the phrase is object-less, so `isReferentialQuery` pairs it with the
    /// copied text and folds it into the wire message exactly as a typed "summarize
    /// this" would. No-op if the clipboard went stale between render and tap.
    ///
    /// Goes straight to `submit()` (the AI path), NOT `submitCurrent()`: a preset is
    /// always an Ask, and `submitCurrent()` would route off the *stale* `liveIntent`
    /// — classification is debounced ~140ms, so right after we set `text` the read is
    /// still whatever the field held before, which could misfile a preset to
    /// Note/Reminder. Calling `submit()` directly sidesteps the classifier entirely;
    /// the referential phrase still drives clipboard injection inside `submit()`.
    func runClipboardPreset(_ preset: ClipboardPreset) {
        guard pendingClipboard != nil else { return }
        manualPanelOverride = nil
        // The "You" bubble shows the short display phrase; the model gets the full
        // instruction. They match for every preset except Translate, whose
        // detect-and-route rule must stay off screen — see `displayPhrase`.
        let display = preset.displayPhrase(cjk: pendingClipboardIsCJK)
        let wire = preset.phrase(cjk: pendingClipboardIsCJK)
        text = display
        forcedWirePhrase = (wire != display) ? wire : nil
        // The chip *is* the clipboard intent — fold the copied text in directly rather
        // than re-deriving it from the phrase's wording (which `isReferentialQuery`
        // can misjudge). `submit()` reads and clears the flag this turn.
        forceClipboardInjection = true
        // This turn is a mechanical light task (translate/summarize/…) — route it to
        // the provider's light model when available (XII-132). Consumed once in
        // `submit()`, so it never leaks into a later typed Ask.
        presetLightTask = true
        submit()
    }

    /// Fire the leading capture chip: file the *copied text itself* straight into
    /// Apple Notes or Reminders, the one-tap path for when you copied a jot rather
    /// than something to ask about. Drops the clip into `text` and routes through the
    /// existing `submitNote()`/`submitReminder()` so the write, the "Added to…" cue,
    /// the Recent row, and (for reminders) `detectedDue` + the recurrence suffix all
    /// come for free — `text.didSet` recomputes the due date from the clip we just
    /// assigned, so the reminder lands at the time the copied line names. No-op if the
    /// clipboard went stale between render and tap.
    func runClipboardCapture(_ panel: Panel) {
        // No-op if the clipboard went stale, or a save is already in flight — the chip
        // vanishes the instant we fire (we clear the verdict below), but the Enter path
        // could re-enter before the async write lands, which would file a duplicate.
        guard let clip = pendingClipboard, !noteSaving else { return }
        // Consume the verdict up front: the chip's whole purpose is this one tap, so it
        // disappears immediately rather than lingering over already-filed text (where a
        // second tap would file a duplicate). The clipboard preview itself stays — the
        // copied text is still a valid Ask referent for the presets beside it.
        manualPanelOverride = nil
        pendingClipboardCapture = nil
        text = clip
        switch panel {
        case .reminder: submitReminder()
        case .note, .chat: submitNote()
        }
    }

    /// The wire copy of the thread for `submit()` (XII-88). Drops, besides the new
    /// round's placeholder, the assistant turns that never became a real answer:
    ///   - an *empty* turn left behind when a follow-up superseded a round before
    ///     its first token (Anthropic 400s on empty assistant content);
    ///   - an *error* turn holding the failure reason the XII-85 card wrote (the
    ///     model would read "Anthropic · HTTP 401" as its own prior reply).
    /// Dropping a turn can leave two user messages adjacent, which Anthropic also
    /// rejects (roles must alternate) — so consecutive same-role messages are
    /// merged. Only this wire copy is filtered; the visible thread keeps every turn.
    private static func wireContext(from turns: [Turn], excluding answerID: UUID)
        -> [ChatMessage]
    {
        var messages: [ChatMessage] = []
        for turn in turns {
            if turn.id == answerID { continue }
            if turn.role == "assistant" {
                let body = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty || turn.isError { continue }
            }
            if let last = messages.last, last.role == turn.role {
                messages[messages.count - 1] = ChatMessage(
                    role: turn.role, content: last.content + "\n\n" + turn.text)
            } else {
                messages.append(ChatMessage(role: turn.role, content: turn.text))
            }
        }
        return messages
    }

    func submit() {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        // Clear any prior error state — this attempt replaces it (XII-85).
        askError = nil
        // One-shot: a preset chip set this so its turn injects the clipboard without
        // having to read as referential. Consume it here regardless of the early
        // returns below, so it can never carry over to a later typed submit.
        let forceClip = forceClipboardInjection
        forceClipboardInjection = false
        // The instruction to send the model in place of the visible bubble text, if a
        // chip set one (Translate). Consumed once here so it never bleeds into a later
        // typed turn. Only honoured on a forced-clip turn, paired with the clipboard.
        let wireOverride = forcedWirePhrase
        forcedWirePhrase = nil
        // One-shot: this turn is a light-task preset (translate/summarize) → route to
        // the provider's light model and skip the tool harness (XII-132). Consumed
        // here so a later typed Ask always uses the main model. Resolve the light
        // service now (main-actor state) so the streaming task can capture it; nil
        // when routing is off / no light tier, and the task falls back to `self.ai`.
        let lightTask = presetLightTask
        presetLightTask = false
        let lightAIService = lightTask ? lightService : nil
        // One-shot regenerate-with-model override (XII-135): build a service pinned
        // to the picked model for THIS turn only, without touching the saved
        // default. Consumed + cleared here. `regenModel` is stamped onto the answer
        // turn below so the result shows which model produced it.
        let overrideModel = regenOverrideModel
        regenOverrideModel = nil
        let overrideService: AIService? = overrideModel.flatMap { m in
            let provider = APIKeyStore.selectedProvider
            guard let key = APIKeyStore.current(for: provider) else { return nil }
            return AppDelegate.makeService(provider: provider, apiKey: key, model: m)
        }
        text = ""
        showHistory = false
        highlightedHistoryIndex = nil

        // A first question starts a fresh thread: give it a new history id so it
        // becomes its own recent row. A follow-up keeps the existing id, so the
        // whole conversation stays one row, updated in place. Captured before the
        // append below empties this out — clipboard injection keys off it too
        // (only a first turn pulls in the clipboard).
        let firstTurn = turns.isEmpty
        if firstTurn { threadHistoryID = UUID() }
        // A brand-new conversation starts unpinned; a follow-up keeps the pin the
        // user set to read the thread (asking on doesn't fold it).
        if firstTurn { isAnswerPinned = false }

        // A follow-up sent while the previous answer is still streaming supersedes
        // it: settle any stale streaming flag now, because the superseded task is
        // cancelled below and will never settle it itself.
        for i in turns.indices where turns[i].streaming { turns[i].streaming = false }

        // Append this question and an empty assistant turn it'll stream into. On a
        // first question `turns` is empty (fresh thread); on a follow-up the prior
        // turns are already here, so the new pair just extends the conversation.
        turns.append(Turn(role: "user", text: q))
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

        // Clipboard-context injection — first turn only. If the user copied text
        // before invoking Notch and then typed a referential query ("summarize
        // this", "translate this"), fold the copied text into THIS user message so
        // the model has the referent. We rewrite the existing user turn's content
        // rather than prepend a fake assistant ack — that keeps the user/assistant
        // alternation valid (Anthropic rejects a leading non-alternating turn) and
        // never persists a ghost turn to the on-screen thread or Recent (the
        // visible `turns` and the saved snapshot still hold the raw `q`). Only the
        // wire copy in `context` carries the clipboard. Skipped on follow-ups: a
        // mid-conversation clipboard change is almost never "about" the new turn.
        // Custom instructions ride the Ask path only (XII-137): a preset
        // (translate/summarize — a `lightTask`) carries its own precise instruction
        // and must not be polluted by "always answer in English"-style preferences.
        let customForTurn = lightTask ? nil : customInstructions
        var system = notchSystemPromptDated(customInstructions: customForTurn)
        // Clipboard injection — first turn only. We no longer gate on a lexical
        // "is this referential?" guess: whenever a clip is eligible we hand the model
        // the FULL copied text and let *it* decide whether the text is relevant to the
        // question (a model judges relevance far better than a keyword list). The
        // framing below makes the clip explicitly optional — "use it only if relevant,
        // otherwise ignore it" — so an incidentally-copied snippet no longer pollutes a
        // self-contained answer.
        //
        // A forced (chip-driven) turn falls back to `pendingClipboard` — the exact text
        // the chip previewed — if a re-read comes back stale (e.g. an in-app copy bumped
        // the baseline between render and tap), so the chip always acts on what it showed.
        let clipForTurn = forceClip ? (clipboardContextIfEligible() ?? pendingClipboard)
                                    : clipboardContextIfEligible()
        if firstTurn, let clip = clipForTurn {
            // The instruction the model acts on: the chip's full wire phrase (e.g. the
            // Translate detect-and-route rule) when one was set, otherwise the visible
            // question. The on-screen bubble keeps `q`; only this wire copy diverges.
            let instruction = wireOverride ?? q
            // A forced/chip turn IS about the clip by construction; a typed turn that
            // reads as referential ("summarize this") almost certainly is too. Those
            // get the imperative framing (act on it) and the 200-word enriched budget.
            // Everything else gets the clip as *optional* background the model may
            // ignore, on the normal budget — copying something then asking an unrelated
            // question shouldn't widen the answer or force the clip in.
            let actsOnClip = forceClip || isReferentialQuery(q)
            if actsOnClip {
                context[context.count - 1] = ChatMessage(
                    role: "user",
                    content: "For context, here is what I have copied:\n\n\(clip)\n\nWith that in mind: \(instruction)")
                // Stamp the on-screen user turn so the result view can show a *permanent*
                // "based on what you copied" trace above it — not a load-only flash. The
                // user turn is the second-to-last entry (the empty assistant placeholder
                // is last). Set before `seedThread = turns` is captured below, so the flag
                // rides into the saved snapshot and survives reopen from Recent.
                if turns.count >= 2 { turns[turns.count - 2].usedClipboard = true }
                // The injected text needs room the 90-word cap can't give. Append the
                // shared enriched-turn marker so the persona allows 200 words AND the
                // client raises the wire `max_tokens` to match (XII-91) — at the default
                // ceiling a long clip + question + 200-word answer was truncated. Single
                // source for the marker string lives in `ReplyTokens`.
                system = notchSystemPromptDated(customInstructions: customForTurn) + ReplyTokens.enrichedMarker
            } else {
                // Optional-context framing: the model gets the full clip but is told to
                // use it only if it's actually relevant to the question, otherwise to
                // answer as if it weren't there. No `usedClipboard` stamp (we don't know
                // the model used it) and no enriched budget.
                context[context.count - 1] = ChatMessage(
                    role: "user",
                    content: "I have the following text on my clipboard — use it only if it's relevant to my question, otherwise ignore it completely:\n\n\(clip)\n\nMy question: \(instruction)")
            }
        }

        // Clipboard IMAGE injection (XII-121). A first turn with a fresh copied
        // image (and no text clip — text always wins the slot) attaches it to the
        // wire message so vision models can see it; the on-screen bubble keeps just
        // the question. The encoded image is also parked on the thread so
        // follow-ups re-attach it — "how do I fix it?" still sees the screenshot
        // the thread started from. Image rounds skip the agent harness below (the
        // tool wire doesn't carry image blocks), taking the plain stream instead.
        var imageAttached = false
        if firstTurn, clipForTurn == nil, let image = clipboardImageIfEligible(),
           let encoded = Self.encodeForVision(image) {
            context[context.count - 1].image = encoded
            threadImage = (threadID: threadHistoryID, image: encoded)
            imageAttached = true
            // Same permanent "based on what you copied" trace the text clip gets.
            if turns.count >= 2 { turns[turns.count - 2].usedClipboard = true }
        } else if !firstTurn, let parked = threadImage, parked.threadID == threadHistoryID,
                  let firstUser = context.firstIndex(where: { $0.role == "user" }) {
            context[firstUser].image = parked.image
            imageAttached = true
        }

        // Fresh thinking word for this answer's pre-stream wait, rotating slowly
        // while we wait so a long search/compose round doesn't freeze on one word.
        startThinkingWordRotation()
        // Light the thinking dots for this round (cleared on the first token or when
        // the round ends) — they ride beside the notch even if the panel folds away.
        thinking = true
        thinkingAnswerID = answerID
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
            self.inFlightRounds.append(
                InFlightRound(answerID: answerID, threadID: threadID, thread: seedThread))
            defer {
                self.roundsInFlight -= 1
                self.inFlightRounds.removeAll { $0.answerID == answerID }
                // A question can't normally outlive its round (cancellation and the
                // timeout both resolve it), but never strand a card on screen — or a
                // parked continuation — if one somehow does.
                for q in self.pendingUserQuestions where q.answerID == answerID {
                    self.resolveUserQuestion(q.id, with: .failure(CancellationError()))
                }
            }
            var thread = seedThread
            // Hoisted out of `do` so the error `catch` can read whatever streamed
            // before the failure — a mid-stream drop that already produced text must
            // persist that partial round, not discard it (see the catch below).
            var acc = ""
            do {
                // One sink for streamed text, shared by the plain and agent paths so
                // the snapshot threading, first-chunk mode-flip, and on-screen guard
                // live in exactly one place. Main-actor (the task inherits it), so it
                // can mutate the task-local `acc`/`thread` and touch UI directly.
                // `[weak self]` mirrors the task; on a detached round `self` is gone
                // and the closure is a no-op.
                let appendChunk: @MainActor (String) -> Void = { [weak self] piece in
                    guard let self else { return }
                    acc += piece
                    if let i = thread.firstIndex(where: { $0.id == answerID }) {
                        thread[i].text = acc
                    }
                    // Keep the reattach mirror current, so an open mid-stream
                    // restores everything written so far, not a stale snapshot.
                    self.syncInFlight(answerID, thread)
                    // First real text for this round ends the thinking phase — clear the
                    // dots even if the panel folded away (the round is detached but still
                    // ours). Idempotent: only the round that owns the flag clears it.
                    self.endThinking(for: answerID)
                    if self.isOnScreen(answerID: answerID) {
                        // First real token ends the pre-stream wait: freeze the
                        // rotating thinking word (the dots/word fade out now anyway).
                        self.stopThinkingWordRotation()
                        // First chunk: flip to the result view so the answer appears
                        // to grow in place out of the thinking state.
                        if self.mode == .load { self.mode = .result }
                        self.updateAnswer(id: answerID, text: acc)
                    }
                }

                // Agent path when the backend can drive tools AND there are tools to
                // offer; otherwise the plain single-shot stream. The harness reads
                // tool calls, runs them, and threads the results back over several
                // turns — but to the UI it's the same growing answer. Any provider
                // that can't do tools, or a turn with an empty registry, falls
                // straight back to the existing behavior: nothing about plain Q&A
                // changes.
                // The standard tool set, plus this round's `ask_user` bridge: the
                // tool's suspension is owned by the model (`awaitUserChoice`), keyed
                // to THIS round's answer turn so the question card renders under the
                // answer it interrupts.
                var agentTools = ToolRegistry.standard(for: APIKeyStore.selectedProvider).tools
                agentTools.append(AskUserTool { [weak self] question, options in
                    guard let self else { throw CancellationError() }
                    return try await self.awaitUserChoice(answerID: answerID,
                                                          question: question,
                                                          options: options)
                })
                let registry = ToolRegistry(agentTools)
                // The service for THIS turn: a one-shot regenerate override (XII-135)
                // wins, else the main service. An upgraded model still gets the tool
                // harness below (search etc.), so the override rides both paths.
                let askService: AIService = overrideService ?? self.ai
                // A light-task turn (translate/summarize preset) takes the plain
                // stream on the light service and skips the tool harness — a
                // mechanical transform never needs web search (XII-132).
                if !lightTask,
                   !imageAttached,
                   let agent = askService as? AgentCapableService,
                   APIKeyStore.selectedProvider.supportsTools,
                   !registry.isEmpty {
                    let harness = AgentHarness(service: agent, registry: registry)
                    let agentMessages = context.map {
                        AgentMessage(kind: .text(role: $0.role, text: $0.content))
                    }
                    try await harness.run(
                        system: system,
                        messages: agentMessages,
                        onText: appendChunk,
                        onActivity: { [weak self] label in
                            guard let self else { return }
                            // The activity line only shows on a still-on-screen
                            // round; a detached harness silently ignores it.
                            if self.isOnScreen(answerID: answerID) {
                                if self.mode == .load { self.mode = .result }
                                self.updateActivity(id: answerID, label: label)
                            }
                        },
                        onSources: { [weak self] roundSources in
                            guard let self else { return }
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
                        })
                } else {
                    // Light-task turns stream from the light service; a regenerate
                    // override (XII-135) streams from its pinned service; everything
                    // else uses the main model.
                    let service = (lightTask ? lightAIService : nil) ?? askService
                    for try await chunk in service.stream(system: system, messages: context) {
                        if Task.isCancelled { return }
                        appendChunk(chunk)
                    }
                }
                if Task.isCancelled { return }
                self.stopThinkingWordRotation()
                self.endThinking(for: answerID)
                if let i = thread.firstIndex(where: { $0.id == answerID }) {
                    thread[i].streaming = false
                }
                // Captured BEFORE persist: whether this round finished detached —
                // the user walked away while it streamed, so the panel folded back
                // to the resting notch (the three dots). When so, fire a native
                // banner so the finished answer doesn't just quietly go out.
                let walkedAway = !self.isOnScreen(answerID: answerID)
                self.markFinished(id: answerID)   // no-op when detached
                self.persistThread(thread, threadID: threadID, answer: acc)
                if walkedAway {
                    self.notifyAnswerReady(threadID: threadID, question: q, answer: acc)
                }
            } catch is CancellationError {
                // superseded by a newer round on the same screen; nothing to persist
            } catch {
                if Task.isCancelled { return }
                self.stopThinkingWordRotation()
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
                    let walkedAway = !self.isOnScreen(answerID: answerID)
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
                    // Failed before any text arrived (refused connection, bad key): no
                    // partial round worth saving. Drop the pending placeholder this
                    // round parked in Recent so the question doesn't linger stuck on
                    // the three dots — whether or not it's still on screen.
                    self.settlePending(threadID)
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
                        self.askError = AskError(message: reason, needsSetup: !self.isConfigured)
                        self.mode = .result
                        // Metadata-only breadcrumb (no prompt/answer/key) — see DiagnosticsLog.
                        DiagnosticsLog.shared.record(
                            provider: APIKeyStore.selectedProvider.displayName,
                            status: Self.httpStatus(from: error),
                            error: error)
                    }
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
        stopThinkingWordRotation()
        thinking = false
        thinkingAnswerID = nil
        setThinkingActivity(nil)
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
        guard askError != nil else { return }
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

    /// The id of the newest settled assistant answer — the argument the keyboard
    /// "save to Notes" action passes to `saveAnswerToNotes` (XII-131). Same
    /// settled/non-empty gate as `lastAnswerText`.
    var lastAnswerID: UUID? {
        guard let last = turns.last, last.role == "assistant", !last.streaming,
              !last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return last.id
    }

    /// Re-run the newest settled answer's question for a fresh take — the answer
    /// footer's regenerate button. Same drop-and-resubmit dance as `retryLastAsk`,
    /// but for a turn that *succeeded*: only ever offered on the last assistant
    /// turn (regenerating mid-thread would orphan everything after it), and gated
    /// on the stream being settled so a tap can't tear down an answer mid-flight.
    func regenerateLastAnswer(model: String? = nil) {
        guard let last = turns.last, last.role == "assistant", !last.streaming else { return }
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
    /// its own content? Sibling to `isReferentialQuery` (which is tuned for ASK
    /// content-ops like summarize/translate) but calibrated for **note-filing**: the
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

    // MARK: - Save answer to Notes (XII-123)

    /// The per-answer cue for the "save to Notes" footer action: which answer
    /// it's about plus the line to show ("Saving…" / "Added to Notes" / error).
    /// Deliberately SEPARATE from `noteSaving`/`lastSavedNote` — those belong to
    /// the input-box capture pipeline, and sharing that single flag across
    /// concurrent writers is exactly the overlap XII-117 flags. One cue at a
    /// time is enough: saving a second answer just moves the cue to it.
    struct AnswerNoteCue: Equatable {
        let answerID: UUID
        let text: String
    }
    @Published var answerNoteCue: AnswerNoteCue? = nil
    private var answerNoteCueTask: Task<Void, Never>? = nil

    /// Save a settled answer into Apple Notes (XII-123): first line = the
    /// thread's generated title (Notes titles a note from its first line),
    /// falling back to the question; body = question + answer, markdown as-is.
    /// Reuses the NotesService write pipeline; feedback renders inline in the
    /// answer's own footer so the thread is never interrupted.
    func saveAnswerToNotes(answerID: UUID) {
        guard let i = turns.firstIndex(where: { $0.id == answerID }),
              turns[i].role == "assistant", !turns[i].streaming else { return }
        let answer = turns[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        let question = turns[..<i].last(where: { $0.role == "user" })?
            .text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = history.first(where: { $0.id == threadHistoryID })?.title ?? question
        var body = title
        if !question.isEmpty, question != title { body += "\n\n" + question }
        body += "\n\n" + answer

        answerNoteCueTask?.cancel()
        answerNoteCue = AnswerNoteCue(answerID: answerID, text: L("input.saving"))
        NotesService.writeNote(body) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.flashAnswerNoteCue(
                    AnswerNoteCue(answerID: answerID, text: L("feedback.addedNotes")))
            case .failure(let err):
                // Errors linger longer — usually "grant Automation access", which
                // takes more than a glance to read.
                self.flashAnswerNoteCue(
                    AnswerNoteCue(answerID: answerID,
                                  text: err.errorDescription ?? L("feedback.notesFailed")),
                    seconds: 5)
            }
        }
    }

    /// Show a terminal save cue for a beat, then fade it — the same rhythm as
    /// `flashSavedCue`, scoped to the answer footer instead of the input box.
    private func flashAnswerNoteCue(_ cue: AnswerNoteCue, seconds: Double = 1.7) {
        answerNoteCueTask?.cancel()
        answerNoteCue = cue
        answerNoteCueTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { self?.answerNoteCue = nil }
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
    /// `link` back to the exact note/reminder so the row jumps there, and an
    /// explicit empty `turns`, so reopening it can never synthesize a ghost answer
    /// bubble — `openHistory` opens the capture in its app instead.
    private func persistCapture(_ line: String, source: HistoryItem.Source, link: String?) {
        var item = HistoryItem(q: line, a: "", t: Date(), turns: [])
        item.source = source
        item.link = link
        history.insert(item, at: 0)
        history = Array(history.prefix(50))
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

    /// Refresh a still-streaming round's reattach mirror with its task's current
    /// snapshot. No-op once the round has settled (its defer removed the entry).
    private func syncInFlight(_ answerID: UUID, _ thread: [Turn]) {
        guard let i = inFlightRounds.firstIndex(where: { $0.answerID == answerID }) else { return }
        inFlightRounds[i].thread = thread
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
    private func updateActivity(id: UUID, label: String?) {
        guard isOnScreen(answerID: id) else { return }
        setThinkingActivity(label)
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
        history = Array(history.prefix(50))
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
        let trimmed = ans.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing worth keeping (a stream that errored before any text): drop the
        // pending placeholder that `submit` parked here, so the question doesn't
        // linger in Recent stuck on the three dots forever.
        guard !trimmed.isEmpty else { settlePending(threadID); return }

        let firstQ = thread.first(where: { $0.role == "user" })?.text ?? ""
        // One history entry per conversation: if this thread already has a row
        // (a follow-up), update it in place instead of inserting a duplicate, so
        // a long chat is a single recent row, not one per turn. Carry over any
        // previously generated title so follow-ups don't wipe it.
        let existingTitle = history.first(where: { $0.id == threadID })?.title
        var item = HistoryItem(id: threadID, q: firstQ, a: trimmed, t: Date(), turns: thread)
        item.title = existingTitle
        if let existing = history.firstIndex(where: { $0.id == threadID }) {
            history.remove(at: existing)
        }
        history.insert(item, at: 0)
        history = Array(history.prefix(50))
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
        let atMilestone = thread.count > 2 && thread.count % 4 == 0
        if existingTitle == nil || atMilestone {
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

        // Route the title to the provider's light model when available (XII-132) —
        // it's a mechanical summary a cheap/fast tier does just as well. Falls back
        // to the main service when routing is off or there's no light tier.
        let service = lightService ?? ai
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
    /// without a live backend. Used by the `NOTCH_DEMO` env path in `AppDelegate`.
    func seedDemo(question: String, answer: String) {
        turns = [
            Turn(role: "user", text: question),
            Turn(role: "assistant", text: answer),
        ]
        mode = .result
    }

    /// Debug-only: seed a pending clipboard (bypassing the freshness/changeCount gate)
    /// so the preset row — and the note/reminder capture chip — can be inspected at
    /// launch without a real copy-then-hover. Runs the same async classification the
    /// live path does. Used by the `NOTCH_DEMO_CLIP` env path in `AppDelegate`.
    func seedDemoClipboard(_ text: String) {
        pendingClipboard = text
        classifyPendingClipboard(text)
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

        showHistory = false
        highlightedHistoryIndex = nil

        // A Note/Reminder capture has no AI answer to reopen — it lives in Apple
        // Notes/Reminders, so tapping the row jumps straight *there*, to the exact
        // note/reminder it created. This is the single choke point for BOTH the
        // click path and the keyboard-Enter path (`historyConfirmHighlighted`
        // calls straight through here), so handling it once here covers both.
        guard item.source == .ask else {
            openCapture(item)
            // Close the panel after launching — the user's attention is moving to
            // Notes/Reminders, so leaving the notch unfurled behind it is noise.
            // Same hard-close Esc/click-outside use.
            fullClose()
            return
        }

        text = ""
        // Restore the whole thread, and adopt this item's id so a follow-up on the
        // reopened conversation updates the same recent row rather than forking a
        // new one. (Legacy single-Q/A items rebuild a two-turn thread.)
        turns = item.conversation
        threadHistoryID = item.id
        mode = .result
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
                // `show` can fail on a stale id (note deleted, or a Core Data id
                // synced from another device) or revoked Automation access — when
                // it does, don't dead-end: fall back to Notes' main window so the
                // tap still lands the user *somewhere*.
                NotesService.showNote(id: id) { [weak self] ok in
                    if !ok { self?.openApp(bundleID: "com.apple.Notes") }
                }
            } else {
                openApp(bundleID: "com.apple.Notes")
            }
        case .reminder:
            if let link = item.link, let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            } else {
                openApp(bundleID: "com.apple.reminders")
            }
        case .ask:
            break   // handled by openHistory; never reached here
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
        openHistory(items[i])
        return true
    }

    /// Enter on an *empty* idle prompt while a capture chip is showing: file the copied
    /// jot straight to Notes/Reminders, the keyboard twin of tapping the leading chip.
    /// Only fires with nothing typed — once there's text, Enter belongs to that line
    /// (routed by intent), so this never steals a real submit. Returns `true` when it
    /// handled the key so the caller stops before the empty `submitCurrent()` no-op.
    func confirmClipboardCaptureIfIdle() -> Bool {
        guard !hasText, let capture = pendingClipboardCapture else { return false }
        runClipboardCapture(capture)
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

    func clearHistory() {
        history = []
        saveHistory()
    }

    /// Drop a single recent item by id (right-click → Delete on its row). Keeps the
    /// keyboard highlight valid: removing a row at/above the highlighted index would
    /// otherwise leave the caret pointing past the end or at the wrong row, so we
    /// recompute it against the shortened visible slice — clamping to the last row,
    /// or releasing the highlight (and folding the list) once it's empty.
    func deleteHistory(id: UUID) {
        guard let removedVisibleIndex = recentVisible.firstIndex(where: { $0.id == id }) else { return }
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

    private func loadHistory() -> [HistoryItem] {
        guard let data = UserDefaults.standard.data(forKey: historyKey) else { return [] }
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

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    // MARK: - Open width per state (matches the prototype's s-* widths)

    var openWidth: CGFloat {
        // Settings needs a touch more room for the provider/model rows; it only
        // ever shows over the idle view, so it wins regardless of `mode`.
        if showSettings { return Tokens.openWidthSettings }
        // What's New is a reading surface — give it the same comfortable column
        // as the result view. Also shows only over idle, so it wins like settings.
        if showWhatsNew { return Tokens.openWidthWhatsNew }
        // The guided first run is a two-column layout (left controls + right demo
        // pane), so it gets its own wider width. Shows only over idle.
        if showOnboarding { return Tokens.openWidthOnboarding }
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
