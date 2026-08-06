import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

/// A single-line field that strips the field editor's completion / prediction
/// magic the moment focus arrives by ANY route. The focusTrigger path in
/// `updateNSView` disables it after its programmatic `makeFirstResponder`, but a
/// direct CLICK into the field creates the editor without that block ever running
/// (its `currentEditor() == nil` guard skips), and `controlTextDidBeginEditing`
/// waits for the first *committed* change — an entire IME composition can play out
/// before that. A click-focused session could therefore reach its first keystrokes
/// with the system completion panel still armed: the intermittent big empty glass
/// box flashing over the panel. Hooking `becomeFirstResponder` covers click, Tab
/// and programmatic focus alike, synchronously, before any keystroke can reach the
/// editor. (Used by the compact filter fields; the prompt itself is a
/// `PromptTextView` — see `PromptField`.)
final class MagiclessTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { PromptField.disableEditorMagic(currentEditor()) }
        return accepted
    }
}

/// The prompt's backing text view. Two jobs beyond a plain `NSTextView`:
///  · strip the completion / prediction magic on every route into focus (same
///    reasoning as `MagiclessTextField` above — a click must never reach a
///    keystroke with the system completion panel still armed);
///  · draw the placeholder itself, since `NSTextView` has none. (Both prompt call
///    sites hand the placeholder to a SwiftUI label instead, so it can fade; this
///    keeps the contract intact for any caller that doesn't.)
final class PromptTextView: NSTextView {
    var placeholder: String = ""
    /// Consulted on ⌘V before the text machinery runs. Returning `true` means the
    /// paste was consumed as something other than text (the agent compose
    /// attaches a pasted IMAGE); `false` falls through to the normal text paste.
    var onPasteImage: () -> Bool = { false }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { PromptField.disableEditorMagic(self) }
        return accepted
    }

    /// A plain-text view's `readablePasteboardTypes` carries no image types, so
    /// with a pixels-only clipboard (a bare ⌃⇧⌘4 screenshot — THE case the agent
    /// compose's image attach exists for) AppKit validates Edit ▸ Paste to
    /// disabled and ⌘V dies before `paste(_:)` is ever called. Claim image
    /// types too, purely so the paste command fires; `paste(_:)` below decides
    /// what actually happens to them.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff]
    }

    override func paste(_ sender: Any?) {
        if onPasteImage() { return }
        // The image types above were claimed only to keep ⌘V alive for the
        // hook. When the hook passes (not composing an agent task) and the
        // clipboard holds nothing the plain-text machinery can read, stop —
        // don't let AppKit improvise an attachment glyph out of raw pixels.
        guard NSPasteboard.general.availableType(from: super.readablePasteboardTypes) != nil else { return }
        super.paste(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor(Tokens.placeholder),
        ]
        (placeholder as NSString).draw(
            at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
            withAttributes: attrs)
    }
}

/// A borderless prompt box styled to the design tokens.
///
/// Backed by an AppKit `NSTextView` (in a scroll view) rather than SwiftUI's
/// `TextField`/`TextEditor` for two reasons:
///
///  1. **No completion panel.** AppKit's text machinery pops a floating
///     autocomplete/prediction panel while typing (the empty glass box) and
///     SwiftUI gives no hook to turn it off — `disableEditorMagic` does.
///  2. **It grows down, not sideways.** A long prompt WRAPS and the box gains a
///     line at a time, up to `maxVisibleLines`, after which it scrolls internally.
///     The old single-line field scrolled horizontally, hiding everything but the
///     tail of what you'd typed.
///
/// The caller sizes the row from `onHeightChange` (the box's current height,
/// already clamped to the line cap).
struct PromptField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat
    /// When this flips true the field grabs first-responder (caret in the box) —
    /// our replacement for SwiftUI `@FocusState`, which can't drive an AppKit view.
    var focusTrigger: Bool = false
    /// How tall the box may grow, in lines of text, before it stops growing and
    /// starts scrolling its content instead.
    var maxVisibleLines: Int = 5
    var onSubmit: () -> Void
    /// Invoked when ← is pressed while the field is empty — lets a result view bind
    /// it to "back / new conversation". No-op by default (e.g. the idle prompt),
    /// so left-arrow there just moves the caret as usual.
    var onBack: () -> Void = {}
    /// Invoked when ↓ is pressed while the field is empty — the idle prompt binds
    /// it to "open / step down the recent list". Returns `true` if it consumed the
    /// key (so the field swallows it); `false` lets ↓ move the caret as usual.
    var onDown: () -> Bool = { false }
    /// Invoked when ↑ is pressed while the field is empty — steps the recent-list
    /// highlight back up (and folds it away past the top). Same return contract as
    /// `onDown`.
    var onUp: () -> Bool = { false }
    /// Whether a keyboard-driven menu is open over the field — the `/` command
    /// menu today. While it is, ↑/↓ go to `onUp`/`onDown` (they walk its rows)
    /// even though the box holds text, which the empty-field rule below would
    /// otherwise send to the caret. Default `false`: no menu, no change.
    var isMenuOpen: () -> Bool = { false }
    /// Whether an ↑/↓ history-recall session is live. When `true`, ↑/↓ keep going
    /// to `onUp`/`onDown` even though the box now holds a recalled question (so the
    /// user can press ↑ again to step further back), instead of moving the caret.
    /// Default `false`: ↑/↓ only fire the callbacks on an empty field.
    var isRecalling: () -> Bool = { false }
    /// Invoked on Enter *before* `onSubmit` — lets the idle prompt open a
    /// keyboard-highlighted recent row instead of submitting. Returns `true` when
    /// it handled the key (a row was open); `false` falls through to `onSubmit`.
    var onSubmitNav: () -> Bool = { false }
    /// Invoked on Tab (⇥) — the idle prompt binds it to step the destination
    /// cycle (Ask → Note → Remind), overriding the classifier for the current
    /// line. Returns `true` when consumed; `false` lets Tab do its default focus
    /// move.
    var onTab: () -> Bool = { false }
    /// Invoked on Shift-Tab (⇧⇥). `nil` (the default) means "same as Tab", so a
    /// caller that doesn't distinguish the two keys keeps the old shared
    /// behaviour on both; the idle prompt binds this separately to flip the
    /// Ask ⇄ Agent bucket. Returns `true` when consumed.
    var onBackTab: (() -> Bool)? = nil
    /// Invoked on ⌘V *before* the text paste — the idle prompt binds it to "attach
    /// a pasted image to the agent compose". Returns `true` when it consumed
    /// the paste (the clipboard held pixels and the compose took them); `false`
    /// lets the paste insert text as usual.
    var onPasteImage: () -> Bool = { false }
    /// Reports the width (pt) of the LAST line the box is currently *showing* —
    /// committed text PLUS any in-progress IME composition (the pinyin/marked text
    /// that isn't yet in `text`). The overlay placeholder watches it so it clears
    /// while pinyin is still composing, instead of trailing the stale committed
    /// text. `0` when the box is empty. No-op by default.
    var onCaretWidth: (CGFloat) -> Void = { _ in }
    /// Reports where that last line sits vertically, as an offset (pt) from the
    /// box's own centre — for anything that needs to ride down with the text as the
    /// box grows into a second, third… line. `0` for a single-line prompt. No-op by
    /// default (nothing reads it today).
    var onCaretY: (CGFloat) -> Void = { _ in }
    /// Reports the box's current height (pt): one line at rest, growing a line at a
    /// time with the wrapped text, clamped at `maxVisibleLines`. The caller frames
    /// the field with it and sizes the row around it. No-op by default.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    /// The text's left inset inside the box — matched to the ~2pt an `NSTextField`
    /// cell used to draw with, so the placeholder labels and the inline hint (which
    /// both carry the same 2pt) still land exactly on the glyphs.
    static let textInset: CGFloat = 2

    /// One line of `fontSize` text, in the same metrics the layout manager lays the
    /// box out with — the unit the row heights and the line cap are counted in.
    static func lineHeight(for fontSize: CGFloat) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: fontSize))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Build the TextKit 1 stack by hand. A bare `NSTextView()` comes up on
        // TextKit 2, where every `layoutManager` touch silently falls back with a
        // console warning — and the layout manager is exactly what measures the
        // box's height and its last line's width here.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        let tv = PromptTextView(
            frame: NSRect(x: 0, y: 0, width: 200, height: Self.lineHeight(for: fontSize)),
            textContainer: container)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.focusRingType = .none
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: Self.textInset, height: 0)
        // Wrap to the box's width, grow without bound downward — the scroll view
        // caps what's *visible*, not what can be typed.
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        Self.disableEditorMagic(tv)
        applyStyle(to: tv)
        // Route ⌘V through the coordinator so the closure the view calls is
        // always the CURRENT one (coordinator.parent is refreshed every update),
        // never the copy captured at makeNSView time.
        let coord = context.coordinator
        tv.onPasteImage = { coord.parent.onPasteImage() }

        let scroll = NSScrollView(frame: tv.frame)
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.borderType = .noBorder
        // OFF until the text actually exceeds the line cap (see `report`). Leaving
        // this on unconditionally let macOS flash the overlay knob whenever a
        // relayout (panel open, list expand) transiently made content > viewport —
        // the ghost "rectangular cursor" at the field's trailing edge.
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        // Overlay scrollers only surface while scrolling, so a capped-out prompt
        // shows the bar it needs and the resting one-liner shows nothing.
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.contentView.drawsBackground = false
        // The inline hint rides the last line, so it has to follow the box as its
        // content scrolls under the cap.
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observe(scroll: scroll, textView: tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? PromptTextView else { return }
        // Refresh the coordinator's view of us so its callbacks (onCaretWidth, the
        // nav hooks) run against the current closures, not the ones captured at init.
        context.coordinator.parent = self
        // NEVER touch the text while an IME composition (marked text) is in flight.
        // During composition the bound `text` lags the display (pinyin isn't
        // committed yet), so the `string != text` check below would "correct" the box
        // back to the stale committed text — wiping the user's half-typed pinyin. And
        // re-renders DO happen mid-composition: the caret/height reports driving the
        // hint and the row size are SwiftUI state changes.
        let composing = tv.hasMarkedText()
        if !composing, tv.string != text {
            // A recall / submit / other model-side replacement starts a genuinely
            // new layout. Do not carry the IME wrap floor from the previous draft
            // into it (programmatic storage edits do not call `textDidChange`).
            context.coordinator.resetHeightStabilization()
            // Set the storage rather than `.string` so the glyphs carry our font and
            // ink outright — a plain string assignment leans on typing attributes and
            // can land unstyled.
            tv.textStorage?.setAttributedString(
                NSAttributedString(string: text, attributes: Self.attributes(fontSize: fontSize)))
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        applyStyle(to: tv)
        if tv.placeholder != placeholder { tv.placeholder = placeholder; tv.needsDisplay = true }
        // Re-measure on every pass: a programmatic set (submit clears the box, ↑
        // recall fills it) posts no edit notification to measure from, and a width
        // change re-wraps the text without touching it at all. Deferred a tick — the
        // reports write SwiftUI state, and we're inside SwiftUI's update.
        context.coordinator.reportAfterUpdate(for: tv)

        // Take focus exactly ONCE per rising edge of focusTrigger. SwiftUI calls
        // updateNSView on every render while the panel is open; without this latch
        // we'd enqueue a `makeFirstResponder` on each pass, piling up async blocks
        // that ping-pong the caret (and, with two PromptFields on screen, fight
        // each other) — a prime suspect for the recurring freeze.
        let coord = context.coordinator
        if focusTrigger {
            if !coord.didFocus, let window = tv.window, window.firstResponder !== tv {
                coord.didFocus = true
                DispatchQueue.main.async { [weak tv] in
                    guard let tv, let window = tv.window, window.firstResponder !== tv else { return }
                    window.makeFirstResponder(tv)
                    // Park the caret at the end rather than leaving a selection: a
                    // re-focus that lands on existing text (the mode/history/clip
                    // `onChange`s all fire `refocusInput`) must never come back with
                    // the whole line highlighted — the next keystroke would replace it.
                    tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                    Self.disableEditorMagic(tv)
                }
            }
        } else {
            coord.didFocus = false   // re-arm for the next open
        }
    }

    /// The real source of the floating suggestion box: the **field editor** (the
    /// shared `NSTextView` that backs editing). Its own auto-completion / text-
    /// prediction / substitution switches are separate from the NSTextField's and
    /// stay ON unless turned off here. We can only reach it once editing starts
    /// (the editor is created lazily), so this runs right after we take focus and
    /// again whenever editing begins.
    static func disableEditorMagic(_ editor: NSText?) {
        guard let tv = editor as? NSTextView else { return }
        tv.isAutomaticTextCompletionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        // Inline predictions (macOS 14+) ride their own NSTextInputTraits switch
        // — none of the flags above turn them off.
        tv.inlinePredictionType = .no
        // Writing Tools (macOS 15.2+) brings its own floating affordance/panel;
        // keep it out of the prompt box entirely.
        if #available(macOS 15.2, *) {
            tv.writingToolsBehavior = .none
        }
    }

    /// The glyph attributes the box types (and pastes) in.
    private static func attributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor(Tokens.ink).withAlphaComponent(0.96),
        ]
    }

    /// Only writes a property when its value actually changed. AppKit setters here
    /// rebuild layout/redraw on every assignment; doing that unconditionally on each
    /// keystroke was wasteful churn. Cheap equality guards keep typing smooth.
    private func applyStyle(to tv: NSTextView) {
        let wantFont = NSFont.systemFont(ofSize: fontSize)
        if tv.font != wantFont { tv.font = wantFont }

        let wantInk = NSColor(Tokens.ink).withAlphaComponent(0.96)
        if tv.textColor != wantInk { tv.textColor = wantInk }
        // An NSTextView's caret defaults to the system text colour (near-black) —
        // invisible on the glass. It's the field's ink, like the field editor's was.
        if tv.insertionPointColor != wantInk { tv.insertionPointColor = wantInk }
        // Guarded like the rest: re-stamping typing attributes on every render would
        // churn them mid-IME-composition for no reason.
        if (tv.typingAttributes[.font] as? NSFont) != wantFont
            || (tv.typingAttributes[.foregroundColor] as? NSColor) != wantInk {
            tv.typingAttributes = Self.attributes(fontSize: fontSize)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        /// Refreshed on every `updateNSView` so the callbacks below (notably
        /// `onCaretWidth`) never fire through a stale closure captured at init.
        var parent: PromptField
        /// One-shot latch: true once we've taken focus for the current rising edge
        /// of `focusTrigger`, reset when it falls. Prevents re-enqueuing focus on
        /// every render. (See updateNSView.)
        var didFocus = false
        /// The box we measure and the scroll view that clips it. Weak — AppKit owns
        /// the view tree; this is just our handle back into it from a notification.
        private weak var textView: PromptTextView?
        private weak var scrollView: NSScrollView?
        /// Last values pushed up, so a re-measure that lands on the same numbers
        /// doesn't kick SwiftUI into another render pass.
        private var lastHeight: CGFloat = -1
        private var lastCaretWidth: CGFloat = -1
        private var lastCaretY: CGFloat = .greatestFiniteMagnitude
        /// Pinyin/kana marked text is commonly wider than the glyph eventually
        /// committed. At a line boundary it can therefore wrap to line N+1, then
        /// snap back to line N as soon as the candidate is chosen. Remember the
        /// tallest layout reached by the active composition and hold that height
        /// after commit until committed text really reaches it. The next IME word
        /// normally does so; meanwhile the row no longer pumps up and down for each
        /// syllable near the boundary.
        private var wasComposing = false
        private var compositionPeakHeight: CGFloat = 0
        private var heldCompositionHeight: CGFloat?
        init(_ parent: PromptField) { self.parent = parent }
        deinit { NotificationCenter.default.removeObserver(self) }

        /// Subscribe to the two things the row's size and the inline hint ride on:
        ///  · the text STORAGE, because IME composition (typing pinyin before it
        ///    commits) edits marked text directly in the storage WITHOUT ever firing
        ///    `textDidChange` — `didProcessEditing` is the only hook that sees it, so
        ///    it's what lets the hint trail the pinyin live;
        ///  · the clip view's bounds, because once the box is capped at
        ///    `maxVisibleLines` the last line moves by SCROLLING, not by growing.
        func observe(scroll: NSScrollView, textView tv: PromptTextView) {
            self.scrollView = scroll
            self.textView = tv
            if let storage = tv.textStorage {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(storageDidProcessEditing),
                    name: NSTextStorage.didProcessEditingNotification,
                    object: storage)
            }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scroll.contentView)
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            PromptField.disableEditorMagic(tv)
            // Drop the island below the IME candidate window while typing so the
            // pinyin/kana/Hangul selection popup isn't covered by the panel.
            (tv.window as? NotchPanel)?.beginFieldEditing()
        }

        func textDidEndEditing(_ notification: Notification) {
            // Restore the resting level now that this box is done editing.
            guard let tv = notification.object as? PromptTextView else { return }
            (tv.window as? NotchPanel)?.endFieldEditing()
            // Once the caret leaves, there is no following composition to bridge
            // into. Return a provisional extra line to its real content height.
            resetHeightStabilization()
            report(for: tv)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? PromptTextView else { return }
            // A non-IME edit (plain typing, delete, paste) is an explicit new
            // layout decision and may shrink normally. An IME commit arrives while
            // `wasComposing` is still true; that edge deliberately keeps the floor.
            if !tv.hasMarkedText(), !wasComposing {
                resetHeightStabilization()
            }
            parent.text = tv.string
            // Belt-and-suspenders: macOS can re-arm prediction as you type, so keep
            // it disabled on every change (cheap idempotent set).
            PromptField.disableEditorMagic(tv)
            // Keep the caret in view once the box has capped out and started scrolling.
            tv.scrollRangeToVisible(tv.selectedRange())
            report(for: tv)
        }

        /// The IME path: fires on EVERY storage edit, marked text included. Posted
        /// from inside `processEditing`, so defer one runloop tick before reading the
        /// layout — measuring mid-edit would read a half-applied state.
        @objc private func storageDidProcessEditing() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.report(for: tv)
            }
        }

        @objc private func clipBoundsDidChange() {
            guard let tv = textView else { return }
            report(for: tv)
        }

        // MARK: Measurement (row height + where the last line ends, IME-aware)

        /// `report`, one runloop tick later. The only safe way to measure from inside
        /// `updateNSView`: the reports write SwiftUI state, which is illegal during
        /// SwiftUI's own update pass.
        func reportAfterUpdate(for tv: PromptTextView) {
            DispatchQueue.main.async { [weak self, weak tv] in
                guard let self, let tv else { return }
                self.report(for: tv)
            }
        }

        /// Drop only the IME wrap hysteresis. `lastHeight` stays intact so the next
        /// report publishes the real height when it differs from the held value.
        func resetHeightStabilization() {
            wasComposing = false
            compositionPeakHeight = 0
            heldCompositionHeight = nil
        }

        /// Lay the text out and push up the two numbers the row is built from: the
        /// box's height (clamped to the line cap) and where the last line ENDS — its
        /// width, and its vertical offset from the box's centre. Everything is read
        /// from the layout manager, so a wrapped line, a pasted paragraph and a
        /// half-composed pinyin syllable all measure the same way.
        func report(for tv: PromptTextView) {
            guard let layout = tv.layoutManager, let container = tv.textContainer else { return }
            layout.ensureLayout(for: container)

            let line = PromptField.lineHeight(for: parent.fontSize)
            // `usedRect` stops at the last GLYPH, so a trailing newline (an empty last
            // line the caret sits on) needs the extra fragment to be counted too.
            var used = layout.usedRect(for: container).height
            if layout.extraLineFragmentTextContainer != nil {
                used = max(used, layout.extraLineFragmentRect.maxY)
            }
            let cap = line * CGFloat(max(1, parent.maxVisibleLines))
            let measuredHeight = min(max(used, line), cap).rounded(.up)

            // Stabilize the IME boundary case described above. Growing is immediate
            // so marked text and its caret remain visible. Shrinking is deferred
            // only when the just-committed candidate is narrower than its marked
            // spelling; ordinary edits never acquire this floor.
            let composing = tv.hasMarkedText()
            if composing {
                if !wasComposing {
                    // Carry only an IME floor from the previous syllable. Using
                    // `lastHeight` here would also carry a stale height across a
                    // programmatic recall/submit before its deferred re-measure.
                    compositionPeakHeight = max(
                        measuredHeight, heldCompositionHeight ?? 0)
                } else {
                    compositionPeakHeight = max(compositionPeakHeight, measuredHeight)
                }
            } else if wasComposing {
                if compositionPeakHeight > measuredHeight + 0.5 {
                    heldCompositionHeight = max(
                        heldCompositionHeight ?? 0, compositionPeakHeight)
                }
                compositionPeakHeight = 0
            }
            wasComposing = composing

            var height = measuredHeight
            if let held = heldCompositionHeight {
                if measuredHeight >= held - 0.5 {
                    // Committed text has naturally occupied the provisional line;
                    // from here the real measurement owns the height again.
                    heldCompositionHeight = nil
                } else {
                    height = held
                }
            }

            // The scroller exists only once the text has capped out and truly
            // scrolls. Kept OFF otherwise so transient mid-animation layouts can't
            // flash the overlay knob over the panel (the ghost "cursor" bug).
            let scrollable = used > cap + 0.5
            if let scroll = scrollView, scroll.hasVerticalScroller != scrollable {
                scroll.hasVerticalScroller = scrollable
            }

            // Where the last line ends — the anchor the inline hint hangs off.
            var lineRect = NSRect(x: 0, y: 0, width: 0, height: line)
            var endX: CGFloat = 0
            if layout.extraLineFragmentTextContainer != nil {
                lineRect = layout.extraLineFragmentRect
                endX = layout.extraLineFragmentUsedRect.maxX
            } else if layout.numberOfGlyphs > 0 {
                let last = layout.numberOfGlyphs - 1
                lineRect = layout.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
                endX = layout.lineFragmentUsedRect(forGlyphAt: last, effectiveRange: nil).maxX
            }
            // The box scrolls under the cap, so the visible y of that line is its
            // position in the text MINUS however far the content has scrolled.
            let scrolled = scrollView?.contentView.bounds.origin.y ?? 0
            let centreY = lineRect.midY + tv.textContainerInset.height - scrolled
            let caretY = centreY - height / 2

            if height != lastHeight {
                lastHeight = height
                parent.onHeightChange(height)
            }
            let width = tv.string.isEmpty ? 0 : ceil(endX)
            if width != lastCaretWidth {
                lastCaretWidth = width
                parent.onCaretWidth(width)
            }
            if abs(caretY - lastCaretY) > 0.5 {
                lastCaretY = caretY
                parent.onCaretY(caretY)
            }
        }

        // MARK: Keys

        /// The authoritative kill switch for the word-completion popup: the text view
        /// asks its delegate for completions on every edit; returning an empty list
        /// (and -1 selection) means there's never anything to show, so the panel never
        /// appears. (Calling `complete(_:)` ourselves did the OPPOSITE — it *opened*
        /// the panel and looped — so that's gone.)
        func textView(_ textView: NSTextView,
                      completions words: [String],
                      forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            index?.pointee = -1
            return []
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Defensively swallow the "show completions" command too.
            if commandSelector == #selector(NSResponder.complete(_:)) {
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // ⇧⏎ breaks the line instead of sending it — the way to write the
                // second paragraph the box can now show. Plain ⏎ still submits.
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                // Give the recent-list highlight first crack at Enter — if a row is
                // keyboard-selected, open it; otherwise submit the prompt as usual.
                if parent.onSubmitNav() { return true }
                parent.onSubmit()
                return true
            }
            // ⌥⏎ — AppKit's own "newline, don't submit" command. Let it through.
            if commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                return false
            }
            // Tab steps the idle prompt's destination cycle (Ask → Note →
            // Remind); Shift-Tab flips the Ask ⇄ Agent bucket. A caller that
            // wants only one behaviour leaves `onBackTab` nil, and Shift-Tab
            // falls back to `onTab` (the old shared behaviour). The caller
            // decides whether to consume the key; unconsumed, it falls through
            // to its usual focus move.
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                return parent.onTab()
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                return (parent.onBackTab ?? parent.onTab)()
            }
            // ← on an empty field means "go back" (start a new conversation) rather
            // than moving a caret that has nothing to move. With text present we let
            // it fall through so normal cursor movement still works while editing.
            if commandSelector == #selector(NSResponder.moveLeft(_:)),
               parent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parent.onBack()
                return true
            }
            // ↓ / ↑ drive history recall / the recent list. They fire on an empty
            // field, and *also* while a recall session is live (`isRecalling`) — so
            // once ↑ has pulled a past question into the box, pressing ↑/↓ again
            // steps through history instead of moving the caret. Otherwise (text
            // present, no recall) the arrows move the caret as usual. `onDown`/`onUp`
            // return whether they consumed the key, so ↓ with no history at all still
            // falls through to default behaviour.
            // …and an open menu takes them first, text or no text: with `/no` in
            // the box the arrows belong to the menu's rows, not to the caret.
            let emptyOrRecalling =
                parent.isMenuOpen()
                || parent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || parent.isRecalling()
            if commandSelector == #selector(NSResponder.moveDown(_:)), emptyOrRecalling {
                return parent.onDown()
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)), emptyOrRecalling {
                return parent.onUp()
            }
            return false
        }
    }
}

/// The compact substring filter that sits above the recent list once it grows past a
/// handful of rows. An `NSViewRepresentable` over `NSTextField` — NOT a SwiftUI
/// `TextField` — for the same reason `PromptField` is: a plain SwiftUI field pops the
/// floating autocomplete/suggestions panel and applies smart substitutions, which
/// would be jarring over the glass. We reuse `PromptField.disableEditorMagic` to kill
/// all of that on the field editor. Deliberately *not* auto-focused: keyboard focus
/// stays in the main prompt so ↓/↑ still drive the list; the user clicks the field to
/// start filtering.
struct HistorySearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat
    /// When this flips true the field grabs first-responder once, so the filter
    /// icon can deposit the caret straight into the expanded field.
    var focusTrigger: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        // MagiclessTextField matters MOST here: this field is deliberately not
        // auto-focused (see above) — a click is its normal way in, which is
        // exactly the path where editor magic used to stay armed until the
        // first committed keystroke.
        let field = MagiclessTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.isAutomaticTextCompletionEnabled = false
        field.allowsCharacterPickerTouchBarItem = false
        field.importsGraphics = false
        field.allowsEditingTextAttributes = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        applyStyle(to: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Same composition guard as PromptField: never overwrite the field while an
        // IME composition is in flight, or half-typed pinyin gets wiped.
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if !composing, field.stringValue != text { field.stringValue = text }
        applyStyle(to: field)
        // Kill editor-level magic whenever this field owns the field editor (the
        // editor is created lazily on first focus; re-applying is harmless).
        if let editor = field.currentEditor() {
            PromptField.disableEditorMagic(editor)
        }
        // Take focus exactly ONCE per rising edge of focusTrigger, mirroring
        // PromptField's latch so we don't fight the field editor on every render.
        let coord = context.coordinator
        if focusTrigger {
            if !coord.didFocus, field.window != nil, field.currentEditor() == nil {
                coord.didFocus = true
                DispatchQueue.main.async { [weak field] in
                    guard let field, field.currentEditor() == nil else { return }
                    field.window?.makeFirstResponder(field)
                    if let editor = field.currentEditor() {
                        // Collapse the auto-select-all that `becomeFirstResponder`
                        // does, so a re-focus drops a caret at the end instead of
                        // highlighting the whole field (see PromptField for why).
                        editor.selectedRange = NSRange(location: editor.string.count, length: 0)
                        PromptField.disableEditorMagic(editor)
                    }
                }
            }
        } else {
            coord.didFocus = false   // re-arm for the next expand
        }
    }

    private func applyStyle(to field: NSTextField) {
        let wantFont = NSFont.systemFont(ofSize: fontSize)
        if field.font != wantFont { field.font = wantFont }
        let wantText = NSColor(Tokens.text2)
        if field.textColor != wantText { field.textColor = wantText }
        let wantPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor(Tokens.text4),
                .font: wantFont,
            ]
        )
        if field.placeholderAttributedString != wantPlaceholder {
            field.placeholderAttributedString = wantPlaceholder
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: HistorySearchField
        /// One-shot latch: true once we've taken focus for the current rising edge
        /// of `focusTrigger`, reset when it falls.
        var didFocus = false
        init(_ parent: HistorySearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            PromptField.disableEditorMagic(field.currentEditor())
            // Same IME fix as PromptField: drop the island below the candidate window
            // while this filter field is being typed into.
            (field.window as? NotchPanel)?.beginFieldEditing()
        }

        func controlTextDidEndEditing(_ note: Notification) {
            ((note.object as? NSTextField)?.window as? NotchPanel)?.endFieldEditing()
        }
    }
}

/// The send button — a piece of the same **Liquid Glass** as the rest of the
/// island (native `.glassEffect` on macOS 26+, blur fallback below), brightening
/// gently on hover rather than flooding to a flat white fill.
///
/// Two shapes, one control:
///   • Given a `label` ("Ask" / "Note"), it renders a **pill that spells out the
///     destination in words** — because a glyph alone (arrow vs. pencil) doesn't
///     read as "ask vs. note" at a glance. The classifier watches the text as it's
///     typed and swaps the word in place; the glyph beside it is a plain ⏎, marking
///     the key you press. So the button tells you in plain language where Enter
///     sends the line, before you press it.
///   • With no `label` (the mid-thread follow-up), it stays a bare arrow circle:
///     a follow-up is always an ask, so there's nothing to disambiguate and the
///     small inline field has no room for a word.
///
/// The label cross-fades when it flips, so ask⇄note reads as one control changing
/// meaning rather than two different buttons.
struct SendButton: View {
    var compact: Bool = false
    /// SF Symbol for the action the current text will trigger. Defaults to the
    /// classic send arrow; callers pass a note glyph when the input reads as a jot.
    var icon: String = "arrow.right"
    /// The destination spelled out ("Ask" / "Note"). When set, the button renders
    /// as a labeled pill; when `nil`, it's the bare arrow circle (follow-up).
    var label: String? = nil
    var action: () -> Void
    @State private var hovering = false

    private var size: CGFloat { compact ? 27 : 30 }

    var body: some View {
        Button(action: action) {
            if let label {
                pill(label)
            } else {
                glyphCircle
            }
        }
        // Same press-give as the island's other glass chips.
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        // The flip rides a quick spring so ask⇄note feels like the control morphing,
        // in step with the rest of the panel's motion language.
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: icon)
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: label)
    }

    /// The labeled form: a glass pill reading "Ask ⏎" / "Note ⏎", the word leading
    /// so the destination is the first thing you read. Whole contents keyed on the
    /// label so a change cross-fades rather than hard-cuts.
    private func pill(_ label: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.sf(13, weight: .semibold))
            Image(systemName: icon)
                .font(.sf(12, weight: .semibold))
        }
        .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
        .id(label)
        .transition(.scale(scale: 0.7).combined(with: .opacity))
        .padding(.horizontal, 13)
        .frame(height: size)
        .glassCapsule(in: Capsule(), brighter: hovering)
        .contentShape(Capsule())
    }

    /// The bare form: just the send arrow in a glass circle (mid-thread follow-up).
    private var glyphCircle: some View {
        Image(systemName: icon)
            .font(.sf(13, weight: .semibold))
            .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
            .id(icon)
            .transition(.scale(scale: 0.55).combined(with: .opacity))
            .frame(width: size, height: size)
            .glassCapsule(in: Circle(), brighter: hovering)
            .contentShape(Circle())
    }
}

/// A small circular icon button rendered in the **Liquid Glass** language: a
/// real translucent glass capsule (native `.glassEffect` on macOS 26+, a blurred
/// `NSVisualEffectView` fallback below that) with the signature soft specular rim
/// and a gentle brighten-on-hover. Used for the in-panel settings entry so the
/// affordance reads as a piece of the same glass island, not a flat icon.
struct GlassIconButton: View {
    var systemName: String
    var help: String
    /// Which side the hover hint floats on — `.top` by default, since these chips
    /// sit at the panel's bottom edge where up is where the room is.
    var tipEdge: VerticalEdge = .top
    var size: CGFloat = 30
    /// Glyph point size inside the capsule. Defaults to the original 14pt; the
    /// compact header corners pass a smaller value so the glass reads as a quiet
    /// mark rather than a full button.
    var glyphSize: CGFloat = 14
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.sf(glyphSize, weight: .regular))
                .foregroundStyle(hovering ? Tokens.text1 : Tokens.text3)
                // Cross-fade the glyph when `systemName` flips (e.g. ⋯ ⇄ back chevron
                // on the manage chip). No-op for the static-icon callers since their
                // symbol never changes.
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .glassCapsule(in: Circle(), brighter: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        // `help` used to be accepted and silently dropped — this chip was the one
        // icon button in the app with NO hover hint at all, while its neighbours
        // carried the glass tip and the segment cluster carried AppKit's yellow
        // bubble. One tooltip species everywhere now.
        .notchTooltip(help, edge: tipEdge)
        .accessibilityLabel(help)
    }
}

/// A row of glyphs riding one Liquid Glass capsule — the panel/detached-window
/// trailing-cluster species, extracted so every caller shares one implementation.
/// The capsule is a quiet whisper of glass at rest and comes to full rim+specular
/// strength whenever the pointer is on any segment (or a segment is `engaged`,
/// e.g. a live pin); each segment carries a soft round highlight under its glyph.
/// `ResultTrailingCluster`, `WindowTrailingCluster`, and the agent detail header
/// all build on this — don't hand-roll another two-icon glass pill.
struct GlassSegmentCluster: View {
    struct Segment {
        var engaged: Bool
        var tooltip: String
        var action: () -> Void
        var glyph: AnyView

        init<Glyph: View>(engaged: Bool = false, tooltip: String,
                          action: @escaping () -> Void,
                          @ViewBuilder glyph: () -> Glyph) {
            self.engaged = engaged
            self.tooltip = tooltip
            self.action = action
            self.glyph = AnyView(glyph())
        }
    }

    var segments: [Segment]
    /// Square tap target per segment (also the pill's height).
    var chip: CGFloat = 26
    /// Which side the hover hints float on. Every caller parks this cluster in a
    /// header at the top of its panel/window, so the tip drops DOWN by default —
    /// floating it up would run it off the top edge.
    var tipEdge: VerticalEdge = .bottom
    /// Drop the glass pill and render the glyphs bare. For the panel's result
    /// header, where these chips are hover-only chrome: a slab of glass appearing
    /// and vanishing with the pointer reads as the panel twitching, while bare
    /// marks just arrive. Without the pill the glyphs carry their own resting
    /// dimming (the glass used to do it) and stand further apart, since nothing
    /// binds them into one control any more.
    var glass: Bool = true

    // Identity is by index (stable across rebuilds), so the hover highlight
    // survives re-renders — a per-segment UUID would churn and drop it.
    @State private var hoveredIndex: Int? = nil

    var body: some View {
        HStack(spacing: glass ? 2 : 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, seg in
                let hovering = hoveredIndex == index
                Button(action: seg.action) {
                    seg.glyph
                        // Glassed: pure white, the pill behind carries the resting
                        // dimming. Bare: the glyph does it itself, and rests QUIET —
                        // the answer-footer icons' level (text3), not a second row of
                        // bright chrome competing with the text. Direct hover (or a
                        // live pin) brings it up to full ink.
                        .foregroundStyle(glass ? Tokens.ink
                                              : (hovering || seg.engaged ? Tokens.text1
                                                                         : Tokens.text3))
                        .frame(width: chip, height: chip)
                        .background(
                            Circle().fill(.white.opacity(
                                seg.engaged ? 0.20 : (hovering && glass ? 0.12 : 0)))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(GlassPressStyle())
                .onHover { inside in
                    if inside { hoveredIndex = index }
                    else if hoveredIndex == index { hoveredIndex = nil }
                }
                // The island's own glass tip, not AppKit's stock yellow bubble —
                // these glyphs sit inches from the answer footer's icons, which
                // have always used `notchTooltip`; two tooltip materials on one
                // screen read as two different apps.
                .notchTooltip(seg.tooltip, edge: tipEdge)
                // `.help()` doubled as the VoiceOver description; the glass tip
                // is purely visual, so name the control explicitly.
                .accessibilityLabel(seg.tooltip)
            }
        }
        .padding(glass ? 3 : 0)
        // The whole cluster is the chip: glass carries ALL the resting dimming
        // (rendered behind the glyphs, so they stay pure white even at rest) and
        // lights fully when hovered or while a segment is engaged.
        .background {
            if glass {
                let lit = hoveredIndex != nil || segments.contains { $0.engaged }
                Color.clear
                    .glassCapsule(in: Capsule(), brighter: lit)
                    .opacity(lit ? 1 : 0.55)
            }
        }
        .animation(.easeOut(duration: 0.18), value: hoveredIndex)
        .animation(.easeOut(duration: 0.18), value: segments.map(\.engaged))
    }
}

/// A small **text** pill in the same Liquid Glass language as `GlassIconButton`
/// — a translucent glass capsule that brightens on hover. Used for word actions
/// like "Clear" so they read as part of the glass island, not flat link text.
struct GlassTextButton: View {
    var title: String
    /// Text size; the capsule's padding scales with it so the pill stays
    /// proportional. Defaults to the original 11pt.
    var fontSize: CGFloat = 11
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.sf(fontSize, weight: .medium))
                .foregroundStyle(hovering ? Tokens.text2 : Tokens.text4)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassCapsule(in: Capsule(), brighter: hovering)
                .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

/// The panel header's back control as **one whole piece of Liquid Glass** —
/// chevron and panel title live inside a single glass capsule instead of a bare
/// glyph sitting next to a loose caption. The header then reads as one physical
/// affordance you press, in the same material as every other chip on the island,
/// rather than two unrelated marks that happen to share a row.
struct PanelBackPill: View {
    var title: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.sf(10.5, weight: .semibold))
                Text(title)
                    .font(.sf(11, weight: .semibold))
                    .tracking(0.4)
                    .lineLimit(1)
            }
            .foregroundStyle(hovering ? Tokens.text1 : Tokens.text3)
            .padding(.leading, 8)
            .padding(.trailing, 11)
            .frame(height: 26)
            .glassCapsule(in: Capsule(), brighter: hovering)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

/// The panel header's back chevron — the one control that walks a full-panel
/// module (Settings, What's New, the first-run guide) back where it came from.
/// A quiet 26pt glyph over the same soft capsule wash every other row-level
/// affordance uses, so the three headers open and close with one gesture in one
/// voice. Three copies of this used to drift apart: two byte-identical, and the
/// onboarding's a 30pt `.plain` button at a lighter weight and a dimmer ink that
/// gave no hover feedback at all.
///
/// Not to be confused with the result header's `GlassBackButton` — that one is a
/// real glass circle because it sits *on* the glass, opposite the glass trailing
/// cluster; this one sits inside a panel's own chrome.
struct PanelBackButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.sf(13, weight: .semibold))
                .foregroundStyle(Tokens.text2)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(RecentEntryStyle())
    }
}

/// Scales the glass capsule down a touch on press for a tactile, physical feel —
/// the glass "gives" under the cursor like the rest of the island. Internal so
/// other glass chips (e.g. the manage menu's filter capsules) share the feel.
struct GlassPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// The trailing "open in Notes/Reminders" pill on a capture row — one control
/// shared by the notch's Recent list and the standalone archive window, so the
/// jump looks and feels identical wherever the row is read. A quiet tinted glass
/// capsule at rest that brightens under the cursor, the same hover language the
/// rows themselves speak, and gives on press like every other glass chip.
struct CaptureJumpButton: View {
    let title: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                    .font(.sf(11, weight: .medium))
                Image(systemName: "arrow.up.right")
                    .font(.sf(8, weight: .semibold))
            }
            .foregroundStyle(hovering ? Tokens.text2 : Tokens.text3)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .glassCapsule(in: Capsule(), brighter: hovering, tint: tint)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

/// A one-shot **rim glow** that pulses whenever a watched value changes — the input
/// field's outer acknowledgement that its *destination* just flipped (Ask → Note →
/// Remind). The destination pill below already cross-fades its word; this brightens
/// the field's own border for a beat so the change registers in peripheral vision
/// too, not only where the eye is reading.
///
/// Mechanics: brighten instantly (no animation) on the change, then ease back to rest —
/// a struck-then-settles curve, the same shape the entry kick uses, so the field reads
/// as having been *tapped* by the switch rather than slowly glowing. Keyed on an
/// `Equatable` trigger so it fires once per real transition; passing the intent
/// *category* (not the full label) keeps a "Remind · Daily" → "Remind · Weekly" suffix
/// edit from pulsing, since the destination itself didn't move.
private struct IntentChangePulse<Trigger: Equatable, S: InsettableShape>: ViewModifier {
    var trigger: Trigger
    var shape: S
    /// The colour of the flash — the NEW destination's tint (read live from the
    /// call site, so the rim strikes in the colour the field just switched TO).
    /// Defaults to the original white for callers without a destination colour.
    var tint: Color = .white
    @State private var glow: Double = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                shape
                    .strokeBorder(tint.opacity(0.55 * glow), lineWidth: 1)
                    .blur(radius: 1.5)
                    .allowsHitTesting(false)
            )
            .onChange(of: trigger) { _, _ in
                // Strike: jump to full on its own (instant) transaction so the brighten
                // is a hit, not a ramp; then release back to rest on a soft ease.
                var instant = Transaction(); instant.disablesAnimations = true
                withTransaction(instant) { glow = 1 }
                withAnimation(.easeOut(duration: 0.45)) { glow = 0 }
            }
    }
}

extension View {
    /// Pulse a soft rim glow on `shape` each time `trigger` changes — see
    /// `IntentChangePulse`. Used on the prompt field to flash its border when the
    /// Ask/Note/Remind destination flips; `tint` colours the flash with the new
    /// destination's hue (defaults to the original white).
    func intentChangePulse<T: Equatable, S: InsettableShape>(
        on trigger: T, shape: S, tint: Color = .white
    ) -> some View {
        modifier(IntentChangePulse(trigger: trigger, shape: shape, tint: tint))
    }
}

extension View {
    /// Wrap the content in a Liquid Glass chip of the given shape — genuine system
    /// glass on macOS 26+, a dark blur fallback below — topped with the same
    /// whisper-thin specular rim the island uses, so it sits in the same material
    /// family. Works for both circular icon chips and capsule text pills.
    @ViewBuilder
    func glassCapsule<S: InsettableShape>(in shape: S, brighter: Bool, tint: Color? = nil) -> some View {
        self
            .background {
                if #available(macOS 26.0, *) {
                    shape.fill(.clear)
                        .glassEffect(.clear.interactive(), in: shape)
                } else {
                    LegacyGlassBackdrop().clipShape(shape)
                }
            }
            // Both overlays are purely decorative (tint + specular rim). They sit ON
            // TOP of the content, and a filled/stroked Shape is hit-testable by
            // default — which would swallow taps meant for any control *nested* inside
            // a capsule (e.g. a remove × or inline button). Mark them non-interactive
            // so clicks pass through to the content below.
            //
            // `tint`, when set, washes the fill in a colour instead of plain white — a
            // whisper of hue so a chip can read as a slightly different colour from its
            // untinted siblings while staying in the same glass material.
            .overlay(
                shape.fill((tint ?? .white)
                    .opacity(tint != nil ? (brighter ? 0.30 : 0.20) : (brighter ? 0.10 : 0.04)))
                    .allowsHitTesting(false)
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(brighter ? 0.32 : 0.20),
                            .white.opacity(0.06),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
                .allowsHitTesting(false)
            )
            // Real Liquid Glass barely casts a shadow — it reads as a thin chip of
            // glass, not a floating card. Just a whisper of a contact shadow to
            // seat it on the island; the specular rim does the rest of the work.
            .shadow(color: .black.opacity(0.10), radius: 1.5, y: 0.5)
    }
}

/// A minimal left-aligned flow layout: lays children left-to-right, wrapping to the
/// next line when the next child would overflow the proposed width. Used for the
/// model-picker chip row, which can carry more chips than fit the panel on one
/// line. Deliberately tiny — no alignment knobs beyond leading — since that's all the
/// chip row needs; reach for a real grid if a second caller wants more.
struct FlowLayout: Layout {
    var hSpacing: CGFloat = 6
    var vSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                // Wrap: bank the finished row's width, drop to the next line.
                widest = max(widest, x - hSpacing)
                x = 0; y += rowHeight + vSpacing; rowHeight = 0
            }
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x - hSpacing)
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0; y += rowHeight + vSpacing; rowHeight = 0
            }
            view.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The destructive "Clear recent history?" confirmation, rendered as a card
/// **centered over the whole island** rather than a popover anchored to the Clear
/// pill (which dropped it down near the bottom of the panel). A dim scrim catches
/// outside taps to cancel; the card itself floats in the middle of the glass.
struct ClearHistoryConfirm: View {
    /// Rows filed in the last 24 hours, and the archive's total. The narrow scope is
    /// only offered when it's a real choice — with nothing recent (0) or nothing
    /// *but* recent (== total), both buttons would do the same thing, so the card
    /// falls back to the plain Cancel / Clear History pair.
    var lastDayCount: Int
    var totalCount: Int
    var onCancel: () -> Void
    var onConfirm: (NotchModel.HistoryClearScope) -> Void

    private var offersScopeChoice: Bool { lastDayCount > 0 && lastDayCount < totalCount }

    var body: some View {
        ZStack {
            // Scrim over the whole island — darkens the panel behind the card and
            // catches a tap-outside to dismiss, like the native dialog's backdrop.
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    Text(L("clear.title"))
                        .font(.sf(15, weight: .semibold))
                        .foregroundStyle(Tokens.text1)
                    Text(L(offersScopeChoice ? "clear.body.scope" : "clear.body"))
                        .font(.sf(12))
                        .foregroundStyle(Tokens.text3)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if offersScopeChoice {
                    // Two reaches, stacked mild-first: the day window reads as plain
                    // glass, "Everything" as red-tinted glass. Cancel drops out of the
                    // material entirely so three capsules don't read as three peers.
                    VStack(spacing: 8) {
                        ConfirmDialogButton(title: L("clear.scope.lastDay"),
                                            kind: .neutral) { onConfirm(.lastDay) }
                        ConfirmDialogButton(title: L("clear.scope.all"),
                                            kind: .destructive) { onConfirm(.all) }
                        ConfirmDialogButton(title: L("clear.cancel"),
                                            kind: .quiet,
                                            action: onCancel)
                    }
                } else {
                    HStack(spacing: 10) {
                        ConfirmDialogButton(title: L("clear.cancel"), kind: .neutral, action: onCancel)
                        ConfirmDialogButton(title: L("clear.confirm"), kind: .destructive) { onConfirm(.all) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: 280)
            .background {
                // Real Liquid Glass, same recipe as the app's other floating cards
                // (`GlassPopoverBackground`): `nativeGlass` for the refraction, a
                // light veil for text contrast — light, not the popovers' occluding
                // 0.42, because this card floats over the island's *own* glass and
                // a scrim, so it can stay airy — then the sheen + specular rim that
                // make it read as a slab of glass rather than a drawn box.
                let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
                ZStack {
                    shape.fill(.clear)
                        .nativeGlass(in: shape)
                        .overlay(shape.fill(Color.black.opacity(0.16)))
                    shape
                        .fill(LinearGradient(colors: [.white.opacity(0.12), .clear],
                                             startPoint: .top, endPoint: .center))
                        .blendMode(.plusLighter)
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.08)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.75)
                }
                .compositingGroup()
                .shadow(color: .black.opacity(0.40), radius: 22, y: 12)
            }
            .padding(24)
        }
    }
}

/// A full-width Liquid Glass button for the confirmation card — the app's own
/// `glassCapsule` material (genuine `.glassEffect` on macOS 26+, blur fallback
/// below), washed white for a neutral action and red for the destructive one. The
/// `quiet` kind carries no material at all: it's the Cancel that sits *below*
/// stacked choices, where a third capsule would read as a third option. Brightens on
/// hover and gives under the press, like every other glass control in the panel.
private struct ConfirmDialogButton: View {
    var title: String
    var kind: Kind
    var action: () -> Void

    enum Kind { case neutral, destructive, quiet }

    @State private var hovering = false

    private var label: Color {
        switch kind {
        case .destructive: Tokens.danger
        case .neutral: Tokens.text1
        case .quiet: hovering ? Tokens.text1 : Tokens.text3
        }
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.sf(13, weight: .semibold))
                .foregroundStyle(label)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .glassButtonSkin(kind: kind, hovering: hovering)
                .contentShape(Capsule())
        }
        .buttonStyle(ConfirmDialogPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

private extension View {
    /// The capsule's material, split out so the `quiet` kind can opt out of glass
    /// entirely (a bare hover wash) while the other two share `glassCapsule`.
    @ViewBuilder
    func glassButtonSkin(kind: ConfirmDialogButton.Kind, hovering: Bool) -> some View {
        switch kind {
        case .quiet:
            self.background(Capsule().fill(Color.white.opacity(hovering ? 0.08 : 0)))
        case .neutral:
            self.glassCapsule(in: Capsule(), brighter: hovering)
        case .destructive:
            self.glassCapsule(in: Capsule(), brighter: hovering, tint: Tokens.danger)
        }
    }
}

/// Liquid Glass gives under a press. A touch of squash on the whole capsule, on the
/// panel's usual short spring — the material's own interactive highlight
/// (`.glassEffect(.clear.interactive())` inside `glassCapsule`) does the rest.
private struct ConfirmDialogPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.72),
                       value: configuration.isPressed)
    }
}

/// The calm three-dot "thinking" wave used while the AI works. `dot`/`spacing`
/// scale the wave down for tight homes (the resting notch's busy extension);
/// the defaults are the original in-panel size.
struct ThinkingDots: View {
    var dot: CGFloat = 6
    var spacing: CGFloat = 7
    @State private var phase = false

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Tokens.text3)
                    .frame(width: dot, height: dot)
                    .scaleEffect(phase ? 1.0 : 0.82)
                    .opacity(phase ? 0.85 : 0.18)
                    .offset(y: phase ? -2 : 0)
                    .animation(
                        .easeInOut(duration: 0.62)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.16),
                        value: phase
                    )
            }
        }
        .frame(minHeight: 22)
        .onAppear { phase = true }
    }
}

/// The "thinking orb" beside the wait word — a 1:1 port of the reference
/// implementation (orbs.jakubantalik.com, github.com/Jakubantalik/thinking-orbs),
/// NOT an approximation. What's ported, file by file:
///
/// - `engine/core.ts` → `OrbEngine`'s primitives: `fibDir` (Fibonacci lattice),
///   `makeProj` (spin + tilt + orthographic projection), `paint` (z-sorted
///   far→near painter, matte grayscale dots whose ink value is mirrored on the
///   dark substrate so near dots read bright) and `radiusScale` (sub-linear
///   size compensation, tuned around a 300pt frame).
/// - `engine/ribbon.ts` → `drawRibbon` (the demo's "Thinking…." pill),
///   `engine/lattice.ts` → `drawGlobe` (searching — a scan meridian sweeps a
///   dotted globe) and `drawRubik` (solving — the same dot field cut into
///   bands that twist in quarter turns, scramble, then click back),
///   `engine/orbits.ts` → `drawOrbits` (working — particles on tilted
///   orbits). All verbatim.
/// - `engine/profiles.ts` + `presets.ts` → each mode's base profile with its
///   inline `@ size 20` preset applied through the same `scaleCounts` /
///   `scaleRadii` machinery. The reference's remaining two modes (wave /
///   morph) have no Notch wait state to wear them, so they aren't ported —
///   dead code isn't fidelity.
///
/// Which mode shows is SEMANTIC, decided where the activity originates (the
/// agent harness knows which tool it just launched — see
/// `AgentHarness.orbState(for:)`), never sniffed back out of a localized
/// status string:
///   • no tool activity (mood word / bare wait)      → `.composing` (ribbon)
///   • a first search round, or reading a page       → `.searching` (globe)
///   • a repeat search round ("digging deeper")      → `.solving`   (rubik)
///   • any other tool running                        → `.working`   (orbits)
/// A state change cross-dissolves on the house beat rather than the
/// reference's hard remount — the one deliberate deviation, matching how
/// `CrossfadeText` melts the wait words this orb sits beside.
///
/// Grayscale literals here are the reference's own ink values, not house
/// tokens, deliberately: fidelity to the source is the point. Under Reduce
/// Motion this renders the reference's static representative frame (t = 0.6),
/// exactly as `ThinkingOrb.tsx` does for `prefers-reduced-motion`.
struct ThinkingOrb: View {
    /// Which of the ported reference states to show. Defaults to the calm
    /// "Thinking…." ribbon; the wait lines pass the live semantic state.
    var state: OrbState = .composing
    /// Rendered size. The reference ships exactly one inline tuning — 20 CSS
    /// px — and every preset below is that tuning, so this stays 20 unless
    /// a new preset is deliberately baked.
    var size: CGFloat = 20

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let preset = OrbEngine.preset(for: state)
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            // The reference clock: seconds × the preset's baked speed. Reduced
            // motion gets the reference's fixed frame (`frame(0.6)`).
            let t = reduceMotion
                ? 0.6
                : timeline.date.timeIntervalSinceReferenceDate * preset.speed
            // The ZStack is the stage for the state cross-dissolve: on a state
            // change the outgoing mode's last frame fades under the incoming
            // live one (`.id` swaps identity, `.transition` overlaps them).
            ZStack {
                Canvas { ctx, canvasSize in
                    preset.draw(&ctx,
                                Double(min(canvasSize.width, canvasSize.height)),
                                t,
                                preset.opts)
                }
                .id(state)
                .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: state)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Center a fixed-size glyph (the orb) on the OPTICAL middle of the text it
    /// sits beside, rather than on its line box.
    ///
    /// `HStack`'s default `.center` aligns the two *boxes*, and a text box is
    /// not centered on its own glyphs: the line box grows to whatever font
    /// actually renders the run, and a mixed Latin/CJK line falls back to
    /// PingFang, whose ascent/descent are both far taller than the glyphs
    /// themselves. The orb then floats visibly above the words it belongs to.
    ///
    /// Anchoring to the baseline instead makes the pairing metric-independent:
    /// the orb's centre lands 0.36em above the baseline — the midpoint of SF's
    /// cap height (0.72em) and, within a third of a point, of the CJK ideographic
    /// square (−0.12em…0.88em). So Latin, Chinese, and a line mixing both all
    /// read centred against the same orb.
    func centeredOnTextGlyphs(fontSize: CGFloat) -> some View {
        alignmentGuide(.firstTextBaseline) { d in d.height / 2 + fontSize * 0.36 }
    }
}

/// The reference states Notch actually wears, named exactly as `types.ts`
/// names them (`OrbState`). The mapping from Notch's wait-line semantics to
/// these lives with the producers (harness / model), not the views.
enum OrbState: Hashable {
    /// Ribbon — the demo's "Thinking…." pairing. The default calm state.
    case composing
    /// Globe with a sweeping scan meridian — the search flow.
    case searching
    /// Bands twisting in quarter turns, scrambling then clicking back to
    /// solved — a second-or-later search round, where the wait line reads
    /// "digging deeper" rather than a fresh search. Named for the reference
    /// state it wears (`solving`), not for Notch's copy; it shares the globe's
    /// dot field on purpose, so a repeat round still reads as the same search
    /// flow instead of a different job starting.
    case solving
    /// Particles on tilted orbits — a non-search tool doing work.
    case working
}

/// The dotted-orb engine, ported 1:1 from `thinking-orbs/src/engine`. Kept as
/// literal a translation as Swift allows — same names, same formulas, same
/// defaults — so it can be diffed against the TypeScript source line by line.
enum OrbEngine {
    /// `core.ts` `Dot`: ink `white` is 0 = darkest ink on paper; the painter
    /// mirrors it on our dark glass so near dots read bright.
    struct Dot {
        var x: Double
        var y: Double
        var z: Double
        var r: Double
        var white: Double
        var a: Double = 1
    }

    /// `core.ts` `hashD`: deterministic hash in [0, 1).
    static func hashD(_ a: Double, _ b: Double) -> Double {
        let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
        return h - h.rounded(.down)
    }

    /// `core.ts` `angleDelta`: shortest signed angular distance, wrapped to (−π, π].
    static func angleDelta(_ a: Double, _ b: Double) -> Double {
        atan2(sin(a - b), cos(a - b))
    }

    /// `core.ts` `fibDir`: stable directions on a unit sphere (Fibonacci lattice).
    static func fibDir(_ i: Int, _ n: Int) -> (Double, Double, Double) {
        let golden = Double.pi * (3 - sqrt(5.0))
        let y = 1 - (2 * (Double(i) + 0.5)) / Double(n)
        let rad = sqrt(max(0, 1 - y * y))
        let a = Double(i) * golden
        return (rad * cos(a), y, rad * sin(a))
    }

    /// `core.ts` `makeProj`: shared spin + tilt + orthographic projection.
    static func makeProj(yaw: Double, tilt: Double, cx: Double, cy: Double, scale: Double)
        -> (Double, Double, Double) -> (Double, Double, Double) {
        let st = sin(tilt), ct = cos(tilt)
        let sy = sin(yaw), cyw = cos(yaw)
        return { x, y, z in
            let x1 = x * cyw + z * sy
            let z1 = -x * sy + z * cyw
            let y1 = y * ct - z1 * st
            let z2 = y * st + z1 * ct
            return (cx + x1 * scale, cy - y1 * scale, z2)
        }
    }

    /// `core.ts` `paint`: z-sort far→near, matte grayscale dots. Notch's glass
    /// is always the dark substrate, so the ink value is mirrored (`1 - white`)
    /// unconditionally — the reference's `dark: true` path.
    static func paint(_ ctx: inout GraphicsContext, _ dots: inout [Dot], rMin: Double = 0.3) {
        dots.sort { $0.z < $1.z }
        for d in dots {
            guard d.a >= 0.02 else { continue }
            let w = min(1, max(0, d.white))
            let g = 1 - w
            let r = max(rMin, d.r)
            let rect = CGRect(x: d.x - r, y: d.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(Color(white: g, opacity: d.a)))
        }
    }

    /// `core.ts` `radiusScale`: dot radii were tuned for a 300pt frame;
    /// sub-linear scaling keeps small spinners legible.
    static func radiusScale(_ size: Double, _ power: Double) -> Double {
        pow(size / 300, power)
    }

    // MARK: profiles + preset (`profiles.ts`, `presets.ts`)

    /// `BASE_PROFILES.ribbon`, verbatim.
    static let ribbonBase: [String: Double] = [
        "lanes": 5, "segs": 88, "ghostN": 150,
        "rBase": 1.1, "rDepth": 1.7, "rsPow": 0.6, "rMin": 0.3,
    ]

    /// `profiles.ts` `scaleCounts`: paired 2-D lattice counts each take √scale
    /// so the TOTAL scales by `scale`; flat counts scale linearly. Only the
    /// keys the ribbon profile carries matter here, but the pair table is kept
    /// whole to stay diffable against the source.
    static func scaleCounts(_ opts: [String: Double], _ scale: Double) -> [String: Double] {
        var out = opts
        var done = Set<String>()
        let rt = sqrt(scale)
        let countPairs = [("latRings", "lonDensity"), ("rings", "lonDensity"), ("lanes", "segs")]
        for (a, b) in countPairs {
            if let va = out[a], let vb = out[b], !done.contains(a), !done.contains(b) {
                out[a] = max(2, (va * rt).rounded())
                out[b] = max(2, (vb * rt).rounded())
                done.insert(a)
                done.insert(b)
            }
        }
        for k in ["orbitN", "ghostN"] {
            if let v = out[k], !done.contains(k) { out[k] = max(1, (v * scale).rounded()) }
        }
        if let v = out["iconD"] { out["iconD"] = max(0.02, v * scale) }
        return out
    }

    /// `profiles.ts` `scaleRadii`: every radius key scales together so a dot's
    /// near/far falloff stays intact while the mark shrinks or grows.
    static func scaleRadii(_ opts: [String: Double], _ scale: Double) -> [String: Double] {
        var out = opts
        for k in ["rBase", "rDepth", "rActive", "rDot", "ghostR", "partR", "partRDepth"] {
            if let v = out[k] { out[k] = v * scale }
        }
        out["rSizeMul"] = (out["rSizeMul"] ?? 1) * scale
        return out
    }

    /// `BASE_PROFILES.globe`, verbatim. (`rBoost` is deliberately absent from
    /// `RADIUS_KEYS` in the source, so preset radius scaling leaves it alone.)
    static let globeBase: [String: Double] = [
        "latRings": 17, "lonDensity": 44,
        "rBase": 0.6, "rDepth": 1.7, "rBoost": 1.0,
        "inkFar": 0.62, "inkSpan": 0.54, "rsPow": 0.6, "rMin": 0.3,
    ]

    /// `BASE_PROFILES.rubik`, verbatim. (`moveCount` is the scramble LENGTH,
    /// not a lattice count key in the source, so preset count scaling leaves
    /// it alone — the sphere thins out, the scramble stays 14 moves long.)
    static let rubikBase: [String: Double] = [
        "latRings": 15, "lonDensity": 40, "moveCount": 14,
        "rBase": 0.6, "rDepth": 1.7, "rActive": 0.3,
        "inkFar": 0.62, "inkSpan": 0.54, "rsPow": 0.6, "rMin": 0.3,
    ]

    /// `BASE_PROFILES.orbits`, verbatim. (`particles` is per-orbit and not a
    /// count key in the source, so it survives count scaling untouched.)
    static let orbitsBase: [String: Double] = [
        "orbitN": 12, "ghostN": 40, "ghostR": 0.9, "ghostA": 0.5,
        "particles": 3, "partR": 1.2, "partRDepth": 1.6,
        "rsPow": 0.6, "rMin": 0.3,
    ]

    /// One resolved (state, 20) preset: the mode's baked clock multiplier, its
    /// fully-scaled draw options, and its frame painter.
    struct OrbPreset {
        let speed: Double
        let opts: [String: Double]
        let draw: (inout GraphicsContext, Double, Double, [String: Double]) -> Void
    }

    /// `resolvePreset(state, 20)` for the three states Notch wears, each built
    /// through the same machinery as the source and cached once:
    ///   composing → ribbon 20 {speed 3.12,  count ×0.051, size ×1.073,
    ///                          spin 0, bandMul 4.94, wobMul 1}
    ///   searching → globe  20 {speed 2.665, count ×0.105, size ×1.75,
    ///                          scanMul 4.335, dimBase 0.45}
    ///   solving   → rubik  20 {speed 1.95,  count ×0.088, size ×1.9}
    ///   working   → orbits 20 {speed 3.9,   count ×0.238, size ×2.4}
    private static let presets: [OrbState: OrbPreset] = {
        var composing = scaleRadii(scaleCounts(ribbonBase, 0.051), 1.073)
        for (k, v) in ["spin": 0.0, "bandMul": 4.94, "wobMul": 1.0] { composing[k] = v }

        var searching = scaleRadii(scaleCounts(globeBase, 0.105), 1.75)
        for (k, v) in ["scanMul": 4.335, "dimBase": 0.45] { searching[k] = v }

        let solving = scaleRadii(scaleCounts(rubikBase, 0.088), 1.9)

        let working = scaleRadii(scaleCounts(orbitsBase, 0.238), 2.4)

        return [
            .composing: OrbPreset(speed: 3.12, opts: composing, draw: drawRibbon),
            .searching: OrbPreset(speed: 2.665, opts: searching, draw: drawGlobe),
            .solving: OrbPreset(speed: 1.95, opts: solving, draw: drawRubik),
            .working: OrbPreset(speed: 3.9, opts: working, draw: drawOrbits),
        ]
    }()

    static func preset(for state: OrbState) -> OrbPreset {
        presets[state]!   // the table covers every OrbState case by construction
    }

    // MARK: ribbon (`ribbon.ts`)

    /// `drawRibbon`, verbatim: an undulating sash of parallel strands rides a
    /// great circle over a faint Fibonacci ghost shell. With the preset's
    /// spin = 0 the 3D tumble is frozen — only the traveling undulation moves.
    static func drawRibbon(_ ctx: inout GraphicsContext, size: Double, t: Double, o: [String: Double]) {
        let cx = size / 2
        let cy = size / 2
        let R = (size / 2) * 0.78
        let spin = o["spin"] ?? 1
        let pt = makeProj(yaw: t * 0.1 * spin, tilt: 0.3, cx: cx, cy: cy, scale: 1)
        let rs = radiusScale(size, o["rsPow"] ?? 0.6)

        var dots: [Dot] = []
        let ghostN = Int(o["ghostN"] ?? 150)
        for i in 0..<ghostN {
            let d = fibDir(i, ghostN)
            let (px, py, z) = pt(d.0 * R, d.1 * R, d.2 * R)
            let depth = (z / R + 1) / 2
            dots.append(Dot(x: px, y: py, z: z, r: 0.8 * rs, white: 0.78,
                            a: 0.1 + 0.22 * depth))
        }

        // The band plane, precessing (frozen when spin = 0).
        let ya = t * 0.24 * spin
        let ta = 0.55 + 0.3 * sin(t * 0.18) * spin
        let ux = cos(ya), uy = 0.0, uz = sin(ya)
        let vx = -uz * sin(ta), vy = cos(ta), vz = ux * sin(ta)
        // Plane normal n = u × v.
        let nx = uy * vz - uz * vy
        let ny = uz * vx - ux * vz
        let nz = ux * vy - uy * vx

        let baseLanes = o["lanes"] ?? 5
        let segs = Int(o["segs"] ?? 88)
        let lanes = max(1, Int((baseLanes * (o["bandMul"] ?? 1)).rounded()))
        for w in 0..<lanes {
            let laneOff = (Double(w) - Double(lanes - 1) / 2) * 0.075
            let edge = abs(Double(w) - Double(lanes - 1) / 2) / max(1, Double(lanes - 1) / 2)
            for k in 0..<segs {
                let a = (Double(k) / Double(segs)) * 2 * .pi
                // The undulation: two traveling waves along the band.
                let wob = (0.16 * sin(a * 3 - t * 1.7 + Double(w) * 0.22)
                         + 0.07 * sin(a * 5 + t * 1.1)) * (o["wobMul"] ?? 1)
                let off = laneOff + wob
                let x = ux * cos(a) + vx * sin(a) + nx * off
                let y = uy * cos(a) + vy * sin(a) + ny * off
                let z = uz * cos(a) + vz * sin(a) + nz * off
                let l = sqrt(x * x + y * y + z * z)
                let (px, py, zr) = pt(x / l * R, y / l * R, z / l * R)
                let depth = (zr / R + 1) / 2
                dots.append(Dot(
                    x: px, y: py, z: zr,
                    r: ((o["rBase"] ?? 1.1) + (o["rDepth"] ?? 1.7) * depth) * (1 - 0.25 * edge) * rs,
                    white: 0.52 - 0.44 * depth + 0.18 * edge,
                    a: 0.4 + 0.6 * depth))
            }
        }
        paint(&ctx, &dots, rMin: o["rMin"] ?? 0.3)
    }

    // MARK: globe (`lattice.ts`)

    /// `drawGlobe`, verbatim: a lat/long dot field; a scan meridian sweeps —
    /// read as a size ripple riding the near face, not a shine.
    static func drawGlobe(_ ctx: inout GraphicsContext, size: Double, t: Double, o: [String: Double]) {
        let spin = 0.5
        let cx = size / 2
        let cy = size / 2
        let radius = (size / 2) * 0.82
        let tilt = 0.4 + 0.06 * sin(t * 0.35)
        let pt = makeProj(yaw: t * spin, tilt: tilt, cx: cx, cy: cy, scale: radius)
        // The scan sweeps relative to the spin; scanMul scales that relative rate.
        let scan = t * (spin + (1.7 - spin) * (o["scanMul"] ?? 1))
        let rs = radiusScale(size, o["rsPow"] ?? 0.6)
        let dimBase = o["dimBase"] ?? 1

        var dots: [Dot] = []
        let latRings = Int(o["latRings"] ?? 17)
        let lonDensity = o["lonDensity"] ?? 44
        for li in 0...latRings {
            let lat = -Double.pi / 2 + (Double(li) / Double(latRings)) * .pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let lonCount = max(1, Int((abs(cosLat) * lonDensity).rounded()))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * .pi
                let (px, py, z) = pt(cosLat * cos(lon), sinLat, cosLat * sin(lon))
                let depth = (z + 1) / 2
                // The scan: a moving meridian read as a size ripple, not a shine.
                let d = angleDelta(lon + t * spin, scan)
                let boost = exp(-(d * d) / 0.18) * max(0, z)
                dots.append(Dot(
                    x: px, y: py, z: z,
                    r: ((o["rBase"] ?? 0.6) + (o["rDepth"] ?? 1.7) * depth
                        + (o["rBoost"] ?? 1) * boost) * rs,
                    white: (o["inkFar"] ?? 0.62) - (o["inkSpan"] ?? 0.54) * depth,
                    // dimBase < 1 fades un-scanned dots so the meridian reads clearly.
                    a: dimBase + (1 - dimBase) * min(1, boost)))
            }
        }
        paint(&ctx, &dots, rMin: o["rMin"] ?? 0.3)
    }

    // MARK: rubik (`lattice.ts`)

    /// `lattice.ts` `Move`: one quarter turn of the band lying between `lo`
    /// and `hi` along `axis` (0 = x, 1 = y, 2 = z).
    private struct Move {
        let axis: Int
        let lo: Double
        let hi: Double
        let ang: Double
    }

    /// `lattice.ts` `solveCycle`, verbatim: rapid eased moves scramble, then
    /// replay in reverse (a palindrome) so everything clicks back to solved,
    /// rests, repeats. Returns how far each move has been applied plus which
    /// one is in flight.
    private static func solveCycle(_ time: Double, _ count: Int,
                                   _ slotDur: Double, _ rest: Double)
        -> (amount: [Double], active: Int) {
        let cyc = 2 * Double(count) * slotDur + rest
        let tc = time.truncatingRemainder(dividingBy: cyc)
        var amount = [Double](repeating: 0, count: count)
        var active = -1
        if tc < 2 * Double(count) * slotDur {
            let slot = Int(tc / slotDur)
            let p = (tc - Double(slot) * slotDur) / slotDur
            let cl = min(1, p / 0.7)
            let ep = 1 - pow(1 - cl, 3)   // machine ease-out
            if slot < count {
                for i in 0..<slot { amount[i] = 1 }
                amount[slot] = ep
                active = slot
            } else {
                let u = 2 * count - 1 - slot
                for i in 0..<u { amount[i] = 1 }
                amount[u] = 1 - ep
                active = u
            }
        }
        return (amount, active)
    }

    /// `lattice.ts` `applyMoves`, verbatim: turn a point by every move whose
    /// band contains it, each scaled by that move's eased amount. Also reports
    /// whether the point rode the move currently in flight — the "hand".
    private static func applyMoves(_ pt3: (Double, Double, Double),
                                   _ moves: [Move],
                                   _ sc: (amount: [Double], active: Int))
        -> (Double, Double, Double, Bool) {
        var (x, y, z) = pt3
        var inActive = false
        for i in 0..<moves.count {
            if sc.amount[i] <= 0 { continue }
            let mv = moves[i]
            let coord = mv.axis == 0 ? x : (mv.axis == 1 ? y : z)
            if coord < mv.lo || coord >= mv.hi { continue }
            if i == sc.active { inActive = true }
            let a = mv.ang * sc.amount[i]
            let ca = cos(a), sa = sin(a)
            if mv.axis == 0 {
                let y2 = y * ca - z * sa
                z = y * sa + z * ca
                y = y2
            } else if mv.axis == 1 {
                let x2 = x * ca + z * sa
                z = -x * sa + z * ca
                x = x2
            } else {
                let x2 = x * ca - y * sa
                y = x * sa + y * ca
                x = x2
            }
        }
        return (x, y, z, inActive)
    }

    /// `lattice.ts` `makeMoves`, verbatim: the scramble is DETERMINISTIC —
    /// axis, band and direction all fall out of `hashD`, so every run turns
    /// the same sequence. Rebuilt per frame exactly as the source does.
    private static func makeMoves(_ count: Int) -> [Move] {
        var moves: [Move] = []
        for i in 0..<count {
            let axis = min(2, Int(hashD(Double(i), 2.3) * 3))
            let lo = -1.0 + 0.5 * Double(min(3, Int(hashD(Double(i), 5.9) * 4)))
            let dir: Double = hashD(Double(i), 7.7) < 0.5 ? 1 : -1
            moves.append(Move(axis: axis, lo: lo, hi: lo + 0.5, ang: dir * .pi / 2))
        }
        return moves
    }

    /// `drawRubik`, verbatim: the globe's lat/long dot field, cut into bands
    /// that twist in quarter turns — scramble, then the moves replay backwards
    /// and the sphere clicks back to solved. The band being turned inks a
    /// touch darker and swells by `rActive`: the "hand" on it.
    static func drawRubik(_ ctx: inout GraphicsContext, size: Double, t: Double, o: [String: Double]) {
        let cx = size / 2
        let cy = size / 2
        let R = (size / 2) * 0.82
        let pt = makeProj(yaw: t * 0.55, tilt: 0.35 + 0.1 * sin(t * 0.9),
                          cx: cx, cy: cy, scale: R)
        let rs = radiusScale(size, o["rsPow"] ?? 0.6)
        let moveCount = Int(o["moveCount"] ?? 14)
        let moves = makeMoves(moveCount)
        let sc = solveCycle(t, moveCount, 0.42, 1.2)

        var dots: [Dot] = []
        let latRings = Int(o["latRings"] ?? 15)
        let lonDensity = o["lonDensity"] ?? 40
        for li in 0...latRings {
            let lat = -Double.pi / 2 + (Double(li) / Double(latRings)) * .pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let lonCount = max(1, Int((abs(cosLat) * lonDensity).rounded()))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * .pi
                let (x, y, z, inActive) = applyMoves(
                    (cosLat * cos(lon), sinLat, cosLat * sin(lon)), moves, sc)
                let (px, py, zr) = pt(x, y, z)
                let depth = (zr + 1) / 2
                dots.append(Dot(
                    x: px, y: py, z: zr,
                    r: ((o["rBase"] ?? 0.6) + (o["rDepth"] ?? 1.7) * depth
                        + (inActive ? (o["rActive"] ?? 0.3) : 0)) * rs,
                    white: (o["inkFar"] ?? 0.62) - (o["inkSpan"] ?? 0.54) * depth
                        - (inActive ? 0.14 : 0)))
            }
        }
        paint(&ctx, &dots, rMin: o["rMin"] ?? 0.3)
    }

    // MARK: orbits (`orbits.ts`)

    /// `drawOrbits`, verbatim: particles on tilted orbits — no nucleus (the
    /// tuned preset runs coreless): just ghost paths and the particles doing
    /// the work.
    static func drawOrbits(_ ctx: inout GraphicsContext, size: Double, t: Double, o: [String: Double]) {
        let cx = size / 2
        let cy = size / 2
        let R = (size / 2) * 0.82
        let pt = makeProj(yaw: t * 0.12, tilt: 0.3, cx: cx, cy: cy, scale: 1)
        let rs = radiusScale(size, o["rsPow"] ?? 0.6)

        var dots: [Dot] = []
        let orbitN = Int(o["orbitN"] ?? 12)
        let ghostN = Int(o["ghostN"] ?? 40)
        let particles = Int(o["particles"] ?? 3)

        // Orbits: each a tilted circle — a ghost path + running particles.
        for orb in 0..<orbitN {
            let h1 = hashD(Double(orb), 1.7)
            let h2 = hashD(Double(orb), 5.2)
            let h3 = hashD(Double(orb), 8.9)
            let ro = R * (0.45 + 0.52 * h1)
            let th = h1 * 2 * .pi
            let phi = acos(2 * h2 - 1)
            // Orbit plane basis (u, v ⟂ normal n).
            let nx = sin(phi) * cos(th)
            let ny = cos(phi)
            let nz = sin(phi) * sin(th)
            var ux = -ny
            var uy = nx
            let uz = 0.0
            let ul = max(1e-6, sqrt(ux * ux + uy * uy))
            ux /= ul
            uy /= ul
            let vx = ny * uz - nz * uy
            let vy = nz * ux - nx * uz
            let vz = nx * uy - ny * ux
            let speed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1)

            // Ghost path.
            for k in 0..<ghostN {
                let a = (Double(k) / Double(ghostN)) * 2 * .pi
                let (px, py, z) = pt((ux * cos(a) + vx * sin(a)) * ro,
                                     (uy * cos(a) + vy * sin(a)) * ro,
                                     (uz * cos(a) + vz * sin(a)) * ro)
                let depth = (z / ro + 1) / 2
                dots.append(Dot(x: px, y: py, z: z,
                                r: (o["ghostR"] ?? 0.9) * rs, white: 0.72,
                                a: (o["ghostA"] ?? 0.5) * (0.4 + 0.6 * depth)))
            }
            // The particles doing the work.
            for m in 0..<particles {
                let a = t * speed + (Double(m) / Double(particles)) * 2 * .pi + h2 * 6
                let (px, py, z) = pt((ux * cos(a) + vx * sin(a)) * ro,
                                     (uy * cos(a) + vy * sin(a)) * ro,
                                     (uz * cos(a) + vz * sin(a)) * ro)
                let depth = (z / ro + 1) / 2
                dots.append(Dot(x: px, y: py, z: z,
                                r: ((o["partR"] ?? 1.2) + (o["partRDepth"] ?? 1.6) * depth) * rs,
                                white: 0.3 - 0.22 * depth))
            }
        }
        paint(&ctx, &dots, rMin: o["rMin"] ?? 0.3)
    }
}

/// A single status-line slot that dissolves whenever its `text` changes, so a
/// rotating mood word ("Glowing" → "Drifting") or a status change ("Searching the
/// web…" → "Reading the results…") melts from one into the next rather than
/// hard-cutting. Two things make the seam read soft instead of stiff:
///
/// 1. **True overlap.** The outgoing and incoming words are two live layers in the
///    same leading slot, animated in opposite directions at once — the slot always
///    has a word in it. (The previous implementation faded out, swapped, then
///    faded in: sequential legs with a fully-blank beat in the middle.)
/// 2. **Blur + drift.** A plain opacity crossover double-exposes the two words at
///    the midpoint — both at half strength, glyph shapes fighting. So each layer
///    also blurs slightly and drifts a few points vertically (out: up and away;
///    in: settling up from below). The blur melts the overlap into one soft mass,
///    and the shared upward direction makes it read as one word giving way to the
///    next — the "blur replace" feel — instead of two ghosts stacked.
///
/// The word also carries the wait-line shimmer (`WaitShimmer`): a slow highlight
/// sweeping the glyphs that marks "the AI is working on this right now". Both the
/// dissolve and the shimmer collapse to a plain opacity swap / static text under
/// Reduce Motion.
struct CrossfadeText: View {
    let text: String
    var font: CGFloat = 15
    var color: Color = Tokens.text2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The word currently lit; swapping it drives the transition below.
    @State private var shown: String = ""

    /// One dissolve. 0.45s reads as a calm melt, not a blink, and completes well
    /// inside the caller's rotation dwell (4s mood words, 1.2s host walk).
    private static let fade: Double = 0.45

    /// The out leg is a touch quicker than the in leg, so the incoming word owns
    /// the second half of the window instead of meeting the outgoing one at a
    /// muddy 50/50 midpoint.
    private var removal: AnyTransition {
        .modifier(
            active: DissolvePhase(opacity: 0, blur: 2.5, y: -3),
            identity: DissolvePhase(opacity: 1, blur: 0, y: 0)
        )
        .animation(.easeIn(duration: Self.fade * 0.7))
    }

    private var insertion: AnyTransition {
        .modifier(
            active: DissolvePhase(opacity: 0, blur: 2, y: 4),
            identity: DissolvePhase(opacity: 1, blur: 0, y: 0)
        )
        .animation(.easeOut(duration: Self.fade))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(shown)
                .font(.sf(font, weight: .regular))
                .foregroundStyle(color)
                .modifier(WaitShimmer(active: !reduceMotion))
                .id(shown)
                .transition(reduceMotion
                    ? .opacity
                    : .asymmetric(insertion: insertion, removal: removal))
        }
        .onAppear {
            // First appearance lights up immediately — no fade-from-blank that
            // would read as a flicker on the very first word.
            shown = text
        }
        .onChange(of: text) { _, newValue in
            guard newValue != shown else { return }
            withAnimation(.easeInOut(duration: Self.fade)) {
                shown = newValue
            }
        }
    }
}

/// One frozen pose of the dissolve — the transition interpolates between the
/// `active` (fully out / not yet in) and `identity` (at rest) poses.
private struct DissolvePhase: ViewModifier {
    var opacity: Double
    var blur: CGFloat
    var y: CGFloat
    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .blur(radius: blur)
            .offset(y: y)
    }
}

/// The slow highlight that sweeps across the wait line while the AI works — the
/// shared visual convention for "generating right now" (ChatGPT's thinking label,
/// Claude Code's spinner text, Gemini's status lines all carry one). Deliberately
/// the most restrained cut: a soft white gleam over the existing grey, clipped to
/// the glyphs themselves — no colour shift, no underlying band. One pass takes
/// 2.6s (the ChatGPT/Claude ballpark); the band starts and ends fully off the
/// text, so the loop restart is invisible. Static under Reduce Motion.
struct WaitShimmer: ViewModifier {
    var active: Bool = true

    /// Horizontal position of the gleam band, in multiples of the text width:
    /// −0.7 parks it fully off the left edge, 1.25 fully off the right.
    @State private var phase: CGFloat = -0.7

    func body(content: Content) -> some View {
        if active {
            content
                .overlay(
                    GeometryReader { geo in
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white.opacity(0.75), location: 0.5),
                                .init(color: .clear, location: 1),
                            ]),
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: max(geo.size.width * 0.45, 36))
                        .offset(x: geo.size.width * phase)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                )
                .onAppear {
                    phase = -0.7
                    withAnimation(.linear(duration: 2.6).repeatForever(autoreverses: false)) {
                        phase = 1.25
                    }
                }
        } else {
            content
        }
    }
}

/// The quiet elapsed-time suffix at the end of the wait line — proof that a long
/// agent round is alive, not hung. Appears only once the wait has crossed
/// `threshold` (quick answers never see a timer), then ticks once a second in a
/// smaller, fainter cut than the wait word so it reads as a footnote, not a
/// stopwatch. The ChatGPT / Claude Code elapsed-time convention, reduced to its
/// minimum.
struct WaitElapsedSuffix: View {
    /// When the round started thinking; nil hides the suffix entirely.
    let since: Date?
    var font: CGFloat = 15

    /// How long the wait must run before the timer surfaces.
    private static let threshold: TimeInterval = 6

    var body: some View {
        if let since {
            TimelineView(.periodic(from: since, by: 1)) { context in
                let s = Int(context.date.timeIntervalSince(since))
                if s >= Int(Self.threshold) {
                    Text("\(s)s")
                        .font(.sf(font - 2))
                        .monospacedDigit()
                        .foregroundStyle(Tokens.text4)
                        .transition(.opacity)
                }
            }
        }
    }
}

/// The whole life of an assistant turn — the pre-stream wait, the answer
/// streaming in, and the settled answer — in ONE view, so nothing structural
/// swaps underneath the answer when the stream ends.
///
/// Why one view: the answer used to render through `StreamingMarkdown` while
/// streaming and then get replaced by a plain `MarkdownBlocks` once settled.
/// That swap re-built the whole subtree from a new identity, and the sub-pixel
/// difference between the two layouts hard-cut the answer ~2pt up-left at
/// completion (the "突然跳掉位移"). Here the answer is ALWAYS the same
/// `MarkdownBlocks` — streaming just keeps feeding it more `text` and it reflows
/// in place; settling only flips `textSelection` on the unchanged tree, which
/// causes no rebuild and no jump.
///
/// The wait state (mood word / tool-activity line) rides as an `.overlay`, never
/// a layout sibling: it fades out as the first real text lands and fades back in
/// between agent rounds, but because it's an overlay it has zero footprint on the
/// answer's own layout — so it can never push the answer around. The overlay also
/// keeps a layer mounted across every fade, so there's no frame where the slot is
/// momentarily empty (the "空白帧" between questions).
struct AssistantTurnView: View {
    let text: String
    /// Still in flight. Gates the wait overlay and holds the source badge back
    /// until the answer settles (so it doesn't jump as rounds add sources).
    var streaming: Bool = false
    /// The live tool-activity line ("Searching the web…") when a tool is running,
    /// else nil — takes the wait slot over the mood word while present.
    var activity: String? = nil
    /// The thinking orb's semantic mode for the wait line — rides the same
    /// harness signal as `activity` (see `NotchModel.thinkingOrbState`), so the
    /// orb and the words always agree. Defaults to the calm thinking ribbon.
    var orbState: OrbState = .composing
    /// The present-progressive mood word for the pre-stream wait (e.g. "Gazing…").
    var thinkingWord: String = ""
    /// When this round started thinking — drives the quiet elapsed-time suffix on
    /// the wait line (only surfaces past its threshold; see `WaitElapsedSuffix`).
    var thinkingSince: Date? = nil
    var sources: [WebSource] = []
    @Binding var hoveredSourceID: UUID?
    @Binding var sourceCloseWork: DispatchWorkItem?
    var baseFont: CGFloat = 15
    var color: Color = Tokens.text1
    /// This turn is an agent run's report (reopened agent session). Its footer drops
    /// the "Copy as plain text" action — an agent report is copied as Markdown only.
    var isAgent: Bool = false
    /// When this agent report's run finished — the reopened record's own timestamp.
    /// Non-nil only on a settled agent report turn; renders as a quiet completion
    /// stamp at the end of the footer. `nil` (no stamp) for ordinary chat answers.
    var completedAt: Date? = nil
    var onInAppCopy: (() -> Void)? = nil
    /// Re-run this answer's question for a fresh take. Non-nil only on the LAST
    /// assistant turn — regenerating a mid-thread answer would orphan everything
    /// after it, so earlier turns never offer it.
    var onRegenerate: (() -> Void)? = nil
    /// The models offered by the regenerate button's right-click menu (XII-135) —
    /// each with whether it's the one currently in effect (greyed as "current").
    /// Empty ⇒ no menu (just the plain left-click regenerate).
    var regenerateModels: [(model: String, isCurrent: Bool)] = []
    /// Regenerate this answer with a specific model, once (XII-135).
    var onRegenerateWith: ((String) -> Void)? = nil
    /// The model this answer was regenerated with, when it wasn't the default
    /// (XII-135) — shown as a small caption so the answer says which model made it.
    var regenModel: String? = nil
    /// The concrete model the provider actually ran, echoed back in the stream —
    /// the real reply behind the `openrouter/free` auto-router. When present it
    /// takes precedence over `regenModel` in the footer caption, shown as a bare
    /// model name (vendor prefix and `:free` suffix stripped).
    var answerModel: String? = nil
    /// A clarifying question the model posed via the `ask_user` tool, still
    /// waiting on the user — renders as an option card under the (possibly still
    /// empty) answer. Non-nil only while this turn streams.
    var pendingQuestion: NotchModel.PendingUserQuestion? = nil
    /// The user tapped an option on the question card: (question id, option text).
    var onChooseOption: ((UUID, String) -> Void)? = nil

    /// One opacity beat, shared by the wait-overlay fade so the handoff reads as
    /// part of the same calm rhythm rather than a separate flourish.
    private static let fade: Double = 0.18

    /// The footer's "which model made this" caption. Prefers the concrete model
    /// the provider actually ran (`answerModel`, shown as a bare name), and falls
    /// back to the regenerate-with pick (`regenModel`, shown verbatim — it's the
    /// user's own choice). `nil` when neither is set, so a plain default answer
    /// carries no caption.
    static func footerModelCaption(answerModel: String?, regenModel: String?) -> String? {
        if let answerModel, !answerModel.isEmpty { return bareModelName(answerModel) }
        return regenModel
    }

    /// A model id reduced to its bare name for display: drop the vendor prefix
    /// (everything up to and including the last `/`) and the `:free` suffix.
    /// `openai/gpt-oss-20b:free` → `gpt-oss-20b`, `openrouter/free` → `free`.
    static func bareModelName(_ id: String) -> String {
        var s = id
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        if s.hasSuffix(":free") { s = String(s.dropLast(":free".count)) }
        return s.isEmpty ? id : s
    }

    /// True while the cursor is anywhere over this turn (answer text or footer).
    /// Drives the footer's island-hover: the action icons rest nearly invisible
    /// and surface together as one toolbar when the cursor enters the answer,
    /// instead of each icon lighting up on its own.
    @State private var turnHovered = false

    /// While the "Reading the results…" cue is up, the page titles are walked one
    /// at a time on a timer rather than snapping to the latest. A search round
    /// hands back all its sources at once, so without a paced walk the line would
    /// jump straight to the last title and every page before it would flash past
    /// unread. `readingIndex` is which source is currently shown; the timer below
    /// advances it, holding each title for `readingDwell` before the next.
    @State private var readingIndex = 0

    /// The rotation clock. A Combine timer publisher (not a hand-rolled `Timer` +
    /// `RunLoop.add`): `.onReceive` runs its closure in the *current* view context,
    /// so bumping `readingIndex` re-renders correctly. The earlier hand-rolled
    /// `Timer` captured a stale `self`, so its `readingIndex += 1` wrote to an
    /// orphaned `@State` box that never drove a re-render — the line looked frozen
    /// on the first host. `.autoconnect()` starts it on subscribe; we gate the tick
    /// on `isReading` so it only advances while the read cue is actually up.
    private let readingClock = Timer.publish(every: Self.readingDwell, on: .main, in: .common)
        .autoconnect()

    /// How long each host stays on the line before rotating to the next. Kept
    /// unhurried on purpose: each address should sit long enough to actually read,
    /// not flick past. The trade-off is that the post-search "reading" window is
    /// short (the model often starts answering within a beat, which clears the cue),
    /// so a long dwell means only the first host or two are seen before the answer
    /// takes over — but a readable pace matters more than walking the whole list.
    private static let readingDwell: TimeInterval = 1.2

    /// True exactly while the post-search read cue is on screen — the window in
    /// which page titles should rotate. Drives both `waitLine` and the timer.
    private var isReading: Bool {
        streaming && activity == L("agent.activity.composing") && !sources.isEmpty
    }

    /// Whether the answer currently has visible text. Trimmed, not a bare
    /// `!text.isEmpty`: GLM/Kimi open an agent turn with a lone `"\n"` content
    /// chunk *before* requesting a tool, so a raw emptiness check flips true on
    /// that newline and would hide the wait while the real answer is still a
    /// tool-round away. Treating whitespace-only as empty keeps the wait lit until
    /// genuine answer text lands. Re-evaluated live (not latched) so the wait
    /// comes back whenever the answer is momentarily empty again between rounds.
    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Show the wait overlay while streaming with no visible answer yet. The wait
    /// yields the INSTANT real text lands — no grace period: the line renders on
    /// top of the answer (it's an overlay), so any hold past the first tokens
    /// double-exposes the two texts (the old `readingHold` kept a host name over
    /// the streaming answer for up to a dwell). A host mid-glance just dissolves
    /// into the answer on the shared fade. Suppressed while an `ask_user`
    /// question card is up: the card IS the wait state then, and a "Waiting for
    /// your choice…" line above it would just say it twice.
    private var showWait: Bool { streaming && !hasText && pendingQuestion == nil }

    /// The mid-answer activity row. Once real text lands, `showWait` is off for
    /// good — but a tool can still be running under that text (the model spoke a
    /// preface, then searched), and hiding every cue there is what made a turn
    /// read as stalled mid-search. Whenever a live activity exists past the first
    /// text, it gets its OWN row under the growing answer instead of the overlay.
    /// Gated on `activity` (not `waitLine`) so the mood-word fallback never rides
    /// along — a plain streaming answer keeps its clean, indicator-free look.
    /// Suppressed under an `ask_user` card exactly like `showWait` (the card is
    /// the wait state then).
    private var showActivityRow: Bool {
        streaming && hasText && activity != nil && pendingQuestion == nil
    }

    /// The distinct hosts to walk through, in first-seen order. `sources` is the
    /// URL-deduped list accumulated across *all* search rounds, so a later round
    /// that pulls a different page of a site already shown (a fresh URL, same host)
    /// would otherwise make the line read out that host a second time. Collapsing
    /// to distinct hosts here means each site is walked once no matter how many of
    /// its pages land across rounds — the line only ever advances to a genuinely
    /// new address. If every result is the same host, this is just that one host
    /// (nothing to switch to), which is the intended "unless they're all the same"
    /// fallback.
    private var readingHosts: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in sources where seen.insert(s.host).inserted { out.append(s.host) }
        return out
    }

    /// The single string the wait line shows, so the slot is always ONE line that
    /// crossfades in place — never a label stacked over a sub-line. While the
    /// post-search "Reading the results…" cue is up and we have a source, the line
    /// *becomes* the page being read right now ("Reading tmtpost.com" — the page's
    /// host, not its title or snippet) rather than the generic cue — naming the
    /// address it's reading, in the same slot. Otherwise it's the live activity
    /// line, or the mood word. nil = nothing to show.
    private var waitLine: String? {
        if isReading, !readingHosts.isEmpty {
            // Walk the DISTINCT hosts. The clock bumps `readingIndex` unbounded;
            // the modulo maps it onto the live distinct-host list (read fresh every
            // render, so hosts from a newer round are included), wrapping back to
            // the first once it has walked them all.
            return L("agent.activity.readingPage", readingHosts[readingIndex % readingHosts.count])
        }
        if let activity { return activity }
        return thinkingWord.isEmpty ? nil : thinkingWord
    }

    /// The one wait row — orb, crossfading line, elapsed suffix — shared by the
    /// pre-text overlay and the mid-answer activity row, so the two states render
    /// identically and hand off without a visual seam.
    private func waitRow(_ line: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ThinkingOrb(state: orbState)
                .centeredOnTextGlyphs(fontSize: baseFont)
            // Word and timer sit on ONE shared baseline. Centering them (the
            // HStack default) doesn't align text of two different sizes: the
            // smaller suffix's baseline lands ~0.5pt above the word's — a whole
            // retina pixel of visible float right beside it. The orb rides the
            // same baseline, optically centred on the glyphs.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CrossfadeText(text: line, font: baseFont, color: Tokens.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // The elapsed suffix sits OUTSIDE the dissolving word (a sibling,
                // fixed size) so the ticking seconds never ride the word-change
                // transition, and a long activity line truncates while the timer
                // stays visible.
                WaitElapsedSuffix(since: thinkingSince, font: baseFont)
                    .fixedSize()
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading,
               spacing: pendingQuestion != nil && !hasText ? 0 : 6) {
            // The answer — the SAME view whether streaming or settled, so the
            // stream→settle edge never rebuilds it. While streaming it reflows in
            // place as `text` grows; once settled it's identical but selectable.
            // Selection stays ENABLED the whole time — including while streaming —
            // on purpose. Toggling `.textSelection` at stream-end would swap between
            // its two distinct modifier types (`Enabled`/`Disabled…`), changing the
            // view's identity and re-introducing exactly the rebuild-jump this unified
            // view exists to kill. A constant `.enabled` keeps one identity throughout,
            // so the answer just reflows in place and never jumps. (The earlier reason
            // to disable mid-stream — the tail-follow `scrollTo` collapsing a drag —
            // only bites in the long, clipped/scrolling layout; the jump-free guarantee
            // matters more, and most answers are short and never scroll.)
            MarkdownBlocks(source: text, baseFont: baseFont, color: color,
                           onInAppCopy: onInAppCopy, streamingTail: streaming)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                // Reserve a line's worth of height while the answer is still empty
                // so the wait overlay has somewhere to sit and the bubble doesn't
                // pop from zero-height to one-line when the first token lands.
                .frame(minHeight: showWait ? baseFont * 1.6 : 0, alignment: .leading)
                // A choice card replaces the pre-answer wait completely. The empty
                // Markdown renderer otherwise keeps an intrinsic line box even
                // though its source is empty, leaving a conspicuous blank band
                // between the user bubble and the card.
                .frame(height: pendingQuestion != nil && !hasText ? 0 : nil,
                       alignment: .topLeading)
                .clipped()
                // The pre-stream wait: mood word, or the tool-activity line while a
                // tool runs. An overlay (not a sibling) so it never shifts the
                // answer; both layers stay mounted and cross-fade on their own
                // opacity, so the slot is never blank between rounds.
                .overlay(alignment: .topLeading) {
                    // ONE line, crossfading in place: mood word → "Searching…" →
                    // the page title it's reading → next page. Never two stacked
                    // layers — `waitLine` folds all of those into a single string
                    // so the slot just dissolves from one to the next.
                    Group {
                        if let waitLine {
                            waitRow(waitLine)
                        }
                    }
                    .opacity(showWait ? 1 : 0)
                    .allowsHitTesting(false)
                }

            // The mid-answer activity row (see `showActivityRow`): the same wait
            // row, but as a SIBLING under the growing text — an overlay would sit
            // on top of the answer. It appears only while a tool is actually
            // running past the first text ("Searching the web…" under a spoken
            // preface), and dissolves when the tool clears and the answer resumes.
            if showActivityRow, let waitLine {
                waitRow(waitLine)
                    // Clear the paragraph's OWN leading. Body text runs at
                    // `lineSpacing(baseFont * 0.45)` ≈ 7pt between its lines, so
                    // at the stack's bare 6pt this row sat tighter than the prose
                    // it follows and read as one more line of that paragraph
                    // rather than a separate status row. 12pt puts clear air
                    // between the spoken preface and the tool cue under it.
                    .padding(.top, 6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // The `ask_user` question card: the model has paused this answer to ask
            // the user a multiple-choice question and is suspended until they pick
            // (or the wait times out). Only while streaming — a settled turn can't
            // be waiting on anyone.
            if streaming, let pendingQuestion {
                UserQuestionCard(question: pendingQuestion) { option in
                    onChooseOption?(pendingQuestion.id, option)
                }
                .padding(.top, hasText ? 2 : 0)
                .transition(.opacity)
            }

            // Settled footer: the source badge (when web-grounded, XII-118) plus a
            // quiet toolbar of answer actions — copy · regenerate · continue in
            // ChatGPT/Claude — in one row under the answer. Info on the left,
            // actions in escalating order (take it → redo it → leave with it).
            // Only once settled — a mid-stream badge would jump as rounds add
            // sources, and copying/regenerating half an answer isn't useful. The
            // action icons share `turnHovered` so they surface together (see
            // `AnswerFooterButton`).
            if !streaming && (hasText || !sources.isEmpty) {
                // Optically align the row's left edge with the answer text above
                // it. When a bare icon leads, its 11pt glyph sits centered in a
                // 22pt hit-frame, so it rests ~5pt inset from x=0 — the row reads
                // as indented past the text. Pull the row back by that inset so
                // the first glyph lands on the text's left edge. A leading source
                // badge is a bounded pill whose capsule is already flush at x=0,
                // so it needs no shift.
                let leadInset: CGFloat = sources.isEmpty ? -5 : 0
                // The same story vertically, and it's why this row crowded the
                // answer exactly when it was web-grounded: a bare icon's 11pt
                // glyph is centered in a 22pt hit-frame, so an icon-led row
                // already carries ~5pt of air above the glyph, while a leading
                // source badge is a flush capsule that carries none. The gap read
                // ~13pt without sources and a cramped 8pt with them. Pay the badge
                // case that difference so the footer sits the same distance under
                // the answer either way.
                let leadTop: CGFloat = sources.isEmpty ? 2 : 7
                HStack(spacing: 2) {
                    if !sources.isEmpty {
                        SourceBadge(sources: sources,
                                    hoveredID: $hoveredSourceID,
                                    pendingClose: $sourceCloseWork)
                            .padding(.trailing, 6)
                    }
                    if hasText {
                        // Copy the answer verbatim — markdown syntax intact
                        // (headings, `**bold**`, lists, code fences). The paired
                        // plain-text button below strips that formatting.
                        AnswerFooterButton(icon: "doc.on.doc",
                                           help: shortcutHelp("result.copyMarkdown",
                                                              action: .copyAnswer),
                                           rowHovered: turnHovered,
                                           confirms: true) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                text.trimmingCharacters(in: .whitespacesAndNewlines),
                                forType: .string
                            )
                            onInAppCopy?()
                        }
                        // Copy with every markdown mark removed — plain prose for
                        // pasting into fields that don't render markdown. Skipped on
                        // an agent report (the detail page copies as Markdown only).
                        if !isAgent {
                            AnswerFooterButton(icon: "text.alignleft",
                                               help: L("result.copyPlainText"),
                                               rowHovered: turnHovered,
                                               confirms: true) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    MarkdownParser.plainText(text)
                                        .trimmingCharacters(in: .whitespacesAndNewlines),
                                    forType: .string
                                )
                                onInAppCopy?()
                            }
                        }
                    }
                    if let onRegenerate {
                        AnswerFooterButton(icon: "arrow.clockwise",
                                           help: shortcutHelp(
                                               regenerateModels.isEmpty
                                                   ? "result.regenerate"
                                                   : "result.regenerate.menu",
                                               action: .regenerate),
                                           rowHovered: turnHovered) {
                            onRegenerate()
                        }
                        // Right-click → pick a model for a one-shot regenerate
                        // (XII-135). Left-click stays "regenerate with the same
                        // model". The current model is shown greyed + disabled.
                        .contextMenu {
                            if !regenerateModels.isEmpty, let onRegenerateWith {
                                Text(L("result.regenerate.with"))
                                ForEach(regenerateModels, id: \.model) { option in
                                    Button {
                                        onRegenerateWith(option.model)
                                    } label: {
                                        if option.isCurrent {
                                            Text(L("result.regenerate.current", option.model))
                                        } else {
                                            Text(option.model)
                                        }
                                    }
                                    .disabled(option.isCurrent)
                                }
                            }
                        }
                    }
                    // The model that produced this answer — an ⓘ glyph whose
                    // tooltip *is* the model name, so hovering it just shows the
                    // name (no click, no popover, no inline unfurl). Prefer the
                    // concrete model the provider actually ran (the real reply
                    // behind `openrouter/free`), shown as a bare name; fall back
                    // to the regenerate-with pick (XII-135) when none was reported.
                    if let caption = Self.footerModelCaption(answerModel: answerModel,
                                                             regenModel: regenModel) {
                        AnswerFooterButton(icon: "info.circle",
                                           help: caption,
                                           rowHovered: turnHovered) {}
                    }
                    // When the run finished — the settled agent report's completion
                    // stamp. A quiet caption (not a button): the wall-clock time on
                    // its own today, month·day·time once older, in the same
                    // hover-reveal rhythm as the action icons. Its tooltip carries
                    // the full date. Only on agent reports (`completedAt` is nil for
                    // chat answers).
                    if let completedAt {
                        Text(completionStamp(completedAt))
                            .font(.sf(11, weight: .medium).monospacedDigit())
                            .foregroundStyle(Tokens.text4)
                            .padding(.leading, 5)
                            .opacity(turnHovered ? 0.9 : 0.4)
                            .animation(.easeOut(duration: 0.18), value: turnHovered)
                            .notchTooltip(L("result.completedAt",
                                            completedAt.formatted(date: .abbreviated,
                                                                  time: .shortened)))
                    }
                }
                .padding(.leading, leadInset)
                .padding(.top, leadTop)
            }
        }
        .onHover { turnHovered = $0 }
        .animation(.easeInOut(duration: Self.fade), value: showWait)
        .animation(.easeInOut(duration: Self.fade), value: showActivityRow)
        .animation(.easeInOut(duration: 0.12), value: activity != nil)
        // The question card fades in when the model asks and out when the pick (or
        // timeout) releases the round — same beat as the wait overlay's fade.
        .animation(.easeInOut(duration: Self.fade), value: pendingQuestion)
        // A clock tick means the host on the line has had its full dwell — advance
        // to the next one so each host occupies exactly one dwell while the cue
        // is up. (No hold once the answer starts: the wait yields immediately.)
        .onReceive(readingClock) { _ in
            guard isReading else { return }
            readingIndex += 1
        }
        // Each time the read cue opens, restart the walk from the first host so a
        // new search begins fresh rather than continuing a stale offset.
        .onChange(of: isReading) { _, reading in
            if reading { readingIndex = 0 }
        }
    }
}

/// The `ask_user` question card: the model paused mid-answer to ask one
/// multiple-choice question, and the round is suspended until the user picks (or
/// walks away and the wait times out).
///
/// It wears the same clothes as the `ClearHistoryConfirm` dialog — Liquid Glass
/// slab, bold question over muted detail, full-width capsule actions — but stays
/// **embedded in the answer's flow** rather than floating over a scrim: this is a
/// step in the reply, not a modal demanding the whole island.
struct UserQuestionCard: View {
    let question: NotchModel.PendingUserQuestion
    /// Called with the option's text when the user picks it.
    var choose: (String) -> Void

    /// `manage_app_settings` hands its confirmation over as one string: the
    /// question on the first line, then one `Label → value` summary per changed
    /// setting. Kept as a single blob it ran as one paragraph that overflowed the
    /// card and collided with the buttons; split, the question can carry a title's
    /// weight and each change gets its own row.
    private var lines: [String] {
        question.question
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var title: String { lines.first ?? question.question }
    private var changes: [String] { Array(lines.dropFirst()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.sf(13.5, weight: .semibold))
                    .foregroundStyle(Tokens.text2)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(changes, id: \.self) { changeRow($0) }
            }

            if question.inlineOptions {
                // Cancel / Confirm as a pair of glass capsules, the dialog's own
                // two-button row. The tool always puts the affirmative last, so
                // the tail option carries the material and the rest stay quiet —
                // two peer capsules would read as two equal choices.
                HStack(spacing: 10) {
                    ForEach(Array(question.options.enumerated()), id: \.element) { index, option in
                        ConfirmDialogButton(
                            title: option,
                            kind: index == question.options.count - 1 ? .neutral : .quiet
                        ) { choose(option) }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    optionRows()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        // A confirmation is a small decision, so it stops well short of the
        // column — but it still needs a *definite* ceiling, or its detail lines
        // propose a width wider than the panel and get clipped. Longer clarifying
        // questions keep the full-column layout so their option labels can wrap.
        .frame(maxWidth: question.inlineOptions ? 340 : .infinity,
               alignment: .leading)
        .background { glass }
    }

    /// One pending change, already written as a whole sentence upstream ("Dock
    /// icon will change to Hidden") — so it renders as plain body text, the thing
    /// actually being asked about, and carries the card's largest type.
    private func changeRow(_ line: String) -> some View {
        Text(line)
            .font(.sf(15))
            .foregroundStyle(Tokens.text1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The card's material — the confirmation dialog's Liquid Glass recipe
    /// (`nativeGlass` refraction, top-down sheen, specular rim), run airy: it
    /// floats on the panel's own glass rather than over arbitrary windows, so it
    /// needs no occluding veil and no drop shadow to sit apart.
    private var glass: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return ZStack {
            shape.fill(.clear)
                .nativeGlass(in: shape, tintOpacity: 0.14)
                .overlay(shape.fill(Color.white.opacity(0.04)))
            shape
                .fill(LinearGradient(colors: [.white.opacity(0.10), .clear],
                                     startPoint: .top, endPoint: .center))
                .blendMode(.plusLighter)
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75)
        }
        .compositingGroup()
    }

    /// Options are de-duplicated by the tool before they get here, so the string
    /// itself is a safe `ForEach` id.
    @ViewBuilder
    private func optionRows() -> some View {
        ForEach(question.options, id: \.self) { option in
            UserQuestionOptionRow(title: option) { choose(option) }
        }
    }
}

/// One tappable option row on the question card. Full-width and left-aligned so
/// the whole line is the target; brightens on hover like the other quiet controls.
private struct UserQuestionOptionRow: View {
    var title: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.sf(12.5))
                .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.13 : 0.07))
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

/// Renders inline `**bold**` markdown into styled text — the same lightweight
/// transform the prototype applied to AI answers.
struct InlineMarkdownText: View {
    let raw: String
    /// Colour for surviving links. Defaults to primary ink so links read in the
    /// same white family as the body text — on our dark glass the stock system
    /// blue is both illegible and off-palette, so links are styled as ink +
    /// underline (the underline, not a colour shift, is what marks them tappable).
    var linkColor: Color = Tokens.text1
    init(_ raw: String, linkColor: Color = Tokens.text1) {
        self.raw = raw
        self.linkColor = linkColor
    }

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        // Inline `$…$` / `\(…\)` math converts to Unicode glyphs BEFORE the
        // markdown parse — by the time SwiftUI reads the line, `x^2` is already
        // `x²` and any character surviving conversion that markdown would
        // reinterpret (`*`, `_`, …) is escaped.
        let source = MathTypeset.inline(raw)
        // SwiftUI's built-in inline-markdown parsing covers **bold**, *italic*,
        // and `code` — exactly the subset we need.
        if var parsed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            // The markdown parser also turns `[label](url)` into a tappable link.
            // The answer text comes from an LLM endpoint we don't fully trust, so a
            // rogue/compromised backend could embed `[ok](file:///…)` or a custom
            // scheme that fires on click. Allow only http/https — real web links the
            // user can open — and strip every other `.link` run (keep its styling,
            // drop the clickable URL), so file:// and custom schemes stay inert.
            // Surviving links get our ink colour + an underline instead of the
            // stock blue, which is illegible on the dark glass.
            for run in parsed.runs where run.link != nil {
                let scheme = run.link?.scheme?.lowercased()
                if scheme != "http" && scheme != "https" {
                    parsed[run.range].link = nil
                } else {
                    parsed[run.range].foregroundColor = linkColor
                    parsed[run.range].underlineStyle = .single
                }
            }
            return parsed
        }
        return AttributedString(source)
    }
}

// MARK: - Block-level markdown

/// One parsed block of an answer. We intentionally support only the block kinds
/// an in-notch assistant actually produces — headings, lists (nested via
/// `indent`, including GFM task items), block quotes, fenced code blocks,
/// GFM tables, and horizontal rules — plus plain paragraphs. Everything else
/// falls through to a paragraph, so unknown syntax still reads cleanly rather
/// than breaking. Inline `**bold**` / `*italic*` / `code` is handled per-line by
/// `InlineMarkdownText`; code blocks render verbatim without inline parsing.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    /// `indent` is the nesting depth (0 = top level) of a list item, derived
    /// from the line's leading whitespace.
    case bullet(text: String, indent: Int)
    case ordered(number: Int, text: String, indent: Int)
    /// A GFM task item — `- [ ] text` / `- [x] text`.
    case task(done: Bool, text: String, indent: Int)
    /// A `>` block quote. Contiguous quoted lines collapse into one block;
    /// `text` keeps their newlines so the quote reads as a single island.
    case quote(text: String)
    case paragraph(text: String)
    case code(language: String?, text: String)
    /// A GitHub-flavoured pipe table. `header` is the first row; `rows` are the
    /// body rows below the `|---|` separator. Every row is normalised to
    /// `header.count` cells (short rows padded, long rows truncated) so the grid
    /// is always rectangular. Cell text keeps its inline markdown.
    case table(header: [String], rows: [[String]])
    /// A display-math island — `$$…$$` / `\[…\]` opening its own line, or a
    /// ```math fence. `text` is the raw LaTeX between the delimiters; rendering
    /// converts it to Unicode via `MathTypeset` (a glyph translation, not a
    /// math engine, in keeping with the no-library rule).
    case math(text: String)
    /// A `![alt](url)` reference lifted out of its line — rendered as an inline
    /// image island, downloaded on first sight (http/https only; see
    /// `AnswerMediaLoader`).
    case image(alt: String, url: String)
    /// A reference to a `.pdf` URL — either image syntax or a `[label](….pdf)`
    /// link standing alone on its line. Rendered as a first-page preview island
    /// via PDFKit; tapping opens the document.
    case pdf(title: String, url: String)
    case divider
}

/// A line-based markdown parser. Deliberately tiny: it walks the answer line by
/// line and classifies each non-empty line as a heading (`#`…`######`), an
/// unordered item (`-`, `*`, `+`, with `- [ ]`/`- [x]` task variants), an
/// ordered item (`1.`, `2)`), a block-quote line (`>`), a horizontal rule
/// (`---` / `***` / `___`), or a paragraph. List items keep a nesting depth
/// derived from their leading whitespace; contiguous `>` lines merge into one
/// quote block. Fenced code blocks (``` `…` ```) span multiple lines and capture
/// their content verbatim — including blank lines — until the closing fence.
/// No nesting beyond that, in keeping with the app's minimalism (no markdown
/// library).
enum MarkdownParser {
    /// Memoized `parse`. A streaming answer's growing source is rendered by
    /// several sibling copies of the same turn at once — the visible thread,
    /// NotchBody's hidden height probe, the progressive-blur overlay copies —
    /// and SwiftUI can re-evaluate each body more than once per update; every
    /// evaluation used to re-run the full line-by-line parse of the whole
    /// accumulated answer. One cache entry per distinct source collapses all
    /// of that to a single parse. NSCache is thread-safe and purges under
    /// memory pressure; the count limit bounds the streaming case, where each
    /// ~33ms flush is a new (one chunk longer) key that's never seen again.
    private static let parseCache: NSCache<NSString, ParsedBlocks> = {
        let cache = NSCache<NSString, ParsedBlocks>()
        cache.countLimit = 32
        return cache
    }()

    /// NSCache values must be objects; a one-field box over the parsed blocks.
    private final class ParsedBlocks {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    static func parseCached(_ source: String) -> [MarkdownBlock] {
        let key = source as NSString
        if let hit = parseCache.object(forKey: key) { return hit.blocks }
        let blocks = parse(source)
        parseCache.setObject(ParsedBlocks(blocks), forKey: key)
        return blocks
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = source.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let rawLine = lines[i]
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Fenced code block — capture everything (including blank lines)
            // until the matching closing fence. The opening fence may carry a
            // language hint (e.g. ```swift); we keep it but don't syntax-color.
            if let lang = codeFence(line) {
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let inner = lines[i]
                    if codeFence(inner.trimmingCharacters(in: .whitespaces)) != nil { break }
                    body.append(inner)
                    i += 1
                }
                // A ```math fence (GitHub's display-math fence) is math, not
                // code — everything else stays a verbatim code island (```latex
                // included: that's usually code the user wants to copy).
                if lang.lowercased() == "math" {
                    blocks.append(.math(text: body.joined(separator: "\n")))
                } else {
                    blocks.append(.code(language: lang.isEmpty ? nil : lang, text: body.joined(separator: "\n")))
                }
                i += 1
                continue
            }

            if line.isEmpty {
                i += 1
                continue
            }

            // Display math — `$$ … $$` or `\[ … \]` opening its own line. The
            // block may close on the same line or span several; an unclosed one
            // swallows the rest (mirroring code fences), so a streaming answer
            // renders its partial formula instead of raw TeX.
            if line.hasPrefix("$$") || line.hasPrefix("\\[") {
                let close = line.hasPrefix("$$") ? "$$" : "\\]"
                let rest = String(line.dropFirst(2))
                if let r = rest.range(of: close) {
                    blocks.append(.math(text: String(rest[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)))
                    // Trailing prose after the closer keeps its own paragraph.
                    let after = String(rest[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !after.isEmpty { blocks.append(.paragraph(text: after)) }
                    i += 1
                    continue
                }
                var body: [String] = rest.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [rest]
                i += 1
                while i < lines.count {
                    let inner = lines[i]
                    if let r = inner.range(of: close) {
                        let before = String(inner[..<r.lowerBound])
                        if !before.trimmingCharacters(in: .whitespaces).isEmpty { body.append(before) }
                        i += 1
                        break
                    }
                    body.append(inner)
                    i += 1
                }
                blocks.append(.math(text: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                continue
            }

            // Block quote — merge every contiguous `>` line into one block so a
            // multi-line quote renders as a single island (a bare `>` spacer
            // becomes a blank line inside it). Checked before table detection so
            // a quoted `|` line can't be mistaken for a table header.
            if line.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let inner = lines[i].trimmingCharacters(in: .whitespaces)
                    guard inner.hasPrefix(">") else { break }
                    quoteLines.append(quoteContent(inner))
                    i += 1
                }
                while quoteLines.first?.isEmpty == true { quoteLines.removeFirst() }
                while quoteLines.last?.isEmpty == true { quoteLines.removeLast() }
                if !quoteLines.isEmpty {
                    blocks.append(.quote(text: quoteLines.joined(separator: "\n")))
                }
                continue
            }

            // GFM pipe table: the current line plus a following `|---|:--:|`
            // separator. Detect it before the divider/heading checks so a header
            // row isn't mistaken for a paragraph and the `---` separator isn't
            // mistaken for a horizontal rule. Consumes the header, the separator,
            // and every contiguous body row.
            if i + 1 < lines.count,
               isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)),
               line.contains("|") {
                let header = tableCells(line)
                var rows: [[String]] = []
                i += 2   // skip the header (handled) and the separator line
                while i < lines.count {
                    let bodyRaw = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !bodyRaw.isEmpty, bodyRaw.contains("|") else { break }
                    // Normalise each body row to the header's column count.
                    var cells = tableCells(bodyRaw)
                    if cells.count < header.count {
                        cells.append(contentsOf: Array(repeating: "", count: header.count - cells.count))
                    } else if cells.count > header.count {
                        cells = Array(cells.prefix(header.count))
                    }
                    rows.append(cells)
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if isDivider(line) {
                blocks.append(.divider)
            } else if let (level, text) = heading(line) {
                blocks.append(.heading(level: level, text: text))
            } else if let text = bullet(line) {
                let indent = listIndent(of: rawLine)
                if let (done, rest) = taskItem(text) {
                    blocks.append(.task(done: done, text: rest, indent: indent))
                } else {
                    blocks.append(.bullet(text: text, indent: indent))
                }
            } else if let (number, text) = ordered(line) {
                blocks.append(.ordered(number: number, text: text, indent: listIndent(of: rawLine)))
            } else {
                blocks.append(contentsOf: paragraphOrMedia(line))
            }
            i += 1
        }
        return blocks
    }

    /// `` ``` `` or `` ```swift `` → optional language tag (empty string if bare).
    /// Returns `nil` for any line that isn't a fence opener/closer, so the caller
    /// can use it for both opening and closing detection.
    private static func codeFence(_ line: String) -> String? {
        guard line.hasPrefix("```") else { return nil }
        let after = line.dropFirst(3)
        // Disallow extra backticks on the same line — that's an inline `code`
        // span gone weird, not a fence.
        if after.contains("`") { return nil }
        return String(after).trimmingCharacters(in: .whitespaces)
    }

    /// `---` / `***` / `___` (3+ of the same char, optional internal spaces).
    /// Conservative: requires the line to be made up of only that marker (after
    /// stripping spaces) so a real `***bold***` paragraph isn't swallowed.
    private static func isDivider(_ line: String) -> Bool {
        let stripped = line.filter { $0 != " " }
        guard stripped.count >= 3, let first = stripped.first else { return false }
        guard first == "-" || first == "*" || first == "_" else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    /// `# Title` … `###### Title` → (level, text). Requires a space after the
    /// hashes so a bare `#tag` stays a paragraph.
    private static func heading(_ line: String) -> (Int, String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
        let text = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    /// `- item` / `* item` / `+ item` → text. The marker must be followed by a
    /// space, so a stray `*emphasis*` at line start isn't mistaken for a bullet.
    private static func bullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// `[ ] buy milk` / `[x] done thing` (the text of an already-matched bullet)
    /// → (done, rest). The space after the bracket is required, so `[link]`-style
    /// text at the start of a bullet isn't mistaken for a checkbox.
    private static func taskItem(_ text: String) -> (Bool, String)? {
        for (marker, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(marker) {
            let rest = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return (done, rest) }
        }
        return nil
    }

    /// Nesting depth of a list line from its leading whitespace (tab = 4 cols).
    /// Both common LLM conventions land on the same depth: 2 *or* 4 columns →
    /// level 1, 6 or 8 → level 2, … Capped so runaway indentation can't push
    /// text off the narrow panel.
    private static func listIndent(of rawLine: String) -> Int {
        var width = 0
        for ch in rawLine {
            if ch == " " { width += 1 }
            else if ch == "\t" { width += 4 }
            else { break }
        }
        return width < 2 ? 0 : min(1 + (width - 2) / 4, 4)
    }

    /// Strip the `>` marker(s) — plus the conventional space after each — from a
    /// quoted line. Nested `> >` quotes flatten into the same block.
    private static func quoteContent(_ line: String) -> String {
        var content = Substring(line)
        while content.hasPrefix(">") {
            content = content.dropFirst()
            if content.hasPrefix(" ") { content = content.dropFirst() }
        }
        return String(content)
    }

    /// A GFM table separator row: `|---|---|`, `| :--- | ---: |`, `--- | ---`,
    /// etc. Every cell must be made of only `-`, `:`, and spaces, with at least
    /// one `-`, and there must be at least one cell. Used to confirm the line
    /// *above* is a table header before we commit to table parsing.
    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("-") else { return false }
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" } && cell.contains("-")
        }
    }

    /// Split a pipe-table row into trimmed cell strings. Tolerates an optional
    /// leading/trailing `|` (so both `| a | b |` and `a | b` work) and ignores a
    /// pipe escaped as `\|` inside a cell.
    private static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }

        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in trimmed {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: - Media references

    /// `![alt](url)` — the alt text, then the URL (an optional `"title"` after
    /// the URL is tolerated and dropped).
    private static let imageRef = #/!\[([^\]]*)\]\(\s*(\S+?)(?:\s+"[^"]*")?\s*\)/#
    /// A `[label](url)` link standing alone on its line.
    private static let soloLink = #/^\[([^\]]+)\]\(\s*(\S+?)(?:\s+"[^"]*")?\s*\)$/#

    /// Turn one paragraph-shaped line into blocks, lifting media out of it:
    /// every `![alt](url)` becomes its own `.image` (or `.pdf` when the URL is
    /// a PDF) below the line's remaining text, and a bare `[label](….pdf)` link
    /// alone on the line becomes a `.pdf` preview. Anything else stays one
    /// paragraph. Lifting is per-line only — images inside lists/quotes/tables
    /// keep their textual form.
    private static func paragraphOrMedia(_ line: String) -> [MarkdownBlock] {
        // The cheap gate: no `](` means no reference of either kind.
        guard line.contains("](") else { return [.paragraph(text: line)] }

        if let m = line.wholeMatch(of: soloLink), isPDFURL(String(m.2)) {
            return [.pdf(title: String(m.1), url: String(m.2))]
        }

        var text = line
        var media: [MarkdownBlock] = []
        while let m = text.firstMatch(of: imageRef) {
            let alt = String(m.1), url = String(m.2)
            media.append(isPDFURL(url) ? .pdf(title: alt, url: url) : .image(alt: alt, url: url))
            text.removeSubrange(m.range)
        }
        guard !media.isEmpty else { return [.paragraph(text: line)] }
        let rest = text.trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? media : [.paragraph(text: rest)] + media
    }

    /// Does the URL's path (query/fragment ignored) end in `.pdf`?
    private static func isPDFURL(_ urlString: String) -> Bool {
        let path = urlString.split(separator: "?", maxSplits: 1)[0]
            .split(separator: "#", maxSplits: 1)[0]
        return path.lowercased().hasSuffix(".pdf")
    }

    /// `1. item` / `2) item` → (number, text).
    private static func ordered(_ line: String) -> (Int, String)? {
        var digits = ""
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isNumber {
            digits.append(line[idx])
            idx = line.index(after: idx)
        }
        guard !digits.isEmpty, let number = Int(digits), idx < line.endIndex else { return nil }
        let sep = line[idx]
        guard sep == "." || sep == ")" else { return nil }
        let afterSep = line.index(after: idx)
        guard afterSep < line.endIndex, line[afterSep] == " " else { return nil }
        let text = String(line[afterSep...]).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (number, text)
    }

    // MARK: - Plain-text flattening

    /// Flatten an answer's markdown into clean plain text — the "copy without
    /// formatting" path. Reuses `parse` so every block kind we render is handled,
    /// then drops the structural syntax: heading hashes, list markers, block-quote
    /// `>`, code fences, table pipes. Inline `**bold**` / `*italic*` / `` `code` ``
    /// / `[label](url)` is stripped per line via `stripInline`. Blocks are joined
    /// with blank lines so paragraphs still read as paragraphs.
    static func plainText(_ source: String) -> String {
        var out: [String] = []
        for block in parse(source) {
            switch block {
            case let .heading(_, text):
                out.append(stripInline(text))
            case let .bullet(text, indent):
                out.append(indentPad(indent) + "• " + stripInline(text))
            case let .ordered(number, text, indent):
                out.append(indentPad(indent) + "\(number). " + stripInline(text))
            case let .task(done, text, indent):
                out.append(indentPad(indent) + (done ? "[x] " : "[ ] ") + stripInline(text))
            case let .quote(text):
                // Keep the quote's own line breaks; strip inline markup per line.
                let lines = text.components(separatedBy: "\n").map { stripInline($0) }
                out.append(lines.joined(separator: "\n"))
            case let .paragraph(text):
                out.append(stripInline(text))
            case let .code(_, text):
                // Code is verbatim — no inline stripping (a `*` in code is a `*`).
                out.append(text)
            case let .table(header, rows):
                // Render as tab-separated rows so columns survive a paste into a
                // plain-text field or spreadsheet.
                var lines = [header.map { stripInline($0) }.joined(separator: "\t")]
                for row in rows {
                    lines.append(row.map { stripInline($0) }.joined(separator: "\t"))
                }
                out.append(lines.joined(separator: "\n"))
            case let .math(text):
                // Copy the formula the way it renders — Unicode, not raw TeX.
                out.append(MathTypeset.unicode(text))
            case let .image(alt, url):
                out.append(alt.isEmpty ? url : "\(alt): \(url)")
            case let .pdf(title, url):
                out.append(title.isEmpty ? url : "\(title): \(url)")
            case .divider:
                // A rule carries no text; drop it (the blank-line join keeps the
                // visual break between the blocks it separated).
                break
            }
        }
        return out.joined(separator: "\n\n")
    }

    private static func indentPad(_ indent: Int) -> String {
        String(repeating: "  ", count: max(0, indent))
    }

    /// Strip inline markdown (`**bold**`, `*italic*`, `` `code` ``, `[label](url)`)
    /// from one line, leaving the visible text. Uses the same SwiftUI markdown
    /// parser as `InlineMarkdownText` so the two stay consistent; falls back to the
    /// raw line if parsing fails.
    private static func stripInline(_ line: String) -> String {
        // Inline math first, same as the visible renderer, so a copied line
        // reads `x²`, not `$x^2$`.
        let source = MathTypeset.inline(line)
        if let parsed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return String(parsed.characters)
        }
        return source
    }
}

// MARK: - LaTeX math → Unicode

/// Turns the LaTeX math LLM answers embed — inline `$…$` / `\(…\)` spans and
/// display `$$…$$` / `\[…\]` blocks — into plain Unicode: `x^2` → `x²`,
/// `\alpha` → `α`, `\frac{a}{b}` → `a/b`, `\sqrt{2}` → `√2`. A glyph
/// translation, not a math engine: no library, no webview, in keeping with the
/// app's minimalism. The long tail of TeX (matrices, over-braces, …) degrades
/// to readable text — an unknown `\command` renders as its bare name — instead
/// of showing raw markup.
enum MathTypeset {

    // MARK: Inline span scanning

    /// Replace every inline math span in one line of markdown with its Unicode
    /// rendering, leaving the rest untouched. `\(…\)` and `$$…$$` are
    /// unambiguous and always convert; `$…$` needs a math "tell" (see `isMath`)
    /// so money — "$5 and $10" — is never eaten. The replacement has its
    /// markdown specials escaped, so a `*` that survives conversion can't turn
    /// the rest of the line italic when SwiftUI parses it.
    static func inline(_ line: String) -> String {
        guard line.contains("$") || line.contains("\\(") else { return line }
        let chars = Array(line)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                if chars[i + 1] == "(", let close = find(chars, "\\)", from: i + 2) {
                    out += escaped(unicode(String(chars[(i + 2)..<close])))
                    i = close + 2
                    continue
                }
                // Any other escape (incl. `\$`) passes through untouched, so
                // the dollar scan below can't take an escaped `$` as a delimiter.
                out.append(c)
                out.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "$" {
                if i + 1 < chars.count, chars[i + 1] == "$",
                   let close = find(chars, "$$", from: i + 2) {
                    out += escaped(unicode(String(chars[(i + 2)..<close])))
                    i = close + 2
                    continue
                }
                if let close = chars[(i + 1)...].firstIndex(of: "$"),
                   isMath(String(chars[(i + 1)..<close])) {
                    out += escaped(unicode(String(chars[(i + 1)..<close])))
                    i = close + 1
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// The `$…$` ambiguity gate: convert only when the span reads as math, not
    /// money or prose. A command / script / equals sign is a sure tell; failing
    /// that, a single space-free non-digit-led token (`$x$`, `$a+b$`) passes,
    /// while "5 and $10" (edge whitespace) and "100-" (digit-led, the span
    /// between two prices) stay literal text.
    private static func isMath(_ body: String) -> Bool {
        guard let first = body.first, let last = body.last,
              !first.isWhitespace, !last.isWhitespace, !body.contains("\n")
        else { return false }
        if body.contains(where: { "\\^_=".contains($0) }) { return true }
        return !body.contains(" ") && !first.isNumber
    }

    /// Index of the first occurrence of a two-character delimiter at/after
    /// `from`, or nil.
    private static func find(_ chars: [Character], _ delim: String, from: Int) -> Int? {
        let d = Array(delim)
        var i = from
        while i + d.count <= chars.count {
            if chars[i] == d[0], chars[i + 1] == d[1] { return i }
            i += 1
        }
        return nil
    }

    /// Escape the markdown-special characters a converted span may still carry
    /// so the math text survives `AttributedString(markdown:)` verbatim.
    private static func escaped(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\*_`[]".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    // MARK: Expression conversion

    /// Convert one LaTeX math expression to a Unicode string.
    static func unicode(_ latex: String) -> String {
        let chars = Array(latex)
        var i = 0
        return squeeze(convert(chars, &i, until: nil))
    }

    /// The recursive walk. `until` is the group-closing brace this level stops
    /// (and consumes) at — nil at top level. Nested `{…}` groups recurse, so an
    /// inner brace never terminates an outer level early.
    private static func convert(_ chars: [Character], _ i: inout Int, until stop: Character?) -> String {
        var out = ""
        while i < chars.count {
            let c = chars[i]
            if let stop, c == stop {
                i += 1
                return out
            }
            switch c {
            case "\\":
                i += 1
                out += command(chars, &i)
            case "^":
                i += 1
                out += scripted(argument(chars, &i), with: Self.superscripts, marker: "^")
            case "_":
                i += 1
                out += scripted(argument(chars, &i), with: Self.subscripts, marker: "_")
            case "{":
                i += 1
                out += convert(chars, &i, until: "}")
            case "}":
                i += 1   // unbalanced closer — drop it
            case "&", "~":
                out += " "   // alignment tab / non-breaking tie → plain space
                i += 1
            default:
                out.append(c)
                i += 1
            }
        }
        return out
    }

    /// One `\…` command, cursor just past the backslash. Structural commands
    /// (fractions, roots, wrappers) recurse; everything else looks up the
    /// symbol table and — the graceful-degradation rule — falls back to its
    /// own name.
    private static func command(_ chars: [Character], _ i: inout Int) -> String {
        guard i < chars.count else { return "" }
        let first = chars[i]
        guard first.isLetter else {
            // Single-character escape: `\\` is a TeX row break; the thin-space
            // family collapses to a space or nothing; anything else (`\{`,
            // `\%`, `\$`, …) means the literal character.
            i += 1
            switch first {
            case "\\": return "\n"
            case ",", ";", ":", " ": return " "
            case "!": return ""
            default: return String(first)
            }
        }
        var name = ""
        while i < chars.count, chars[i].isLetter {
            name.append(chars[i])
            i += 1
        }
        if i < chars.count, chars[i] == "*" { i += 1 }   // \operatorname* etc.

        switch name {
        case "frac", "dfrac", "tfrac", "cfrac":
            return fraction(argument(chars, &i), argument(chars, &i))
        case "sqrt":
            var degree: String?
            if i < chars.count, chars[i] == "[" {
                i += 1
                var d = ""
                while i < chars.count, chars[i] != "]" {
                    d.append(chars[i])
                    i += 1
                }
                if i < chars.count { i += 1 }
                degree = unicode(d)
            }
            let body = argument(chars, &i)
            let prefix = degree.map { scripted($0, with: superscripts, marker: "") } ?? ""
            return body.count <= 2 ? prefix + "√" + body : prefix + "√(" + body + ")"
        case "text", "textrm", "textit", "textbf", "textsf", "texttt", "textnormal",
             "mathrm", "mathit", "mathbf", "mathsf", "mathtt", "mathfrak",
             "operatorname", "mbox", "hbox", "boldsymbol", "bm", "pmb":
            return argument(chars, &i)
        case "mathbb":
            return remapped(argument(chars, &i), via: blackboard)
        case "mathcal", "mathscr":
            return remapped(argument(chars, &i), via: calligraphic)
        case "vec", "hat", "widehat", "bar", "overline", "underline",
             "tilde", "widetilde", "dot", "ddot":
            // Single-character accents ride as combining marks (`\vec{v}` →
            // v⃗); longer bodies drop the decoration and keep the text.
            let body = argument(chars, &i)
            if body.count == 1, let mark = combining[name] { return body + mark }
            return body
        case "left", "right":
            // Delimiter sizing — the delimiter itself follows and the main
            // loop keeps it; `\left.` / `\right.` is an invisible wall.
            if i < chars.count, chars[i] == "." { i += 1 }
            return ""
        case "big", "Big", "bigg", "Bigg", "bigl", "bigr", "bigm",
             "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr",
             "displaystyle", "textstyle", "scriptstyle", "limits", "nolimits":
            return ""
        case "phantom", "vphantom", "hphantom":
            _ = argument(chars, &i)
            return ""
        case "hspace", "vspace":
            _ = argument(chars, &i)
            return " "
        case "begin", "end":
            _ = argument(chars, &i)   // the environment name — rows/tabs are
            return ""                 // handled by the global `\\` / `&` rules
        case "pmod":
            return " (mod " + argument(chars, &i) + ")"
        case "not":
            let rel = argument(chars, &i)
            return negated[rel] ?? ("¬" + rel)
        default:
            return symbols[name] ?? name
        }
    }

    /// One command argument: a `{…}` group, a nested `\command`, or a single
    /// character. Leading spaces are TeX-insignificant and skipped.
    private static func argument(_ chars: [Character], _ i: inout Int) -> String {
        while i < chars.count, chars[i] == " " { i += 1 }
        guard i < chars.count else { return "" }
        let c = chars[i]
        if c == "{" {
            i += 1
            return convert(chars, &i, until: "}")
        }
        if c == "\\" {
            i += 1
            return command(chars, &i)
        }
        i += 1
        return String(c)
    }

    /// Render a super/subscript: whole-span Unicode when every character has a
    /// script form (`x^2` → `x²`, `a_n` → `aₙ`), else fall back to the marker
    /// (`x^(n+1)`), parenthesised only when the script is more than one glyph.
    private static func scripted(_ body: String, with map: [Character: Character], marker: String) -> String {
        if body.isEmpty { return "" }
        if body == "∘" { return "°" }   // `x^\circ` is the degree sign
        let mapped = body.compactMap { map[$0] }
        if mapped.count == body.count { return String(mapped) }
        return body.count == 1 ? marker + body : marker + "(" + body + ")"
    }

    /// `\frac{a}{b}` → `a/b`, parenthesising a side only when it carries an
    /// operator or space (`\frac{a+b}{2}` → `(a+b)/2`, `\frac{dy}{dx}` →
    /// `dy/dx`). The handful of fractions with real glyphs use them.
    private static func fraction(_ num: String, _ den: String) -> String {
        if let glyph = vulgar[num + "/" + den] { return glyph }
        return side(num) + "/" + side(den)
    }

    private static func side(_ s: String) -> String {
        s.contains(where: { "+-−±∓=<>≤≥*·×÷/, ".contains($0) }) ? "(" + s + ")" : s
    }

    private static func remapped(_ s: String, via table: [Character: Character]) -> String {
        String(s.map { table[$0] ?? $0 })
    }

    /// Collapse runs of spaces (TeX treats them as one) and trim each line's
    /// edges, leaving row breaks from `\\` intact.
    private static func squeeze(_ s: String) -> String {
        s.components(separatedBy: "\n").map { line in
            var out = ""
            var lastWasSpace = false
            for ch in line.trimmingCharacters(in: .whitespaces) {
                if ch == " " {
                    if !lastWasSpace { out.append(ch) }
                    lastWasSpace = true
                } else {
                    out.append(ch)
                    lastWasSpace = false
                }
            }
            return out
        }.joined(separator: "\n")
    }

    // MARK: Glyph tables

    /// `\command` → symbol, kept to what LLM answers actually emit.
    private static let symbols: [String: String] = [
        // Greek
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
        "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ",
        "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "φ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // Operators & relations
        "times": "×", "div": "÷", "pm": "±", "mp": "∓", "cdot": "·",
        "ast": "∗", "star": "⋆", "circ": "∘", "bullet": "•",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠",
        "ne": "≠", "equiv": "≡", "approx": "≈", "sim": "∼",
        "simeq": "≃", "cong": "≅", "propto": "∝", "ll": "≪", "gg": "≫",
        "prec": "≺", "succ": "≻", "asymp": "≍", "doteq": "≐",
        // Calculus & big operators
        "infty": "∞", "partial": "∂", "nabla": "∇", "sum": "∑",
        "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬",
        "iiint": "∭", "oint": "∮", "prime": "′",
        // Sets & logic
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂",
        "supset": "⊃", "subseteq": "⊆", "supseteq": "⊇",
        "subsetneq": "⊊", "supsetneq": "⊋", "cup": "∪", "cap": "∩",
        "setminus": "∖", "emptyset": "∅", "varnothing": "∅",
        "forall": "∀", "exists": "∃", "nexists": "∄", "neg": "¬",
        "lnot": "¬", "land": "∧", "wedge": "∧", "lor": "∨", "vee": "∨",
        "oplus": "⊕", "ominus": "⊖", "otimes": "⊗", "oslash": "⊘",
        "odot": "⊙", "models": "⊨", "vdash": "⊢", "dashv": "⊣",
        "top": "⊤", "bot": "⊥", "therefore": "∴", "because": "∵",
        "implies": "⟹", "iff": "⟺",
        // Arrows
        "to": "→", "rightarrow": "→", "gets": "←", "leftarrow": "←",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "leftrightarrow": "↔",
        "Leftrightarrow": "⇔", "mapsto": "↦", "uparrow": "↑",
        "downarrow": "↓", "longrightarrow": "⟶", "longleftarrow": "⟵",
        "hookrightarrow": "↪", "rightharpoonup": "⇀",
        // Delimiters & dots
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋",
        "lceil": "⌈", "rceil": "⌉", "ldots": "…", "cdots": "⋯",
        "vdots": "⋮", "ddots": "⋱", "dots": "…", "dotsc": "…", "dotsb": "⋯",
        // Misc
        "angle": "∠", "perp": "⊥", "parallel": "∥", "nparallel": "∦",
        "mid": "∣", "nmid": "∤", "degree": "°", "hbar": "ℏ", "ell": "ℓ",
        "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "wp": "℘", "dagger": "†",
        "ddagger": "‡", "checkmark": "✓", "triangle": "△", "square": "□",
        "Box": "□", "diamond": "◇", "colon": ":", "quad": " ",
        "qquad": " ", "space": " ",
    ]

    /// `\not` + relation → the precomposed negated glyph where one exists.
    private static let negated: [String: String] = [
        "=": "≠", "∈": "∉", "<": "≮", ">": "≯", "≤": "≰", "≥": "≱",
        "≡": "≢", "∼": "≁", "≈": "≉", "⊂": "⊄", "⊃": "⊅", "⊆": "⊈",
        "⊇": "⊉", "∣": "∤", "∥": "∦",
    ]

    /// Single-character accent decorations → combining marks.
    private static let combining: [String: String] = [
        "vec": "\u{20D7}", "hat": "\u{0302}", "widehat": "\u{0302}",
        "bar": "\u{0304}", "overline": "\u{0305}", "underline": "\u{0332}",
        "tilde": "\u{0303}", "widetilde": "\u{0303}",
        "dot": "\u{0307}", "ddot": "\u{0308}",
    ]

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵",
        "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻",
        "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ",
        "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ",
        "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ",
        "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ",
        "z": "ᶻ", "T": "ᵀ",
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅",
        "6": "₆", "7": "₇", "8": "₈", "9": "₉", "+": "₊", "-": "₋",
        "−": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ",
        "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ",
        "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
    ]

    private static let blackboard: [Character: Character] = [
        "A": "𝔸", "B": "𝔹", "C": "ℂ", "D": "𝔻", "E": "𝔼", "F": "𝔽",
        "G": "𝔾", "H": "ℍ", "I": "𝕀", "J": "𝕁", "K": "𝕂", "L": "𝕃",
        "M": "𝕄", "N": "ℕ", "O": "𝕆", "P": "ℙ", "Q": "ℚ", "R": "ℝ",
        "S": "𝕊", "T": "𝕋", "U": "𝕌", "V": "𝕍", "W": "𝕎", "X": "𝕏",
        "Y": "𝕐", "Z": "ℤ", "1": "𝟙",
    ]

    private static let calligraphic: [Character: Character] = [
        "A": "𝒜", "B": "ℬ", "C": "𝒞", "D": "𝒟", "E": "ℰ", "F": "ℱ",
        "G": "𝒢", "H": "ℋ", "I": "ℐ", "J": "𝒥", "K": "𝒦", "L": "ℒ",
        "M": "ℳ", "N": "𝒩", "O": "𝒪", "P": "𝒫", "Q": "𝒬", "R": "ℛ",
        "S": "𝒮", "T": "𝒯", "U": "𝒰", "V": "𝒱", "W": "𝒲", "X": "𝒳",
        "Y": "𝒴", "Z": "𝒵",
    ]

    private static let vulgar: [String: String] = [
        "1/2": "½", "1/3": "⅓", "2/3": "⅔", "1/4": "¼", "3/4": "¾",
        "1/5": "⅕", "2/5": "⅖", "3/5": "⅗", "4/5": "⅘", "1/6": "⅙",
        "5/6": "⅚", "1/8": "⅛", "3/8": "⅜", "5/8": "⅝", "7/8": "⅞",
    ]
}

/// Renders a parsed answer as stacked block-level markdown — headings and lists
/// laid out vertically, each line's inline markdown handled by
/// `InlineMarkdownText`. Caller controls the base font/colour; this only adds the
/// per-block structure (sizing for headings, the bullet/number gutter for lists).
struct MarkdownBlocks: View {
    let source: String
    var baseFont: CGFloat = 15
    var color: Color = Tokens.text1
    /// Called when a code block's copy button writes its text to the pasteboard,
    /// so the owner (NotchBody) can re-baseline the clipboard and stop that in-app
    /// copy from poisoning the next Ask's clipboard-context injection. `nil` in the
    /// (non-result) contexts that don't care.
    var onInAppCopy: (() -> Void)? = nil
    /// While the answer streams, the LAST block is the growing tail: its
    /// newly-revealed glyphs fade in (macOS 15+, see `StreamTailRenderer`).
    /// False everywhere else — settled answers and non-answer contexts render
    /// plain.
    var streamingTail: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // `parseCached`, not `parse`: this computed property re-runs on every body
    // evaluation, which during streaming happens for every ~33ms flush times
    // every mounted copy of the turn (visible thread, height probe, blur
    // overlays). The cache makes all but the first evaluation of a given
    // source free.
    private var blocks: [MarkdownBlock] { MarkdownParser.parseCached(source) }

    var body: some View {
        let parsed = blocks
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parsed.enumerated()), id: \.offset) { i, block in
                // Per-block styling lives in `MarkdownBlockRow`, shared with the
                // streaming renderer (`StreamingMarkdown`) so a settled answer and a
                // live one are laid out identically — they differ only in the tail
                // fade/selection wrapping, never in how a block kind looks.
                // `.equatable()` — see the row's `Equatable` conformance for why.
                MarkdownBlockRow(block: block, baseFont: baseFont, color: color,
                                 onInAppCopy: onInAppCopy,
                                 fadeTail: streamingTail && !reduceMotion && i == parsed.count - 1)
                    .equatable()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The streaming face of `MarkdownBlocks`: same layout, but the live tail
/// **fades in** as chunks land instead of snapping. The result is the "逐字出现"
/// typewriter feel the answer is supposed to have — text appears to dissolve into
/// place rather than blink on in jumps.
///
/// Why only the tail: re-parsing the whole `source` every chunk and re-fading all
/// of it would make the entire (already-read) answer flicker on each token. So we
/// split the parsed blocks into the *settled head* (every block but the last) and
/// the *growing tail* (the final block). The head renders through the plain
/// `MarkdownBlocks` with no animation; the tail is keyed on its own text so that
/// each time it grows, SwiftUI re-runs an 80ms opacity ramp from `tailFloor` → 1
/// over just that block — the freshly-arrived words shimmer in, the rest holds.
///
/// Settles to nothing once streaming ends: the caller swaps back to a plain
/// `MarkdownBlocks` for the finished, fully-selectable answer (see `turnView`),
/// so none of this fade machinery touches a settled turn.
struct StreamingMarkdown: View {
    let source: String
    var baseFont: CGFloat = 15
    var color: Color = Tokens.text1
    var onInAppCopy: (() -> Void)? = nil

    private var blocks: [MarkdownBlock] { MarkdownParser.parseCached(source) }

    var body: some View {
        let parsed = blocks
        // The tail is the block currently growing; the head is everything already
        // settled above it. An empty source yields no blocks — the caller shows
        // ThinkingDots in that case, so we just render nothing here.
        let headCount = max(0, parsed.count - 1)
        return VStack(alignment: .leading, spacing: 8) {
            if headCount > 0 {
                // Settled blocks: render verbatim through the plain renderer so they
                // never re-fade as later chunks arrive. Rebuilt from the same
                // `source` prefix; cheap, and keeps inline/code handling identical.
                ForEach(Array(parsed.prefix(headCount).enumerated()), id: \.offset) { _, block in
                    MarkdownBlockRow(block: block, baseFont: baseFont, color: color, onInAppCopy: onInAppCopy)
                        .equatable()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let tail = parsed.last {
                MarkdownBlockRow(block: tail, baseFont: baseFont, color: color, onInAppCopy: onInAppCopy)
                    .equatable()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(TailFadeIn(token: tailToken(for: tail)))
            }
        }
    }

    /// A change-key for the tail's fade: re-ramps opacity whenever the tail's text
    /// grows. We key on the rendered character count (per block kind) rather than
    /// the whole `source` so head edits never re-trigger the tail's fade.
    private func tailToken(for block: MarkdownBlock) -> Int {
        switch block {
        case .heading(_, let t), .bullet(let t, _), .ordered(_, let t, _),
             .task(_, let t, _), .quote(let t), .paragraph(let t), .math(let t):
            return t.count
        case .code(_, let t):
            return t.count
        case .table(let header, let rows):
            // Grow as cells stream in: keys on total rendered character count so a
            // table still building its last row re-fades only as it changes.
            return header.reduce(0) { $0 + $1.count }
                + rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
        case .image(_, let url), .pdf(_, let url):
            return url.count
        case .divider:
            return -1
        }
    }
}

/// No-op. The tail block used to dim to a `floor` opacity and ease back to 1 on
/// every chunk (a typewriter-style fade), but with a long single-paragraph answer
/// the *whole* tail is one block, so the entire body below the first line dimmed
/// and re-lit on each token — read as the text going pale mid-answer and only
/// settling once the stream ended. Tail text now renders at full opacity like the
/// settled head; streaming just reflows line by line, no fade. Kept as a modifier
/// (rather than deleting the call site) so `StreamingMarkdown`'s head/tail split is
/// untouched and the fade can be reintroduced here if it's ever made
/// per-new-character instead of per-block.
private struct TailFadeIn: ViewModifier {
    let token: Int
    func body(content: Content) -> some View { content }
}

// MARK: - Streaming tail glyph fade (macOS 15+)

/// Which glyphs of the streaming tail are *fresh* — revealed within the last fade
/// window — recorded as character-count milestones with timestamps. This is the
/// per-NEW-CHARACTER fade the old `TailFadeIn` couldn't do: that one re-faded the
/// whole tail block per chunk (a long paragraph visibly dimmed and re-lit on every
/// token — why it was neutered to a no-op). Here only glyphs *beyond* the length
/// already seen animate; everything already read never re-fades.
struct GlyphBirths: Equatable {
    struct Milestone: Equatable {
        var count: Int
        var at: TimeInterval
    }

    /// Glyph indices below this are settled — they always draw at full ink.
    var settled = 0
    /// Recent growth milestones, oldest first: a glyph at index i (settled ≤ i <
    /// count) was born at the first milestone whose `count` exceeds i.
    var fresh: [Milestone] = []

    mutating func note(length: Int, at now: TimeInterval) {
        // A shrink means the tail re-parsed into a different block shape (e.g. a
        // list marker completing); settle to the new length rather than replaying
        // a fade over text the reader has already seen.
        if length < (fresh.last?.count ?? settled) {
            settled = length
            fresh.removeAll()
            return
        }
        fresh.append(Milestone(count: length, at: now))
        // Milestones past the fade window draw at full ink anyway — fold them
        // into `settled` so the per-glyph lookup stays O(few) instead of growing
        // with the stream (30 ticks/s over a long answer).
        let horizon = now - 0.3
        while let first = fresh.first, first.at < horizon {
            settled = max(settled, first.count)
            fresh.removeFirst()
        }
    }

    func opacity(forGlyph index: Int, at now: TimeInterval, fade: TimeInterval) -> Double {
        if index < settled { return 1 }
        guard let birth = fresh.first(where: { index < $0.count })?.at else {
            // Laid out before its growth milestone was noted (same frame):
            // newborn. With no milestones at all, nothing is animating — full ink.
            return fresh.isEmpty ? 1 : 0
        }
        let age = now - birth
        return age >= fade ? 1 : max(0, age / fade)
    }
}

/// Draws the tail block's glyphs with recency-based opacity: glyphs the pacer
/// revealed within the last 180ms ramp from 0 → 1, everything older is plain
/// ink. Glyph order stands in for character order (true for the linear text
/// these rows hold), so no attribute plumbing through the markdown parser is
/// needed. Redraw cadence comes for free while streaming: the paced reveal
/// mutates the text ~30×/s, and each pass re-reads the clock here.
@available(macOS 15.0, *)
struct StreamTailRenderer: TextRenderer {
    var births: GlyphBirths

    /// How long one newly-revealed glyph takes to reach full ink.
    static let fade: TimeInterval = 0.18

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        let now = ProcessInfo.processInfo.systemUptime
        var index = 0
        for line in layout {
            for run in line {
                for slice in run {
                    let opacity = births.opacity(forGlyph: index, at: now, fade: Self.fade)
                    if opacity >= 1 {
                        ctx.draw(slice)
                    } else {
                        var faded = ctx
                        faded.opacity = opacity
                        faded.draw(slice)
                    }
                    index += 1
                }
            }
        }
    }
}

/// Owns the birth history for one tail block and feeds it to the renderer.
/// Mounted fresh when a block becomes the tail, so a brand-new block fades in
/// whole (it IS entirely new text) and a block that graduates to the settled
/// head simply drops the renderer — full ink, no re-fade.
@available(macOS 15.0, *)
private struct StreamTailFade: ViewModifier {
    let textLength: Int
    @State private var births = GlyphBirths()

    func body(content: Content) -> some View {
        content
            .textRenderer(StreamTailRenderer(births: births))
            .onAppear {
                births.note(length: textLength, at: ProcessInfo.processInfo.systemUptime)
            }
            .onChange(of: textLength) { _, newValue in
                births.note(length: newValue, at: ProcessInfo.processInfo.systemUptime)
            }
    }
}

/// Availability shim: the glyph fade needs macOS 15's `TextRenderer`; on the
/// 14.0 deployment floor the streaming text falls back to the paced reveal
/// alone (still smooth — just no per-glyph ramp).
struct TailFadeIfAvailable: ViewModifier {
    var active: Bool
    var length: Int
    func body(content: Content) -> some View {
        if active, #available(macOS 15.0, *) {
            content.modifier(StreamTailFade(textLength: length))
        } else {
            content
        }
    }
}

/// One block of an answer, extracted from `MarkdownBlocks.row(for:)` so both the
/// settled renderer and the streaming renderer share identical block styling. The
/// two callers differ only in animation/selection wrapping, never in how a given
/// block kind looks.
struct MarkdownBlockRow: View, Equatable {
    let block: MarkdownBlock
    var baseFont: CGFloat = 15
    var color: Color = Tokens.text1
    var onInAppCopy: (() -> Void)? = nil
    /// True only on the growing tail block of a streaming answer: its fresh
    /// glyphs fade in (macOS 15+). Must participate in `==` — when a new block
    /// appends, the previous tail's content is unchanged but this flag flips,
    /// and the row must re-evaluate to drop the fade renderer.
    var fadeTail: Bool = false

    /// The row-level diff gate (used via `.equatable()` at every call site).
    /// `onInAppCopy` is a closure, and a closure field defeats SwiftUI's
    /// synthesized memberwise diff — without this, EVERY row of an answer
    /// re-evaluated its body (re-running `InlineMarkdownText`'s AttributedString
    /// parse) on every ~33ms streaming flush, so a flush's cost grew with the
    /// length of the already-settled text above the tail. Comparing the visual
    /// inputs only is safe: the closure is the same capture for the life of the
    /// thread, so a row whose block/font/colour are unchanged renders identically.
    static func == (lhs: MarkdownBlockRow, rhs: MarkdownBlockRow) -> Bool {
        lhs.block == rhs.block && lhs.baseFont == rhs.baseFont && lhs.color == rhs.color
            && lhs.fadeTail == rhs.fadeTail
    }

    /// Only linear text rows fade; code and tables render whole (fading a code
    /// block per-glyph reads as flicker over syntax, and both were excluded by
    /// the industry implementations this follows), and a divider has no glyphs.
    private static func fadeable(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .code, .table, .divider, .image, .pdf: return false
        default: return true
        }
    }

    /// The fade's growth signal: the row's rendered-text character count. Raw
    /// block text (markdown syntax included) slightly overshoots the laid-out
    /// glyph count when inline `**`/`` ` `` markers get stripped — the error only
    /// ever makes a glyph fade a beat early, never re-fade, so it's harmless.
    private static func fadeLength(_ block: MarkdownBlock) -> Int {
        switch block {
        case .heading(_, let t), .bullet(let t, _), .ordered(_, let t, _),
             .task(_, let t, _), .quote(let t), .paragraph(let t), .math(let t):
            return t.count
        case .code, .table, .divider, .image, .pdf:
            return 0
        }
    }

    var body: some View {
        rowContent
            .modifier(TailFadeIfAvailable(
                active: fadeTail && Self.fadeable(block),
                length: Self.fadeLength(block)))
    }

    @ViewBuilder
    private var rowContent: some View {
        switch block {
        case .heading(let level, let text):
            let size = max(baseFont, baseFont + CGFloat(7 - min(level, 5)) * 1.5)
            InlineMarkdownText(text, linkColor: color)
                .font(.sf(size, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .bullet(let text, let indent):
            listRow(marker: Text(bulletGlyph(for: indent)), text: text, indent: indent)

        case .ordered(let number, let text, let indent):
            listRow(marker: Text("\(number)."), text: text, indent: indent)

        case .task(let done, let text, let indent):
            // A checked-off item dims: the checkbox already says "done", the
            // fade just keeps open items visually in front.
            listRow(
                marker: Text(Image(systemName: done ? "checkmark.square" : "square")),
                text: text,
                indent: indent,
                textOpacity: done ? 0.55 : 1
            )

        case .quote(let text):
            InlineMarkdownText(text, linkColor: color.opacity(0.8))
                .font(.sf(baseFont))
                .tracking(-0.05)
                .lineSpacing(baseFont * 0.45)
                .foregroundStyle(color.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.leading, 13)
                .overlay(alignment: .leading) {
                    // The accent bar that marks the island as quoted speech.
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color.opacity(0.25))
                        .frame(width: 3)
                }
                .padding(.vertical, 2)

        case .paragraph(let text):
            InlineMarkdownText(text, linkColor: color)
                .font(.sf(baseFont))
                .tracking(-0.05)
                .lineSpacing(baseFont * 0.6)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .code(_, let text):
            CodeBlockView(text: text, baseFont: baseFont, color: color, onInAppCopy: onInAppCopy)

        case .table(let header, let rows):
            MarkdownTableView(header: header, rows: rows, baseFont: baseFont, color: color)

        case .math(let text):
            // Display math: the Unicode rendering, centred like a typeset
            // formula, a shade larger than body so it reads as an island.
            Text(MathTypeset.unicode(text))
                .font(.sf(baseFont + 1))
                .tracking(0.1)
                .lineSpacing(baseFont * 0.5)
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 2)

        case .image(let alt, let url):
            AnswerImageView(alt: alt, urlString: url, baseFont: baseFont, color: color)

        case .pdf(let title, let url):
            AnswerPDFView(title: title, urlString: url, baseFont: baseFont, color: color)

        case .divider:
            Rectangle()
                .fill(Tokens.hairline)
                .frame(height: 0.5)
                .padding(.vertical, 4)
        }
    }

    /// A list item: a fixed-width gutter holds the marker so wrapped lines hang
    /// neatly under the text, not under the bullet. `indent` steps the whole row
    /// right for nested items; `textOpacity` lets done tasks read as settled.
    private func listRow(marker: Text, text: String, indent: Int = 0, textOpacity: Double = 1) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker
                .font(.sf(baseFont, weight: .medium).monospacedDigit())
                .foregroundStyle(color.opacity(0.7))
                .frame(minWidth: 16, alignment: .trailing)
            InlineMarkdownText(text, linkColor: color.opacity(textOpacity))
                .font(.sf(baseFont))
                .tracking(-0.05)
                .lineSpacing(baseFont * 0.5)
                .foregroundStyle(color.opacity(textOpacity))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(indent) * 16)
    }

    /// Bullet glyph by nesting depth — the standard •/◦/▪ ladder, so levels read
    /// apart even when the indent step is subtle on the narrow panel.
    private func bulletGlyph(for indent: Int) -> String {
        switch indent {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪"
        }
    }
}

/// A GFM pipe table rendered as a `Grid`: the header row reads slightly bolder
/// and dimmer (a column label), a hairline rules off the header, and body rows
/// align in shared columns so cells line up no matter how the text wraps. Each
/// cell keeps its inline markdown (`**bold**`, `code`, …) via `InlineMarkdownText`.
/// The whole island is boxed by a faint hairline so it reads as one unit on the
/// glass rather than four loose columns of text.
private struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]
    let baseFont: CGFloat
    let color: Color

    private var columnCount: Int { header.count }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    cellText(cell, weight: .semibold, opacity: 0.85)
                }
            }
            .padding(.vertical, 6)

            Divider().overlay(Tokens.hairline).gridCellColumns(max(columnCount, 1))

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        cellText(cell, weight: .regular, opacity: 1)
                    }
                }
                .padding(.vertical, 6)

                if index < rows.count - 1 {
                    Divider().overlay(Tokens.hairline.opacity(0.6))
                        .gridCellColumns(max(columnCount, 1))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Tokens.hairline, lineWidth: 0.5)
        )
    }

    private func cellText(_ raw: String, weight: Font.Weight, opacity: Double) -> some View {
        InlineMarkdownText(raw, linkColor: color.opacity(opacity))
            .font(.sf(baseFont - 1, weight: weight))
            .tracking(-0.05)
            .foregroundStyle(color.opacity(opacity))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

// MARK: - Answer media (images & PDFs)

/// Downloads and caches the media an answer references. One shared instance so
/// the several mounted copies of a turn (visible thread, height probe, blur
/// overlays) resolve a URL to ONE download: finished outcomes are cached,
/// in-flight fetches are joined. http/https only — answer text comes from an
/// LLM, so every other scheme (file://, custom) stays inert, matching the link
/// policy in `InlineMarkdownText`.
@MainActor
final class AnswerMediaLoader {
    static let shared = AnswerMediaLoader()

    /// A rendered PDF preview: page 1 plus how much more there is.
    struct PDFPreview {
        let firstPage: NSImage
        let pageCount: Int
    }

    enum Outcome {
        case image(NSImage)
        case pdf(PDFPreview)
        case failed
    }

    private enum Kind { case image, pdf }

    private var cache: [String: Outcome] = [:]
    private var order: [String] = []   // insertion order, for eviction
    private var inflight: [String: Task<Outcome, Never>] = [:]

    /// More than this is a mistake to pull down for a chat answer.
    private nonisolated static let byteCap = 30 * 1024 * 1024
    /// Decode bound — the panel shows ~700 device pixels, so a 12-megapixel
    /// photograph should cost a thumbnail's memory, not a 50 MB bitmap.
    private nonisolated static let maxPixel: CGFloat = 1600

    func image(for urlString: String) async -> Outcome {
        await outcome(for: urlString, as: .image)
    }

    func pdf(for urlString: String) async -> Outcome {
        await outcome(for: urlString, as: .pdf)
    }

    private func outcome(for urlString: String, as kind: Kind) async -> Outcome {
        if let hit = cache[urlString] { return hit }
        if let running = inflight[urlString] { return await running.value }
        let task = Task { await Self.fetch(urlString, as: kind) }
        inflight[urlString] = task
        let result = await task.value
        inflight[urlString] = nil
        cache[urlString] = result
        order.append(urlString)
        if order.count > 64 { cache.removeValue(forKey: order.removeFirst()) }
        return result
    }

    /// The off-main part: download, bound, decode. `nonisolated` so the fetch
    /// runs on the concurrency pool, not the main thread this class lives on.
    private nonisolated static func fetch(_ urlString: String, as kind: Kind) async -> Outcome {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let (data, response) = try? await URLSession.shared.data(from: url),
              data.count <= byteCap,
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return .failed }

        switch kind {
        case .image:
            guard let image = downsampled(data) else { return .failed }
            return .image(image)
        case .pdf:
            guard let doc = PDFDocument(data: data), doc.pageCount > 0,
                  let page = doc.page(at: 0)
            else { return .failed }
            let bounds = page.bounds(for: .mediaBox)
            let scale = min(2, 1200 / max(bounds.width, 1))
            let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            return .pdf(PDFPreview(firstPage: page.thumbnail(of: size, for: .mediaBox),
                                   pageCount: doc.pageCount))
        }
    }

    /// Decode via ImageIO with a pixel cap (also normalises EXIF rotation).
    private nonisolated static func downsampled(_ data: Data) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// Open a media reference in the default app — same scheme gate as the loader.
private func openAnswerMediaURL(_ urlString: String) {
    guard let url = URL(string: urlString),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else { return }
    NSWorkspace.shared.open(url)
}

/// The shape media takes while its download is in flight — a quiet island of
/// fixed height, so the panel settles in one reflow when the pixels land.
private struct MediaLoadingPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.04))
            .frame(height: 120)
            .overlay(ProgressView().controlSize(.small).tint(.white.opacity(0.4)))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Tokens.hairline, lineWidth: 0.5)
            )
    }
}

/// The degraded form of a media reference whose download failed (or whose
/// bytes weren't what the syntax claimed): a compact link-out chip, so the
/// reference is still reachable, never silently dropped.
private struct MediaLinkChip: View {
    let icon: String
    let label: String
    var baseFont: CGFloat = 15
    var color: Color = Tokens.text1
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.sf(baseFont - 3, weight: .medium))
                Text(label)
                    .font(.sf(baseFont - 1))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "arrow.up.right")
                    .font(.sf(baseFont - 5, weight: .semibold))
                    .opacity(0.6)
            }
            .foregroundStyle(color.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Tokens.hairline, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// One `![alt](url)` reference as an inline image island. Spans the answer's
/// width (left-aligned, never upscaled past its natural size); tapping opens the
/// source in the browser.
private struct AnswerImageView: View {
    let alt: String
    let urlString: String
    var baseFont: CGFloat = 15
    var color: Color = Tokens.text1

    /// Height ceiling for a tall image — enforced by capping the *width* instead
    /// of the height, so the frame keeps hugging the image (a maxHeight would
    /// pillarbox it inside a wider border).
    private static let heightCap: CGFloat = 360

    @State private var outcome: AnswerMediaLoader.Outcome?

    var body: some View {
        Group {
            switch outcome {
            case .image(let image):
                let ratio = image.size.width / max(image.size.height, 1)
                Button { openAnswerMediaURL(urlString) } label: {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(ratio, contentMode: .fit)
                        .frame(maxWidth: min(image.size.width, Self.heightCap * ratio))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Tokens.hairline, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(alt.isEmpty ? "image" : alt)
            case .pdf, .failed:
                MediaLinkChip(icon: "photo",
                              label: alt.isEmpty ? (URL(string: urlString)?.host ?? urlString) : alt,
                              baseFont: baseFont, color: color) {
                    openAnswerMediaURL(urlString)
                }
            case nil:
                MediaLoadingPlaceholder()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: urlString) {
            outcome = await AnswerMediaLoader.shared.image(for: urlString)
        }
    }
}

/// A `.pdf` reference as a document island: the first page, then a footer with
/// the document's name and page count. Tapping opens the PDF itself.
private struct AnswerPDFView: View {
    let title: String
    let urlString: String
    var baseFont: CGFloat = 15
    var color: Color = Tokens.text1

    @State private var outcome: AnswerMediaLoader.Outcome?

    var body: some View {
        Group {
            switch outcome {
            case .pdf(let preview):
                Button { openAnswerMediaURL(urlString) } label: {
                    VStack(spacing: 0) {
                        Image(nsImage: preview.firstPage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 240)
                            .frame(maxWidth: .infinity)
                        Divider().overlay(Tokens.hairline)
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.sf(baseFont - 3, weight: .medium))
                            Text(displayTitle)
                                .font(.sf(baseFont - 1, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(preview.pageCount == 1 ? "1 page" : "\(preview.pageCount) pages")
                                .font(.sf(baseFont - 2))
                                .opacity(0.55)
                            Image(systemName: "arrow.up.right")
                                .font(.sf(baseFont - 5, weight: .semibold))
                                .opacity(0.6)
                        }
                        .foregroundStyle(color.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Tokens.hairline, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(displayTitle)
            case .image, .failed:
                MediaLinkChip(icon: "doc.text", label: displayTitle,
                              baseFont: baseFont, color: color) {
                    openAnswerMediaURL(urlString)
                }
            case nil:
                MediaLoadingPlaceholder()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: urlString) {
            outcome = await AnswerMediaLoader.shared.pdf(for: urlString)
        }
    }

    private var displayTitle: String {
        if !title.isEmpty { return title }
        let name = URL(string: urlString)?.lastPathComponent ?? ""
        return name.isEmpty ? urlString : name
    }
}

/// A code island with its own ghost one-tap copy button. Split out of
/// `MarkdownBlocks.row(for:)` so it can hold the `hovering`/`copied` `@State` the
/// button needs. The button is a tap target overlaid on the island — independent of
/// scroll position and text-selection hit-testing — so it works identically while
/// the answer streams (once the closing fence parses this block into the tree) and
/// after it settles, where multi-line drag-select on the narrow panel is unreliable.
private struct CodeBlockView: View {
    let text: String
    let baseFont: CGFloat
    let color: Color
    /// Fired after the in-app pasteboard write so the owner can re-baseline the
    /// clipboard and keep this copy from being re-injected into the next Ask.
    let onInAppCopy: (() -> Void)?

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        // NOTE: the parent `MarkdownBlocks` container in NotchBody wraps the whole
        // answer in `.textSelection(.disabled)` WHILE STREAMING (so tail-follow
        // scroll can't collapse a drag) and `.enabled` once settled — so the inner
        // `.textSelection(.enabled)` here is only effective post-stream. The copy
        // button below works in BOTH states; don't remove the parent wrapper without
        // auditing this.
        Text(text)
            .font(.system(size: baseFont - 1, weight: .regular, design: .monospaced))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Tokens.hairline, lineWidth: 0.5)
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    onInAppCopy?()
                    Haptics.confirm()
                    withAnimation(.easeOut(duration: 0.15)) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation(.easeOut(duration: 0.25)) { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.sf(11, weight: .regular))
                        .foregroundStyle(copied ? Tokens.text2 : Tokens.text3)
                        // Native SF Symbols swap — the doc morphs to the check
                        // instead of hard-cutting.
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(5)
                // Ghost by default; brightens on hover; full while showing the check.
                .opacity(copied ? 1.0 : hovering ? 0.7 : 0.3)
                .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
                .animation(.easeOut(duration: 0.15), value: copied)
            }
            .onHover { hovering = $0 }
    }
}

/// One ghost icon in a settled answer's footer toolbar — copy, regenerate, and
/// continue-elsewhere all share this recipe. The copy affordance exists because
/// SwiftUI selection can't cross the per-block `Text` views the answer renders
/// through — a drag stops at every block edge, so multi-line copy needs one tap.
///
/// Island-hover in three levels: nearly invisible at rest, the whole row
/// surfaces together when the cursor enters the owning turn (`rowHovered`), and
/// the pointed-at button alone goes full — so the toolbar reads as one unit on
/// approach, not scattered dots that light up one by one. `confirms` flips the
/// icon to a checkmark for a beat after the tap, for copy-style actions whose
/// effect is otherwise invisible; regenerate skips it (the answer visibly
/// re-streaming IS the feedback).
private struct AnswerFooterButton: View {
    let icon: String
    let help: String
    /// True while the cursor is anywhere over the owning turn — brightens the
    /// whole footer as one unit (owned by `AssistantTurnView`).
    let rowHovered: Bool
    var confirms: Bool = false
    let action: () -> Void

    @State private var hovering = false
    @State private var confirmed = false

    var body: some View {
        Button {
            action()
            guard confirms else { return }
            Haptics.confirm()
            withAnimation(.easeOut(duration: 0.15)) { confirmed = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.easeOut(duration: 0.25)) { confirmed = false }
            }
        } label: {
            Image(systemName: confirmed ? "checkmark" : icon)
                .font(.sf(11, weight: .regular))
                .foregroundStyle(confirmed ? Tokens.text2 : Tokens.text3)
                // Native SF Symbols swap — icon morphs to the check, no hard cut.
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Rest → row hover → direct hover/checkmark: 0.25 → 0.7 → 1.
        .opacity(confirmed || hovering ? 1.0 : rowHovered ? 0.7 : 0.25)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        .animation(.easeOut(duration: 0.18), value: rowHovered)
        .animation(.easeOut(duration: 0.15), value: confirmed)
        .notchTooltip(help)
    }
}

/// The floating source popup's request, published up the view tree by the hovered
/// badge: where it is (`anchor`, the pill's frame) and what to show (`sources`).
/// `nil` when no badge is hovered. An ancestor *outside* the conversation
/// ScrollView reads this and draws the panel, so the popup escapes the scroll's
/// clip that was chopping it off (XII-118).
struct SourcePopoverRequest: Equatable {
    let id: UUID
    let anchor: Anchor<CGRect>
    let sources: [WebSource]
    static func == (a: SourcePopoverRequest, b: SourcePopoverRequest) -> Bool { a.id == b.id }
}

struct SourcePopoverKey: PreferenceKey {
    static let defaultValue: SourcePopoverRequest? = nil
    static func reduce(value: inout SourcePopoverRequest?, nextValue: () -> SourcePopoverRequest?) {
        // Last writer wins — at most one badge is hovered at a time.
        if let next = nextValue() { value = next }
    }
}

/// A source badge shown under a search-grounded answer (XII-118). Rests as a
/// compact pill — just the first source's site name plus "+N" for the rest, e.g.
/// "tmtpost + 3", no icons. **Hover** the pill and a floating panel pops up over
/// the content listing every source as "site · title (date)"; click a row to open
/// the original page. The panel is rendered by an ancestor (see
/// `conversationOverlay`) so it floats above the answer and is never clipped by
/// the scroll view.
///
/// `hoveredID` is the shared "which badge is open" state owned by `NotchBody`: the
/// badge sets it to its own `id` on hover and clears it on exit; the floating
/// panel keeps it set while the cursor is over the panel, so moving up onto a row
/// doesn't dismiss it. The pill only *publishes its anchor* when it's the open one.
struct SourceBadge: View {
    let sources: [WebSource]
    @Binding var hoveredID: UUID?
    /// Shared deferred-close handle (owned by `NotchBody`): when the cursor leaves
    /// the pill we don't close immediately — we schedule a close ~140ms out, and
    /// the floating panel cancels it the moment the cursor lands on it. Without
    /// this, the 6pt gap between pill and panel is a dead zone that snaps the popup
    /// shut before the cursor can cross it.
    @Binding var pendingClose: DispatchWorkItem?

    /// Identity for "this badge is the open one". MUST be `@State`, not a plain
    /// `let`: the parent turn re-runs its body whenever its own `turnHovered`
    /// flips — which happens the instant the cursor moves onto the floating
    /// panel, because the panel (an overlay above the ScrollView) steals the
    /// hit test from the turn underneath. A plain `let UUID()` would be
    /// regenerated by that re-init, so `hoveredID` (holding the old UUID) no
    /// longer matches, `isOpen` flips false, the anchor unpublishes, and the
    /// panel tears itself down one frame after the cursor reaches it. `@State`
    /// storage survives struct re-inits, keeping the badge's identity stable
    /// for as long as it exists in the hierarchy.
    @State private var id = UUID()
    private var isOpen: Bool { hoveredID == id }

    var body: some View {
        Text(pillLabel)
            .font(.sf(11, weight: .medium))
            .tracking(0.1)
            .foregroundStyle(Tokens.text3)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.white.opacity(isOpen ? 0.10 : 0.06))
            )
            .overlay(Capsule().stroke(Tokens.hairline, lineWidth: 0.5))
            .contentShape(Capsule())
            // Publish this pill's frame + sources up to the ancestor overlay, but
            // only while it's the open one — so the ancestor knows where to float
            // the panel. A hidden tracking value when closed keeps the key present.
            .anchorPreference(key: SourcePopoverKey.self, value: .bounds) { anchor in
                isOpen ? SourcePopoverRequest(id: id, anchor: anchor, sources: sources) : nil
            }
            .onHover { hovering in
                if hovering {
                    pendingClose?.cancel()      // re-entered the pill — cancel any close
                    pendingClose = nil
                    hoveredID = id
                } else if isOpen {
                    scheduleClose()             // grace period to reach the panel
                }
            }
    }

    /// Close after a short grace period, unless something (the panel's hover, or
    /// re-entering the pill) cancels it first.
    private func scheduleClose() {
        pendingClose?.cancel()
        let work = DispatchWorkItem {
            if hoveredID == id { hoveredID = nil }
        }
        pendingClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    /// "tmtpost + 3" — the first source's short site name, plus a count of the
    /// rest. A single source just shows its site, no "+".
    private var pillLabel: String {
        let lead = sources.first?.site ?? L("source.badge.fallback")
        let extra = sources.count - 1
        return extra > 0 ? "\(lead) + \(extra)" : lead
    }
}

/// The floating source list — a self-contained card backed by the **same Liquid
/// Glass** the island uses (`nativeGlass`: genuine `.glassEffect(.clear)` on
/// macOS 26+, blurred fallback below) so the wallpaper refracts through it and the
/// panel reads as a piece of the same glass surface floated out, not a flat opaque
/// block. A soft dark veil under the glass keeps the source rows legible over any
/// wallpaper, and a specular hairline rim + soft shadow seat it as a layer above
/// the answer. Rendered by an ancestor overlay (escaping the scroll clip) and
/// positioned over the badge by the caller. `keepOpen`/`dismiss` let it hold the
/// badge open while the cursor is over its rows.
struct SourcePopoverPanel: View {
    let sources: [WebSource]
    let keepOpen: () -> Void
    let dismiss: () -> Void

    // Show at most this many rows; the rest scroll. ~18pt per row (11pt line +
    // 2pt padding top/bottom) plus the 7pt inter-row gap.
    private static let visibleRows = 4
    private static let rowHeight: CGFloat = 18
    private static let rowSpacing: CGFloat = 7
    // Runways the edge fades taper across when the list scrolls. They live INSIDE
    // the scroll viewport (as content padding), so they double as the card's
    // vertical padding — see `cardPadding` below.
    private static let topRunway: CGFloat = 14
    private static let bottomRunway: CGFloat = 24
    private static let cardPadding: CGFloat = 14

    /// Transparent hover bridge below the card, spanning the gap down to the
    /// badge's top edge. Without it the cursor crosses a dead strip on its way
    /// from pill → panel, and both `.onHover`s read "not hovering" during the
    /// crossing — which fires the pill's deferred close before the panel can
    /// cancel it, snapping the popup shut mid-reach. The bridge is part of the
    /// panel's hover region, so hover stays continuous the whole way across.
    /// Must match the gap the caller leaves in `NotchBody` (`bridgeGap`).
    static let bridgeGap: CGFloat = 6

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let scrolls = sources.count > Self.visibleRows
        // Cap the visible height at `visibleRows` rows; shorter lists size down to
        // their own content (no empty space, no scroll). Computing the height
        // explicitly — rather than letting `.fixedSize` measure it — lets the
        // ScrollView scroll the overflow once there are more rows than fit.
        //
        // The runways count toward that height. They're content padding, so they
        // occupy the viewport: leaving them out capped the viewport at bare row
        // math and the runways then ate it from both ends — the 4th row fell out
        // of view and the card read as two blank bands squeezing three rows.
        let topRunway = scrolls ? Self.topRunway : 0
        let bottomRunway = scrolls ? Self.bottomRunway : 0
        let shownRows = CGFloat(min(sources.count, Self.visibleRows))
        let rowsHeight = max(0, shownRows * Self.rowHeight + (shownRows - 1) * Self.rowSpacing)
        let visibleHeight = rowsHeight + topRunway + bottomRunway
        ScrollView(.vertical, showsIndicators: scrolls) {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(sources) { source in
                    SourceRow(source: source)
                }
            }
            // Breathing room each fade falls across, so the first / last row rests
            // outside its taper at full strength at either end of the scroll.
            .padding(.top, topRunway)
            .padding(.bottom, bottomRunway)
        }
        .scrollBounceBehavior(.basedOnSize)
        // The shared dissolve at both overflow edges (`scrollEdgeFade`) instead of a
        // hard cut — only when the list actually scrolls; a short list that fits
        // stays crisp. A thin feather up top, where only a row on its way out needs
        // swallowing.
        .scrollEdgeFade(top: scrolls, bottom: scrolls,
                        topFade: Self.topRunway, bottomFade: Self.bottomRunway)
        .frame(height: visibleHeight)
        .padding(.horizontal, 16)
        // A scrolling list already carries its own vertical inset (the runways) —
        // stacking the card's padding on top of it doubled the gap above the first
        // row. Only a short, runway-less list needs the card padding here.
        .padding(.vertical, scrolls ? 0 : Self.cardPadding)
        // A fixed width gives the rows a definite bound to truncate long titles
        // against (instead of stretching the popup to the longest line).
        .frame(width: 350, alignment: .leading)
        .background {
            // Real Liquid Glass: the high-transparency `.clear` material refracts
            // the wallpaper through the whole card; a soft dark veil over it keeps
            // the rows readable against bright backgrounds (the same recipe the
            // quick-tools popover uses — glass over a legibility veil).
            shape.fill(.clear).nativeGlass(in: shape)
                .overlay(shape.fill(Color.black.opacity(0.55)))
        }
        .overlay(
            // Specular hairline rim — a top-bright → bottom-faint edge, the
            // signature glass bevel, instead of a flat uniform outline.
            shape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.22), .white.opacity(0.06)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 0.75
            )
        )
        .clipShape(shape)
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
        // Extend the hover region downward by `bridgeGap` with a transparent
        // strip so the pill → panel crossing is never un-hovered (see comment
        // on `bridgeGap`). The card keeps its visual position; only the
        // hit-testable area grows down to meet the badge.
        .padding(.bottom, Self.bridgeGap)
        .background(Color.clear.contentShape(Rectangle()))
        // Hovering the panel (card + bridge) keeps the badge open; leaving it
        // dismisses — so the round-trip pill → row works, and moving away closes.
        .onHover { $0 ? keepOpen() : dismiss() }
    }
}

/// One expanded source row: "site · title", with the date trailing if known.
/// Clicking opens the URL. Hover lifts it slightly so it reads as actionable.
private struct SourceRow: View {
    let source: WebSource
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: source.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(source.site)
                    .font(.sf(11, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
                    .lineLimit(1)
                    .fixedSize()
                Text(source.title)
                    .font(.sf(11))
                    .foregroundStyle(hovering ? Tokens.text2 : Tokens.text4)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let date = source.date, let day = Self.dayOnly(date) {
                    Text(day)
                        .font(.sf(10))
                        .foregroundStyle(Tokens.text4)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// Show just the calendar day, not a full timestamp. Providers report dates
    /// inconsistently — some send a clean "2026-06-23", others a full ISO instant
    /// like "2026-06-20T10:26:35.000Z". Take the leading "YYYY-MM-DD" when the
    /// string is ISO-shaped; otherwise pass it through unchanged (a non-ISO label
    /// like "Jun 2026" stays as-is). Returns nil for empty input so the row hides
    /// the date entirely.
    static func dayOnly(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        // ISO-shaped: the date is the part before any "T" (or space) separator.
        let datePart = s.prefix { $0 != "T" && $0 != " " }
        // Only trust the truncation when it really is a YYYY-MM-DD prefix; for any
        // other shape, show the original string untouched.
        let isISODay = datePart.count == 10
            && datePart.allSatisfy { $0.isNumber || $0 == "-" }
        return isISODay ? String(datePart) : s
    }
}

/// One saved attachment, drawn from the history image store by filename. Renders
/// nothing at all when the file is gone (a cleared store, a hand-deleted JPEG) —
/// a missing picture is silence, never a broken-image box.
struct SavedImageThumb: View {
    let file: String
    var width: CGFloat = 34
    var height: CGFloat = 24
    var corner: CGFloat = 5

    var body: some View {
        if let image = NotchModel.historyImage(named: file) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
        }
    }
}

/// The images a SAVED turn rode in with — the copied screenshot an Ask attached, the
/// shots pasted into an agent task — shown above that turn's text wherever a saved
/// thread is read back (the reopened panel, the archive transcript). Deliberately the
/// same 34×24 thumbnail language as the live compose previews, so a reopened
/// conversation looks like the one that was sent. Clicking one opens the full-size
/// JPEG in Preview: the strip is a reminder of what was asked about, and the archive
/// is where you'd go to look at it properly.
struct SavedTurnImages: View {
    let files: [String]

    /// Past this the strip folds the rest into a "+N", same as the agent compose row —
    /// a task can carry up to `NotchModel.agentImageLimit` (20) images, far more than
    /// fits across the panel.
    private static let stripMax = 6

    var body: some View {
        HStack(spacing: 6) {
            ForEach(files.prefix(Self.stripMax), id: \.self) { file in
                Button {
                    NSWorkspace.shared.open(NotchModel.historyImageURL(file))
                } label: {
                    SavedImageThumb(file: file)
                }
                .buttonStyle(.plain)
            }
            if files.count > Self.stripMax {
                Text("+\(files.count - Self.stripMax)")
                    .font(.sf(10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Tokens.text4)
                    .frame(width: 26, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Agent work trail

/// The transcript of an agent run's work, in the CLI apps' own display grammar:
/// narration the agent wrote between tool calls reads as prose; the tool calls
/// BETWEEN two narrations fold into one summary row ("4 commands · 2 file
/// edits") that expands to the individual calls — each of which expands again
/// to the output it captured. Folded by default so a busy run reads as a story,
/// not a wall of terminal lines. Shared by the live agent detail page and a
/// reopened run's record, so the two read identically.
struct AgentWorkTrailView: View {
    let entries: [AgentLogEntry]
    /// Materialize rows lazily (only those near the viewport). The LIVE detail
    /// page turns this on: its trail holds the full log (capped at 300 entries)
    /// and pins to the bottom, so eagerly laying out hundreds of rows — every
    /// one a button with its own chevron — on the tap that opens the page was
    /// a visible stall the chat thread never had; and every ~250ms progress
    /// tick re-ran that full-stack layout while the page stayed up. Lazy, the
    /// mount and each tick only touch the screenful by the tail. Records keep
    /// the eager stack (default): their logs are one settled round's slice
    /// inside a thread whose scroll already manages its own geometry.
    var isLazy: Bool = false

    /// One display unit of the trail: a prose paragraph, a follow-up prompt
    /// marker, or a run of consecutive tool calls (folded together). Identified
    /// by its first entry's id, which stays stable while a live run grows the
    /// trailing group — so the group's expand state survives streaming.
    private enum Block: Identifiable {
        case prose(AgentLogEntry)
        case marker(AgentLogEntry)
        case tools([AgentLogEntry])

        var id: UUID {
            switch self {
            case .prose(let e), .marker(let e): return e.id
            case .tools(let run):               return run[0].id
            }
        }
    }

    /// Fold consecutive mono entries into `.tools` runs, keeping prose/markers
    /// as their own blocks in order.
    private var blocks: [Block] {
        var out: [Block] = []
        var run: [AgentLogEntry] = []
        func flush() {
            guard !run.isEmpty else { return }
            out.append(.tools(run)); run = []
        }
        for entry in entries {
            if entry.mono {
                run.append(entry)
            } else {
                flush()
                out.append(entry.title.hasPrefix("› ") ? .marker(entry) : .prose(entry))
            }
        }
        flush()
        return out
    }

    var body: some View {
        if isLazy {
            LazyVStack(alignment: .leading, spacing: 7) { rows }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 7) { rows }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The trail rows themselves — one ForEach, shared by the lazy and eager
    /// containers above. (Lazy containers preserve per-row @State — a group
    /// expanded, an output unfolded — for rows that scroll offscreen, so the
    /// two containers behave identically beyond when layout happens.)
    private var rows: some View {
        ForEach(blocks) { block in
            switch block {
            case .tools(let run):
                if run.count == 1 {
                    // A lone call carries its own headline ("$ npm test",
                    // "Editing Foo.swift") — a summary would only hide it.
                    AgentTrailToolRow(entry: run[0])
                } else {
                    AgentTrailGroupRow(entries: run)
                }
            case .marker(let entry):
                // A follow-up round's prompt marker — present only in the
                // live trail (the record files the prompt as its own user
                // turn instead). Reads as a quiet inline bubble, in the
                // user bubble's own type (14.5 medium).
                Text(String(entry.title.dropFirst(2)))
                    .font(.sf(14.5, weight: .medium))
                    .foregroundStyle(Tokens.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(0.05))
                    )
                    .padding(.vertical, 3)
            case .prose(let entry):
                // Narration is the agent's own words — set exactly like an
                // answer (same MarkdownBlocks, same 15pt base), one shade
                // quieter so the final report still leads.
                MarkdownBlocks(source: entry.title, baseFont: 15,
                               color: Tokens.text2)
            }
        }
    }
}

/// A folded run of consecutive tool calls: one quiet summary line ("4 commands
/// · 2 file edits ›") that expands to the individual calls, each still its own
/// `AgentTrailToolRow`. This is what keeps a busy stretch of work one line
/// tall until the reader actually asks for it.
private struct AgentTrailGroupRow: View {
    let entries: [AgentLogEntry]

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    expanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.summary(entries))
                        .font(.sf(13))
                        .foregroundStyle(Tokens.text4)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.sf(7.5, weight: .semibold))
                        .foregroundStyle(Tokens.text4)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entries) { AgentTrailToolRow(entry: $0) }
                }
                // Indented under the summary, with a hairline rail so the
                // unfolded run reads as the summary's own contents.
                .padding(.leading, 9)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 0.75)
                        .fill(.white.opacity(0.08))
                        .frame(width: 1.5)
                }
            }
        }
    }

    /// "4 commands · 2 file edits · 1 search" — counts by the title prefixes the
    /// parsers write ("$ ", "Editing ", "Searching ", "Read/Reading/Grep/Glob"),
    /// anything else counted as a plain tool call.
    private static func summary(_ entries: [AgentLogEntry]) -> String {
        var commands = 0, edits = 0, searches = 0, reads = 0, others = 0
        for e in entries {
            if e.title.hasPrefix("$ ") { commands += 1 }
            else if e.title.hasPrefix("Editing ") { edits += 1 }
            else if e.title.hasPrefix("Searching ") { searches += 1 }
            else if e.title.hasPrefix("Read") || e.title.hasPrefix("Grep")
                     || e.title.hasPrefix("Glob") { reads += 1 }
            else { others += 1 }
        }
        var parts: [String] = []
        if commands > 0 { parts.append(commands == 1 ? L("agent.trail.cmd.one") : L("agent.trail.cmd.many", commands)) }
        if edits > 0    { parts.append(edits == 1 ? L("agent.trail.edit.one") : L("agent.trail.edit.many", edits)) }
        if reads > 0    { parts.append(reads == 1 ? L("agent.trail.read.one") : L("agent.trail.read.many", reads)) }
        if searches > 0 { parts.append(searches == 1 ? L("agent.trail.search.one") : L("agent.trail.search.many", searches)) }
        if others > 0   { parts.append(others == 1 ? L("agent.trail.tool.one") : L("agent.trail.tool.many", others)) }
        return parts.joined(separator: " · ")
    }
}

/// One tool call in the trail: the input line in mono, with a disclosure
/// chevron when the tool's output was captured — tapping unfolds the output in
/// a quiet code-block card. Rows without output are inert (nothing to unfold).
private struct AgentTrailToolRow: View {
    let entry: AgentLogEntry

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard entry.detail != nil else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    expanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Mono at 12 = the code rung under the 13pt secondary body,
                    // the same base−1 step markdown code blocks use.
                    Text(entry.title)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Tokens.text4)
                        .lineLimit(expanded ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                    if entry.detail != nil {
                        Image(systemName: "chevron.right")
                            .font(.sf(7.5, weight: .semibold))
                            .foregroundStyle(Tokens.text4)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, let detail = entry.detail {
                Text(detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Tokens.text3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.white.opacity(0.03))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
                            )
                    )
            }
        }
    }
}
