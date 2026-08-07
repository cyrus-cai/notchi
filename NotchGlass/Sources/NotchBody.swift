import SwiftUI
import AppKit

/// The content that lives inside the glass, below the constant black notch zone.
/// Switches between idle / load / result exactly like the prototype's modes.
struct NotchBody: View {
    @ObservedObject var model: NotchModel
    /// The conversation store, observed SEPARATELY from the model: `turns` no
    /// longer publishes through `model.objectWillChange` (see `ConversationStore`),
    /// so this wrapper is what re-evaluates this body as an answer streams in.
    /// Reads stay `model.turns` — the model forwards to the same store.
    @ObservedObject private var conversation: ConversationStore
    /// Self-update state — read here only to badge the settings gear with a dot
    /// when a newer release is available (the action itself lives in settings).
    @ObservedObject private var updater = UpdaterService.shared
    /// Release-notes state — read here to surface the "what's new" cue in the idle
    /// input row once, on the first launch after an update (see `unseenVersion`).
    @ObservedObject private var whatsNew = WhatsNewService.shared
    /// The agent-Codex run (XII: agent-to-Codex) — observed so the idle
    /// view's task card tracks progress live and flips to the result on finish.
    @ObservedObject private var agentManager = AgentTaskManager.shared
    /// The model catalog behind the ⌘⇧I picker — the same store Settings' chip reads,
    /// so a list fetched on one surface is already warm on the other.
    @ObservedObject private var catalog = ModelCatalogStore.shared
    /// Two-step cancel for an agent status row: the ✕ arms this with its task's
    /// id, and only the armed "cancel?" chip actually terminates that run.
    /// Auto-disarms after a beat. One slot on purpose — arming a second row
    /// relaxes the first.
    @State private var confirmingAgentCancelID: UUID? = nil
    /// Which agent status row the pointer is over. The row's trailing slot rests
    /// as an elapsed clock and only becomes the ✕ under the pointer, so a list of
    /// runs reads as durations at a glance and never as a row of close buttons.
    @State private var hoveredAgentRowID: UUID? = nil
    /// Which attached-image thumbnail the pointer is over. Each thumbnail's ×
    /// removal badge only appears while its own thumbnail is hovered, so the
    /// strip rests as clean previews instead of a row of close buttons.
    @State private var hoveredComposeImageIndex: Int? = nil
    /// Where the agent model+effort card hangs from: half the chip's width, i.e.
    /// the point under its centre — **frozen for as long as the card is up**.
    /// The chip re-titles live while you pick ("Opus 5 medium" → "Sonnet 5
    /// high"), so its width moves underneath; the card must not slide with it.
    /// The chips row is leading-packed, so the chip's leading edge stays put and
    /// a held offset from it is a genuinely static anchor. Nil = not measured
    /// yet (the card can be armed by ⌘⇧I before the chip ever mounts).
    @State private var agentChipAnchorX: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the custom field's first-responder. Set shortly after the panel
    /// opens so the caret lands without a click (the AppDelegate has just made
    /// the panel key; a tiny delay lets that settle first).
    @State private var focused = false
    /// Natural (intrinsic) height of the answer text, reported by a preference
    /// reader. Used ONLY to decide whether the thread has outgrown `answerMaxHeight`
    /// and must switch to the clipped+scrolling layout — it does NOT drive the
    /// height of the un-clipped layout. (It used to: the scroll frame tracked this
    /// measured value, and since the measurement lags the content by a layout pass,
    /// every streamed line nudged the frame a beat late and the spring on it
    /// overshot — the per-line "jump". Now a short answer just sizes to its own
    /// content with no measure→frame feedback loop, so it grows smoothly in the same
    /// frame the text lands.)
    @State private var measuredAnswerHeight: CGFloat = 0
    /// Width (pt) of everything the prompt field is currently showing — committed
    /// text plus any in-progress IME composition (pinyin) — reported live by the
    /// field via `onCaretWidth`. It's how the placeholder knows to get out of the
    /// way the moment the editor shows anything, including pinyin that hasn't
    /// committed to `model.text` yet (which lags a whole composition behind).
    @State private var caretWidth: CGFloat = 0
    /// Same live display width, but for the follow-up field. Its placeholder is a
    /// SwiftUI overlay (so the copy can cross-fade — see `followUpPlaceholderLabel`),
    /// and this is how the overlay knows to vanish the moment the editor shows
    /// anything — including pinyin that hasn't committed to `model.text` yet, which
    /// is exactly when the native placeholder would disappear.
    @State private var followUpCaretWidth: CGFloat = 0
    /// The height the prompt box is asking for: one line at rest, growing with the
    /// wrapped text up to `NotchBody.promptMaxLines`, after which it scrolls inside
    /// itself. The input rows size themselves off these.
    @State private var inputHeight: CGFloat = PromptField.lineHeight(for: NotchBody.idleFontSize)
    /// Cursor over the bucket row's "what's new" chip — brightens its glass, in the
    /// same step the Recent chevron beside it takes (see `whatsNewCue`).
    @State private var whatsNewHovered = false
    /// Cursor over an "Update to X" chip — one per host (the idle prompt's bucket
    /// row, the recent list's manage bar); they're never on screen together, but
    /// separate flags keep the hover honest either way (see `updateCue`).
    @State private var updateCueIdleHovered = false
    @State private var updateCueBarHovered = false
    @State private var followUpHeight: CGFloat = PromptField.lineHeight(for: NotchBody.followUpFontSize)
    /// A thread opened by a prompt shortcut keeps its follow-up input folded into a
    /// small floating button (see `followUpButton`) until this flips — the run is a
    /// one-shot on a selection, so an always-open composer would cost a row of
    /// height nobody asked for. Reset whenever the thread changes underneath it.
    @State private var followUpExpanded = false
    /// The live agent-detail page's own follow-up line — kept separate from the
    /// idle prompt's `model.text` so a line typed while watching a run doesn't
    /// leak into the fresh-chat box the page falls back to when the task ends.
    /// Enter queues it as the run's next instruction (`AgentTaskManager.followUp`),
    /// exactly like the detached agent window's field; the box stays put after
    /// send so more can be lined up.
    @State private var agentDetailFollowUp: String = ""
    @State private var agentDetailFollowUpCaretWidth: CGFloat = 0
    @State private var agentDetailFollowUpHeight: CGFloat = PromptField.lineHeight(for: NotchBody.followUpFontSize)
    /// Small directional slide-in for the idle prompt as ↑/↓ recall swaps a past
    /// question in: set to a nonzero offset (with the step's direction) the instant
    /// a recall fires, then animated back to rest. See `model.recallPulse`.
    @State private var recallSlide: CGFloat = 0
    /// Drives the compact history filter field's first-responder. Set when the
    /// filter icon is tapped so the caret lands in the expanded field without a
    /// second click; reset when the filter collapses so it can re-arm next time.
    @State private var filterFocused = false
    /// Measured height of the immersive floating header (input, plus the copied-
    /// image preview when one is pending). The list's top
    /// runway and frost band are derived from this so the first row always rests
    /// clear of the header no matter how tall it gets — a plain input is short, a
    /// header with a preview is taller. Seeded to the plain-input baseline so the
    /// first frame (before the preference lands) already clears a bare-input header.
    @State private var measuredImmersiveHeaderHeight: CGFloat = NotchBody.immersiveHeaderBaseline
    /// Whether the immersive header height has been measured at least once this open.
    /// The FIRST measurement (baseline → real height) must land silently — animating
    /// it forces a second, animated layout pass before the expand can even start,
    /// which read as a ~0.5s stall before the list moved. Only LATER changes (a preview
    /// appearing/clearing while open) animate, so those still slide. Reset on close.
    @State private var didMeasureImmersiveHeader = false
    /// Which answer's source badge is currently open (hovered), shared between the
    /// badge in the scroll and the floating panel rendered by `resultView` so the
    /// popup escapes the scroll's clip (XII-118). `nil` = none open.
    @State private var hoveredSourceID: UUID? = nil
    /// Deferred-close handle for the source popup, so leaving the pill doesn't snap
    /// it shut before the cursor can cross the gap to the panel. Cancelled when the
    /// cursor reaches the panel (or re-enters the pill).
    @State private var sourceCloseWork: DispatchWorkItem? = nil
    /// Whether the manage bar's secondary controls (Settings + Clear) are revealed.
    /// The first level is a single ⋯ chip; tapping it unfurls the two actions to its
    /// right. Local presentational state — collapses on selection or a second tap.
    @State private var manageExpanded = false

    /// Seed `measuredAnswerHeight` from the model's parked measurement, so a
    /// hover-reopen into a long answer mounts DIRECTLY in the clipped layout.
    /// NotchBody unmounts on every close (`if isOpen` in ContentView), resetting
    /// all @State — without the seed the thread re-mounted unclipped at full
    /// intrinsic height and flipped to the clipped scroller one preference pass
    /// later, mid-open-spring: a structural swap (new ScrollView, header →
    /// overlay, follow-up → float, scroll snapped to bottom) stacked on top of
    /// the unfurl, which is what made reopening an answer visibly rougher than
    /// opening the idle prompt. Seeded, the first frame is already the final
    /// layout and the open rides one clean spring — same as idle. The model zeros
    /// the seed on every close after parking it, so a non-restore open (fresh
    /// idle, settings, another thread) still mounts "unmeasured" as before.
    init(model: NotchModel) {
        self.model = model
        _conversation = ObservedObject(wrappedValue: model.conversation)
        _measuredAnswerHeight = State(initialValue: model.lastMeasuredAnswerHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.mode {
            case .result:
                resultView
            case .load:
                // A follow-up already has the thread on screen — keep showing the
                // conversation (its last bubble renders the thinking dots) so the
                // prior turns don't vanish while the answer is in flight. Only the
                // very first question, with nothing on screen yet, gets the bare
                // centered load view.
                if model.turns.isEmpty {
                    loadView
                } else {
                    resultView
                }
            case .idle:
                // An open agent detail page owns the idle slot: the run's full
                // work trail, live while it works. Falls back to the idle panel
                // by itself once the task is dismissed (the lookup fails).
                if let task = agentDetailTask {
                    agentDetailView(task)
                } else {
                    idleView
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 15)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The cross-provider model chooser — opened by the Ask bucket's model chip
        // (`askModelChip`), the settings chip, and ⌘⇧I's fallback when no agent CLI is
        // installed. It hangs under the panel body rather than off the chip so all three
        // front doors land it right below the island, where the eye already is.
        //
        // The rows are built only while the menu is actually up: `rows` walks every
        // provider (each one's `ready` check, then the whole catalog's fold and sort),
        // and this modifier sits on the panel body — so an unfurl used to pay for a
        // menu nobody asked for. The body re-runs when `showModelPicker` flips, which
        // is before the presenter reads them.
        .modelMenu(isPresented: $model.showModelPicker,
                   models: model.showModelPicker ? catalog.rows(selected: selectedProvider) : [],
                   selectedProvider: selectedProvider,
                   selectedID: selectedModelID,
                   centered: true,
                   onSelect: { prov, id in
                       ModelCatalogStore.select(provider: prov, model: id)
                   },
                   onConfigure: { m in
                       // "Add key" on a keyless model: the menu can't take a key, so
                       // hand the pick to Settings — it opens on that provider's key
                       // row and commits the model the moment the key lands. The active
                       // backend stays untouched until then.
                       model.pendingModelSetup = .init(provider: m.provider, id: m.info.id)
                       withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                           model.openSettings()
                       }
                   })
        .onChange(of: model.showModelPicker) { _, open in
            // A menu is a snapshot of the catalog it was built from — refresh the live
            // models on open so the *next* one is current (the bundled list shows now).
            if open { Task { await catalog.loadAll() } }
            // The menu is its own window, outside the island's tracking area —
            // suspend the leave-collapse while it's up, exactly as the settings
            // picker does, or moving the pointer into the card folds the panel away.
            model.isModelPickerOpen = open
        }
        // The agent's model+effort picker (⌘⇧I / the compose chip tap) hangs off
        // the model chip itself — see `agentComposeChips` — not the body, so it
        // pops from the control that opened it exactly like the Ask chip's menu.
        .onChange(of: model.showAgentPicker) { _, open in
            model.isModelPickerOpen = open
        }
        .onChange(of: model.showAskModelPicker) { _, open in
            model.isModelPickerOpen = open
        }
        .onChange(of: model.showAgentFolderPicker) { _, open in
            model.isModelPickerOpen = open
        }
        .onChange(of: model.open) { _, isOpen in
            if isOpen {
                refocusInput()
            } else {
                focused = false
            }
        }
        // Returning to the idle prompt (← / back button / Enter-submit-then-finish)
        // tears down the result/follow-up field and builds a fresh idle PromptField,
        // which has never held focus — so its ↓/↑ history-nav keys went dead. Re-arm
        // the focus latch on every switch *into* idle while open, so the caret (and
        // the keyboard history nav that rides on it) always lands back in the prompt.
        .onChange(of: model.mode) { _, newMode in
            if model.open, newMode == .idle {
                refocusInput()
            }
        }
        // Collapsing the recent list returns the caret to the prompt. Without this, a
        // user who clicked into the new HistorySearchField (taking first-responder off
        // the prompt) and then pressed Esc to fold the list would be left in focus
        // limbo on the now-removed filter field — unable to type until they click.
        .onChange(of: model.showHistory) { _, isShowing in
            if model.open, !isShowing, model.mode == .idle {
                refocusInput()
            }
            // Closing the list tears down the immersive layout, so re-arm the
            // "first measurement lands silently" latch for the next open — otherwise
            // the next open's baseline→real jump would animate (and stall) again.
            if !isShowing { didMeasureImmersiveHeader = false }
        }
        // When the answer grows past `answerMaxHeight` and the clipped layout mounts,
        // followUpRow moves from a VStack sibling to a ZStack child in a new structural
        // position — SwiftUI recreates the NSTextField underneath, and the `focused`
        // Bool has no false→true edge to re-grab first-responder. refocusInput() drops
        // then re-raises `focused` next runloop, so the follow-up caret survives the
        // crossover without a click. Only the false→true edge of `isAnswerClipped`
        // matters (the moment the answer first crosses the ceiling this session).
        .onChange(of: isAnswerClipped) { _, nowClipped in
            if nowClipped, model.open {
                refocusInput()
            }
        }
        // Leaving a thread (← / ⌘N new-chat, tearing it off into a window) empties
        // `turns` while the panel — and this view — stay mounted, so neither init's
        // seed nor the measurement probe runs again: the OLD thread's measurement
        // would survive into the next one. If that thread was long (>300), a fresh
        // short question mounts straight into the full-height clipped scroller and
        // — because the probe deliberately stays down while streaming — holds full
        // height for the entire answer. Zero the measurement (and its model mirror,
        // which seeds the next mount) the moment the thread leaves the screen, so
        // every new chat starts unclipped and sizes to its content. Close is
        // unaffected: `fullClose` parks the measurement before it empties `turns`.
        .onChange(of: model.turns.isEmpty) { _, isEmpty in
            if isEmpty {
                measuredAnswerHeight = 0
                model.lastMeasuredAnswerHeight = 0
                // A thread leaving the screen re-folds the shortcut follow-up, so the
                // next shortcut run opens on its button rather than an unfolded field
                // it inherited from the previous answer.
                followUpExpanded = false
            }
        }
        // A fresh prompt-shortcut run (hotkey pressed again while the panel is up)
        // re-folds too — same reason, without waiting for `turns` to empty.
        .onChange(of: model.fromPromptShortcut) { _, isShortcut in
            if isShortcut { followUpExpanded = false }
        }
        .onAppear {
            if model.open {
                refocusInput()
            }
        }
    }

    /// The provider and model in effect — what the ⌘⇧I picker opens on. Read straight
    /// from the store rather than mirrored into state: a pick closes the popover, so the
    /// body re-reads on the next summon and can never show a stale selection.
    private var selectedProvider: Provider { APIKeyStore.selectedProvider }

    /// The wire id in effect, with the sentinels resolved (an empty override, or a CLI
    /// backend's legacy "codex" / "grok" / "claude", all mean "this provider's
    /// default") — mirrors the settings chip.
    private var selectedModelID: String {
        let p = selectedProvider
        let id = APIKeyStore.storedModel(for: p)
        if p == .codex, id.isEmpty || id == "codex" { return p.defaultModel }
        if p == .grokCode, id.isEmpty || id == "grok" { return p.defaultModel }
        if p == .claudeCode, id.isEmpty || id == "claude" { return p.defaultModel }
        if p == .commandCode, id.isEmpty || id == CommandCodeCLIService.defaultSentinel {
            return p.defaultModel
        }
        return id.isEmpty ? p.defaultModel : id
    }

    /// Re-arm the PromptField's first-responder latch. `focusTrigger` only fires on
    /// a false→true edge, so when `focused` is already true (e.g. coming back to
    /// idle without the panel ever closing) we must drop it first, then raise it
    /// next runloop — otherwise there's no edge and the new field never grabs focus.
    /// The small delay also lets SwiftUI finish swapping the field in.
    private func refocusInput() {
        focused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { focused = true }
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.showSettings {
                // Settings owns the whole body when open — the "Ask anything" prompt is
                // hidden, since you're configuring the app, not asking a question. Its
                // own "‹ SETTINGS" header carries the way back (gear / Esc / chevron).
                InlineSettingsView(model: model)
                    .transition(moduleTransition)
            } else if model.showWhatsNew {
                // What's New owns the whole body, like settings — the idle prompt is
                // hidden while the user reads the release notes. Its own back chevron
                // (and Esc) carries the way home.
                WhatsNewView(model: model)
                    .transition(moduleTransition)
            } else if useImmersiveHistory {
                // Immersive recent list: the input floats as a translucent header
                // over a tall scroll surface that reaches UP behind it. Rows scroll
                // under the input and frost + fade out — present but pushed back —
                // so the panel reads as one continuous surface, not a stack of
                // blocks. Only taken once the list overflows (`useImmersiveHistory`);
                // a short list keeps the calm compact layout below.
                immersiveHistoryView
            } else {
                // While ↑/↓ recall is walking the history, the slot above the input
                // shows a "which of how many" counter instead of the copied-image
                // preview — the preview is irrelevant to a recalled question, and the
                // counter tells you how far back you've stepped. An active agent
                // compose repurposes the slot: the ambient clipboard preview is
                // suppressed (its context chips live *below* the input), but an image
                // the user explicitly ⌘V-pasted into the task shows here — that's
                // part of the task being written, not noise over it.
                if !model.agentComposeActive {
                    if let recall = model.recallPosition {
                        recallCounterLine(recall)
                            .transition(moduleTransition)
                    } else if !model.askComposeImages.isEmpty {
                        composeImagesAttachedLine(model.askComposeImages) {
                            model.removeAskComposeImage(at: $0)
                        }
                        .padding(.bottom, 8)
                        .transition(moduleTransition)
                    }
                } else if !model.agentComposeImages.isEmpty {
                    composeImagesAttachedLine(model.agentComposeImages) {
                        model.removeAgentComposeImage(at: $0)
                    }
                    .padding(.bottom, 8)
                    .transition(moduleTransition)
                }

                idleInputRow

                // (The `/` command menu is NOT in this stack — it lives in its own
                // borderless window, hung under the input by `SlashMenuHost`. It
                // takes no space here, moves nothing, and is free to overhang the
                // island's edge.)

                // The bucket row (XII: agent-to-Codex): the destination pill as
                // fixed chrome below the input, with the folder / model / effort
                // chips unfurling beside it while Agent is armed — same slot and
                // glass language as the one-tap presets. It rides the panel even
                // with no agent CLI installed: the pill is now where the routing
                // (Ask / Note / Remind) shows itself, so it can't be optional.
                // (Both the pill and the Recent chevron leave the row while
                // Recent is expanded — the chevron moves to the manage bar's
                // bottom-right — so the row itself drops out when nothing is left.)
                if bucketRowHasContent {
                    bucketRow
                        .transition(moduleTransition)
                }

                // Agent runs' presence (XII: agent-to-Codex): one status line per
                // task — the live activity while it works, the outcome once it
                // settles. These live ONLY inside the opened Recent list (they ride
                // the TOP of `historyList`), never as a standalone strip in this
                // resting compact view — tap the Recent chevron to see them. While a
                // run is live the chevron carries the "N running" count as the sole
                // resting cue; the rows themselves stay behind that disclosure.

                // The recent list expands below the prompt once the clock is tapped.
                // (The immersive variant above handles the overflowing case.)
                if !model.hasText && recentHasContent && model.showHistory {
                    historySection
                        .padding(.top, 12)
                        .transition(moduleTransition)
                }

                // The note-save feedback line (Saving… / Added to Notes / error).
                // Only present when there's something to say — when there's nothing it
                // takes ZERO height, so the resting prompt is just the 48pt input. A
                // line classified as a note routes to Apple Notes without changing the
                // surface, and this quiet cue is the only sign it landed there.
                if let feedback = noteFeedbackContent {
                    feedback
                        .padding(.top, 8)
                        .transition(moduleTransition)
                }
            }
        }
        // The note-save feedback unfurls/fades on the panel's standard module spring,
        // matching the recent list right above it.
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.noteSaving)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.lastSavedNote)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.noteError)
        // Typing folds the recent list from `text.didSet` (showHistory = false) —
        // a model-side write with NO withAnimation around it, so without these keys
        // the fold (and the immersive⇄flat layout swap that rides on hasText /
        // showHistory) was a hard pop instead of the module spring every *other*
        // open/close path plays. Same spring as those withAnimation call sites.
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.showHistory)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.hasText)
    }

    /// The idle prompt field, with the live note-error reset wired in. Shared by
    /// the flat idle layout and the immersive history header so the field — and
    /// all its focus/IME plumbing — exists exactly once, never duplicated.
    /// An armed agent folder swaps the placeholder: the same field is now
    /// composing Codex's task, and the ghost text should say so. A mode pinned by
    /// `/` swaps it the same way ("Write a note…"), since an empty field has no
    /// glyphs for the inline ghost to trail — see `idlePlaceholderKey`.
    private var idleInputRow: some View {
        inputRow(placeholder: L(model.idlePlaceholderKey), followUp: false)
            .onChange(of: model.text) { _, _ in
                // Editing the field clears a stale note-save error so the cue
                // doesn't linger over a line the user is actively rewriting.
                if model.noteError != nil { model.noteError = nil }
            }
            // The idle page has no header, so the input row's free strip is its
            // tear-off grip — see `detachGrip`.
            .background(detachGrip)
    }

    /// The idle page's tear-off grip: a transparent sheet laid BEHIND the row,
    /// so dragging its free strip pulls the prompt out into its own composer
    /// window (`DetachedSession.compose`) while everything drawn on top keeps
    /// its own mouse. That layering is the point — a grip wrapped *around* the
    /// row would be an ancestor of the prompt field, and dragging to select text
    /// would tear the panel off the bezel. Behind it, the field (and every chip)
    /// hit-tests first and the grip only ever sees the empty space beside them.
    ///
    /// That invisibility is also why it carries `grabCursor()`: the hand is the
    /// only thing telling you the strip is grabbable at all.
    private var detachGrip: some View {
        Color.clear
            .contentShape(Rectangle())
            .grabCursor()
            .gesture(detachDragGesture)
    }

    /// Take the immersive (input-floats-over-scroll) layout only when the recent
    /// list is both open and long enough to scroll. A short list that fits has
    /// nothing to flow under the input, so it keeps the calm compact layout —
    /// matching the same `> 6` overflow calibration the list itself uses.
    ///
    /// A pending copied-image preview doesn't force the compact fallback: it rides
    /// inside the immersive floating header above the input, and the runway grows to
    /// clear that taller header — so the frosted immersive surface stays consistent
    /// whether or not a preview is present.
    private var useImmersiveHistory: Bool {
        !model.hasText
            && model.showHistory
            && noteFeedbackContent == nil
            && model.recentVisible.count > 6
    }

    /// Whether the Recent area has anything to disclose — past history, or the live
    /// agent tasks that ride the top of that same list. A running task with no prior
    /// history still gives the chevron something to open (its own status row), so the
    /// "N running" disclosure is never a dead button.
    private var recentHasContent: Bool {
        !model.history.isEmpty || !agentManager.tasks.isEmpty
    }

    /// True while the Recent list is on screen (flat `historySection` or its
    /// immersive variant). The Ask|Agent bucket pill hides in this state — an
    /// expanded Recent view shouldn't also carry the compose-family switch.
    private var recentListShown: Bool {
        !model.hasText && recentHasContent && model.showHistory
    }

    // MARK: - Immersive history

    /// The immersive recent layout: a tall scroll surface with the prompt floating
    /// over its top as a translucent header. The list's content reaches up behind
    /// the header (`immersiveTopReach`), so rows scroll under the input and frost +
    /// fade out rather than ending on a hard cut — the panel reads as one
    /// continuous surface. The manage bar (the ⋯ chip at bottom-left, the Recent
    /// chevron at bottom-right) FLOATS across the bottom as fixed chrome: the list
    /// runs full-height *behind* it, so rows can scroll down past the buttons and
    /// stay partly visible through/around the glass.
    private var immersiveHistoryView: some View {
        ZStack(alignment: .top) {
            historyList(immersive: true)
        }
            .overlay(alignment: .top) {
                // Front: the floating header — NO background of its own. The glass
                // shell must read identically whether the panel is collapsed or
                // expanded, so the prompt sits directly on the same translucent
                // material as the resting state. Legibility of the rows passing
                // behind comes entirely from the list's own top fade + blur (see
                // `historyList(immersive:)`).
                VStack(alignment: .leading, spacing: 0) {
                    // A pending copied-image preview rides INSIDE the floating
                    // header, above the prompt. The runway (`immersiveTopReach`,
                    // measured from this header's real height) grows to keep the
                    // first row clear. Same slot swap as the flat layout: an
                    // active agent compose shows its pasted attachment instead.
                    if model.agentComposeActive {
                        if !model.agentComposeImages.isEmpty {
                            composeImagesAttachedLine(model.agentComposeImages) {
                                model.removeAgentComposeImage(at: $0)
                            }
                            .padding(.bottom, 8)
                        }
                    } else if !model.askComposeImages.isEmpty {
                        composeImagesAttachedLine(model.askComposeImages) {
                            model.removeAskComposeImage(at: $0)
                        }
                        .padding(.bottom, 8)
                    }
                    idleInputRow
                    // The bucket row rides the immersive header too — but only while
                    // it still carries something (an active compose). The destination
                    // pill and the Recent chevron both leave it once the list is up,
                    // and an empty row would just pad the header.
                    if bucketRowHasContent {
                        bucketRow
                    }
                    // Agent status rows do NOT ride the header — they scroll with the
                    // recent list as its newest rows (see `historyList(immersive:)`),
                    // so a running task isn't pinned over the top of the scroll.
                }
                .padding(.bottom, 6)
                // Measure the header's real height so runway/frost track it.
                // A header with a preview is taller than a bare input; the preference feeds
                // measuredImmersiveHeaderHeight so immersiveTopReach adapts.
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ImmersiveHeaderHeightKey.self, value: geo.size.height
                        )
                    }
                )
            }
            .onPreferenceChange(ImmersiveHeaderHeightKey.self) { h in
                let measured = max(h, NotchBody.immersiveHeaderBaseline)
                if didMeasureImmersiveHeader {
                    // A later change (preview appearing/clearing) slides the runway
                    // so the list shifts smoothly rather than snapping.
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                        measuredImmersiveHeaderHeight = measured
                    }
                } else {
                    // First measurement of this open: land it silently. Animating
                    // here forces an animated second layout pass that stalls the
                    // expand start.
                    didMeasureImmersiveHeader = true
                    measuredImmersiveHeaderHeight = measured
                }
            }
            // Fixed bottom chrome: the ⋯ chip and the Recent chevron, FLOATING over the
            // bottom corners of the full-height list. Because it's an overlay (not a sibling), the list runs
            // its whole height behind it — rows scroll down past the buttons and stay
            // partly visible through/around the translucent glass capsules. The glass
            // material gives the buttons enough body to stay legible over moving rows.
            .overlay(alignment: .bottom) {
                // Pull the bar tighter into the bottom corners than the body's
                // 20pt horizontal / 22pt bottom insets would leave it: negative
                // padding tucks it ~10pt closer on each edge — the same 10 left and
                // right, so the ⋯ and the Recent chevron end up equidistant from
                // their own panel edge — still clear of the 30pt NotchShape corner
                // arc at the bar's height.
                manageBar
                    .padding(.horizontal, -10)
                    .padding(.bottom, -8)
            }
            .transition(moduleTransition)
    }

    // MARK: - Note save feedback

    /// The line under the input after a note save — `nil` when there's nothing to
    /// report, so the row simply doesn't exist (zero height) and the resting prompt
    /// is just the input.
    ///
    /// Deliberately quiet: no icons, no colour, no echo of what was typed — just one
    /// small line in the same `text4` grey as RECENT and the timestamps, so a save
    /// confirms without ever shouting. The success path settles to "Added to Notes";
    /// "Saving…" reads the same grey while the write is in flight. The error path is
    /// the one exception — it's actionable (usually "grant permission"), so it gets
    /// a touch more presence (text2, still no loud icon/colour) to make sure it's
    /// seen, since silently failing to save would be worse than a quiet cue.
    private var noteFeedbackContent: AnyView? {
        if let err = model.noteError {
            return AnyView(
                Text(err)
                    .font(.sf(12))
                    .foregroundStyle(Tokens.text2)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            )
        }
        // Both save paths now store their full display string (e.g.
        // "Added to Reminders · Daily" / "Added to Notes") in lastSavedNote,
        // so the cue text is whatever the model put there — no binary rebuild here.
        if let cue = model.lastSavedNote {
            return AnyView(feedbackLine(cue))
        }
        if model.noteSaving {
            return AnyView(feedbackLine(L("input.saving")))
        }
        return nil
    }

    /// One line of the calm note-save feedback: small, `text4` grey, no icon —
    /// the same whisper as the RECENT label.
    private func feedbackLine(_ text: String) -> some View {
        Text(text)
            .font(.sf(12))
            .tracking(0.2)
            .foregroundStyle(Tokens.text4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// How many thumbnails the attached strip shows before folding the rest into
    /// a "+N" chip. The real cap is `NotchModel.agentImageLimit` (20) — far more
    /// than fits across a 540pt panel, so the strip shows the first few and the
    /// "+N" chip carries the rest.
    private static let agentThumbStripMax = 6

    /// The agent compose's attached images: a strip of thumbnails in the same
    /// language as the copied-image preview above, each with its own × — unlike
    /// the ambient clipboard preview (which self-refreshes), these were explicit
    /// ⌘Vs and need an explicit way back out, one at a time. The run hands exactly
    /// these images to the agent. Shared with the settled card's follow-up field,
    /// which clears its own attachments — hence the injected remove action.
    private func composeImagesAttachedLine(_ images: [NSImage],
                                           onRemove: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(images.prefix(Self.agentThumbStripMax).enumerated()),
                    id: \.offset) { index, image in
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 34, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .overlay(alignment: .topTrailing) {
                        Button { onRemove(index) } label: {
                            Image(systemName: "xmark")
                                .font(.sf(8, weight: .bold))
                                .foregroundStyle(Tokens.text1)
                                .frame(width: 15, height: 15)
                                .background(Circle().fill(Color.black.opacity(0.66)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        // Rest as a clean preview; the × only appears while the
                        // pointer is over this thumbnail.
                        .opacity(hoveredComposeImageIndex == index ? 1 : 0)
                        .allowsHitTesting(hoveredComposeImageIndex == index)
                    }
                    .onHover { inside in
                        withAnimation(.easeOut(duration: 0.12)) {
                            hoveredComposeImageIndex = inside ? index : (hoveredComposeImageIndex == index ? nil : hoveredComposeImageIndex)
                        }
                    }
            }
            if images.count > Self.agentThumbStripMax {
                Text("+\(images.count - Self.agentThumbStripMax)")
                    .font(.sf(10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Tokens.text4)
                    .frame(width: 26, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )
            }
        }
        // The × badges overhang their thumbnails — give the row the 4pt back.
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The ↑/↓ recall counter shown above the input while walking history: a small
    /// clock glyph + "pos / total" (newest = 1), so you can see
    /// how far back the current recalled question sits.
    private func recallCounterLine(_ recall: (pos: Int, total: Int)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.sf(10, weight: .semibold))
                .foregroundStyle(Tokens.text4)
                .baselineOffset(-1)
            Text("\(recall.pos) / \(recall.total)")
                .font(.sf(11, weight: .medium))
                .monospacedDigit()
                .tracking(0.3)
                .foregroundStyle(Tokens.text4)
                .lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }

    // MARK: - Agent to Codex (XII: agent-to-Codex)

    /// An engine's real brand mark, tinted like the surrounding text — the vendors'
    /// own glyphs, never an SF-symbol stand-in. Shared with the ⌘⇧I agent picker
    /// (`AgentEngineMark`), which lists the same engines' models.
    private func agentEngineMark(_ engine: AgentEngine, size: CGFloat,
                                    tint: Color) -> some View {
        AgentEngineMark(engine: engine, size: size, tint: tint)
    }

    /// The bucket row under the idle prompt — fixed chrome once a local agent
    /// CLI is installed: the Ask|Agent pill, and (while Agent is armed) the
    /// compose chips unfurled beside it. The pill is the panel's one explicit
    /// top-level choice; everything the classifier does (note/remind routing)
    /// happens invisibly inside its Ask half.
    private var bucketRow: some View {
        HStack(spacing: 6) {
            // The Ask|Agent switch drops out while the Recent list is expanded —
            // the compose-family pill shouldn't crowd the recall view.
            // The Ask|Agent switch — and the compose chips that unfurl beside it —
            // drop out while the Recent list is expanded: the recall view shouldn't
            // also carry the compose-family chrome.
            if !recentListShown {
                BucketTogglePill(model: model)
                if model.agentComposeActive {
                    agentComposeChips
                        .transition(.opacity)
                } else {
                    askModelChip
                        .transition(.opacity)
                }
            }
            // The Recent (+ pin) cluster rides this row's trailing edge — on the
            // same line as the Ask|Agent pill, pushed right by the spacer — instead
            // of hovering a row up in the input's trailing slot. The bare Recent
            // chevron / pin hide while typing (the input's inline send hint owns that
            // slot then), but a live "N running ⌄" count stays put — a background
            // agent's progress shouldn't vanish the moment you start a new prompt.
            // Handed over to the manage bar's trailing edge once Recent is up (see
            // `manageBar`), so the way out of the list sits in the bottom-right corner.
            let runningLive = agentManager.runningTasks.count > 0
            if (!model.hasText || runningLive) && !recentListShown {
                let cluster = idleTrailingCluster
                // The first-launch-after-update cue rides the same trailing edge,
                // just inside the Recent chevron — glass beside glass. It keeps the
                // row alive on its own when the cluster has nothing to draw (a first
                // run with no history and no pin).
                // A waiting build says so in words right here, on the home page —
                // not as a dot behind the ⋯ menu (see `updateCue`).
                let pending = model.hasText ? nil : pendingUpdateVersion
                // One chip on that edge, never two: an update waiting outranks the
                // notes for the build already running, so "What's New" stands down
                // until the update is taken.
                let showsCue = !model.hasText && whatsNew.unseenVersion != nil
                                && pending == nil
                if !cluster.isEmpty || showsCue || pending != nil {
                    Spacer(minLength: 8)
                    if let pending {
                        updateCue(version: pending, height: 30,
                                  hovered: $updateCueIdleHovered)
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                    if showsCue {
                        whatsNewCue
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                    if !cluster.isEmpty { cluster }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
        // The second grip on the idle page (see `detachGrip`): the bucket row's
        // free strip between the pill and the Recent cluster pulls the whole
        // prompt out into its own window.
        .background(detachGrip)
    }

    /// Whether the bucket row still has anything to draw. With Recent expanded the
    /// Ask|Agent pill and its compose chips hide, and the Recent cluster moves down
    /// to the manage bar, so the row can end up empty — and an empty row would still
    /// spend its 10pt top padding, padding out the immersive header for nothing.
    private var bucketRowHasContent: Bool {
        !recentListShown
    }

    /// The idle prompt's Recent-list disclosure (and, once pinned, the tack) as a
    /// glass cluster, configured against the model. Built here once and hosted in
    /// one of two places: the bucket row's trailing edge when a local agent CLI
    /// gives us that row, else the input row's own trailing slot.
    private var idleTrailingCluster: IdleTrailingCluster {
        IdleTrailingCluster(
            pinned: model.isAnswerPinned,
            recentOpen: model.showHistory,
            showsRecent: recentHasContent,
            runningCount: agentManager.runningTasks.count,
            togglePin: {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    model.toggleAnswerPin()
                }
            },
            toggleRecent: {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    model.showHistory.toggle()
                    // Closing via the chevron drops any keyboard highlight; opening
                    // starts un-highlighted (the caret stays in the input).
                    model.highlightedHistoryIndex = nil
                }
            }
        )
    }

    /// The Ask bucket's model chip — the Ask-side twin of the agent compose chips,
    /// riding the same slot beside the pill. It names the model in effect and, on
    /// tap, opens the Ask recents quick menu (`AskRecentModelPickerView`) — the
    /// agent card's little glass sibling listing the five most recently used
    /// models, instead of detouring through the full cross-provider catalog (which
    /// stays reachable from Settings). The popover hangs off the chip itself — a
    /// menu should pop from the control that opened it, not float detached under
    /// the island the way the keyboard-summoned pickers do. Reads the selection
    /// straight from the store like the settings chip, so the chip can never show
    /// a stale model.
    ///
    /// With nothing configured it names the gap instead — "Choose model…" in the
    /// danger ink, the one chip in the row that is reporting a problem rather than
    /// a setting. It used to print the selected provider's *default* model there,
    /// which meant a fresh install advertised "Gpt-5.5" with no key behind it: the
    /// one place that should have said "set this up" was the place claiming it
    /// already was.
    ///
    /// Where the tap goes then depends on what's already on the machine. A signed-in
    /// `codex` / `claude` / `grok` CLI is a *working backend that needs no key* — so
    /// if any are there, the menu lists them (tagged CLI) and one click is the whole
    /// setup. Only with none of them does it fall through to Settings.
    private var askModelChip: some View {
        AgentComposeChip(title: model.isConfigured
                            ? ModelRatings.prettyName(for: selectedModelID,
                                                      provider: selectedProvider)
                            : L("model.choose"),
                         tint: model.isConfigured ? nil : Tokens.danger.opacity(0.62),
                         action: {
            if model.isConfigured || !availableCLIProviders.isEmpty {
                model.showAskModelPicker = true
            } else {
                model.settingsSection = "Model"
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    model.openSettings()
                }
            }
        }, icon: { EmptyView() })
        .fixedSize()
        // Settle-gated like the body-hung pickers: a pick changes the chip's
        // title, the chip resizes, and a bare NSPopover would stay pinned to
        // where the chip *was* — the gate re-glues it to the moved chip.
        .modifier(SettledPopover(isPresented: $model.showAskModelPicker) {
            AskRecentModelPickerView(
                rows: askRecentModelRows,
                selectedProvider: selectedProvider,
                selectedModelID: selectedModelID,
                onSelect: { row in
                    ModelCatalogStore.select(provider: row.provider, model: row.id)
                },
                // "More models…" hands off to Settings' Model pane — the full
                // cross-provider catalog the recents menu deliberately doesn't carry.
                onMoreModels: {
                    model.settingsSection = "Model"
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        model.openSettings()
                    }
                },
                onDone: { model.showAskModelPicker = false })
                .preferredColorScheme(.dark)
                .modifier(GlassPopoverBackground(cornerRadius: 14, veilOpacity: 0, glassTint: 0.14))
        })
    }

    /// The rows the Ask chip's quick menu shows: the selection in effect first, then
    /// the most recently asked-through models (`AskModelMRU`), skipping duplicates
    /// and providers that can't serve right now, capped at the MRU's five. No
    /// padding: fewer than five recents just means a shorter menu — every row is
    /// something the user actually used or picked, never a catalog filler.
    ///
    /// With nothing configured there are no recents worth listing — the "selection
    /// in effect" is a provider default nobody chose and every MRU slot is empty —
    /// so the menu becomes the CLI offer instead: whichever of the local agent CLIs
    /// is installed and signed in, ready to use as-is.
    private var askRecentModelRows: [AskRecentModelPickerView.Row] {
        guard model.isConfigured else {
            return availableCLIProviders.map {
                AskRecentModelPickerView.Row(provider: $0,
                                             id: APIKeyStore.effectiveModel(for: $0)
                                                 ?? $0.defaultModel)
            }
        }
        var rows = [AskRecentModelPickerView.Row(provider: selectedProvider, id: selectedModelID)]
        for e in AskModelMRU.entries {
            let row = AskRecentModelPickerView.Row(provider: e.provider, id: e.model)
            guard !rows.contains(row), ModelCatalogStore.ready(e.provider) else { continue }
            rows.append(row)
        }
        return Array(rows.prefix(AskModelMRU.capacity))
    }

    /// The agent CLIs that are installed *and* signed in right now — real backends
    /// that need no key, so with nothing else configured they are the shortest way
    /// out of an unusable Ask. Each service's `isAvailable` is a warm cache after
    /// the launch warm-up, so reading it during a render costs nothing.
    private var availableCLIProviders: [Provider] {
        var out: [Provider] = []
        if ClaudeCLIService.isAvailable { out.append(.claudeCode) }
        if CodexCLIService.isAvailable { out.append(.codex) }
        if GrokCLIService.isAvailable { out.append(.grokCode) }
        if CommandCodeCLIService.isAvailable { out.append(.commandCode) }
        return out
    }

    /// The folder chip menu's rows: the project in effect first, then the other
    /// recently worked-in ones (`AgentFolderMRU`, dead paths already dropped). No
    /// padding — every row is a project the user actually worked in.
    private var agentFolderRows: [URL] {
        var rows: [URL] = []
        if let current = model.agentComposeFolder { rows.append(current) }
        for f in AgentFolderMRU.entries where !rows.contains(f) { rows.append(f) }
        return Array(rows.prefix(AgentFolderMRU.capacity))
    }

    /// The agent compose chips beside the pill: the task's three facts as glass
    /// chips in the clipboard presets' own language — the folder the agent will
    /// work in (tap to re-pick; "choose" until one has ever been picked), the
    /// model (one menu mixing every engine's entries; picking a model picks its
    /// engine), and the reasoning effort. The way out is the pill's Ask half.
    /// The input above is composing the task description; Enter starts the run.
    private var agentComposeChips: some View {
        HStack(spacing: 6) {
            AgentComposeChip(title: Self.compactFolderTitle(
                                        model.agentComposeFolder?.lastPathComponent)
                                    ?? L("agent.folder.choose"),
                                action: {
                // With projects to switch between, the chip is a menu like its
                // model neighbours; with nothing to list (first-ever agent, or a
                // single remembered project) a one-row menu would be theatre —
                // go straight to the file panel.
                if agentFolderRows.count > 1 {
                    model.showAgentFolderPicker = true
                } else {
                    model.pickAgentFolder()
                }
            }, icon: { EmptyView() })
            .fixedSize()
            // Same settle-gated, chip-hung popover as the model menus — a pick
            // resizes the chip, and the gate re-glues the tail to where it lands.
            .modifier(SettledPopover(isPresented: $model.showAgentFolderPicker) {
                AgentFolderPickerView(
                    folders: agentFolderRows,
                    selected: model.agentComposeFolder,
                    onSelect: { model.selectAgentFolder($0) },
                    onBrowse: { model.pickAgentFolder() },
                    onDone: { model.showAgentFolderPicker = false })
                    .preferredColorScheme(.dark)
                    .modifier(GlassPopoverBackground(cornerRadius: 14, veilOpacity: 0, glassTint: 0.14))
            })

            // Model + reasoning effort read as ONE chip — "Claude Opus xhigh".
            // Clicking it opens the same model+effort quick picker ⌘⇧I summons,
            // not an NSMenu — so both front doors land on one card and behave
            // identically.
            // The title tracks the armed pick LIVE — a model or effort chosen in
            // the open card re-titles the chip on the spot, no waiting for the
            // card to close. The card itself stays exactly where it opened: it
            // doesn't hang off the chip (whose width moves with the title) but
            // off the frozen point below — see `agentChipAnchorX`.
            AgentComposeChip(title: agentModelEffortTitle, action: {
                model.showAgentPicker = true
            }, icon: { EmptyView() })
            .fixedSize()
            // The card hangs off a 1pt probe pinned under the chip's centre —
            // a point, not the chip's own frame. Same place the card has always
            // opened (bottom edge, centred), but re-titling the chip can't drag
            // it sideways or trip `SettledPopover`'s re-glue, which would blink
            // the card shut and open mid-pick. Placed with `.position` (a real
            // layout placement the popover's anchor rect follows) — `.offset`
            // is a render-time transform the anchor ignores, which lands the
            // card at the chip's leading edge instead. In the background, so
            // the chip's own button keeps every click. The settle gate still
            // earns its keep for the island moving underneath (⌘⇧I mid-spring).
            .background {
                GeometryReader { g in
                    Color.clear
                        .frame(width: 1, height: 1)
                        .modifier(SettledPopover(isPresented: $model.showAgentPicker) {
                            AgentModelPickerView(
                                choices: AgentEngine.available.flatMap(\.modelChoices),
                                selectedEngine: model.agentArmedEngine,
                                selectedModelID: model.agentModelID,
                                selectedEffort: model.agentEffort,
                                onSelectModel: { choice in
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        model.selectAgentModel(choice)
                                    }
                                },
                                // Same spring as the model pick, so the chip's title
                                // (and width) catches the new effort as a glide
                                // rather than a jump.
                                onSelectEffort: { effort in
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        model.agentEffort = effort
                                    }
                                },
                                onDone: { model.showAgentPicker = false })
                                // Resolve the Claude aliases to concrete model names ("opus" →
                                // "Claude Opus 4.8") so the rows can say what they actually run;
                                // cached + TTL'd, so this is usually a no-op, and the labels fill
                                // in reactively when a real probe lands.
                                .task { catalog.resolveClaudeAliases() }
                                .preferredColorScheme(.dark)
                                // A thinner veil than the standard popover — this card reads as
                                // transparent Liquid Glass, the wallpaper refracting through it.
                                .modifier(GlassPopoverBackground(cornerRadius: 14, veilOpacity: 0, glassTint: 0.14))
                        })
                        // The chip's bottom-centre — where the card has always
                        // hung from — held at the width the chip had when it opened.
                        .position(x: agentChipAnchorX ?? g.size.width / 2,
                                  y: g.size.height)
                        // Track the centre while the card is down; hold it still
                        // for as long as the card is up.
                        .onChange(of: g.size.width, initial: true) { _, w in
                            guard !model.showAgentPicker || agentChipAnchorX == nil
                            else { return }
                            agentChipAnchorX = w / 2
                        }
                        // Catch up once the card is gone: the title (and with it
                        // the chip's width) may well have changed under it, and
                        // the next open has to hang off the NEW centre.
                        .onChange(of: model.showAgentPicker) { _, open in
                            if !open { agentChipAnchorX = g.size.width / 2 }
                        }
                }
            }
        }
    }

    /// The folder chip's title, middle-truncated in the STRING rather than by
    /// the Text: the chip is `.fixedSize()` (without it the row's fixed-size
    /// menu chips squeeze it and SwiftUI trims even a short name to "not…"),
    /// so a pathological folder name must be bounded here instead.
    private static func compactFolderTitle(_ name: String?) -> String? {
        guard let name else { return nil }
        guard name.count > 22 else { return name }
        return name.prefix(12) + "…" + name.suffix(9)
    }

    /// The model chip's title: the explicit pick's label, or the engine's plain
    /// name when the run rides the CLI-config default. The vendor family word is
    /// dropped the same way the picker's rows drop it — "Claude Opus 4.8" reads
    /// as "Opus 4.8", "GPT-5.1-Codex" as "5.1-Codex" — so the merged chip stays a
    /// tight "Opus 4.8 xhigh" instead of restating the vendor on every run.
    private var agentModelTitle: String {
        let engine = model.agentArmedEngine
        if let id = model.agentModelID,
           let choice = engine.modelChoices.first(where: { $0.id == id }) {
            return Self.strippingModelFamily(choice.label, engine: engine)
        }
        return engine.displayName
    }

    /// Drop the leading vendor family word from a model label — codex labels are
    /// "GPT-…", claude labels "Claude …", so the chip shows only the model. Mirrors
    /// `AgentModelPickerView.shortLabel`; labels without the prefix pass through.
    private static func strippingModelFamily(_ label: String, engine: AgentEngine) -> String {
        let family: String
        switch engine {
        case .codex:  family = "gpt"
        case .claude: family = "claude"
        case .grok:   family = "grok"
        // Command Code fronts a dozen labs — there is no one family word to drop,
        // and the vendor is exactly what tells its models apart.
        case .commandCode: return label
        }
        for sep in ["-", " "] {
            let p = family + sep
            if label.lowercased().hasPrefix(p), label.count > p.count {
                return String(label.dropFirst(p.count))
            }
        }
        return label
    }

    /// The merged model+effort chip's title: the model on its own while effort
    /// rides its CLI default, or "model effort" once a level is picked — the
    /// effort trails as the bare lowercase level (`xhigh`), no separator, no
    /// dash, so the line stays quiet and only names the effort when it's set.
    private var agentModelEffortTitle: String {
        guard let effort = model.agentEffort else { return agentModelTitle }
        return "\(agentModelTitle) \(effort.rawValue)"
    }

    /// The panel presence of agent runs — one quiet line per task, never a card.
    /// Presence and reading are separate things: a bead and one phrase, nothing
    /// else. While a run works the line is the live activity and the leading slot
    /// breathes a soft tint pulse; once it settles a glass bead lights the slot and the line
    /// falls back to the task's own name. A tap opens the run's Recent record in the result view — the
    /// same conversation surface every other thread reads in. Outcome prose,
    /// clocks, file counts and the work trail all belong in that record, not
    /// here: this is a glance surface.
    private var agentStatusRows: some View {
        // spacing 0 so a stack of agent rows keeps the SAME vertical rhythm as the
        // Recent rows below (each row carries its own 9pt vertical pad — see
        // `agentStatusRow`), instead of an airier gap that reads as "bigger padding".
        VStack(alignment: .leading, spacing: 0) {
            // `tasks` is stored in spawn order; show it newest-first so the most
            // recently started run sits at the top of the list.
            ForEach(agentManager.tasks.reversed()) { task in
                agentStatusRow(task)
            }
        }
    }

    private func agentStatusRow(_ task: AgentTaskManager.AgentTask) -> some View {
        HStack(spacing: 8) {
            // A settled run marks its slot with a glass bead (blue done, red
            // failed, grey cancelled); a working one breathes a soft tint pulse.
            AgentStatusDot(running: task.isRunning, outcome: task.outcome)
            if task.isRunning {
                // What the run is doing right now, crossfading as the CLI reports
                // each step — the panel twin of the resting notch's ticker. The
                // changing words and the ticking clock are the "it's alive" signal.
                CrossfadeText(text: task.activity ?? L("agent.thinking"),
                              font: 14, color: Tokens.text3)
                    .tracking(-0.1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                // Stopping a minutes-long run is destructive — two-step: the ✕
                // arms an explicit "cancel?" chip (auto-disarms after a beat),
                // and only that second tap actually terminates.
                if confirmingAgentCancelID == task.id {
                    Button {
                        agentManager.cancel(taskID: task.id)
                        confirmingAgentCancelID = nil
                    } label: {
                        Text(L("agent.cancelConfirm"))
                            .font(.sf(11, weight: .medium))
                            .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.40))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.red.opacity(0.16)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
                    .task {
                        // Un-tapped, the armed confirm quietly relaxes back to
                        // the plain ✕. Cancelled automatically if the chip
                        // leaves the screen first.
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            if confirmingAgentCancelID == task.id {
                                confirmingAgentCancelID = nil
                            }
                        }
                    }
                } else {
                    agentRowTrailing(task) {
                        agentCardButton("xmark", help: L("agent.cancel")) {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                confirmingAgentCancelID = task.id
                            }
                        }
                    }
                }
            } else {
                // Settled: just the task's own name — what was asked, not a
                // report of what came back. The dot already says how it went, and
                // the record behind the tap says the rest. The row body is the tap
                // target that opens it; the ✕ throws the row away without opening
                // (the record stays in Recent either way).
                Text(task.prompt)
                    .font(.sf(14))
                    .tracking(-0.1)
                    .foregroundStyle(task.outcome == .failure
                        ? Tokens.danger.opacity(0.9)
                        : (task.outcome == .cancelled ? Tokens.text3 : Tokens.text2))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                agentRowTrailing(task) {
                    agentCardButton("xmark", help: L("agent.dismiss")) {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                            agentManager.dismissFinished(taskID: task.id)
                        }
                    }
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        // Match the Recent rows' 9pt vertical pad so an agent line sits in the same
        // rhythm as the history below it, not a taller-looking slot.
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The same faint glass floor + thin-material whisper the Recent rows lift
        // under the pointer (HistoryRowStyle), at that style's unselected-hover
        // presence (0.5), so an agent line highlights exactly like the rows below
        // it instead of being the one row that stays flat under the cursor.
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(hoveredAgentRowID == task.id ? 0.015 : 0))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.thinMaterial)
                        .opacity(hoveredAgentRowID == task.id ? 0.11 : 0)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.16)) {
                if inside { hoveredAgentRowID = task.id }
                else if hoveredAgentRowID == task.id { hoveredAgentRowID = nil }
            }
        }
        .onTapGesture {
            if task.isRunning {
                // A live run opens its detail page — the full work trail,
                // streaming — instead of waiting for the record to exist.
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    model.agentDetailTaskID = task.id
                }
            } else {
                openAgentRecord(task)
            }
        }
    }

    /// The row's trailing slot. At rest it's the run's clock — ticking while the
    /// run works, frozen at its final duration once it settles — because that's
    /// what a glance wants to know. Only under the pointer does it become the ✕
    /// (`control`): the close affordance appears on the row you're aiming at,
    /// instead of a column of ✕s shouting at you down the whole list.
    private func agentRowTrailing<Control: View>(
        _ task: AgentTaskManager.AgentTask,
        @ViewBuilder control: () -> Control
    ) -> some View {
        ZStack(alignment: .trailing) {
            if hoveredAgentRowID == task.id {
                control()
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            } else if task.isRunning {
                // Live: re-read the clock every second while the run works.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    agentElapsedLabel(context.date.timeIntervalSince(task.startedAt))
                }
                .transition(.opacity)
            } else {
                // Settled: `elapsed` is pinned by `finishedAt`, so this is the
                // round's final duration, not a clock that keeps running.
                agentElapsedLabel(task.elapsed)
                    .transition(.opacity)
            }
        }
        // Hold the ✕'s width so swapping between clock and button can't shove
        // the line beside it around.
        .frame(minWidth: 18, minHeight: 18, alignment: .trailing)
    }

    /// The elapsed clock itself, in the same language as the collapsed notch's
    /// right ear: monospaced digits that roll rather than hard-cut on each tick.
    private func agentElapsedLabel(_ elapsed: TimeInterval) -> some View {
        let seconds = max(0, Int(elapsed))
        return Text(NotchModel.formatAgentElapsed(TimeInterval(seconds)))
            .font(.sf(11))
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(seconds)))
            .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: seconds)
            .foregroundStyle(Tokens.text4)
            .lineLimit(1)
            .fixedSize()
    }

    /// Open a settled run where it's actually read: its Recent record, in the
    /// result view. The row's job is done once the record is open, so it leaves
    /// the tray with the tap (the record itself stays in Recent regardless).
    /// While the run is live there's nothing filed yet — the tap waits.
    private func openAgentRecord(_ task: AgentTaskManager.AgentTask) {
        guard !task.isRunning else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            model.openThread(id: task.id)
            agentManager.dismissFinished(taskID: task.id)
        }
    }

    // MARK: - Agent run detail page

    /// The task behind the open agent detail page, if any — nil once the task
    /// leaves the tray (dismissed), which drops the page back to idle by itself.
    private var agentDetailTask: AgentTaskManager.AgentTask? {
        model.agentDetailTaskID.flatMap { id in
            agentManager.tasks.first { $0.id == id }
        }
    }

    /// Stable id for the tail spacer the detail scroll follows while streaming.
    private static let agentDetailBottomID = "agent-detail-bottom"

    /// The detail scroll's height. Tuned so the whole page (26pt header + 10 gap
    /// + this + 10 gap + 39pt follow-up row = 320pt) matches the immersive
    /// history layout, whose 320pt list is the only thing that opens the island
    /// (its input header floats as an overlay, taking no layout height) — the
    /// agent page must never make the island taller than the recent list does.
    private let agentDetailScrollHeight: CGFloat = 235

    /// A live run's detail page: the task prompt, then the full work trail —
    /// the agent's narration as prose, each tool call a collapsible mono row —
    /// with the activity ticker at the tail while it works, and the final
    /// report once it settles. Same information structure as the record a
    /// settled row opens; this is the during-the-run way in.
    private func agentDetailView(_ task: AgentTaskManager.AgentTask) -> some View {
        // The flat trail (`task.log`) spans every round; the settled rounds each
        // own their own slice via `exchange.log`. Whatever's left over belongs to
        // the round in flight — its "› " prompt marker plus the tool rows it has
        // produced so far. Split by entry id, never by index, so a capped/trimmed
        // trail still partitions cleanly.
        let claimedIDs = Set(task.exchanges.flatMap { $0.log.map(\.id) })
        let liveTail = task.log.filter { !claimedIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: 10) {
            agentDetailHeader(task)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Every settled round in order — its prompt, its own slice
                        // of the work trail, then its report — so a follow-up thread
                        // keeps ALL prior answers on screen. (This page used to
                        // collapse to the task headline + the single latest answer,
                        // dropping every earlier round's report the moment a
                        // follow-up started.) Same structure as the record a settled
                        // Recent row reopens into.
                        ForEach(Array(task.exchanges.enumerated()), id: \.offset) { _, exchange in
                            UserQuestionBubble(text: exchange.prompt)
                            // The trail's last narration entry IS this round's report
                            // (the parser records it in both places) — drop it so it
                            // isn't printed again by the answer just below. See
                            // `droppingTrailingAnswer`.
                            let trail = exchange.log.droppingTrailingAnswer(exchange.answer)
                            if !trail.isEmpty {
                                // Lazy: a long run's trail is hundreds of rows and
                                // this page pins to the tail — see `isLazy`'s doc.
                                AgentWorkTrailView(entries: trail, isLazy: true)
                            }
                            if !exchange.answer.isEmpty {
                                MarkdownBlocks(source: exchange.answer, baseFont: 15)
                            }
                        }
                        // The round still in flight has no settled exchange yet.
                        // Round one carries no "› " marker, so its prompt is the task
                        // headline; a follow-up round's prompt already rides the live
                        // tail as its leading "› " marker.
                        if task.isRunning {
                            if task.exchanges.isEmpty {
                                UserQuestionBubble(text: task.prompt)
                            }
                            if !liveTail.isEmpty {
                                AgentWorkTrailView(entries: liveTail, isLazy: true)
                            }
                            // The collapsed row's ticker, following the trail —
                            // what the run is doing right now. Same 14pt/text3
                            // face the status row wears.
                            CrossfadeText(text: task.activity ?? L("agent.thinking"),
                                          font: 14, color: Tokens.text3)
                                .tracking(-0.1)
                                .lineLimit(1)
                                .padding(.vertical, 2)
                        }
                        Color.clear.frame(height: 1).id(Self.agentDetailBottomID)
                    }
                    // Runway: the trail rests below the header, then scrolls up into
                    // this empty band to fade + frost out — the same soft top edge
                    // the detached agent window wears (`ThreadScroll`), so the page
                    // reads identically on both sides of a tear.
                    .padding(.top, ThreadScroll.runway)
                    .padding(.bottom, 10)
                }
                // The shared dissolve at the top edge only — the page pins to the
                // tail, so the newest line rests at the bottom and must stay at
                // full strength (a bottom taper would permanently dim it).
                .scrollEdgeFade(top: true, bottom: false, topFade: ThreadScroll.runway)
                // Frost rests while the run streams (same discipline as the result
                // view's ConditionalTopBlur): the blurred copy re-rasterizes on
                // every content change, and a live trail changes constantly.
                .modifier(ConditionalTopBlur(active: !task.isRunning,
                                             height: ThreadScroll.band,
                                             maxRadius: ThreadScroll.blurRadius))
                // Follow the tail while entries stream in, like a terminal.
                .onChange(of: task.log.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.agentDetailBottomID, anchor: .bottom)
                    }
                }
                .onAppear {
                    proxy.scrollTo(Self.agentDetailBottomID, anchor: .bottom)
                }
            }
            .frame(height: agentDetailScrollHeight)

            // A live follow-up box, same as the detached agent window carries. The
            // run is mid-reply, so Enter can't interrupt it — the line queues and
            // the manager dispatches it as the next round on settle (its "› "
            // marker joins the trail above the moment it lands). The box stays after
            // send, so several instructions can be lined up. Hidden only when the
            // run settled without ever reporting a session id (nothing to resume,
            // ever); a still-running or resumable task keeps it live.
            if task.isRunning || task.sessionID != nil {
                agentDetailFollowUpRow(task)
            }
        }
    }

    /// The agent-detail page's follow-up input. Wired straight to the task's queue
    /// (`AgentTaskManager.followUp`) rather than the panel's submit routing — the
    /// page renders in `.idle` mode with empty `turns`, so `submitCurrent` would
    /// mis-route the line to the chat model. Placeholder says "queue" while a round
    /// is in flight, "ask a follow-up" once it settles.
    private func agentDetailFollowUpRow(_ task: AgentTaskManager.AgentTask) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            ZStack(alignment: .leading) {
                PromptField(
                    text: $agentDetailFollowUp,
                    placeholder: "",
                    fontSize: NotchBody.followUpFontSize,
                    focusTrigger: focused,
                    maxVisibleLines: NotchBody.promptMaxLines,
                    onSubmit: { submitAgentDetailFollowUp(task) },
                    onCaretWidth: { agentDetailFollowUpCaretWidth = $0 },
                    onHeightChange: { agentDetailFollowUpHeight = $0 }
                )
                .frame(height: agentDetailFollowUpHeight)
                if agentDetailFollowUp.isEmpty && agentDetailFollowUpCaretWidth == 0 {
                    Text(L(task.isRunning ? "agent.followUp.queue"
                                          : "agent.followUp.placeholder"))
                        .font(.sf(NotchBody.followUpFontSize))
                        .foregroundStyle(Tokens.placeholder)
                        .lineLimit(1)
                        .padding(.leading, PromptField.textInset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(height: max(27, agentDetailFollowUpHeight))
            .animation(.easeOut(duration: 0.16), value: agentDetailFollowUpCaretWidth == 0)

            if !agentDetailFollowUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SendButton(compact: true) { submitAgentDetailFollowUp(task) }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(focused ? Tokens.recessFillLit : Tokens.recessFill)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(focused ? Tokens.recessRimLit : Tokens.recessRim, lineWidth: 0.5)
        )
        .animation(.easeOut(duration: 0.2), value: focused)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: agentDetailFollowUp.isEmpty)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: agentDetailFollowUpHeight)
    }

    /// Queue the line as the run's next instruction and clear the field — the box
    /// itself stays so more can follow. While the round is in flight the manager
    /// holds it and dispatches on settle; a settled-but-resumable task spawns it
    /// straight away. Never dismisses the page.
    private func submitAgentDetailFollowUp(_ task: AgentTaskManager.AgentTask) {
        let line = agentDetailFollowUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        agentDetailFollowUp = ""
        AgentTaskManager.shared.followUp(taskID: task.id, prompt: line)
    }

    /// The detail page's top bar: back chevron (the page is a peek, not a mode —
    /// backing out never touches the run), status dot + engine·folder title,
    /// then the same elapsed clock the collapsed row shows and the open-folder
    /// jump the settled record offers.
    private func agentDetailHeader(_ task: AgentTaskManager.AgentTask) -> some View {
        HStack(spacing: 10) {
            // Back chevron: the page renders in `.idle` mode, so the bare-← key
            // handler (which gates on `mode != .idle`) can't reach it — a visible
            // button is the only reliable way out (Esc closes the whole panel).
            // Same chevron the result header carries; taps `newChat()`, which
            // drops `agentDetailTaskID` and falls back to the idle prompt.
            backButton
            Spacer(minLength: 0)
            if task.isRunning {
                TimelineView(.periodic(from: task.startedAt, by: 1)) { context in
                    agentElapsedLabel(context.date.timeIntervalSince(task.startedAt))
                }
            } else {
                agentElapsedLabel(task.elapsed)
            }
            // Open-folder + detach ride the same trailing-cluster glass the result
            // header and detached window wear (`GlassSegmentCluster`), so every
            // two-icon corner control in the app reads as one species.
            GlassSegmentCluster(segments: [
                .init(tooltip: L("agent.openFolder"),
                      action: { NSWorkspace.shared.open(task.folder) }) {
                    Image(systemName: "folder")
                        .font(.sf(12, weight: .semibold))
                },
                .init(tooltip: shortcutHelp("detached.open", action: .detach),
                      action: { model.openDetachedWindow() }) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.sf(12, weight: .semibold))
                },
            ])
        }
        // The detail header is also the run's tear-off grip — drag the page out
        // and the task splits into its own window. The hand cursor rides the
        // WHOLE strip, buttons included, because the whole strip really is
        // draggable: the icons win the tap, the drag arms past its minimum.
        .contentShape(Rectangle())
        .grabCursor()
        .gesture(detachDragGesture)
    }

    /// A small quiet icon button for the agent card's corner actions — a bare
    /// glyph, no drawn backing: the card already carries enough chrome, so the
    /// buttons read as marks, not more boxes. The 18pt frame keeps the target.
    private func agentCardButton(_ systemName: String, help: String,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.sf(9.5, weight: .semibold))
                .foregroundStyle(Tokens.text4)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }


    /// Shared open/close feel for the modules that unfurl below the prompt
    /// (recent list, inline settings): the whole block grows in from the top and
    /// fades, rather than popping in instantly.
    private var moduleTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .top)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.97, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
        )
    }

    /// The manage bar: the recent panel's bottom chrome, in both the compact and
    /// immersive layouts. The ⋯ chip holds the BOTTOM-LEFT corner and pops the manage
    /// MENU upward (filter by source, Settings) — see `manageMenu`. While a
    /// source filter is active and the menu is closed, a small tinted chip beside
    /// the ⋯ names the filter and clears it on tap, so the narrowed list never
    /// reads as "history lost". The Recent chevron (and the pin, once ⌘P holds the
    /// panel) holds the BOTTOM-RIGHT corner opposite it — while the list is up, the
    /// way out of it belongs on the same baseline as the ⋯, not up in the header.
    /// Always visible — fixed chrome below the list.
    ///
    /// Used by `historySection` (compact) as a VStack sibling below the list, and by
    /// `immersiveHistoryView` as an overlay across the bottom of the scroll frame.
    private var manageBar: some View {
        HStack(spacing: 6) {
            // The single ⋯ chip. It only toggles the menu.
            moreEntry

            // A waiting build sits OUTSIDE the menu, next to the ⋯ — spelled out,
            // one tap, no digging. It stays put while the menu is up (the menu
            // floats above this row, covering nothing), and the menu drops its own
            // update row meanwhile (see `updateMenuRow`), so the action lives in
            // exactly one place.
            if let pending = pendingUpdateVersion {
                updateCue(version: pending, height: 34,
                          hovered: $updateCueBarHovered)
                    .transition(
                        .move(edge: .leading)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.9, anchor: .leading))
                    )
            }

            // Active-filter chip: visible while a source filter narrows the list
            // and the menu is folded away. Tinted with the source's colour; the ×
            // makes "tap to clear" legible without a tooltip.
            if !manageExpanded, let source = model.historySourceFilter {
                activeFilterChip(source)
                    .transition(
                        .move(edge: .leading)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.9, anchor: .leading))
                    )
            }

            Spacer(minLength: 8)   // hold the two clusters apart, one per corner

            // The Recent (+ pin) cluster, handed over from the header for as long as
            // the list is up (see `bucketRow` / `inputRow`).
            let cluster = idleTrailingCluster
            if !cluster.isEmpty {
                cluster
            }
        }
        // The menu floats ABOVE the chip, anchored to its bottom-left, and grows
        // upward out of it. An overlay (not a sibling) so opening it never
        // relayouts the list — it draws over the rows like a real popup menu.
        .overlay(alignment: .bottomLeading) {
            if manageExpanded {
                manageMenu
                    // Lift the menu's bottom edge just above the 34pt ⋯ chip.
                    .offset(y: -(34 + 8))
                    // Unfurl UP and OUT of the ⋯ chip: grow from its top-left
                    // corner with a small rise, rather than popping in place —
                    // the upward mirror of how the island's other modules move.
                    .transition(
                        .scale(scale: 0.86, anchor: .bottomLeading)
                            .combined(with: .offset(y: 6))
                            .combined(with: .opacity)
                    )
            }
        }
        // Collapse the menu whenever the panel itself closes, so the next open
        // starts back at the bare ⋯ rather than a stale open menu.
        .onChange(of: model.showHistory) { _, showing in
            if !showing { manageExpanded = false }
        }
        // One inset, both sides: the ⋯ and the Recent chevron sit the same distance
        // from their own edge, so the bar's two corners read as a matched pair. The
        // call site supplies the outward pull (the body's own 20pt is too generous
        // for corner chrome) and the bottom placement.
        .padding(.horizontal, 2)
    }

    /// The version of a build that's downloaded and waiting, if any — what the
    /// "Update to X" chips print. Nil at every other phase (idle, checking,
    /// updating, failed), which is what keeps the chips off the rows until there
    /// is actually something to install.
    private var pendingUpdateVersion: String? {
        if case .available(let v) = updater.phase { return v }
        return nil
    }

    /// The ⋯ entry: a single Liquid Glass chip that pops the manage menu up above
    /// itself. No update badge — a waiting build gets its own chip beside this one
    /// (see `updateCue`) rather than a dot to decode.
    private var moreEntry: some View {
        // ⋯ when closed; × once the menu is up, so the chip reads as "dismiss"
        // while the popup is showing.
        GlassIconButton(
            systemName: manageExpanded ? "xmark" : "ellipsis",
            help: L(manageExpanded ? "recent.collapse" : "recent.manage"),
            size: 34
        ) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                manageExpanded.toggle()
            }
        }
    }

    /// The upward manage menu: one small glass card holding the update action,
    /// release notes, and Settings — the two update entries pulled out here so
    /// they're one tap away instead of buried in Settings → About. (The source
    /// filter chips used to sit above it but were removed.) "See all history" and
    /// Clear deliberately do NOT live here — they sit at the very END of the recent
    /// list (see `historyFooterActions`), so they're reached by scrolling the list
    /// to its bottom.
    private var manageMenu: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 2) {
            // Update action: "Update to X" once a newer build is ready, otherwise a
            // manual freshness check that reports its result in place. Same
            // behaviour as the About version row.
            updateMenuRow
            // Release notes: the What's New panel, without a detour through Settings.
            manageMenuRow(icon: LucideIcons.scrollText, title: L("recent.menu.releaseNotes")) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    manageExpanded = false
                    model.openWhatsNew(on: nil)
                }
            }
            // The keyboard reference. It lands in Settings → Shortcuts rather than
            // popping a card of its own: the list is long enough to want the
            // settings pane's room, and the summon chord it leads with is
            // *editable* in the section right above it (General), so the two
            // belong under one roof. Same jump the update row makes to About.
            manageMenuRow(icon: LucideIcons.command, title: L("recent.menu.shortcuts")) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    manageExpanded = false
                    model.settingsSection = "Shortcuts"
                    model.toggleSettings()
                }
            }
            manageMenuRow(icon: LucideIcons.settings, title: L("recent.menu.settings"), shortcut: "⌘,") {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    manageExpanded = false
                    model.toggleSettings()
                }
            }
        }
        .padding(6)
        .frame(minWidth: 176, alignment: .leading)
        .fixedSize()
        // REAL Liquid Glass, same recipe as the source popover: the `.clear`
        // material refracts whatever sits behind the card (list rows, wallpaper
        // through the island), with a soft dark veil over it for text contrast —
        // not a flat material approximation.
        .background {
            shape.fill(.clear).nativeGlass(in: shape)
                .overlay(shape.fill(Color.black.opacity(0.38)))
        }
        // A soft top-down sheen, like light catching the card's upper edge.
        .overlay(
            shape.fill(
                LinearGradient(
                    colors: [.white.opacity(0.09), .clear],
                    startPoint: .top, endPoint: .center
                )
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        )
        // Specular hairline rim — top-bright fading down the sides, the same
        // bevel language as the island's chips and the source popover.
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.30), .white.opacity(0.07)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 0.75
            )
            .allowsHitTesting(false)
        )
        .clipShape(shape)
        // Two shadows seat the floating card: a tight contact shadow that keys it
        // to the chip it grew from, and a wide soft one lifting it off the rows.
        .shadow(color: .black.opacity(0.30), radius: 3, y: 1)
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }

    /// The update row of the manage menu — "Check for updates", a tap jumps to
    /// Settings → About with a user-initiated check already running (the same path
    /// as the app menu's "Check for Updates…"), so the spinner, the "up to date"
    /// note, or the Update button land in the About slot built to show them instead
    /// of the menu pantomiming the check in place.
    ///
    /// Once a build IS waiting the row drops out entirely: the "Update to X" chip
    /// on the bar outside owns that action now (see `updateCue`), and repeating it
    /// in here would be the same tap twice.
    @ViewBuilder
    private var updateMenuRow: some View {
        if pendingUpdateVersion != nil {
            EmptyView()
        } else {
            manageMenuRow(icon: LucideIcons.circleFadingArrowUp,
                          title: L("recent.menu.checkForUpdates")) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    manageExpanded = false
                    model.settingsSection = "About"
                    model.toggleSettings()
                }
                updater.checkManually()
            }
        }
    }

    /// One full-width action row of the manage menu — icon, label, optional
    /// trailing shortcut hint — with the plain white hover wash the other glass
    /// popover menus use (see `ManageMenuRowStyle`).
    private func manageMenuRow(
        icon: LucideIcons.Mark, title: String, shortcut: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // A step quieter than the label it leads — the word is the thing being
                // read, the glyph only marks the row.
                LucideIcon(mark: icon)
                    .foregroundStyle(Tokens.text3)
                Text(title)
                    .font(.sf(12, weight: .medium))
                    .foregroundStyle(Tokens.text2)
                Spacer(minLength: 16)
                if let shortcut {
                    Text(shortcut)
                        .font(.sf(10))
                        .foregroundStyle(Tokens.text4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(ManageMenuRowStyle())
    }

    /// The collapsed-state reminder that a source filter is narrowing the list:
    /// a small tinted capsule beside the ⋯ naming the filter, with an × — tap
    /// anywhere on it to clear the filter and show everything again.
    private func activeFilterChip(_ source: NotchModel.HistoryItem.Source) -> some View {
        ActiveFilterChip(model: model, source: source)
    }

    /// The two end-of-list actions — "See all history" (the standalone archive
    /// window, holding everything past `NotchModel.notchRecentCap`) and the
    /// destructive Clear. They live at the tail of the scroll content, not in the ⋯
    /// menu: you meet them only after scrolling past the oldest row, which is
    /// precisely the moment "show me everything" or "wipe this" becomes the next
    /// move. A fading hairline above them marks where the list ends.
    private var historyFooterActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0), .white.opacity(0.12), .white.opacity(0)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(height: 0.5)

            HStack(spacing: 8) {
                // "See all history" earns its place only once the archive holds MORE
                // than the notch list can show — i.e. older items have been truncated
                // past `notchRecentCap`. When everything still fits, the archive window
                // would open onto the exact same rows already on screen, so the button
                // is pure redundancy and we drop it (Clear stays — it's always apt).
                if model.history.count > NotchModel.notchRecentCap {
                    HistoryFooterButton(
                        icon: "clock.arrow.circlepath",
                        title: L("recent.menu.seeAll")
                    ) {
                        // Fold the expanded recent list back to the compact prompt as
                        // the standalone archive takes over. Otherwise the still-open
                        // list floats above the newly centered History window and its
                        // top gets covered — and it's redundant, since the archive now
                        // holds everything. Same spring as the list's open/close.
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                            model.collapseHistory()
                        }
                        NotificationCenter.default.post(name: .openHistoryArchiveRequested, object: nil)
                    }
                }
                // Destructive, so it arms the confirmation instead of wiping on the
                // first tap. The confirm card renders centered over the whole island
                // (see NotchIsland), not anchored to this pill.
                HistoryFooterButton(
                    icon: "trash",
                    title: L("recent.clear")
                ) {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        model.confirmingClear = true
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 10)
        .padding(.horizontal, 8)
    }

    /// The compact recent list (≤6 visible rows) with the manage bar (the ⋯ chip)
    /// pinned at the BOTTOM-LEFT below the list rows — matching the immersive layout.
    /// The open animation moves the whole block together via the moduleTransition at
    /// the call site (which also supplies the 12pt gap above the list).
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Live filter — hidden behind the filter icon by default. Only shown
            // once the list is long enough to be worth searching (matches historyList's
            // own > 6 overflow calibration) AND the user has explicitly expanded it.
            // The field spans the section width so its text aligns with the list rows
            // below, and its vertical padding is kept tight since it's a revealed
            // secondary control.
            if model.history.count > 6, model.showHistoryFilter {
                HistorySearchField(
                    text: $model.historySearchQuery,
                    placeholder: L("recent.filter"),
                    fontSize: 12,
                    focusTrigger: filterFocused
                )
                .frame(height: 18)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Tokens.hairline, lineWidth: 0.5)
                        )
                )
                .padding(.bottom, 4)
                .transition(.opacity)
                .onAppear {
                    // The field is summoned with ⌘F (ContentView's key catcher flips
                    // showHistoryFilter). It only mounts once that's true, so grabbing
                    // focus on appear lands the caret without a click. The tiny delay
                    // lets SwiftUI finish inserting the field before the focus grab.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        filterFocused = true
                    }
                }
                .onChange(of: model.showHistoryFilter) { _, showing in
                    if !showing { filterFocused = false }
                }
            }

            historyList()

            // Manage bar below the list rows — bottom-left, matching the immersive
            // layout. The .padding(.top, 12) at the historySection call site in
            // idleView supplies the gap above the list; this bar closes the section.
            // No bottom inset: the body's own 22pt bottom padding is the breathing
            // room, and this keeps the bar low like the immersive variant.
            manageBar
                .padding(.top, 6)
                // Keep the popped-up manage menu (an overlay reaching UP over the
                // rows) drawing above the ScrollView sibling during transitions.
                .zIndex(1)
        }
    }

    /// Plain-input header baseline: the height the floating header now measures with
    /// just the input (the manage bar moved to the bottom, out of the header). The
    /// `inputRow` carries `.frame(height: 48)` and the floating-header VStack wraps it
    /// with `.padding(.bottom, 6)` → 54pt measured for the bare-input case. The seed is
    /// set to exactly 54 so the `max(h, baseline)` clamp matches the real first-frame
    /// measurement and never over-reserves runway.
    private static let immersiveHeaderBaseline: CGFloat = 54

    /// Breathing room between the bottom of the floating header and the first row's
    /// resting top. `baseline (54) + gap (12) = 66`, the runway the bare-input layout
    /// uses; a header with a preview measures taller and the runway grows with it.
    private let immersiveHeaderGap: CGFloat = 12

    /// How far the immersive list's content reaches UP behind the floating header so
    /// the first row rests just clear of it. Derived from the *measured* header height
    /// (`measuredImmersiveHeaderHeight`) rather than a constant, because the header is
    /// not fixed: a plain input is short, but a pending copied-image preview adds a
    /// line above the input. Tracking the real
    /// height keeps the first row clear whether or not a preview is present.
    private var immersiveTopReach: CGFloat { measuredImmersiveHeaderHeight + immersiveHeaderGap }

    /// Height of the top frost band, in points. Kept SHORTER than the layout runway
    /// (`immersiveTopReach`) on purpose: the band must taper fully to clear before it
    /// reaches the first row's resting position, or the blurred light-grey glyphs of
    /// that row stack into a bright halo (see `ProgressiveTopBlur`). A 4pt margin under
    /// the runway is the tuned ceiling — over the 320pt viewport the deepest frost layer
    /// is also the faintest, so its tail grazing the runway edge stays imperceptible
    /// while the opaque bulk of the frost sits above. Derived from the runway (not a
    /// constant) so the band tracks the header: it grows when a preview raises the header
    /// and shrinks back for a plain input, always ending just above the first row.
    private var immersiveBlurReach: CGFloat { max(immersiveTopReach - 4, 0) }

    /// How far the immersive list's content reaches DOWN behind the floating manage
    /// bar — the bottom mirror of `immersiveTopReach`. It's the runway the last rows
    /// scroll down into and dissolve (fade + frost) behind the ⋯ chrome, so
    /// reaching the very bottom of the list reads as rows sliding under the buttons,
    /// not stopping above them. Sized to clear the bar (gear 30 + 4pt bottom pad ≈
    /// 34) plus a little headroom so a row can travel fully behind it.
    private let immersiveBottomReach: CGFloat = 44

    /// Height of the bottom frost band — the mirror of `immersiveBlurReach`. Kept
    /// SHORTER than the bottom runway so the band tapers to clear before it reaches
    /// the last row's resting position (no blurred-glyph halo at rest); only rows
    /// travelling down into the runway behind the bar frost out.
    private var immersiveBottomBlurReach: CGFloat { max(immersiveBottomReach - 4, 0) }

    /// Total height of the immersive scroll region — deliberately taller than the
    /// compact 220 so the recent list fills the panel and reads as one continuous
    /// surface flowing under the header. The manage bar floats over its bottom-left;
    /// rows run their whole height behind it. Older rows are a scroll (or ↓) away.
    /// Static so Settings can size its own body against it (see
    /// `InlineSettingsView.settingsPaneMaxHeight`) — switching between the two
    /// must not resize the island, and two hand-tuned numbers would drift.
    static let immersiveListHeight: CGFloat = 320

    /// Height of the compact scroll region, and the two content measurements the
    /// compact overflow test weighs against it: one recent row (9pt padding on each
    /// side of a 14pt line) and the end-of-list footer (hairline + gap + one 25pt
    /// glass pill, plus its 10pt lead-in). Estimates, not measurements — they only
    /// decide whether the bottom taper is worth drawing.
    private let compactListHeight: CGFloat = 220
    private let compactRowHeight: CGFloat = 35
    private let historyFooterHeight: CGFloat = 50

    #if DEBUG
    private func debugGeom(_ tag: String, _ y: CGFloat) {
        let line = "[GEOM \(tag)] tasks=\(agentManager.tasks.count) recent=\(model.recentVisible.count) contentTopY=\(String(format: "%.1f", y)) topReach=\(String(format: "%.1f", immersiveTopReach)) header=\(String(format: "%.1f", measuredImmersiveHeaderHeight))\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/notch-geom.log") {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: URL(fileURLWithPath: "/tmp/notch-geom.log"))
        }
    }
    #endif

    /// The recent list. `immersive` swaps the compact, below-the-header list for
    /// the tall variant whose content scrolls UP behind the floating input —
    /// frosting and fading as it goes (see `immersiveTopReach`). Only used once
    /// the list overflows; a short list stays compact under the header.
    private func historyList(immersive: Bool = false) -> some View {
        // More content than fits the window → the list scrolls. In the compact layout
        // the first row sits right under the (non-scrolling) RECENT header, so the
        // TOP never needs a fade — a fixed top pad there would just open a dead gap
        // below the header. The immersive layout is the opposite: its top reaches
        // up behind the floating input, so it DOES taper (fade + frost) there.
        //
        // The compact bottom taper turns on exactly when the content outgrows the
        // 220pt frame. `historyFooterActions` rides at the tail of that content, so
        // its height counts here too — otherwise a 5-row list would quietly scroll
        // its footer off a hard, un-faded edge.
        let contentHeight =
            CGFloat(model.recentVisible.count) * compactRowHeight
            + (model.recentVisible.isEmpty ? 0 : historyFooterHeight)
        let overflowing = contentHeight > compactListHeight
        return ScrollViewReader { proxy in
        ScrollView {
            // Lazy: the data holds up to `notchRecentCap` (50) rows but only ~6–9
            // fit the frame — no need to build and lay out the off-screen ones.
            LazyVStack(alignment: .leading, spacing: 0) {
                #if DEBUG
                // TEMP: report the content-top position inside the scroll viewport so
                // we can see the resting scroll offset (topReach = pinned to top).
                Color.clear.frame(height: 0).background(GeometryReader { g in
                    Color.clear
                        .onAppear { debugGeom("appear", g.frame(in: .named("immScroll")).minY) }
                        .onChange(of: g.frame(in: .named("immScroll")).minY) { _, y in
                            debugGeom("change", y)
                        }
                })
                #endif
                // Agent runs ride the TOP of the scroll — the newest rows, scrolling
                // with the recent list like everything else — instead of pinned above
                // it (immersive: in the floating header; compact: a fixed sibling). So
                // a live task scrolls away normally rather than fixed over the top.
                if !agentManager.tasks.isEmpty {
                    // No extra gap here: each agent row already carries the same 9pt
                    // vertical pad as a Recent row, so the last agent row meets the
                    // first history row on the same 18pt rhythm as any two rows.
                    agentStatusRows
                }
                // Index into the SAME slice the model navigates (`recentVisible`),
                // so the keyboard highlight and the rendered rows can't drift.
                ForEach(Array(model.recentVisible.enumerated()), id: \.element.id) { index, item in
                    Button { model.openHistory(item) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(item.displayTitle)
                                .font(.sf(14))
                                .tracking(-0.1)
                                .foregroundStyle(Tokens.text2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            // Ask rows show how long ago; Note/Reminder captures
                            // show where tapping goes, in the same trailing slot —
                            // so the Recent list reads as one ledger of everything
                            // the notch did, not just AI answers. The capture badge
                            // pairs the destination with an up-right arrow (the same
                            // "opens elsewhere" glyph the footer uses) so the row
                            // reads as a live jump into Notes/Reminders, not a dead
                            // label — tapping it lands on that exact note/reminder.
                            if item.pending {
                                // Still answering: the question is already in the list,
                                // and this small three-dot wave sits where the timestamp
                                // will land once the answer settles in place.
                                RecentPendingDots()
                            } else if item.source.isThread {
                                HStack(spacing: 6) {
                                    // A round that produced no answer keeps its row
                                    // (the question is the user's), so the row has to
                                    // say so — otherwise it reads as an ordinary
                                    // answer until you open it.
                                    if item.failed {
                                        Text(L("recent.badge.failed"))
                                            .font(.sf(11, weight: .medium))
                                            .foregroundStyle(Tokens.danger.opacity(0.9))
                                    }
                                    Text(relativeTime(item.t))
                                        .font(.sf(11).monospacedDigit())
                                        .tracking(0.2)
                                        .foregroundStyle(Tokens.text4)
                                }
                            } else {
                                // The jump to Notes/Reminders lives on its OWN button,
                                // not the row body — tapping the row must never yank the
                                // user out to another app they didn't ask to open. Only
                                // this trailing pill switches apps. `.plain` + its own
                                // `contentShape` isolate the hit region so a tap here
                                // fires the jump and doesn't bubble to the row's Ask path.
                                CaptureJumpButton(
                                    title: item.source == .note ? L("recent.badge.notes") : L("recent.badge.reminders"),
                                    tint: item.source.tint
                                ) { model.openCaptureInApp(item) }
                                // VoiceOver: this control is the jump; name it by
                                // destination so it reads distinctly from the row.
                                .accessibilityLabel(
                                    item.source == .note ? L("recent.hint.note") : L("recent.hint.reminder")
                                )
                            }
                        }
                        .padding(.vertical, 9)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HistoryRowStyle(selected: model.highlightedHistoryIndex == index))
                    // VoiceOver: an Ask row IS its action — combine title + timestamp
                    // into one element that reopens the thread. A capture row's action
                    // now lives on the SEPARATE trailing jump button (the row body no
                    // longer switches apps), so keep it a container (`.contain`) whose
                    // jump button stays independently focusable rather than folding it
                    // into the row.
                    .modifier(RecentRowAccessibility(item: item))
                    // A deleted row collapses up and fades rather than vanishing on a
                    // hard cut — the rows below slide into the gap on the same spring
                    // that drives the list's other module motion. Paired with the
                    // `withAnimation` around the delete below; the removal edge is what
                    // SwiftUI plays this transition against.
                    //
                    // …except during a bulk Clear (`bulkClearing`), where the sideways
                    // slide is the wrong verb: it says "this one row, swept out", and a
                    // whole 24-hour window playing it at once read as a curtain wiping
                    // across the list. A clear isn't per-row — the rows just stop
                    // existing — so they dissolve in place and only the gap closing
                    // carries the motion.
                    .transition(
                        model.bulkClearing
                            ? .opacity.combined(with: .scale(scale: 0.97))
                            : .move(edge: .leading)
                                .combined(with: .opacity)
                                .combined(with: .scale(scale: 0.96, anchor: .leading))
                    )
                    // Right-click a row to drop just that entry (Clear still wipes
                    // the whole list). Single-item delete needs no confirmation —
                    // one row is cheap to retype, unlike the destructive Clear-all.
                    .contextMenu {
                        Button(L("recent.delete"), role: .destructive) {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                model.deleteHistory(id: item.id)
                            }
                        }
                    }
                    // Target for keyboard-follow scrolling: ↓/↑ moves the highlight,
                    // and the onChange below scrolls that row's id into view.
                    .id(item.id)
                }

                // End-of-list actions. They ride at the BOTTOM of the scroll content,
                // so a long list only reveals them once it's dragged all the way down —
                // past the oldest row, where "see everything" and "wipe everything"
                // are what's left to do. A short list that doesn't scroll shows them
                // right away, since it's already at its bottom.
                if !model.recentVisible.isEmpty {
                    historyFooterActions
                }
            }
            // The immersive TOP runway is NOT padding — it's a safe-area inset on the
            // ScrollView itself (see `.safeAreaInset` below), because a runway made of
            // content is a runway SwiftUI can scroll away. The compact layout takes a
            // short content reserve of its own (only when the list actually scrolls) so
            // its top taper falls over empty space under the (non-floating) RECENT
            // header rather than dimming the first row at idle.
            // The bottom inset differs by layout: the immersive list runs its
            // rows full-height behind the floating manage bar (so the last rows stay
            // visible through/around the buttons) and only needs a little clearance
            // off the rounded corner; the compact list reserves the full edgeFade so
            // its bottom taper falls over empty space, not a row.
            .padding(.top, immersive ? 0 : (overflowing ? compactTopFade : 0))
            // Immersive: a bottom runway rows scroll DOWN into behind the manage bar
            // (always present — the immersive layout only mounts for an overflowing
            // list). Compact: the edgeFade reserve, only when actually overflowing.
            .padding(.bottom, immersive ? immersiveBottomReach : (overflowing ? edgeFade : 0))
        }
        #if DEBUG
        .coordinateSpace(name: "immScroll")
        #endif
        // The immersive top runway (`immersiveTopReach`): the strip the first row
        // rests below, and that rows travel up into behind the floating input. It is
        // a SAFE-AREA INSET rather than `.padding(.top)` on the stack, and that
        // distinction is the whole fix for a bug that made the list open "covering"
        // the prompt: as an inset the runway lives OUTSIDE the scrollable content,
        // so there is nothing there for the scroll view to scroll away.
        //
        // As content it was stealable, and got stolen intermittently. A LazyVStack's
        // content height keeps settling for a second or so after the list opens (rows
        // materialise and re-measure: 1688 → 1697 → 1703 → 1730pt in a measured
        // trace), and on every content-size change SwiftUI re-anchors the scroll to
        // the first *item*. Padding is not an item, so the anchor snapped row 0 to the
        // very top of the viewport — the offset jumped 0 → 66 in a single frame, with
        // no scroll gesture anywhere near it — and the top rows came to rest under the
        // "Type anything…" header. Whether it hit depended on whether one of those
        // height changes happened to land while the list sat still, which is exactly
        // why it looked random. Rows still scroll under the header as before: the
        // inset moves where the content RESTS, not how far it can travel.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: immersive ? immersiveTopReach : 0)
        }
        // Immersive: a tall surface that fills the whole panel; the manage bar floats
        // over its bottom-left. Compact: ~6 rows before the list scrolls, so a short
        // Recent list doesn't reserve a tall empty band. Older rows are a scroll away.
        .frame(maxHeight: immersive ? Self.immersiveListHeight : compactListHeight)
        .scrollIndicators(.never)
        // BOTH edges taper in either layout — the top dissolves rows sliding up under
        // the header (immersive: the floating input), the bottom dissolves rows sliding
        // DOWN behind the floating manage bar (so reaching the end reads as rows sliding
        // under the ⋯ chip, mirroring the top). Each edge's taper length tracks its own
        // runway (`immersiveTopReach` / `immersiveBottomReach`; compact: `compactTopFade`
        // / `edgeFade`), and the compact top only arms once the list actually overflows.
        .scrollEdgeFade(
            top: immersive ? true : overflowing,
            bottom: immersive ? true : overflowing,
            topFade: immersive ? immersiveTopReach : compactTopFade,
            bottomFade: immersive ? immersiveBottomReach : edgeFade
        )
        // Immersive only: frost the rows as they scroll UP into the runway behind the
        // floating input, so they read as pushed back — present but soft — not
        // hard-clipped. The band is kept SHORTER than the runway (`immersiveBlurReach`
        // < `immersiveTopReach`) so it tapers out before the first resting row: idle
        // rows stay crisp (no blurred-glyph halo), only rows travelling up under
        // "Type anything…" frost. Decoupled from `immersiveTopReach` (which is layout:
        // where rows rest) so tuning the blur never shifts the list. Glass translucency
        // is untouched — this only softens focus, never darkens.
        .modifier(ConditionalTopBlur(active: immersive, height: immersiveBlurReach, maxRadius: 36))
        // Immersive only: the mirror at the BOTTOM — frost rows scrolling DOWN into
        // the runway behind the manage bar, so they dissolve under the buttons the
        // same way the top dissolves them under the input. Band kept shorter than the
        // bottom runway (`immersiveBottomBlurReach` < `immersiveBottomReach`) so it
        // clears the last resting row (no halo at rest). A lighter peak radius than
        // the top (the bar is shorter than the input header, so less depth to hide).
        .modifier(ConditionalBottomBlur(active: immersive, height: immersiveBottomBlurReach, maxRadius: 22))
        // Keep the keyboard-highlighted row visible: stepping ↓/↑ past the visible
        // window would otherwise leave the selection offscreen. Mirrors the
        // streaming tail-follow in `conversationScroll` — a reactive scroll in its
        // OWN transaction, separate from the highlight mutation, so SwiftUI doesn't
        // silently drop the `scrollTo` mid-reconciliation.
        .onChange(of: model.highlightedHistoryIndex) { _, newIndex in
            guard let i = newIndex, model.recentVisible.indices.contains(i) else { return }
            let id = model.recentVisible[i].id
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        }
    }

    // MARK: - Load

    private var loadView: some View {
        VStack(alignment: .leading, spacing: 0) {
            resultHeader
            // No drawn rule here — the gap alone separates the chevron from the
            // content below. Roughly the rhythm the old Divider held (its 9pt
            // top/bottom pad plus the hairline) so the spacing reads the same.
            Spacer().frame(height: 18)
            // Text-only wait line — no animated dots. Before any tool runs the
            // status is empty, so fall back to the rotating mood word — the same
            // opening a follow-up turn shows — instead of a static "Thinking…"
            // (the first question and a follow-up used to start differently for
            // no reason). The elapsed suffix is a sibling, not part of the
            // dissolving word, so the ticking seconds never ride the word swap.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                let label = model.thinkingStatus.isEmpty ? model.currentThinkingWord : model.thinkingStatus
                ThinkingOrb(state: model.thinkingOrbState)
                    .centeredOnTextGlyphs(fontSize: 15)
                // Word and timer share ONE baseline — centering text of two
                // different sizes floats the smaller suffix ~0.5pt high. Same
                // pairing as `AssistantTurnView.waitRow`, so the pre-answer wait
                // and the mid-answer one read identically.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    CrossfadeText(text: label, font: 15, color: Tokens.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    WaitElapsedSuffix(since: model.thinkingStartedAt, font: 15)
                        .fixedSize()
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Result

    /// The tallest the answer area is ever allowed to grow. Short answers size to
    /// their own content (below this); only long ones clip + scroll at the ceiling.
    /// This value is ALSO the threshold that flips `isAnswerClipped` — do NOT change
    /// it to match the clipped frame height; those are intentionally different.
    private let answerMaxHeight: CGFloat = 300

    /// Fixed frame height for `clippedConversation` when the follow-up input floats
    /// over its bottom. = answerMaxHeight (300) + the .padding(.top, 24) gap that
    /// today separates the scroll from the follow-up row (24) + followUpRow's own
    /// rendered height (27pt content + 6+6 vertical padding = 39pt) = 363pt.
    /// Absorbing those 63pt into the scroll frame keeps `resultView`'s total height
    /// identical to today — the panel never resizes at the short↔long crossover,
    /// which also keeps the source-popup y-offset formula (`rect.minY - geo.size.height`)
    /// correct without needing to account for the shift.
    private let clippedAnswerMaxHeight: CGFloat = 363

    /// Height of the floating header block the clipped thread reaches UP behind:
    /// the 26pt back/pin row plus the 18pt gap the short layout keeps below it.
    /// When clipped, that block leaves the VStack flow and floats over the scroll's
    /// top, and the scroll frame grows by exactly this much — so the panel's total
    /// height never changes at the crossover, and the header renders at the same
    /// spot in both layouts. It doubles as the top runway: the fade taper length
    /// and the first row's resting inset when scrolled fully up (the result-view
    /// mirror of `immersiveTopReach`).
    private let resultHeaderReach: CGFloat = 44

    /// Height of the top frost band — kept 4pt SHORTER than the top runway, the
    /// same convention as `immersiveBlurReach` / `clippedBottomBlurReach`, so the
    /// band tapers fully to clear at the runway's lower edge. Text scrolling up
    /// behind the back/pin chrome frosts + fades on its way out instead of ending
    /// on a hard cut under the header.
    private var clippedTopBlurReach: CGFloat { max(resultHeaderReach - 4, 0) }

    /// Bottom runway inside `clippedConversation`: empty scroll space the last turn
    /// scrolls DOWN into, behind the floating follow-up input. = followUpRow box
    /// height (39pt) + dissolve headroom above the box top (41pt) = 80pt. It lives
    /// ABOVE the `scrollBottomID` anchor in the VStack (not in `.padding(.bottom)`),
    /// so `scrollTo(anchor:.bottom)` pins the anchor's bottom to the viewport bottom
    /// while the last real turn rests ~82pt above it — 31pt above the input's top
    /// edge, entirely within the dissolve zone.
    private let clippedBottomRunway: CGFloat = 80

    /// Height of the bottom blur band — kept 4pt SHORTER than the runway so the band
    /// tapers fully to clear before it touches the last resting row (mirrors the
    /// `immersiveBottomBlurReach = immersiveBottomReach - 4` convention). At idle the
    /// last row sits ~82pt above the viewport bottom and the band reaches 76pt up —
    /// 6pt of clearance, so nothing haloes at rest.
    private var clippedBottomBlurReach: CGFloat { max(clippedBottomRunway - 4, 0) }

    /// True when the thread's intrinsic height exceeds `answerMaxHeight` and the
    /// clipped+scrolling layout is active. Derived from the same @State that
    /// `conversationScroll` already reads — promoted here so `resultView`, `body`,
    /// and `conversationScroll` all share the identical boolean without duplication.
    private var isAnswerClipped: Bool { measuredAnswerHeight > answerMaxHeight }

    /// True while the follow-up input is folded into a glyph on the header's glass
    /// pill — a thread the user landed on by hitting a prompt shortcut on a
    /// selection (translate this, explain this), where the answer is the whole
    /// point and a standing composer is just a row of empty height. One tap on the
    /// pill's speech-bubble unfolds the real field
    /// (`followUpExpanded`), and typing a line at all retires the fold for good
    /// (`NotchModel.submit` clears `fromPromptShortcut`).
    private var followUpIsFolded: Bool {
        model.fromPromptShortcut && !followUpExpanded && !model.hasText
            && model.visibleAskError == nil && model.isConfigured
    }

    private var resultView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Short layout only: the header sits as a sibling above the thread.
            // When clipped, it FLOATS over the scroll's top instead (the overlay on
            // the ZStack below), so the thread can travel up behind it and dissolve
            // — mirroring how the immersive recent list runs under the input header.
            if !isAnswerClipped {
                resultHeader
                // No drawn rule between the chevron and the thread — a quiet gap does
                // the separating instead. Matches the rhythm the old Divider held (its
                // 9pt top/bottom pad plus the hairline) so the layout doesn't shift.
                Spacer().frame(height: 18)
            }

            // When the answer is clipped (long, scrolling), the follow-up input
            // FLOATS over the scroll's bottom (ZStack child, alignment .bottom)
            // rather than sitting as a VStack sibling below — so content scrolls
            // down behind it and dissolves (fade + blur), mirroring the recent list
            // behind the manage bar. The scroll frame is `clippedAnswerMaxHeight`
            // (363 = 300 + the 24pt gap + the 39pt input that the sibling layout
            // used), so the resultView's total height is identical in both layouts
            // — the panel never resizes at the crossover, which also keeps the
            // source-popup y-offset (`rect.minY - geo.size.height`) correct.
            //
            // When short (not clipped), the ZStack just wraps `conversationScroll`
            // transparently (one child → passthrough size) and the input renders as
            // a sibling below, exactly as before. The AnswerHeightKey probe lives in
            // `conversationScroll`'s .background and is always mounted regardless.
            ZStack(alignment: .bottom) {
                conversationScroll

                // Floating follow-up: only the clipped + configured + no-error case.
                // Error / unconfigured states keep their rows as siblings below (an
                // actionable error must never be hidden behind the scroll). A folded
                // shortcut thread renders no composer at all here — its entry is the
                // glyph on the header's glass pill (see `resultHeader`).
                if isAnswerClipped && !followUpIsFolded
                    && model.visibleAskError == nil && model.isConfigured {
                    followUpRow
                        // Lift off the viewport bottom so a sliver of dissolved
                        // content shows beneath the box rather than it sitting flush.
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
            }
            // Clipped layout: the header floats over the scroll's TOP as fixed
            // chrome (no background of its own — legibility of the text passing
            // behind comes from the thread's top fade + frost, exactly like the
            // immersive input header). The scroll frame absorbed the header block's
            // 44pt (see `resultHeaderReach`), so the panel height is unchanged and
            // the header renders at the same spot as the sibling it replaces.
            .overlay(alignment: .top) {
                if isAnswerClipped {
                    resultHeader
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 1.0), value: isAnswerClipped)

            // Row slot BELOW the ZStack. The error / "set up a model" rows always
            // live here as siblings (in both layouts) so they push the panel taller
            // when they appear — intentional, an actionable row must stay visible.
            // The normal follow-up input renders here ONLY in the short layout; when
            // clipped it floats inside the ZStack above and must NOT also render here
            // (two NSTextFields would fight for first-responder).
            //
            // An agent run the app died in the middle of gets its own actionable
            // capsule under the answer: one tap re-issues the cut-off round in the
            // CLI session it left behind. It sits ABOVE the follow-up input, which
            // still does its usual thing (ask the chat model about this thread).
            if let resume = model.openAgentResume {
                agentResumeRow(engine: resume.engine, resume: resume.resume)
                    .padding(.top, isAnswerClipped ? 8 : 24)
                    .transition(.opacity)
            }

            // A failed Ask gets an actionable capsule right under the answer (XII-85):
            // "Open Settings" when there's no key to retry with, "Try again" otherwise.
            // Scoped to the round that failed (`visibleAskError`) — a failure in one
            // conversation must not replace another conversation's follow-up input.
            if let askError = model.visibleAskError {
                errorActionRow(askError)
                    .padding(.top, isAnswerClipped ? 8 : 24)
                    .transition(.opacity)
            } else if !isAnswerClipped && !followUpIsFolded {
                // Short layout: follow-up input (or setup CTA) as a sibling, as before.
                // (Folded shortcut button excluded — it floats inside the ZStack so
                // it never pushes the panel taller.)
                Group {
                    if model.isConfigured {
                        followUpRow
                    } else {
                        setupModelRow
                    }
                }
                // The resume capsule already spends the 24pt gap under the answer;
                // the input just needs to clear the capsule, not repeat that gap.
                .padding(.top, model.openAgentResume == nil ? 24 : 10)
                .transition(.opacity)
            } else if !model.isConfigured {
                // Clipped + unconfigured: the setup CTA stays a sibling (it's a
                // one-time prompt, not the live input, so floating it makes no sense).
                setupModelRow
                    .padding(.top, 8)
                    .transition(.opacity)
            }
            // (Clipped + configured + no error: followUpRow is inside the ZStack;
            //  nothing renders here — the gap+row were absorbed into the scroll frame.)

            // Note/Reminder save feedback for lines filed FROM the result view (now
            // that the follow-up field routes by intent). The idle prompt shows this
            // same calm cue via `noteFeedbackContent`, but that path never renders in
            // `.result` — so mirror it here: "Saving…" in flight, then the model's
            // "Added to Reminders · Daily" / "Added to Notes" cue, which the model
            // auto-clears after ~1.7s. The error slot above owns the failure case.
            if model.noteSaving {
                feedbackLine(L("input.saving"))
                    .padding(.top, 6)
                    .transition(.opacity)
            } else if let cue = model.lastSavedNote {
                feedbackLine(cue)
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        }
        // The short↔long crossover moves the follow-up between sibling and overlay;
        // animate the sibling-slot changes on the same spring the ZStack uses so the
        // whole transition reads as one motion.
        .animation(.spring(response: 0.3, dampingFraction: 1.0), value: isAnswerClipped)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.lastSavedNote)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.noteSaving)
        // Float the source popup here, at the result-view level — OUTSIDE the
        // conversation ScrollView — so it's never clipped by the scroll's height
        // (which was chopping the popup's top off, XII-118). The hovered badge
        // publishes its frame via `SourcePopoverKey`; we resolve it in this view's
        // coordinate space and place the panel just ABOVE the badge, clamped to the
        // left edge so a badge near the right doesn't push it off-screen.
        .overlayPreferenceValue(SourcePopoverKey.self) { request in
            GeometryReader { geo in
                if let request {
                    let rect = geo[request.anchor]
                    SourcePopoverPanel(
                        sources: request.sources,
                        keepOpen: {
                            // Cursor reached the panel — cancel the pending close
                            // and keep this badge open.
                            sourceCloseWork?.cancel()
                            sourceCloseWork = nil
                            hoveredSourceID = request.id
                        },
                        dismiss: {
                            // Left the panel — close after the same grace period so
                            // a slip back toward the pill doesn't flicker it shut.
                            sourceCloseWork?.cancel()
                            let work = DispatchWorkItem {
                                if hoveredSourceID == request.id { hoveredSourceID = nil }
                            }
                            sourceCloseWork = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
                        }
                    )
                    // Horizontal fixed (the panel sets its own 380pt width); leave
                    // vertical flexible so the panel's own maxHeight cap applies and
                    // overflowing rows scroll instead of growing the card.
                    .fixedSize(horizontal: true, vertical: false)
                    // Anchor the panel's BOTTOM-leading right at the badge's top,
                    // so it pops up over the answer. `.bottomLeading` alignment +
                    // an offset of (badge.minX, badge.minY) positions the panel's
                    // bottom-left at the badge's top-left. No visual gap is
                    // subtracted here: the panel carries its own transparent
                    // `bridgeGap` strip at its bottom (see `SourcePopoverPanel`),
                    // which spans the gap as a continuous hover region so the
                    // pill → panel crossing never falls into a dead zone.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .offset(x: max(0, rect.minX),
                            y: rect.minY - geo.size.height)
                    .transition(.opacity)
                }
            }
            .allowsHitTesting(request != nil)
            .animation(.easeInOut(duration: 0.16), value: request)
        }
    }

    /// Stand-in for the follow-up field while on the offline stub: a full-width
    /// button that opens Settings (same path as the gear / ⌘,) so the user can
    /// paste an API key and get live answers. Styled like the follow-up box it
    /// replaces, so the result view's footprint doesn't jump.
    private var setupModelRow: some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                model.openSettings()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.sf(13, weight: .medium))
                Text(L("result.setUpModel"))
                    .font(.sf(14.5, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.sf(11, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
            }
            .foregroundStyle(Tokens.text1)
            .padding(.leading, 13)
            .padding(.trailing, 12)
            .frame(height: 39)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SetupModelButtonStyle())
    }

    /// The resume footer under an interrupted agent run's answer — the GUI half of
    /// `AgentEngine.resumeCommand`. One tap hands the round the app died in the
    /// middle of straight back to the CLI session it left behind; the run picks up
    /// as a live task and re-files this same Recent row when it settles. Styled as
    /// the same full-width capsule the failed-Ask footer uses.
    ///
    /// The engine can be gone by now (uninstalled since the run), and then there's
    /// nothing to press — so the row degrades to naming the terminal command, which
    /// is exactly what the answer text used to carry.
    @ViewBuilder
    private func agentResumeRow(engine: AgentEngine,
                                resume: NotchModel.HistoryItem.AgentResume) -> some View {
        if engine.isAvailable {
            Button {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    model.resumeAgentThread()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.sf(13, weight: .medium))
                    Text(L("agent.resume", engine.displayName))
                        .font(.sf(14.5, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.sf(11, weight: .semibold))
                        .foregroundStyle(Tokens.text3)
                }
                .foregroundStyle(Tokens.text1)
                .padding(.leading, 13)
                .padding(.trailing, 12)
                .frame(height: 39)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SetupModelButtonStyle())
        } else {
            Text(L("agent.interrupted.resume",
                   engine.resumeCommand(session: resume.session)))
                .font(.sf(11.5))
                .monospaced()
                .foregroundStyle(Tokens.text4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The actionable error footer for a failed Ask (XII-85): a full-width capsule —
    /// "Open Settings" when no key is configured (retrying can't help), else
    /// "Try again", which re-runs the same question. Styled like `setupModelRow` so
    /// the result view's footprint doesn't jump between the two.
    private func errorActionRow(_ askError: NotchModel.AskError) -> some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                if askError.needsSetup {
                    model.openSettings()
                } else {
                    model.retryLastAsk()
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: askError.needsSetup ? "slider.horizontal.3" : "arrow.clockwise")
                    .font(.sf(13, weight: .medium))
                Text(askError.needsSetup ? L("error.openSettings") : L("error.retry"))
                    .font(.sf(14.5, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: askError.needsSetup ? "arrow.up.right" : "chevron.right")
                    .font(.sf(11, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
            }
            .foregroundStyle(Tokens.text1)
            .padding(.leading, 13)
            .padding(.trailing, 12)
            .frame(height: 39)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SetupModelButtonStyle())
    }

    /// The whole conversation, scrolling: every user/assistant turn stacked, the
    /// newest at the bottom. Sizes to its content up to `answerMaxHeight`, then
    /// clips + scrolls; a `ScrollViewReader` keeps the latest turn pinned in view
    /// as a follow-up streams in. The bottom fade is the "more below" cue.
    private var conversationScroll: some View {
        let clipped = isAnswerClipped
        return Group {
            if clipped {
                clippedConversation
            } else {
                // Unclipped, the thread IS its intrinsic height — this layout has
                // no ceiling anywhere (see `growingConversation`) — so the visible
                // tree doubles as the measurement and the hidden probe below stays
                // unmounted. This is the common case (most answers fit under
                // `answerMaxHeight`), and it used to pay a second full text layout
                // of the whole thread on every streamed flush just to feed the
                // `clipped` switch a number the visible layout already knew.
                growingConversation
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: AnswerHeightKey.self, value: geo.size.height)
                        }
                    )
            }
        }
        // Measure the thread's INTRINSIC height — what it wants to be with no ceiling
        // — to drive ONLY the `clipped` switch above. While unclipped the visible
        // layout reports it directly (above). Once CLIPPED the visible layout is
        // pinned to `answerMaxHeight` (300), so measuring it would report 300, which
        // isn't > 300, and `clipped` would flip-flop on the boundary — that state
        // needs the hidden, unconstrained copy of the turn stack below. It's laid
        // out but never drawn (`.hidden()`), and overlaid at zero size so it never
        // affects this view's layout. The measurement lagging the content by a pass
        // is harmless — it feeds a boolean threshold, not a frame height.
        .background(alignment: .top) {
            // Mounted only while clipped AND settled. While a clipped thread still
            // STREAMS the probe stays down: within one round the content only
            // grows, so once past the ceiling it can't change the layout decision —
            // it would only double every flush's text-layout work feeding a boolean
            // that's already true. It mounts when the stream settles, so the next
            // content change that CAN shrink the thread (a regenerate replacing a
            // long answer, opening a shorter history thread) re-measures as before.
            if clipped && !model.isStreaming {
                growingConversation
                    // Take the thread's full intrinsic height regardless of the height
                    // this background slot proposes (300 when the visible layout is the
                    // clipped scroller) — otherwise the probe would cap at 300 and the
                    // `clipped` switch couldn't tell 300 from 1000, so it'd flip-flop on
                    // the boundary. `fixedSize(vertical:)` makes it report its true height.
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .allowsHitTesting(false)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: AnswerHeightKey.self, value: geo.size.height)
                        }
                    )
            }
        }
        .onPreferenceChange(AnswerHeightKey.self) {
            // 0 means "the probe is unmounted" (suspended above, or a transient
            // empty pass) — never "the content shrank to nothing". Keep the last
            // real measurement so the clipped layout holds while suspended.
            guard $0 > 0 else { return }
            measuredAnswerHeight = $0
            // Mirror to the model (a plain var — no invalidation) so `fullClose`
            // can park the measurement with the session; the next mount seeds its
            // layout decision from it (see `init`).
            model.lastMeasuredAnswerHeight = $0
        }
        // The ONE place a height change is animated: the cross-over between the two
        // layouts (a short answer growing past the 300pt ceiling into the clipped
        // scroller). Critically damped (1.0) so it settles without the overshoot that
        // produced the per-line bounce; short so it stays tight. Within a single
        // layout there's no `.frame(height:)` to animate, so day-to-day streaming
        // growth carries no animation here at all — it just reflows.
        .animation(.spring(response: 0.3, dampingFraction: 1.0), value: clipped)
    }

    /// Short-answer layout: the thread sizes to its own content, NO ScrollView, NO
    /// fixed frame height. New lines extend the stack in the same layout pass they
    /// land — the height *is* the content height, so there's nothing lagging behind
    /// to jump. This is the common case (most answers fit under `answerMaxHeight`).
    private var growingConversation: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(model.turns.filter { !$0.hidesUserBubble }) { turn in
                turnView(turn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(turn.id)
            }
        }
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Long-answer layout: once the thread outgrows `answerMaxHeight` it pins to
    /// `clippedAnswerMaxHeight` (363pt) and scrolls, with the follow-up input floating
    /// over the bottom. The taller frame absorbs the 24pt gap + 39pt input the sibling
    /// layout used, so the panel's total height is unchanged at the crossover.
    ///
    /// **Tail-follow geometry (why the runway sits ABOVE the anchor):**
    /// `scrollTo(scrollBottomID, anchor: .bottom)` aligns the anchor's BOTTOM edge with
    /// the viewport's bottom. If the runway were `.padding(.bottom)` (below the anchor),
    /// the anchor would land at the viewport bottom and the last turn would sit right
    /// at the bottom — hidden behind the floating input. Instead the runway is a Spacer
    /// placed IN the VStack ABOVE the anchor:
    ///     [last turn] [Spacer 80pt] [Color.clear 2pt .id(scrollBottomID)]
    /// so `anchor:.bottom` puts the anchor at the viewport bottom, the 80pt runway sits
    /// just above it, and the last turn rests ~82pt above the viewport bottom — 31pt
    /// above the input's top edge, entirely in the dissolve zone.
    private var clippedConversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.turns.filter { !$0.hidesUserBubble }) { turn in
                        turnView(turn)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(turn.id)
                    }
                    // The bottom runway: empty scroll space the last turn slides DOWN
                    // into behind the floating follow-up input. Positioned HERE — above
                    // the anchor — so `scrollTo(anchor:.bottom)` leaves the last turn
                    // ~82pt above the viewport bottom (see the doc comment's geometry).
                    Spacer(minLength: 0)
                        .frame(height: clippedBottomRunway)
                    // The anchor the reader scrolls to so new turns always land in view.
                    // Sits at the very end of the runway, so anchor:.bottom clears the
                    // runway above it for the dissolve.
                    Color.clear.frame(height: 2).id(scrollBottomID)
                }
                .padding(.trailing, 8)
                // Top runway: the inset the first line rests at when scrolled fully
                // up, sized to the floating header block (`resultHeaderReach`) so it
                // sits just clear of the back/pin chrome — and the space mid-thread
                // text travels up into, dissolving (fade + frost) behind the header
                // instead of hard-cutting below it. The bottom has its own runway
                // Spacer inside the VStack (above), so no .padding(.bottom) is needed.
                .padding(.top, resultHeaderReach)
            }
            // Taller than `answerMaxHeight` (300): absorbs the 24pt gap + 39pt
            // follow-up row that no longer sit as VStack siblings, PLUS the floating
            // header block (`resultHeaderReach`, 44pt) the clipped layout lifts out
            // of the VStack flow — keeping the panel the same total height. The
            // `isAnswerClipped` threshold stays at 300.
            .frame(height: clippedAnswerMaxHeight + resultHeaderReach)
            .scrollIndicators(.never)
            // Submitting a follow-up appends two turns and flips mode
            // result→load→result, which rebuilds the ScrollView and resets its
            // offset to the top. Snap straight back to the bottom (no animation) so
            // there's no visible jump up — the streaming tail-follow below is what
            // gets the smooth motion.
            .onChange(of: model.turns.count) { _, _ in
                proxy.scrollTo(scrollBottomID, anchor: .bottom)
            }
            // Follow the tail smoothly as the answer streams in, so the freshest
            // text stays in view without the user scrolling by hand.
            .onChange(of: model.turns.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(scrollBottomID, anchor: .bottom)
                }
            }
            // Entering the clipped layout (just crossed the ceiling) lands at the top
            // by default; pin to the bottom so the newest text stays in view.
            .onAppear { proxy.scrollTo(scrollBottomID, anchor: .bottom) }
        }
        // Per-edge fades: each taper tracks its own runway. The top matches the
        // floating header block (`resultHeaderReach`, 44pt) so text dissolves to
        // nothing across the back/pin zone; the bottom matches its runway (80pt)
        // so the taper falls entirely across the empty space above the input box.
        .scrollEdgeFade(top: true, bottom: true, topFade: resultHeaderReach, bottomFade: clippedBottomRunway)
        // Progressive blur on the top runway, mirroring the immersive input header:
        // text scrolling up behind the back/pin chrome frosts out as it goes, so the
        // header zone reads as one continuous surface, not a hard cut. Band kept 4pt
        // shorter than the runway (`clippedTopBlurReach` = 40pt); maxRadius 22
        // matches the bottom band (comparably thin chrome, unlike the deep 36 the
        // immersive input header needs).
        //
        // Both bands rest while the answer is still STREAMING: each is a full
        // `drawingGroup`-flattened copy of the scroll viewport, re-rasterized
        // whenever its content changes — and a streaming thread changes on every
        // ~33ms flush AND every frame of the tail-follow scroll, so the two frost
        // copies were the bulk of the per-update render cost of a long answer.
        // The `scrollEdgeFade` opacity taper above stays on throughout, so text
        // still dissolves at both runways; the frost simply joins when the stream
        // settles and the content goes static.
        .modifier(ConditionalTopBlur(active: !model.isStreaming, height: clippedTopBlurReach, maxRadius: 22))
        // Progressive blur on the bottom runway, mirroring the immersive manage bar's
        // ConditionalBottomBlur: rows scrolling down into the runway frost out as they
        // go behind the input. Kept 4pt shorter than the runway (`clippedBottomBlurReach`
        // = 76pt) so the band clears the last resting row (~82pt up) — no halo at rest.
        // maxRadius 22 matches the manage bar (comparable chrome). Active whenever the
        // answer is settled — clippedConversation is only ever mounted when
        // `isAnswerClipped` — and resting during the stream, same as the top band.
        .modifier(ConditionalBottomBlur(active: !model.isStreaming, height: clippedBottomBlurReach, maxRadius: 22))
    }

    /// Height of the taper at each scroll edge, in points. Generous on purpose so
    /// the dissolve is a long, gentle gradient — not a thin line that still reads
    /// as a cut. The scroll content carries matching top/bottom padding, so the
    /// fade falls across that breathing room rather than over live text.
    private let edgeFade: CGFloat = 64

    /// The compact RECENT list's TOP taper — deliberately shorter than `edgeFade`.
    /// The compact list is only ~6 rows tall, so mirroring the full 64pt reserve up
    /// top would spend two rows of the viewport on empty runway. This is just enough
    /// to swallow a row on its way out under the RECENT header instead of cutting it
    /// mid-glyph, and the scroll content carries a matching top inset so the first
    /// row still rests below the gradient at full strength.
    private let compactTopFade: CGFloat = 24

    /// Stable id for the invisible spacer at the very bottom of the thread; the
    /// `ScrollViewReader` scrolls to it to keep the newest text in view.
    private let scrollBottomID = "conversation-bottom"

    /// One bubble in the thread. A user turn reads as a quiet, dimmer line tagged
    /// "You"; an assistant turn renders full markdown at body weight. A streaming
    /// assistant turn with no text yet shows the thinking dots, so the wait reads
    /// the same in a follow-up as it does on the first question.
    @ViewBuilder
    private func turnView(_ turn: NotchModel.Turn) -> some View {
        if turn.role == "user" {
            VStack(alignment: .leading, spacing: 5) {
                // Permanent clipboard trace: when this question's message was enriched
                // with what the user copied, a quiet line says so — sitting right above
                // the question bubble and staying for the life of the answer (unlike the
                // load-only "Using clipboard" cue). Indented to line up with the bubble's
                // text inset so it reads as a caption on this turn. `paperclip`-free on
                // purpose: one small grey line, same whisper as the note-save cue.
                // An image the turn rode in with outranks that line: the picture IS
                // the trace, and says what "based on what you copied" only describes.
                // Persisted with the thread, so a row reopened from Recent shows the
                // same screenshot the question was asked about.
                if !turn.imageFiles.isEmpty {
                    SavedTurnImages(files: turn.imageFiles)
                        .padding(.leading, 12)   // matches the bubble's horizontal inset
                } else if turn.usedClipboard {
                    Text(L("result.basedOnCopied"))
                        .font(.sf(11))
                        .tracking(0.2)
                        .foregroundStyle(Tokens.text4)
                        .padding(.leading, 12)   // matches the bubble's horizontal inset
                }
                // The user's question rides in a quiet chat bubble — a barely-there
                // tint with a hairline border — instead of a "You" label. The bubble
                // itself says "this is what you asked", so no tag is needed and the
                // thread reads cleaner. It hugs its content (not full width) and
                // left-aligns with the answer below.
                UserQuestionBubble(text: turn.text)
            }
        } else {
            // Assistant turn — streaming AND settled share ONE view tree, so the
            // moment the stream ends there's no structural swap to a different
            // renderer (that swap is what hard-cut the answer ~2pt up-left at
            // completion — the "突然跳掉位移"). `AssistantTurnView` always lays the
            // answer out through the same `MarkdownBlocks`, and only fades a
            // thinking/activity overlay on top while the text is still empty; the
            // overlay never participates in the answer's layout, so it can't shift
            // it, and `textSelection` just toggles on the unchanged tree.
            // Footer actions that only make sense at the thread's tail: regenerate
            // re-runs THIS question (and would orphan any later turns), and the
            // ChatGPT/Claude handoff always copies the whole thread — so both ride
            // only the last turn's footer, never mid-thread ones.
            let isLastTurn = model.turns.last?.id == turn.id
            // An agent run's report never offers regenerate: the chat model can't
            // re-run the task in its folder, so "regenerating" it would only
            // hallucinate a fresh report over the real one. (Chat follow-ups on
            // the same reopened thread aren't agent turns, so they keep it.)
            let canRegenerate = isLastTurn && !turn.isAgent
            VStack(alignment: .leading, spacing: 14) {
                // An agent answer carries its round's work trail above the report —
                // the record's copy of the live detail page, so a reopened run
                // reads the way the run looked while it worked.
                if turn.isAgent,
                   let trail = turn.agentLog?.droppingTrailingAnswer(turn.text),
                   !trail.isEmpty {
                    AgentWorkTrailView(entries: trail)
                }
                AssistantTurnView(
                    text: turn.text,
                    streaming: turn.streaming,
                    activity: turn.streaming ? model.currentActivity : nil,
                    orbState: turn.streaming ? model.thinkingOrbState : .composing,
                    thinkingWord: model.currentThinkingWord,
                    thinkingSince: turn.streaming ? model.thinkingStartedAt : nil,
                    sources: turn.sources,
                    hoveredSourceID: $hoveredSourceID,
                    sourceCloseWork: $sourceCloseWork,
                    isAgent: turn.isAgent,
                    // The record's completion time, shown as the report footer's
                    // stamp — only on the last agent turn, so the single stored
                    // timestamp maps to exactly one report (a follow-up chat turn,
                    // being non-agent, never carries it).
                    completedAt: (turn.isAgent && isLastTurn) ? model.currentThreadCompletedAt : nil,
                    onInAppCopy: { model.rebaselineClipboardAfterInAppWrite() },
                    onRegenerate: canRegenerate ? { model.regenerateLastAnswer() } : nil,
                    // Right-click the regenerate button to re-run this answer with a
                    // different model, once (XII-135). Only on the last turn (same gate
                    // as plain regenerate).
                    regenerateModels: canRegenerate ? model.regenerateModelOptions : [],
                    onRegenerateWith: canRegenerate ? { model.regenerateLastAnswer(model: $0) } : nil,
                    regenModel: turn.regenModel,
                    answerModel: turn.answerModel,
                    // The `ask_user` question card, when the model has paused this
                    // still-streaming answer on a choice only the user can make.
                    pendingQuestion: turn.streaming ? model.pendingQuestion(for: turn.id) : nil,
                    onChooseOption: { questionID, option in
                        model.chooseUserOption(option, questionID: questionID)
                    }
                )
            }
        }
    }

    // Back chevron leads (the question itself is the "You" turn below, so no title
    // here); a pin button trails top-right. Pinning holds the panel open when the
    // pointer leaves, so the answer can be read without hovering it (see
    // `NotchModel.collapseOnLeave`).
    /// Whether the result header's trailing chips (follow-up / detach / pin) are
    /// showing: only under the pointer, or while the answer is pinned — see the
    /// note at their use site.
    private var headerChipsShown: Bool { model.pointerInside || model.isAnswerPinned }

    private var resultHeader: some View {
        HStack(spacing: 10) {
            backButton
            Spacer(minLength: 0)
            // A folded shortcut thread's follow-up entry: its own module, set
            // apart from the detach/pin pair by the header's wider 10pt gap.
            // Same species (one-segment `GlassSegmentCluster`), separate group —
            // it's a composer, not a view action, so it doesn't join their pair.
            Group {
                if followUpIsFolded {
                    followUpChip
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                ResultTrailingCluster(
                    pinned: model.isAnswerPinned,
                    togglePin: {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            model.toggleAnswerPin()
                        }
                    },
                    detach: { model.openDetachedWindow() }
                )
            }
            // These are buttons sitting on the header's tear-off grip, which pushes
            // the open-hand cursor for the whole strip — take the plain arrow back
            // over the glyphs so they say "click" rather than "pull".
            .arrowCursor()
            // Hover-only chrome: at rest the header carries nothing but the back
            // chevron, so an answer read from across the desk is just the answer.
            // The chips fade in the moment the pointer is on the island and fade
            // back out when it leaves. They keep their slot either way (opacity,
            // not removal), so nothing shifts as they appear.
            // A PINNED answer is the exception — the tack is the only thing saying
            // "this is staying open", and it earns its place with the pointer away.
            .opacity(headerChipsShown ? 1 : 0)
            .allowsHitTesting(headerChipsShown)
            .animation(.easeOut(duration: Tokens.hoverFade), value: headerChipsShown)
        }
        // The header's free strip doubles as the tear-off grip: drag the thread
        // out of the notch and it splits into its own window (see
        // `NotchModel.detachDragChanged`). Buttons keep their taps — the drag
        // only arms past its minimum distance — so the hand cursor covers the
        // whole strip, which is exactly how far the drag reaches.
        .contentShape(Rectangle())
        .grabCursor()
        .gesture(detachDragGesture)
    }

    /// The folded follow-up's entry point (shortcut threads only): one speech
    /// bubble in the header, standing apart from the detach/pin pair. Tapping it unfolds the real composer below, with the
    /// caret already in it.
    private var followUpChip: some View {
        GlassSegmentCluster(segments: [
            .init(tooltip: L("result.followUp"), action: {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    followUpExpanded = true
                }
                // The field mounts with this tap; give it the caret without a
                // second click (the same drop-then-raise the clipped crossover
                // uses).
                refocusInput()
            }) {
                Image(systemName: "bubble.left")
                    .font(.sf(12, weight: .semibold))
            }
        ], glass: false)
    }

    /// The tear-off drag: raw translation goes to the model, which arms the
    /// ghost card, stretches the membrane, and fires the split at the
    /// threshold. The gesture keeps delivering after the hand-off — the model
    /// ignores those ticks (`detachHandedOff`).
    private var detachDragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                model.detachDragChanged(value.translation)
            }
            .onEnded { _ in
                model.detachDragEnded()
            }
    }

    /// Back to a fresh conversation: clears this Q&A off the screen and returns to
    /// the idle prompt (panel stays open). Safe mid-answer — an in-flight stream
    /// finishes detached and lands in Recent (see `NotchModel.newChat`). Also bound
    /// to the ← arrow key (see ContentView's key handler), so a glance-and-go feels
    /// keyboard-native.
    private var backButton: some View {
        GlassBackButton {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                model.newChat()
            }
        }
    }

    // MARK: - Inputs

    /// The prompt's type size, and the follow-up field's — shared by the field, its
    /// inline hint and the row metrics, so a one-line box and its row agree.
    static let idleFontSize: CGFloat = 16.5
    static let followUpFontSize: CGFloat = 14.5
    /// How far a prompt grows before it stops growing and scrolls inside itself. A
    /// pasted paragraph unfolds the box downward — five lines of it — rather than
    /// scrolling off to the right where all but the tail is invisible.
    static let promptMaxLines = 5
    /// The idle row at rest: a one-line prompt in a 48pt row. As the box grows the
    /// row keeps exactly that breathing room above and below.
    static let idleRowHeight: CGFloat = 48
    private var idleRowVerticalPadding: CGFloat {
        NotchBody.idleRowHeight - PromptField.lineHeight(for: NotchBody.idleFontSize)
    }

    private func inputRow(placeholder: String, followUp: Bool) -> some View {
        let fontSize: CGFloat = followUp ? NotchBody.followUpFontSize : NotchBody.idleFontSize
        return HStack(spacing: 12) {
            // The field and its fading placeholder. Where Enter sends the line is
            // spelled out by the destination pill on the row below, not by anything
            // trailing the caret.
            ZStack(alignment: .leading) {
                PromptField(
                    text: $model.text,
                    // Idle prompt: the native NSTextField placeholder HARD-SWAPS
                    // (zero animation) — deleting the last character popped
                    // "Type anything…" in on a cut. Keep it empty and draw the
                    // placeholder as the SwiftUI label below, which fades — the
                    // same ownership trick `followUpRow` uses. The defensive
                    // followUp branch keeps the native one (that path is unused).
                    placeholder: followUp ? placeholder : "",
                    fontSize: fontSize,
                    focusTrigger: focused,
                    maxVisibleLines: NotchBody.promptMaxLines,
                    // Enter routes by intent (ask / note / remind) from the idle
                    // prompt. The real mid-thread field is `followUpRow`, which now
                    // also routes by intent; this `followUp` branch is only the
                    // defensive path if `inputRow` is ever reused with `followUp: true`,
                    // and it keeps the plain-ask behaviour for that unused case.
                    onSubmit: { followUp ? model.submit() : model.submitCurrent() },
                    // Idle prompt only: ↑/↓ are shared between shell-style recall
                    // (fill the box with a past question) and the recent list, with
                    // a fixed precedence — an open, highlighted list owns the keys;
                    // recall gets them otherwise. ↓ first steps a live recall back
                    // toward the newest (clearing past the newest), and only when no
                    // recall is in flight does it open/step the recent list. Enter
                    // opens a keyboard-highlighted row instead of submitting. The
                    // follow-up field leaves these at their no-op defaults.
                    onDown: followUp ? { false } : {
                        // An open `/` menu owns the arrows before anything else —
                        // they walk its rows.
                        if model.slashMenuStep(1) { return true }
                        if model.recallNextQuestion() { return true }
                        return withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                            model.historyNavigateDown()
                        }
                    },
                    // ↑ mirrors ↓'s split, list side first: while a recent row is
                    // keyboard-highlighted, ↑ steps the highlight up (and past the
                    // top row folds the list back to the input — the exact inverse
                    // of the ↓ that opened it). Only with no highlight to walk does
                    // ↑ fall through to shell-style recall.
                    onUp: followUp ? { false } : {
                        if model.slashMenuStep(-1) { return true }
                        let steppedList = withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                            model.historyNavigateUp()
                        }
                        if steppedList { return true }
                        return model.recallPreviousQuestion()
                    },
                    // Keep ↑/↓ routed to recall even after the box fills with a
                    // recalled question, so pressing ↑ again steps further back
                    // instead of moving the caret.
                    // While `/` has the menu up, ↑/↓ belong to its rows even
                    // though the field holds text.
                    isMenuOpen: followUp ? { false } : { model.slashMenuOpen },
                    isRecalling: followUp ? { false } : { model.isRecallingHistory },
                    onSubmitNav: followUp ? { false } : {
                        // Enter lands the highlighted `/` command — the word in the
                        // box IS the command, never a question to send.
                        if withAnimation(.spring(response: 0.34, dampingFraction: 0.82), {
                            model.confirmSlashCommand()
                        }) { return true }
                        // Otherwise Enter confirms a keyboard-highlighted Recent row,
                        // which short-circuits the empty submit.
                        return model.historyConfirmHighlighted()
                    },
                    // Tab steps where Enter sends this line (Ask → Note →
                    // Remind →…) when the classifier guessed wrong — the pill
                    // below steps with it. Agent is NOT a stop (the pill's other
                    // half owns that switch). It works on the EMPTY prompt too: the
                    // mode is picked before the line is typed, exactly like a `/`
                    // command, and the placeholder ("Write a note…") says which
                    // one is armed. Always consumed either way, so focus never
                    // wanders out of the prompt.
                    onTab: followUp ? { false } : {
                        guard let event = NSApp.currentEvent,
                              ReservedAppShortcut.cycleIntent.matches(event) else {
                            return false
                        }
                        // Tab picks the highlighted `/` row too — the completion
                        // key doing the completing, before the cycle gets a turn.
                        if withAnimation(.spring(response: 0.34, dampingFraction: 0.82), {
                            model.confirmSlashCommand()
                        }) { return true }
                        model.toggleSubmitPanel()
                        return true
                    },
                    // Shift-Tab flips the Ask ⇄ Agent bucket — the keyboard twin
                    // of the BucketTogglePill. Always consumed so focus never
                    // wanders out of the prompt; a no-op that stays on Ask when
                    // no agent CLI is installed.
                    onBackTab: followUp ? nil : {
                        guard let event = NSApp.currentEvent,
                              ReservedAppShortcut.bucket.matches(event) else {
                            return false
                        }
                        model.toggleAgentBucket()
                        return true
                    },
                    // ⌘V explicitly attaches a clipboard image to the current Ask
                    // or Agent compose. Ordinary text keeps the native paste path.
                    onPasteImage: followUp ? { false } : {
                        model.handleComposePasteImage()
                    },
                    // Live width of the last line's committed text + any composing
                    // pinyin — what the overlay placeholder watches so it clears the
                    // instant the editor shows anything. Only the idle prompt feeds
                    // this; `followUpRow` owns its own tracking.
                    onCaretWidth: followUp ? { _ in } : { caretWidth = $0 },
                    // The box's own height — one line, or as many as the text has
                    // wrapped to (capped). The row is built around it.
                    onHeightChange: followUp ? { _ in } : { inputHeight = $0 }
                )
                .frame(height: followUp ? nil : inputHeight)
                // No trailing ghost, and so no reserved strip beside the text: the
                // destination is spelled out in the pill below the field (see
                // `BucketTogglePill`), which leaves the line the full width of the
                // row to wrap into.

                // The placeholder, drawn as a SwiftUI label over the (natively
                // placeholder-less) field so its appearance can FADE — on emptying
                // the field the native swap was an instant pop. Gated on the caret
                // width, not just emptiness, so in-progress pinyin hides it too.
                // Emptiness is the RAW string, not `hasText` (which trims): a
                // ⇧⏎/⌥⏎ line break leaves text = "\n", which trims back to empty
                // and used to keep the ghost sitting on line 1 of a now-two-line
                // box. Anything at all in the editor takes the placeholder away.
                if !followUp && model.text.isEmpty && caretWidth == 0 {
                    Text(placeholder)
                        .font(.sf(fontSize))
                        .foregroundStyle(Tokens.placeholder)
                        .lineLimit(1)
                        // Sit on the box's own ~2pt left inset so the label lands
                        // exactly where the typed glyphs will.
                        .padding(.leading, PromptField.textInset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                } else if !followUp && model.slashMenuOpen && model.text == "/" {
                    // The bare "/" gets its own hint, parked right after the slash:
                    // the menu below already lists every command, so the one thing
                    // left to say is that typing narrows it. Gone the moment a
                    // letter lands — the filtering has begun; saying so is noise.
                    Text(L("slash.filter"))
                        .font(.sf(fontSize))
                        .foregroundStyle(Tokens.placeholder)
                        .lineLimit(1)
                        .padding(.leading, PromptField.textInset + caretWidth + 1)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            // Drives the placeholder fade in BOTH directions (first character in,
            // last character out — including pinyin pre-composition, which flips
            // `caretWidth` while `hasText` is still false). The second key covers
            // a bare line break, which moves neither `caretWidth` nor `hasText`.
            .animation(.easeOut(duration: 0.16), value: caretWidth == 0)
            .animation(.easeOut(duration: 0.16), value: model.text.isEmpty)
            // ↑/↓ history recall: as each recalled question swaps in, slide the text
            // in from the step's direction (↑ from above, ↓ from below) and fade it
            // up. Idle prompt only. We snap `recallSlide` to the start offset the
            // instant the pulse ticks (no animation on that set), then spring it home
            // — so the eye reads the swap as a small physical push, not a hard cut.
            // `caretWidth`-driven hint rides along because it's inside this ZStack.
            .modifier(RecallSlide(offset: recallSlide, active: !followUp))
            .onChange(of: model.recallPulse.n) { _ in
                guard !followUp else { return }
                recallSlide = model.recallPulse.dir == .older ? -7 : 7
                withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                    recallSlide = 0
                }
            }

            // With the destination spelled out in the pill below, the trailing send
            // pill would just repeat it — so this slot stays empty. The "what's new"
            // cue moved down to the bucket row's trailing edge, beside the Recent
            // chevron, where the panel's other glass chips live.
        }
        // Grows with the box: the prompt keeps its resting breathing room and the row
        // gains a line's height for every line the text wraps to, so the panel unfolds
        // downward instead of the text scrolling away sideways.
        .frame(height: followUp ? 30 : max(NotchBody.idleRowHeight, inputHeight + idleRowVerticalPadding))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.hasText)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: inputHeight)
        // The `/` menu's anchor: a zero-cost probe that reports THIS row's screen
        // rect and hangs the menu's own window under it. Nothing about the row (or
        // anything else in the panel) changes when the menu is up — see
        // `SlashMenuHost`.
        .background(SlashMenuHost(model: model, open: !followUp && model.slashMenuOpen))
    }

    /// The first-launch-after-update cue: a "what's new" chip on the bucket row's
    /// trailing edge, immediately left of the Recent chevron. Same glass language as
    /// the chevron cluster's "N running" capsule (`glassCapsule` + `GlassPressStyle`),
    /// so the two sit on that edge as one family. Tapping it opens the release-notes
    /// panel, and `openWhatsNew` marks this version seen, so the cue shows once.
    private var whatsNewCue: some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                model.openWhatsNew(on: nil)
            }
        } label: {
            Text(L("whatsnew.cue"))
                .font(.sf(11.5, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(whatsNewHovered ? Tokens.text1 : Tokens.text2)
                .padding(.horizontal, 10)
                // The cluster's chip height — the cue lines up with the chevron
                // beside it instead of sitting a hair short.
                .frame(height: 30)
                .glassCapsule(in: Capsule(), brighter: whatsNewHovered)
                .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { whatsNewHovered = $0 }
        .animation(.easeOut(duration: 0.18), value: whatsNewHovered)
    }

    /// The "Update to X" chip: the waiting-update action promoted OUT of the ⋯
    /// menu onto the surfaces themselves — the idle prompt's bucket row and the
    /// recent list's manage bar. A new build is the one thing worth surfacing,
    /// and a 5pt dot on the ⋯ chip asked the user to go looking for it. Same
    /// glass capsule as the "what's new" cue beside it, plus the arrow-up mark
    /// the About row uses, so the chip reads as the update family wherever it
    /// lands. Tapping installs and relaunches.
    ///
    /// `height` matches whichever row hosts it — 30 on the bucket row, 34 on the
    /// manage bar — so the chip lines up with the chevron / ⋯ beside it.
    private func updateCue(version: String, height: CGFloat,
                           hovered: Binding<Bool>) -> some View {
        Button {
            updater.update()
        } label: {
            HStack(spacing: 5) {
                LucideIcon(mark: LucideIcons.circleFadingArrowUp, size: 12)
                Text(L("about.update.to", version))
                    .font(.sf(11.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(hovered.wrappedValue ? Tokens.text1 : Tokens.text2)
            .padding(.horizontal, 10)
            .frame(height: height)
            .glassCapsule(in: Capsule(), brighter: hovered.wrappedValue)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovered.wrappedValue = $0 }
        .animation(.easeOut(duration: 0.18), value: hovered.wrappedValue)
    }

    private var followUpRow: some View {
        // Bottom-aligned so the send button stays on the box's last line as a long
        // follow-up unfolds upward off the answer, instead of floating at its middle.
        // A one-line box is 27pt — the button's own height — so the resting row is
        // unchanged.
        HStack(alignment: .bottom, spacing: 6) {
            ZStack(alignment: .leading) {
                PromptField(
                    // The native placeholder stays empty on purpose: the box can only
                    // hard-swap its placeholder string, so the slot is owned by the
                    // SwiftUI labels below, which cross-fade their copy instead.
                    text: $model.text,
                    placeholder: "",
                    fontSize: NotchBody.followUpFontSize,
                    focusTrigger: focused,
                    maxVisibleLines: NotchBody.promptMaxLines,
                    // Route by intent, same as the idle prompt — a follow-up line
                    // like "remind me to ping Alex tomorrow at 9am" files to
                    // Reminders instead of being asked to the AI. A plain question
                    // still resolves to `.chat` → `submit()`, which continues the
                    // existing thread (firstTurn = turns.isEmpty), so the common
                    // follow-up path is unchanged.
                    onSubmit: { model.submitCurrent() },
                    onBack: {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                            model.newChat()
                        }
                    },
                    // Tab cycles where Enter sends this line (Ask → Note → Remind →…)
                    // when the classifier guessed wrong — the correction escape hatch,
                    // matching the idle prompt. Empty-field Tab is still swallowed so
                    // focus never wanders out of the field.
                    onTab: {
                        guard let event = NSApp.currentEvent,
                              ReservedAppShortcut.cycleIntent.matches(event) else {
                            return false
                        }
                        if model.hasText { model.toggleSubmitPanel() }
                        return true
                    },
                    // Lets the overlay placeholder hide itself the instant the editor
                    // shows ANYTHING — committed text or still-composing pinyin (which
                    // isn't in `model.text` yet) — matching the native behaviour.
                    onCaretWidth: { followUpCaretWidth = $0 },
                    onHeightChange: { followUpHeight = $0 }
                )
                .frame(height: followUpHeight)
                // No trailing ghost here either — a follow-up is always an ask
                // anyway (`effectiveSubmitPanel` pins a thread to `.chat`), so the
                // field keeps its full width and the destination's colour wash below
                // is all the routing this row has to say.
                // The placeholder, shown only while the editor is truly empty —
                // committed text, a bare line break, and in-progress pinyin all
                // hide it. (Raw `text.isEmpty`, not `hasText`: the latter trims,
                // so a ⇧⏎-only field read as empty and kept the ghost.)
                if model.text.isEmpty && followUpCaretWidth == 0 {
                    followUpPlaceholderLabel
                        // Nudge to sit on the box's own ~2pt left inset so the label
                        // lands where the typed glyphs will, not 2pt left.
                        .padding(.leading, PromptField.textInset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            // The box at rest is one line (18pt) but the row is pinned to the send
            // button's 27pt — so a resting field centres in that slot exactly as it
            // always has, and only a wrapped follow-up pushes the row taller.
            .frame(height: max(27, followUpHeight))
            // Drives the placeholder's fade during IME pre-composition: pinyin
            // showing in the editor flips `followUpCaretWidth` while `hasText` is
            // still false, and the row-level hasText animation never fires — so
            // without this key the placeholder would hard-pop instead of fading.
            .animation(.easeOut(duration: 0.16), value: followUpCaretWidth == 0)
            .animation(.easeOut(duration: 0.16), value: model.text.isEmpty)

            // The send button appears the moment the user starts typing a
            // follow-up. (The "continue in ChatGPT/Claude" handoff used to rest
            // here while the field was empty; it now lives in the answer footer
            // with the other per-answer actions — see `AssistantTurnView`.)
            if model.hasText {
                SendButton(compact: true) { model.submitCurrent() }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        // Height comes from the field's own slot above (27pt at rest, taller once the
        // text wraps), so the row stays put when the send button shows/hides.
        .padding(.leading, 13)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(focused ? Tokens.recessFillLit : Tokens.recessFill)
                // A whisper of the destination's colour washed over the box while
                // there's text — the quiet twin of the tinted destination pill,
                // so the field itself leans toward where Enter will send the line.
                // Fades out on an empty field (destination is just the default).
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(model.submitTint
                            .opacity(model.hasText ? 0.045 : 0))
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(focused ? Tokens.recessRimLit : Tokens.recessRim, lineWidth: 0.5)
        )
        // Flash the field's rim when the destination flips (Ask⇄Note⇄Remind) — the
        // peripheral twin of the pill's word swap, in the NEW
        // destination's colour. Keyed on the intent *category* so a
        // recurrence-suffix edit doesn't pulse.
        .intentChangePulse(on: model.effectiveSubmitPanel,
                           shape: RoundedRectangle(cornerRadius: 12),
                           tint: model.submitInk)
        .animation(.smooth(duration: 0.25), value: model.effectiveSubmitPanel)
        .animation(.easeOut(duration: 0.2), value: focused)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.hasText)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: followUpHeight)
    }

    /// The follow-up field's placeholder, drawn as a SwiftUI label in the slot the
    /// native placeholder would occupy (same font, colour and inset). SwiftUI
    /// ownership (rather than the box's own placeholder) is what lets it hide the
    /// instant the field shows anything — including still-composing pinyin, which a
    /// native placeholder wouldn't yield to.
    private var followUpPlaceholderLabel: some View {
        // On an agent thread the placeholder says who actually answers. With the
        // run's CLI session still on record (and its engine installed), Enter
        // resumes THAT session — the agent continues the work (`submit()` routes
        // it via `continueAgentThread`); while a round is still in flight the
        // line queues for the next one, and the placeholder says so. Only when
        // the session is gone does the question fall through to the chat model,
        // with the report as context.
        Group {
            if let engine = model.agentThreadContinuation {
                Text(model.agentThreadTaskRunning
                    ? L("result.followUp.agentQueue", engine.displayName)
                    : L("result.followUp.agentContinue", engine.displayName))
            } else {
                Text(L(model.threadIsAgentRun ? "result.followUp.agent" : "result.followUp"))
            }
        }
        .font(.sf(NotchBody.followUpFontSize))
        .foregroundStyle(Tokens.placeholder)
        .lineLimit(1)
    }

}

/// History row highlight — a *hint* of glass, not a slab of it. The earlier
/// `.ultraThinMaterial` plate rendered at full strength and turned the whole row
/// into a bright frosted block that upstaged the text. Here the same idea is kept
/// but dialled right down: a barely-there white wash to say "this row", with a thin
/// material laid over it at very low opacity so a touch of real glass refraction
/// shows through — present enough to feel like the panel's own material, faint
/// enough that the text stays the hero. Keyboard selection (↑/↓) reads a little
/// firmer than a passing hover; a hovered-selected row firmer still.
struct HistoryRowStyle: ButtonStyle {
    var selected: Bool = false
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        // 0 → nothing, up to 1 → most present. Even "most" is gentle.
        let presence: Double = selected ? (hovering ? 1.0 : 0.72) : (hovering ? 0.5 : 0)
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    // Faint white floor so the row reads even where the material has
                    // nothing dark behind it to refract.
                    .fill(.white.opacity(0.03 * presence))
                    // A whisper of real glass on top — thin material, held to a low
                    // opacity so it shimmers rather than slabs.
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.thinMaterial)
                            .opacity(0.22 * presence)
                    )
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.rowFade), value: selected)
            .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
    }
}

/// Hover wash for a row sitting on a floating GLASS CARD — the ⋯ manage menu.
/// `HistoryRowStyle` can't do this job here: its highlight is mostly a
/// `.thinMaterial` plate, and a material laid over a `glassEffect` card samples
/// the same backdrop the card already samples, so the wash all but vanishes and
/// the row reads as having no hover at all. Plain white instead — the same
/// treatment the other glass popover menus use (`AskRecentModelRow`,
/// `AgentModelRow`), at the card's inner corner radius (14 card − 6 padding).
struct ManageMenuRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let wash: Double = configuration.isPressed ? 0.10 : (hovering ? 0.06 : 0)
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(wash))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
    }
}

/// The ONE colour a source wears wherever it shows a face — the Recent filter
/// chips, the collapsed active-filter tag, the capture rows' "open in Notes /
/// Reminders" pill, and every one of the archive window's chips, rows and
/// bubbles. Note the Notes amber, Remind the Reminders orange, Ask a cool blue,
/// Agent the violet; the values themselves live in `Tokens`, beside the matching
/// `Panel.intentTint` the composer reads, so the input's colour story and the
/// history's are literally the same table.
///
/// This used to be three separate copies (`filterTint` / `captureJumpTint` here,
/// `archiveTint` over in the archive window) that happened to agree — one edit
/// away from a source reading amber in the notch and yellow in the window.
extension NotchModel.HistoryItem.Source {
    var tint: Color {
        switch self {
        case .ask:      return Tokens.askTint
        case .note:     return Tokens.noteTint
        case .reminder: return Tokens.reminderTint
        case .agent:    return Tokens.agentTint
        }
    }
}

/// Recent-row VoiceOver wiring, split by kind. An Ask row combines its children
/// into one element that reopens the thread. A capture row stays a *container*
/// so its separate trailing jump button remains an independently-focusable
/// control — folding it in (`.combine`) would hide the one control that jumps.
private struct RecentRowAccessibility: ViewModifier {
    let item: NotchModel.HistoryItem
    func body(content: Content) -> some View {
        if item.source.isThread {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(item.displayTitle)
                .accessibilityHint(L("recent.hint.ask"))
        } else {
            content
                .accessibilityElement(children: .contain)
                .accessibilityLabel(item.displayTitle)
        }
    }
}

/// What the input is wearing right now. `Panel` has no agent case on purpose —
/// the agent isn't a classifier destination, it's an armed mode — so an active
/// agent compose would otherwise fall back to Ask's blue while its chips and
/// Recent rows wear violet. These two resolve that: agent compose paints the
/// input the agent violet, everything else its destination's colour.
fileprivate extension NotchModel {
    /// Saturated body — for the field's low-opacity background wash.
    var submitTint: Color {
        submitGoesToAgent ? Tokens.agentTint : effectiveSubmitPanel.intentTint
    }
    /// The luminous face — for the rim pulse and other ink on the dark glass.
    var submitInk: Color {
        submitGoesToAgent ? Tokens.agentInk : effectiveSubmitPanel.intentInk
    }
}

/// The destination colour of an intent — the SAME palette everywhere a
/// destination shows its face: Ask a cool blue, Note the Notes amber, Remind
/// the Reminders orange. Read by the destination pill under the prompt, the
/// follow-up field's background wash, and the intent-change rim pulse, so the
/// input's colour story always matches the filter chips and capture chips.
extension NotchModel.Panel {
    /// Saturated body colour — right for low-opacity WASHES over the dark glass
    /// (the follow-up box's background lean), where saturation survives dilution.
    var intentTint: Color {
        switch self {
        case .chat:     return Tokens.askTint
        case .note:     return Tokens.noteTint
        case .reminder: return Tokens.reminderTint
        }
    }

    /// The same hue lifted toward white — for TEXT and glows on the dark glass.
    /// A fully saturated colour used as ink sinks into the dark background (blue
    /// especially reads as a murky shadow); these luminous pastels read as
    /// coloured *light* instead, keeping the hue legible and the ghost elegant.
    var intentInk: Color {
        switch self {
        case .chat:     return Tokens.askInk
        case .note:     return Tokens.noteInk
        case .reminder: return Tokens.reminderInk
        }
    }
}

/// A glass pill carrying an icon and a word, used for the two actions parked at the
/// bottom of the recent list. Same Liquid Glass language as `GlassTextButton` — it
/// brightens on hover and gives under a press — with a `destructive` face that reads
/// soft red so Clear can never be mistaken for the archive link beside it.
private struct HistoryFooterButton: View {
    var icon: String
    var title: String
    var action: () -> Void

    @State private var hovering = false

    /// Both footer pills read the same weight — Clear used to sit at near-white
    /// while "See all history" was meta-dim, and the mismatch made the pair look
    /// like two different controls rather than one row. The destructive step is
    /// carried by the confirmation card, not by a brighter label.
    private var tint: Color {
        hovering ? Tokens.text2 : Tokens.text4
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.sf(10, weight: .medium))
                Text(title)
                    .font(.sf(11, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassCapsule(in: Capsule(), brighter: hovering)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

/// The one place a history source maps to its filter-chip face: the label key
/// and the source's app colour (Notes amber, Reminders orange, Ask a cool blue,
/// Agent a violet).
/// Shared by the manage menu's chips and the collapsed active-filter chip so the
/// two can never drift apart.
extension NotchModel.HistoryItem.Source {
    fileprivate var filterTitle: String {
        switch self {
        case .note:     return L("recent.filter.note")
        case .reminder: return L("recent.filter.remind")
        case .ask:      return L("recent.filter.ask")
        case .agent:    return L("recent.filter.agent")
        }
    }
}

/// The collapsed-state reminder that a source filter is narrowing the list: a
/// small tinted capsule beside the ⋯ naming the filter, with an × — tap anywhere
/// on it to clear the filter and show everything again. Brightens on hover like
/// every other glass chip.
private struct ActiveFilterChip: View {
    @ObservedObject var model: NotchModel
    var source: NotchModel.HistoryItem.Source

    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                model.historySourceFilter = nil
            }
        } label: {
            HStack(spacing: 5) {
                Text(source.filterTitle)
                    .font(.sf(11, weight: .medium))
                    .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
                Image(systemName: "xmark")
                    .font(.sf(8, weight: .semibold))
                    .foregroundStyle(hovering ? Tokens.text2 : Tokens.text4)
            }
            .padding(.horizontal, 12)
            // Match the ⋯ chip beside it exactly (GlassIconButton size 34), so the
            // pair reads as one bar of same-height controls, not a big circle with
            // a smaller tag hanging off it.
            .frame(height: 34)
            .glassCapsule(in: Capsule(), brighter: hovering, tint: source.tint)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

/// The directional slide-in applied to the idle prompt while ↑/↓ recall swaps a
/// past question in. `offset` is the live vertical displacement (driven from a
/// spring back to 0); opacity is derived from it so the text fades up as it
/// settles — full at rest, dipping to ~0.4 at the 7pt extreme. A no-op when
/// `active` is false (the follow-up field), so it never touches that path.
private struct RecallSlide: ViewModifier {
    var offset: CGFloat
    var active: Bool
    func body(content: Content) -> some View {
        if active {
            content
                .offset(y: offset)
                .opacity(1 - min(abs(offset) / 7, 1) * 0.6)
        } else {
            content
        }
    }
}

/// A compact three-dot wave for a Recent row whose answer is still streaming —
/// the same calm cadence as `ThinkingDots`, sized down to sit in the trailing
/// slot where the timestamp lands once the answer settles. Sits in the row at
/// `.firstTextBaseline`, so the dots align with the title rather than floating.
struct RecentPendingDots: View {
    @State private var phase = false
    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Tokens.text4)
                    .frame(width: 3.5, height: 3.5)
                    .opacity(phase ? 0.9 : 0.25)
                    .animation(
                        .easeInOut(duration: 0.62)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.16),
                        value: phase
                    )
            }
        }
        .onAppear { phase = true }
        .accessibilityLabel(L("recent.answering"))
    }
}

/// Carries the answer text's intrinsic height up to the body so the scroll area
/// can size itself to the content (capped at the ceiling).
private struct AnswerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // Take the latest reported height, NOT max(). There's a single reader (the
        // scroll content's GeometryReader), so this just carries its current height
        // through — which must be able to SHRINK, not only grow. `max` latched the
        // measurement to the largest value ever seen (a tall earlier answer, or a
        // transient layout pass), so when a short answer replaced a long one the
        // scroll frame stayed tall and left a dead band under the text. Last-value
        // lets the frame track the real content up and down.
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// Carries the immersive floating header's measured height up to `NotchBody` so the
/// list's top runway and frost band can be sized to whatever the header actually
/// holds — a bare input, or an input topped by a copied-image preview.
private struct ImmersiveHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // Single reader; last value wins so the runway can SHRINK back when the
        // preview clears, not just grow (same rationale as `AnswerHeightKey`).
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// The "Set up your model" row that stands in for the follow-up field on the
/// offline stub. Mirrors the follow-up box's chrome — rounded rect, faint fill,
/// hairline border — and brightens on hover / gives slightly on press so it reads
/// as the same kind of affordance, just leading somewhere instead of accepting text.
struct SetupModelButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .recessedSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                             lit: hovering)
            .scaleEffect(pressed ? 0.985 : 1)
            .opacity(pressed ? 0.85 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressed)
    }
}

/// The idle prompt's trailing controls — the pin and the Recent disclosure. Each is
/// its own round glass chip, in exactly the language of the recent panel's ⋯ entry
/// (`GlassIconButton`): a translucent glass circle that brightens under the cursor.
/// They used to share one capsule, which wrapped the lone chevron in a pill of
/// dead space — the chip IS the target now, no padding around it.
///
/// Engaged state (pinned, or Recent open) reads through the glyph alone — the
/// filled, upright tack and the flipped chevron — never a wash.
///
/// The idle prompt shows no pin *button*: an unpinned panel offers only Recent, and
/// ⌘P/⌘D (ContentView's key handler) is how pinning happens. The tack appears here
/// only once the panel IS pinned — state made visible, and the click that releases it.
struct IdleTrailingCluster: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var pinned: Bool
    var recentOpen: Bool
    /// Recent has nothing to show on a first run — the pill then carries the pin
    /// alone and shrinks to a single round segment.
    var showsRecent: Bool
    /// How many agent runs are live. Non-zero swaps the round chevron for a
    /// "N running ⌄" capsule — the live count rides the disclosure itself instead
    /// of a standalone status strip below the prompt.
    var runningCount: Int = 0
    var togglePin: () -> Void
    var toggleRecent: () -> Void

    /// Nothing to draw when neither segment is live — an empty capsule of glass
    /// would still read as a control. A live run always draws (the "N running"
    /// chip), even before any Recent history exists to disclose.
    var isEmpty: Bool { !pinned && !showsRecent && runningCount == 0 }

    private enum Segment { case pin, recent }

    @State private var hovered: Segment? = nil

    /// The ⋯ chip's diameter, one step down: these sit inside the prompt row, not on
    /// the panel's chrome.
    private let chipSize: CGFloat = 30

    var body: some View {
        HStack(spacing: 6) {
            // The pin has no button at rest — ⌘P/⌘D is the way in. Once pinned it
            // surfaces here as the state's own affordance: it shows the panel is held
            // open, and clicking it lets go.
            if pinned {
                segment(.pin, engaged: true, action: togglePin,
                        tooltip: shortcutHelp("result.unpin", action: .pin)) {
                    // A pinned pin tips upright, the way a pushed-in tack sits.
                    Image(systemName: "pin")
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            // Live runs fold their count into the disclosure — "N running ⌄" — so
            // the resting panel stays at its input while a background agent works;
            // the standalone status strip stays hidden until nothing's running.
            if runningCount > 0 {
                runningRecentChip
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            } else if showsRecent {
                segment(.recent, engaged: recentOpen, action: toggleRecent,
                        tooltip: L("recent.recent")) {
                    // A downward chevron reads as "pull the recent list down"; it flips
                    // to point up once the list is open, so the same control says
                    // "close" on the way back.
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(recentOpen ? 180 : 0))
                        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: recentOpen)
                }
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: showsRecent)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: pinned)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: runningCount)
    }

    /// The disclosure while runs are live: the same glass, stretched to a capsule
    /// that carries a breathing bead, the "N running" count, and the chevron. Tapping
    /// it drops the Recent list, whose top rows are those very runs (with their
    /// cancel controls) — so the count is a live handle, never a dead badge.
    private var runningRecentChip: some View {
        let hovering = hovered == .recent
        return Button(action: toggleRecent) {
            HStack(spacing: 5) {
                AgentStatusDot(running: true, outcome: nil)
                Text(L("agent.running.count", runningCount))
                    .font(.sf(11.5, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(runningCount)))
                    // Roll the digit natively, the way the row clock ticks: the
                    // animation has to ride the Text itself for `numericText` to
                    // fire — on the outer Button it only drives the layout.
                    .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: runningCount)
                Image(systemName: "chevron.down")
                    .font(.sf(10, weight: .semibold))
                    .rotationEffect(.degrees(recentOpen ? 180 : 0))
                    .animation(.spring(response: 0.32, dampingFraction: 0.8), value: recentOpen)
            }
            .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
            .padding(.horizontal, 10)
            .frame(height: chipSize)
            .glassCapsule(in: Capsule(), brighter: hovering)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { inside in
            if inside { hovered = .recent }
            else if hovered == .recent { hovered = nil }
        }
        .animation(.easeOut(duration: 0.18), value: hovered)
        .animation(.snappy(duration: 0.3), value: runningCount)
    }

    /// One round glass chip — the ⋯ entry's `GlassIconButton` body, with an extra
    /// `engaged` ink step (pinned / Recent open) the shared component doesn't carry.
    private func segment<Glyph: View>(
        _ segment: Segment, engaged: Bool, action: @escaping () -> Void,
        tooltip: String, @ViewBuilder glyph: () -> Glyph
    ) -> some View {
        let hovering = hovered == segment
        return Button(action: action) {
            glyph()
                .font(.sf(11.5, weight: .semibold))
                .foregroundStyle(hovering ? Tokens.text1 : (engaged ? Tokens.text2 : Tokens.text3))
                .frame(width: chipSize, height: chipSize)
                .glassCapsule(in: Circle(), brighter: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { inside in
            if inside { hovered = segment }
            else if hovered == segment { hovered = nil }
        }
        .animation(.easeOut(duration: 0.18), value: hovered)
    }
}

/// The result header's trailing control — the pin — held in a Liquid Glass capsule
/// (`glassCapsule` = native `.glassEffect` on macOS 26+, blur fallback below). The
/// capsule is a circle around the lone pin. A bare glyph would read as an unrelated
/// control in a different material; the system's own grouped-glass shape gives it a
/// proper pane, the way a Safari toolbar button sits.
///
/// The glass lives on the capsule and only there: a hovered segment marks itself
/// with ink and a soft circle of light, never a second pane of glass nested inside
/// the first. Glyphs stay pure white — engaged (pinned) reads through the filled
/// tack, its upright tilt, and a white wash, never a colour tint.
///
/// Toggling routes back through the model so an un-pin can immediately re-arm
/// the leave-fold if the pointer is already gone.
struct ResultTrailingCluster: View {
    var pinned: Bool
    var togglePin: () -> Void
    /// Tear-off action. When set, a detach chip joins the pin, to its left — the
    /// two view actions read as one pair (tight 6pt spacing), set apart from the
    /// composer chip further left by the header's wider 10pt gap.
    var detach: (() -> Void)? = nil

    var body: some View {
        GlassSegmentCluster(segments: {
            var segs: [GlassSegmentCluster.Segment] = []
            if let detach {
                segs.append(.init(tooltip: shortcutHelp("detached.open", action: .detach),
                                  action: detach) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.sf(10.5, weight: .medium))
                })
            }
            segs.append(.init(engaged: pinned,
                              tooltip: shortcutHelp(pinned ? "result.unpin" : "result.pin",
                                                    action: .pin),
                              action: togglePin) {
                // A pinned pin tips upright, the way a pushed-in tack sits — a small
                // physical cue that it's engaged, on top of the engaged tint.
                Image(systemName: "pin")
                    .font(.sf(11, weight: .medium))
                    .rotationEffect(.degrees(pinned ? 0 : 32))
            })
            return segs
        }(), glass: false)
        // Hover-only chrome sitting right beside the answer: it should be
        // findable, not loud. This drops the bare cluster's own levels onto the
        // history footer's meta pair — text4 at rest, text2 under the pointer —
        // without giving this one caller a private tint API.
        .opacity(0.72)
    }
}

/// The header's back chevron, wearing the panel's **Liquid Glass** language: a
/// real glass circle (native `.glassEffect` on macOS 26+, blurred fallback below)
/// with the signature specular rim, brightening under the cursor like every other
/// chip in the header. It used to be a bare glyph over a flat white-wash hover
/// pill, which read as a different material from the glass cluster opposite it.
private struct GlassBackButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.sf(13, weight: .semibold))
                .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
                .frame(width: 26, height: 26)
                .glassCapsule(in: Circle(), brighter: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

struct RecentEntryStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // A Capsule, not a Circle: it collapses to a perfect circle behind a
            // square icon button (e.g. the 27×27 continue-elsewhere icon) but reads
            // as a proper pill behind a wide text label. A Circle stretched to the
            // label's wide rectangular bounds rendered as an oversized ellipse that
            // bled above and below the text.
            .background(
                Capsule().fill(.white.opacity(hovering ? 0.08 : 0))
            )
            .opacity(configuration.isPressed ? 0.5 : (hovering ? 1 : 0.85))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
    }
}

/// The user's question, shown in a quiet chat bubble. The bubble's corner radius
/// adapts to how tall the text is: a single line stays a full pill (radius = half
/// the height, exactly like the old `Capsule`), but once the text wraps to two or
/// more lines the radius drops to a fixed, smaller value. A capsule at multi-line
/// height rounds its corners by half the *tall* box — a bloated, over-round blob;
/// the smaller radius keeps a multi-line quote reading as a tidy card.
/// `style: .continuous` matches the panel's other rounded shapes.
struct UserQuestionBubble: View {
    let text: String

    /// Whether the user tapped to expand a truncated question. Starts collapsed so a
    /// pasted wall of text never dominates the thread on first render.
    @State private var expanded = false

    /// Collapsed cap: a long pasted question folds to this many lines, keeping the
    /// bubble a tidy card instead of a scroll-eating slab. Tapping expands to full.
    private let collapsedLineLimit = 6

    /// Ceiling for the EXPANDED bubble. A very long question doesn't grow without
    /// bound — past this the text scrolls INSIDE the bubble. This is the fix for the
    /// freeze: an unbounded expanded height fed back into the result view's
    /// `AnswerHeightKey` measurement (which flips the clip/scroll layout at 300pt),
    /// and the two height feedbacks drove an endless relayout. Capping the bubble
    /// keeps its contribution bounded, so that loop can't form.
    private let expandedMaxHeight: CGFloat = 240

    /// Corner radius — a fixed modest card once the bubble is clearly multi-line, a
    /// pill when it's a short single/double line. Derived purely from the text (no
    /// geometry read), so there's no measurement feeding back into layout.
    private let multiLineRadius: CGFloat = 16
    private let pillRadius: CGFloat = 16.5   // ~half a single-line bubble height

    /// Cheap, allocation-light estimate of whether the collapsed text is truncated —
    /// purely from the string, NO GeometryReader (a height probe here is exactly what
    /// caused the relayout freeze). Counts hard newlines, plus an approximate wrap
    /// count for long unbroken lines (~48 chars/line at this width/font). If that
    /// exceeds the collapsed cap, the question is being clipped, so show the toggle.
    private var isTruncated: Bool { estimatedLines(exceed: collapsedLineLimit) }

    /// Whether the EXPANDED text outgrows `expandedMaxHeight` and actually scrolls
    /// inside the bubble — the gate for the scroll-edge fade below. Same string-only
    /// estimate as `isTruncated` (no geometry read): ~19pt per line at this font, so
    /// 240pt ≈ 12 lines.
    private var expandedOverflows: Bool { estimatedLines(exceed: 12) }

    private func estimatedLines(exceed cap: Int) -> Bool {
        var lines = 0
        for segment in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += 1 + segment.count / 48
            if lines > cap { return true }
        }
        return false
    }

    /// Pill only for a genuinely short question; anything that could wrap past a line
    /// or two reads better as a rounded card.
    private var radius: CGFloat { isTruncated || text.count > 44 ? multiLineRadius : pillRadius }

    private var questionText: some View {
        Text(text)
            .font(.sf(14.5, weight: .medium))
            .tracking(-0.1)
            .foregroundStyle(Tokens.text2)
            // Collapsed to a fixed cap until the user expands; nil = unlimited.
            .lineLimit(expanded ? nil : collapsedLineLimit)
            .fixedSize(horizontal: false, vertical: true)
            // The question itself is selectable too — drag to highlight and
            // copy it, same as the answer below. (It's a settled user turn,
            // never streaming, so there's no tail-follow scroll to fight.)
            .textSelection(.enabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Expanded: the full text can be tall, so it scrolls WITHIN a capped
            // frame instead of pushing the bubble (and the whole result view) past
            // any height. Collapsed: the plain clamped text, no scroll container.
            if expanded {
                ScrollView(.vertical, showsIndicators: false) {
                    questionText
                        // Breathing room each fade falls across, so the first / last
                        // line can rest outside its taper at full strength at either
                        // end (the shared fade discipline — never dim resting text).
                        .padding(.top, expandedOverflows ? 16 : 0)
                        .padding(.bottom, expandedOverflows ? 28 : 0)
                }
                .frame(maxHeight: expandedMaxHeight)
                // The shared dissolve instead of a hard cut where the text scrolls
                // past either of the bubble's edges. Gated on actual overflow — a
                // bubble whose full text fits sizes to content, and fading it would
                // dim real lines. A thin feather up top: one line leaving is all it
                // has to swallow.
                .scrollEdgeFade(top: expandedOverflows, bottom: expandedOverflows, topFade: 16, bottomFade: 28)
            } else {
                questionText
            }

            // Only shown when the collapsed text is actually cut off. A quiet grey
            // toggle in the same `text4` as the timestamps — never shouts.
            if isTruncated {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    Text(expanded ? L("bubble.showLess") : L("bubble.showMore"))
                        .font(.sf(11, weight: .medium))
                        .tracking(0.2)
                        .foregroundStyle(Tokens.text4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Tokens.hairline, lineWidth: 1)
                )
        )
    }
}

// MARK: - Agent status dot

/// The outcome of an agent run in one 7pt glass bead: purple done, red failed,
/// grey cancelled. A *working* run draws nothing here — its activity line and
/// ticking clock already say it's alive, and a pulsing dot on top of them was
/// only noise. The slot is held either way, so the phrase beside it doesn't
/// slide sideways the moment the bead lights up.
struct AgentStatusDot: View {
    let running: Bool
    let outcome: AgentTaskManager.Outcome?

    @State private var breathing = false

    private var tint: Color {
        switch outcome {
        case .failure:   return Tokens.danger
        case .cancelled: return Tokens.text4
        default:         return Tokens.accent
        }
    }

    var body: some View {
        ZStack {
            if running {
                // A working run breathes a flat translucent white dot in the slot —
                // the "it's alive" pulse that rides alongside the ticking activity
                // line, swinging transparency and scale as it breathes so it reads
                // without any glass sheen.
                Circle()
                    .fill(.white.opacity(0.5))
                    .opacity(breathing ? 0.7 : 0.26)
                    .scaleEffect(breathing ? 1.0 : 0.72)
                    .onAppear { breathing = true }
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                               value: breathing)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else {
                // A settled run marks its slot with a flat coloured dot.
                Circle()
                    .fill(tint.opacity(0.92))
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: 7, height: 7)
        .animation(.spring(response: 0.38, dampingFraction: 0.7), value: running)
    }
}

// MARK: - Agent compose chips (XII: agent-to-Codex)

/// The shared face of one armed-compose chip: leading glyph + label in the
/// clipboard preset chips' exact glass capsule, so the agent row reads as
/// the same species living in the same slot.
private struct AgentChipFace<Icon: View>: View {
    var icon: Icon
    var title: String
    var hovering: Bool
    /// Overrides the resting ink. Used when the chip is reporting something wrong
    /// rather than naming a setting — the Ask chip with no model configured.
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 5) {
            icon
            Text(title)
                .font(.sf(12, weight: .light))
                .foregroundStyle(tint ?? (hovering ? Tokens.text2 : Tokens.text4))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Capsule())
    }
}

/// A compose chip that fires an action on tap (the folder chip).
struct AgentComposeChip<Icon: View>: View {
    var title: String
    var tint: Color? = nil
    var action: () -> Void
    @ViewBuilder var icon: () -> Icon

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            AgentChipFace(icon: icon(), title: title, hovering: hovering, tint: tint)
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

/// A compose chip that opens a picker menu on click (model / effort). The
/// system menu indicator is hidden — the chip itself is the whole affordance,
/// like every other capsule in the row.
struct AgentComposeMenuChip<Icon: View, Items: View>: View {
    var title: String
    @ViewBuilder var items: () -> Items
    @ViewBuilder var icon: () -> Icon

    @State private var hovering = false

    var body: some View {
        Menu(content: items) {
            AgentChipFace(icon: icon(), title: title, hovering: hovering)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

/// Hangs the `/` menu under the prompt in a window of its OWN — the reason the
/// menu is a true overlay instead of another block in the panel's stack.
///
/// This is a zero-size probe dropped in the input row's `.background`. It takes no
/// space, so nothing in the panel moves when the menu opens; it reports the row's
/// SCREEN rect (from its own `NSView`, so it stays right through island re-layouts
/// and display switches); and it parents a borderless child panel to the island's
/// window, hung just under that rect. Being a separate window is what lets the card
/// overhang the island's edge and spill onto the desktop — inside the SwiftUI tree
/// it would be clipped by the glass form and would push the panel taller.
///
/// The child panel deliberately **cannot become key** (`SlashMenuPanel`), so
/// clicking a row never pulls first-responder off the prompt field — you can keep
/// typing to filter with the pointer sitting on the card. It closes itself when the
/// menu shuts, when the probe leaves the tree (panel folded, thread opened), and
/// when its host window goes away.
private struct SlashMenuHost: NSViewRepresentable {
    let model: NotchModel
    let open: Bool

    func makeNSView(context: Context) -> NSView { SlashMenuAnchorView() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? SlashMenuAnchorView)?.apply(model: model, open: open)
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? SlashMenuAnchorView)?.closeMenu()
    }
}

/// A borderless panel that never takes key focus — the menu's window. Everything
/// it hosts is pointer-driven; the keyboard stays with the prompt field that the
/// user is typing the command into.
private final class SlashMenuPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The probe view: measures, positions, and owns the menu's panel.
private final class SlashMenuAnchorView: NSView {
    /// Air between the input row's bottom edge and the card's top.
    private static let gap: CGFloat = 6
    /// Transparent margin inside the window, around the card — the card draws its
    /// own two shadows in SwiftUI, and a window sized flush to the card would clip
    /// them off. Also the slack the position math has to add back.
    private static let shadowMargin: CGFloat = 28

    private var panel: SlashMenuPanel?
    private var hosting: NSHostingView<AnyView>?
    private var isOpen = false

    func apply(model: NotchModel, open: Bool) {
        guard open else {
            closeMenu()
            return
        }
        let card = AnyView(
            SlashCommandMenu(model: model).padding(Self.shadowMargin)
        )
        if let hosting {
            hosting.rootView = card
        } else {
            openMenu(with: card)
        }
        reposition()
    }

    private func openMenu(with card: AnyView) {
        guard let host = window else { return }
        let hosting = NSHostingView(rootView: card)
        let panel = SlashMenuPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false          // the card draws its own
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false
        // Dark like the island, and along for the ride across Spaces / full-screen.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.contentView = hosting
        panel.alphaValue = 0
        // A CHILD of the island's window: it rides along when that window moves,
        // stays ordered above it whatever level the island is at (the panel drops
        // to `.floating` while an IME is composing), and goes away with it.
        host.addChildWindow(panel, ordered: .above)
        self.panel = panel
        self.hosting = hosting
        self.isOpen = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func closeMenu() {
        guard let panel else { return }
        self.panel = nil
        self.hosting = nil
        self.isOpen = false
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Park the card just under the input row, left edges flush. Runs on every
    /// apply and on every layout pass, so a growing prompt box (or the island
    /// re-laying out under it) carries the card with it instead of leaving it
    /// stranded mid-panel.
    private func reposition() {
        guard let panel, let hosting, let host = window else { return }
        let size = hosting.fittingSize
        let anchor = host.convertToScreen(convert(bounds, to: nil))
        let margin = Self.shadowMargin
        var origin = CGPoint(
            x: anchor.minX - margin,
            y: anchor.minY - Self.gap - size.height + margin
        )
        // Never let it walk off the bottom of the display it's on.
        if let visible = (host.screen ?? NSScreen.main)?.visibleFrame {
            origin.y = max(origin.y, visible.minY + 8 - margin)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    override func layout() {
        super.layout()
        if isOpen { reposition() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closeMenu() } else if isOpen { reposition() }
    }

    // The probe is invisible chrome: it must never eat a click meant for the row
    // it is sitting behind.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The `/` command menu — a small floating card of plain words under the prompt.
///
/// Deliberately spare: one word per row, no icons, no descriptions, no shortcut
/// column. The whole menu is a completion list for what the user is already
/// typing, so the words ARE the content — anything else beside them is furniture
/// competing with the four things that matter. It sizes to its longest word and
/// hangs at the prompt's left edge, in the same Liquid Glass the manage menu
/// wears, so it reads as a card hovering over the panel rather than a new block
/// bolted into it.
///
/// Keyboard and pointer drive the SAME highlight (`model.slashHighlight`): ↑/↓
/// walk it, hover moves it under the cursor, Enter/Tab land it. One index, so the
/// row the eye is on is always the row Enter picks.
///
/// The card itself knows nothing about where it is drawn — `SlashMenuHost` puts it
/// in its own window.
private struct SlashCommandMenu: View {
    @ObservedObject var model: NotchModel

    /// The card's padding around the rows, and each row's around its word — shared
    /// with the width arithmetic below so the two can't drift.
    static let cardPad: CGFloat = 5
    static let rowPad: CGFloat = 9
    static let fontSize: CGFloat = 13

    /// The card's width: the widest destination word (measured in the very font
    /// SwiftUI will draw it in — `Font.sf` IS the system face, the same trick
    /// `BucketWord.labelWidth` uses) plus both paddings. Plain arithmetic instead
    /// of a geometry read, so the card is right on its first frame.
    static var cardWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let widest = NotchModel.SlashCommand.allCases
            .map { NSAttributedString(string: $0.title, attributes: [.font: font]).size().width }
            .max() ?? 0
        return ceil(widest) + (rowPad + cardPad) * 2
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(model.slashMatches.enumerated()), id: \.element.id) { index, command in
                SlashCommandRow(
                    command: command,
                    selected: index == model.slashHighlight,
                    hover: { model.slashHighlight = index },
                    action: {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            model.applySlashCommand(command)
                        }
                    }
                )
            }
        }
        .padding(SlashCommandMenu.cardPad)
        // Sized by its own words, pinned left under the caret — a menu, not a bar.
        // An explicit width rather than `fixedSize()`: under a fixed size every row
        // gets its IDEAL width, so the selected row's wash would stop at the end of
        // its own word instead of spanning the card. Measured off the widest of ALL
        // four words (not just the ones currently matching), so the card holds still
        // as the list filters down instead of breathing in and out per keystroke.
        .frame(width: SlashCommandMenu.cardWidth, alignment: .leading)
        // The manage menu's card recipe: `.clear` material refracting what's behind
        // it under a dark veil, a top sheen, a specular rim, and the two shadows
        // that lift it off the surface.
        //
        // The veil is heavier here than on the manage menu (0.38 → 0.66) because
        // this card lives in its OWN window and routinely hangs off the island onto
        // whatever the desktop happens to be — a bright Finder window, a white page.
        // At 0.38 the words washed out the moment the card left the glass; the
        // darker veil makes the menu read the same over anything.
        .background {
            shape.fill(.clear).nativeGlass(in: shape)
                .overlay(shape.fill(Color.black.opacity(0.66)))
        }
        .overlay(
            shape.fill(
                LinearGradient(colors: [.white.opacity(0.09), .clear],
                               startPoint: .top, endPoint: .center)
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        )
        .overlay(
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.07)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75
            )
            .allowsHitTesting(false)
        )
        .clipShape(shape)
        .shadow(color: .black.opacity(0.30), radius: 3, y: 1)
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }
}

/// One row: the destination's word, and nothing else. The selected row wears a
/// soft wash — pointer and keyboard share it, so there's never a second,
/// competing hover state.
private struct SlashCommandRow: View {
    let command: NotchModel.SlashCommand
    let selected: Bool
    let hover: () -> Void
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button(action: action) {
            Text(command.title)
                .font(.sf(SlashCommandMenu.fontSize, weight: .medium))
                .foregroundStyle(selected ? Tokens.text1 : Tokens.text3)
                .lineLimit(1)
                .padding(.horizontal, SlashCommandMenu.rowPad)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if selected {
                        shape.fill(Color.white.opacity(0.14))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Hover writes the SHARED highlight instead of painting a second one, so
        // moving the mouse over the card also moves what Enter would pick.
        .onHover { if $0 { hover() } }
        .animation(.easeOut(duration: Tokens.rowFade), value: selected)
        .accessibilityLabel(command.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The persistent destination pill that anchors the bucket row — the panel's
/// one explicit top-level choice, and the ONE place where routing shows itself.
/// Its first half is the live destination: it reads "Ask" at rest and becomes
/// "Note" / "Remind · Daily" (mark and colour with it) the moment the classifier
/// — or Tab — points the line somewhere else. Its second half arms the
/// folder-scoped agent compose, and only exists where an agent CLI does.
///
/// Words in one glass capsule washed with the active side's colour — the
/// ManageFilterChip recipe: the selected word bright, the other dim, no thumb,
/// no divider; the wash alone says which side is live. A plain click is enough
/// of a gate because arming is inert — it only unfurls the chips row; a run
/// still needs a folder, a typed task, and an explicit Enter.
private struct BucketTogglePill: View {
    @ObservedObject var model: NotchModel

    /// The pill's whole geometry, as five constants: the mark's slot, the gap from
    /// the mark to its word, a word's leading padding, the soft edge its label is
    /// wiped open with, and the gap between the two words. Both the words AND the
    /// well below are laid out from these same numbers, which is what keeps the
    /// flip a single continuous move.
    ///
    /// `wipeSoft` is carved out of what used to be the word's trailing padding, so
    /// the label's clip ends in a fade instead of a razor cut — every outer
    /// measurement stays exactly what it was (`wordPad + wipeSoft + wordTrailPad`
    /// is still 9 + 9), only the last 8pt of the box is now a falloff instead of
    /// dead air.
    static let iconSlot: CGFloat = 18
    static let labelGap: CGFloat = 5
    static let wordPad: CGFloat = 9
    static let wipeSoft: CGFloat = 8
    static let wordTrailPad: CGFloat = wordPad - wipeSoft
    private static let wordGap: CGFloat = 2

    /// How wide the label's box is: the soft edge alone once the word is wiped
    /// shut, the gap plus the spelled-out word plus that edge when it is open.
    static func labelBoxWidth(_ title: String, spelled: Bool) -> CGFloat {
        spelled ? labelGap + BucketWord.labelWidth(title) + wipeSoft : wipeSoft
    }

    /// How wide a half is: always its mark, plus the spelled-out word when live.
    private static func wordWidth(_ title: String, spelled: Bool) -> CGFloat {
        wordPad + iconSlot + labelBoxWidth(title, spelled: spelled) + wordTrailPad
    }

    /// Where Enter sends the line right now, as far as the Ask half is concerned.
    /// An armed Agent bucket owns the line, so the Ask half falls back to its
    /// resting face rather than showing a destination it isn't going to use.
    private var destination: NotchModel.Panel {
        model.agentComposeActive ? .chat : model.effectiveSubmitPanel
    }

    /// The Ask half's word — the destination *spelled out*: "Ask", "Note",
    /// "Remind · Daily". This is the panel's one place where the routing shows
    /// itself; there is no ghost trailing the caret any more.
    private var askWord: String {
        switch destination {
        case .chat:     return L("hint.ask")
        case .note:     return L("hint.note")
        case .reminder: return L("hint.remind") + model.submitLabelSuffix
        }
    }

    /// …and its mark, which changes with the word: bubble, pencil, bell.
    private var askMark: LucideIcons.Mark {
        switch destination {
        case .chat:     return LucideIcons.messageCircle
        case .note:     return LucideIcons.pencilLine
        case .reminder: return LucideIcons.bell
        }
    }

    var body: some View {
        let agentOn = model.agentComposeActive
        let ask = askWord, agent = L("hint.agent")
        HStack(spacing: Self.wordGap) {
            // `swapKey` is the destination CATEGORY, not the word: it's what the
            // mark and word roll on, so Ask⇄Note⇄Remind rolls while a
            // "Remind · Daily"→"Remind · Weekly" suffix edit doesn't (the same
            // distinction the field's rim pulse already draws).
            BucketWord(title: ask, icon: askMark, active: !agentOn,
                       swapKey: destination) {
                model.setAgentBucket(false)
            }
            // The Agent half only exists where an agent CLI does. Without one the
            // pill is a single word — the live destination, and nothing to switch.
            if model.agentAvailable {
                // No key: the Agent half's face never changes, so it has nothing
                // to roll — it only ever wipes.
                BucketWord(title: agent, icon: LucideIcons.codeXml, active: agentOn,
                           swapKey: nil) {
                    model.setAgentBucket(true)
                }
            }
        }
        // Horizontal only (the words still stretch to the pill's 30pt height):
        // pins the row to exactly the width `wordWidth` computes, so a parent that
        // hands the pill extra room can never stretch a word out from under the
        // well below.
        .fixedSize(horizontal: true, vertical: false)
        // The active side sits in a recessed inner-shadow well — the pushed-in
        // "pin" look, so the live half reads as pressed into the glass rather than
        // just brighter. The 3pt inset matches the pill's 3pt horizontal padding,
        // so the well keeps an even margin to the glass on all four sides.
        //
        // ONE persistent shape behind BOTH words, positioned by the same word
        // arithmetic the words themselves are built from — not a per-word
        // background that inserts on one side and removes on the other, and not a
        // `matchedGeometryEffect` pair. Flipping the bucket just changes a width
        // and an offset, so the well GLIDES across and resizes on the pill's single
        // spring and can never disagree with the words it sits behind (the model
        // picker card's armed-row wash learned this the same way).
        .background(alignment: .leading) {
            Capsule().fill(
                Color.white.opacity(0.17)
                    .shadow(.inner(color: .black.opacity(0.48), radius: 3, y: 1))
            )
            // A hairline top rim sells the recessed glass edge — the well reads as
            // a brighter, more solid pane than a barely-there wash.
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
            }
            .frame(width: Self.wordWidth(agentOn ? agent : ask, spelled: true))
            .padding(.vertical, 3)
            .offset(x: agentOn ? Self.wordWidth(ask, spelled: false) + Self.wordGap : 0)
        }
        // Match the Recent disclosure chevron's fixed 30pt (IdleTrailingCluster's
        // chipSize) so the pill and the trailing dropdown line up on the row.
        .frame(height: 30)
        .padding(.horizontal, 3)
        // The glass takes the DESTINATION's colour, not a fixed Ask blue: the pill
        // is the routing's face now, so Note ambers and Remind oranges the capsule
        // the way the ghost used to tint its word.
        .glassCapsule(in: Capsule(), brighter: false,
                      tint: agentOn ? Tokens.agentTint : destination.intentTint)
        // Fast and all but critically damped. A 30pt switch is not a panel: the
        // old 0.34/0.82 took ~300ms and arrived with a visible bounce, where the
        // tab bar this is modelled on settles a comparable move in ~175ms flat.
        // 0.26/0.86 lands at ~220ms with under half a point of overshoot — quick
        // enough to read as one snap, with just enough spring left to belong to
        // the rest of the panel. The same spring carries an Ask→Note→Remind word
        // change, so the capsule resizes on one curve either way.
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: agentOn)
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: ask)
        .accessibilityElement(children: .contain)
    }
}

/// One word of the bucket pill. Both halves carry their mark (the destination's —
/// bubble / pencil / bell — on the first, a code bracket `</>` for Agent); the
/// active one spells its name out beside it, the inactive one collapses to the bare
/// icon — dim, brightening on hover, the way over to the other side.
/// Clicking the active half is a no-op — the pill sets a bucket, never surprises.
///
/// **The pill has two switches, so it has two axes.** Changing BUCKET
/// (Ask⇄Agent) is horizontal: the well glides, one word wipes open while the
/// other wipes shut. Changing DESTINATION (Ask⇄Note⇄Remind) doesn't move
/// between halves at all — it substitutes a face in place — so it gets the
/// vertical one: mark and word roll up together and the new pair rises from
/// below, while the capsule springs to the new word's width around them. Read
/// the two side by side and you can tell which switch fired without reading a
/// single glyph, which is the whole point of spending the second axis on it.
private struct BucketWord: View {
    var title: String
    var icon: LucideIcons.Mark
    var active: Bool
    /// What a *roll* is keyed on — the live destination for the Ask half, `nil`
    /// for the Agent half, whose face is fixed. Keyed on the category rather than
    /// `title` so the bell doesn't somersault when only the recurrence suffix
    /// changes; that edit stays a quiet cross-fade inside the word (see
    /// `contentTransition` below).
    var swapKey: NotchModel.Panel?
    var action: () -> Void

    @State private var hovering = false

    /// How far the outgoing face lifts and the incoming one rises from — small on
    /// purpose. This is a 30pt pill, not a page: past ~6pt the roll stops reading
    /// as a substitution and starts reading as something falling through the
    /// glass. 5pt is enough to give the swap a direction, and still lets a 15pt
    /// glyph travel inside `rollBox` without the clip biting it.
    private static let rollTravel: CGFloat = 5
    /// The vertical room the word's clip leaves for that travel: the 12pt line
    /// (~15pt tall) plus the roll on both sides. Sized here rather than left to
    /// the text's own height, because `.clipped()` would otherwise slice the
    /// rolling glyphs off at their own baseline box.
    private static let rollBox: CGFloat = 26

    /// The destination swap itself. Asymmetric for the same reason the wipe's ink
    /// is: share one curve and both faces sit at half opacity through the middle
    /// of the move — the double exposure this replaced. So the old face is gone in
    /// ~100ms, before it has travelled far, and the new one comes up just behind
    /// it. Up-and-out / up-and-in in one direction always: a wheel that turns one
    /// way reads as "the destination changed", where a reversible roll would keep
    /// promising an order the classifier doesn't actually walk in.
    private static let roll = AnyTransition.asymmetric(
        insertion: .offset(y: rollTravel).combined(with: .opacity)
            .animation(.easeOut(duration: 0.20).delay(0.04)),
        removal: .offset(y: -rollTravel).combined(with: .opacity)
            .animation(.easeIn(duration: 0.10))
    )

    /// The spelled-out word's exact width. `Font.sf` IS the system face, so
    /// `NSFont.systemFont` measures the very glyphs SwiftUI will draw — which turns
    /// the label into plain arithmetic instead of a geometry read that only settles
    /// a frame later, and hands the pill's well the SAME number this word is sized
    /// from. The +1 keeps the last glyph clear of the clip below.
    static func labelWidth(_ title: String) -> CGFloat {
        ceil(NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
        ).size().width) + 1
    }

    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(active ? Tokens.text1
                                        : (hovering ? Tokens.text2 : Tokens.text4))
                // Asymmetric on purpose: the trailing 8pt the word used to pad
                // with now lives inside the label's box as the wipe's falloff.
                .padding(.leading, BucketTogglePill.wordPad)
                .padding(.trailing, BucketTogglePill.wordTrailPad)
                // Fill the pill's full height so the well behind it can be inset a
                // uniform amount on every side, instead of being sized by the text
                // and floating with an uneven top/bottom margin.
                .frame(maxHeight: .infinity)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        // No per-word `active` animation: the word's reveal and the dim⇄bright
        // colour change ride the pill's single spring (BucketTogglePill's
        // `.animation(value:)`), so both halves and the well move as one shot
        // rather than each easing on its own.
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private var content: some View {
        // Nothing here is ever inserted or removed by the BUCKET flip — that's the
        // whole point. The mark is permanent on BOTH halves, and the word stays in
        // the tree too, revealed by an animatable WIDTH (0 ⇄ its measured width)
        // under a clip. So the switch is one continuous interpolation on the pill's
        // spring: the word wipes open beside its mark while the other wipes shut
        // and the well glides between them. A `if active { Text }` instead would
        // pop the label in and out of layout and leave the outgoing word fading
        // outside the flow — the desynced, un-"一镜到底" version of this.
        //
        // A DESTINATION change is the one thing that does swap identity, because
        // it has to: the mark is a Path and two paths can't interpolate. It stays
        // "one shot" by keeping both faces in the same slot (the ZStacks below)
        // and rolling them together on one curve — the horizontal geometry never
        // learns a swap happened, it just springs to the new word's width.
        //
        // The mark is bigger AND heavier than a menu glyph (15/2.0 → 1.25pt of
        // stroke, against the menu's 13/1.75 → 0.95pt), because it carries more: on
        // the inactive side, with the word wiped shut, it is the ONLY thing naming
        // the other half of the switch, and it does that at 40% ink instead of the
        // menu's 55%. `weight` is grid-relative, so holding it at 2.0 through the
        // size bump is what lets the stroke ride up with the glyph rather than
        // staying pinned to the set's thinner line — deliberate, not an oversight.
        // (The SF mark this replaced ran `.bold` for the same reason.) It takes the
        // active side's ink from the shared `foregroundStyle`, so a live mark is
        // exactly as bright as the word beside it.
        HStack(spacing: 0) {
            // Two different paths can't interpolate, so a destination change
            // (bubble→pencil→bell) swaps identity and ROLLS. The ZStack is what
            // makes that a substitution rather than a shove: identity-swapped
            // views both live in the layout while the transition runs, and side
            // by side in the HStack the outgoing mark would push the word along
            // in front of it.
            ZStack {
                LucideIcon(mark: icon, size: 15, weight: 2.0)
                    .id(swapKey)
                    .transition(Self.roll)
            }
            // Same air around the glyph the SF mark had (11pt in 14), scaled.
            .frame(minWidth: BucketTogglePill.iconSlot)
            ZStack(alignment: .leading) {
                Text(title)
                    .font(.sf(12, weight: .medium))
                    // Within ONE destination the word can still change — a
                    // recurrence suffix ("Remind · Daily"→"· Weekly"). Identity
                    // holds across that, so it cross-fades in place instead of
                    // rolling the whole word for an edit the routing didn't make.
                    .contentTransition(.opacity)
                    // Ideal width regardless of the frame below, so the wipe slides
                    // the clip across a fully-typeset word instead of re-wrapping it.
                    .fixedSize()
                    .padding(.leading, BucketTogglePill.labelGap)
                    // The ink is the ONE thing that does NOT ride the pill's spring.
                    // Sharing that curve leaves both words parked at half opacity
                    // through the middle of the flip — two ghosts, the exact
                    // opposite of one continuous shot. So the outgoing word is gone
                    // in ~70ms (before its box has travelled far) and the incoming
                    // one comes up just BEHIND the wipe front, never ahead of it.
                    //
                    // It lives INSIDE the rolled view on purpose: an
                    // `.animation(_:value:)` wrapping the `.transition` below would
                    // put the roll inside a second animation scope, and which curve
                    // won would then be SwiftUI's business rather than ours. Here
                    // the two switches own strictly separate modifiers.
                    .opacity(active ? 1 : 0)
                    .animation(active ? .easeOut(duration: 0.16).delay(0.04)
                                      : .easeIn(duration: 0.07),
                               value: active)
                    // …and the word rolls on the SAME key and the same beat as the
                    // mark beside it, so the pair leaves and arrives as one face.
                    .id(swapKey)
                    .transition(Self.roll)
            }
                // Width is the wipe's (springs with the destination's word length);
                // the height is the roll's headroom. Both words sit leading-aligned
                // inside it, so a roll never nudges the mark or the pill's rim.
                .frame(width: BucketTogglePill.labelBoxWidth(title, spelled: active),
                       height: Self.rollBox,
                       alignment: .leading)
                .clipped()
                // …and the front itself is a gradient, not a razor: the glyph
                // crossing it rises through the falloff instead of being sliced
                // down the middle. At rest the 8pt zone sits past the last glyph,
                // in what used to be the word's trailing padding, so a settled
                // label is fully opaque.
                .mask(alignment: .leading) {
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .black.opacity(0)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: BucketTogglePill.wipeSoft)
                    }
                }
        }
    }
}

/// Presents a popover only once its anchor is standing still — and re-pins it
/// if the anchor moves underneath.
///
/// `.popover` on macOS is an NSPopover: it computes its screen position ONCE,
/// from the anchor's frame at presentation time, and never re-tracks SwiftUI
/// layout (the island animates entirely inside one hosting NSView, so AppKit
/// sees nothing move). Fire a picker mid-spring — ⌘⇧I pressed right on the
/// open edge, or a flag left armed while the body was unmounted — and the
/// card lands wherever the island happened to be that frame, its tail
/// visibly torn off the glass. The fix is temporal, not spatial: hold the
/// actual presentation until the anchor's global frame has been quiet for a
/// beat, and if the anchor slides under an open popover (the island
/// re-laying out, a chip growing on pick), drop and re-present so the tail
/// is glued again.
struct SettledPopover<PopContent: View>: ViewModifier {
    /// The caller's intent flag (usually a model @Published). `shown` is what
    /// the real `.popover` sees — it trails this by however long the anchor
    /// needs to stop moving, and reflects click-away dismissals back into it.
    @Binding var isPresented: Bool
    var arrowEdge: Edge
    @ViewBuilder var popoverContent: () -> PopContent

    @State private var shown = false
    /// True while `shown` is being cycled false→true to re-pin after an
    /// anchor move — tells the dismiss-sync below the drop wasn't the user's.
    @State private var regluing = false
    /// When the anchor's global frame last changed. `.distantPast` means "no
    /// move ever seen" — a settled anchor presents with zero added latency.
    @State private var lastMove = Date.distantPast

    /// How long the anchor must hold still to count as settled. The open
    /// spring (response 0.42) stops emitting layout deltas well inside this
    /// once its tail goes sub-pixel.
    private static var quiet: TimeInterval { 0.15 }

    init(isPresented: Binding<Bool>,
         arrowEdge: Edge = .bottom,
         @ViewBuilder popoverContent: @escaping () -> PopContent) {
        _isPresented = isPresented
        self.arrowEdge = arrowEdge
        self.popoverContent = popoverContent
    }

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                let frame = g.frame(in: .global)
                Color.clear
                    .onChange(of: frame) { old, new in
                        lastMove = Date()
                        // Anchor slid under an open popover — NSPopover won't
                        // follow, so re-pin once it settles. Sub-pixel layout
                        // jitter doesn't count; a real move does.
                        guard shown, !regluing,
                              abs(new.midX - old.midX) + abs(new.maxY - old.maxY) > 2
                        else { return }
                        regluing = true
                        shown = false
                        afterSettle {
                            shown = isPresented
                            regluing = false
                        }
                    }
            })
            .popover(isPresented: $shown, arrowEdge: arrowEdge) { popoverContent() }
            .onChange(of: isPresented) { _, wants in
                if wants {
                    afterSettle { if isPresented { shown = true } }
                } else {
                    shown = false
                }
            }
            // Click-away/Esc dismisses the NSPopover directly — reflect that
            // back into the intent flag so the model knows the card is gone.
            .onChange(of: shown) { _, s in
                if !s, !regluing, isPresented { isPresented = false }
            }
            // The intent flag can be armed while this view is unmounted (⌘⇧I
            // with the island closed leaves it set): present once the mount's
            // open spring lands. Seeding `lastMove` here is what makes the
            // gate wait — the spring's first frames haven't emitted a change
            // yet, and presenting on the mount frame is exactly the bug.
            .onAppear {
                guard isPresented else { return }
                lastMove = Date()
                afterSettle { if isPresented { shown = true } }
            }
    }

    /// Run `action` once the anchor has been still for `quiet`, checking on
    /// short hops (a spring's tail emits no "done" signal to observe). Gives
    /// up after ~1.2s and runs anyway — a continuously-reflowing body (a
    /// streaming answer) must not eat the popover entirely.
    private func afterSettle(_ action: @escaping () -> Void) {
        afterSettle(deadline: Date().addingTimeInterval(1.2), action)
    }

    private func afterSettle(deadline: Date, _ action: @escaping () -> Void) {
        let since = Date().timeIntervalSince(lastMove)
        if since >= Self.quiet || Date() >= deadline {
            action()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.quiet - since) + 0.02) {
                afterSettle(deadline: deadline, action)
            }
        }
    }
}
