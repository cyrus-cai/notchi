import AppKit

/// A borderless, transparent, always-on-top panel that hosts the notch UI.
///
/// It deliberately behaves like a system overlay rather than a normal window:
///  · no title bar / no shadow drawn by AppKit (the glass draws its own)
///  · transparent background so only the SwiftUI glass form is visible
///  · floats above every app and joins every Space / full-screen app
///  · non-activating as a *style*, so a stray click on the glass never activates
///    the app by itself (it can still receive key events via `canBecomeKey`).
///    App activation is driven deliberately by the AppDelegate open/close path
///    instead — the panel must belong to the *focused application* while open,
///    or AX-based voice/dictation tools (Typeless & co.) can't reach its fields.
final class NotchPanel: NSPanel {
    /// Resting level: above the menu bar and every normal window, where the island
    /// belongs when it isn't being typed into.
    static let restingLevel: NSWindow.Level = .statusBar
    /// Level while an IME composition is in flight. The macOS input-method
    /// candidate window (the pinyin/kana/Hangul selection popup) is drawn by the
    /// input server at window layer 20 — ABOVE normal app windows but BELOW both the
    /// menu bar (24) and a `.statusBar` overlay (25) — so at the resting level it
    /// gets covered or clipped by the island, making CJK input unusable. `.floating`
    /// keeps the island above ordinary windows yet below the candidate window, so the
    /// selection popup shows through.
    ///
    /// It is **only** used while marked text actually exists (see `setComposing`).
    /// Anything below layer 24 is also below the menu bar, so while the island sits
    /// here macOS draws the menu bar — its titles and its item chips — straight over
    /// the island's black notch cap, and the top of the "notch" visibly comes apart.
    /// That used to happen on the FIRST keystroke of every editing session (NSTextView
    /// posts `textDidBeginEditing` on the first edit, not on focus) and lasted until
    /// the caret left, which is what the "typing pulls a gap open at the top of the
    /// notch" report was. There is no level that clears the menu bar *and* stays under
    /// the candidate window, so the drop is now scoped to the moments that need it:
    /// a live composition, when the popup is on screen and the eye is on it anyway.
    static let editingLevel: NSWindow.Level = .floating

    /// How many field editors currently hold the caret. The island can host more than
    /// one IME field (prompt + history search), so ref-count rather than a bool — the
    /// last one ending is what clears any leftover composition state.
    private var activeEditors = 0

    /// Whether a field editor is mid-composition right now (marked text present).
    /// This — not merely having the caret — is what puts the island at
    /// `editingLevel`.
    private var composing = false

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = Self.restingLevel              // above menu bar / normal windows
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titlebarAppearsTransparent = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false

        // The island's surface is dark glass no matter what the Mac's appearance
        // is, so pin the panel to dark: every AppKit-drawn control inside (the
        // update spinner, switches, menus) then paints with its dark-mode ink
        // instead of following the system into light mode and vanishing.
        appearance = NSAppearance(named: .darkAqua)

        // Show on top of full-screen apps and follow the user across Spaces.
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
    }

    /// Keep the frame exactly where we put it. The canvas deliberately reaches a
    /// few points ABOVE the screen's top edge (see
    /// `AppDelegate.canvasTopOverreach`) so the screen's very top row routes to
    /// this window instead of falling through; AppKit's default constraining
    /// would pull that strip back down onto the visible frame and undo it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    // A borderless panel returns false by default; allow it so the prompt field
    // can become first responder when the user types into the glass.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A field editor took the caret. The LEVEL deliberately doesn't move here —
    /// editing alone doesn't summon a candidate window, and dropping below the menu
    /// bar for a whole typing session is what tore the notch's top open (see
    /// `editingLevel`). Call its `endFieldEditing()` counterpart on end-editing.
    func beginFieldEditing() {
        activeEditors += 1
    }

    /// A field editor stopped editing. Once the last one ends, any composition it was
    /// holding is over too, so the island climbs back above the menu bar.
    func endFieldEditing() {
        activeEditors = max(0, activeEditors - 1)
        if activeEditors == 0 { restRestingLevel() }
    }

    /// The composition gate: `true` while the focused field holds marked text (the
    /// candidate window is up, or about to be), `false` the moment it commits. Called
    /// on every storage edit, so it must stay cheap and idempotent — it only touches
    /// `level` when the state actually flips.
    func setComposing(_ isComposing: Bool) {
        guard composing != isComposing else { return }
        composing = isComposing
        let want = isComposing ? Self.editingLevel : Self.restingLevel
        if level != want { level = want }
    }

    /// Force the island back to its resting level and clear the editing ref-count.
    /// Called on panel close (and key-resign) so a missed end-editing notification —
    /// e.g. the panel closing mid-composition — can never strand it at `editingLevel`,
    /// where it would sit below the menu bar and other windows at rest.
    func restRestingLevel() {
        activeEditors = 0
        composing = false
        if level != Self.restingLevel { level = Self.restingLevel }
    }
}
