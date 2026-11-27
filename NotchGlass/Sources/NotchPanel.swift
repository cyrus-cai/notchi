import AppKit
import Carbon

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
    /// Resting level of a top-right card (the menu bar card and corner panels).
    /// Notification Center draws its banners at window layer 23; the card sits
    /// one below it so a banner shows over the card. The card hangs under the
    /// menu bar (24), so it does not need to clear it.
    static let cardLevel = NSWindow.Level(rawValue: 22)
    /// This panel's resting level: `restingLevel` for a notch, `cardLevel` for
    /// a card. Set by `AppDelegate.position`.
    private(set) var restLevel: NSWindow.Level = NotchPanel.restingLevel

    func setRestLevel(_ newValue: NSWindow.Level) {
        guard restLevel != newValue else { return }
        restLevel = newValue
        if !composing { level = newValue }
    }
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
    /// No level clears the menu bar *and* stays under the candidate window, so the
    /// drop is scoped to a live composition, when the popup is on screen anyway —
    /// not to the whole editing session.
    static let editingLevel: NSWindow.Level = .floating

    /// How many field editors currently hold the caret. The island can host more than
    /// one IME field (prompt + history search), so ref-count rather than a bool — the
    /// last one ending is what clears any leftover composition state.
    private var activeEditors = 0

    /// Whether a field editor is mid-composition right now (marked text present).
    /// This — not merely having the caret — is what puts the island at
    /// `editingLevel`.
    private var composing = false

    /// Climb-back from `editingLevel` is delayed so a CJK syllable commit does
    /// not briefly uncover the menu bar before the next pinyin letter marks text
    /// again. Without this the bar strobes in and out of the notch cap between
    /// every character. Dropping under a live candidate is still immediate.
    private var restAfterComposition: DispatchWorkItem?
    private static let compositionRestDelay: TimeInterval = 0.55

    /// A mouse-down landed inside the panel. The AppDelegate answers it by
    /// giving this panel the keyboard (and activating the app) when it doesn't
    /// already hold it.
    ///
    /// The panel is `.nonactivatingPanel` and its canvas takes first mouse, so a
    /// click on the open island is DELIVERED without the app ever coming
    /// forward: buttons work, but every keyboard chord the panel owns stays
    /// dead, because key events go to whatever app is actually active.
    /// Clicking the open island is deliberate engagement, so it claims the
    /// keyboard the way clicking any window does.
    var onClickInside: (() -> Void)?

    /// A double-click landed on the panel's blank glass: not on a button, a
    /// menu, an input or selectable text. The AppDelegate pins the
    /// open panel in answer.
    var onDoubleClickInside: (() -> Void)?

    /// When a control that should not pin on a double-click last fired. A
    /// SwiftUI button has no AppKit view of its own for `sendEvent` to hit-test,
    /// so the button records its own action here instead; the second press of
    /// the pair, arriving within the double-click interval, then skips the pin.
    private static var doubleClickExemptAt: TimeInterval = 0

    /// Called from such a control's action.
    static func exemptNextDoubleClick() {
        doubleClickExemptAt = ProcessInfo.processInfo.systemUptime
    }

    /// Whether `event`, the second press of a double-click, must not pin.
    /// True when a control reported its own press (`exemptNextDoubleClick`),
    /// when the first press of the pair was not in this window, or when either
    /// press landed on a control (`DoubleClickPress`).
    static func doubleClickIsExempt(_ event: NSEvent) -> Bool {
        if event.timestamp - doubleClickExemptAt <= NSEvent.doubleClickInterval { return true }
        guard let window = event.window else { return true }
        return DoubleClickPress.pairTouchesControl(event, in: window)
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = Self.restingLevel
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

    // AppKit draws Liquid Glass and vibrancy in the inactive (flat grey) state
    // when the window loses key or Notchi goes to the background. The panel
    // keeps the active look at all times. Private NSWindow selectors.
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }

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
    /// `level` when the state actually flips. A `false` is held for
    /// `compositionRestDelay` so consecutive IME syllables do not bounce the island
    /// above the menu bar between commits.
    func setComposing(_ isComposing: Bool) {
        if isComposing {
            restAfterComposition?.cancel()
            restAfterComposition = nil
            applyComposing(true)
            return
        }
        guard composing || restAfterComposition != nil else { return }
        restAfterComposition?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restAfterComposition = nil
            self.applyComposing(false)
        }
        restAfterComposition = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.compositionRestDelay,
                                      execute: work)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if SelectableTextCopy.copyIfNeeded(event, in: self) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        SelectableTextCopy.note(event, in: self)
        // Before `onClickInside`, so the handler still sees the state recorded
        // at the first click of the pair.
        if event.type == .leftMouseDown, event.clickCount == 2,
           !Self.doubleClickIsExempt(event),
           !isOverControlOrText(event.locationInWindow) {
            onDoubleClickInside?()
        }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            onClickInside?()
        default:
            break
        }
        if event.type == .rightMouseDown, showAnswerMenuOverSelectableText(event) { return }
        super.sendEvent(event)
    }

    /// Force the island back to its resting level and clear the editing ref-count.
    /// Called on panel close (and key-resign) so a missed end-editing notification —
    /// e.g. the panel closing mid-composition — can never strand it at `editingLevel`,
    /// where it would sit below the menu bar and other windows at rest.
    func restRestingLevel() {
        restAfterComposition?.cancel()
        restAfterComposition = nil
        activeEditors = 0
        composing = false
        if level != restLevel { level = restLevel }
    }

    private func applyComposing(_ isComposing: Bool) {
        guard composing != isComposing else { return }
        composing = isComposing
        let want = isComposing ? Self.editingLevel : restLevel
        if level != want { level = want }
    }
}

// MARK: - Selectable text

/// ⌘C for SwiftUI's `.textSelection(.enabled)` text.
///
/// The Edit menu sends `copy:` to the first responder. After a drag-select in
/// an answer, focus can move back to the prompt field (the panel refocuses it),
/// so `copy:` reaches an empty field while the answer still shows its
/// selection, and nothing is copied. Each window records the selectable text
/// view the last press landed in, and ⌘C copies from that view unless an
/// editable field has a selection of its own.
enum SelectableTextCopy {
    private static weak var lastPressed: NSView?

    /// Call from `sendEvent` for every event.
    static func note(_ event: NSEvent, in window: NSWindow) {
        MainActor.assumeIsolated { SelectionQuote.note(event, in: window) }
        guard event.type == .leftMouseDown else { return }
        lastPressed = window.selectableTextView(at: event.locationInWindow)
    }

    /// Call from `performKeyEquivalent`. True when it copied.
    static func copyIfNeeded(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.keyCode == UInt16(kVK_ANSI_C)
                || event.charactersIgnoringModifiers?.lowercased() == "c" else { return false }
        if let field = window.firstResponder as? NSTextView,
           field.selectedRange().length > 0 { return false }
        guard let view = lastPressed, view.window === window else { return false }
        let before = NSPasteboard.general.changeCount
        NSApp.sendAction(#selector(NSText.copy(_:)), to: view, from: nil)
        return NSPasteboard.general.changeCount != before
    }
}

// MARK: - Quote from a selection

/// A window whose replies can carry a quote picked out of its selectable text.
protocol SelectionQuoteTarget: AnyObject {
    /// Nil when the window has nothing to reply into right now.
    var onQuoteSelection: ((String) -> Void)? { get }
}

/// Right-click on selected answer text adds "Quote" to the top of the system
/// text menu. The item sets the window's next reply to the selected text.
@MainActor
enum SelectionQuote {
    private static weak var pressedView: NSView?
    private static weak var pressedWindow: NSWindow?
    private static var pressedAt = Date.distantPast
    private static var installed = false
    /// Used by windows that are not a `SelectionQuoteTarget` (the notch panel
    /// and the menu bar card): replies into the live thread.
    static var fallback: (() -> ((String) -> Void)?)?

    /// Call from `sendEvent` for every event.
    static func note(_ event: NSEvent, in window: NSWindow) {
        let secondary = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard secondary else { return }
        installIfNeeded()
        pressedView = window.selectableTextView(at: event.locationInWindow)
        pressedWindow = window
        pressedAt = Date()
    }

    private static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { note in
            guard let menu = note.object as? NSMenu else { return }
            MainActor.assumeIsolated { decorate(menu) }
        }
    }

    /// The selection under the right-click that opened the menu on screen,
    /// for the answer menu's own Quote item (`takeMenuSelection`).
    private static var menuSelection: String?

    /// The selected text the open menu was raised over, once.
    static func takeMenuSelection() -> String? {
        defer { menuSelection = nil }
        return menuSelection
    }

    private static func decorate(_ menu: NSMenu) {
        defer { pressedView = nil }
        guard menu.supermenu == nil else { return }
        menuSelection = nil
        if let view = pressedView, Date().timeIntervalSince(pressedAt) < 1 {
            menuSelection = selectedText(in: view)
        }
        // The answer bubble's menu has its own Quote.
        guard !menu.items.contains(where: { $0.title == L("message.quote") }) else { return }
        guard let view = pressedView, let window = pressedWindow,
              Date().timeIntervalSince(pressedAt) < 1,
              !menu.items.contains(where: { $0.representedObject as? String == itemTag })
        else { return }
        trimTextMenu(menu)
        guard let handler = (window as? SelectionQuoteTarget)?.onQuoteSelection
                ?? (window is SelectionQuoteTarget ? nil : fallback?()),
              let text = selectedText(in: view) else { return }
        let item = NSMenuItem(title: L("message.quote"),
                              action: #selector(QuoteAction.run(_:)), keyEquivalent: "")
        item.target = QuoteAction.shared
        item.representedObject = itemTag
        item.image = NSImage.icon("text.quote")
        QuoteAction.shared.pending = { handler(text) }
        menu.insertItem(item, at: 0)
        if menu.items.count > 1 { menu.insertItem(.separator(), at: 1) }
    }

    /// The system text menu over answer text keeps Look Up, Translate and
    /// Copy. Cut, Paste, Share, Font, Spelling, Services and the rest do
    /// nothing useful on text that cannot be edited.
    private static func trimTextMenu(_ menu: NSMenu) {
        func keeps(_ item: NSMenuItem) -> Bool {
            guard let action = item.action else { return false }
            if action == #selector(NSText.copy(_:)) { return true }
            let name = NSStringFromSelector(action).lowercased()
            return name.contains("lookup") || name.contains("translat")
        }
        let lookups = menu.items.filter { keeps($0) && $0.action != #selector(NSText.copy(_:)) }
        let copies = menu.items.filter { $0.action == #selector(NSText.copy(_:)) }
        menu.removeAllItems()
        lookups.forEach { menu.addItem($0) }
        if !lookups.isEmpty, !copies.isEmpty { menu.addItem(.separator()) }
        copies.forEach { menu.addItem($0) }
    }

    private static let itemTag = "notchi.quoteSelection"

    /// The selection, read through the Services path the text view already
    /// answers ("Search With Google"), into a private pasteboard so the user's
    /// clipboard is left alone.
    private static func selectedText(in view: NSView) -> String? {
        let selector = #selector(NSServicesMenuRequestor.writeSelection(to:types:))
        guard view.responds(to: selector),
              let imp = view.method(for: selector) else { return nil }
        typealias Write = @convention(c) (AnyObject, Selector, NSPasteboard, NSArray) -> Bool
        let write = unsafeBitCast(imp, to: Write.self)
        let board = NSPasteboard(name: NSPasteboard.Name("notchi.quoteSelection"))
        board.clearContents()
        guard write(view, selector, board, [NSPasteboard.PasteboardType.string] as NSArray),
              let raw = board.string(forType: .string) else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let limit = NotchModel.replyQuoteLimit
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private final class QuoteAction: NSObject {
        static let shared = QuoteAction()
        var pending: (() -> Void)?
        @objc func run(_ sender: Any?) {
            let action = pending
            pending = nil
            DispatchQueue.main.async { action?() }
        }
    }
}

extension NSWindow {
    /// The view SwiftUI puts behind `.textSelection(.enabled)` text at this
    /// window point, if any. It is an `AppKitTextInteractionView`, which neither
    /// `hitTest` returns (the hosting view answers for it) nor subclasses
    /// `NSText`, so it is found by class name and frame.
    func selectableTextView(at windowPoint: NSPoint) -> NSView? {
        guard let content = contentView else { return nil }
        func search(_ view: NSView) -> NSView? {
            for sub in view.subviews where !sub.isHidden {
                if NSStringFromClass(type(of: sub)).contains("TextInteractionView"),
                   sub.convert(sub.bounds, to: nil).contains(windowPoint) {
                    return sub
                }
                if let found = search(sub) { return found }
            }
            return nil
        }
        return search(content)
    }

    func isOverEditableText(_ point: NSPoint) -> Bool {
        guard let contentView,
              var view = contentView.hitTest(contentView.convert(point, from: nil)) else { return false }
        while true {
            if let text = view as? NSText, text.isEditable { return true }
            if let field = view as? NSTextField, field.isEditable { return true }
            guard let parent = view.superview else { return false }
            view = parent
        }
    }

    /// Whether this window point is on an AppKit control, a text view, or
    /// SwiftUI's selectable text. A double-click there belongs to that view.
    func isOverControlOrText(_ point: NSPoint) -> Bool {
        if selectableTextView(at: point) != nil { return true }
        guard let contentView,
              var view = contentView.hitTest(contentView.convert(point, from: nil)) else { return false }
        while true {
            // An editable text view takes the double-click only where it has
            // a word to select. Its empty area, and an empty field, are glass.
            if let tv = view as? NSTextView, tv.isEditable {
                return Self.textView(tv, hasGlyphAt: tv.convert(point, from: nil))
            }
            if view is NSControl || view is NSText { return true }
            guard let parent = view.superview else { return false }
            view = parent
        }
    }

    private static func textView(_ tv: NSTextView, hasGlyphAt point: NSPoint) -> Bool {
        guard !tv.string.isEmpty, let layout = tv.layoutManager,
              let container = tv.textContainer else { return false }
        let origin = tv.textContainerOrigin
        let p = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layout.glyphIndex(for: p, in: container)
        guard glyph < layout.numberOfGlyphs else { return false }
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                       in: container)
        return rect.insetBy(dx: -2, dy: -2).contains(p)
    }

    /// A right-click on selectable text goes to the text view, which shows the
    /// system text menu (Cut / Copy / Paste / Font…) instead of the
    /// `.contextMenu` the answer declares. With no selection that menu's Copy is
    /// disabled, so this shows the SwiftUI menu at that point instead. With a
    /// selection the system menu stays, since its Copy copies the selection.
    /// Returns true when it showed a menu.
    func showAnswerMenuOverSelectableText(_ event: NSEvent) -> Bool {
        guard let textView = selectableTextView(at: event.locationInWindow) else { return false }
        if firstResponder === textView, let systemMenu = textView.menu(for: event) {
            systemMenu.update()
            if systemMenu.items.contains(where: {
                $0.action == #selector(NSText.copy(_:)) && $0.isEnabled
            }) { return false }
        }
        var host = textView.superview
        while let view = host, !NSStringFromClass(type(of: view)).contains("HostingView") {
            host = view.superview
        }
        guard let host, let menu = host.menu(for: event), !menu.items.isEmpty else { return false }
        NSMenu.popUpContextMenu(menu, with: event, for: host)
        return true
    }
}



// MARK: - Double-click on a control

/// Decides whether a double-click landed on a control, for every window that
/// pins on a double-click. A SwiftUI control has no AppKit view for `hitTest`
/// to return, so it is found through the accessibility tree instead, which
/// SwiftUI builds for every button, toggle, picker, slider, field and link.
/// No control has to opt in.
enum DoubleClickPress {
    private struct Press {
        let window: Int
        let location: NSPoint
        let timestamp: TimeInterval
    }

    /// The press before the current one, and the current one. Recorded by a
    /// local monitor, so a press in any of the app's windows (a menu card
    /// included) counts as the first half of a pair.
    private static var previous: Press?
    private static var current: Press?
    private static var monitor: Any?

    /// Installs the press recorder. Called once at launch.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            previous = current
            current = Press(window: event.windowNumber,
                            location: event.locationInWindow,
                            timestamp: event.timestamp)
            return event
        }
    }

    private static let controlRoles: Set<NSAccessibility.Role> = [
        .button, .popUpButton, .menuButton, .checkBox, .radioButton, .slider,
        .textField, .textArea, .comboBox, .link, .menuItem, .menuBarItem,
        .incrementor, .disclosureTriangle, .colorWell, .scrollBar, .tabGroup,
        .radioGroup, .valueIndicator, .handle,
    ]

    /// True when the pair should not pin: its first press was in another
    /// window, or either press is on a control.
    static func pairTouchesControl(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let first = previous,
              first.window == event.windowNumber,
              event.timestamp - first.timestamp <= NSEvent.doubleClickInterval
        else { return true }
        return isControl(at: event.locationInWindow, in: window)
            || isControl(at: first.location, in: window)
    }

    /// Whether the accessibility element under `point` (window coordinates),
    /// or one of its few nearest ancestors, is a control.
    static func isControl(at point: NSPoint, in window: NSWindow) -> Bool {
        guard let content = window.contentView else { return false }
        let screen = window.convertPoint(toScreen: point)
        var element = content.accessibilityHitTest(screen)
        // A button's label can come back as its own static text; the button is
        // a level or two up. Stop at the hosting view: above it is the window.
        for _ in 0..<4 {
            guard let node = element as? NSAccessibilityProtocol else { return false }
            if let role = node.accessibilityRole(), controlRoles.contains(role) { return true }
            if node === content { return false }
            element = node.accessibilityParent()
        }
        return false
    }
}
