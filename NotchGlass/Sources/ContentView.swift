import SwiftUI

/// The full transparent canvas. The notch island is pinned to the top-center;
/// everything else is empty space that lets clicks fall through to apps below.
struct ContentView: View {
    @ObservedObject var model: NotchModel
    /// First-run state — drives the breathing gesture hint under the resting notch
    /// on the very first launch (see `OnboardingService`).
    @ObservedObject private var onboarding = OnboardingService.shared
    /// The live string store. Observing it here, at the root of every panel, plus
    /// the `.id(loc.language)` below, rebuilds the whole SwiftUI subtree when the
    /// App Language changes — so every `L(_:)` lookup re-evaluates at once, no
    /// relaunch, without each child view having to observe the store itself.
    @EnvironmentObject private var loc: Localization
    @Environment(\.notchMetrics) private var metrics
    /// Reduce-motion skips the close dissolve (the content fade beat), collapsing in
    /// one step — mirrors how the open spring already degrades to a plain settle.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            // No click-outside scrim anymore: leaving the island already folds the
            // panel (see `collapseOnLeave` — leave = fold, restored on re-hover),
            // so by the time the pointer reaches anything outside, the panel is
            // gone. Removing the scrim also stops it swallowing the first click
            // on whatever sits under the canvas.
            NotchIsland(model: model)
                // Rebuild the island's subtree on an App Language switch so every
                // localized string re-evaluates at once. The island is collapsed
                // (or being opened) when the user returns from a switch, so the
                // identity change never interrupts a visible animation.
                .id(loc.language)

            // First-run gesture hint: a slow breathing glow under the resting notch
            // with one line ("hover — or ⌘,"). Like the thinking dots, it's a
            // free-floating sibling shown ONLY while collapsed, and only on the very
            // first launch — it dies the first time the panel opens and never
            // returns (see `OnboardingService`). Suppressed if the panel is already
            // open or while the thinking dots own the same spot.
            if onboarding.showGestureHint,
               !model.isOpen(on: metrics.displayID),
               !model.thinking {
                NotchGestureHint(hasHardwareNotch: metrics.hasHardwareNotch)
                    .offset(y: metrics.restHeight)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: metrics.canvasWidth, alignment: .top)
        .ignoresSafeArea()
        // Round start/end drives the fly-into-notch exit — a snappy spring so the
        // tuck reads as one quick, intentional motion (not a slow drift). Panel
        // fold/expand keeps the gentle in-place fade (the dots and the panel are
        // handing off, not animating "into" anything).
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: model.thinking)
        .animation(.easeInOut(duration: 0.2), value: model.isOpen(on: metrics.displayID))
        // Fade the first-run gesture hint out (rather than snapping) the moment the
        // panel opens for the first time and `markPanelOpened()` retires it.
        .animation(.easeInOut(duration: 0.3), value: onboarding.showGestureHint)
        .background(KeyEventCatcher { event in
            // ⌘↵ submits the current line to the *other family* — Ask ⇄ Capture
            // (Note/Remind) — the one-key correction for when the inline hint reads
            // the line wrong (see NotchModel.submitOtherFamily; Tab remains the
            // precise three-way pick). Fresh prompt only: intent routing never
            // applies to follow-ups, and it needs text to send. keyCode 36 is Return.
            if event.keyCode == 36, event.modifierFlags.contains(.command),
               model.mode == .idle, model.hasText,
               !model.showOnboarding, !model.showSettings, !model.showWhatsNew {
                model.submitOtherFamily()
                return true
            }
            // ⌘F summons the recent-list filter. The chip is gone — this is the only
            // way in. Only meaningful when there's a list worth filtering (matches the
            // field's own > 6 render gate). If the list is collapsed, open it first so
            // the field has somewhere to land; if the filter's already up, ⌘F is a
            // no-op rather than a toggle (Esc clears/closes it — see below).
            if event.keyCode == 3, event.modifierFlags.contains(.command),
               !model.showSettings, model.history.count > 6 {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    if !model.showHistory { model.showHistory = true }
                    model.showHistoryFilter = true
                }
                return true
            }
            // ⌘N starts a fresh conversation from anywhere in a thread — the
            // keyboard twin of the ← back chevron, but it fires even mid-typing
            // a follow-up (the ⌘ modifier means it never collides with caret
            // movement or text entry, so unlike bare ← it needn't gate on an
            // empty field). No-op on the idle prompt — already a fresh chat.
            // keyCode 45 is N.
            if event.keyCode == 45, event.modifierFlags.contains(.command),
               model.mode != .idle {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    model.newChat()
                }
                return true
            }
            // Answer-state action keys (XII-131): the hover toolbar's actions, put
            // on the keyboard so the whole flow stays hands-on-keys. Only in a
            // settled result (not idle/settings/what's-new, not mid-stream) — the
            // toolbar they mirror only exists there. Guarded so a follow-up being
            // typed keeps normal editing: when the prompt field editor is first
            // responder, ⌘C/⌘S/⌘R fall through to the system (⌘C copies the
            // selection/line, etc.). ⌘P/⌘D handle their own state below.
            //   ⌘C (8)  = copy the whole answer      ⌘S (1) = save to Notes
            //   ⌘R (15) = regenerate
            if event.modifierFlags.contains(.command),
               model.mode == .result, !model.showSettings, !model.showWhatsNew,
               !model.isStreaming, !fieldEditorIsFirstResponder() {
                switch event.keyCode {
                case 8:   // C — copy the whole answer (no manual selection to honour;
                          // the field editor guard above already ceded ⌘C while typing)
                    if let answer = model.lastAnswerText {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer, forType: .string)
                        model.rebaselineClipboardAfterInAppWrite()
                        return true
                    }
                case 1:   // S — save the answer to Apple Notes (XII-123 pipeline)
                    if let id = model.lastAnswerID {
                        model.saveAnswerToNotes(answerID: id)
                        return true
                    }
                case 15:  // R — regenerate the last answer
                    model.regenerateLastAnswer()
                    return true
                default:
                    break
                }
            }
            // ⌘P (and ⌘D) pins/unpins the answer on screen — the keyboard twin of
            // the top-right pin button. A pinned answer stays open when the pointer
            // leaves (see NotchModel.collapseOnLeave). Only over a result (there's
            // nothing to pin on the idle prompt / settings), so both fall through to
            // the system everywhere else. keyCode 35 is P, 2 is D.
            if event.keyCode == 35 || event.keyCode == 2, event.modifierFlags.contains(.command),
               model.mode == .result, !model.showSettings, !model.showWhatsNew {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    model.toggleAnswerPin()
                }
                return true
            }
            // Esc: if the recent list is open, fold just that back to the input
            // first (one step "out"); only a second Esc closes the whole panel.
            // Works mid-request too — closing detaches the in-flight answer, which
            // finishes in the background and lands in Recent (see NotchModel).
            if event.keyCode == 53 {
                // Clear confirmation armed → first Esc dismisses just the dialog,
                // before any panel-level step-out / close.
                if model.confirmingClear {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        model.confirmingClear = false
                    }
                    return true
                }
                // Guided first run open → Esc skips it (returns to the prompt and
                // records it done, like the header's Skip).
                if model.showOnboarding {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        model.closeOnboarding()
                    }
                    return true
                }
                // Settings open → first Esc folds back to the prompt, not a full
                // close (mirrors the recent-list step-out below).
                if model.showSettings {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        model.closeSettings()
                    }
                    return true
                }
                // What's New open → same step-out: first Esc returns to the prompt.
                if model.showWhatsNew {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        model.closeWhatsNew()
                    }
                    return true
                }
                if model.showHistory {
                    // Stepped Esc while filtering, unwinding the ⌘F summon in reverse:
                    //   1. non-empty query  → clear the query (keep the field open)
                    //   2. empty query, field up → close just the filter field
                    //   3. field down        → fold the list back to the prompt
                    // Must run before collapseHistory() — this catcher fires ahead of
                    // SwiftUI's own exit handling.
                    if !model.historySearchQuery.isEmpty {
                        model.historySearchQuery = ""
                        return true
                    }
                    if model.showHistoryFilter {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                            model.showHistoryFilter = false
                        }
                        return true
                    }
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        model.collapseHistory()
                    }
                    return true
                }
                // Streaming → first Esc STOPS generation (XII-122), keeping the
                // partial answer on screen; a second Esc (now settled) closes the
                // panel as before. Stepping out one level at a time, same as the
                // history/settings unwinds above.
                if model.isStreaming {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        model.stopStreaming()
                    }
                    return true
                }
                model.beginClose(sequenced: !reduceMotion)
                return true
            }
            // ← goes "back" to a fresh conversation from the thread view — also
            // while the answer is still loading/streaming (the back chevron is
            // visible then, and the round finishes detached into Recent). Only
            // when the follow-up field is empty, so a left-arrow while editing
            // still just moves the caret instead of leaving the thread.
            if event.keyCode == 123, model.mode != .idle, !model.hasText {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    model.newChat()
                }
                return true
            }
            return false
        })
    }

    /// True when the key window's first responder is a text field editor — i.e. the
    /// user is typing in the prompt / follow-up / history-filter field. The
    /// answer-state action keys (XII-131) defer to it so ⌘C/⌘S/⌘R keep their normal
    /// editing meaning while a field is focused; only when nothing is being edited
    /// do they act on the answer. An `NSText` field editor is what AppKit installs
    /// as first responder for a focused `NSTextField`/`TextEditor`.
    private func fieldEditorIsFirstResponder() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSText
    }
}

/// The first-run gesture hint: a slow breathing glow centered under the resting
/// notch, with one line teaching the summon affordance. Quiet and in-character —
/// the glow uses the same cool top / warm-neutral palette as the glass edge light,
/// not a loud accent colour, so it reads as the notch itself inviting a hover
/// rather than a banner stuck on top. It shows only on the very first launch and
/// fades away the first time the panel opens (`OnboardingService.markPanelOpened`).
private struct NotchGestureHint: View {
    /// On a notched Mac the glow points at the hardware notch and the line names
    /// the hover. On a notch-less screen (external display / older Mac) there's no
    /// notch to hover, so the glow is dropped and the line names ⌘, alone.
    let hasHardwareNotch: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        VStack(spacing: 9) {
            if hasHardwareNotch {
                // A soft cool-white radial bloom, hinged to the notch's bottom edge.
                // It breathes between a dim rest and a brighter peak — slow enough to
                // read as ambient, never as a blinking cursor.
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.22),
                                Color.white.opacity(0.0),
                            ],
                            center: .top,
                            startRadius: 0,
                            endRadius: 70
                        )
                    )
                    .frame(width: Tokens.notchWidth + 64, height: 44)
                    .scaleEffect(x: 1, y: breathing ? 1.12 : 0.9, anchor: .top)
                    .opacity(breathing ? 0.9 : 0.35)
                    .blur(radius: 6)
            }

            Text(hasHardwareNotch
                 ? L("onboarding.gestureHint")
                 : L("onboarding.gestureHint.noNotch"))
                .font(.sf(12.5))
                .tracking(0.2)
                .foregroundStyle(Tokens.text2)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }
}

/// The measured natural widths of the copy-sense EARS — the content on each
/// side of the hardware notch. Reported up to `NotchIsland`, which adds the ear
/// insets and sizes/slides the island so each shoulder hugs its own content
/// (a different length in every language and stage) while the black center
/// stays fused to the physical camera housing.
struct SenseEarWidths: Equatable {
    var left: CGFloat = 0
    var right: CGFloat = 0
}

private struct SenseEarWidthsKey: PreferenceKey {
    static let defaultValue = SenseEarWidths()
    static func reduce(value: inout SenseEarWidths, nextValue: () -> SenseEarWidths) {
        let next = nextValue()
        value = SenseEarWidths(left: max(value.left, next.left),
                               right: max(value.right, next.right))
    }
}

/// The copy-sense rest content, in the two-eared compact idiom (the Dynamic
/// Island's): nothing can sit ON the camera housing — on a notched Mac those
/// pixels physically don't exist — so the hint splits across the shoulders the
/// flex opens on each side of it. Left ear: what will happen ("设提醒" / "Set
/// Reminder"), then the write's dots, then the one-word verdict — the same slot
/// the busy dots use, so "working" always lives left of the notch. Right ear:
/// the key to press ("⌘C"), following the macOS menu convention of label left,
/// shortcut right; it folds shut the moment the offer is consumed. Each ear is
/// a pinned slot — content can never slide under the camera by construction.
private struct ClipboardSenseEars: View {
    let sense: NotchModel.ClipboardSense
    /// The drawn hardware-notch width the ears flank (content-free gap).
    let notchWidth: CGFloat
    /// The island's current ear slots (content + insets, animated by the
    /// island's own settle) — the ears lay out inside exactly these.
    let earLeft: CGFloat
    let earRight: CGFloat

    private var isHinting: Bool {
        if case .hinting = sense { return true }
        return false
    }

    /// A stable identity per visual stage, so SwiftUI transitions between stages
    /// (and not between, say, a note hint and a reminder hint's shared text).
    private var stageKey: String {
        switch sense {
        case .idle: return "idle"
        case .hinting(let p): return "hint-\(p.rawValue)"
        case .saving: return "saving"
        case .saved: return "saved"
        case .failed: return "failed"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left ear — the outcome phrase, then the dots, then the verdict.
            ZStack {
                leftStage
                    .id(stageKey)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
            .animation(.easeInOut(duration: 0.22), value: stageKey)
            .frame(width: earLeft)

            // The camera gap — content-free by construction.
            Color.clear.frame(width: notchWidth)

            // Right ear — the key to press, only while the offer stands.
            ZStack {
                if isHinting {
                    earText("⌘C", color: Tokens.text3)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(
                                key: SenseEarWidthsKey.self,
                                value: SenseEarWidths(right: proxy.size.width))
                        })
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: isHinting)
            .frame(width: earRight)
        }
        .frame(minHeight: 22)
    }

    @ViewBuilder
    private var leftStage: some View {
        Group {
            switch sense {
            case .hinting(let panel):
                earText(panel == .reminder ? L("sense.reminder") : L("sense.note"),
                        color: Tokens.text3)
            case .saving:
                ThinkingDots(dot: 4, spacing: 5)
                    .fixedSize()
            case .saved:
                earText(L("sense.saved"), color: Tokens.text4)
            case .failed:
                earText(L("sense.failed"), color: Tokens.text4)
            case .idle:
                EmptyView()
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: SenseEarWidthsKey.self,
                                   value: SenseEarWidths(left: proxy.size.width))
        })
    }

    /// Deliberately faint — a hint, not an announcement. `fixedSize` so the
    /// text NEVER truncates: while its slot is still settling it overflows
    /// (hidden by the island's clip) instead of drawing half a line.
    private func earText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.sf(11.5, weight: .regular))
            .tracking(0.3)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}

/// The continuous black→glass island that grows out of the notch.
struct NotchIsland: View {
    @ObservedObject var model: NotchModel
    @Environment(\.notchMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the black bleeds above the screen's top edge, guaranteeing no gap.
    private let topBleed: CGFloat = 6

    /// How far the resting notch grows leftward while an answer is still
    /// streaming in the background — the strip that hosts the small thinking
    /// dots. Wide enough for the three-dot wave to breathe, narrow enough to
    /// read as the notch itself flexing, never as a second island.
    private let busyExtension: CGFloat = 48

    /// The copy-sense ears' measured content widths (via `SenseEarWidthsKey`),
    /// so each shoulder of the flex fits its own content — the phrase/dots/
    /// verdict on the left, the ⌘C key on the right — in whatever language and
    /// stage is showing.
    @State private var senseEarContent = SenseEarWidths()

    /// Breathing room on each side of an ear's content.
    private let senseEarPad: CGFloat = 11

    /// The transient "entry kick" — the cursor's momentum, absorbed by the
    /// glass. Set to a small displacement in the direction of approach the
    /// instant the island opens, then released to zero on an underdamped
    /// spring, so the form gets gently shoved and settles back. Deliberately
    /// subtle: the island is hinged to the bezel, so this reads as the material
    /// giving, never as the island flying around.
    @State private var kick = EntryKick.zero

    /// THIS screen's open state — gated on `activeDisplay` so hovering one
    /// screen's notch never unfurls the islands on the others. Every read that
    /// used to consult `model.open` goes through here (including the animation
    /// `value:`s — a display *switch* flips this while `model.open` stays true,
    /// and the fold/unfurl must still animate).
    private var isOpen: Bool {
        model.isOpen(on: metrics.displayID)
    }

    /// True when the panel is fully closed (on every display) but an Ask round
    /// is still streaming detached — the resting notch shows the busy extension.
    /// Gated on the GLOBAL `open`, not this display's `isOpen`: while the panel
    /// is open anywhere the round is on screen there, and the other displays'
    /// resting notches shouldn't claim background work.
    private var busy: Bool {
        !model.open && model.roundsInFlight > 0
    }

    /// True when the resting notch is offering (or narrating) a clipboard
    /// capture. Gated on the GLOBAL `open` like `busy`, and yields to the busy
    /// dots — an in-flight answer outranks a copy hint for the one strip.
    private var sensing: Bool {
        !model.open && !busy && model.clipboardSense != .idle
    }

    /// The resting notch's LEFT flex — the busy dots' strip, or the copy-sense
    /// left ear (phrase → dots → verdict), sized to its measured content. The
    /// two occupants never coexist (`sensing` yields to `busy`).
    private var earLeft: CGFloat {
        if busy { return busyExtension }
        if sensing, senseEarContent.left > 0 {
            return senseEarContent.left + senseEarPad * 2
        }
        return 0
    }

    /// The resting notch's RIGHT flex — the copy-sense ⌘C ear, present only
    /// while the offer stands (it folds shut on confirm). Busy never extends
    /// right: its strip stays pinned to the bezel exactly as before.
    private var earRight: CGFloat {
        guard sensing, senseEarContent.right > 0 else { return 0 }
        return senseEarContent.right + senseEarPad * 2
    }

    private var width: CGFloat {
        if isOpen { return model.openWidth }
        return Tokens.notchWidth + earLeft + earRight
    }

    private var bottomRadius: CGFloat {
        isOpen ? 30 : Tokens.notchRestRadius
    }

    var body: some View {
        // The island sizes its HEIGHT to its content (the constant black zone +,
        // when open, the glass body). We deliberately do NOT pin height to a
        // measured value — that creates a clip↔measure deadlock. Width is the
        // only explicit dimension; height follows the VStack intrinsically, and
        // the layout `.animation` springs the grow/shrink.
        VStack(spacing: 0) {
            // Constant black "hardware" zone with the camera dot. It overshoots
            // the screen's top edge by `topBleed` so the black always reaches the
            // very top — no sliver of wallpaper between the bezel and the form.
            ZStack {
                // No camera dot on screens without a real camera housing — a
                // fake lens on an external monitor reads as a smudge, not charm.
                if !isOpen, metrics.hasHardwareNotch {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color(white: 0.17), Color(white: 0.02)],
                                center: UnitPoint(x: 0.35, y: 0.30),
                                startRadius: 0, endRadius: 5
                            )
                        )
                        .frame(width: 7, height: 7)
                        // Uneven ears shift the island's center off the notch
                        // zone's center by (L−R)/2 — push the lens dot back by
                        // exactly that so it never drifts off the physical
                        // camera. (Busy: L=48, R=0 → the familiar +24pt.)
                        .offset(x: (earLeft - earRight) / 2, y: topBleed / 2)
                }

                // Background-activity dots, centered in the strip the busy
                // extension opens up on the left: the notch flexes out and the
                // same calm wave that marks thinking in the panel keeps marking
                // the detached round while it streams. They live inside the
                // island's own black zone — one material, one form — which is
                // what makes the extension read as the notch working, not as a
                // badge stuck beside it.
                if busy {
                    ThinkingDots(dot: 4, spacing: 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 13)
                        .offset(y: topBleed / 2)
                        .transition(.opacity)
                }

                // The copy-sense ears: the copied text read as a note/reminder,
                // and the notch is offering to file it. Both shoulders extend at
                // once — the outcome phrase on the left, the ⌘C key on the right
                // (menu convention: label left, shortcut right) — and the camera
                // gap between them is content-free by construction, so text can
                // never slide under the housing and render half-hidden.
                if sensing {
                    ClipboardSenseEars(sense: model.clipboardSense,
                                       notchWidth: Tokens.notchWidth,
                                       earLeft: earLeft,
                                       earRight: earRight)
                        .offset(y: topBleed / 2)
                        .transition(.opacity)
                }
            }
            .frame(height: metrics.restHeight + topBleed)

            // The glass body unfurls below the notch zone when open. On the way out
            // it fades FIRST (driven by `model.closing`), while the shell holds its
            // expanded size — then `beginClose` drops `open`, this view leaves, and
            // the shell retracts. So content dissolves, then the form collapses,
            // instead of both clamping shut on one transaction. The `.opacity`
            // transition still carries the open fade-in (and the final unmount).
            if isOpen {
                NotchBody(model: model)
                    .opacity(model.closing ? 0 : 1)
                    // Ease the dissolve over the model's content-fade window so it
                    // completes just as `beginClose` fires the shell retract.
                    .animation(.easeOut(duration: NotchModel.closeContentFade), value: model.closing)
                    .transition(.opacity)
            }
        }
        .frame(width: width)
        .padding(.top, -topBleed)   // pull the form up so it bleeds off the top
        .background(GlassMaterial(bottomRadius: bottomRadius,
                                  expanded: isOpen,
                                  cameraZone: metrics.restHeight))
        // The destructive "Clear recent history?" confirmation floats centered over
        // the whole island (scrim + card), instead of a popover anchored under the
        // Clear pill that landed it near the bottom of the panel. Mounted here so it
        // centers in the full glass body; clipped to the island shape below.
        .overlay {
            if model.confirmingClear {
                ClearHistoryConfirm(
                    onCancel: {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            model.confirmingClear = false
                        }
                    },
                    onConfirm: {
                        // Two beats, not one: the card fades out first while the
                        // island holds its height, THEN the emptied recent list
                        // collapses on the panel's standard module spring. Clearing
                        // immediately (and outside the transaction) yanked the
                        // island short mid-dismiss, re-centering and clipping the
                        // still-fading card — a visible jump.
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            model.confirmingClear = false
                        } completion: {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                                model.clearHistory()
                            }
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .clipShape(NotchShape(bottomRadius: bottomRadius))
        // The "slab of glass" look (per the reference): the dark body holds and
        // stays readable, the top reads near-solid and the lower body eases more
        // translucent (that vertical gradient lives in GlassMaterial's veil), and
        // the EDGES are defined by a lit beveled rim — bright along the bottom and
        // sides, brightest at the rounded corners. Stamped on top of the composited
        // island so the highlight traces the edge crisply instead of being clipped.
        .overlay(IslandRim(shape: NotchShape(bottomRadius: bottomRadius)))
        // The entry kick deforms the whole composited island — anchored at the
        // top edge so it hinges off the bezel. The system glass backdrop does
        // NOT ride along with SwiftUI render transforms, so the deform briefly
        // desyncs the veil/rim from the glass region — but with the panel's
        // base darkening baked into the glass material itself (see
        // `nativeGlass(in:)`), the slivers that escape on either side read as
        // the same smoked glass / dark veil, not a bright band. That's what
        // makes the whole-island lean safe; on the content alone the kick was
        // imperceptible (it plays out while the body is still fading in).
        // `ignoredByLayout()` keeps the deform render-only: nothing reads the
        // island's transformed frame, and letting layout see it would force
        // anchor/geometry recomputation on every frame of the kick — right on
        // top of the open spring's own per-frame layout work.
        .modifier(EntryKickEffect(tx: kick.tx, shear: kick.shear, squash: kick.squash).ignoredByLayout())
        .contentShape(NotchShape(bottomRadius: bottomRadius))
        // Slide the whole form so its black CENTER (not its geometric center)
        // stays fused to the hardware notch: the island is centered in the
        // canvas, so uneven ears would otherwise drag the camera zone off the
        // physical housing. (R−L)/2 is exactly that correction — for busy
        // (L=48, R=0) it reduces to the familiar −24pt right-edge pin; for even
        // ears it's zero and the form blooms symmetrically. Sits BEFORE the
        // isOpen animation so an open/close morph carries the slide on the
        // same spring as the width.
        .offset(x: (earRight - earLeft) / 2)
        // Spring expand (eased by how hard the cursor arrived — see `openSpring`);
        // the collapse settles on `closeSpring` (XII-108) so the shell drops back
        // with a touch of gravity/rebound instead of a flat clamp — EXCEPT when
        // the close lands on the extended busy rest. The rebound's undershoot
        // briefly renders the island SMALLER than the hardware notch (shorter
        // and narrower both); on a normal close that whole dip hides inside the
        // black cutout, but the busy extension sits over visible screen, so the
        // same dip reads as the "notch" shrinking away from the bezel. A busy
        // close takes the overshoot-free settle instead.
        .animation(isOpen ? openSpring : (earLeft + earRight > 0 ? busySettle : closeSpring), value: isOpen)
        // The busy/sense extension's own grow/retract (no open/close involved —
        // e.g. the detached answer lands while the notch rests) must NOT bounce:
        // an underdamped settle undershoots the rest width, and for a beat the
        // drawn island is NARROWER than the hardware notch it's impersonating —
        // physically impossible, and exactly the tell that breaks the illusion.
        // A near-critically-damped, unhurried ease reads as the notch quietly
        // relaxing back into the bezel. (A close that lands ON the extended
        // rest still rides `closeSpring` via the isOpen animation above — its
        // target there is wider than the notch, so its rebound never dips
        // below the hardware width.)
        .animation(busySettle, value: earLeft)
        .animation(busySettle, value: earRight)
        // The kick fires on the open *edge*, reading the entry vector the hover
        // just recorded. Closing lets any residual kick decay on its own.
        .onChange(of: isOpen) { _, nowOpen in
            if nowOpen { applyEntryKick() }
        }
        // The ears' measured content widths feed `earLeft`/`earRight`; the flex
        // then re-settles (on the same `busySettle` keyed below) whenever a
        // stage's content changes size — hint phrase → dots → verdict, and the
        // ⌘C ear folding shut on confirm.
        .onPreferenceChange(SenseEarWidthsKey.self) { senseEarContent = $0 }
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: model.openWidth)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.mode)
        // The note-save feedback line (Saving… → Added to Notes → gone) changes the
        // body's intrinsic height. Without these, only the inner idleView spring
        // governed that change — it animates the line's own fade/scale but does NOT
        // propagate up to this island's frame, glass background, or clip shape, so
        // the outer form resized on a mismatched (or no) transaction while the inner
        // text eased out. Keying the island's grow/shrink on the same note states,
        // with the SAME spring idleView uses (response 0.42, damping 0.82), makes the
        // whole island — content and glass shell — settle as one smooth motion.
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.noteSaving)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.lastSavedNote)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.noteError)
        // Expanding / collapsing the Recent list changes the body's intrinsic
        // height. Like the note-save line above, that height change must drive the
        // island's frame, glass background AND clip shape on ONE spring — otherwise
        // the inner `moduleTransition` animates the list's own fade/slide while the
        // outer shell resizes on a mismatched (or no) transaction. The visible
        // symptom was exactly that desync: the black notch cap and the glass veil
        // (whose gradient stops are derived from the live, animating height) redrew
        // out of step with the growing form, so the black zone and frost appeared to
        // "jump" as the list opened. Keying the island here — same spring the clock
        // toggle uses — makes the whole form grow as one piece, so the glass reads
        // as one continuous surface unfurling rather than a stack snapping open.
        // `showHistoryFilter` is included because revealing the ⌘F field also nudges
        // the height, and it should ride the same coherent motion.
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.showHistory)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.showHistoryFilter)
        // Publish the island's live frame (canvas-window space) so the model can
        // verify hover events against the pointer's real position — the raw
        // enter/exit stream includes artifacts synthesized by this very frame
        // animating (see `NotchModel.pointerInsideIsland`). A plain var write on
        // the model, deliberately not @Published: this fires per frame during
        // the open/close springs.
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { model.registerIslandFrame(proxy.frame(in: .global), for: metrics.displayID) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in
                    model.registerIslandFrame(frame, for: metrics.displayID)
                }
        })
        .onHover { inside in
            if inside {
                model.hoverEntered(on: metrics.displayID,
                                   velocity: MouseVelocityTracker.shared.entryVelocity())
            } else {
                model.collapseOnLeave(from: metrics.displayID, sequenced: !reduceMotion)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)   // center within canvas
    }

    // MARK: - Entry physics

    /// 0…1 measure of how energetically the cursor arrived. √-compressed so the
    /// difference between a lazy drift and a normal move reads, while slamming
    /// the mouse can't push past the cap.
    private var entryEnergy: CGFloat {
        let v = model.entryVelocity
        let speed = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        return min(speed / 2500, 1).squareRoot()
    }

    /// The unfurl spring, eased by approach speed. The resting end is *calmer*
    /// than the old fixed spring (longer response, more damping — an unhurried
    /// bloom); a fast entry only tightens it back to roughly the old feel, so
    /// momentum shows up as the energetic end of the range, never as haste
    /// beyond what the panel already had.
    private var openSpring: Animation {
        guard !reduceMotion else {
            return .spring(response: 0.50, dampingFraction: 0.85)
        }
        let s = entryEnergy
        return .spring(response: 0.50 - 0.06 * s,
                       dampingFraction: 0.82 - 0.10 * s)
    }

    /// The busy extension's grow/retract at rest: gentle and, crucially,
    /// overshoot-free (dampingFraction ≥ 0.95 keeps the width from ever dipping
    /// below the hardware notch — see the comment at the use site).
    private var busySettle: Animation {
        guard !reduceMotion else { return .easeOut(duration: 0.30) }
        return .spring(response: 0.50, dampingFraction: 0.95)
    }

    /// The retract animation (XII-108): instead of a flat ease-out, the shell
    /// settles on a slightly-underdamped spring so it reads as an object dropping
    /// back into the bezel with a touch of gravity/rebound, not a clean clamp.
    /// Paced to breathe with the open (response 0.50): the original 0.34 retract
    /// was nearly twice as fast as the unfurl, and with leave-to-fold making the
    /// close a constant companion it read as a harsh clamp — too few frames for
    /// the motion to be legible at all. The slower period also lets the rebound
    /// actually READ as physics; damping comes up a touch so the longer spring
    /// stays one soft settle, not a wobble. Reduce-motion keeps the flat ease.
    private var closeSpring: Animation {
        guard !reduceMotion else { return .easeOut(duration: 0.30) }
        return .spring(response: 0.46, dampingFraction: 0.76)
    }

    /// Seed the kick from the entry vector, then release it. Two writes on
    /// purpose: the displacement lands in a no-animation transaction (one
    /// imperceptible frame — it reads as the island being struck), and the
    /// release to zero rides a soft underdamped spring, giving one gentle
    /// wobble that settles. All gains are deliberately small — a hint of give,
    /// not a stunt.
    private func applyEntryKick() {
        guard !reduceMotion else { return }
        let v = model.entryVelocity
        let speed = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        // A slow deliberate approach gets no kick at all — the physics only
        // wakes up once there's real momentum to absorb.
        guard speed > 250 else { return }

        var seeded = EntryKick.zero
        // Sideways momentum: a slight nudge plus a top-hinged lean (shear), the
        // bottom edge trailing in the direction of travel.
        seeded.tx = max(-5, min(5, v.dx * 0.003))
        seeded.shear = max(-0.025, min(0.025, v.dx * 0.000015))
        // Upward momentum (dy < 0): the glass compresses a touch, absorbing the
        // hit. The clamp is asymmetric — compression reads as material give,
        // but there's almost no stretch case (you can't approach from above).
        seeded.squash = max(-0.030, min(0.010, v.dy * 0.000020))

        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { kick = seeded }
        withAnimation(.spring(response: 0.60, dampingFraction: 0.62)) {
            kick = .zero
        }
    }
}

/// The components of the entry kick, in render terms: a horizontal nudge (pt),
/// a top-hinged x-shear (x shift per pt of y), and a vertical squash (scaleY
/// delta, negative = compressed).
struct EntryKick: Equatable {
    var tx: CGFloat = 0
    var shear: CGFloat = 0
    var squash: CGFloat = 0
    static let zero = EntryKick()
}

/// Renders the entry kick as one affine transform anchored at the island's
/// top-center — the point where the glass meets the bezel, which must never
/// move. Volume is loosely conserved: vertical squash buys a little horizontal
/// spread, which is what sells the jelly read over a flat scale.
struct EntryKickEffect: GeometryEffect {
    var tx: CGFloat
    var shear: CGFloat
    var squash: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(tx, AnimatablePair(shear, squash)) }
        set {
            tx = newValue.first
            shear = newValue.second.first
            squash = newValue.second.second
        }
    }


    func effectValue(size: CGSize) -> ProjectionTransform {
        let sy = 1 + squash
        let sx = 1 - squash * 0.5
        let recenter = CGAffineTransform(translationX: -size.width / 2, y: 0)
        let deform = CGAffineTransform(a: sx, b: 0, c: shear, d: sy, tx: 0, ty: 0)
        let back = CGAffineTransform(translationX: size.width / 2 + tx, y: 0)
        return ProjectionTransform(recenter.concatenating(deform).concatenating(back))
    }
}

/// Bridges global key events (Esc) into SwiftUI without stealing focus.
struct KeyEventCatcher: NSViewRepresentable {
    var handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        let v = CatcherView()
        v.handler = handler
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.handler = handler
    }

    final class CatcherView: NSView {
        var handler: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    // One catcher lives in every per-screen panel, and local
                    // monitors all see every app key event — only the panel that
                    // actually holds the keyboard may act, or N panels would each
                    // consume/act on the same Esc.
                    guard let self, self.window?.isKeyWindow == true else { return event }
                    if self.handler?(event) == true { return nil }
                    return event
                }
            }
        }
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}

