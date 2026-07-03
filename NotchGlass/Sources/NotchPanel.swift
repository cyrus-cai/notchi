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
    /// Level while a text field is actively being edited. The macOS input-method
    /// candidate window (the pinyin/kana/Hangul selection popup) is drawn by the
    /// input server ABOVE normal app windows but BELOW a `.statusBar` overlay — so at
    /// the resting level it gets covered or clipped by the island, making CJK input
    /// unusable. `.floating` keeps the island above ordinary windows yet below the
    /// candidate window, so the selection popup shows through while editing. Restored
    /// to `restingLevel` the moment editing ends.
    static let editingLevel: NSWindow.Level = .floating

    /// How many field editors are currently composing/editing. The island can host
    /// more than one IME field (prompt + history search), so ref-count rather than a
    /// bool — the level only climbs back to resting once the LAST one ends.
    private var activeEditors = 0

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

        // Show on top of full-screen apps and follow the user across Spaces.
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
    }

    // A borderless panel returns false by default; allow it so the prompt field
    // can become first responder when the user types into the glass.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A field editor started composing/editing — drop to `editingLevel` so the IME
    /// candidate window can show above the island. Idempotent across multiple fields
    /// via the ref-count. Call its `endFieldEditing()` counterpart on end-editing.
    func beginFieldEditing() {
        activeEditors += 1
        if level != Self.editingLevel { level = Self.editingLevel }
    }

    /// A field editor stopped editing. Once the last active editor ends, climb back
    /// to the resting level so the island again floats above the menu bar at rest.
    func endFieldEditing() {
        activeEditors = max(0, activeEditors - 1)
        if activeEditors == 0 { restRestingLevel() }
    }

    /// Force the island back to its resting level and clear the editing ref-count.
    /// Called on panel close (and key-resign) so a missed end-editing notification —
    /// e.g. the panel closing mid-composition — can never strand it at `editingLevel`,
    /// where it would sit below other windows at rest.
    func restRestingLevel() {
        activeEditors = 0
        if level != Self.restingLevel { level = Self.restingLevel }
    }
}
