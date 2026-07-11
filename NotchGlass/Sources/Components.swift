import SwiftUI
import AppKit
import Combine

/// A borderless prompt field styled to the design tokens.
///
/// Backed by a custom `NSTextField` rather than SwiftUI's `TextField` for one
/// specific reason: AppKit's text fields pop up a floating **autocomplete
/// suggestions panel** while typing/deleting (the empty glass box the user saw).
/// SwiftUI gives no hook to turn it off, so we wrap `NSTextField` directly and
/// disable `isAutomaticTextCompletionEnabled` (plus all the other "smart"
/// substitutions that don't belong in a prompt box).
/// The prompt's backing field. One job: strip the field editor's completion /
/// prediction magic the moment focus arrives by ANY route. The focusTrigger
/// path in `updateNSView` disables it after its programmatic
/// `makeFirstResponder`, but a direct CLICK into the field creates the editor
/// without that block ever running (its `currentEditor() == nil` guard skips),
/// and `controlTextDidBeginEditing` waits for the first *committed* change — an
/// entire IME composition can play out before that. A click-focused session
/// could therefore reach its first keystrokes with the system completion panel
/// still armed: the intermittent big empty glass box flashing over the panel.
/// Hooking `becomeFirstResponder` covers click, Tab and programmatic focus
/// alike, synchronously, before any keystroke can reach the editor.
final class MagiclessTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { PromptField.disableEditorMagic(currentEditor()) }
        return accepted
    }
}

struct PromptField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat
    /// When this flips true the field grabs first-responder (caret in the box) —
    /// our replacement for SwiftUI `@FocusState`, which can't drive an AppKit view.
    var focusTrigger: Bool = false
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
    /// Whether an ↑/↓ history-recall session is live. When `true`, ↑/↓ keep going
    /// to `onUp`/`onDown` even though the box now holds a recalled question (so the
    /// user can press ↑ again to step further back), instead of moving the caret.
    /// Default `false`: ↑/↓ only fire the callbacks on an empty field.
    var isRecalling: () -> Bool = { false }
    /// Invoked on Enter *before* `onSubmit` — lets the idle prompt open a
    /// keyboard-highlighted recent row instead of submitting. Returns `true` when
    /// it handled the key (a row was open); `false` falls through to `onSubmit`.
    var onSubmitNav: () -> Bool = { false }
    /// Invoked on Tab (and Shift-Tab) — the idle prompt binds it to "flip the
    /// destination" (Ask ⇄ Note), overriding the classifier for the current line.
    /// Returns `true` when consumed; `false` lets Tab do its default focus move.
    var onTab: () -> Bool = { false }
    /// Reports the width (pt) of everything the field editor is currently *showing*,
    /// in the field's own font — committed text PLUS any in-progress IME composition
    /// (the pinyin/marked text that isn't yet in `text`). The inline hint uses this
    /// to sit right after the caret, so "— Ask" trails the pinyin live and slides
    /// right as more is typed, instead of anchoring to the stale committed text.
    /// `0` when the field is empty. No-op by default.
    var onCaretWidth: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = MagiclessTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.isBezeled = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        // Kill the floating suggestions panel + all auto-substitutions at the
        // NSTextField level.
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
        // Refresh the coordinator's view of us so its callbacks (onCaretWidth, the
        // nav hooks) run against the current closures, not the ones captured at init.
        context.coordinator.parent = self
        // NEVER touch the field while an IME composition (marked text) is in flight.
        // During composition the bound `text` lags the display (pinyin isn't
        // committed yet), so the `stringValue != text` check below would "correct"
        // the field back to the stale committed text — wiping the user's half-typed
        // pinyin. And re-renders DO happen mid-composition now: the caret-width
        // updates driving the inline hint are SwiftUI state changes.
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        let textChanged = !composing && field.stringValue != text
        if textChanged { field.stringValue = text }
        applyStyle(to: field)
        // When `text` is cleared programmatically (after submit) there's no editor
        // change notification to re-measure from, so push the new width here. Use the
        // bound `text` (the editor mirrors it; no marked text is in flight on a reset).
        if textChanged {
            let font = NSFont.systemFont(ofSize: fontSize)
            let w = text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: [.font: font]).width)
            onCaretWidth(w)
        }
        // Take focus exactly ONCE per rising edge of focusTrigger. SwiftUI calls
        // updateNSView on every render while the panel is open; without this latch
        // we'd enqueue a `makeFirstResponder` on each pass, piling up async blocks
        // that ping-pong the caret (and, with two PromptFields on screen, fight
        // each other) — a prime suspect for the recurring freeze.
        let coord = context.coordinator
        if focusTrigger {
            if !coord.didFocus, field.window != nil, field.currentEditor() == nil {
                coord.didFocus = true
                DispatchQueue.main.async { [weak field, weak coord] in
                    guard let field, field.currentEditor() == nil else { return }
                    field.window?.makeFirstResponder(field)
                    // AppKit's default `becomeFirstResponder` on an NSTextField
                    // SELECTS ALL of the field's contents. When a submit happens to
                    // coincide with a re-focus (the mode/history/clip `onChange`s fire
                    // `refocusInput`, and the editor can be momentarily torn down by a
                    // layout swap so the `currentEditor() == nil` guard above passes
                    // even though the field is still the visual focus), that select-all
                    // is exactly the intermittent bug: the prior text shows up fully
                    // highlighted and the caret reads as "lost" — the next keystroke
                    // would replace the whole selection. Collapse the selection to a
                    // caret at the end so a re-focus never highlights existing text.
                    if let editor = field.currentEditor() {
                        editor.selectedRange = NSRange(location: editor.string.count, length: 0)
                    }
                    Self.disableEditorMagic(field.currentEditor())
                    // The editor exists from this moment — hook the caret-width
                    // observers NOW, not at controlTextDidBeginEditing. That delegate
                    // call only fires on the first *committed* change, so a user who
                    // starts straight into IME composition (pinyin) would compose an
                    // entire word before any observer existed.
                    coord?.attachEditorObservers(field.currentEditor())
                }
            }
        } else {
            coord.didFocus = false   // re-arm for the next open
        }
        // Belt-and-suspenders for click-to-focus and editor swaps: whenever this
        // field currently owns the field editor, make sure the caret-width observers
        // are attached (idempotent — re-attaching the same editor is a no-op) and
        // the editor's completion/prediction magic stays off. The authoritative
        // kill for click-focus is MagiclessTextField.becomeFirstResponder (a render
        // isn't guaranteed between a click and the first keystroke); this pass just
        // re-asserts it, since macOS can re-arm traits on a live editor.
        if let editor = field.currentEditor() {
            Self.disableEditorMagic(editor)
            coord.attachEditorObservers(editor)
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

    /// Only writes a property when its value actually changed. AppKit setters like
    /// `placeholderAttributedString` rebuild layout/redraw on every assignment;
    /// doing that unconditionally on each keystroke was wasteful churn. Cheap
    /// equality guards keep typing smooth.
    private func applyStyle(to field: NSTextField) {
        let wantFont = NSFont.systemFont(ofSize: fontSize)
        if field.font != wantFont { field.font = wantFont }

        let wantText = NSColor(Tokens.ink).withAlphaComponent(0.96)
        if field.textColor != wantText { field.textColor = wantText }

        // Compare the *whole* attributed placeholder (string AND color/font), not
        // just the text — otherwise a color change with the same text gets
        // silently dropped and the field keeps an old, darker placeholder.
        let wantPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor(Tokens.placeholder),
                .font: wantFont,
            ]
        )
        if field.placeholderAttributedString != wantPlaceholder {
            field.placeholderAttributedString = wantPlaceholder
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        /// Refreshed on every `updateNSView` so the callbacks below (notably
        /// `onCaretWidth`) never fire through a stale closure captured at init.
        var parent: PromptField
        /// One-shot latch: true once we've taken focus for the current rising edge
        /// of `focusTrigger`, reset when it falls. Prevents re-enqueuing focus on
        /// every render. (See updateNSView.)
        var didFocus = false
        /// The field editor we've subscribed to, and its text storage. Held weakly —
        /// it's the shared window field editor, not ours to retain. The STORAGE is
        /// the one that matters: IME composition (typing pinyin before it commits)
        /// edits the marked text directly in the storage WITHOUT posting
        /// `NSText.didChangeNotification` or calling `controlTextDidChange` — those
        /// only fire for committed changes. `NSTextStorage.didProcessEditingNotification`
        /// fires for every storage edit, marked text included, so it's the only hook
        /// that lets the inline hint trail the pinyin live.
        private weak var observedEditor: NSText?
        private weak var observedStorage: NSTextStorage?
        init(_ parent: PromptField) { self.parent = parent }
        deinit { detachEditorObservers() }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            // Editor exists now — strip its completion/prediction behaviours.
            PromptField.disableEditorMagic(field.currentEditor())
            attachEditorObservers(field.currentEditor())
            reportCaretWidth(for: field.currentEditor())
            // Drop the island below the IME candidate window while typing so the
            // pinyin/kana/Hangul selection popup isn't covered by the panel.
            (field.window as? NotchPanel)?.beginFieldEditing()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            detachEditorObservers()
            // Restore the resting level now that this field is done editing.
            ((obj.object as? NSTextField)?.window as? NotchPanel)?.endFieldEditing()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            // Belt-and-suspenders: macOS can re-arm prediction on the editor as
            // you type, so keep it disabled on every change (cheap idempotent set).
            PromptField.disableEditorMagic(field.currentEditor())
            attachEditorObservers(field.currentEditor())
            reportCaretWidth(for: field.currentEditor())
        }

        // MARK: Caret-width tracking (for the inline hint, IME-aware)

        /// Subscribe to the field editor's text storage (and, for committed-change
        /// coverage, the editor's own didChange). Idempotent — re-attaching the same
        /// editor/storage is a no-op — so it's safe to call from every hook that
        /// might be the first to see the editor (focus grab, begin editing, change).
        func attachEditorObservers(_ editor: NSText?) {
            guard let editor else { return }
            if editor !== observedEditor {
                if let old = observedEditor {
                    NotificationCenter.default.removeObserver(
                        self, name: NSText.didChangeNotification, object: old)
                }
                observedEditor = editor
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(editorTextDidChange(_:)),
                    name: NSText.didChangeNotification,
                    object: editor
                )
            }
            // The IME-aware hook: marked-text (pinyin) edits land in the storage and
            // post didProcessEditing even though no "text did change" ever fires.
            if let storage = (editor as? NSTextView)?.textStorage, storage !== observedStorage {
                if let old = observedStorage {
                    NotificationCenter.default.removeObserver(
                        self, name: NSTextStorage.didProcessEditingNotification, object: old)
                }
                observedStorage = storage
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(storageDidProcessEditing(_:)),
                    name: NSTextStorage.didProcessEditingNotification,
                    object: storage
                )
            }
        }

        private func detachEditorObservers() {
            if let editor = observedEditor {
                NotificationCenter.default.removeObserver(
                    self, name: NSText.didChangeNotification, object: editor)
            }
            observedEditor = nil
            if let storage = observedStorage {
                NotificationCenter.default.removeObserver(
                    self, name: NSTextStorage.didProcessEditingNotification, object: storage)
            }
            observedStorage = nil
        }

        /// Committed-change path (kept as a cheap backstop alongside the storage hook).
        @objc private func editorTextDidChange(_ note: Notification) {
            reportCaretWidth(for: note.object as? NSText)
        }

        /// The IME path: fires on EVERY storage edit, including marked-text (pinyin)
        /// updates mid-composition. Posted from inside `processEditing`, so defer one
        /// runloop tick before reading the storage — measuring mid-edit would read a
        /// half-applied state.
        @objc private func storageDidProcessEditing(_ note: Notification) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reportCaretWidth(for: self.observedEditor)
            }
        }

        /// Measure everything the editor is currently showing — committed text plus
        /// any in-progress IME composition — in the field's font, and hand it to the
        /// inline hint so it sits right after the caret. The editor's `string`
        /// already includes the marked (composing) text, so measuring it covers the
        /// pinyin-in-progress case for free.
        private func reportCaretWidth(for editor: NSText?) {
            let shown = editor?.string ?? parent.text
            let font = NSFont.systemFont(ofSize: parent.fontSize)
            let width = shown.isEmpty
                ? 0
                : ceil((shown as NSString).size(withAttributes: [.font: font]).width)
            parent.onCaretWidth(width)
        }

        /// The authoritative kill switch for the word-completion popup: the field
        /// editor asks its delegate for completions on every edit; returning an
        /// empty list (and -1 selection) means there's never anything to show, so
        /// the panel never appears. (Calling `complete(_:)` ourselves did the
        /// OPPOSITE — it *opened* the panel and looped — so that's gone.)
        func control(_ control: NSControl, textView: NSTextView,
                     completions words: [String],
                     forPartialWordRange charRange: NSRange,
                     indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
            index.pointee = -1
            return []
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            // Defensively swallow the "show completions" command too.
            if commandSelector == #selector(NSResponder.complete(_:)) {
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Give the recent-list highlight first crack at Enter — if a row is
                // keyboard-selected, open it; otherwise submit the prompt as usual.
                if parent.onSubmitNav() { return true }
                parent.onSubmit()
                return true
            }
            // Tab flips the line's destination (Ask ⇄ Note). Shift-Tab too — the
            // toggle is binary, so "the other one" is the same either way. The
            // caller decides whether to consume it; unconsumed, Tab falls through
            // to its usual focus move.
            if commandSelector == #selector(NSResponder.insertTab(_:))
                || commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                return parent.onTab()
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
            let emptyOrRecalling =
                parent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

/// A Siri-style **inline ghost hint** that trails the typed text on the same line,
/// spelling out where Enter will send it — "— Ask" for a question, "— Note" for a
/// jot — the way Siri appends a faint "— Ask Siri" after what you've typed. The
/// classifier (via `NotchModel.submitLabel` / `effectiveSubmitPanel`)
/// already recomputes that destination on every keystroke; this just *shows* it,
/// in place, so the routing is visible before you press Return.
///
/// It's an overlay, not part of the field: the backing `NSTextField` can't host a
/// trailing accessory, so we measure the typed text's width with the field's exact
/// `NSFont` and offset the ghost label by that much inside a leading-aligned
/// `ZStack`. When the text grows toward the trailing edge, the hint doesn't vanish —
/// it **docks** at the right edge of the row and holds there while the field scrolls,
/// so the Ask/Note read is never lost on a long line. The caller reserves that
/// docking slot in the field itself (`reservedTrailingWidth`), so scrolled text can
/// never run underneath the docked hint.
///
/// Mounted by the caller *over* the same row as its `PromptField`, sharing the
/// field's `fontSize` so the measurement lines up glyph-for-glyph. Caller passes the
/// available width (usually the row's own width, via a `GeometryReader`) so the
/// dock position is known.
struct InlineSendHint: View {
    /// "Ask" / "Note" — the destination the classifier currently reads.
    var label: String
    /// A softer trailing detail after the destination word — the Ask model name
    /// ("Ask gpt-4o") or the Remind recurrence ("Remind · Daily"). Rendered a shade
    /// lighter than the word so it reads as a footnote, not a second destination.
    var suffix: String = ""
    /// The field's font size, so the hint matches the body text size exactly.
    var fontSize: CGFloat
    /// Width (pt) of everything the field is currently showing — committed text PLUS
    /// any in-progress IME composition (pinyin) — measured in the field's font by
    /// `PromptField` (`onCaretWidth`). This is where the caret sits, hence where the
    /// ghost begins; sourcing it from the editor (not from the committed `text`) is
    /// what lets "— Ask" trail the pinyin live and slide right as you type.
    var caretWidth: CGFloat
    /// Width available on the row for text + hint. The hint hides rather than clip
    /// when the content leaves it no room.
    var availableWidth: CGFloat
    /// Left inset of the NSTextField's text (its cell draws ~2pt in from the edge),
    /// so the ghost lands flush after the glyphs, not 2pt early.
    var leadingInset: CGFloat = 2
    /// The destination's colour (Ask blue / Note amber / Remind orange — the same
    /// palette the filter chips and capture chips wear), painted on the WORD only;
    /// the leading em dash stays placeholder-grey so the connector reads as
    /// punctuation and the colour lands on the destination itself. `nil` keeps the
    /// whole hint in the classic placeholder grey.
    var tint: Color? = nil

    /// Breathing room between the last glyph and the ghost.
    private static let gap: CGFloat = 8

    /// Trailing room the caller should reserve INSIDE the field (as trailing
    /// padding) so text can never scroll under the docked hint. Sized to the *current*
    /// label ("— Ask", "— Note", "— Remind · Weekly · …") rather than the widest
    /// possible label, so the field uses all available width when the destination is
    /// short and no dead strip appears to the right of the ghost. The caller animates
    /// this padding alongside the hint so Ask→Note→Remind transitions stay smooth.
    static func reservedTrailingWidth(label: String, suffix: String = "", fontSize: CGFloat) -> CGFloat {
        return width(of: "— \(label)\(suffix)", fontSize: fontSize) + gap
    }

    var body: some View {
        // Sit the ghost just past the glyphs, with a small breathing gap — but never
        // past the dock at the row's trailing edge. A short line reads inline
        // (Siri-style, right after the caret); as the line grows the hint glides
        // right until it reaches the dock and holds there, staying visible while the
        // field scrolls underneath (the caller reserved that slot, so no overlap).
        // Visibility keys on `caretWidth` (not the committed `text`) so the hint
        // stays up while pinyin is still composing.
        //
        // The dock anchors to the LEFT edge of the reserved strip the caller padded
        // into the field. Both the field's usable width and the dock reference the SAME
        // reserved width (now sized to the current label) so the ghost lands flush where
        // the text area ends — no gap, no overlap — while short labels reclaim the rest
        // of the row for the editable area.
        let reserved = Self.reservedTrailingWidth(label: label, suffix: suffix, fontSize: fontSize)
        let dock = availableWidth - reserved + Self.gap
        let start = min(leadingInset + caretWidth + Self.gap, dock)
        let visible = caretWidth > 0

        // Motion notes — tuned to Apple's current language for ghost text:
        //  · FOLLOW is a critically-damped spring, not a fixed-duration ease. Typing
        //    retargets the animation every keystroke; a spring merges those
        //    retargets velocity-continuously (each new target inherits the current
        //    velocity), where an ease restarts from zero each time and reads as a
        //    mechanical stutter under fast input. No bounce — the hint is "pulled
        //    along" behind the caret, it never overshoots past it.
        //  · APPEAR/DISAPPEAR is a materialize (blur + fade, in place) — the same
        //    treatment Apple Intelligence uses for ghost text (`.blurReplace` on
        //    macOS 15; recreated below for our 14 target). Structurally inserting
        //    the Text (`if visible`) is what keeps the appearance anchored: a freshly
        //    inserted view is born at its final offset, so it condenses into
        //    position rather than flying in from wherever the hint last sat.
        //  · The WORD swap (Ask⇄Note) is a quiet in-place cross-fade
        //    (`contentTransition`), not a scale/bounce — the meaning changes, the
        //    object doesn't.
        return ZStack(alignment: .leading) {
            if visible {
                // Match the body text exactly — same size, same (regular) weight as
                // the field's own glyphs — so the hint reads as a quiet continuation
                // of the line rather than a smaller label. Only the colour sets it
                // apart: the whole hint wears the destination's tint — the em dash
                // in a softer cut of the SAME hue (a grey dash next to a coloured
                // word read as two disjoint pieces), the word carrying the full
                // ghost strength. Typed text stays near-white.
                // Three strengths of the SAME hue: the em dash softest (punctuation),
                // the destination word full ghost-strength, and the trailing detail
                // (model name / recurrence) a shade lighter than the word so it reads
                // as a quiet footnote rather than a second destination.
                (Text("— ").foregroundColor(tint.map { $0.opacity(0.42) } ?? Tokens.placeholder)
                    + Text(label).foregroundColor(tint.map { $0.opacity(0.68) } ?? Tokens.placeholder)
                    + Text(suffix).foregroundColor(tint.map { $0.opacity(0.42) } ?? Tokens.placeholder.opacity(0.6)))
                    .font(.system(size: fontSize, weight: .regular))
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.opacity)
                    .animation(.smooth(duration: 0.25), value: label + suffix)
                    .offset(x: start)
                    .animation(.smooth(duration: 0.25), value: start)
                    .transition(.materialize)
            }
        }
        .allowsHitTesting(false)
        // Drives the insertion/removal (materialize) transition above.
        .animation(.smooth(duration: 0.3), value: visible)
    }

    /// Measure a string's rendered width in `NSFont.systemFont(ofSize:)` — the same
    /// font family `PromptField` installs — so the ghost's start matches the real
    /// caret. Uses AppKit's text sizing (not a SwiftUI `Text` measurement) because
    /// the field itself is an `NSTextField`; same engine, same metrics.
    private static func width(of string: String, fontSize: CGFloat) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: fontSize)
        let size = (string as NSString).size(withAttributes: [.font: font])
        return ceil(size.width)
    }
}

/// The two ends of the ghost-text materialize: hidden is a soft transparent haze
/// (blurred + clear), shown is the sharp resting glyphs. Used via
/// `AnyTransition.materialize` so insertion condenses the text into place and
/// removal dissolves it — Apple Intelligence's ghost-text treatment (macOS 15's
/// `.blurReplace`), recreated with a modifier transition for our macOS 14 target.
private struct MaterializeEffect: ViewModifier {
    var shown: Bool
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 4)
    }
}

extension AnyTransition {
    /// Blur-and-fade in place: condense in on insertion, dissolve out on removal.
    static let materialize = AnyTransition.modifier(
        active: MaterializeEffect(shown: false),
        identity: MaterializeEffect(shown: true)
    )
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
        .animation(.easeOut(duration: 0.18), value: hovering)
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
                .font(.system(size: 13, weight: .semibold))
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
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
            .font(.system(size: 13, weight: .semibold))
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
    var size: CGFloat = 30
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .regular))
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
        .animation(.easeOut(duration: 0.18), value: hovering)
        .help(help)
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
        .animation(.easeOut(duration: 0.18), value: hovering)
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
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(hovering ? Tokens.text2 : Tokens.text3)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .glassCapsule(in: Capsule(), brighter: hovering, tint: tint)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// A one-shot **rim glow** that pulses whenever a watched value changes — the input
/// field's outer acknowledgement that its *destination* just flipped (Ask → Note →
/// Remind). The inline "— Ask"/"— Note" ghost already cross-fades the word beside the
/// caret; this brightens the field's own border for a beat so the change registers in
/// peripheral vision too, not only where the eye is reading.
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

/// One clipboard-preset chip — a small glass capsule labelled with a Writing-Tools
/// style action ("Summarize", "Proofread", "更友好"…) that, on tap, runs that preset
/// against the copied text. Same Liquid Glass language as `GlassTextButton`, sized a
/// touch larger so a row of them reads as tappable actions, not metadata.
struct ClipboardPresetChip: View {
    var title: String
    /// A faint background tint for the leading capture chip ("Note"/"Remind"), set so
    /// it reads as a slightly different *colour* from the plain-glass Ask presets beside
    /// it — same size, same text weight, same hover feel, just a coloured wash over the
    /// glass. `nil` (the default) leaves the chip untinted, identical to the presets.
    var tint: Color? = nil
    /// When set, a trailing "↵" key cap rides inside the chip — the discoverability cue
    /// for the leading capture chip, which Enter on an empty prompt already fires. Only
    /// the capture chip passes this; the plain Ask presets leave it `nil`.
    var keyHint: Bool = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.sf(12, weight: .medium))
                    .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
                    .lineLimit(1)
                // The "↵" cue: a small return glyph, so the capture chip advertises its
                // keyboard twin without spelling out the word "Enter". Brightens with the
                // chip on hover. No background — it rides as a bare glyph beside the label.
                if keyHint {
                    Image(systemName: "return")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(hovering ? Tokens.text2 : Tokens.text3)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, keyHint ? 10 : 12)
            .padding(.vertical, 6)
            .glassCapsule(in: Capsule(), brighter: hovering, tint: tint)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
    }
}

/// A minimal left-aligned flow layout: lays children left-to-right, wrapping to the
/// next line when the next child would overflow the proposed width. Used for the
/// clipboard-preset chip row, which carries more chips than fit the panel on one
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
    var onCancel: () -> Void
    var onConfirm: () -> Void

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
                    Text(L("clear.body"))
                        .font(.sf(12))
                        .foregroundStyle(Tokens.text3)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    ConfirmDialogButton(title: L("clear.cancel"), role: .cancel, action: onCancel)
                    ConfirmDialogButton(title: L("clear.confirm"), role: .destructive, action: onConfirm)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: 280)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    // Real glass: a thin blur of whatever sits behind the card,
                    // dropped onto a dark tint so the text keeps its contrast.
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.black.opacity(0.28))
                    )
                    // A soft top-down sheen, like light catching the upper edge.
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.10), .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                            .blendMode(.plusLighter)
                    )
                    // Gradient hairline — bright along the top, fading down the sides.
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.30), .white.opacity(0.08)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.75
                            )
                    )
                    .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
            }
            .padding(24)
        }
    }
}

/// A flat, full-width-ish button for the confirmation card — a neutral capsule for
/// Cancel, a soft-red one for the destructive Clear. Brightens on hover.
private struct ConfirmDialogButton: View {
    var title: String
    var role: ButtonRole
    var action: () -> Void

    @State private var hovering = false

    private var isDestructive: Bool { role == .destructive }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.sf(13, weight: .semibold))
                .foregroundStyle(isDestructive ? Tokens.danger : Tokens.text1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(
                            isDestructive
                                ? Tokens.danger.opacity(hovering ? 0.26 : 0.16)
                                : Color.white.opacity(hovering ? 0.16 : 0.09)
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
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
                    .fill(Tokens.text2)
                    .frame(width: dot, height: dot)
                    .scaleEffect(phase ? 1.0 : 0.82)
                    .opacity(phase ? 0.95 : 0.22)
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

/// A single status-line slot that cross-fades whenever its `text` changes, so a
/// rotating mood word ("Glowing" → "Drifting") or a status change ("Searching the
/// web…" → "Reading the results…") dissolves rather than hard-cutting. The seam is
/// the whole point: SwiftUI's default for a `Text` whose string changes is to swap
/// the value with no transition, and keying it on `.id()` only re-inserts the view
/// (which, without an enclosing animated transaction, blinks). Here two layers —
/// the outgoing word and the incoming word — are stacked in the same leading slot
/// and their opacities are animated in opposite directions over one easeInOut
/// window, so one fades out exactly as the other fades in. The phase is flipped on
/// a `.task(id:)` keyed to the incoming text, which also enforces a minimum dwell
/// before the *caller* is allowed to rotate again (the caller's timer interval is
/// the dwell; this view just guarantees the fade can't be cut short by a too-fast
/// change — it always completes a full fade before showing the next).
struct CrossfadeText: View {
    let text: String
    var font: CGFloat = 15
    var color: Color = Tokens.text2

    /// The word currently lit. Lags `text` by exactly one fade: when `text`
    /// changes, the old `shown` fades out while the new `text` fades in, then
    /// `shown` catches up.
    @State private var shown: String = ""
    @State private var visible = true

    /// One fade leg (out, then in). 0.45s reads as a calm dissolve, not a blink,
    /// and is short enough that back-to-back rotations never pile up.
    private static let fade: Double = 0.45

    var body: some View {
        // Always render `shown`; `visible` alone drives opacity. The incoming word
        // is swapped into `shown` only after the out-leg finishes, so the slot never
        // briefly shows the next word at full opacity (which would read as a flash
        // of the next word before the current one has faded).
        Text(shown)
            .font(.system(size: font, weight: .regular))
            .foregroundStyle(color)
            .opacity(visible ? 1 : 0)
            .animation(.easeInOut(duration: Self.fade), value: visible)
            .onAppear {
                // First appearance lights up immediately — no fade-from-blank that
                // would read as a flicker on the very first word.
                shown = text
                visible = true
            }
            .onChange(of: text) { _, newValue in
                guard newValue != shown else { return }
                // Fade the old word out…
                visible = false
                // …then, after the out-leg completes, swap in the new word and
                // fade it back. The delay matches `fade` so the two legs are
                // sequential (out, in) rather than overlapping into a muddy blur.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.fade) {
                    shown = newValue
                    visible = true
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
    /// The present-progressive mood word for the pre-stream wait (e.g. "Gazing…").
    var thinkingWord: String = ""
    var sources: [WebSource] = []
    @Binding var hoveredSourceID: UUID?
    @Binding var sourceCloseWork: DispatchWorkItem?
    var baseFont: CGFloat = 15
    var color: Color = Tokens.text1
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            MarkdownBlocks(source: text, baseFont: baseFont, color: color, onInAppCopy: onInAppCopy)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                // Reserve a line's worth of height while the answer is still empty
                // so the wait overlay has somewhere to sit and the bubble doesn't
                // pop from zero-height to one-line when the first token lands.
                .frame(minHeight: showWait ? baseFont * 1.6 : 0, alignment: .leading)
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
                            CrossfadeText(text: waitLine, font: baseFont, color: Tokens.text2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .opacity(showWait ? 1 : 0)
                    .allowsHitTesting(false)
                }

            // The `ask_user` question card: the model has paused this answer to ask
            // the user a multiple-choice question and is suspended until they pick
            // (or the wait times out). Only while streaming — a settled turn can't
            // be waiting on anyone.
            if streaming, let pendingQuestion {
                UserQuestionCard(question: pendingQuestion) { option in
                    onChooseOption?(pendingQuestion.id, option)
                }
                .padding(.top, 2)
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
                                           help: L("result.copyMarkdown"),
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
                        // pasting into fields that don't render markdown.
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
                    if let onRegenerate {
                        AnswerFooterButton(icon: "arrow.clockwise",
                                           help: regenerateModels.isEmpty
                                               ? L("result.regenerate")
                                               : L("result.regenerate.menu"),
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
                }
                .padding(.top, 2)
            }
        }
        .onHover { turnHovered = $0 }
        .animation(.easeInOut(duration: Self.fade), value: showWait)
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
/// walks away and the wait times out). Quiet by design — a hairline-outlined card
/// with the question on top and one tappable row per option, in the same visual
/// family as the source popover: this is part of the answer's flow, not a modal
/// demanding attention.
struct UserQuestionCard: View {
    let question: NotchModel.PendingUserQuestion
    /// Called with the option's text when the user picks it.
    var choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(question.question)
                .font(.sf(13, weight: .medium))
                .foregroundStyle(Tokens.text1)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                // Options are de-duplicated by the tool before they get here, so
                // the string itself is a safe ForEach id.
                ForEach(question.options, id: \.self) { option in
                    UserQuestionOptionRow(title: option) { choose(option) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
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
        .animation(.easeOut(duration: 0.14), value: hovering)
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
        // SwiftUI's built-in inline-markdown parsing covers **bold**, *italic*,
        // and `code` — exactly the subset we need.
        if var parsed = try? AttributedString(
            markdown: raw,
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
        return AttributedString(raw)
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
                blocks.append(.code(language: lang.isEmpty ? nil : lang, text: body.joined(separator: "\n")))
                i += 1
                continue
            }

            if line.isEmpty {
                i += 1
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
                blocks.append(.paragraph(text: line))
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
        if let parsed = try? AttributedString(
            markdown: line,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return String(parsed.characters)
        }
        return line
    }
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

    // `parseCached`, not `parse`: this computed property re-runs on every body
    // evaluation, which during streaming happens for every ~33ms flush times
    // every mounted copy of the turn (visible thread, height probe, blur
    // overlays). The cache makes all but the first evaluation of a given
    // source free.
    private var blocks: [MarkdownBlock] { MarkdownParser.parseCached(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                // Per-block styling lives in `MarkdownBlockRow`, shared with the
                // streaming renderer (`StreamingMarkdown`) so a settled answer and a
                // live one are laid out identically — they differ only in the tail
                // fade/selection wrapping, never in how a block kind looks.
                // `.equatable()` — see the row's `Equatable` conformance for why.
                MarkdownBlockRow(block: block, baseFont: baseFont, color: color, onInAppCopy: onInAppCopy)
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
             .task(_, let t, _), .quote(let t), .paragraph(let t):
            return t.count
        case .code(_, let t):
            return t.count
        case .table(let header, let rows):
            // Grow as cells stream in: keys on total rendered character count so a
            // table still building its last row re-fades only as it changes.
            return header.reduce(0) { $0 + $1.count }
                + rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
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

/// One block of an answer, extracted from `MarkdownBlocks.row(for:)` so both the
/// settled renderer and the streaming renderer share identical block styling. The
/// two callers differ only in animation/selection wrapping, never in how a given
/// block kind looks.
struct MarkdownBlockRow: View, Equatable {
    let block: MarkdownBlock
    var baseFont: CGFloat = 15
    var color: Color = Tokens.text1
    var onInAppCopy: (() -> Void)? = nil

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
    }

    var body: some View {
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
                    withAnimation(.easeOut(duration: 0.15)) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation(.easeOut(duration: 0.25)) { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(copied ? Tokens.text2 : Tokens.text3)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(5)
                // Ghost by default; brightens on hover; full while showing the check.
                .opacity(copied ? 1.0 : hovering ? 0.7 : 0.3)
                .animation(.easeOut(duration: 0.18), value: hovering)
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
            withAnimation(.easeOut(duration: 0.15)) { confirmed = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.easeOut(duration: 0.25)) { confirmed = false }
            }
        } label: {
            Image(systemName: confirmed ? "checkmark" : icon)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(confirmed ? Tokens.text2 : Tokens.text3)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Rest → row hover → direct hover/checkmark: 0.25 → 0.7 → 1.
        .opacity(confirmed || hovering ? 1.0 : rowHovered ? 0.7 : 0.25)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
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
            .notchTooltip(L("source.badge.help"))
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
        // Cap the visible height at `visibleRows` rows; shorter lists size down to
        // their own content (no empty space, no scroll). Computing the height
        // explicitly — rather than letting `.fixedSize` measure it — lets the
        // ScrollView scroll the overflow once there are more rows than fit.
        let shownRows = CGFloat(min(sources.count, Self.visibleRows))
        let visibleHeight = max(0, shownRows * Self.rowHeight + (shownRows - 1) * Self.rowSpacing)
        let scrolls = sources.count > Self.visibleRows
        ScrollView(.vertical, showsIndicators: scrolls) {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(sources) { source in
                    SourceRow(source: source)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: visibleHeight)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        // A fixed width gives the rows a definite bound to truncate long titles
        // against (instead of stretching the popup to the longest line).
        .frame(width: 380, alignment: .leading)
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
