import SwiftUI

/// The content that lives inside the glass, below the constant black notch zone.
/// Switches between idle / load / result exactly like the prototype's modes.
struct NotchBody: View {
    @ObservedObject var model: NotchModel
    /// Self-update state — read here only to badge the settings gear with a dot
    /// when a newer release is available (the action itself lives in settings).
    @ObservedObject private var updater = UpdaterService.shared
    /// Release-notes state — read here to surface the "what's new" cue in the idle
    /// input row once, on the first launch after an update (see `unseenVersion`).
    @ObservedObject private var whatsNew = WhatsNewService.shared
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
    /// field via `onCaretWidth`. Drives where the inline "— Ask"/"— Note" hint sits,
    /// so it trails the pinyin as you type rather than anchoring to the committed
    /// text (which lags a whole composition behind).
    @State private var caretWidth: CGFloat = 0
    /// Same live display width, but for the follow-up field. Its placeholder is a
    /// SwiftUI overlay (so the copy can cross-fade — see `followUpPlaceholderLabel`),
    /// and this is how the overlay knows to vanish the moment the editor shows
    /// anything — including pinyin that hasn't committed to `model.text` yet, which
    /// is exactly when the native placeholder would disappear.
    @State private var followUpCaretWidth: CGFloat = 0
    /// Small directional slide-in for the idle prompt as ↑/↓ recall swaps a past
    /// question in: set to a nonzero offset (with the step's direction) the instant
    /// a recall fires, then animated back to rest. See `model.recallPulse`.
    @State private var recallSlide: CGFloat = 0
    /// Drives the compact history filter field's first-responder. Set when the
    /// filter icon is tapped so the caret lands in the expanded field without a
    /// second click; reset when the filter collapses so it can re-arm next time.
    @State private var filterFocused = false
    /// Measured height of the immersive floating header (input, plus the quote
    /// preview and action chips when a clipboard quote is pending). The list's top
    /// runway and frost band are derived from this so the first row always rests
    /// clear of the header no matter how tall it gets — a plain input is short, a
    /// quote-with-chips header is tall. Seeded to the plain-input baseline so the
    /// first frame (before the preference lands) already clears a no-quote header.
    @State private var measuredImmersiveHeaderHeight: CGFloat = NotchBody.immersiveHeaderBaseline
    /// Whether the immersive header height has been measured at least once this open.
    /// The FIRST measurement (baseline → real height) must land silently — animating
    /// it forces a second, animated layout pass before the expand can even start,
    /// which read as a ~0.5s stall before the list moved. Only LATER changes (a quote
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
                idleView
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 15)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .onAppear {
            if model.open {
                refocusInput()
            }
        }
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
            // The guided first run leads on a fresh install — it owns the whole body
            // like settings/What's New, in the same glass and spring, and hands back
            // to the prompt when finished or skipped (see `OnboardingView`).
            if model.showOnboarding {
                OnboardingView(model: model)
                    .transition(moduleTransition)
            } else if model.showSettings {
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
                // shows a "which of how many" counter. The clipboard-quote preview
                // that used to share this slot has been removed — a copied clip no
                // longer echoes back above the prompt; its one-tap chips below the
                // input remain the way to act on it.
                if let recall = model.recallPosition {
                    recallCounterLine(recall)
                        .transition(moduleTransition)
                }

                idleInputRow

                // The one-tap action chips for the pending clipboard sit *below* the
                // prompt — the field stays the focus, with the shortcuts as a quiet
                // row beneath it. Suppressed while the recent list is open: the list
                // takes that same space below the prompt, and showing both stacks the
                // chips on top of the RECENT rows (a visible collision). Recent wins —
                // it's what the user just summoned — so the shortcuts fold away until
                // the list is closed again. Also suppressed while a note-save cue is up
                // ("Saving…" / "Added to Notes" / error): the save just consumed the
                // clipboard, so the action row is stale — fold it away and let the calm
                // confirmation stand alone rather than crowding it with shortcuts.
                // Also folded away during ↑/↓ recall: the box now holds a recalled
                // question, not the copied text, so "summarize this"-style chips would
                // act on the wrong thing.
                if model.pendingClipboard != nil && !model.showHistory
                    && noteFeedbackContent == nil && model.recallPosition == nil {
                    clipboardPresetChips()
                        .transition(moduleTransition)
                }

                // The recent list expands below the prompt once the clock is tapped.
                // (The immersive variant above handles the overflowing case.)
                if !model.hasText && !model.history.isEmpty && model.showHistory {
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
    private var idleInputRow: some View {
        inputRow(placeholder: L("input.placeholder"), followUp: false)
            .onChange(of: model.text) { _, _ in
                // Editing the field clears a stale note-save error so the cue
                // doesn't linger over a line the user is actively rewriting.
                if model.noteError != nil { model.noteError = nil }
            }
    }

    /// Take the immersive (input-floats-over-scroll) layout only when the recent
    /// list is both open and long enough to scroll. A short list that fits has
    /// nothing to flow under the input, so it keeps the calm compact layout —
    /// matching the same `> 6` overflow calibration the list itself uses.
    ///
    /// A pending clipboard quote no longer forces the compact fallback: the quote
    /// preview and its action chips ride inside the immersive floating header (above
    /// and below the input), and the runway grows to clear that taller header — so the
    /// frosted immersive surface stays consistent whether or not a quote is present.
    private var useImmersiveHistory: Bool {
        !model.hasText
            && model.showHistory
            && noteFeedbackContent == nil
            && model.recentVisible.count > 6
    }

    // MARK: - Immersive history

    /// The immersive recent layout: a tall scroll surface with the prompt floating
    /// over its top as a translucent header. The list's content reaches up behind
    /// the header (`immersiveTopReach`), so rows scroll under the input and frost +
    /// fade out rather than ending on a hard cut — the panel reads as one
    /// continuous surface. The manage bar (gear + Clear) FLOATS over the bottom-left
    /// as fixed chrome: the list runs full-height *behind* it, so rows can scroll
    /// down past the buttons and stay partly visible through/around the glass.
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
                    // The clipboard-quote preview that used to ride inside this
                    // floating header has been removed — a pending clip no longer
                    // echoes above the prompt. The header is now just the input; the
                    // runway shrinks back to the bare-input baseline accordingly.
                    idleInputRow
                    // No preset chips here: this IS the expanded Recent state, and
                    // the list owns the space below the prompt. Chips fold away to
                    // avoid a visible collision with the RECENT rows — matching the
                    // flat layout's same suppression when showHistory is open.
                }
                .padding(.bottom, 6)
                // Measure the header's real height so runway/frost track it.
                // A quote header is taller than a bare input; the preference feeds
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
                    // A later change (quote appearing/clearing) slides the runway
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
            // Fixed bottom chrome: gear + Clear, FLOATING over the bottom-left of the
            // full-height list. Because it's an overlay (not a sibling), the list runs
            // its whole height behind it — rows scroll down past the buttons and stay
            // partly visible through/around the translucent glass capsules. The glass
            // material gives the buttons enough body to stay legible over moving rows.
            .overlay(alignment: .bottomLeading) {
                // Pull the bar tighter into the bottom-left corner than the body's
                // 20pt horizontal / 22pt bottom insets would leave it: negative
                // padding tucks it ~10pt closer on each edge, still clear of the
                // 30pt NotchShape corner arc at the bar's height.
                manageBar
                    .padding(.leading, -10)
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

    /// The ↑/↓ recall counter shown above the input while walking history: a small
    /// "History" label + "pos / total" (newest = 1), so you can see how far back the
    /// current recalled question sits. (The clipboard-quote preview that once shared
    /// this slot has been removed — a copied clip no longer echoes above the prompt.)
    private func recallCounterLine(_ recall: (pos: Int, total: Int)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("History")
                .font(.sf(10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Tokens.text4)
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

    /// A *short* row of one-tap preset actions for the pending clipboard, sitting just
    /// beneath the prompt. Deliberately auxiliary — the prompt above is the focus — so
    /// by default only the few most-common actions (Summarize / Proofread / Translate)
    /// show, with a small "⋯" chip to reveal the rest (Key Points / Rewrite / tone) on
    /// demand. Tapping an action chip authors a referential query into the prompt and
    /// submits it, so the existing clipboard-injection path in `submit()` folds the
    /// copied text in — the chip is just a shortcut for typing "summarize this". The
    /// label/phrase script follows the copied text (CJK chips for CJK clips), so a
    /// Chinese clipboard offers 总结 / 校对 / 翻译 etc.
    private func clipboardPresetChips() -> some View {
        // The user's enabled quick-tools (XII-111): collapsed to the first few, the
        // rest tucked behind a "⋯" chip that unfurls on hover. Unchecked tools never
        // appear. Wraps via FlowLayout if a row ever overflows.
        FlowLayout(hSpacing: 6, vSpacing: 6) {
            // When the copied text itself reads as a note/reminder, lead with a one-tap
            // capture chip — filing the jot is the more likely intent than asking the AI
            // about it, so it sits ahead of the Ask presets. The verdict lands
            // asynchronously (~15ms after the row is up); the chip fades+scales in (and
            // the presets glide right) via the `.animation(value:)` on the row below.
            // Only while the prompt is empty: once there's typed text, Enter belongs to
            // that line (confirmClipboardCaptureIfIdle guards !hasText), so the whole
            // chip retires — scaling out to the leading edge while the Ask presets glide
            // left into its place — and returns the same way if the text is cleared.
            if let capture = model.pendingClipboardCapture, !model.hasText {
                ClipboardPresetChip(title: captureChipTitle(capture),
                                    tint: captureChipTint(capture),
                                    keyHint: true) {
                    model.runClipboardCapture(capture)
                }
                .transition(.scale(scale: 0.7, anchor: .leading).combined(with: .opacity))
            }
            ForEach(model.visibleClipboardPresets) { preset in
                translateChip(preset)
                    // The overflow chips (everything past the collapsed few) unfurl from the
                    // leading edge — scaling up and fading in as they push out on hover, and
                    // collapsing back the same way. Asymmetric so the fold-back reads as a
                    // tuck-in rather than a mirror of the reveal.
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.55, anchor: .leading)
                                .combined(with: .opacity),
                            removal: .scale(scale: 0.7, anchor: .leading)
                                .combined(with: .opacity)
                        )
                    )
            }
            // The "⋯" affordance: only when the enabled set is longer than the collapsed
            // count. Expands on *hover* (the whole row's onHover drives the flag), so the
            // extra chips unfurl in place; collapsed it's a quiet hint, expanded the
            // trailing chips have replaced it so it disappears on its own.
            if !model.clipboardPresetsExpanded
                && model.clipboardPresets.count > NotchModel.collapsedPresetCount {
                ClipboardPresetChip(title: "⋯") {
                    // Tap still works as a fallback for non-hover input.
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        model.clipboardPresetsExpanded = true
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
        // Hover anywhere over the chip row to unfurl the overflow actions in place;
        // leaving folds them back to the collapsed few. Driving the expansion off the
        // *row's* hover (not the tiny "⋯" chip's) lets the pointer travel onto the
        // newly-revealed chips without collapsing them.
        .onHover { hovering in
            guard model.clipboardPresets.count > NotchModel.collapsedPresetCount else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                model.clipboardPresetsExpanded = hovering
            }
        }
        // Tie the FlowLayout reflow (capture chip landing AND overflow unfurling) to the
        // same spring that carries the per-chip transitions, so existing chips glide to
        // their new positions while new ones scale in beside them.
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.visibleClipboardPresets.count)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: model.pendingClipboardCapture)
        // The capture chip's retire/return as typing starts/clears rides the same
        // spring: the chip scales out through its `.transition` while the presets
        // glide left to close the gap (and the reverse on clearing the text).
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: model.hasText)
    }

    /// One clipboard-preset chip, with the Translate chip getting special treatment:
    /// it shows both preferred languages (e.g. "译 中/En") and surfaces a context
    /// menu split into pref1 / pref2 submenus. Left-click still runs the preset
    /// immediately. All other presets render as plain chips.
    @ViewBuilder
    private func translateChip(_ preset: NotchModel.ClipboardPreset) -> some View {
        if preset == .translate {
            // Chip label: "译 →En" — preset label + the resolved target for the
            // pending clip. We route the clip the same way the prompt does and name
            // only the target language ("→En"), dropping the source to keep the chip
            // compact. See `NotchModel.translateChipDirection`.
            let chipTitle: String = "\(preset.label) \(model.translateChipDirection)"
            ClipboardPresetChip(title: chipTitle) {
                model.runClipboardPreset(preset)
            }
            .contextMenu {
                // Two sections: one per preference slot. Each lists all languages
                // with a checkmark on the current value for that slot.
                Section(L("translation.pref1")) {
                    ForEach(TranslationLanguage.allCases) { lang in
                        Button {
                            model.translationPref1 = lang
                        } label: {
                            if lang == model.translationPref1 {
                                Label(lang.label, systemImage: "checkmark")
                            } else {
                                Text(lang.label)
                            }
                        }
                    }
                }
                Section(L("translation.pref2")) {
                    ForEach(TranslationLanguage.allCases) { lang in
                        Button {
                            model.translationPref2 = lang
                        } label: {
                            if lang == model.translationPref2 {
                                Label(lang.label, systemImage: "checkmark")
                            } else {
                                Text(lang.label)
                            }
                        }
                    }
                }
            }
        } else {
            ClipboardPresetChip(title: preset.label) {
                model.runClipboardPreset(preset)
            }
        }
    }

    /// Label for the leading clipboard-capture chip, in the copied text's script and
    /// naming where the tap files it: Apple Notes vs. Apple Reminders. Mirrors the
    /// inline send hint's wording so the chip reads as the same destination.
    private func captureChipTitle(_ panel: NotchModel.Panel) -> String {
        switch panel {
        case .reminder: return L("capture.remind")
        case .note, .chat: return L("capture.note")
        }
    }

    /// The faint background hue for the capture chip — keyed to its destination's app
    /// colour so the chip reads as "this goes to Reminders/Notes": Reminders' orange,
    /// Notes' amber-yellow. Washed in at low opacity by `glassCapsule`, so it stays a
    /// whisper of colour over the same glass material, not a solid fill.
    private func captureChipTint(_ panel: NotchModel.Panel) -> Color {
        switch panel {
        case .reminder: return .orange
        case .note, .chat: return .yellow
        }
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

    /// The manage bar, pinned to the BOTTOM-LEFT of the recent panel in both the
    /// compact and immersive layouts. A single ⋯ chip that pops the manage MENU
    /// upward (filter by source, Settings, Clear) — see `manageMenu`. While a
    /// source filter is active and the menu is closed, a small tinted chip beside
    /// the ⋯ names the filter and clears it on tap, so the narrowed list never
    /// reads as "history lost". Always visible — fixed chrome below the list.
    ///
    /// Used by `historySection` (compact) as a VStack sibling below the list, and by
    /// `immersiveHistoryView` as an overlay over the bottom-left of the scroll frame.
    private var manageBar: some View {
        HStack(spacing: 6) {
            // The single ⋯ chip. It only toggles the menu. The passive update dot
            // rides on it (the update action lives behind Settings, one level down).
            moreEntry

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
            Spacer()   // push the controls to the LEFT; Spacer sits at the trailing end
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
        // Leading inset trimmed (the outer body already pads 20pt) so the bar tucks
        // further into the bottom-left corner; the trailing 8 just keeps the Spacer
        // honest. Bottom-left placement is finished by the call-site bottom padding.
        .padding(.leading, 2)
        .padding(.trailing, 8)
    }

    /// The ⋯ entry: a single Liquid Glass chip that pops the manage menu up above
    /// itself. Carries the passive update dot (the update action itself sits
    /// behind Settings, one level in).
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
        .overlay(alignment: .topTrailing) {
            if case .available = updater.phase {
                Circle()
                    .fill(Tokens.text2)
                    .frame(width: 5, height: 5)
                    .offset(x: -1, y: 1)
            }
        }
    }

    /// The upward manage menu: one small glass card holding everything the old
    /// horizontal unfurl carried, plus the source filter. Top to bottom: a row of
    /// three filter chips (Note / Remind / Ask), then Settings, then Clear — the
    /// destructive action last, in the standard menu position.
    private var manageMenu: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 2) {
            // Filter — one chip per history source, in each source's app colour
            // (Notes amber, Reminders orange, Ask a cool blue). Tap to narrow the
            // list to that source; tap the active one again to show everything.
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.sf(10, weight: .medium))
                    .foregroundStyle(Tokens.text4)
                    .padding(.trailing, 1)
                ManageFilterChip(model: model, source: .note) { manageExpanded = false }
                ManageFilterChip(model: model, source: .reminder) { manageExpanded = false }
                ManageFilterChip(model: model, source: .ask) { manageExpanded = false }
            }
            .padding(.horizontal, 8)
            .padding(.top, 3)
            .padding(.bottom, 9)

            // Hairline between filter and actions — fades out at both ends like a
            // light caught across the glass, not a flat printed rule.
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0), .white.opacity(0.14), .white.opacity(0)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(height: 0.5)
                .padding(.horizontal, 2)
                .padding(.bottom, 4)

            manageMenuRow(icon: "gearshape", title: L("recent.menu.settings"), shortcut: "⌘,") {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    manageExpanded = false
                    model.toggleSettings()
                }
            }
            // Clear is destructive, so it arms a confirmation rather than wiping
            // history on first tap. The card itself is rendered centered over the
            // whole island (see NotchIsland) — not anchored here — so it lands in
            // the middle of the panel instead of down by the menu.
            manageMenuRow(icon: "trash", title: L("recent.clear"), destructive: true) {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    manageExpanded = false
                    model.confirmingClear = true
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

    /// One full-width action row of the manage menu — icon, label, optional
    /// trailing shortcut hint — with the same gentle hover wash the history rows
    /// use, so the menu reads as part of the same surface.
    private func manageMenuRow(
        icon: String, title: String, shortcut: String? = nil,
        destructive: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.sf(11, weight: .medium))
                    .foregroundStyle(destructive ? Color.red.opacity(0.75) : Tokens.text3)
                    .frame(width: 14)
                Text(title)
                    .font(.sf(12, weight: .medium))
                    .foregroundStyle(destructive ? Color.red.opacity(0.85) : Tokens.text2)
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
        .buttonStyle(HistoryRowStyle())
    }

    /// The collapsed-state reminder that a source filter is narrowing the list:
    /// a small tinted capsule beside the ⋯ naming the filter, with an × — tap
    /// anywhere on it to clear the filter and show everything again.
    private func activeFilterChip(_ source: NotchModel.HistoryItem.Source) -> some View {
        ActiveFilterChip(model: model, source: source)
    }

    /// The compact recent list (≤6 visible rows) with the manage bar (gear + Clear)
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
    /// with `.padding(.bottom, 6)` → 54pt measured for the no-quote case. The seed is
    /// set to exactly 54 so the `max(h, baseline)` clamp matches the real first-frame
    /// measurement and never over-reserves runway.
    private static let immersiveHeaderBaseline: CGFloat = 54

    /// Breathing room between the bottom of the floating header and the first row's
    /// resting top. `baseline (54) + gap (12) = 66`, the runway the no-quote layout
    /// uses; a quote header measures taller and the runway grows with it.
    private let immersiveHeaderGap: CGFloat = 12

    /// How far the immersive list's content reaches UP behind the floating header so
    /// the first row rests just clear of it. Derived from the *measured* header height
    /// (`measuredImmersiveHeaderHeight`) rather than a constant, because the header is
    /// not fixed: a plain input is short, but a pending clipboard quote adds a preview
    /// line above the input and a row of action chips below it. Tracking the real
    /// height keeps the first row clear whether or not a quote is present.
    private var immersiveTopReach: CGFloat { measuredImmersiveHeaderHeight + immersiveHeaderGap }

    /// Height of the top frost band, in points. Kept SHORTER than the layout runway
    /// (`immersiveTopReach`) on purpose: the band must taper fully to clear before it
    /// reaches the first row's resting position, or the blurred light-grey glyphs of
    /// that row stack into a bright halo (see `ProgressiveTopBlur`). A 4pt margin under
    /// the runway is the tuned ceiling — over the 320pt viewport the deepest frost layer
    /// is also the faintest, so its tail grazing the runway edge stays imperceptible
    /// while the opaque bulk of the frost sits above. Derived from the runway (not a
    /// constant) so the band tracks the header: it grows when a quote raises the header
    /// and shrinks back for a plain input, always ending just above the first row.
    private var immersiveBlurReach: CGFloat { max(immersiveTopReach - 4, 0) }

    /// How far the immersive list's content reaches DOWN behind the floating manage
    /// bar — the bottom mirror of `immersiveTopReach`. It's the runway the last rows
    /// scroll down into and dissolve (fade + frost) behind the gear/Clear chrome, so
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
    private let immersiveListHeight: CGFloat = 320

    /// The recent list. `immersive` swaps the compact, below-the-header list for
    /// the tall variant whose content scrolls UP behind the floating input —
    /// frosting and fading as it goes (see `immersiveTopReach`). Only used once
    /// the list overflows; a short list stays compact under the header.
    private func historyList(immersive: Bool = false) -> some View {
        // More rows than fit the window → the list scrolls. In the compact layout
        // the first row sits right under the (non-scrolling) RECENT header, so the
        // TOP never needs a fade — a fixed top pad there would just open a dead gap
        // below the header. The immersive layout is the opposite: its top reaches
        // up behind the floating input, so it DOES taper (fade + frost) there.
        // The compact frame holds ~6 rows (~35pt each in 220pt); the fade + scroll
        // only earn their keep past that. Calibrated to the current height so the
        // bottom taper turns on right when the list actually overflows.
        let overflowing = model.recentVisible.count > 6
        return ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
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
                            } else if item.source == .ask {
                                Text(relativeTime(item.t))
                                    .font(.sf(11).monospacedDigit())
                                    .tracking(0.2)
                                    .foregroundStyle(Tokens.text4)
                            } else {
                                // The jump to Notes/Reminders lives on its OWN button,
                                // not the row body — tapping the row must never yank the
                                // user out to another app they didn't ask to open. Only
                                // this trailing pill switches apps. `.plain` + its own
                                // `contentShape` isolate the hit region so a tap here
                                // fires the jump and doesn't bubble to the row's Ask path.
                                Button { model.openCaptureInApp(item) } label: {
                                    HStack(spacing: 3) {
                                        Text(item.source == .note ? L("recent.badge.notes") : L("recent.badge.reminders"))
                                            .font(.sf(11).weight(.medium))
                                            .tracking(0.2)
                                        Image(systemName: "arrow.up.right")
                                            .font(.sf(9, weight: .semibold))
                                    }
                                    .foregroundStyle(Tokens.text4)
                                    .padding(.vertical, 3)
                                    .padding(.horizontal, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(CaptureJumpButtonStyle())
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
                    .transition(
                        .move(edge: .leading)
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
            }
            // In the immersive layout the TOP gets an inset (`immersiveTopReach`):
            // the runway rows scroll up into, behind the floating input, so the first
            // row rests *below* the input at idle but can travel up under it. The
            // compact layout keeps its top tight under the (non-floating) RECENT
            // header. The bottom inset differs by layout: the immersive list runs its
            // rows full-height behind the floating manage bar (so the last rows stay
            // visible through/around the buttons) and only needs a little clearance
            // off the rounded corner; the compact list reserves the full edgeFade so
            // its bottom taper falls over empty space, not a row.
            .padding(.top, immersive ? immersiveTopReach : 0)
            // Immersive: a bottom runway rows scroll DOWN into behind the manage bar
            // (always present — the immersive layout only mounts for an overflowing
            // list). Compact: the edgeFade reserve, only when actually overflowing.
            .padding(.bottom, immersive ? immersiveBottomReach : (overflowing ? edgeFade : 0))
        }
        // Immersive: a tall surface that fills the whole panel; the manage bar floats
        // over its bottom-left. Compact: ~6 rows before the list scrolls, so a short
        // Recent list doesn't reserve a tall empty band. Older rows are a scroll away.
        .frame(maxHeight: immersive ? immersiveListHeight : 220)
        .scrollIndicators(.never)
        // Compact: only the bottom fades (the RECENT header caps the top), at the
        // shared 64pt. Immersive: BOTH edges taper — the top dissolves rows sliding
        // up behind the input, the bottom dissolves rows sliding DOWN behind the
        // floating manage bar (so reaching the end reads as rows sliding under the
        // gear/Clear, mirroring the top). Each edge's taper length tracks its own
        // runway (`immersiveTopReach` / `immersiveBottomReach`).
        .scrollEdgeFade(
            top: immersive,
            bottom: immersive ? true : overflowing,
            topFade: immersive ? immersiveTopReach : edgeFade,
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
            // Text-only wait line — no animated dots. Before any tool runs the status
            // is empty, so fall back to "Thinking…" rather than leaving the line blank.
            Group {
                let label = model.thinkingStatus.isEmpty ? L("agent.activity.thinking") : model.thinkingStatus
                CrossfadeText(text: label, font: 15, color: Tokens.text2)
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
                // actionable error must never be hidden behind the scroll).
                if isAnswerClipped && model.askError == nil && model.isConfigured {
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
            // A failed Ask gets an actionable capsule right under the answer (XII-85):
            // "Open Settings" when there's no key to retry with, "Try again" otherwise.
            if let askError = model.askError {
                errorActionRow(askError)
                    .padding(.top, isAnswerClipped ? 8 : 24)
                    .transition(.opacity)
            } else if !isAnswerClipped {
                // Short layout: follow-up input (or setup CTA) as a sibling, as before.
                Group {
                    if model.isConfigured {
                        followUpRow
                    } else {
                        setupModelRow
                    }
                }
                .padding(.top, 24)
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
                    .font(.system(size: 13, weight: .medium))
                Text(L("result.setUpModel"))
                    .font(.sf(14.5, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
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
                    .font(.system(size: 13, weight: .medium))
                Text(askError.needsSetup ? L("error.openSettings") : L("error.retry"))
                    .font(.sf(14.5, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: askError.needsSetup ? "arrow.up.right" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
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
                growingConversation
            }
        }
        // Measure the thread's INTRINSIC height — what it wants to be with no ceiling
        // — to drive ONLY the `clipped` switch above. This can't read the visible
        // layout's height: the clipped layout is pinned to `answerMaxHeight` (300), so
        // measuring it would report 300, which isn't > 300, and `clipped` would
        // flip-flop on the boundary. Instead a hidden, unconstrained copy of the same
        // turn stack reports its natural height. It's laid out but never drawn
        // (`.hidden()`), and overlaid at zero size so it never affects this view's
        // layout. The measurement lagging the content by a pass is harmless now — it
        // feeds a boolean threshold, not a frame height, so it can't jump.
        .background(alignment: .top) {
            // The hidden copy reports its NATURAL height via the GeometryReader in its
            // background. The copy is given the same width as the real thread (matched
            // through the enclosing layout) but left vertically unconstrained, so the
            // reader sees the intrinsic content height. `.hidden()` keeps it invisible;
            // it sits in a `.background` collapsed to this view's own frame, so however
            // tall the probe wants to be it can't push this view taller — a background
            // takes the primary content's size, overflow just isn't drawn.
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
        .onPreferenceChange(AnswerHeightKey.self) {
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
            ForEach(model.turns) { turn in
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
                    ForEach(model.turns) { turn in
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
        .modifier(ConditionalTopBlur(active: true, height: clippedTopBlurReach, maxRadius: 22))
        // Progressive blur on the bottom runway, mirroring the immersive manage bar's
        // ConditionalBottomBlur: rows scrolling down into the runway frost out as they
        // go behind the input. Kept 4pt shorter than the runway (`clippedBottomBlurReach`
        // = 76pt) so the band clears the last resting row (~82pt up) — no halo at rest.
        // maxRadius 22 matches the manage bar (comparable chrome). Always active —
        // clippedConversation is only ever mounted when `isAnswerClipped`.
        .modifier(ConditionalBottomBlur(active: true, height: clippedBottomBlurReach, maxRadius: 22))
    }

    /// Height of the taper at each scroll edge, in points. Generous on purpose so
    /// the dissolve is a long, gentle gradient — not a thin line that still reads
    /// as a cut. The scroll content carries matching top/bottom padding, so the
    /// fade falls across that breathing room rather than over live text.
    private let edgeFade: CGFloat = 64

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
                if turn.usedClipboard {
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
            AssistantTurnView(
                text: turn.text,
                streaming: turn.streaming,
                activity: turn.streaming ? model.currentActivity : nil,
                thinkingWord: model.currentThinkingWord,
                sources: turn.sources,
                hoveredSourceID: $hoveredSourceID,
                sourceCloseWork: $sourceCloseWork,
                onInAppCopy: { model.rebaselineClipboardAfterInAppWrite() },
                onRegenerate: isLastTurn ? { model.regenerateLastAnswer() } : nil,
                // Right-click the regenerate button to re-run this answer with a
                // different model, once (XII-135). Only on the last turn (same gate
                // as plain regenerate).
                regenerateModels: isLastTurn ? model.regenerateModelOptions : [],
                onRegenerateWith: isLastTurn ? { model.regenerateLastAnswer(model: $0) } : nil,
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

    // Back chevron leads (the question itself is the "You" turn below, so no title
    // here); a pin button trails top-right. Pinning holds the panel open when the
    // pointer leaves, so the answer can be read without hovering it (see
    // `NotchModel.collapseOnLeave`).
    private var resultHeader: some View {
        HStack(spacing: 10) {
            backButton
            Spacer(minLength: 0)
            ResultPinButton(
                pinned: model.isAnswerPinned,
                toggle: {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        model.toggleAnswerPin()
                    }
                }
            )
        }
    }

    /// Back to a fresh conversation: clears this Q&A off the screen and returns to
    /// the idle prompt (panel stays open). Safe mid-answer — an in-flight stream
    /// finishes detached and lands in Recent (see `NotchModel.newChat`). Also bound
    /// to the ← arrow key (see ContentView's key handler), so a glance-and-go feels
    /// keyboard-native.
    private var backButton: some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                model.newChat()
            }
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.text2)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(RecentEntryStyle())
    }

    // MARK: - Inputs

    private func inputRow(placeholder: String, followUp: Bool) -> some View {
        let fontSize: CGFloat = followUp ? 14.5 : 16.5
        return HStack(spacing: 12) {
            // The field, with a Siri-style ghost hint trailing the typed text on the
            // same line. This `inputRow` renders the hint only for the idle prompt
            // (`!followUp`); the mid-thread field is `followUpRow`, which carries its
            // own copy of the same hint. A `GeometryReader` hands the hint the row's
            // width so it knows where to dock once a long line runs out of room.
            ZStack(alignment: .leading) {
                GeometryReader { geo in
                    if !followUp {
                        InlineSendHint(
                            label: model.submitLabel,
                            fontSize: fontSize,
                            caretWidth: caretWidth,
                            availableWidth: geo.size.width,
                            tint: model.effectiveSubmitPanel.intentInk
                        )
                        .frame(height: geo.size.height, alignment: .center)
                    }
                }
                .allowsHitTesting(false)

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
                        let steppedList = withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                            model.historyNavigateUp()
                        }
                        if steppedList { return true }
                        return model.recallPreviousQuestion()
                    },
                    // Keep ↑/↓ routed to recall even after the box fills with a
                    // recalled question, so pressing ↑ again steps further back
                    // instead of moving the caret.
                    isRecalling: followUp ? { false } : { model.isRecallingHistory },
                    onSubmitNav: followUp ? { false } : {
                        // Enter first confirms a keyboard-highlighted Recent row; failing
                        // that, on an empty prompt it fires the leading capture chip
                        // (save the copied jot). Either short-circuits the empty submit.
                        model.historyConfirmHighlighted() || model.confirmClipboardCaptureIfIdle()
                    },
                    // Tab steps where Enter sends this line (Ask → Note → Remind →…)
                    // when the classifier guessed wrong — the inline hint steps with
                    // it. Only meaningful with text in the field; an empty field's Tab
                    // is still swallowed so focus never wanders out of the prompt.
                    onTab: followUp ? { false } : {
                        if model.hasText { model.toggleSubmitPanel() }
                        return true
                    },
                    // Live width of committed text + any composing pinyin, so the
                    // inline hint trails the caret as the IME composes. Only the idle
                    // prompt feeds `caretWidth` here; `followUpRow` owns its own
                    // `followUpCaretWidth` tracking and its own hint overlay.
                    onCaretWidth: followUp ? { _ in } : { caretWidth = $0 }
                )
                // Reserve the hint's docking slot at the row's trailing edge: a long
                // line scrolls within this narrower field while "— Ask"/"— Note"
                // holds in the reserved strip beside it, never overlapped, never lost.
                // The reserved width follows the current label so short labels don't
                // waste space; the ZStack animation keeps the resize smooth.
                .padding(.trailing, followUp ? 0 : InlineSendHint.reservedTrailingWidth(label: model.submitLabel, fontSize: fontSize))
                .animation(.smooth(duration: 0.25), value: model.submitLabel)

                // The placeholder, drawn as a SwiftUI label over the (natively
                // placeholder-less) field so its appearance can FADE — on emptying
                // the field the native swap was an instant pop. Gated on the caret
                // width, not just `hasText`, so in-progress pinyin hides it too.
                if !followUp && !model.hasText && caretWidth == 0 {
                    Text(placeholder)
                        .font(.system(size: fontSize))
                        .foregroundStyle(Tokens.placeholder)
                        .lineLimit(1)
                        // Sit on the NSTextField cell's own ~2pt left inset so the
                        // label lands exactly where the native placeholder drew.
                        .padding(.leading, 2)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            // Drives the placeholder fade in BOTH directions (first character in,
            // last character out — including pinyin pre-composition, which flips
            // `caretWidth` while `hasText` is still false).
            .animation(.easeOut(duration: 0.16), value: caretWidth == 0)
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

            // With the destination now spelled out inline beside the caret, the
            // trailing send pill would just repeat it — so while there's text the
            // inline hint owns that job and the trailing slot stays empty. When the
            // field is empty the faint clock entry tucks in there to toggle Recent,
            // and — on the first launch after an update — a "what's new" cue leads
            // it, the one-tap way into the release notes.
            if !model.hasText && !followUp {
                HStack(spacing: 8) {
                    if whatsNew.unseenVersion != nil {
                        whatsNewCue
                            .transition(.opacity)
                    }
                    if !model.history.isEmpty {
                        recentEntry
                            .transition(.opacity)
                    }
                }
            }
        }
        .frame(height: followUp ? 30 : 48)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.hasText)
    }

    /// The first-launch-after-update cue: a quiet "what's new" pill in the idle
    /// input's trailing slot. Tapping it opens the release-notes panel, and
    /// `openWhatsNew` marks this version seen, so the cue shows once.
    private var whatsNewCue: some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                model.openWhatsNew(on: nil)
            }
        } label: {
            Text(L("whatsnew.cue"))
                .font(.sf(12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(Tokens.text3)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(L("whatsnew.title"))
    }

    /// The minimal clock entry that opens / closes the recent list.
    private var recentEntry: some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                model.showHistory.toggle()
                // Closing via the clock drops any keyboard highlight; opening via
                // the clock starts un-highlighted (the caret stays in the input).
                model.highlightedHistoryIndex = nil
            }
        } label: {
            // A downward chevron reads as "pull the recent list down"; it flips to
            // point up once the list is open, so the same control says "close" on
            // the way back — the natural disclosure direction for a panel that
            // unfurls below the prompt.
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.showHistory ? Tokens.text2 : Tokens.text4)
                .rotationEffect(.degrees(model.showHistory ? 180 : 0))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .animation(.spring(response: 0.32, dampingFraction: 0.8), value: model.showHistory)
        }
        .buttonStyle(RecentEntryStyle())
        .help(L("recent.recent"))
    }

    private var followUpRow: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                // Same Siri-style ghost hint the idle prompt carries, now on the
                // mid-thread field too: "— Ask"/"— Note"/"— Remind" trailing the caret
                // so a routed-by-intent follow-up shows its destination, and Tab's
                // correction step is finally visible here. Rendered behind the field
                // and hit-transparent. Mounted unconditionally, exactly like the idle
                // row: the hint's OWN `visible` gate (caretWidth > 0, so it covers
                // CJK/IME pre-composition) drives its materialize in/out. An outer
                // structural `if` here would bypass that dissolve and hard-pop the
                // ghost on the first/last character.
                GeometryReader { geo in
                    InlineSendHint(
                        label: model.submitLabel,
                        fontSize: 14.5,
                        caretWidth: followUpCaretWidth,
                        availableWidth: geo.size.width,
                        tint: model.effectiveSubmitPanel.intentInk
                    )
                    .frame(height: geo.size.height, alignment: .center)
                }
                .allowsHitTesting(false)

                PromptField(
                    // The native placeholder stays empty on purpose: NSTextField can
                    // only hard-swap its placeholder string, so the slot is owned by
                    // the SwiftUI labels below, which cross-fade their copy instead.
                    text: $model.text,
                    placeholder: "",
                    fontSize: 14.5,
                    focusTrigger: focused,
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
                        if model.hasText { model.toggleSubmitPanel() }
                        return true
                    },
                    // Lets the overlay placeholder hide itself the instant the editor
                    // shows ANYTHING — committed text or still-composing pinyin (which
                    // isn't in `model.text` yet) — matching the native behaviour.
                    onCaretWidth: { followUpCaretWidth = $0 }
                )
                // Reserve the hint's docking slot at the trailing edge, exactly like
                // the idle row, so typed text scrolls within a narrower field and the
                // "— Ask"/"— Remind" ghost never overlaps it. Width follows the current
                // label so short labels don't leave a dead strip on the right.
                .padding(.trailing, InlineSendHint.reservedTrailingWidth(label: model.submitLabel, fontSize: 14.5))
                .animation(.smooth(duration: 0.25), value: model.submitLabel)
                // The placeholder, shown only while the editor is truly empty —
                // committed text AND in-progress pinyin both hide it.
                if !model.hasText && followUpCaretWidth == 0 {
                    followUpPlaceholderLabel
                        // Nudge to sit on the NSTextField cell's own ~2pt left inset
                        // so the label lands where the placeholder was, not 2pt left.
                        .padding(.leading, 2)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            // Drives the placeholder's fade during IME pre-composition: pinyin
            // showing in the editor flips `followUpCaretWidth` while `hasText` is
            // still false, and the row-level hasText animation never fires — so
            // without this key the placeholder would hard-pop instead of fading.
            .animation(.easeOut(duration: 0.16), value: followUpCaretWidth == 0)

            // The send button appears the moment the user starts typing a
            // follow-up. (The "continue in ChatGPT/Claude" handoff used to rest
            // here while the field was empty; it now lives in the answer footer
            // with the other per-answer actions — see `AssistantTurnView`.)
            if model.hasText {
                SendButton(compact: true) { model.submitCurrent() }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        // Pin the row to the height it has WITH the send button (27pt button),
        // so it stays put when the button shows/hides instead of growing.
        .frame(height: 27)
        .padding(.leading, 13)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(focused ? 0.08 : 0.05))
                // A whisper of the destination's colour washed over the box while
                // there's text — the background twin of the tinted "— Note" ghost,
                // so the field itself leans toward where Enter will send the line.
                // Fades out on an empty field (destination is just the default).
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(model.effectiveSubmitPanel.intentTint
                            .opacity(model.hasText ? 0.045 : 0))
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(focused ? 0.20 : 0.10), lineWidth: 0.5)
        )
        // Flash the field's rim when the destination flips (Ask⇄Note⇄Remind) — the
        // peripheral twin of the inline "— Ask"/"— Note" word swap, in the NEW
        // destination's colour. Keyed on the intent *category* so a
        // recurrence-suffix edit doesn't pulse.
        .intentChangePulse(on: model.effectiveSubmitPanel,
                           shape: RoundedRectangle(cornerRadius: 12),
                           tint: model.effectiveSubmitPanel.intentInk)
        .animation(.smooth(duration: 0.25), value: model.effectiveSubmitPanel)
        .animation(.easeOut(duration: 0.2), value: focused)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.hasText)
    }

    /// The follow-up field's placeholder, drawn as a SwiftUI label in the slot the
    /// native placeholder would occupy (same font, colour and inset). SwiftUI
    /// ownership (rather than the NSTextField's own placeholder) is what lets it
    /// hide the instant the field shows anything — including still-composing
    /// pinyin, which the native placeholder wouldn't yield to.
    private var followUpPlaceholderLabel: some View {
        Text(L("result.followUp"))
            .font(.sf(14.5))
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
            .animation(.easeOut(duration: 0.16), value: selected)
            .animation(.easeOut(duration: 0.16), value: hovering)
    }
}

/// The trailing "open in Notes/Reminders" pill on a capture row. A quiet chip at
/// rest that firms up on hover — enough to read as a tappable target distinct
/// from the row, so the user knows *this* is what jumps them out to the app (the
/// row body no longer does). Kept low-key so it doesn't shout over the row title.
struct CaptureJumpButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let on = hovering || configuration.isPressed
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(on ? 0.08 : 0))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.thinMaterial)
                            .opacity(on ? 0.28 : 0)
                    )
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.14), value: hovering)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// Recent-row VoiceOver wiring, split by kind. An Ask row combines its children
/// into one element that reopens the thread. A capture row stays a *container*
/// so its separate trailing jump button remains an independently-focusable
/// control — folding it in (`.combine`) would hide the one control that jumps.
private struct RecentRowAccessibility: ViewModifier {
    let item: NotchModel.HistoryItem
    func body(content: Content) -> some View {
        if item.source == .ask {
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

/// The destination colour of an intent — the SAME palette everywhere a
/// destination shows its face: Ask a cool blue, Note the Notes amber, Remind
/// the Reminders orange. Read by the inline "— Ask/— Note/— Remind" ghost, the
/// follow-up field's background wash, and the intent-change rim pulse, so the
/// input's colour story always matches the filter chips and capture chips.
extension NotchModel.Panel {
    /// Saturated body colour — right for low-opacity WASHES over the dark glass
    /// (the follow-up box's background lean), where saturation survives dilution.
    var intentTint: Color {
        switch self {
        case .chat:     return .blue
        case .note:     return .yellow
        case .reminder: return .orange
        }
    }

    /// The same hue lifted toward white — for TEXT and glows on the dark glass.
    /// A fully saturated colour used as ink sinks into the dark background (blue
    /// especially reads as a murky shadow); these luminous pastels read as
    /// coloured *light* instead, keeping the hue legible and the ghost elegant.
    var intentInk: Color {
        switch self {
        case .chat:     return Color(red: 0.66, green: 0.80, blue: 1.00)
        case .note:     return Color(red: 1.00, green: 0.89, blue: 0.58)
        case .reminder: return Color(red: 1.00, green: 0.78, blue: 0.56)
        }
    }
}

/// The one place a history source maps to its filter-chip face: the label key
/// and the source's app colour (Notes amber, Reminders orange, Ask a cool blue).
/// Shared by the manage menu's chips and the collapsed active-filter chip so the
/// two can never drift apart.
extension NotchModel.HistoryItem.Source {
    fileprivate var filterTitle: String {
        switch self {
        case .note:     return L("recent.filter.note")
        case .reminder: return L("recent.filter.remind")
        case .ask:      return L("recent.filter.ask")
        }
    }
    fileprivate var filterTint: Color {
        switch self {
        case .note:     return .yellow
        case .reminder: return .orange
        case .ask:      return .blue
        }
    }
}

/// One source-filter chip inside the manage menu. The active chip wears its
/// source's tint (the same wash the capture chips use); inactive chips are
/// plain glass that brightens on hover. Tapping the active chip again clears
/// the filter. Selecting one folds the menu so the narrowed list is
/// immediately visible underneath.
private struct ManageFilterChip: View {
    @ObservedObject var model: NotchModel
    var source: NotchModel.HistoryItem.Source
    var collapse: () -> Void

    @State private var hovering = false

    var body: some View {
        let active = model.historySourceFilter == source
        Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                model.historySourceFilter = active ? nil : source
                collapse()
            }
        } label: {
            Text(source.filterTitle)
                .font(.sf(11, weight: .medium))
                .foregroundStyle(active ? Tokens.text1 : (hovering ? Tokens.text2 : Tokens.text3))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            .glassCapsule(in: Capsule(), brighter: active || hovering,
                          tint: active ? source.filterTint : nil)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
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
            .glassCapsule(in: Capsule(), brighter: hovering, tint: source.filterTint)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .help(L("recent.filter.clear"))
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
/// holds — a bare input, or an input flanked by a clipboard quote and its chips.
private struct ImmersiveHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // Single reader; last value wins so the runway can SHRINK back when the quote
        // clears, not just grow (same rationale as `AnswerHeightKey`).
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
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(hovering ? 0.10 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(hovering ? 0.22 : 0.10), lineWidth: 0.5)
            )
            .scaleEffect(pressed ? 0.985 : 1)
            .opacity(pressed ? 0.85 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressed)
    }
}

/// The faint clock entry: brightens slightly on hover, dims on press.
/// Top-right pin, sitting on a real Liquid Glass circle — the same native
/// `.glassEffect` chip the settings icon uses (`glassCapsule` on macOS 26+, blur
/// fallback below), so it reads as a piece of the glass island rather than a bare
/// glyph. The glyph stays pure white in both states — engaged reads through the
/// filled glyph, the upright tilt, and a white glass wash, never a colour tint.
/// Toggling routes back through the model so an un-pin can immediately re-arm
/// the leave-fold if the pointer is already gone.
struct ResultPinButton: View {
    var pinned: Bool
    var toggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                // A pinned pin tips slightly, the way a pushed-in tack sits — a small
                // physical cue that it's engaged, on top of the fill.
                .rotationEffect(.degrees(pinned ? 0 : 32))
                .frame(width: 26, height: 26)
                // The glass renders behind the glyph and carries ALL the resting
                // dimming, so the pin itself stays pure white even at rest — only
                // the glass is a quiet whisper of a chip until hovering or pinning
                // brings it (rim + specular + white wash when pinned) to full
                // strength.
                .background {
                    Color.clear
                        .glassCapsule(in: Circle(), brighter: pinned || hovering,
                                      tint: pinned ? .white : nil)
                        .opacity(pinned || hovering ? 1 : 0.55)
                }
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .notchTooltip(L(pinned ? "result.unpin" : "result.pin"))
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
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// The user's question, shown in a quiet chat bubble. The bubble's corner radius
/// adapts to how tall the text is: a single line stays a full pill (radius = half
/// the height, exactly like the old `Capsule`), but once the text wraps to two or
/// more lines the radius drops to a fixed, smaller value. A capsule at multi-line
/// height rounds its corners by half the *tall* box — a bloated, over-round blob;
/// the smaller radius keeps a multi-line quote reading as a tidy card.
/// `style: .continuous` matches the panel's other rounded shapes.
private struct UserQuestionBubble: View {
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
    private var isTruncated: Bool {
        var lines = 0
        for segment in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += 1 + segment.count / 48
            if lines > collapsedLineLimit { return true }
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
                }
                .frame(maxHeight: expandedMaxHeight)
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
