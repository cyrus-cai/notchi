import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A lossless-enough snapshot of the current pasteboard for a temporary
/// replace-selection paste. Every eagerly readable representation is retained;
/// restoration is skipped if another app changes the pasteboard in the meantime.
private struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        _ = pasteboard.writeObjects(restored)
    }
}

// MARK: - What a detached window holds

/// One session torn out of the notch into its own window: a chat thread (Ask, or
/// a reopened agent-run thread) identified by its history id, a live agent task
/// identified by its `AgentTaskManager` id, or — with no session at all — the
/// idle prompt itself, torn out as a standalone composer. `.compose` carries no
/// id on purpose: it is the one page there can only ever be one of, so a second
/// tear-off focuses the composer already open instead of forking a twin. Sending
/// its first question promotes it to `.thread` in place (see `adoptThread`).
enum DetachedSession: Equatable {
    case compose
    /// A prompt shortcut with no saved instruction: the selection is already
    /// captured, and this compact face asks only for the one-off instruction.
    case shortcutComposer(id: UUID)
    case thread(id: UUID)
    case agentTask(id: UUID)

    var threadID: UUID? { if case .thread(let id) = self { return id }; return nil }
    var taskID: UUID?   { if case .agentTask(let id) = self { return id }; return nil }
}

/// The face the tear-off card wears — computed once at detach time so the ghost
/// in the canvas and the newborn window render the exact same card.
struct DetachedCardFace: Equatable {
    var title: String
    var subtitle: String
    var isAgent: Bool
    var running: Bool
}

/// Live mirror of a detached thread. While its round still streams, `NotchModel`
/// pushes every snapshot here (see `syncInFlight`/`persistThread`), so the
/// window keeps writing in real time even though the thread left the panel.
/// Deliberately its own tiny store: streaming-cadence updates invalidate only
/// the one window observing it, never the panel tree.
@MainActor
final class DetachedThreadStore: ObservableObject {
    /// Mutable because a regenerate on a single-pair thread re-ids it (the
    /// panel pipeline treats the emptied seed as a fresh thread) — the model
    /// re-keys this mirror to the new id so the window keeps following.
    var threadID: UUID
    @Published var turns: [NotchModel.Turn]
    @Published var agentFolderPath: String?
    @Published var completedAt: Date?
    /// Whether this thread's next destination can receive image input. Agent
    /// records follow their persisted CLI engine; ordinary Ask threads follow
    /// the active chat model at the moment the window is created.
    let followUpSupportsImages: Bool

    init(threadID: UUID, turns: [NotchModel.Turn],
         agentFolderPath: String? = nil, completedAt: Date? = nil,
         followUpSupportsImages: Bool = false) {
        self.threadID = threadID
        self.turns = turns
        self.agentFolderPath = agentFolderPath
        self.completedAt = completedAt
        self.followUpSupportsImages = followUpSupportsImages
    }

    /// The round finished (persisted to Recent) — freeze the mirror: no caret,
    /// no stale "searching…" line.
    func settle(with thread: [NotchModel.Turn]) {
        var cleaned = thread
        for i in cleaned.indices {
            cleaned[i].streaming = false
            cleaned[i].toolActivity = nil
            cleaned[i].thinkingStartedAt = nil
            cleaned[i].pendingQuestion = nil
        }
        turns = cleaned
    }
}

/// The detached window itself: borderless (the glass draws its own rounded
/// form — the system titlebar backdrop kept flashing against the glass and its
/// corner mask doesn't apply to transparent windows), but still key/main so
/// the follow-up field and shortcuts work. `.resizable` in the mask keeps
/// AppKit's edge-resize on a borderless window.
private final class DetachedWindow: NSWindow {
    var closesOnEscape = false
    /// The app's editable chords (⌘P pin, ⌘C copy, ⌘R regenerate — see
    /// `DetachedSessionWindowController.handleAppShortcut`). A detached window is
    /// its own key window, so the panel's `KeyEventCatcher` — which only acts
    /// while ITS window is key — never sees these keys; the window has to answer
    /// them itself, or its chips would advertise chords that do nothing here.
    /// Returns true when the chord was claimed.
    var onAppShortcut: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Where the press that may become a move started: the pointer on screen and
    /// the window's own corner, both frozen at mouse-down.
    private var dragAnchor: (mouse: NSPoint, origin: NSPoint)?
    /// The press has travelled far enough to be a move rather than a click.
    private var dragging = false
    /// How far it has to travel first, so a tap on a SwiftUI button is still a
    /// tap — SwiftUI draws its controls, it does not give them AppKit views, so
    /// a press on one is indistinguishable from a press on bare glass until it
    /// moves.
    private static let dragSlop: CGFloat = 4

    /// Move the window from here, rather than leaving it to
    /// `isMovableByWindowBackground`.
    ///
    /// That flag is worse than useless here, and `makeWindow` turns it OFF. The
    /// card's content is one `NSHostingView`, which answers
    /// `mouseDownCanMoveWindow = true` for every point SwiftUI merely draws, so
    /// the window server claimed those presses for its own background drag and
    /// then moved nothing. The same mechanism made the earlier grab view
    /// (`WindowDragArea`, now gone) carve two dead strips instead of a handle.
    ///
    /// So the move is explicit: the press is watched here, and once it travels,
    /// the window follows the pointer by hand. Nothing about it depends on which
    /// view SwiftUI decided to put where.
    ///
    /// The other half of "a press lands here at all" is upstream of AppKit. A
    /// borderless window that isn't opaque gets an INPUT REGION, and a press
    /// outside it is routed to whatever app is behind the window — the app never
    /// hears about it. A view that opts out of SwiftUI hit testing is left out of
    /// that region no matter how solidly it draws, which is what a
    /// `.allowsHitTesting(false)` on the card's own glass cost: the card was a
    /// hole everywhere except its input recess and the rows' focus proxies, so it
    /// could be picked up by the input line and nowhere else. Measured, on this
    /// exact window shape: glass + 30% black, opted out → the press goes to the
    /// app behind; the same pixels left hit-testable → the press arrives. The
    /// glass is the card's surface; it takes the press.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragging = false
            dragAnchor = pressIsOnBareGlass(event)
                ? (NSEvent.mouseLocation, frame.origin) : nil
        case .leftMouseDragged:
            if let anchor = dragAnchor {
                let now = NSEvent.mouseLocation
                let dx = now.x - anchor.mouse.x
                let dy = now.y - anchor.mouse.y
                if dragging || hypot(dx, dy) > Self.dragSlop {
                    dragging = true
                    setFrameOrigin(NSPoint(x: anchor.origin.x + dx,
                                           y: anchor.origin.y + dy))
                    // The press is carrying the window; the content must not also
                    // read it as a gesture of its own.
                    return
                }
            }
        case .leftMouseUp:
            let wasDragging = dragging
            dragging = false
            dragAnchor = nil
            if wasDragging { return }
        default:
            break
        }
        super.sendEvent(event)
    }

    /// Did this press land on the card's own surface rather than on something
    /// that wants it?
    ///
    /// Asked as a deny-list, not an allow-list. The card's hierarchy is mostly
    /// SwiftUI, which backs almost nothing with an AppKit view — but not
    /// nothing: SwiftUI wraps every representable in a plain host view. Listing
    /// the views that DO count as glass silently turns each of those into a dead
    /// patch the window will not move from.
    ///
    /// What actually wants a press is narrow and nameable: something that edits
    /// text or acts as a control. The prompt field keeps its caret and its
    /// selection, the answer keeps its selectable text, and every other pixel —
    /// known or not — carries the window.
    private func pressIsOnBareGlass(_ event: NSEvent) -> Bool {
        guard let content = contentView else { return false }
        let point = content.superview?.convert(event.locationInWindow, from: nil)
            ?? event.locationInWindow
        guard let hit = content.hitTest(point) else { return true }
        // Up the chain, not just the leaf: a press inside a field's inner clip
        // view still belongs to the field.
        var view: NSView? = hit
        while let v = view, v !== content {
            if v is NSControl || v is NSText { return false }
            view = v.superview
        }
        return true
    }

    /// LSUIElement app: there is no menu-bar Close item to catch ⌘W, so the
    /// window answers the equivalent itself — same path as the close chip.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if closesOnEscape,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           event.charactersIgnoringModifiers == "\u{1b}" {
            close()
            return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        if onAppShortcut?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Window controller

/// The exact spring used by the main-flow Recent module. The compact Force
/// Touch drawer shares it for its shell, rows, and disclosure glyph so the whole
/// interaction has one gravity/rebound signature.
private enum CompactHistoryMotion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.78)
    /// The reveal's backstop window (see `animateCompactHeight`): the frame
    /// normally lands on the spring's own completion, and this only covers a
    /// reveal that never reports.
    static let settleDuration: TimeInterval = 0.70
}

/// One controller per detached window. Born either mid-drag (`beginDragDetach`,
/// the tear-off path: a borderless-looking card that rides the mouse until
/// release, then settles into a full window) or directly (`present`, the V0
/// button path: the same settle morph, just without the ride).
@MainActor
final class DetachedSessionWindowController: NSObject, NSWindowDelegate {
    /// Every open detached window, so a second detach of the same session
    /// focuses the existing window instead of forking a twin.
    private static var controllers: [DetachedSessionWindowController] = []

    static func controller(for session: DetachedSession) -> DetachedSessionWindowController? {
        controllers.first { $0.session == session }
    }

    /// What this window holds *right now* — a composer can become a thread
    /// mid-life, so it lives in the observable state and every reader (the merge
    /// zone, the twin check, the root view) goes through here.
    var session: DetachedSession { state.session }
    private var threadStore: DetachedThreadStore? { state.threadStore }
    private let face: DetachedCardFace
    private weak var model: NotchModel?
    private var window: NSWindow!
    private let state: DetachedWindowState
    /// Prompt-shortcut results use the same live thread machinery, but wear a
    /// smaller pointer-side shell whose height follows the answer.
    private let compactShortcut: Bool
    /// Quick actions operate on captured text, so an invocation without a real
    /// selection is born at the input-only height instead of opening empty space
    /// that the first SwiftUI layout immediately has to remove.
    private var composerRestingHeight: CGFloat {
        CompactShortcutPromptView.restingHeight(
            withPicks: !state.compactSourceText
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    /// Stable identity of the prompt binding that owns a compact window. Its
    /// thread id changes on each invocation; this id keeps the shell singular.
    private let compactShortcutID: UUID?
    /// The app that owned the selected text when the shortcut fired. Updated on
    /// every invocation because one shortcut window may be reused across apps.
    private var replacementApplication: NSRunningApplication?
    /// The pointer this composer was summoned at — kept so the first real layout
    /// can put the caret exactly on it (`alignCaret`), rather than leaving the
    /// window wherever the pre-layout estimate guessed.
    private var summonPointer: NSPoint?
    /// How long after a pointer-side window opens a resign-key is read as the
    /// echo of the gesture that summoned it rather than as the user leaving.
    private static let summonGrace: TimeInterval = 0.6
    /// Until when that applies — see `armSummonGrace`.
    private var summonGraceUntil: Date?
    /// Polls the button that is still holding the summoning press down.
    private var summonReleaseTimer: Timer?
    /// Key has already been taken back once for the current grace.
    private var reclaimedAfterSummon = false
    /// Streaming Markdown can briefly report a shorter layout while a token is
    /// being reclassified or SwiftUI catches up with AppKit's text estimate.
    /// Keep the tallest accepted height for this round so those transient
    /// measurements cannot pull the window back and forth.
    private var compactRoundHeight: CGFloat = CompactShortcutPromptView.restingHeight
    /// The height this round is pinned to until it has an answer to open for —
    /// the waiting card for a shortcut that opens straight into one, the
    /// composer's own height for a round the user typed
    /// (`submitCompactShortcutPrompt`). Thinking never moves the window.
    private var compactFloorHeight: CGFloat =
        DetachedSessionWindowController.compactInitialHeight
    /// The live glide that opens the window as the answer lands: where it's
    /// headed, the tick that takes it there, and when that tick last ran.
    private var compactTargetHeight: CGFloat = 0
    private var compactGlideTimer: Timer?
    private var compactGlideAt: TimeInterval = 0
    private var compactRevealCompletion: DispatchWorkItem?
    private var compactRevealGeneration = 0
    /// A History disclosure is one discrete resize, unlike streaming answer
    /// growth. It gets a dedicated top-locked animation instead of borrowing
    /// the answer glide while SwiftUI is animating the rows too.
    private var animateForceTouchHistoryResize = false
    /// Tracks the empty/non-empty boundary of the compact prompt. Crossing it
    /// folds or restores the quick actions, so that one height change gets the
    /// same discrete top-locked animation as History instead of a hard resize.
    private var compactPromptWasEmpty = true

    /// Mid-drag machinery (tear-off path only).
    private var dragMonitor: Any?
    private var grabOffset = NSPoint.zero          // mouse → window-origin delta, keeps the grip point
    private var lastMouse = NSPoint.zero
    private var lastMouseAt: TimeInterval = 0

    /// Merge-back machinery (settled phase).
    private var moveObserver: NSObjectProtocol?
    private var mergeArmed = false

    /// This window has held the keyboard at least once. The empty-composer
    /// dismissal below hangs off *losing* key, and a window that never got it
    /// (the activation lost a race with the source app) must not be closed by
    /// the resign that never had a matching become.
    private var hasHeldKey = false

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: Entry points

    /// V0 (the header button): open (or focus) the session's window, fading in
    /// right where the panel is — the full window from frame one, no thumbnail
    /// stage.
    static func present(session: DetachedSession, face: DetachedCardFace,
                        model: NotchModel, from spawnRect: NSRect?) {
        if let existing = controller(for: session) {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let c = DetachedSessionWindowController(session: session, face: face, model: model)
        controllers.append(c)
        c.makeWindow(at: spawnRect ?? c.centeredDefaultRect(), model: model)
        if reduceMotion {
            c.window.alphaValue = 1
        } else {
            c.window.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                c.window.animator().alphaValue = 1
            }
        }
        c.state.phase = .settled
        c.finishSettle()
    }

    /// V1: the tear-off crossed its threshold mid-drag. The COMPLETE window is
    /// born in place over the panel — full size, full session content — and
    /// rides the mouse until release. No intermediate card: what's under the
    /// hand IS the window.
    static func beginDragDetach(session: DetachedSession, face: DetachedCardFace,
                                model: NotchModel, spawnRect: NSRect) {
        if let existing = controller(for: session) {
            // Already windowed (shouldn't normally arm, but never fork a twin).
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let c = DetachedSessionWindowController(session: session, face: face, model: model)
        controllers.append(c)
        c.makeWindow(at: spawnRect, model: model)
        c.beginRide()
    }

    /// The pointer's side of the screen holds exactly ONE shortcut window: a new
    /// answer beside the cursor retires whatever the last shortcut left there.
    ///
    /// Without this they pile up invisibly. Nothing closes a compact window when
    /// it loses focus, and it is unpinned (`.normal` level), so clicking back
    /// into the source app merely slips it *behind* that app — the user reads
    /// that as "gone". It isn't: every later `NSApp.activate(ignoringOtherApps:)`
    /// raises the whole app, that window with it, and since every shortcut
    /// anchors beside the same pointer they stack on the same spot. Esc then
    /// closes only the front one and hands key status to the app's next window —
    /// the older answer, sitting right underneath, looking like it came back from
    /// the dead.
    ///
    /// Windows torn out of the panel are the user's own and are left alone; this
    /// is only the transient pointer-side surface.
    private static func retirePointerWindows(besides shortcutID: UUID) {
        for c in controllers
        where c.compactShortcut && c.compactShortcutID != shortcutID {
            c.window.close()
        }
    }

    /// Open a prompt-shortcut result beside the pointer location captured at the
    /// hot-key edge. The thread is already running headlessly, so the first frame
    /// can attach to its live mirror without ever unfolding the notch.
    static func presentCompactShortcut(shortcutID: UUID, threadID: UUID, title: String,
                                       model: NotchModel, near pointer: NSPoint,
                                       sourceApplication: NSRunningApplication?) {
        retirePointerWindows(besides: shortcutID)
        if let existing = controllers.first(where: {
            $0.compactShortcutID == shortcutID
        }) {
            existing.replaceCompactThread(with: threadID, title: title,
                                          near: pointer,
                                          sourceApplication: sourceApplication)
            return
        }
        let session = DetachedSession.thread(id: threadID)
        if let existing = controller(for: session) {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let face = DetachedCardFace(title: title, subtitle: "",
                                    isAgent: false, running: true)
        let c = DetachedSessionWindowController(
            session: session, face: face, model: model,
            compactShortcut: true, compactShortcutID: shortcutID,
            replacementApplication: sourceApplication)
        controllers.append(c)
        let rect = c.compactRect(near: pointer)
        c.anchorEntrance(rect: rect, pointer: pointer)
        c.makeWindow(at: rect, model: model)
        c.playPointerEntrance()
        c.state.phase = .settled
        c.finishSettle()
    }

    /// Open the empty-prompt form of a prompt shortcut. Selection capture has
    /// already happened; the small window merely asks what to do with that text.
    /// Enter promotes the same shell into the streaming result, so there is no
    /// second window and no intermediate trip through the notch.
    static func presentCompactShortcutComposer(shortcutID: UUID, selectedText: String,
                                               model: NotchModel, near pointer: NSPoint,
                                               sourceApplication: NSRunningApplication?,
                                               forceTouch: Bool = false) {
        retirePointerWindows(besides: shortcutID)
        if let existing = controllers.first(where: {
            $0.compactShortcutID == shortcutID
        }) {
            existing.replaceCompactComposer(selectedText: selectedText,
                                             near: pointer,
                                             sourceApplication: sourceApplication,
                                             forceTouch: forceTouch)
            return
        }
        let session = DetachedSession.shortcutComposer(id: shortcutID)
        let face = DetachedCardFace(title: L("shortcuts.promptAction.window.context"),
                                    subtitle: "", isAgent: false, running: false)
        let c = DetachedSessionWindowController(
            session: session, face: face, model: model,
            compactShortcut: true, compactShortcutID: shortcutID,
            replacementApplication: sourceApplication)
        c.state.compactSourceText = selectedText
        c.state.forceTouchInvocation = forceTouch
        c.summonPointer = pointer
        controllers.append(c)
        let rect = c.compactRect(near: pointer, asComposer: true)
        c.anchorEntrance(rect: rect, pointer: pointer)
        c.state.grownIn = ForceClickHerald.shared.isPresenting
        c.makeWindow(at: rect, model: model)
        if c.state.grownIn {
            // Nothing to fade up: a press that drew a capsule grew THIS window
            // (`beginPressureComposer`), so the shape is already standing and the
            // branch above should have found it. Reaching here means the press let
            // go of it — appear at full strength rather than swelling over it.
            c.window.alphaValue = 1
            ForceClickHerald.shared.handOff()
        } else {
            c.playPointerEntrance()
        }
        c.state.phase = .settled
        c.finishSettle()
    }

    /// A selection that only answered after its composer was already standing.
    ///
    /// The composer no longer waits for the accessibility read: the first,
    /// synchronous pass answers instantly for a native app, and when it comes
    /// back empty the box opens anyway while a browser's web tree is still being
    /// woken up (`SelectedTextCapture.current(firstPassEmpty:completion:)`). This
    /// is where that late text lands.
    ///
    /// It only ever ADDS context. A window the user has already sent, or one
    /// whose badge they dropped, is left exactly as it is — a late arrival must
    /// never overwrite what someone did in the meantime.
    static func attachCompactSelection(shortcutID: UUID, text: String) {
        guard !text.isEmpty,
              let c = controllers.first(where: { $0.compactShortcutID == shortcutID }),
              c.state.compactSourceText.isEmpty
        else { return }
        guard case .shortcutComposer = c.state.session else { return }
        withAnimation(.easeOut(duration: 0.18)) { c.state.compactSourceText = text }
    }

    // MARK: - The force click, before it is a composer

    /// True while this window is drawing a force click that hasn't fired yet, or
    /// the stretch that follows it — i.e. while it is the cue *and* the window.
    private(set) var isDrawingPressure = false
    /// A retreat is in flight. Only `drawPressure` reads it, to interrupt that
    /// retreat when the same press comes back before the fade is done.
    private var pressureRetracting = false

    /// Still on screen in some pressure phase. `ForceClickHerald`'s latch checks
    /// this, so a window closed from underneath it (Escape, ⌘W, another shortcut
    /// retiring it) can't leave the press stream latched out for good.
    var isPressureAlive: Bool { isDrawingPressure && window?.isVisible == true }

    /// Open the composer *as the force click itself*: the real window, at the real
    /// geometry, drawing nothing but its own input capsule's rounded left cap.
    ///
    /// This is the one-glass rule (see `ForceClickHerald`). The press is not a
    /// stand-in that later hands over to a window — it IS this window, small. The
    /// cue and the composer were two `.clear` glass surfaces before, and glass
    /// multiplies: every frame where both stood measured more than twice as dark as
    /// either alone, which is exactly the "opens opaque, then turns into glass"
    /// this replaces.
    static func beginPressureComposer(shortcutID: UUID, model: NotchModel,
                                      at pointer: NSPoint)
        -> DetachedSessionWindowController? {
        guard NSScreen.containing(pointer) != nil else { return nil }
        // A composer already standing for this shortcut owns an unsent draft and a
        // spot the user put it in. A press must not shrink that back to a cap and
        // drag it to the pointer, so it draws nothing and the fire path re-anchors
        // the existing window exactly as it always did.
        if let existing = controllers.first(where: { $0.compactShortcutID == shortcutID }) {
            return existing.isDrawingPressure ? existing : nil
        }
        let session = DetachedSession.shortcutComposer(id: shortcutID)
        let face = DetachedCardFace(title: L("shortcuts.promptAction.window.context"),
                                    subtitle: "", isAgent: false, running: false)
        let c = DetachedSessionWindowController(
            session: session, face: face, model: model,
            compactShortcut: true, compactShortcutID: shortcutID)
        c.isDrawingPressure = true
        c.state.forceTouchInvocation = true
        c.state.pressDepth = 0
        // The capsule is already standing by the time there is anything to put in
        // it, so the face must never replay its own swell on top of the stretch.
        c.state.grownIn = true
        c.state.phase = .settled
        c.summonPointer = pointer
        controllers.append(c)
        let rect = composerWindowRect(near: pointer)
        c.anchorEntrance(rect: rect, pointer: pointer)
        c.makeWindow(at: rect, model: model)
        // It is a cue until it fires: it must never take a click, a key press or
        // the pointer away from the app the user is pressing inside of. The whole
        // gesture happens in someone else's window.
        c.window.ignoresMouseEvents = true
        c.window.alphaValue = 0
        // AppKit derives a borderless window's shadow from the drawn silhouette and
        // caches it, so a shadow sampled around the cap would stay cap-sized for the
        // window's whole life. It comes on once the stretch has settled.
        c.window.hasShadow = false
        return c
    }

    /// One trackpad frame. The cap is drawn at full size and scaled about its own
    /// centre, so a press costs one transform and no layout at all.
    func drawPressure(_ eased: Double, at pointer: NSPoint) {
        guard isDrawingPressure, let window else { return }
        // A press can wobble back under the floor and push again inside the 130ms
        // it takes to fade out. Kill the retreat before writing this frame's alpha,
        // or the fade keeps driving the window to 0 underneath the live press.
        if pressureRetracting {
            pressureRetracting = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                window.animator().alphaValue = eased
            }
        }
        summonPointer = pointer
        let rect = Self.composerWindowRect(near: pointer)
        window.setFrame(rect, display: false)
        let scale = ForceClickHerald.seedScale + (1 - ForceClickHerald.seedScale) * eased
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let layer = window.contentView?.layer {
            // The cap's centre in the content view's own (bottom-left) coordinates.
            let centre = CGPoint(x: CompactShortcutMetrics.inset
                                    + CompactShortcutMetrics.capDiameter / 2,
                                 y: rect.height - CompactShortcutMetrics.caretOffset.y)
            layer.transform = CATransform3DConcat(
                CATransform3DMakeTranslation(-centre.x, -centre.y, 0),
                CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1),
                                    CATransform3DMakeTranslation(centre.x, centre.y, 0)))
        }
        window.alphaValue = eased
        CATransaction.commit()
        // The fill deepens on its own axis, so a slow press keeps showing progress
        // after the growth has all but finished — the "越来越实心" half of the cue.
        state.pressDepth = eased
        if !window.isVisible { window.orderFrontRegardless() }
    }

    /// The press fired: the cap springs out to the capsule's full width and the
    /// window stops being a cue. One surface, one spring — the composer's field and
    /// badge arrive *inside* a shape that is already standing there.
    func openFromPressure() {
        guard isDrawingPressure, let window else { return }
        // Hand the shape back to SwiftUI at its true size before stretching it: the
        // press scaled the whole layer, and stretching a still-scaled capsule would
        // carry that scale into the composer's final geometry.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.contentView?.layer?.transform = CATransform3DIdentity
        window.alphaValue = 1
        CATransaction.commit()
        window.ignoresMouseEvents = false
        withAnimation(ForceClickHerald.stretch) { state.pressDepth = nil }
        applyPinLevel()
        armMergeTracking()
        // The silhouette the shadow is derived from is only final once the spring
        // is — the same beat `playPointerEntrance` waits out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self, let window = self.window, self.isDrawingPressure else { return }
            self.isDrawingPressure = false
            window.hasShadow = true
            window.invalidateShadow()
        }
    }

    /// The press let go — it fell short, or it fired and found nothing to work on.
    /// The capsule fades out the way it came and the window goes with it: nothing
    /// was typed into it and nothing was captured, so there is nothing to keep.
    func dismissPressure(collapsing: Bool) {
        guard isDrawingPressure else { return }
        guard let window, window.isVisible else { return closePressureWindow() }
        if collapsing, !Self.reduceMotion {
            withAnimation(.easeOut(duration: 0.13)) { state.pressDepth = 0 }
        }
        pressureRetracting = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // A press that resumed during the fade has already re-shown the window
            // at a live alpha; closing it here would blink it away.
            guard let self, self.pressureRetracting,
                  self.window?.alphaValue ?? 0 < 0.02 else { return }
            self.closePressureWindow()
        }
    }

    private func closePressureWindow() {
        guard isDrawingPressure else { return }
        isDrawingPressure = false
        pressureRetracting = false
        state.pressDepth = nil
        window?.contentView?.layer?.transform = CATransform3DIdentity
        window?.close()
    }

    private init(session: DetachedSession, face: DetachedCardFace, model: NotchModel,
                 compactShortcut: Bool = false, compactShortcutID: UUID? = nil,
                 replacementApplication: NSRunningApplication? = nil) {
        self.state = DetachedWindowState(session: session)
        self.face = face
        self.model = model
        self.compactShortcut = compactShortcut
        self.compactShortcutID = compactShortcutID
        self.replacementApplication = replacementApplication
        super.init()
        // Pointer-side shortcut results behave like ordinary transient utility
        // windows. They stay above other apps only when the user explicitly pins
        // them; regular torn-out sessions retain their pinned-by-default behavior.
        if compactShortcut { state.pinned = false }
        if let threadID = session.threadID {
            state.threadStore = model.adoptDetachedThread(threadID)
        }
        if case .compose = session {
            // The line the user was already writing rides out with the window.
            // Read before `completeDetach` clears the panel's box — both entry
            // points construct the controller first.
            state.composeDraft = model.text
        }
    }

    /// The same prompt shortcut fired again: keep this exact NSWindow and replace
    /// only the live thread it observes. The prior round is cancelled, the shell
    /// returns to its waiting height, and the new answer grows it in place.
    private func replaceCompactThread(with threadID: UUID, title: String,
                                      near pointer: NSPoint,
                                      sourceApplication: NSRunningApplication?) {
        guard compactShortcut, let model else { return }
        // Before any resize: the height clamps below measure against the frame,
        // so the window must already be on the display it's going to keep.
        summonPointer = nil
        setCompactWidth(Self.compactWidth)
        reanchorForInvocation(near: pointer, asComposer: false)
        if let oldStore = threadStore, oldStore.threadID != threadID {
            model.cancelCompactRound(threadID: oldStore.threadID)
            model.releaseDetachedThread(oldStore.threadID)
        }
        state.threadStore = model.adoptDetachedThread(threadID)
        state.session = .thread(id: threadID)
        // A shortcut that opens straight into an answer IS an arrival: it plays
        // the pointer entrance, unlike the capsule growing into its own card.
        state.openingFromComposer = false
        state.compactFaceDrills = false
        replacementApplication = sourceApplication
        window.title = title
        window.minSize = Self.compactMinSize
        // A fresh round with no composer behind it waits at the card again.
        compactFloorHeight = Self.compactInitialHeight
        resizeCompactThread(to: Self.compactInitialHeight, reset: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        armSummonGrace()
    }

    /// Reusing the same empty-prompt shortcut replaces both pieces of transient
    /// state: the captured selection and any draft left in the field. If its
    /// previous invocation was still generating, that obsolete round is stopped
    /// before this window returns to its one-line composer face.
    private func replaceCompactComposer(selectedText: String,
                                        near pointer: NSPoint,
                                        sourceApplication: NSRunningApplication?,
                                        forceTouch: Bool) {
        guard compactShortcut, let model, let shortcutID = compactShortcutID else { return }
        summonPointer = pointer
        state.grownIn = ForceClickHerald.shared.isPresenting
        // Narrow again first: the re-anchor below places the window by the size
        // it is holding, so an answer's width would land the caret off the
        // pointer that summoned it.
        setCompactWidth(Self.composerWidth)
        reanchorForInvocation(near: pointer, asComposer: true)
        if let oldStore = threadStore {
            // Force Touch is another independent Ask, not a replacement for the
            // one already running. Match main-flow new-chat behavior: detach the
            // old round so it can finish into Recent instead of cancelling it.
            if forceTouch || state.forceTouchInvocation {
                model.detachCompactRound(threadID: oldStore.threadID)
            } else {
                model.cancelCompactRound(threadID: oldStore.threadID)
            }
            model.releaseDetachedThread(oldStore.threadID)
        }
        state.threadStore = nil
        state.compactSourceText = selectedText
        state.forceTouchInvocation = forceTouch
        state.forceTouchHistoryExpanded = false
        state.compactPromptDraft = ""
        compactPromptWasEmpty = true
        state.compactPromptGeneration += 1
        state.openingFromComposer = false
        state.compactFaceDrills = false
        state.session = .shortcutComposer(id: shortcutID)
        replacementApplication = sourceApplication
        window.title = L("shortcuts.promptAction.window.context")
        // Back to the capsule: drop the answer floor first, or AppKit clamps the
        // window at the taller size it was holding as a result view.
        window.minSize = Self.compactComposerMinSize
        compactFloorHeight = Self.compactInitialHeight
        resizeCompactThread(to: composerRestingHeight, reset: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        armSummonGrace()
        // The capsule the press stretched IS this window's capsule, so there is no
        // cue to take off screen — only the herald's bookkeeping to let go of.
        if state.grownIn { ForceClickHerald.shared.handOff() }
    }

    /// The transient instruction now has everything it needs. Start the same
    /// headless prompt-shortcut round as a saved instruction and let this exact
    /// compact window become its live result view in place.
    private func submitCompactShortcutPrompt(_ prompt: String, pin: ModelPin? = nil) {
        guard compactShortcut,
              case .shortcutComposer = state.session,
              let model,
              let threadID = model.startPromptShortcutRound(
                prompt: prompt, selectedText: state.compactSourceText, pin: pin,
                origin: state.forceTouchInvocation ? .forceTouch : nil)
        else { return }
        // The line stays in the capsule while the capsule dissolves: clearing it
        // here brought the placeholder ("What should I do with it?") flashing
        // back for the length of the fade. The next invocation resets the draft
        // (`replaceCompactComposer`), and this face is leaving regardless.
        state.threadStore = model.adoptDetachedThread(threadID)
        // Everything below changes what the card holds AND how tall it is, in one
        // turn — so the reveal's mask has to be on the card before any of it runs
        // (see `withCompactRevealArmed`). Arming it costs a frame in which the
        // composer is unchanged, which is nothing to look at.
        withCompactRevealArmed { [weak self] in
            self?.openCompactAnswer(threadID: threadID)
        }
    }

    /// The second half of `submitCompactShortcutPrompt`, run once the reveal mask
    /// is live: the capsule's contents become the card's, and the window opens
    /// down to the waiting height.
    private func openCompactAnswer(threadID: UUID) {
        guard window != nil else { return }
        // The card takes over the box in place — it does not arrive from
        // anywhere (`DetachedSessionRootView.compactShortcutFace`), and it does
        // not dissolve into anything either: this is the morph, not navigation.
        state.openingFromComposer = true
        state.compactFaceDrills = false
        // Unanimated, like the two navigation paths: the growth this face needs
        // is the reveal mask's, which springs on its own, and the contents cross
        // over on their own numbers. An ambient animation here has nothing left
        // to do except spring the LAYOUT — every mark in the card sliding from
        // where it sat in the capsule to where it sits in the answer — which is
        // the opposite of the box simply opening.
        state.session = .thread(id: threadID)
        window.minSize = Self.compactMinSize
        // Enter opens the capsule into the waiting card, once, and the window
        // then holds there for the whole wait — the answer's arrival grows it
        // from that floor in one continuous glide (`resizeCompactThread`).
        //
        // It used to freeze at exactly the capsule's height so Enter moved
        // nothing at all. That only worked while the answer face was a bare
        // slab: it now carries the same header and follow-up line every other
        // detached thread does, and a capsule-height window would clip both.
        //
        // That growth is GLIDED, not set: a hard `setFrame` from the one-line
        // capsule to the waiting card is a cut, and a cut is what makes the card
        // read as a new dialog rather than the same box opening.
        // The card the user typed in does NOT resize to think: it holds the
        // exact height it already has after its quick actions have folded, and
        // only the answer grows it from there. Dropping to the waiting card's own
        // floor shrank the box under the line just submitted, which is a window closing and
        // another opening, not a card filling in.
        //
        // The BOX, though — not the drawer under it. An open History ledger is
        // hung below the input and leaves with the composer's face, so its rows
        // must come off this measurement first. Left in, they became the answer's
        // floor (`resizeCompactThread` never goes below it), and a one-line reply
        // submitted from an open ledger opened a card as tall as the whole recent
        // list, its answer stranded at the top of a void.
        compactFloorHeight = max(composerHeightWithoutLedger(),
                                 Self.compactInitialHeight)
        // The box the user typed in opens DOWNWARD and nothing else: same width,
        // same top edge, same left edge. It used to widen to the answer's
        // reading box (`compactWidth`) on the way, which moved the trailing edge
        // — and, at a screen edge, the whole window — out from under the line
        // the user had just pressed Enter on. One axis moves, and it is the one
        // the answer is arriving on.
        resizeCompactThread(to: compactFloorHeight, reset: true, animated: true)
    }

    /// The window's height with the History drawer's rows discounted — what the
    /// composer alone occupies. Equal to the frame while the ledger is folded.
    private func composerHeightWithoutLedger() -> CGFloat {
        guard state.forceTouchHistoryExpanded else { return window.frame.height }
        let ledger = CompactShortcutPromptView.historyBlock(
            model?.forceTouchHistory.count ?? 0)
        return max(window.frame.height - ledger, 0)
    }

    /// Keep History inside the pointer-side shell. From the composer the clock
    /// unfolds its private ledger below the input; from a result it returns this
    /// same window to that expanded ledger.
    private func toggleForceTouchHistory() {
        guard compactShortcut, state.forceTouchInvocation else { return }
        if case .shortcutComposer = state.session {
            // Arm the disclosure's mask BEFORE the ledger changes size, so the
            // measurement it triggers can resize the window in the same turn it
            // arrives (see `withCompactRevealArmed`).
            withCompactRevealArmed { [weak self] in
                guard let self else { return }
                self.animateForceTouchHistoryResize = true
                self.state.forceTouchHistoryExpanded.toggle()
            }
            return
        }

        if let oldStore = threadStore {
            model?.releaseDetachedThread(oldStore.threadID)
        }
        state.threadStore = nil
        state.compactPromptDraft = ""
        compactPromptWasEmpty = true
        state.compactPromptGeneration += 1
        // Back is a SET, not a disclosure — so nothing here arms the reveal.
        animateForceTouchHistoryResize = false
        state.forceTouchHistoryExpanded = true
        state.openingFromComposer = false
        // …but it IS the ledger coming back, so it dissolves in the way it
        // dissolved out (`compactFaceTransition`).
        state.compactFaceDrills = true
        window.minSize = Self.compactComposerMinSize
        // NOT wrapped in `withAnimation`, and that is the whole point.
        //
        // The window's new height is a `setFrame` — instant, and the NSWindow
        // frame is provably never in motion here (measured at 120Hz: it goes to
        // its new value on the first tick and never moves again). But SwiftUI
        // lays the face out INSIDE that window, so the resize shows up as a
        // layout change on the very next update pass — and if that pass is
        // carrying an animation, SwiftUI springs the whole face from the old
        // geometry to the new one. Measured on the way back out of a
        // conversation, with the window stock still the entire time: the card
        // dropped 117px in one frame, sat there for three, then travelled back
        // up over ~270ms while growing. That is the jump — not the window, the
        // layout of the face inside it.
        //
        // So nothing here opens an animated transaction. The cross-fade does not
        // need one: `compactFaceTransition` declares its own animations, which
        // is what makes a transition play on an unanimated change.
        state.session = .shortcutComposer(
            id: compactShortcutID ?? SelectedTextShortcutStore.actionID)
        // The mirror of `openForceTouchHistoryThread`: the window knows how tall
        // the composer is before that face mounts — the draft was just cleared, so
        // it is one line, and the ledger below it is the same rows it always had —
        // so it lands there in ONE set and the cross-fade carries the change.
        //
        // Routed through the disclosure's reveal mask (what it used to do), the
        // return settled its top TWICE: the mask is top-anchored and holds the
        // window at the ANSWER's height for the whole collapse, laying the
        // composer out inside that tall frame, and the face then re-measured
        // itself on mount — a second, un-animated height report that cancelled the
        // reveal mid-flight and hard-set the frame. That is the jump-and-return
        // on the way back.
        let hasSelection = !state.compactSourceText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        resizeCompactThread(
            to: CompactShortcutPromptView.expandedHeight(
                withPicks: hasSelection,
                historyCount: model?.forceTouchHistory.count ?? 0),
            reset: true,
            animated: false)
    }

    /// Replace the drawer with a saved Force Touch conversation without creating
    /// or activating another window.
    private func openForceTouchHistoryThread(_ threadID: UUID) {
        guard compactShortcut, state.forceTouchInvocation, let model else { return }
        let store = model.adoptDetachedThread(threadID)
        state.threadStore = store
        // The ledger stays logically OPEN behind the conversation. Folding it
        // here re-measured the composer — still the live face for another beat —
        // as a collapsed one-line box, and that report was honoured: the window
        // slammed 379 → 147 → the card's own height inside 10ms, which is the
        // blink on opening an entry. Nothing reads the flag while a thread is up,
        // and Back sets it true again regardless, so there is nothing to fold.
        state.openingFromComposer = true
        // Forward through the ledger: the two faces cross-fade into each other
        // rather than staggering (`compactFaceTransition`).
        state.compactFaceDrills = true
        window.minSize = Self.compactMinSize
        compactFloorHeight = Self.compactInitialHeight
        // Unanimated, for the reason spelled out in `toggleForceTouchHistory`:
        // the window's height lands in one set, and an animated transaction here
        // would have SwiftUI spring the whole face's layout to meet it.
        state.session = .thread(id: threadID)
        // A saved thread is already written, so the window knows how tall it has
        // to be before the face mounts — open it AT that height in one move. It
        // used to open at the waiting card's floor and let the mounted view grow
        // it back out, which took the disclosure's own 0.7s reveal to hand the
        // answer over (the visible "a beat late"), and a longer answer's growth
        // landed mid-reveal only to be shrunk away again by that reveal's
        // completion — leaving a window too short to show the answer at all.
        //
        // And it lands in ONE set, not through the disclosure's reveal mask. That
        // mask is top-anchored: while it runs, the card is laid out at the OLD
        // frame's height, so everything the slab hangs off its bottom edge — the
        // action row, the follow-up capsule — sits below the mask's edge and only
        // snaps in when the frame is finally committed. The face swap already
        // cross-fades (`compactFaceContent`); the window simply arrives at the
        // size that face needs, with all of it visible at once.
        let answer = store.turns.last(where: { $0.role == "assistant" })?.text ?? ""
        let opening = max(Self.compactInitialHeight,
                          DetachedThreadView.estimatedCompactWindowHeight(for: answer))
        resizeCompactThread(to: opening, reset: true, animated: false)
    }

    /// The composer sent its first question: this window IS that thread now.
    /// Re-key it, adopt the round's live mirror, and let the root view swap the
    /// composer for the conversation — same window, in place, no second window
    /// and no trip back through the notch.
    private func adoptThread(_ threadID: UUID) {
        guard let model, state.session == .compose else { return }
        let store = model.adoptDetachedThread(threadID)
        state.threadStore = store
        withAnimation(Self.reduceMotion ? nil : .easeOut(duration: 0.2)) {
            state.session = .thread(id: threadID)
        }
        growIntoThread()
    }

    /// A composer is a short window (it holds one input line); the conversation
    /// it just became needs room to write. Grow downward from the same top edge
    /// so the box the user typed in doesn't move under their eyes.
    private func growIntoThread() {
        let frame = window.frame
        let target = Self.threadWindowSize
        guard frame.height < target.height || frame.width < target.width else { return }
        var grown = NSRect(x: frame.minX, y: frame.maxY - max(frame.height, target.height),
                           width: max(frame.width, target.width),
                           height: max(frame.height, target.height))
        if let visible = window.screen?.visibleFrame {
            grown.origin = Self.clamped(origin: grown.origin, size: grown.size, in: visible)
        }
        window.minSize = Self.threadMinSize
        if Self.reduceMotion {
            window.setFrame(grown, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(grown, display: true)
            }
        }
    }

    /// The draft wrapped (or a save cue appeared / cleared): grow or shrink the
    /// slab from its BOTTOM edge, so the box the user is typing in never moves.
    /// Composer only — once it's a thread the window is the user's to size.
    private func resizeComposer(to height: CGFloat) {
        guard state.session == .compose, window != nil else { return }
        let frame = window.frame
        guard abs(frame.height - height) > 0.5 else { return }
        var target = NSRect(x: frame.minX, y: frame.maxY - height,
                            width: frame.width, height: height)
        if let visible = window.screen?.visibleFrame {
            target.origin = Self.clamped(origin: target.origin, size: target.size,
                                         in: visible)
        }
        window.setFrame(target, display: true, animate: false)
    }

    /// Follow a compact answer's intrinsic height. Keep the top edge fixed while
    /// there is room below; at a screen edge the window shifts just enough to stay
    /// wholly visible. Past the cap, the thread's ScrollView takes over.
    private func resizeCompactThread(to desiredHeight: CGFloat, reset: Bool = false,
                                     animated: Bool = false) {
        guard compactShortcut, window != nil else { return }
        let frame = window.frame
        let visible = window.screen?.visibleFrame
            ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        let screenCap = visible.map { $0.height * 0.65 } ?? Self.compactMaxHeight
        // The bare composer is exactly as tall as its badge + capsule — far
        // shorter than any answer, and it must SHRINK again when a wrapped draft
        // is deleted, so it takes neither the answer floor nor the growth-only
        // hysteresis below.
        var bareComposer = false
        if case .shortcutComposer = state.session { bareComposer = true }
        // A round's floor is wherever it STARTED: a shortcut that opened straight
        // into an answer starts at the waiting card, one that grew out of a
        // composer keeps the composer's own height, so the wait never moves the
        // window (`submitCompactShortcutPrompt`).
        let floor = bareComposer
            ? CompactShortcutPromptView.restingHeight
            : compactFloorHeight
        let measured = min(max(desiredHeight, floor),
                           min(Self.compactMaxHeight, screenCap))
        if reset || bareComposer {
            compactRoundHeight = measured
            guard abs(frame.height - measured) > 0.5 else {
                stopCompactGlide()
                // A collapse keeps the NSWindow at its expanded height until the
                // reveal mask finishes. If the user re-opens History during that
                // interval, the requested height therefore already matches the
                // window even though the mask is still closing. Retarget that
                // reveal instead of returning and letting the stale collapse
                // completion shrink an expanded drawer underneath SwiftUI.
                if animated && !Self.reduceMotion,
                   (compactRevealCompletion != nil || state.compactRevealHeight != nil) {
                    animateCompactHeight(to: measured)
                }
                return
            }
            // Discrete composer changes reveal through one top-anchored mask.
            // Streaming answers still use the re-targetable glide below.
            if animated && !Self.reduceMotion {
                animateCompactHeight(to: measured)
            } else {
                stopCompactGlide()
                cancelCompactReveal()
                setCompactHeight(measured)
            }
            return
        }
        // Same hysteresis as the prompt editor's IME fix: growth is real and
        // immediate; a lower intermediate measurement is not. The floor is
        // deliberately reset only when this shortcut starts a new round.
        guard measured > compactRoundHeight + 0.5 else { return }
        compactRoundHeight = measured
        // A disclosure reveal in flight OWNS this window's height: it masks the
        // card to its own animating height and commits its target frame when it
        // finishes. Gliding underneath it draws the extra height behind that mask
        // and then loses it to the stale commit — and the growth-only hysteresis
        // above never asks again, so the answer stays clipped for good (this is
        // what left a reopened thread showing its toolbar over an empty card).
        // Re-aim the reveal instead.
        if compactRevealCompletion != nil || state.compactRevealHeight != nil {
            animateCompactHeight(to: measured)
            return
        }
        guard !Self.reduceMotion else {
            setCompactHeight(measured)
            return
        }
        glideCompact(to: measured)
    }

    /// Drop any disclosure reveal still in flight. A hard set owns this window's
    /// height outright, so a reveal left running would keep masking the card to a
    /// stale height and then commit a stale frame when it finished.
    private func cancelCompactReveal() {
        compactRevealGeneration += 1
        compactRevealCompletion?.cancel()
        compactRevealCompletion = nil
        state.onRevealArmed = nil
        guard state.compactRevealHeight != nil else { return }
        withAnimation(nil) { state.compactRevealHeight = nil }
    }

    /// Put the compact window at `height`, hanging from its own top edge and
    /// nudged back inside the screen at the bottom. Every compact resize — the
    /// hard sets and every frame of the glide — goes through here.
    private func setCompactHeight(_ height: CGFloat, width: CGFloat? = nil,
                                  reshadow: Bool = true) {
        guard window != nil else { return }
        let target = compactFrame(height: height, width: width)
        window.setFrame(target, display: true, animate: false)
        // The window's silhouette is its own glass, not its rect (the action pill
        // leaves a transparent band above the card), so AppKit has to re-derive
        // the shadow from what's drawn. Re-deriving it costs real work, so the
        // glide only asks for it every few frames (and always on its last one).
        if reshadow { window.invalidateShadow() }
    }

    /// The target frame shared by hard sets, streaming glides, and the one-shot
    /// History disclosure. Its top edge stays fixed whenever the screen allows.
    private func compactFrame(height: CGFloat, width: CGFloat? = nil) -> NSRect {
        let frame = window.frame
        var target = NSRect(x: frame.minX, y: frame.maxY - height,
                            width: width ?? frame.width, height: height)
        let visible = window.screen?.visibleFrame
            ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        // Growing downward walks the bottom edge into the dock, and a window
        // summoned near a side may already be sitting against one.
        if let visible {
            target.origin = Self.clamped(origin: target.origin, size: target.size,
                                         in: visible)
        }
        return target
    }

    /// A discrete compact resize is revealed inside a stationary top edge.
    ///
    /// Driving `NSWindow.setFrame` on every animation frame made the glass and
    /// its shadow re-layout independently of SwiftUI. Even with a mathematically
    /// fixed `maxY`, that redraw made the top border visibly tremble. Grow the
    /// window once, then animate only a top-aligned mask; for a collapse, shrink
    /// the mask first and commit the smaller window frame when it has finished.
    private func animateCompactHeight(to height: CGFloat) {
        stopCompactGlide()
        let revealInFlight = state.compactRevealHeight != nil
        compactRevealCompletion?.cancel()
        compactRevealGeneration += 1

        let start = window.frame
        let scale = window.backingScaleFactor
        let fixedTop = (start.maxY * scale).rounded() / scale
        let targetHeight = (height * scale).rounded() / scale
        let target = NSRect(x: start.minX,
                            y: fixedTop - targetHeight,
                            width: start.width,
                            height: targetHeight)
        let expanding = targetHeight > start.height + 0.5
        let generation = compactRevealGeneration
        let duration = Self.reduceMotion ? 0.22 : CompactHistoryMotion.settleDuration
        let revealAnimation: Animation = Self.reduceMotion
            ? .easeOut(duration: duration)
            : CompactHistoryMotion.spring

        // Install the mask before the host is allowed to take the larger size,
        // otherwise one unmasked final-size frame can flash between the two. An
        // interrupted reveal already has a live presentation value: preserve it
        // so another click reverses the spring from where it visibly is instead
        // of snapping back to the old endpoint first.
        if !revealInFlight {
            withAnimation(nil) {
                state.compactRevealHeight = start.height
            }
        }
        window.contentView?.layoutSubtreeIfNeeded()
        // Safe to take the larger size right here: every discrete resize enters
        // through `withCompactRevealArmed`, so the mask above is already drawn by
        // the time this runs.
        if expanding {
            window.setFrame(target, display: true, animate: false)
        }

        // Landing the window on the smaller frame: the reveal owns the height
        // until it finishes, and this is what hands it back. Runs exactly once —
        // whichever of the two paths below gets here first.
        var committed = false
        let commit: () -> Void = { [weak self] in
            guard let self, !committed, self.window != nil,
                  self.compactRevealGeneration == generation else { return }
            committed = true
            if targetHeight < self.window.frame.height - 0.5 {
                self.window.setFrame(target, display: true, animate: false)
            }
            withAnimation(nil) {
                self.state.compactRevealHeight = nil
            }
            self.window.invalidateShadow()
            self.compactRevealCompletion = nil
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.compactRevealGeneration == generation else { return }
            // The commit rides the reveal's OWN completion, not a stopwatch. A
            // fixed delay had to be padded past the underdamped spring's settle
            // to be safe, which left the card folded and the window — its glass
            // and its shadow — still standing at the old height for the padding,
            // then snapping down a beat later. `.logicallyComplete` fires when the
            // spring has reached its value rather than when its last ripple is
            // retired, so the frame lands with the fold instead of after it.
            withAnimation(revealAnimation, completionCriteria: .logicallyComplete) {
                self.state.compactRevealHeight = targetHeight
            } completion: {
                commit()
            }
        }

        // Backstop only. If the reveal never reports (its view left the tree
        // mid-flight), the window would otherwise keep the reveal's height for
        // good. Deliberately later than the animation so the completion above is
        // what normally lands the frame.
        let completion = DispatchWorkItem(block: commit)
        compactRevealCompletion = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.25,
                                      execute: completion)
    }

    /// Put the reveal mask on the card at the height it ALREADY has — visually a
    /// no-op — and run `body` only once the face has actually drawn it. Every
    /// discrete compact resize is entered through here.
    ///
    /// The mask is published state: setting it does not draw anything, it
    /// schedules SwiftUI's next update, and that update lands whole frames later.
    /// Both ways of ignoring that are visible on screen:
    ///
    ///   · resize the window first (what this used to do) and the card is
    ///     presented at its FINAL size with no mask on it for 2-3 frames, then
    ///     snapped back to the old height for the reveal to play from — the
    ///     flash on entering an answer;
    ///   · defer only the `setFrame`, and the face — already laid out for the
    ///     new content — spends those frames squeezed into a window that is
    ///     still too small, which is a jump at the card's top edge.
    ///
    /// Arming at the height the card already has is free: the mask cuts exactly
    /// where the card already ends, so the wait costs nothing on screen. Once it
    /// is drawn, the content change, the measurement it triggers and the
    /// `setFrame` that follows can all stay in one synchronous turn.
    private func withCompactRevealArmed(_ body: @escaping () -> Void) {
        guard !Self.reduceMotion, window != nil,
              state.compactRevealHeight == nil else { return body() }
        withAnimation(nil) { state.compactRevealHeight = window.frame.height }
        let armedGeneration = compactRevealGeneration
        var ran = false
        let run: () -> Void = { [weak self] in
            guard !ran else { return }
            ran = true
            self?.state.onRevealArmed = nil
            body()
            // The mask is only ever meant to be handed straight to a reveal. If
            // the change turned out not to resize anything, no `animateCompactHeight`
            // follows to take it off again — and a mask left standing at a stale
            // height clips every later growth, which is how an answer ends up
            // permanently cut off. Take it back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard let self, self.compactRevealGeneration == armedGeneration,
                      self.state.compactRevealHeight != nil else { return }
                withAnimation(nil) { self.state.compactRevealHeight = nil }
            }
        }
        state.onRevealArmed = run
        // A face that never draws (the window closing mid-flight) must not
        // swallow the change it was gating.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: run)
    }

    /// Open the window down to `height` as ONE continuous move.
    ///
    /// An answer doesn't arrive at a height, it arrives at thirty of them — a
    /// chunk of Markdown at a time. Animating each report separately (the old
    /// 0.18s ease-out per geometry change) restarts the deceleration on every
    /// chunk, which is what made the expansion read as a stutter of little
    /// lurches instead of one shot. So the target is just re-aimed while the
    /// window is already moving: a critically-damped glide chases whatever the
    /// latest target is at whatever speed it currently has, and stops once —
    /// when the answer stops growing.
    private func glideCompact(to height: CGFloat) {
        compactTargetHeight = height
        guard compactGlideTimer == nil else { return }  // already moving: re-aimed
        compactGlideAt = ProcessInfo.processInfo.systemUptime
        var frame = 0
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            guard let self, self.window != nil else { timer.invalidate(); return }
            let now = ProcessInfo.processInfo.systemUptime
            // Clamped so a stalled run loop can't teleport the window.
            let dt = min(max(now - self.compactGlideAt, 1.0 / 240.0), 1.0 / 20.0)
            self.compactGlideAt = now
            let ease = 1 - exp(-dt / Self.compactGlideTau)
            let current = self.window.frame.height
            var next = current + (self.compactTargetHeight - current) * ease
            let done = abs(self.compactTargetHeight - next) < 0.5
            if done { next = self.compactTargetHeight }
            frame += 1
            self.setCompactHeight(next, reshadow: done || frame % 6 == 0)
            if done { self.stopCompactGlide() }
        }
        RunLoop.main.add(timer, forMode: .common)
        compactGlideTimer = timer
    }

    private func stopCompactGlide() {
        compactGlideTimer?.invalidate()
        compactGlideTimer = nil
    }

    /// Put the window at `width` now, without animating — the path back from an
    /// answer to a composer, where nothing else is moving either.
    private func setCompactWidth(_ width: CGFloat) {
        guard window != nil, abs(window.frame.width - width) > 0.5 else { return }
        var frame = window.frame
        frame.size.width = width
        if let visible = window.screen?.visibleFrame {
            frame.origin = Self.clamped(origin: frame.origin, size: frame.size, in: visible)
        }
        window.setFrame(frame, display: true)
    }

    /// The glide's time constant: ~63% of the remaining distance per 0.1s, so a
    /// short answer opens in about a quarter second and a long one keeps opening
    /// at the same pace it's already moving at.
    private static let compactGlideTau: Double = 0.1

    /// A settled session window's working size, and the floor it may be dragged
    /// down to. A composer opens far shorter than this (see `makeWindow`).
    private static let threadWindowSize = NSSize(width: 560, height: 460)
    private static let threadMinSize = NSSize(width: 420, height: 320)
    /// Kept BELOW the composer's resting height — a floor above it would have
    /// AppKit inflate the window the moment it's created.
    private static let composeMinSize = NSSize(width: 380, height: 96)
    /// ONE width for every pointer-side window: the box the user types in, and
    /// the answer it becomes — a prompt shortcut firing straight into a card
    /// included. They are the same window, so they are the same width.
    ///
    /// It used to be two numbers, 330 for the composer and 410 for the answer,
    /// with Enter widening the box between them. 410 is wider than a card
    /// summoned at the pointer wants to be, 330 is tight for prose, and the
    /// widening was a moving edge under the line the user had just typed. This
    /// sits between them.
    static let compactWidth: CGFloat = 370
    /// The composer is that same box before it has anything to say.
    static let composerWidth: CGFloat = compactWidth
    /// The waiting card — what an answer window is before a word has landed: the
    /// window chrome an answered card carries (margins, header, follow-up row),
    /// its own top/bottom padding, the resting gaps the one orb row rests
    /// between, and that row. A single line never scrolls, so it wears the
    /// resting rhythm rather than the runways (`DetachedThreadView`) — budgeting
    /// two 28pt runways for it opened the wait 38pt taller than the card it
    /// becomes and left the orb floating in the middle of an empty box.
    private static let compactInitialHeight: CGFloat =
        CompactShortcutMetrics.answerChrome
            + DetachedThreadView.compactCardPadding * 2
            + DetachedThreadView.restingTopGap + DetachedThreadView.restingBottomGap + 26
    fileprivate static let compactMaxHeight: CGFloat = 520
    /// Kept at or below `compactWidth` — a compact composer opens into its
    /// answer at its OWN width now, and a floor wider than that is a floor
    /// AppKit widens the window through the instant the answer face sets it.
    private static let compactMinSize = NSSize(width: 300, height: 96)
    /// The bare prompt-shortcut composer is shorter than any answer window, so
    /// it carries its own floor — the shared one would have AppKit inflate it
    /// back into a half-empty slab the moment it's created.
    /// Kept below `compactWidth` on BOTH axes — a floor wider than the composer
    /// is a floor AppKit inflates it back through the moment it is created.
    private static let compactComposerMinSize = NSSize(width: 300, height: 60)
    private static let pointerGap: CGFloat = 6
    /// The safe distance a pointer-side window keeps from every edge of its
    /// display. Not a hairline: these windows are summoned wherever the cursor
    /// happens to be, so a press taken near a corner regularly lands one against
    /// a side — flush there it reads as clipped, as though the box ran off the
    /// screen. Every placement, nudge and resize goes through `clamped(origin:)`
    /// so there is exactly one answer to where the edge is.
    private static let screenMargin: CGFloat = 16

    // MARK: Window construction

    private func makeWindow(at rect: NSRect, model: NotchModel) {
        var rect = rect
        let composing = session == .compose
        var bareComposer = false
        if case .shortcutComposer = session { bareComposer = true }
        if composing || bareComposer {
            // A composer is just the input: born as a slab the height of the
            // prompt row, hanging from the same top edge the panel had, instead
            // of a session-sized window three-quarters empty. The prompt-shortcut
            // composer is shorter still — a badge over a capsule, nothing else.
            let h = bareComposer
                ? composerRestingHeight
                : DetachedComposeView.restingHeight
            rect = NSRect(x: rect.minX, y: rect.maxY - h, width: rect.width, height: h)
        }
        let w = DetachedWindow(
            contentRect: rect,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = face.title
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isReleasedWhenClosed = false
        // OFF, and it has to be off. Left on, the WINDOW SERVER claims every
        // press that lands on a point whose view answers `mouseDownCanMoveWindow`
        // — which is the hosting view, i.e. all of the card's own glass — and
        // runs its background-drag itself. It then moves nothing, and the app
        // never sees the event at all (a global monitor catches those presses;
        // `sendEvent` does not). The only pixels that stayed alive were the ones
        // AppKit views cover — the input's recess and the two chips — which is
        // exactly the map of what could and couldn't be grabbed: the header row's
        // empty half, the card's padding, dead; the input capsule, fine.
        //
        // With it off, every press reaches `DetachedWindow.sendEvent`, which
        // carries the window by hand (see the note there).
        w.isMovableByWindowBackground = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.closesOnEscape = compactShortcut
        w.onAppShortcut = { [weak self] event in
            self?.handleAppShortcut(event) ?? false
        }
        w.minSize = bareComposer
            ? Self.compactComposerMinSize
            : (compactShortcut ? Self.compactMinSize
                               : (composing ? Self.composeMinSize : Self.threadMinSize))
        // While being carried it floats above everything, like a piece of the
        // island in the hand. `finishSettle` drops it to its pinned level.
        w.level = .statusBar
        if compactShortcut {
            // The other half of "beside the pointer": a pointer-side window
            // belongs to wherever the user is working *now*, not to the Space it
            // happened to be born on. Without this, re-firing the shortcut on
            // another display drags the user back across Spaces to the old
            // window — or leaves it answering invisibly on the Space they left.
            // Torn-out session windows are the user's own and keep AppKit's
            // default (they stay put on their Space).
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        }

        // Thread actions read the store's threadID at CALL time (not capture
        // time): a regenerate can re-id the thread, and the store's key is
        // kept current by the model (`runDetachedRound`).
        let root = DetachedSessionRootView(
            state: state,
            model: model,
            onTogglePin: { [weak self] in self?.togglePin() },
            onClose: { [weak self] in self?.window.close() },
            onInAppCopy: { [weak self] in
                self?.model?.rebaselineClipboardAfterInAppWrite()
            },
            onReplaceOriginal: { [weak self] text in
                self?.replaceOriginalText(with: text) ?? false
            },
            onFollowUp: { [weak self] line, images in
                guard let self, let id = self.threadStore?.threadID else { return }
                self.model?.submitDetachedFollowUp(threadID: id, question: line,
                                                   images: images)
            },
            onRegenerate: { [weak self] in
                guard let self, let id = self.threadStore?.threadID else { return }
                self.model?.regenerateDetachedAnswer(threadID: id)
            },
            onRegenerateWith: { [weak self] pick in
                guard let self, let id = self.threadStore?.threadID else { return }
                self.model?.regenerateDetachedAnswer(threadID: id, model: pick)
            },
            onChooseOption: { [weak self] questionID, option in
                self?.model?.chooseUserOption(option, questionID: questionID)
            },
            regenerateOptions: { [weak self] in
                self?.model?.regenerateModelOptions ?? []
            },
            // Enter in the composer: the round runs headless through the panel
            // pipeline and this window becomes the thread it started.
            onCompose: { [weak self] line, destination in
                guard let self, let model = self.model else { return }
                if let threadID = model.submitDetachedCompose(line, destination: destination) {
                    self.adoptThread(threadID)
                }
            },
            onComposeHeight: { [weak self] h in self?.resizeComposer(to: h) },
            onCompactPrompt: { [weak self] line, pin in
                self?.submitCompactShortcutPrompt(line, pin: pin)
            },
            onToggleForceTouchHistory: { [weak self] in
                self?.toggleForceTouchHistory()
            },
            onOpenForceTouchHistory: { [weak self] id in
                self?.openForceTouchHistoryThread(id)
            },
            onCaretOffset: { [weak self] offset in self?.alignCaret(to: offset) },
            compactShortcut: compactShortcut,
            onThreadHeight: { [weak self] h in
                guard let self else { return }
                var quickActionsChanged = false
                if case .shortcutComposer = self.state.session {
                    let promptIsEmpty = self.state.compactPromptDraft
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    quickActionsChanged = promptIsEmpty != self.compactPromptWasEmpty
                    self.compactPromptWasEmpty = promptIsEmpty
                }
                let animated = self.animateForceTouchHistoryResize || quickActionsChanged
                self.animateForceTouchHistoryResize = false
                self.resizeCompactThread(to: h, animated: animated)
            })
            .environmentObject(Localization.shared)
            // This window's own edges are the wall its hover tooltips clamp to —
            // the island's coordinate space doesn't reach here.
            .notchTooltipClipBox()
        let hosting = NSHostingView(rootView: root)
        // This window's size is OURS, not SwiftUI's. Every height here is
        // computed by the controller (`resizeComposer`, `resizeCompactThread`,
        // `glideCompact`) and written with `setFrame` — often mid-animation,
        // many times a second.
        //
        // Left at its default, `NSHostingView` also claims that ownership: on
        // every constraints pass it re-derives the window's content min/max
        // extrema by measuring the SwiftUI content, and it resizes the window
        // itself from `windowDidLayout`. Those measurements dirty the very view
        // graph that produced them, so the invalidation lands INSIDE AppKit's
        // display cycle and `-[NSWindow _postWindowNeedsUpdateConstraints]`
        // throws:
        //
        //   "marked as needing another Update Constraints in Window pass, but it
        //    has already had more … passes than there are views in the window"
        //
        // Keeping single views out of the sizing path only dodges one
        // instance of it. Emptying `sizingOptions` stops the
        // content-derived constraints, and keeping the hosting view one level
        // below `NSWindow.contentView` also removes SwiftUI's window-size bridge.
        // (On macOS 27 that bridge can still run `updateAnimatedWindowSize` for a
        // direct content view even when its sizing options are empty.) The plain
        // AppKit container owns the window edge; SwiftUI only autoresizes inside
        // the frame the controller gives it.
        hosting.sizingOptions = []
        let container = NSView(frame: NSRect(origin: .zero,
                                             size: w.contentLayoutRect.size))
        container.autoresizesSubviews = true
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        w.contentView = container
        w.delegate = self
        window = w
        w.orderFrontRegardless()
    }

    /// Replace the selection that launched this compact shortcut. Paste is used
    /// instead of AX assignment because it works across native, browser and
    /// Electron editors. The user's clipboard is restored after the target has
    /// consumed it, unless somebody else changed it during that short interval.
    private func replaceOriginalText(with text: String) -> Bool {
        guard compactShortcut,
              !text.isEmpty,
              let application = replacementApplication,
              !application.isTerminated
        else { return false }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            snapshot.restore(to: pasteboard)
            return false
        }
        let replacementChangeCount = pasteboard.changeCount
        model?.rebaselineClipboardAfterInAppWrite()

        // Let the button render its confirmation before this unpinned utility
        // window yields focus back to the source app.
        DispatchQueue.main.async { [weak self] in
            guard application.activate() else {
                if pasteboard.changeCount == replacementChangeCount {
                    snapshot.restore(to: pasteboard)
                    self?.model?.rebaselineClipboardAfterInAppWrite()
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                Self.postPasteShortcut()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard pasteboard.changeCount == replacementChangeCount else { return }
                    snapshot.restore(to: pasteboard)
                    self?.model?.rebaselineClipboardAfterInAppWrite()
                }
            }
        }
        return true
    }

    private static func postPasteShortcut() {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func centeredDefaultRect() -> NSRect {
        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        return NSRect(x: screen.midX - 320, y: screen.midY - 280,
                      width: 640, height: 560)
    }

    /// Where a pointer-side window is born — ONE answer for every one of them.
    ///
    /// Beside the pointer: its right side, flipped left when that would cross the
    /// display, with the top edge just above the cursor. A prompt shortcut firing
    /// straight into an answer already opened here; a force click's composer used
    /// to be placed by its CARET instead, so the box wrapped around the cursor
    /// and the two gestures dropped their windows in visibly different places.
    /// The shortcut's placement is the one that survived.
    ///
    /// Pinning the *top* edge is what keeps it true for the rest of the window's
    /// life — every compact resize hangs off that edge (`setCompactHeight`), so
    /// growing into the answer never moves the line the user typed on.
    ///
    /// It clamps to the usable screen frame. The display is `NSScreen.containing`
    /// — the app's single source of truth for "where is the mouse", so a chord
    /// fired at a screen seam or in the menu-bar row can't land the window on a
    /// different monitor.
    ///
    /// `size` lets an already-grown window be re-anchored without shrinking back
    /// to the opening size; it defaults to the size a fresh window is born at.
    private func compactRect(near pointer: NSPoint, size: NSSize? = nil,
                             asComposer: Bool = false) -> NSRect {
        Self.pointerSideRect(
            near: pointer,
            size: size ?? NSSize(width: Self.compactWidth,
                                 height: asComposer
                                     ? composerRestingHeight
                                     : Self.compactInitialHeight))
    }

    /// The frame itself. Static and public to the module because
    /// `ForceClickHerald` has to land its pressure cue on the *same* geometry —
    /// including the clamp. Two places each doing their own version of this
    /// arithmetic is exactly how the cue and the box it becomes would drift apart
    /// at a screen edge.
    static func pointerSideRect(near pointer: NSPoint, size: NSSize? = nil) -> NSRect {
        let visible = NSScreen.containing(pointer)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(size?.width ?? compactWidth, visible.width - screenMargin * 2)
        let height = size?.height ?? compactInitialHeight
        let rightX = pointer.x + pointerGap
        let leftX = pointer.x - pointerGap - width
        let x = rightX + width <= visible.maxX - screenMargin ? rightX : leftX
        let box = NSSize(width: width, height: height)
        return NSRect(origin: clamped(origin: NSPoint(x: x, y: pointer.y + 18 - height),
                                      size: box, in: visible),
                      size: box)
    }

    /// The composer's own frame at that placement — the same box, at the height a
    /// resting one-line composer is born.
    static func composerWindowRect(near pointer: NSPoint,
                                   size: NSSize? = nil) -> NSRect {
        pointerSideRect(near: pointer,
                        size: size ?? NSSize(width: compactWidth,
                                             height: CompactShortcutPromptView.restingHeight))
    }

    /// The input capsule's own screen rect inside that window — what the pressure
    /// cue grows into, and what it must be indistinguishable from at handoff.
    static func composerCapsuleRect(near pointer: NSPoint) -> NSRect {
        let window = composerWindowRect(near: pointer)
        let inset = CompactShortcutMetrics.inset
        let height = CompactShortcutMetrics.capDiameter
        return NSRect(x: window.minX + inset,
                      y: window.maxY - CompactShortcutMetrics.caretOffset.y - height / 2,
                      width: window.width - inset * 2,
                      height: height)
    }

    /// The composer just told us where its caret really is. Remember it for the next
    /// press (and for the pressure cue), then slide this window so the caret sits on
    /// the pointer that summoned it — the opening estimate is corrected inside the
    /// entrance, before there is anything to see.
    private func alignCaret(to offset: CGPoint) {
        // Remembered, not acted on. The offset still says where the input
        // capsule sits INSIDE the window, which is what the pressure cue scales
        // about (`drawPressure`) — but the window is no longer placed by it. It
        // opens beside the pointer like every other pointer-side window
        // (`pointerSideRect`), so sliding it afterwards to put the caret back
        // under the cursor would undo exactly that.
        CompactShortcutMetrics.rememberCaret(offset)
    }

    /// A window origin pulled back inside `visible`, keeping `screenMargin` clear
    /// on every edge. The single definition of "don't touch the sides" for the
    /// pointer-side windows — placement, the caret nudge and every resize go
    /// through it, so they cannot disagree about where the edge is.
    ///
    /// A display too small to hold the window with its margins keeps the leading
    /// and top edges rather than centring it: an overflowing box is better cut
    /// off where nothing is written than in the middle of the line.
    static func clamped(origin: NSPoint, size: NSSize, in visible: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, visible.minX + screenMargin),
                   max(visible.minX + screenMargin,
                       visible.maxX - screenMargin - size.width)),
            y: min(max(origin.y, visible.minY + screenMargin),
                   max(visible.minY + screenMargin,
                       visible.maxY - screenMargin - size.height)))
    }

    /// Where the entrance grows from: the pointer itself, expressed as a unit
    /// point in the window's own frame.
    ///
    /// A caret-placed composer holds the pointer *inside* it, so a corner anchor
    /// would swell the box out of a corner the user isn't looking at — it has to
    /// open from the caret. An answer window sits beside the pointer, which is
    /// outside its frame, so the clamp lands it on the leading or trailing edge
    /// exactly as the old corner test did.
    private func anchorEntrance(rect: NSRect, pointer: NSPoint) {
        guard rect.width > 0, rect.height > 0 else {
            state.entranceAnchor = .topLeading
            return
        }
        state.entranceAnchor = UnitPoint(
            x: min(max((pointer.x - rect.minX) / rect.width, 0), 1),
            y: min(max((rect.maxY - pointer.y) / rect.height, 0), 1))
    }

    /// The pointer-side opening: the window fades up while its content swells
    /// out of the pointer corner (`DetachedSessionRootView.playEntrance`) — one
    /// move, not a fade followed by a settle.
    ///
    /// AppKit derives a borderless window's shadow from the drawn silhouette and
    /// caches it, so a shadow sampled mid-growth would stay a size too small for
    /// the rest of the window's life — it's re-derived once the spring is done.
    private func playPointerEntrance() {
        guard !Self.reduceMotion else {
            window.alphaValue = 1
            return
        }
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak window] in
            window?.invalidateShadow()
        }
    }

    /// A pointer-side window is *defined* by the pointer that summoned it, so a
    /// fresh invocation brings it to where the user is working NOW — even on the
    /// same display. Nothing closes these on focus loss: an unpinned one just
    /// drops behind the app in front, which reads as dismissed. Re-firing it then
    /// used to raise it back at its old spot, a screen away from the selection
    /// that summoned it.
    ///
    /// Two cases keep the window exactly where it is:
    ///   · it's PINNED — the tack means "keep this where I put it";
    ///   · the pointer is already at the window (a re-fire in place), so moving
    ///     it would only nudge a window the user is looking straight at.
    ///
    /// `asComposer` is passed rather than read off `state.session`: a re-fire
    /// re-anchors BEFORE the session is put back to its composer face, so the
    /// state would still say "thread" and place the window by the wrong rule.
    private func reanchorForInvocation(near pointer: NSPoint, asComposer: Bool) {
        guard NSScreen.containing(pointer) != nil else { return }
        let sameDisplay = window.screen?.displayID == NSScreen.containing(pointer)?.displayID
        if window.isVisible, sameDisplay {
            if state.pinned { return }
            // "At the window" = inside it, or within the gap it was placed at.
            let reach = Self.pointerGap * 2
            if window.frame.insetBy(dx: -reach, dy: -reach).contains(pointer) { return }
        }
        // It moved to a new selection, so it *arrives* there: same entrance as a
        // fresh window, replayed in place of a teleport. (The early returns above
        // — pinned, or already under the pointer — leave it alone, and with it
        // the entrance.)
        let target = compactRect(near: pointer, size: window.frame.size,
                                 asComposer: asComposer)
        window.setFrame(target, display: true)
        anchorEntrance(rect: target, pointer: pointer)
        if !Self.reduceMotion {
            state.entranceToken += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak window] in
                window?.invalidateShadow()
            }
        }
    }

    // MARK: The ride (mid-drag, the window follows the mouse)

    private func beginRide() {
        let mouse = NSEvent.mouseLocation
        grabOffset = NSPoint(x: window.frame.origin.x - mouse.x,
                             y: window.frame.origin.y - mouse.y)
        lastMouse = mouse
        lastMouseAt = ProcessInfo.processInfo.systemUptime
        // The original canvas panel owns the AppKit drag session (it took the
        // mouse-down), so its events keep flowing app-locally regardless of what
        // SwiftUI does with the gesture — a local monitor rides them. The window
        // is moved by delta, never by re-anchoring, so the grip point holds.
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDragged: self.follow()
            case .leftMouseUp:      self.settleAfterRide()
            default: break
            }
            return event
        }
    }

    private func follow() {
        guard dragMonitor != nil else { return }
        // Missed mouse-up (app deactivated mid-drag, monitor starved): settle.
        guard NSEvent.pressedMouseButtons & 1 == 1 else {
            settleAfterRide(); return
        }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: mouse.x + grabOffset.x, y: mouse.y + grabOffset.y))

        // Momentum tilt: the window leans a whisper into its horizontal
        // velocity, hinged at the grip. Spring-smoothed on the SwiftUI side;
        // kept subtle — this is a full window in the hand, not a playing card.
        let now = ProcessInfo.processInfo.systemUptime
        let dt = max(now - lastMouseAt, 1.0 / 240.0)
        let vx = (mouse.x - lastMouse.x) / dt
        lastMouse = mouse
        lastMouseAt = now
        if !Self.reduceMotion {
            state.tilt = max(-1.4, min(1.4, vx * 0.0016))
        }
    }

    private func endRide() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
        state.tilt = 0
    }

    // MARK: Settle (release the ride)

    /// The hand lets go: the window stays exactly where it is — it was already
    /// the full window — and just becomes a normal citizen: normal level,
    /// traffic lights fade in, key. The only motion is the tilt springing to
    /// rest; nothing resizes, nothing crossfades.
    private func settleAfterRide() {
        endRide()
        guard state.phase == .riding else { return }
        state.phase = .settled
        finishSettle()
    }

    private func finishSettle() {
        applyPinLevel()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        armSummonGrace()
        armMergeTracking()
    }

    /// Hold this window's focus through the tail of the gesture that opened it.
    ///
    /// A pointer-side window is summoned by a press inside SOMEONE ELSE'S
    /// window, and a force click fires while the button is still down. So the
    /// order of events is: we activate and take key — then the user lifts their
    /// finger, that mouse-up lands in the app underneath, and macOS activates
    /// *it* again. The window we just opened resigns key through no act of the
    /// user's: at `.normal` level it sinks behind that app, and an untouched
    /// composer reads the resign as "the keyboard left" and closes itself
    /// (`windowDidResignKey`) — which is why the box appeared and vanished
    /// before it could be typed in, clicked or dragged.
    ///
    /// For this long, a resign is that echo: key is taken back and nothing
    /// closes. If the button is still down the window waits for the release
    /// first, since the echo cannot arrive before it.
    private func armSummonGrace() {
        guard compactShortcut else { return }
        summonGraceUntil = Date().addingTimeInterval(Self.summonGrace)
        reclaimedAfterSummon = false
        summonReleaseTimer?.invalidate()
        summonReleaseTimer = nil
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
        // A held button, watched by polling rather than by an event monitor: the
        // press belongs to another app, and the mouse-up that ends it may never
        // pass through this process at all.
        let giveUp = Date().addingTimeInterval(3)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, window.isVisible else {
                    return t.invalidate()
                }
                guard NSEvent.pressedMouseButtons & 1 == 0 || Date() > giveUp else { return }
                t.invalidate()
                self.summonReleaseTimer = nil
                // The release is what triggers the other app's activation, so the
                // grace starts counting from here, not from the open.
                self.summonGraceUntil = Date().addingTimeInterval(Self.summonGrace)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        summonReleaseTimer = timer
    }

    /// Take key back after the summoning press handed it to the app underneath.
    ///
    /// Once. Trading activation with the other app for the length of the grace
    /// is a visible flicker and ends in the close anyway; one attempt covers the
    /// echo, and anything after it is the user going somewhere on purpose.
    private func reclaimKeyAfterSummon() {
        guard !reclaimedAfterSummon else { return }
        reclaimedAfterSummon = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isVisible,
                  !window.isKeyWindow, self.isInSummonGrace else { return }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var isInSummonGrace: Bool {
        if summonReleaseTimer != nil { return true }
        guard let summonGraceUntil else { return false }
        return Date() < summonGraceUntil
    }

    /// Pinned (the default) floats the session above normal windows — torn out
    /// to be watched; unpinned it's an ordinary citizen of the window stack.
    private func applyPinLevel() {
        window.level = state.pinned ? .floating : .normal
    }

    private func togglePin() {
        state.pinned.toggle()
        if state.phase == .settled { applyPinLevel() }
    }

    /// The app's editable chords, answered by the window that has the keyboard.
    /// The panel's `KeyEventCatcher` bails whenever its own window isn't key
    /// (one catcher per screen, all of them watching the same local monitor), so
    /// every chord the panel owns is dead inside a torn-out window unless it is
    /// re-served here — including ⌘P, which this window's pin chip advertises in
    /// its tooltip.
    ///
    /// Only the chords whose action EXISTS in this window are claimed; the rest
    /// fall through to the system, exactly as they do over settings in the
    /// panel. ⌘F (the recent-list filter), ⌘⇧I (the picker card), ⌘N (a fresh
    /// chat) and ⌃⇧= (detach) all name panel-only surfaces — a detached window
    /// has no recent list, no picker and no idle prompt, and it is already
    /// detached — so swallowing them here would only make them fizzle.
    private func handleAppShortcut(_ event: NSEvent) -> Bool {
        // While a chord is being recorded in Shortcuts the keyboard belongs to
        // the recorder — same rule the panel's catcher opens with.
        if ShortcutRecording.isActive { return false }
        // ⌘P floats/unfloats the window — the keyboard twin of the header's pin
        // chip. Unguarded by the field editor: ⌘P is not a text-editing key, and
        // pinning mid-follow-up is exactly when you want it.
        if AppShortcutStore.matches(.pin, event: event) {
            togglePin()
            return true
        }
        // ⌘C / ⌘R mirror the answer footer's copy and regenerate. Guarded on the
        // follow-up field the way the panel guards its composer: with the caret
        // in text, ⌘C copies the selection and ⌘R stays out of the way.
        if window.firstResponder is NSText { return false }
        guard let store = threadStore,
              !store.turns.contains(where: { $0.streaming }) else { return false }
        if AppShortcutStore.matches(.copyAnswer, event: event) {
            // Verbatim markdown — the `doc.on.doc` footer button's text, not the
            // plain-text twin beside it (which has no chord in the panel either).
            let answer = store.turns.last(where: { $0.role == "assistant" })?.text
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !answer.isEmpty else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(answer, forType: .string)
            model?.rebaselineClipboardAfterInAppWrite()
            return true
        }
        if AppShortcutStore.matches(.regenerate, event: event) {
            // The footer's own gate: only the last settled turn, and never an
            // agent report (it has no round to re-run).
            guard let last = store.turns.last, last.role == "assistant",
                  !last.isAgent else { return false }
            model?.regenerateDetachedAnswer(threadID: store.threadID)
            return true
        }
        return false
    }

    // MARK: Merge back (drag the window home to the notch)

    /// While the settled window rides a user drag, watch its position against
    /// every screen's resting-notch zone; hovering the zone swells the island
    /// (the "it'll take it back" hint), releasing inside it merges the session
    /// home: the window sinks toward the notch and the panel reopens on it.
    private func armMergeTracking() {
        guard moveObserver == nil else { return }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A pointer-side shortcut window is a transient utility surface,
                // not a torn-out session: there is nothing to hand back to the
                // notch, and the zone reaches far enough (80×56 around the notch)
                // that simply dragging the box out of the way near the top of the
                // screen swallowed it. Moving a window must never be a way to
                // lose it.
                guard !self.compactShortcut else { return }
                self.windowMoved()
            }
        }
    }

    private func windowMoved() {
        guard state.phase == .settled, let model else { return }
        // Only a live user drag can merge — programmatic moves don't count.
        guard NSEvent.pressedMouseButtons & 1 == 1 else { return }
        let inZone = mergeDisplay() != nil
        if inZone != mergeArmed {
            mergeArmed = inZone
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                model.detachMergeHint = inZone
            }
            if inZone { Haptics.alignment() }
        }
        if inZone { watchForMergeDrop() }
    }

    /// The display whose notch zone the window's top edge is currently inside.
    private func mergeDisplay() -> CGDirectDisplayID? {
        guard let model else { return nil }
        let topCenter = NSPoint(x: window.frame.midX, y: window.frame.maxY)
        for display in model.knownDisplays {
            guard let notch = model.restingNotchScreenRect(on: display) else { continue }
            if notch.insetBy(dx: -80, dy: -56).contains(topCenter) { return display }
        }
        return nil
    }

    /// The mouse is down inside the zone — poll for the release that commits the
    /// merge (during a native window drag the app sees no mouse-up event, so a
    /// short poll on `pressedMouseButtons` is the reliable end-of-drag signal).
    private func watchForMergeDrop() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.mergeArmed, self.state.phase == .settled else { return }
            if NSEvent.pressedMouseButtons & 1 == 1 { self.watchForMergeDrop(); return }
            if self.mergeDisplay() != nil {
                self.mergeBack(animated: !Self.reduceMotion)
            } else {
                self.disarmMergeHint()
            }
        }
    }

    private func disarmMergeHint() {
        mergeArmed = false
        if let model, model.detachMergeHint {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                model.detachMergeHint = false
            }
        }
    }

    /// Close the window and hand the session back to the notch panel. With
    /// animation, the window sinks toward the notch as it fades — the reverse
    /// of the tear-off — while the island unfurls to receive it.
    func mergeBack(animated: Bool) {
        guard let model else { window.close(); return }
        let display = mergeDisplay() ?? model.knownDisplays.first
        disarmMergeHint()
        state.phase = .merging

        let reopen = { [weak self] in
            guard let self else { return }
            model.reattachDetachedSession(self.session,
                                          snapshot: self.threadStore?.turns,
                                          draft: self.state.composeDraft,
                                          on: display)
            self.window.close()
        }

        if animated, let notch = display.flatMap({ model.restingNotchScreenRect(on: $0) }) {
            let target = NSRect(x: notch.midX - 160, y: notch.minY - 60,
                                width: 320, height: 88)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.26
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0.05, 0.85, 0.6)
                window.animator().setFrame(target, display: true)
                window.animator().alphaValue = 0
            } completionHandler: { reopen() }
        } else {
            reopen()
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        hasHeldKey = true
        // The user came back mid-retreat (clicked the capsule while it was on its
        // way out). Put the window back at full strength — the fade already wrote
        // alpha down the animator's path, so it has to be written back by hand.
        guard state.exiting else { return }
        state.exiting = false
        window?.animator().alphaValue = 1
    }

    /// A force-click composer nobody typed into takes itself off screen the
    /// moment the keyboard leaves it.
    ///
    /// Nothing else ever closed it. Unpinned it only *slips behind* the app in
    /// front, which reads as gone — but it is still there, on every Space
    /// (`.moveToActiveSpace`), and the next `NSApp.activate(ignoringOtherApps:)`
    /// from any other part of the app raises it back over everything. A gesture
    /// as easy to trip as a force click then leaves a trail of empty capsules
    /// that keep reappearing, which is what `retirePointerWindows` was patching
    /// from the far end (retire the *previous* one when a new one opens) instead
    /// of never leaving one behind.
    ///
    /// Only the untouched composer goes. A draft, an answer, or a tack is the
    /// user's, and stays until they close it.
    func windowDidResignKey(_ notification: Notification) {
        // Still inside the gesture that opened this window: the app underneath
        // has just taken activation back off the summoning click. That is not
        // the user leaving — take key back and close nothing.
        if isInSummonGrace { return reclaimKeyAfterSummon() }
        guard isUntouchedComposer else { return }
        // Resign also fires on the way *to* another window of this app, and
        // AppKit can hand key across in two steps. Settle first, then check.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isUntouchedComposer,
                  let window = self.window, window.isVisible, !window.isKeyWindow
            else { return }
            self.fadeOutAndClose()
        }
    }

    /// A pointer-side composer with nothing in it and nothing holding it open.
    private var isUntouchedComposer: Bool {
        guard compactShortcut, hasHeldKey, !state.pinned, !isDrawingPressure,
              case .shortcutComposer = state.session
        else { return false }
        // The pointer is ON the box. Whatever took the keyboard away, the user is
        // reaching for this — picking it up, going for one of its shortcuts,
        // about to type in it. A window is never taken out from under the hand
        // that is on it, and this is what closed the box mid-drag: the press
        // that grabbed it also handed activation back to the app underneath, and
        // the box read that as the keyboard leaving and dissolved.
        if let window,
           window.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation) {
            return false
        }
        return state.compactPromptDraft
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The entrance, run backwards: the face settles back toward the pointer it
    /// grew out of while the window sinks under it.
    ///
    /// A bare alpha ramp on its own was the stiff version — the capsule arrives by
    /// swelling out of the caret over a 0.36s spring and left by simply ceasing to
    /// be there, on a curve half that long, with nothing moving. The shape has to
    /// go the way it came: `state.exiting` collapses the face on its entrance
    /// anchor, and the window's own alpha carries the shadow (which AppKit derives
    /// from the silhouette and will not fade with SwiftUI's opacity) out with it.
    private func fadeOutAndClose() {
        guard let window else { return }
        guard !Self.reduceMotion else { return window.close() }
        state.exiting = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.26
            // Holds near full for the first third, so the collapse is *seen*
            // before the window is gone; a symmetric ease would have faded the
            // shape out from under its own move.
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.85, 0.35)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // Key came back during the retreat: `windowDidBecomeKey` has already
            // put it back, and this completion is the tail of a cancelled fade.
            guard let self, let window = self.window,
                  !window.isKeyWindow, self.state.exiting else { return }
            window.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        endRide()
        stopCompactGlide()
        // The reveal's commit now also rides SwiftUI's animation completion, which
        // no work item can cancel — the generation bump is what retires it.
        compactRevealGeneration += 1
        compactRevealCompletion?.cancel()
        compactRevealCompletion = nil
        state.onRevealArmed = nil
        summonReleaseTimer?.invalidate()
        summonReleaseTimer = nil
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        disarmMergeHint()
        if let threadStore {
            // Match the main panel's close semantics for Force Touch: closing the
            // surface drops our cancellation handle, never the round itself. The
            // task keeps feeding its in-flight snapshot and settles into Recent.
            if state.forceTouchInvocation {
                model?.detachCompactRound(threadID: threadStore.threadID)
            }
            model?.releaseDetachedThread(threadStore.threadID)
        }
        Self.controllers.removeAll { $0 === self }
    }
}

// MARK: - Window content

/// The window's one mutable knob set: its life phase (riding the drag →
/// settled → merging away), the ride's momentum tilt, and whether it floats
/// pinned above other windows (the default — a torn-out session is a thing
/// being watched; unpin demotes it to a normal window).
@MainActor
final class DetachedWindowState: ObservableObject {
    enum Phase { case riding, settled, merging }
    @Published var phase: Phase = .riding
    @Published var tilt: Double = 0
    @Published var pinned = true
    /// What the window holds. Mutable because a `.compose` window becomes the
    /// `.thread` it starts — the same window keeps writing where the composer
    /// stood, so this can't be fixed at birth.
    @Published var session: DetachedSession
    /// The live mirror of the thread being watched — nil while composing.
    @Published var threadStore: DetachedThreadStore?
    /// The composer's unsent line: seeded from the panel's box at tear-off, and
    /// handed back to it on a merge home.
    @Published var composeDraft = ""
    /// The empty-prompt shortcut's captured context and one-off instruction.
    /// They live on the window state so invoking the same shortcut again can
    /// atomically replace both without creating a second controller.
    @Published var compactSourceText = ""
    @Published var compactPromptDraft = ""
    @Published var compactPromptGeneration = 0
    /// The corner the pointer summoned this window from — the entrance grows out
    /// of it, so the window reads as opening *from* the selection rather than
    /// fading in on top of it. Trailing when it had to open on the pointer's
    /// left (`DetachedSessionWindowController.compactRect`).
    @Published var entranceAnchor: UnitPoint = .topLeading
    /// True when a force click already stretched this capsule into place
    /// (`ForceClickHerald`). The face then skips its own swell — replaying it over
    /// the identical shape the press is holding is exactly the cross-fade the
    /// stretch exists to avoid. The badge under the box still arrives on its own
    /// beat.
    @Published var grownIn = false
    /// How far the force click that is drawing this window has come, 0…1 — `nil`
    /// once it has fired and this is an ordinary composer.
    ///
    /// While it is set, the window draws its input capsule's rounded left cap and
    /// nothing else: no field, no band, no badge. That cap is not a stand-in for
    /// the composer's capsule, it IS the composer's capsule at its cap width, so
    /// firing only springs one number. Two surfaces were tried first — a cue panel
    /// above the window — and could not be made to hand over invisibly: `.clear`
    /// Liquid Glass multiplies, so the frames where both stood came out more than
    /// twice as dark as either alone.
    @Published var pressDepth: Double?
    /// Bumped whenever the window lands at a new pointer without being re-made
    /// (the same shortcut fired again somewhere else) — the face replays its
    /// entrance there instead of teleporting.
    @Published var entranceToken = 0
    /// True while the answer face is taking over from THIS window's own composer
    /// (Enter in the capsule). The card is then already standing when it appears —
    /// no swell, no fade up from nothing: the capsule opens into it as one move.
    /// An entrance here would read as a second, foreign window popping over the
    /// line the user just typed, which is exactly what the morph exists to avoid.
    @Published var openingFromComposer = false
    /// True when this pointer-side shell was summoned by an actual Force Touch,
    /// rather than the selected-text keyboard action that reuses the same view.
    /// Drives both the scoped History affordance and the origin stamp on submit.
    @Published var forceTouchInvocation = false
    /// The inline ledger beneath the Force Touch composer. Its height is part of
    /// this window's own measured face; it never opens a secondary window.
    @Published var forceTouchHistoryExpanded = false
    /// During a discrete compact resize the actual window is already at the
    /// destination size (or stays at its old size until a collapse completes).
    /// This top-aligned mask is the only animated edge, so the window's upper
    /// border never participates in the disclosure animation.
    @Published var compactRevealHeight: CGFloat? = nil
    /// Whether the next swap between the card's two faces is NAVIGATION — a saved
    /// conversation opened out of the ledger, or Back out of it — rather than the
    /// capsule morphing into the answer it was just asked for. The two read
    /// differently on purpose; see `compactFaceTransition`.
    @Published var compactFaceDrills = false
    /// Called by the face the first time SwiftUI has actually DRAWN a freshly
    /// installed `compactRevealHeight`. The controller may only grow the NSWindow
    /// once that has happened — see `animateCompactHeight`, where waiting on this
    /// rather than on a guessed delay is what removes the flash.
    var onRevealArmed: (() -> Void)?
    /// The window is on its way out (`fadeOutAndClose`). The composer face reads
    /// it to collapse back onto its entrance anchor instead of just vanishing.
    @Published var exiting = false

    init(session: DetachedSession) {
        self.session = session
    }
}

/// Root view: the glass slab, wearing the tear-off card while riding the drag
/// and crossfading into the full session view on landing.
struct DetachedSessionRootView: View {
    @ObservedObject var state: DetachedWindowState
    /// Only the composer talks to the panel model directly (its placeholder, its
    /// armed bucket, its note-save feedback all live there) — and only IT
    /// observes it. Held here as a plain reference on purpose: observing the
    /// model at this level would re-render a streaming thread window on every
    /// unrelated model publish.
    let model: NotchModel
    /// The answer's voice, tracked on its own key so this view can follow the
    /// setting live without observing the whole model — see `sessionBody`.
    @AppStorage(Handwriting.defaultsKey) private var handwrittenAnswers = false
    var onTogglePin: () -> Void
    var onClose: () -> Void
    // Thread-window actions (unused by the agent-task face, which talks to
    // `AgentTaskManager` directly).
    var onInAppCopy: () -> Void = {}
    var onReplaceOriginal: (String) -> Bool = { _ in false }
    var onFollowUp: (String, [NSImage]) -> Void = { _, _ in }
    var onRegenerate: () -> Void = {}
    var onRegenerateWith: (String) -> Void = { _ in }
    var onChooseOption: (UUID, String) -> Void = { _, _ in }
    var regenerateOptions: () -> [(model: String, isCurrent: Bool)] = { [] }
    /// Enter in the composer face: the line and where it reads as going.
    var onCompose: (String, NotchModel.Panel) -> Void = { _, _ in }
    /// The composer's wanted height as its draft wraps — the window follows it.
    var onComposeHeight: (CGFloat) -> Void = { _ in }
    /// Enter in an empty-prompt shortcut's one-line composer — or a tap on one
    /// of the shortcut buttons standing over it, which carries that shortcut's
    /// own pinned backend with it.
    var onCompactPrompt: (String, ModelPin?) -> Void = { _, _ in }
    var onToggleForceTouchHistory: () -> Void = {}
    var onOpenForceTouchHistory: (UUID) -> Void = { _ in }
    /// Where the composer's caret laid out, in the window's own coordinates — the
    /// window is placed by it rather than by counted insets.
    var onCaretOffset: (CGPoint) -> Void = { _ in }
    /// Compact prompt-shortcut threads size to their answer instead of taking a
    /// fixed session-window frame.
    var compactShortcut = false
    var onThreadHeight: (CGFloat) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Has the pointer-side entrance played? False for exactly one frame per
    /// appearance — see `playEntrance`.
    @State private var entered = false
    /// Native-notification-style corner actions stay out of the composer's way
    /// until the pointer is actually over this compact surface.
    @State private var compactHovering = false

    /// The window's own silhouette — the glass draws it (the window is
    /// borderless), continuous-rounded like the island's bottom corners.
    ///
    /// Exactly the open island's bottom radius (`ContentView.bottomRadius`, 30),
    /// which is also what the prompt-shortcut card already wore
    /// (`CompactShortcutMetrics.corner`). ONE radius across every detached face:
    /// a torn-out session and a pointer-side answer are the same window at two
    /// sizes, so they cannot round differently. (It used to be 16 here, which
    /// read as a second, squarer species of window beside the 30 of the
    /// shortcut card.)
    static let cornerRadius: CGFloat = 30

    /// The empty-prompt shortcut face paints NO window slab: its context badge
    /// floats free above a capsule input, and those two pieces *are* the window
    /// (see `CompactShortcutPromptView`). Every other face — threads, composer,
    /// agent tasks — rides the smoked glass slab.
    private var isBareComposer: Bool {
        if case .shortcutComposer = state.session { return true }
        return false
    }

    /// History grows the composer downward without changing the curve it wore
    /// while collapsed. The answer remains the ordinary detached-window shape.
    private var compactCornerRadius: CGFloat {
        isBareComposer ? CompactShortcutPromptView.cardCornerRadius : Self.cornerRadius
    }

    var body: some View {
        Group {
            if compactShortcut {
                compactShortcutFace
            } else {
                slab(corner: Self.cornerRadius)
            }
        }
        .rotationEffect(.degrees(state.tilt), anchor: .top)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.62), value: state.tilt)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: state.phase)
    }

    /// The prompt-shortcut window's two faces. The **composer** is a band, a
    /// capsule and a footnote badge floating free over the app underneath. The
    /// **answer** is not a special card any more — it is the ordinary detached
    /// session slab (`DetachedThreadView`: header, thread, follow-up), filling
    /// the window inside the same 8pt margin, so a pointer-side answer and a
    /// torn-out session are one window at two sizes rather than two styles.
    ///
    /// Both faces are the same card in the same place: the chips row on top, a
    /// capsule on the bottom, and between them either the user's shortcuts or
    /// the answer. Enter replaces the middle and lets the bottom edge travel —
    /// it does not move the card.
    private var compactShortcutFace: some View {
        ZStack(alignment: .top) {
            compactGlass
            compactFaceContent
        }
        // The reveal mask is on the card as of this update pass. Nothing about
        // the window's size may move before this fires (`animateCompactHeight`).
        .onChange(of: state.compactRevealHeight) { _, _ in state.onRevealArmed?() }
        // History and composer-to-result resizing reveal downward from the
        // existing top edge. The NSWindow itself is never resized per frame.
        //
        // The reveal edge carries the CARD's own bottom corners, not a straight
        // cut. A plain `Rectangle` mask sliced the sheet on a hard horizontal
        // line, so for the whole 0.28s disclosure the window wore square bottom
        // corners and only snapped round on the last frame — the disclosure read
        // as a box being unrolled rather than the card growing. So the mask is
        // the card's silhouette: inset by the window's own transparent margin
        // (nothing is ever drawn out there, so nothing is lost) and rounded at
        // the bottom on the same radius the slab wears. The top stays a square
        // full-bleed edge — the mask only ever cuts downward, and the band and
        // chips above the card must never be touched by it.
        .mask(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: compactCornerRadius,
                                   bottomTrailingRadius: compactCornerRadius,
                                   style: .continuous)
                .padding(.horizontal, CompactShortcutMetrics.inset)
                .padding(.bottom, CompactShortcutMetrics.inset)
                .frame(height: state.compactRevealHeight ?? 10_000,
                       alignment: .top)
        }
        // Added after the reveal mask so the notification-style composer
        // controls can genuinely cross the card edge instead of being clipped
        // back to its silhouette.
        .overlay(alignment: .top) { compactChrome }
        // ONE entrance for the sheet and whatever is drawn on it. Split across
        // the two faces (as it was) the glass and its content could be caught
        // mid-morph playing different transforms — the exact seam this whole
        // arrangement exists to remove.
        .modifier(CompactEntrance(bare: isBareComposer, entered: entered,
                                  grownIn: state.grownIn, exiting: state.exiting,
                                  anchor: state.entranceAnchor,
                                  reduceMotion: reduceMotion))
        // Enter in this window's OWN capsule is not an arrival: the card is the
        // box the user is already looking at, grown. Replaying the pointer
        // entrance there made it read as a second window popping over the line
        // just typed (see `submitCompactShortcutPrompt`).
        .onAppear {
            if !isBareComposer, state.openingFromComposer { entered = true }
            else { playEntrance() }
        }
        .onChange(of: state.entranceToken) { _, _ in playEntrance() }
        .onHover { compactHovering = $0 }
    }

    /// Close keeps the native-notification position on the card's upper-left
    /// corner. Settings now lives beside the History disclosure in the composer
    /// row, so the right corner deliberately stays empty.
    @ViewBuilder
    private var compactChrome: some View {
        if isBareComposer {
            HStack(spacing: 0) {
                CompactNotificationCloseButton(action: onClose)

                Spacer(minLength: 0)
            }
            // The card begins at this y/x inset. Pulling the 18pt control 4pt
            // across that boundary leaves a deliberate notification-style
            // overhang without clipping it against the NSWindow.
            .padding(.horizontal, 2)
            .padding(.top, CompactShortcutMetrics.inset
                     + CompactShortcutMetrics.band
                     + CompactShortcutMetrics.gap - 4)
            .opacity(compactHovering && state.pressDepth == nil ? 1 : 0)
            .allowsHitTesting(compactHovering && state.pressDepth == nil)
            .animation(
                reduceMotion ? nil : .easeOut(duration: compactHovering ? 0.22 : 0.12),
                value: compactHovering
            )
            .transition(Self.cornerMarkTransition(arriving: false))
        } else {
            compactAnswerChips
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(Self.cornerMarkTransition(arriving: true))
        }
    }

    /// The corner's two marks HAND OVER — they never share the corner.
    ///
    /// They are different objects in different places: the composer's close is an
    /// 18pt circle at (2, 44), deliberately overhanging the card's top edge by
    /// 4pt the way a notification's does; the card's is a ~62x32 segment cluster
    /// at (16, 56), sitting inside the card. Twelve points apart vertically,
    /// fourteen horizontally, and different sizes. Cross-fading them — which is
    /// what an undeclared `if/else` inside an animated transaction does — puts
    /// two rounded glass shapes over each other in one 40pt corner, on top of the
    /// composer's own input line still dissolving underneath. That is the pile-up
    /// at the top-left, and it only shows when the pointer is on the card, which
    /// a force click guarantees (the composer's close is hover-gated).
    ///
    /// So the outgoing mark is gone before the incoming one starts, on the same
    /// numbers the card's contents use (`compactFaceTransition`, morph case) —
    /// the corner is briefly empty, exactly like the glass in the middle of the
    /// move, and the hand-over reads as one thing becoming another.
    private static func cornerMarkTransition(arriving: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(
                .easeOut(duration: arriving ? 0.22 : 0.20)
                    .delay(arriving ? 0.10 : 0.08)),
            removal: .opacity.animation(.easeIn(duration: 0.10)))
    }

    private var compactAnswerChips: some View {
        let pinned = state.pinned
        // Close leads the cluster on the card's upper-LEFT corner, matching the
        // bare composer's notification-style close rather than sitting opposite
        // it.
        var segments: [GlassSegmentCluster.Segment] = [
            .init(id: "compact-close", tooltip: L("detached.close"), action: onClose) {
                Image(systemName: "xmark")
                    .font(.sf(11, weight: .semibold))
            }
        ]
        // A Force Touch card carries its own composer and ledger — the answer is
        // one face of THIS window, not a dead end. Back returns to it in place.
        if state.forceTouchInvocation {
            segments.append(.init(id: "compact-back",
                                  tooltip: L("recent.collapse"),
                                  action: onToggleForceTouchHistory) {
                Image(systemName: "chevron.left")
                    .font(.sf(11, weight: .semibold))
            })
        }
        // An unpinned answer stays quiet: the pin appears only after the keyboard
        // shortcut pins it, making the held state visible and clickable to undo.
        if pinned {
            segments.append(.init(id: "compact-primary",
                                  engaged: true,
                                  tooltip: shortcutHelp("result.unpin", action: .pin),
                                  action: onTogglePin) {
                PinStateGlyph(pinned: true, size: 12.5, weight: .semibold)
            })
        }
        return GlassSegmentCluster(segments: segments, showsTooltips: false)
        .padding(.top, CompactShortcutMetrics.inset + CompactShortcutMetrics.band
                 + CompactShortcutMetrics.gap + DetachedThreadView.compactCardPadding)
        .padding(.leading, CompactShortcutMetrics.inset
                 + DetachedThreadView.compactCardPadding)
        // While a force click is still being decided the window is drawn as a
        // bare cap — the same gate the card's own content is behind.
        .opacity(state.pressDepth == nil ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: pinned)
    }

    /// What is drawn ON the sheet: only the content crosses over, never the glass
    /// under it. How it crosses is `compactFaceTransition`.
    @ViewBuilder
    private var compactFaceContent: some View {
        if isBareComposer {
            compactComposerFace
                .transition(compactFaceTransition(composer: true))
        } else {
            slab(corner: Self.cornerRadius, glass: false)
                .padding(CompactShortcutMetrics.inset)
                // Sits on the sheet, which hangs below the band in both faces.
                .padding(.top, CompactShortcutMetrics.band + CompactShortcutMetrics.gap)
                .transition(compactFaceTransition(composer: false))
        }
    }

    /// How the card's two faces trade places — one of two verbs, chosen by
    /// whoever changed the session (`state.compactFaceDrills`).
    ///
    /// **Morph.** Enter in the capsule. Only the contents cross-fade, the
    /// composer's leaving quickly and the card's arriving a beat later, so the
    /// glass is visibly alone in the middle of the move. That beat is the whole
    /// point: it reads as one surface reshaping, not two slabs swapping.
    ///
    /// **Drill.** A saved conversation opened out of the ledger, and Back out of
    /// it. Nothing travels — a sideways page push was tried here first and is far
    /// too heavy a move for a 370pt card whose height is also landing in one set.
    ///
    /// A BATON PASS, not an overlap: the leaving page is gone before the arriving
    /// one starts (the insertion's delay is exactly the removal's duration).
    /// Running them together — which is what a literal cross-fade does — puts two
    /// full pages of text on the card at half strength each, and at these
    /// durations both are perfectly legible at once: six ledger rows and four
    /// lines of answer, interleaved. That double exposure is the mess; length
    /// only made it easier to read.
    ///
    /// Still deliberately slower than the morph's, so the dissolve is something
    /// you watch rather than a cut with a smear on it.
    private func compactFaceTransition(composer: Bool) -> AnyTransition {
        guard state.compactFaceDrills, !reduceMotion else {
            return .asymmetric(
                insertion: .opacity.animation(
                    .easeOut(duration: composer ? 0.20 : 0.22)
                        .delay(composer ? 0.08 : 0.10)),
                removal: .opacity.animation(.easeIn(duration: 0.10)))
        }
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.30).delay(0.14)),
            removal: .opacity.animation(.easeIn(duration: 0.14)))
    }

    /// The one piece of glass both compact faces are drawn on.
    ///
    /// The composer and the answer are not two surfaces that trade places — they
    /// are ONE card whose contents are replaced. Three of its edges are the
    /// window's own 8pt margin and the fourth, the top, sits below the same
    /// transparent band in both states: on Enter nothing about this sheet moves
    /// except its bottom edge, which follows the window down as the answer
    /// arrives (`glideCompact`).
    ///
    /// The top edge used to RISE into the band as the card opened, taking the
    /// chips row and the card's whole top margin with it. That is a window
    /// changing shape, and it read as one — a second box appearing over the line
    /// just typed. The band stays.
    ///
    /// It is also the force-click cue: the press narrows this same sheet to the
    /// card's left cap and deepens its fill, and firing springs it back to full
    /// width (`openFromPressure`). One surface for the pointer thickening into an
    /// object, the composer it becomes, and the card that opens out of it.
    private var compactGlass: some View {
        let pressing = state.pressDepth != nil
        let depth = state.pressDepth ?? 1
        let shape = RoundedRectangle(cornerRadius: compactCornerRadius, style: .continuous)
        // The card's height while the disclosure is in flight — the reveal's own
        // value, minus the chrome this glass hangs below, so the veil's hem stays
        // on the card's bottom edge for every frame of the fold. `nil` at rest,
        // where the surface and the card are the same thing.
        let card = state.compactRevealHeight.map {
            max($0 - CompactShortcutMetrics.chrome, 0)
        }
        return CompactComposerGlass(shape: shape, cardHeight: card)
            // The fill deepens with the press and is fully there by the time the
            // stretch begins, so the shape stops changing character mid-flight.
            .overlay(shape.fill(Color.black.opacity(0.01 + 0.34 * (1 - depth))))
            // The slab's top sheen — the one thing the answer's glass carries
            // that the composer's does not. It fades in with the card rather
            // than arriving with a new surface behind it.
            .overlay {
                LinearGradient(colors: [.white.opacity(0.05), .white.opacity(0.0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .blendMode(.plusLighter)
                    .clipShape(shape)
                    .opacity(isBareComposer ? 0 : 1)
            }
            // A rim while it is a cue — the pointer thickening into an object —
            // easing to the composer's own bare card as it opens, and coming
            // back as the window's hairline once it is a card.
            .overlay(shape.strokeBorder(
                Color.white.opacity(pressing ? 0.16 + 0.16 * depth : 0), lineWidth: 1))
            .overlay(shape.strokeBorder(Tokens.hairline, lineWidth: 1)
                        .opacity(isBareComposer ? 0 : 1))
            .frame(width: pressing ? CompactShortcutMetrics.capDiameter : nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The band this card hangs below — the same in both faces, so the
            // top edge is fixed and only the bottom one travels.
            .padding(.top, CompactShortcutMetrics.band + CompactShortcutMetrics.gap)
            .padding(CompactShortcutMetrics.inset)
    }

    /// The empty-prompt shortcut's composer: a band held clear on top, and the
    /// card.
    ///
    /// There is no "Using copied text" footnote under it any more. The window is
    /// only ever summoned ON a selection, so the badge said the one thing that
    /// was never in doubt — and it cost a whole band of height plus the beat of
    /// motion to bring it in. (Its × dropped the captured text, which went with
    /// it: an answer about nothing is not what anyone presses for.)
    private var compactComposerFace: some View {
        face
        // The space the caret reports its position in: this view fills the window's
        // content, so an offset measured here is an offset from the window's corner
        // (`CompactShortcutMetrics.caretOffset`).
        .coordinateSpace(.named(CompactShortcutMetrics.faceSpace))
    }

    /// The composer's drawn half — everything the entrance transform acts on.
    private var face: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Carries nothing — it holds the card's top edge where the answer
            // card's header will land, and the window is transparent, so an
            // empty band shows nothing at all. (The composer's own two chips
            // live INSIDE the card, on its first row: a control that acts on
            // the box has to sit on the box.)
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: CompactShortcutMetrics.band)
            compactBox
                .padding(.top, CompactShortcutMetrics.gap)
        }
        .padding(CompactShortcutMetrics.inset)
    }

    /// Straight to the page these buttons came from: Settings → Shortcuts, whose
    /// first group IS the prompt-shortcut list. The composer closes behind it —
    /// the settings panel opens at the notch, and leaving a floating box standing
    /// at the pointer over it is a second surface asking for the same attention.
    private func openShortcutSettings() {
        model.settingsSection = InlineSettingsView.Section.shortcuts.rawValue
        NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
        onClose()
    }

    /// Collapse the face to its seed and let it spring open. The collapsed state
    /// has to be drawn once before the spring, or a replay (same window, new
    /// pointer) would animate from the size it is already at — i.e. not at all.
    private func playEntrance() {
        guard !reduceMotion else { entered = true; return }
        entered = false
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                entered = true
            }
        }
    }

    /// The composer face's lower half: the instruction capsule. (The answer it
    /// becomes is no longer a box inside this frame — it is the window's own
    /// slab, see `compactShortcutFace`.)
    private var compactBox: some View { sessionBody }

    /// `glass: false` for the compact prompt-shortcut face, whose glass is the
    /// shared sheet underneath (`compactGlass`) — a slab of its own drawn here
    /// would be a second surface cross-fading over the one that is stretching.
    private func slab(corner: CGFloat, glass: Bool = true) -> some View {
        ZStack {
            if !isBareComposer {
                if glass { DetachedWindowGlass() }
            }
            // The full session from frame one — riding and settled look the
            // same; merging just dissolves on the way home.
            sessionBody
                .opacity(state.phase == .merging ? 0 : 1)
        }
        // An image opened out of this window's thread covers this window, not
        // the panel it was torn from — each surface hosts its own lightbox.
        .imageLightboxHost()
        // The glass carves the window's rounded form itself; the rim rides on
        // top of the clipped result so the edge highlight stays crisp.
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            if !isBareComposer, glass {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Tokens.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var sessionBody: some View {
        sessionContent
            // Same injection as the panel root (see `ContentView`): a detached
            // thread is the same answer in another window and must speak in the
            // same voice.
            //
            // Read from defaults rather than from `model.handwrittenAnswers`,
            // even though the model is right there: this view holds the model
            // *unobserved* on purpose (see the property above), so reading the
            // published value here would render the current setting once and then
            // never update — the toggle would appear to do nothing in an already
            // open window. `@AppStorage` invalidates on this one key only, which
            // keeps the "don't re-render a streaming thread on unrelated model
            // publishes" property that the plain reference exists to protect.
            .environment(\.handwritten, HandwritingFeature.isEnabled && handwrittenAnswers)
    }

    @ViewBuilder
    private var sessionContent: some View {
        if case .shortcutComposer = state.session {
            CompactShortcutPromptView(
                state: state,
                historyItems: model.forceTouchHistory,
                onSubmit: onCompactPrompt,
                onToggleHistory: onToggleForceTouchHistory,
                onOpenHistory: onOpenForceTouchHistory,
                onOpenSettings: openShortcutSettings,
                onDisable: { scope in
                    model.disableForceTouch(scope)
                    onClose()
                },
                onDesiredHeight: liveHeight(from: state.session),
                onCaretOffset: onCaretOffset)
                .id(state.compactPromptGeneration)
        } else if state.session == .compose {
            DetachedComposeView(state: state, model: model, pinned: state.pinned,
                                onTogglePin: onTogglePin,
                                onClose: onClose, onSubmit: onCompose,
                                onDesiredHeight: onComposeHeight)
        } else if let taskID = state.session.taskID {
            DetachedAgentTaskView(taskID: taskID, pinned: state.pinned,
                                  onTogglePin: onTogglePin,
                                  onClose: onClose)
        } else if let threadStore = state.threadStore {
            DetachedThreadView(store: threadStore, pinned: state.pinned,
                               onTogglePin: onTogglePin,
                               onClose: onClose,
                               onInAppCopy: onInAppCopy,
                               onReplaceOriginal: onReplaceOriginal,
                               onFollowUp: onFollowUp,
                               onRegenerate: onRegenerate,
                               onRegenerateWith: onRegenerateWith,
                               onChooseOption: onChooseOption,
                               regenerateOptions: regenerateOptions,
                               compactShortcut: compactShortcut,
                               onDesiredHeight: liveHeight(from: state.session))
        }
    }

    /// A height report, honoured only while the face that sent it is still the
    /// one the window belongs to.
    ///
    /// Both compact faces report through the same channel, and the outgoing one
    /// stays in the tree for the whole cross-fade — by which time the window has
    /// ALREADY landed on the incoming face's height. So the leaving view re-lays
    /// itself out inside that new frame and dutifully reports what IT would like
    /// to be. Acted on, that hard-sets the window back to the height of the page
    /// being left, and the arriving page's own report then undoes it: the
    /// jump-and-return on the way out of a conversation, visible for exactly
    /// those entries whose card was a different height from the ledger.
    ///
    /// The session is captured when the branch builds its view, so it is the one
    /// that face belongs to for as long as that face exists.
    private func liveHeight(from session: DetachedSession) -> (CGFloat) -> Void {
        { [weak state] h in
            guard state?.session == session else { return }
            onThreadHeight(h)
        }
    }
}

/// The pointer-side window's entrance, applied ONCE to the glass and the face
/// it carries together (`DetachedSessionRootView.compactShortcutFace`).
///
/// **Composer.** The whole face closes IN on itself: drawn a touch oversized and
/// settling to true size about its own centre, so every edge travels inward at
/// once and the box arrives by coming into focus rather than by growing out of a
/// corner — the Spotlight move. 1.04 is bounded by the face's own 8pt margin, so
/// the overhang stays inside the window and nothing is clipped mid-flight.
/// Leaving, only the shape moves: the fade belongs to the window, whose alpha
/// takes the shadow with it (`fadeOutAndClose`).
///
/// **Answer.** A card summoned straight into an answer IS an arrival, so it
/// swells out of the corner the pointer called it from. Opening out of this
/// window's own composer is not — `entered` is already true by then, this
/// resolves to the identity, and the only thing moving is the glass reshaping.
private struct CompactEntrance: ViewModifier {
    var bare: Bool
    var entered: Bool
    var grownIn: Bool
    var exiting: Bool
    var anchor: UnitPoint
    var reduceMotion: Bool

    /// One chain, no `if bare … else …`.
    ///
    /// A structural branch HERE is not a style choice: a ViewModifier's body is
    /// where its content's identity is decided, so branching on `bare` gives the
    /// composer and the answer two different identities for the same subtree.
    /// Enter flips the flag, and SwiftUI tears the whole face down and builds it
    /// again — glass, mask, chrome and all — in the middle of the spring that is
    /// supposed to be opening the capsule into the card. That teardown is the
    /// double flash on entering a chat: the surface blinks out and back as it is
    /// rebuilt (a fresh `glassEffect` layer fades itself in), and the content's
    /// own crossfade (`compactFaceContent`) never plays, because a rebuilt
    /// subtree is an insertion, not a transition.
    ///
    /// Every difference between the two faces is a VALUE here — a number, an
    /// anchor, an animation — so the face survives the flip as one object and
    /// only the numbers travel.
    func body(content: Content) -> some View {
        // The composer is already on screen when a press stretched it into place
        // (`grownIn`); the answer is only ever shown once `entered` latched, which
        // Enter has already done by the time this is read.
        let shown = bare ? (entered || grownIn) : entered
        return content
            .scaleEffect(shown ? 1 : (bare ? 1.04 : 0.92),
                         anchor: bare ? .center : anchor)
            .opacity(shown ? 1 : 0)
            .offset(y: bare || shown ? 0 : -4)
            .scaleEffect(bare && exiting ? 1.03 : 1, anchor: .center)
            .animation(reduceMotion || !bare ? nil : .easeIn(duration: 0.24),
                       value: exiting)
    }
}

/// The window header's trailing control — pin + close, the two bare glyphs the
/// compact shortcut card wears, so a torn-out session and the composer it grew
/// from keep one set of chrome. Pin here means "float above other windows" (on
/// by default for a fresh tear-off).
///
/// No reattach button: handing the session back to the notch is the drag —
/// pull the window up over the notch and it merges. A glyph for it only
/// duplicated the gesture in a header that has room for two marks.
private struct WindowTrailingCluster: View {
    var pinned: Bool
    var togglePin: () -> Void
    var close: () -> Void

    var body: some View {
        GlassSegmentCluster(segments: [
            .init(engaged: pinned,
                  tooltip: shortcutHelp(pinned ? "result.unpin" : "result.pin",
                                        action: .pin),
                  action: togglePin) {
                PinStateGlyph(pinned: pinned, size: 12.5, weight: .semibold)
            },
            .init(tooltip: L("detached.close"), action: close) {
                Image(systemName: "xmark")
                    .font(.sf(11, weight: .semibold))
            },
        ], showsTooltips: false)
    }
}

/// The prompt-shortcut window's numbers. The composer face is laid out from
/// these; the answer face is an ordinary detached session slab and takes its
/// rhythm from `DetachedThreadView` — only the transparent margin is shared.
enum CompactShortcutMetrics {
    /// The transparent margin around the floating pieces — the window's own
    /// breathing room, not padding inside a slab. The answer slab sits in the
    /// same margin, which is why its header lands where this band stood.
    static let inset: CGFloat = 8
    /// The chrome band above the capsule: one `GlassSegmentCluster`'s height (a
    /// 26pt chip in 3pt of glass) — i.e. exactly the answer card's header, which
    /// is what takes this slot once the answer arrives.
    static let band: CGFloat = 32
    /// Band → box.
    static let gap: CGFloat = 8
    /// The capsule's corners. Same value as the window silhouette
    /// (`DetachedSessionRootView.cornerRadius`), capped at half its height so a
    /// resting one-line composer is a true capsule.
    static let corner: CGFloat = DetachedSessionRootView.cornerRadius
    /// Everything the composer face carries around its capsule.
    static var chrome: CGFloat { inset + band + gap + inset }
    /// What an ANSWER window carries around its scrolling thread. It is the
    /// composer's own `chrome` — the margins AND the band the card hangs below,
    /// which the answer keeps rather than rising into (see `compactGlass`) —
    /// plus the header row and the follow-up line. The card's own padding is
    /// added by the caller (`DetachedThreadView`).
    static var answerChrome: CGFloat {
        chrome + DetachedThreadView.headerHeight
            + DetachedThreadView.compactFollowUpGap + DetachedThreadView.followUpHeight
    }

    // MARK: Where the caret lands
    //
    // The composer is placed by its text cursor, not by its corner: a force
    // click puts the caret exactly under the pointer
    // (`DetachedSessionWindowController.compactRect`). These are the offsets that
    // buys, and `ForceClickHerald` draws against the same numbers so the pressure
    // cue and the capsule it becomes occupy one spot.

    /// The card edge to the first glyph's cell: the card's own padding plus the
    /// compact input row's deliberately small internal inset.
    static var capsuleLeading: CGFloat {
        CompactShortcutPromptView.cardPad
            + CompactShortcutPromptView.inputLeadingPadding
            + PromptField.textInset
    }

    /// The face's coordinate space, so the caret can report where it landed in it.
    static let faceSpace = "compactShortcutFace"

    /// Where the text cursor sits inside the composer, from the window's top-left.
    ///
    /// This is MEASURED, not computed. The arithmetic below is only the opening
    /// guess for the very first composer on a fresh install; from then on the
    /// number comes from the laid-out view (`CaretProbe` → `rememberCaret`) and is
    /// persisted.
    ///
    /// It has to work that way. Placing the window by hand-totalled insets, while
    /// the face lays itself out from its own stack, is two sources of truth for one
    /// number — and they have already drifted once: a band moved from above the box
    /// to below it, the face grew a `footer`'s worth of height that the placement
    /// arithmetic didn't know about, and the pressure cue and the capsule it was
    /// supposed to become ended up on different lines of text. Measuring makes that
    /// class of bug impossible: the cue reads whatever the composer last actually
    /// did, so re-laying the face out can move both or neither, never one.
    static var caretOffset: CGPoint {
        if let stored = UserDefaults.standard.array(forKey: caretKey) as? [CGFloat],
           stored.count == 2, stored[0] > 0, stored[1] > 0 {
            return CGPoint(x: stored[0], y: stored[1])
        }
        return CGPoint(x: inset + capsuleLeading,
                       y: inset + band + gap + CompactShortcutPromptView.cardPad
                          + CompactShortcutPromptView.picksBlock(
                              CompactShortcutPromptView.quickPicks.count)
                          + CompactShortcutPromptView.restingRowHeight / 2)
    }

    /// Record where the composer's caret just laid out. Only a real, settled
    /// one-line layout is kept — a zero or a mid-animation measurement would poison
    /// the next window's placement.
    static func rememberCaret(_ offset: CGPoint) {
        guard offset.x > 0, offset.y > 0,
              offset.x.isFinite, offset.y.isFinite else { return }
        let current = caretOffset
        guard abs(current.x - offset.x) > 0.5 || abs(current.y - offset.y) > 0.5 else { return }
        UserDefaults.standard.set([offset.x, offset.y], forKey: caretKey)
    }

    private static let caretKey = "composerCaretOffset"

    /// The diameter of the capsule's rounded left cap — a full row, since the
    /// resting capsule is a true pill.
    static var capDiameter: CGFloat { NotchBody.idleRowHeight }

}

/// Reports where the prompt's first glyph cell sits inside the window, so the
/// composer can be *placed* by its caret instead of by a hand-totalled stack of
/// insets that nothing verifies (`CompactShortcutMetrics.caretOffset`).
private struct CaretProbe: View {
    var report: (CGPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            let box = geo.frame(in: .named(CompactShortcutMetrics.faceSpace))
            Color.clear
                .onAppear { report(Self.caret(in: box)) }
                .onChange(of: box) { _, new in report(Self.caret(in: new)) }
        }
        .allowsHitTesting(false)
    }

    /// The field's box begins `textInset` before its first glyph, and a one-line
    /// caret is centred on the row.
    private static func caret(in box: CGRect) -> CGPoint {
        CGPoint(x: box.minX + PromptField.textInset, y: box.midY)
    }
}

/// The compact composer's one trailing action slot. Collapsed History owns it
/// while the field is empty; once expanded, its disclosure moves to the drawer's
/// bottom-right corner like the main flow. Send uses this same footprint whenever
/// text exists, so typing never creates a second button or shifts the row.
private struct CompactShortcutTrailingControl: View {
    var hasText: Bool
    var showsHistory: Bool
    var historyExpanded: Bool
    var send: () -> Void
    var toggleHistory: () -> Void

    /// The shared footprint, held whether Send is showing or not.
    /// Same diameter as the main-flow `IdleTrailingCluster` Recent disclosure.
    private static let slot: CGFloat = 30

    var body: some View {
        ZStack {
            if hasText {
                GlassIconButton(
                    systemName: "arrow.up",
                    help: L("shortcuts.send"),
                    size: Self.slot,
                    glyphSize: 13,
                    showsTooltip: false,
                    action: send)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if showsHistory && !historyExpanded {
                CompactHistoryDisclosure(
                    expanded: historyExpanded,
                    action: toggleHistory)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(width: Self.slot, height: Self.slot)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hasText)
    }
}

/// The main-flow disclosure, now standing beside rather than inside the compact
/// input recess.
private struct CompactHistoryDisclosure: View {
    var expanded: Bool
    var action: () -> Void
    @State private var hovering = false

    /// Same diameter as the main-flow `IdleTrailingCluster` Recent disclosure.
    private static let size: CGFloat = 30

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.sf(11.5, weight: .semibold))
                .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
                .rotationEffect(.degrees(expanded ? 180 : 0))
                .frame(width: Self.size, height: Self.size)
                .glassCapsule(in: Circle(), brighter: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        .animation(CompactHistoryMotion.spring, value: expanded)
        .accessibilityLabel("History")
    }
}

/// The compact composer's notification-style close control: smaller than the
/// row controls, genuinely backdrop-blurred, and locally responsive when the
/// pointer catches it.
private struct CompactNotificationCloseButton: View {
    var action: () -> Void
    @State private var hovering = false

    private static let size: CGFloat = 18

    var body: some View {
        let shape = Circle()
        return Button(action: action) {
            Image(systemName: "xmark")
                .font(.sf(7.5, weight: .semibold))
                .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
                .frame(width: Self.size, height: Self.size)
                .background {
                    shape.fill(.clear)
                        .nativeGlass(in: shape, tintOpacity: 0.18)
                        .overlay(shape.fill(Color.black.opacity(hovering ? 0.16 : 0.22)))
                        .overlay(shape.fill(Color.white.opacity(hovering ? 0.12 : 0.04)))
                        .overlay(shape.strokeBorder(
                            Color.white.opacity(hovering ? 0.34 : 0.18), lineWidth: 0.6))
                }
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .scaleEffect(hovering ? 1.08 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(L("detached.close"))
    }
}

/// The same smoked glass the window slab wears (`DetachedWindowGlass`), cut to
/// an arbitrary shape. The bare composer has no slab to sit on, so its badge
/// and its input capsule each carry this themselves and still read as pieces of
/// the island rather than two foreign chips.
struct CompactComposerGlass<S: InsettableShape>: View {
    var shape: S
    /// How tall the CARD is right now, in points, when that differs from this
    /// surface. Only the veil reads it, and only to decide where its hem lands —
    /// the glass itself still fills whatever it is given, so nothing about the
    /// layout (or the card's edges, which the reveal mask owns) depends on this.
    ///
    /// It exists because the window keeps the disclosure's OPEN height until the
    /// reveal lands (`animateCompactHeight`), so during a fold this surface is
    /// taller than the card drawn on it. With the veil's stops being fractions of
    /// the surface, that stretched the gradient over the open height and left the
    /// mask showing only its smoked top — the transparent hem sat below the
    /// mask's edge — until the frame commit re-flowed the whole gradient into the
    /// collapsed box in one frame. That one frame is the flash.
    var cardHeight: CGFloat? = nil

    /// Smoked at the crown, letting go at the hem, and deliberately NOT a
    /// straight ramp between them: the top half gives up 0.13 of veil over its
    /// whole length while the bottom half gives up 0.27, so the surface reads as
    /// something lit from below rather than as a linear wash.
    ///
    /// The stops are FRACTIONS of the surface, not points off its edges. This
    /// glass carries a 56pt composer capsule, the Recent list unfolded under it,
    /// and the answer card — and all three are the same object at three heights,
    /// so the gradient has to stretch with it. Anchoring the hem to a fixed depth
    /// (which it was, briefly) left everything but the last 30pt of an unfolded
    /// list wearing the old even veil: the capsule shaded and the drawer under it
    /// flat, i.e. two materials in one window.
    /// `hem` is where location 1.00 lands, as a fraction of the surface — 1 for
    /// a surface that IS the card. Below the hem the gradient simply carries its
    /// last colour on, and that region is under the reveal mask anyway.
    private static func veil(hem: CGFloat) -> LinearGradient { LinearGradient(stops: [
        .init(color: .black.opacity(0.47), location: 0.00),
        .init(color: .black.opacity(0.41), location: 0.16),
        .init(color: .black.opacity(0.34), location: 0.40),
        .init(color: .black.opacity(0.28), location: 0.66),
        .init(color: .black.opacity(0.18), location: 0.86),
        .init(color: .black.opacity(0.07), location: 1.00),
    ], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: hem)) }

    var body: some View {
        Color.clear
            .nativeGlass(in: shape)
            // An overlay carrying a GeometryReader: it reads the size it is
            // handed and proposes nothing back, so the veil can be painted
            // against the card's height without any of it reaching layout.
            .overlay {
                GeometryReader { geo in
                    let hem = cardHeight.map {
                        min(max($0 / max(geo.size.height, 1), 0.05), 1)
                    } ?? 1
                    shape.fill(Self.veil(hem: hem))
                }
            }
    }
}

/// The same smoked-glass slab the History window wears — one even dark Liquid
/// Glass surface with a whisper of top sheen, so a detached session reads as a
/// piece of the island that left home, not as a foreign window.
struct DetachedWindowGlass: View {
    var body: some View {
        Rectangle()
            .fill(.clear)
            .nativeGlass(in: Rectangle())
            .overlay(Color.black.opacity(0.30))
            .overlay(
                LinearGradient(colors: [.white.opacity(0.05), .white.opacity(0.0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
            .ignoresSafeArea()
    }
}

// MARK: - Empty prompt-shortcut window

/// A selected-text shortcut with no saved instruction. The selection is already
/// held by the controller; this face deliberately exposes only that fact, the
/// user's own shortcuts, and a focused instruction field. Sending promotes the
/// same shell into the compact streaming result view.
///
/// It is the one face with no window slab behind it: everything lives in ONE
/// floating card — the shortcut buttons over a sunken input row — with the
/// "Using copied text" badge and the band above it belonging to the root view,
/// which carries them unchanged into the answer face. This view is ONLY the
/// card, so asking grows that card in place and moves nothing else
/// (see `DetachedSessionRootView.compactShortcutFace`).
///
/// The card and the field inside it are the app's two existing recipes stacked:
/// the shortcut rows are `MenuCardRow`s (the `/` menu's rows, verbatim), and the
/// input is the `ComposerBox` recess every other input in a slab wears — same
/// 39pt resting row, same 13/6/6 insets, same lit floor and rim. One surface,
/// nothing invented for it.
private struct CompactShortcutPromptView: View {
    @ObservedObject var state: DetachedWindowState
    let historyItems: [NotchModel.HistoryItem]
    var onSubmit: (String, ModelPin?) -> Void
    var onToggleHistory: () -> Void
    var onOpenHistory: (UUID) -> Void
    /// Straight to the page where these shortcuts are edited.
    var onOpenSettings: () -> Void = {}
    /// Put Force Touch away — the pause chip's answer. The controller runs it
    /// against the model and shuts this window, since the popup it belongs to is
    /// exactly what the user just asked to stop seeing.
    var onDisable: (NotchModel.ForceTouchDisable) -> Void = { _ in }
    var onDesiredHeight: (CGFloat) -> Void = { _ in }
    /// Where this face's text cursor actually landed, in the window's own
    /// coordinates. The window is placed by it (`alignCaret`).
    var onCaretOffset: (CGPoint) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var focused = false
    @State private var caretWidth: CGFloat = 0
    /// Whether the pause chooser is up over this card.
    @State private var confirmingDisable = false
    @State private var inputHeight: CGFloat =
        PromptField.lineHeight(for: CompactShortcutPromptView.fontSize)
    /// Read once per appearance rather than per render: the list is the user's
    /// saved shortcuts, and the window's whole height is measured off its count
    /// (`restingHeight`) before the first frame is drawn.
    @State private var picks: [PromptShortcut] = CompactShortcutPromptView.quickPicks
    /// Everything above the field — the shortcut rows — arrives on
    /// one beat, coming down from over the card's top edge.
    @State private var contentIn = false

    /// The card's padding around its rows and its field, and the gap between the
    /// two. `cardPad` is what makes the card's corner concentric with the input
    /// recess inside it (`cardShape`).
    static let cardPad: CGFloat = 8
    static let cardGap: CGFloat = 8
    /// Match the field's first glyph to `MenuCardRow`'s title inset. PromptField
    /// contributes its own 2pt text-container inset, so only the remainder lives
    /// on the row itself.
    static let inputLeadingPadding: CGFloat = MenuCard.rowPad - PromptField.textInset
    private static let inputTrailingPadding: CGFloat = 4
    private static let inputVerticalPadding: CGFloat = 4
    /// The input's type size: the card's own row type, not the notch's 16.5 idle
    /// prompt. That size is scaled to the island — dropped into this small card
    /// it towers over the shortcut titles right below it, and the box reads as
    /// two type scales stacked.
    private static let fontSize: CGFloat = 14.5
    static var restingRowHeight: CGFloat {
        max(34, max(27, PromptField.lineHeight(for: fontSize))
            + inputVerticalPadding * 2)
    }
    static var cardCornerRadius: CGFloat {
        (cardPad * 2 + restingRowHeight) / 2
    }
    /// The shortcut rows' type and slot, raised from the `/` menu's numbers for
    /// the same reason: there they are a completion list under a caret, here they
    /// are the surface's primary buttons. Held a notch under the input above
    /// them: the line the caret sits on leads the card, and matching it exactly
    /// made the coloured chips read as a second prompt rather than as its answers.
    static let pickFontSize: CGFloat = 13.5
    static let pickRowHeight: CGFloat = 32
    static let historyRowHeight: CGFloat = 34
    /// Match the main flow: let the Recent content extend naturally until it
    /// reaches the same compact-list ceiling, then hand the overflow to scrolling.
    static let historyMaxHeight: CGFloat = 220
    /// The strip between the composer and the first row's resting top — the main
    /// flow's `immersiveHeaderGap` (12) at card scale. It is NOT the plain
    /// `cardGap` this used to be: the runway lives INSIDE the ledger's scroll (as
    /// a safe-area inset, see `historyDrawer`), so rows dragged up travel into it
    /// and dissolve under the input the way the panel's immersive Recent dissolves
    /// under "Type anything…", instead of ending on a hard cut one gap below the
    /// field.
    static let historyTopRunway: CGFloat = 12
    /// Height of the frost band over that runway. Kept SHORTER than the runway on
    /// purpose (the same 4pt margin the main flow keeps): the band must taper fully
    /// to clear before it reaches the first row's resting top, or that row's
    /// blurred glyphs stack into a halo at rest (see `ProgressiveTopBlur`).
    static let historyTopBand: CGFloat = 8
    /// Give adjacent shortcut capsules enough separation to read as independent
    /// actions; the generic menu's 1pt row rhythm is too tight side by side.
    static let pickSpacing: CGFloat = 6
    /// Taper lengths for the rail's two overflow edges (`scrollEdgeFade`). The
    /// trailing one also sets the runway padding after the last chip.
    static let pickLeadingFade: CGFloat = 10
    static let pickTrailingFade: CGFloat = 24

    /// The shortcuts offered as buttons: the user's own, in the order they saved
    /// them, minus the ones with nothing to run and the ones the user has taken
    /// out of this box (each row's overflow menu). A chord is NOT required here —
    /// the button is the way to run it. ALL of them — the list scrolls.
    static var quickPicks: [PromptShortcut] {
        PromptShortcutStore.current
            .filter { !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter(\.appearsInForceTouch)
    }

    /// Quick actions always occupy one horizontal rail; additional actions scroll
    /// sideways instead of making the pointer card grow vertically.
    static func picksHeight(_ count: Int) -> CGFloat {
        count > 0 ? pickRowHeight : 0
    }

    /// …plus its gap to the field — zero when the user has no shortcuts, so the
    /// card is then just the input it has always been.
    static func picksBlock(_ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return picksHeight(count) + cardGap
    }

    /// Short history lists grow the card normally. Only long lists become a
    /// viewport, using the same 220pt ceiling as the main flow's compact Recent.
    static func historyHeight(_ count: Int) -> CGFloat {
        guard count > 0 else { return historyRowHeight }
        let whole = CGFloat(count) * historyRowHeight
            + CGFloat(max(0, count - 1)) * MenuCard.rowSpacing
        return min(whole, historyMaxHeight)
    }

    static func historyOverflows(_ count: Int) -> Bool {
        guard count > 0 else { return false }
        let whole = CGFloat(count) * historyRowHeight
            + CGFloat(max(0, count - 1)) * MenuCard.rowSpacing
        return whole > historyMaxHeight
    }

    /// The window's height with a one-line prompt: the band's chrome, the card
    /// (its padding, the picks, one input row) and the badge's own band under it
    /// — the same slot the answer's action pill lands in. A wrapped draft grows
    /// it from here.
    static func restingHeight(withPicks: Bool) -> CGFloat {
        CompactShortcutMetrics.chrome + cardPad * 2
            + (withPicks ? picksBlock(quickPicks.count) : 0)
            + restingRowHeight
    }
    /// The card at its shortest: the header line and the field, nothing between
    /// them — a box summoned on no selection, and the size the pressure cue is
    /// drawn at (nothing has been read yet when it goes up).
    static var restingHeight: CGFloat { restingHeight(withPicks: false) }

    /// The same height with the ledger already open — the size this face takes on
    /// the way BACK from an answer, where the draft is cleared (so the field is one
    /// line) and the drawer is expanded. Computed from the very numbers the layout
    /// uses (`cardHeight`), so the controller can put the window there in one set
    /// before the face mounts and the face's own first report is then a no-op.
    static func expandedHeight(withPicks: Bool, historyCount: Int) -> CGFloat {
        restingHeight(withPicks: withPicks) + historyBlock(historyCount)
    }

    /// Everything the open ledger adds under the input: its lead-in runway and
    /// the rows themselves. Named because it is also what has to come back OFF
    /// the window when the drawer's face leaves (see `openCompactAnswer`) — the
    /// ledger is a drawer hung under the box, never part of the box.
    static func historyBlock(_ count: Int) -> CGFloat {
        historyTopRunway + historyHeight(count)
    }

    private var trimmed: String {
        state.compactPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Quick actions operate on the captured selection. They stay out of a plain
    /// empty composer, and fold away on the first typed character.
    private var visiblePicks: [PromptShortcut] {
        let hasSelection = !state.compactSourceText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasSelection && trimmed.isEmpty ? picks : []
    }

    /// The field's own slot — one line of its type size until it has reported a
    /// real layout, exactly as `ComposerBox` measures it.
    private var fieldHeight: CGFloat {
        inputHeight > 0 ? inputHeight : PromptField.lineHeight(for: Self.fontSize)
    }
    /// The input row: the field's slot plus the compact vertical inset.
    private var rowHeight: CGFloat {
        max(34, max(27, fieldHeight) + Self.inputVerticalPadding * 2)
    }

    private var cardHeight: CGFloat {
        Self.cardPad * 2 + Self.picksBlock(visiblePicks.count)
            + rowHeight
            + (state.forceTouchHistoryExpanded
                ? historyBlockHeight
                : 0)
    }

    private var historyBlockHeight: CGFloat {
        Self.historyBlock(historyItems.count)
    }

    private var desiredHeight: CGFloat {
        CompactShortcutMetrics.chrome + cardHeight
    }

    var body: some View {
        card
            .onAppear {
                picks = Self.quickPicks
                onDesiredHeight(desiredHeight)
                focused = false
                // The next runloop pass, not a timed beat: the window is already
                // key by the time this lands (`finishSettle` runs synchronously
                // after the hosting view is set), and a delay here is a delay
                // before the box takes a keystroke — the whole point of opening
                // it at the pointer.
                DispatchQueue.main.async { focused = true }
                guard !reduceMotion else { contentIn = true; return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    contentIn = true
                }
            }
            .onChange(of: desiredHeight) { _, height in onDesiredHeight(height) }
    }

    /// The whole face: the input first, then the user's shortcuts and History
    /// continuing below it in one card.
    ///
    /// The shortcuts unfold downward from the line the caret is already sitting
    /// on, so the input remains the card's stable anchor.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            composerRow

            VStack(alignment: .leading, spacing: 0) {
                if !visiblePicks.isEmpty {
                    GeometryReader { proxy in
                        let count = visiblePicks.count
                        let spacing = Self.pickSpacing
                        let visibleSlots = count <= 2 ? CGFloat(count) : 2.25
                        let visibleGaps: CGFloat = count <= 1 ? 0 : (count == 2 ? 1 : 2)
                        let itemWidth = max(1,
                            (proxy.size.width - spacing * visibleGaps) / visibleSlots)

                        ScrollView(.horizontal) {
                            LazyHStack(spacing: spacing) {
                                ForEach(visiblePicks) { pick in
                                    // No accessory: the shortcut that opened this
                                    // window is the one the user just pressed. One
                                    // item fills the rail, two split it, and a longer
                                    // list leaves the next item peeking into view.
                                    MenuCardRow(title: pick.displayName,
                                                fontSize: Self.pickFontSize,
                                                height: Self.pickRowHeight,
                                                selected: false,
                                                promptShortcutID: pick.id,
                                                action: { onSubmit(pick.prompt, pick.pin) })
                                        .frame(width: itemWidth)
                                }
                            }
                            .frame(height: Self.pickRowHeight)
                            // Runway past the trailing fade, so the last chip can
                            // scroll fully clear of the taper instead of resting
                            // dimmed at the end of the rail (same trick the
                            // settings page's shortcut rail uses).
                            .padding(.trailing, Self.pickTrailingFade)
                        }
                        .scrollIndicators(.never)
                        // The rail dissolves into both boundaries rather than
                        // being sliced by the viewport — the panel's shared
                        // overflow language (`scrollEdgeFade`), the same one the
                        // History drawer below and the settings page's shortcut
                        // rail already speak. It replaces a per-item
                        // `scrollTransition` that snapped a whole capsule between
                        // opaque and clear: a chip crossing the edge became a flat
                        // half-transparent slab with a hard cut down its side,
                        // which is exactly the harshness this taper removes.
                        // Leading taper is kept short: at rest the first chip sits
                        // flush at 0, so anything longer would visibly thin its
                        // own corner instead of only softening what scrolls past.
                        .scrollEdgeFade(leading: true,
                                        trailing: true,
                                        leadingFade: Self.pickLeadingFade,
                                        trailingFade: Self.pickTrailingFade)
                    }
                    .frame(height: Self.picksHeight(visiblePicks.count))
                    .padding(.top, Self.cardGap)
                }
            }
            .opacity(contentIn ? 1 : 0)
            .offset(y: contentIn ? 0 : -10)
            // Keep the ledger laid out even while it is closing. The window's
            // top-aligned reveal mask folds these rows away progressively; making
            // this slot zero-height (or transparent) as soon as the state flipped
            // cleared every row before that fold had a chance to pass over it.
            historyDrawer
                .frame(height: historyBlockHeight, alignment: .top)
                .clipped()
                .opacity(state.forceTouchHistoryExpanded ? 1 : 0)
                .scaleEffect(state.forceTouchHistoryExpanded ? 1 : 0.97,
                             anchor: .top)
                .offset(y: state.forceTouchHistoryExpanded ? 0 : -8)
                .allowsHitTesting(state.forceTouchHistoryExpanded)
                .animation(reduceMotion ? nil : CompactHistoryMotion.spring,
                           value: state.forceTouchHistoryExpanded)
        }
        // While a force click is still being decided the card is drawn as its own
        // cap, and a field laid out inside a 48pt circle is neither useful nor
        // cheap — the glass is the whole cue. The content keeps its full-width
        // layout underneath (it is the glass that is narrow, see `cardGlass`), so
        // the stretch never re-wraps a line of text.
        .opacity(state.pressDepth == nil ? 1 : 0)
        .padding(Self.cardPad)
        .frame(height: cardHeight, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: inputHeight)
        .animation(CompactHistoryMotion.spring, value: trimmed.isEmpty)
        // The chooser covers this whole card — scrim included — the way the Clear
        // card covers the island. Clipped to the card's own silhouette: the scrim
        // is a rectangle, and unclipped it planted four square corners outside the
        // 30pt radius the glass is drawn with. It is only reachable from the
        // ledger's bottom bar, so the window is always at its expanded height when
        // this can appear and the card has room to centre in.
        .overlay {
            if confirmingDisable {
                ForceTouchDisableConfirm(
                    onCancel: {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            confirmingDisable = false
                        }
                    },
                    onConfirm: { scope in
                        confirmingDisable = false
                        onDisable(scope)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius,
                                            style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    /// The field and its one trailing slot: collapsed History at rest, replaced
    /// in place by Send while the user is typing. Once expanded, the History
    /// disclosure moves to the drawer's bottom bar beside Settings.
    private var composerRow: some View {
        HStack(alignment: .center, spacing: 6) {
            inputRow
                .frame(maxWidth: .infinity)

            CompactShortcutTrailingControl(
                hasText: !trimmed.isEmpty,
                showsHistory: state.forceTouchInvocation,
                historyExpanded: state.forceTouchHistoryExpanded,
                send: send,
                toggleHistory: onToggleHistory)
        }
    }

    /// The Force Touch-only ledger, physically inside the composer card. Its rows
    /// continue directly below the input; selecting one asks the controller to
    /// replace this face with that thread in the same NSWindow.
    private var historyDrawer: some View {
        Group {
            if historyItems.isEmpty {
                Text("No Force Touch history yet")
                    .font(.sf(13))
                    .foregroundStyle(Tokens.text4)
                    .frame(maxWidth: .infinity, minHeight: Self.historyRowHeight,
                           alignment: .center)
                    // Sit in the same slot a first row would, below the runway.
                    .padding(.top, Self.historyTopRunway)
            } else {
                ScrollView {
                    // Lazy, like the main flow's Recent: the ledger holds every
                    // Force Touch conversation but only ~6 rows fit the drawer.
                    // Eager rows were built for the whole ledger on every layout
                    // pass — including while the card sat collapsed, since the
                    // drawer stays mounted for the fold mask — and again on every
                    // frame of the disclosure.
                    LazyVStack(spacing: MenuCard.rowSpacing) {
                        ForEach(historyItems) { item in
                            MenuCardRow(
                                title: item.displayTitle,
                                accessory: relativeTime(item.t),
                                fontSize: 13.5,
                                accessoryFontSize: 11.5,
                                height: Self.historyRowHeight,
                                selected: false,
                                action: { onOpenHistory(item.id) })
                        }
                    }
                }
                .scrollIndicators(.never)
                // The runway is a SAFE-AREA INSET, not `.padding(.top)` — the
                // main flow's hard-won distinction (see `historyList(immersive:)`
                // in NotchBody): padding is content, and a LazyVStack settling its
                // height re-anchors the scroll to the first *item*, which steals a
                // padded runway and rests row 0 under the field. An inset lives
                // outside the scrollable content, so there is nothing there to
                // scroll away — rows still travel up into it, they just come to
                // rest clear of the composer.
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear.frame(height: Self.historyTopRunway)
                }
                // Both edges taper now, as they do in the panel: the top dissolves
                // rows sliding up under the input, the bottom rows sliding down
                // behind the settings chip.
                .scrollEdgeFade(top: true,
                                bottom: Self.historyOverflows(historyItems.count),
                                topFade: Self.historyTopRunway,
                                bottomFade: 10)
                // …and frost them on the way, so a row passing under "Type
                // anything…" reads as pushed back behind the field rather than
                // crossing its glyphs. Band shorter than the runway, so no
                // resting row sits inside it.
                .progressiveTopBlur(height: Self.historyTopBand, maxRadius: 10)
            }
        }
        .frame(height: Self.historyTopRunway + Self.historyHeight(historyItems.count))
        // Match the main flow's immersive Recent: bottom chrome floats over the
        // list instead of reserving a separate row beneath it. Settings anchors
        // the left corner and the expanded History disclosure moves to the right,
        // so the way out of the list sits on the same bottom baseline.
        .overlay(alignment: .bottom) {
            HStack(spacing: 6) {
                settingsControl
                disableControl
                Spacer(minLength: 8)
                CompactHistoryDisclosure(
                    expanded: true,
                    action: onToggleHistory)
            }
        }
    }

    private var settingsControl: some View {
        GlassIconButton(
            systemName: "slider.horizontal.3",
            hoverSystemName: "arrow.up.right",
            help: L("recent.menu.settings"),
            size: 34,
            showsTooltip: false,
            action: onOpenSettings)
    }

    /// Turning Force Touch off, next to Settings on the ledger's own bottom bar.
    /// It is the one trigger that fires without being asked for — it rides a press
    /// you were making anyway — so the surface it opens is where "not right now"
    /// belongs, rather than three levels into Settings.
    ///
    /// The chip only asks; how long is answered on `ForceTouchDisableConfirm`, the
    /// same stacked card the Clear action uses for its time scopes.
    private var disableControl: some View {
        GlassIconButton(
            systemName: "power",
            help: L("recent.menu.disable"),
            size: 34,
            showsTooltip: false
        ) {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                confirmingDisable = true
            }
        }
    }

    /// The instruction line sits directly on the compact card's glass so the
    /// composer reads as one continuous surface rather than a nested recess.
    private var inputRow: some View {
        ZStack(alignment: .leading) {
            PromptField(
                text: $state.compactPromptDraft,
                placeholder: "",
                fontSize: Self.fontSize,
                focusTrigger: focused,
                maxVisibleLines: NotchBody.promptMaxLines,
                onSubmit: send,
                // Match the visible disclosure: with an empty Force Touch
                // composer, ↓ pulls the popup-local History ledger open.
                onDown: {
                    guard state.forceTouchInvocation,
                          !state.forceTouchHistoryExpanded
                    else { return false }
                    onToggleHistory()
                    return true
                },
                // …and ↑ puts it away again — the plain inverse of the ↓ that
                // pulled it open, so the ledger opens and closes on the two keys
                // that already mean "down into it" and "back up out of it".
                onUp: {
                    guard state.forceTouchInvocation,
                          state.forceTouchHistoryExpanded
                    else { return false }
                    onToggleHistory()
                    return true
                },
                onTab: { true },
                onCaretWidth: { caretWidth = $0 },
                onHeightChange: { inputHeight = $0 }
            )
            .frame(height: fieldHeight)

            if state.compactPromptDraft.isEmpty && caretWidth == 0 {
                // "What should I do with it?" only means something when there IS
                // an "it". Pressed on nothing (or with the context dropped), this
                // is the ordinary prompt and says what the notch's own box says.
                Text(L(state.compactSourceText.isEmpty
                       ? "input.placeholder"
                       : "shortcuts.promptAction.window.placeholder"))
                    .font(.sf(Self.fontSize))
                    .foregroundStyle(Tokens.placeholder)
                    .lineLimit(1)
                    .padding(.leading, PromptField.textInset)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(height: max(27, fieldHeight))
        .background(CaretProbe(report: onCaretOffset))
        .animation(.easeOut(duration: 0.16), value: caretWidth == 0)
        .animation(.easeOut(duration: 0.16), value: state.compactPromptDraft.isEmpty)
        .padding(.leading, Self.inputLeadingPadding)
        .padding(.trailing, Self.inputTrailingPadding)
        .padding(.vertical, Self.inputVerticalPadding)
    }

    private func send() {
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed, nil)
    }
}

// MARK: - Compose window body

/// The idle prompt, torn out: a standalone composer window. It carries the
/// panel's own input (`PromptField`, the same Tab correction cycle, the same
/// destination spelled out — here on the send button) but keeps its line to
/// itself — the notch's box is cleared when the composer leaves, so the two
/// never write over each other.
///
/// Enter routes exactly as it would in the notch: Note and Remind file through
/// the identical services (their feedback lands on the model, mirrored below),
/// an armed Agent bucket spawns its run into the tray, and an Ask starts a round
/// that this very window then holds — the composer becomes the conversation in
/// place (`DetachedSessionWindowController.adoptThread`).
///
struct DetachedComposeView: View {
    @ObservedObject var state: DetachedWindowState
    @ObservedObject var model: NotchModel
    var pinned: Bool
    var onTogglePin: () -> Void
    var onClose: () -> Void
    var onSubmit: (String, NotchModel.Panel) -> Void
    /// The height this composer wants right now — the window follows it, so the
    /// slab grows with a wrapping draft exactly as the notch does.
    var onDesiredHeight: (CGFloat) -> Void = { _ in }

    @State private var focused = false
    @State private var caretWidth: CGFloat = 0
    @State private var caretY: CGFloat = 0
    @State private var inputHeight: CGFloat = PromptField.lineHeight(for: NotchBody.idleFontSize)
    /// This window's own read of its own line — see the type comment.
    @State private var due: Date?
    /// Tab's manual destination override, scoped to the line being written
    /// exactly like the panel's (`NotchModel.manualPanelOverride`).
    @State private var override: NotchModel.Panel?
    @State private var typedNoteTrigger: String?

    /// The window's height with a one-line prompt: the body's insets, the header,
    /// its gap, and the input row. A wrapped draft grows the window from here.
    static let restingHeight: CGFloat =
        DetachedThreadView.cardTopPadding + 26 + 10 + NotchBody.idleRowHeight
            + DetachedThreadView.cardBottomPadding

    /// One feedback line's own height plus its gap — added to the window when a
    /// save cue is up, so the cue never squeezes the input.
    private static let feedbackHeight: CGFloat = 8 + 16

    private var desiredHeight: CGFloat {
        Self.restingHeight
            + max(0, inputHeight - PromptField.lineHeight(for: NotchBody.idleFontSize))
            + (feedbackText == nil ? 0 : Self.feedbackHeight)
    }

    private var draft: String { state.composeDraft }

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where Enter sends this line. Same resolution as the panel's
    /// `effectiveSubmitPanel`: Ask until the user pins something by hand, and
    /// nothing reads the text to change that. A pinned Capture names the bucket,
    /// not the leaf — the date still decides Notes vs Reminders under it, which
    /// is invisible here (both faces say Capture).
    private var destination: NotchModel.Panel {
        guard let override else { return .chat }
        return override == .note && due != nil ? .reminder : override
    }

    /// An armed Agent bucket owns the line regardless of any pin — the same
    /// precedence `submitCurrent()` uses.
    private var goesToAgent: Bool { model.agentComposeActive }

    private var hintLabel: String {
        if goesToAgent { return L("hint.agent") }
        switch destination {
        case .chat:              return L("hint.ask")
        // One word for both Capture leaves, same as the panel's pill.
        case .note, .reminder:   return L("hint.capture")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            composerRow
                .padding(.top, 10)
            if let feedback = feedbackText {
                Text(feedback)
                    .font(.sf(12))
                    .tracking(0.2)
                    .foregroundStyle(model.noteError == nil ? Tokens.text4 : Tokens.text2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DetachedThreadView.cardHorizontalPadding)
        .padding(.top, DetachedThreadView.cardTopPadding)
        .padding(.bottom, DetachedThreadView.cardBottomPadding)
        .onAppear {
            // Same false→true edge the panel uses to hand an AppKit field
            // first-responder; the small delay lets the window become key first.
            focused = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { focused = true }
        }
        .onChange(of: desiredHeight) { _, h in onDesiredHeight(h) }
        .onChange(of: draft) { _, value in
            guard let trigger = typedNoteTrigger,
                  !value.hasPrefix(trigger) else { return }
            typedNoteTrigger = nil
            override = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : .chat
        }
        // The date read that decides which service a capture is filed through,
        // mirroring the panel's `scheduleDueDetection`. Nothing classifies this
        // window's line any more — the destination is whatever the user pinned.
        // `.task(id:)` cancels the in-flight read on every keystroke.
        .task(id: trimmed) {
            let snapshot = trimmed
            guard !snapshot.isEmpty else {
                due = nil
                return
            }
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            let when = await Task.detached {
                RemindersService.futureDate(in: snapshot)
                    ?? RemindersService.recurrenceDate(in: snapshot)
            }.value
            guard !Task.isCancelled else { return }
            due = when
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            WindowTrailingCluster(pinned: pinned, togglePin: onTogglePin,
                                  close: onClose)
        }
        .frame(height: 26)
    }

    /// The panel's idle input, in a window: the same field, and a send button that
    /// names where Enter sends the line.
    private var composerRow: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .leading) {
                PromptField(
                    text: $state.composeDraft,
                    // Placeholder drawn as a SwiftUI label below so it can fade
                    // (the native one hard-swaps) — the panel's own trick.
                    placeholder: "",
                    fontSize: NotchBody.idleFontSize,
                    focusTrigger: focused,
                    maxVisibleLines: NotchBody.promptMaxLines,
                    onSubmit: send,
                    // Tab steps the destination when the classifier reads the
                    // line wrong, exactly as in the notch; always consumed so
                    // focus never wanders out of the box.
                    onTab: {
                        typedNoteTrigger = nil
                        override = Self.nextDestination(after: override ?? destination)
                        return true
                    },
                    // Match the notch's fresh prompt: the hand-typed sigil is
                    // retained and pins this detached line to Note. If the
                    // composer was armed for Agent, Note explicitly leaves it.
                    onInitialNoteTrigger: { trigger in
                        model.setAgentBucket(false)
                        typedNoteTrigger = String(trigger)
                        override = .note
                    },
                    onCaretWidth: { caretWidth = $0 },
                    onCaretY: { caretY = $0 },
                    onHeightChange: { inputHeight = $0 }
                )
                .frame(height: inputHeight)
                .padding(.trailing,
                         typedNoteTrigger == nil
                            ? 0
                            : InlineModeHint.reservedTrailingWidth(
                                text: "You are using Note mode",
                                fontSize: NotchBody.idleFontSize))
                .background {
                    if typedNoteTrigger != nil {
                        GeometryReader { geo in
                            InlineModeHint(
                                text: "You are using Note mode",
                                fontSize: NotchBody.idleFontSize,
                                caretWidth: caretWidth,
                                caretY: caretY,
                                availableWidth: geo.size.width,
                                tint: Tokens.noteInk)
                            .frame(height: geo.size.height, alignment: .center)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .animation(.smooth(duration: 0.25), value: typedNoteTrigger != nil)
                if draft.isEmpty && caretWidth == 0 {
                    Text(L(model.idlePlaceholderKey))
                        .font(.sf(NotchBody.idleFontSize))
                        .foregroundStyle(Tokens.placeholder)
                        .lineLimit(1)
                        .padding(.leading, PromptField.textInset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.16), value: caretWidth == 0)
            .animation(.easeOut(duration: 0.16), value: draft.isEmpty)

            // The window has no bucket row to carry a destination pill, so the send
            // button spells it out instead: "Note ⏎" / "Remind ⏎" — the same word
            // the panel's pill would show, on the control Enter maps to.
            if !trimmed.isEmpty {
                SendButton(compact: true, label: hintLabel, action: send)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(height: max(NotchBody.idleRowHeight,
                           inputHeight + NotchBody.idleRowHeight
                               - PromptField.lineHeight(for: NotchBody.idleFontSize)))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: trimmed.isEmpty)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: inputHeight)
    }

    /// The note/reminder save cue, mirrored from the model — the writes run
    /// through the panel's own services, so their feedback lives there.
    private var feedbackText: String? {
        if let err = model.noteError { return err }
        if let cue = model.lastSavedNote { return cue }
        if model.noteSaving { return L("input.saving") }
        return nil
    }

    private func send() {
        let line = trimmed
        guard !line.isEmpty else { return }
        let where_ = destination
        state.composeDraft = ""
        typedNoteTrigger = nil
        override = nil
        due = nil
        onSubmit(line, where_)
    }

    /// Tab's cycle — Ask ⇄ Capture, matching `toggleSubmitPanel`. Note and
    /// Remind are not separate stops: which leaf a capture lands in follows the
    /// time the line names, so there is nothing here for Tab to step through.
    private static func nextDestination(after current: NotchModel.Panel) -> NotchModel.Panel {
        switch current {
        case .chat:              return .note
        case .note, .reminder:   return .chat
        }
    }
}

// MARK: - Thread scroll edge

/// Shared geometry for a headed thread scroll's soft edges. The conversation
/// runs up behind the header into a `runway` of empty inset, fading
/// (`scrollEdgeFade`) and frosting (`progressiveTopBlur`) as it goes — the same
/// dissolve the panel's immersive list uses, so overflowing content melts into
/// the glass instead of ending on a hard cut. The frost `band` stays shorter
/// than the runway so no resting row sits inside it and haloes (see
/// `ProgressiveTopBlur`). The BOTTOM edge is the exact mirror — same runway,
/// same band, `progressiveBottomBlur` — so a thread scrolled to its end melts
/// into the follow-up line the way it melts into the header, instead of the
/// hard cut the tear-off used to show there. Internal on purpose: the panel's
/// agent-detail page (NotchBody) is the same species and shares these numbers,
/// so the tear-off keeps the exact dissolve the panel showed.
enum ThreadScroll {
    static let runway: CGFloat = 28
    static let band: CGFloat = 22
    static let blurRadius: CGFloat = 16
}

/// The compact answer's laid-out content height, reported up from the probe
/// inside the thread's ScrollView.
///
/// `max`, NOT `value = nextValue()`: the probe is one contributor among the
/// siblings SwiftUI reduces over, and the ones that set nothing hand back the
/// default. A last-writer-wins reduce therefore delivered a flat **0** for
/// every compact answer (measured), so the window's "authoritative" measurement
/// never reached it at all and its whole height fell to the AppKit estimate
/// below — which is how a short answer ended up in a window a third empty.
private struct DetachedThreadContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Thread window body

/// A detached chat thread: the conversation, writing itself live while its
/// round streams (fed by `DetachedThreadStore`), with one exit — hand the
/// session back to the notch.
struct DetachedThreadView: View {
    @ObservedObject var store: DetachedThreadStore
    var pinned: Bool
    var onTogglePin: () -> Void
    var onClose: () -> Void
    var onInAppCopy: () -> Void
    var onReplaceOriginal: (String) -> Bool
    var onFollowUp: (String, [NSImage]) -> Void
    var onRegenerate: () -> Void
    var onRegenerateWith: (String) -> Void
    var onChooseOption: (UUID, String) -> Void
    var regenerateOptions: () -> [(model: String, isCurrent: Bool)]
    var compactShortcut = false
    var onDesiredHeight: (CGFloat) -> Void = { _ in }

    @State private var followUp = ""
    @State private var followUpImages: [NSImage] = []
    @State private var hoveredSourceID: UUID?
    @State private var sourceCloseWork: DispatchWorkItem?
    @State private var metadataMenuOpen = false
    /// The WHOLE thread's laid-out height, mirrored out of the content probe
    /// below. `compactAnswerIsCapped` reads it: whether the card has stopped
    /// growing and handed the tail to its ScrollView is a property of the
    /// thread, not of the newest answer's text (see there).
    @State private var measuredContentHeight: CGFloat = 0

    private static let bottomID = "detached-thread-bottom"

    private var streaming: Bool { store.turns.contains { $0.streaming } }
    private var renderedTurns: [NotchModel.Turn] {
        store.turns.filter { !$0.hidesUserBubble }
    }
    private var latestAssistantTurn: NotchModel.Turn? {
        renderedTurns.last(where: { $0.role == "assistant" })
    }
    private var agentReport: NotchModel.Turn? {
        renderedTurns.last(where: { $0.role == "assistant" && $0.isAgent })
    }
    private var agentRunCaption: String? {
        guard let report = agentReport else { return nil }
        return AssistantTurnView.footerModelCaption(
            answerModel: report.answerModel, regenModel: report.regenModel)
    }
    private var hasAgentMetadata: Bool {
        agentRunCaption != nil || store.agentFolderPath != nil || store.completedAt != nil
    }
    /// ONE rhythm for every detached thread — a pointer-side prompt-shortcut
    /// answer and a torn-out session are the same view at two sizes, so they get
    /// the same runways, the same card padding, the same header and the same
    /// follow-up line. (The compact face used to run a second, tighter set of
    /// numbers — 0 card padding, 15/14 runways, no header, no follow-up — which
    /// is precisely what made it read as a different kind of window.)
    ///
    /// The top runway must clear the complete frost band; otherwise the first
    /// answer line rests inside the blur and looks clipped.
    ///
    /// **A runway is only worth its height on a window that has height to
    /// spare.** A torn-out session is a fixed 460pt frame the user resizes at
    /// will, so its threads scroll and the 28pt bands are free — they live in
    /// space the window already has. A pointer-side card is the opposite: it
    /// sizes ITSELF to its answer, so every point of runway is a point the
    /// window grows by. At 28+28 a two-line reply opened a card carrying 36pt of
    /// nothing between its action row and the follow-up capsule against 23 under
    /// the capsule — the bottom margin reading as a sag.
    ///
    /// So the compact card rests on the panel's own short-answer rhythm instead
    /// (`NotchBody.resultView`: header, an 18pt quiet gap, the thread, 24pt, the
    /// input). It is ONE rhythm, not a switch on whether the answer happens to
    /// fit: swapping the insets mid-answer relaid the card out underneath a
    /// window that was still gliding open, and AppKit tears the window down for
    /// exceeding its constraint passes when those two argue. A long answer
    /// scrolls under an 18pt taper instead of a 28pt one — the bands are sized
    /// to these gaps below, so nothing is ever frosted while at rest.
    private var scrollTopInset: CGFloat {
        compactShortcut ? Self.restingTopGap : ThreadScroll.runway
    }
    private var scrollBottomInset: CGFloat {
        compactShortcut ? Self.restingBottomGap : ThreadScroll.runway
    }
    /// The compact card keeps the panel's 18pt quiet gap above the thread and
    /// the detached window's short 8pt gap above the follow-up line. In the
    /// waiting state that separation keeps the lone thinking row from crowding
    /// the disabled composer; ordinary detached windows additionally carry the
    /// full `ThreadScroll.runway` below their content.
    static let restingTopGap: CGFloat = 18
    static let restingBottomGap: CGFloat = 0
    /// The panel's own rhythm — `NotchBody.panelPadding`, the SAME on all four
    /// sides, so the follow-up capsule sits as far from the bottom edge as it
    /// does from the sides and 15 reads concentric against the window's 30pt
    /// corner (`DetachedSessionRootView.cornerRadius`, the island's own radius).
    ///
    /// It used to run horizontal 20 / top 15 / bottom 14 here — three different
    /// numbers, none of them the panel's — which is exactly what made a detached
    /// window's margins read as a different species from the notch's: the
    /// follow-up line hung 20 from the sides but only 14 off the rounded bottom,
    /// so the corner curve ate the side gap and the row looked to sag.
    static let cardHorizontalPadding: CGFloat = NotchBody.panelPadding
    static let cardTopPadding: CGFloat = NotchBody.panelPadding
    static let cardBottomPadding: CGFloat = NotchBody.panelPadding
    /// The answer keeps its established reading inset; the tighter nested
    /// padding is local to the composer input treatment.
    static let compactCardPadding: CGFloat = 8
    /// The header pill's height (`GlassSegmentCluster` — a 26pt chip in 3pt of
    /// glass) and the follow-up row's, so the compact window can budget for the
    /// chrome it now carries (`CompactShortcutMetrics.answerChrome`).
    static let headerHeight: CGFloat = 32
    static let compactFollowUpGap: CGFloat = 8
    static let followUpGap: CGFloat = 8
    static let followUpHeight: CGFloat = 39
    /// The fade and frost bands are exactly the gaps the thread rests between —
    /// never deeper — so a card at rest is crisp edge to edge and only content
    /// that has actually travelled into a gap gets dissolved.
    /// The card's own insets for this face — the composer's on the compact one
    /// (see `compactCardPadding`), the panel's uniform inset everywhere else.
    private var cardHorizontal: CGFloat { Self.cardHorizontalPadding }
    /// The header row alone rides the compact card's tighter inset — those two
    /// marks are the composer's chips, in the composer's exact spot, and they
    /// may not move when Enter replaces what is under them. Prose does not
    /// inherit that: text at 8 from the rim reads as a card with no margins
    /// (which is what it looked like), so the reading column below keeps the
    /// panel's own `cardHorizontalPadding` in both faces.
    private var headerHorizontal: CGFloat {
        compactShortcut ? Self.compactCardPadding : Self.cardHorizontalPadding
    }
    /// The follow-up capsule rides the tighter inset too — it IS the composer's
    /// own input capsule, in the composer's own spot, so it stands as close to
    /// the card's sides as that one does. Only the prose between them is held at
    /// the reading margin.
    private var followUpHorizontal: CGFloat { headerHorizontal }
    private var cardTop: CGFloat {
        compactShortcut ? Self.compactCardPadding : Self.cardTopPadding
    }
    private var cardBottom: CGFloat {
        compactShortcut ? Self.compactCardPadding : Self.cardBottomPadding
    }
    private var topFade: CGFloat { scrollTopInset }
    private var bottomFade: CGFloat { scrollBottomInset }
    private var topBand: CGFloat { min(ThreadScroll.band, scrollTopInset) }
    private var bottomBand: CGFloat { min(ThreadScroll.band, scrollBottomInset) }


    /// The window height a compact card wants for a turn stack this tall — the
    /// one place that arithmetic lives, so the height the window is set to and
    /// the layout inside it can never disagree.
    private func compactWindowHeight(forContentHeight bare: CGFloat) -> CGFloat {
        Self.compactWindowHeight(forContentHeight: bare)
    }

    /// The same arithmetic without a mounted view, so the controller can open a
    /// REOPENED thread straight at the height its answer needs instead of
    /// collapsing to the waiting floor and growing back out of it. Only ever
    /// asked about the compact face, whose runways are exactly these gaps.
    static func compactWindowHeight(forContentHeight bare: CGFloat) -> CGFloat {
        bare + restingTopGap + restingBottomGap
            + compactCardPadding * 2
            + CompactShortcutMetrics.answerChrome
    }
    /// What the answer footer adds under the prose: 6pt of stack spacing, the
    /// row's 2pt top inset, and a 22pt icon frame. Only the AppKit text estimate
    /// needs this — the SwiftUI probe measures the footer along with everything
    /// else in the turn stack — and the estimate is a floor, so the badge-led
    /// row's slightly taller lead-in is safe to round down to.
    private static let compactFooterHeight: CGFloat = 30
    private var latestAnswerText: String {
        latestAssistantTurn?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    /// Has this thread ever written anything? The FIRST round's wait is the one
    /// case where the card must not move — it opens once, to its floor, and the
    /// orb sits in it. Every round after that is a follow-up: the question
    /// bubble and the wait row under it are real content arriving in a card
    /// that is already open, and the card has to make room for them AS THEY
    /// ARRIVE. Gating the height report on the LATEST answer instead meant a
    /// follow-up reported nothing at all while it thought (the new assistant
    /// turn is empty until the first token), so the box stayed exactly as tall
    /// as it was and the new question pushed the follow-up capsule out through
    /// its own bottom edge.
    private var hasAnswered: Bool {
        renderedTurns.contains {
            $0.role == "assistant"
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    private var hasPendingQuestion: Bool {
        store.turns.contains { $0.streaming && $0.pendingQuestion != nil }
    }
    // The panel body's exact rhythm (NotchBody: a uniform 15pt inset, header then
    // an 18pt quiet gap, turns at 14pt spacing) — so the first frame after the
    // tear lays out where the panel's last frame did, and the question bubble is
    // the title; the header carries no text of its own.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, headerHorizontal)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(renderedTurns) { turn in
                            turnView(turn)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // A ScrollView otherwise accepts the viewport's finite height
                    // proposal and the probe below only reports that clipped box.
                    // Ask for the stack's ideal vertical size so the probe sees the
                    // complete laid-out answer, including lines below the fold.
                    .fixedSize(horizontal: false, vertical: true)
                    // Measured BARE — inside the gaps, not around them — so the
                    // window's height is built from the turn stack plus whichever
                    // gaps this face rests it between (`compactWindowHeight`),
                    // rather than from a number that already has one pair baked in.
                    .background(GeometryReader { geo in
                        Color.clear.preference(
                            key: DetachedThreadContentHeightKey.self,
                            value: geo.size.height)
                    })
                    // The gaps rows rest between and then scroll away into — up
                    // behind the header, down behind the input — fading and
                    // frosting out on both edges. A session window can afford
                    // the full 28pt runways; the compact card pays for them in
                    // its own height, so it rests on the panel's short rhythm
                    // (see `scrollTopInset`).
                    .padding(.top, scrollTopInset)
                    .padding(.bottom, scrollBottomInset)
                }
                .scrollIndicators(.automatic)
                // Sticky affordances inside the thread (a code block's copy
                // button) park below the top fade band, not in it.
                .environment(\.stickyScrollTopInset, topFade)
                .scrollEdgeFade(top: true, bottom: true,
                                topFade: topFade, bottomFade: bottomFade)
                // ONE merged pass, not the two stacked modifiers — see
                // `ProgressiveEdgeBlur`: stacking them rebuilds the whole thread
                // four times over on mount.
                .progressiveEdgeBlur(top: topBand, bottom: bottomBand,
                                     topRadius: ThreadScroll.blurRadius)
                // The fade/blur modifiers render copies of the scroll surface.
                // Clip the composed result at the viewport itself so those
                // layers cannot follow a live scroll into the transparent bands
                // around the compact card.
                .clipped()
                // A follow-up appends two turns at once — the question bubble
                // and the empty assistant turn waiting under it. Neither carries
                // any text, so the tail-follow below (keyed on the answer's
                // characters) cannot fire for them: a capped card left the new
                // question below the fold, behind the composer, until the first
                // token finally landed. Follow the tail on the append itself.
                //
                // TWICE, on purpose: `onChange` runs while SwiftUI is still
                // updating, so the ScrollView's content at that instant is the
                // OLD, shorter thread and this first `scrollTo` can only clamp at
                // the old maximum offset. The deferred pass runs once the
                // appended turns have been laid out, when the anchor can actually
                // be reached. (Same shape as the panel's own result view.)
                .onChange(of: store.turns.count) { _, _ in
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    DispatchQueue.main.async {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
                .onChange(of: store.turns.last?.text.count ?? 0) { _, _ in
                    guard streaming else { return }
                    // The compact window opens to fit its answer, so there is
                    // nothing to follow until the answer outgrows the cap —
                    // and following the few points the waiting orb overflows a
                    // still-closed box would nudge the first line up exactly as
                    // it lands.
                    if compactShortcut, !compactAnswerIsCapped { return }
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
                // Regular detached threads append their footer on settle. At the
                // ceiling it lands below the fold, so follow their tail once more
                // after layout. A compact answer carries its footer from the first
                // token (`stabilizesFooterWhileStreaming`), so settling adds no
                // height there and the tail is already where the reader left it.
                .onChange(of: streaming) { _, nowStreaming in
                    guard !nowStreaming else { return }
                    guard !compactShortcut else { return }
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(Self.bottomID, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(.horizontal, cardHorizontal)
            // Every detached thread can be continued where it stands — a
            // pointer-side answer no longer dead-ends at "copy it or close it".
            followUpRow
                .padding(.horizontal, followUpHorizontal)
                .padding(.top, compactShortcut ? Self.compactFollowUpGap
                                               : Self.followUpGap)
        }
        .padding(.top, cardTop)
        .padding(.bottom, cardBottom)
        .onPreferenceChange(DetachedThreadContentHeightKey.self) { measured in
            guard compactShortcut, measured > 0 else { return }
            // Recorded BEFORE the wait gate below: `compactAnswerIsCapped` must
            // know how tall the thread stands even in the rounds this view
            // deliberately declines to resize the window for.
            measuredContentHeight = measured
            // A wait is not a reason to move a window: the waiting card opens
            // once, to its own floor (`compactInitialHeight`), and only the
            // answer grows it past that (`compactFloorHeight`). That holds for
            // the FIRST round only — see `hasAnswered`.
            guard hasAnswered || hasPendingQuestion else { return }
            // The turn stack — footer included, it is part of the answer — plus
            // the gaps it rests between, the card's own padding, and the window
            // chrome an answered shortcut carries: the margins, the header and
            // the follow-up row.
            onDesiredHeight(max(compactWindowHeight(forContentHeight: measured),
                                estimatedCompactWindowHeight(for: latestAnswerText)))
        }
        .onChange(of: latestAnswerText) { _, answer in
            guard compactShortcut, !answer.isEmpty else { return }
            // The AppKit estimate is an independent backstop for streaming
            // Markdown. It changes at the exact character edge, so the window can
            // grow even if SwiftUI coalesces or constrains a geometry preference.
            onDesiredHeight(estimatedCompactWindowHeight(for: answer))
        }
        .onAppear {
            guard compactShortcut, !latestAnswerText.isEmpty else { return }
            onDesiredHeight(estimatedCompactWindowHeight(for: latestAnswerText))
        }
        // The hovered source badge's popup, floated at the window level — outside
        // the thread's ScrollView, which would otherwise clip it. Without this the
        // badge in a detached window published its anchor to nobody: the pill sat
        // there and hovering it did nothing at all. Same modifier the panel uses.
        .sourcePopoverOverlay(hoveredID: $hoveredSourceID, closeWork: $sourceCloseWork)
    }

    /// The thread has outgrown the window's ceiling — past here the window stops
    /// opening and the ScrollView takes over, which is the only point at which a
    /// compact answer needs its tail followed.
    ///
    /// Measured off the THREAD, not the newest answer. The AppKit estimate alone
    /// asks "would this one answer's prose fill a whole 520pt window?", which in
    /// a follow-up round is answered by an assistant turn that is still empty —
    /// so a second question landing in an already-capped card followed nothing at
    /// all, and the new bubble plus its wait row sat below the fold behind the
    /// composer. The content probe reports the complete stack (every turn, both
    /// bubbles of every round), so it knows what the estimate cannot. The
    /// estimate stays as the streaming backstop it was, for the beat before a
    /// geometry pass lands.
    private var compactAnswerIsCapped: Bool {
        max(compactWindowHeight(forContentHeight: measuredContentHeight),
            estimatedCompactWindowHeight(for: latestAnswerText))
            > DetachedSessionWindowController.compactMaxHeight
    }

    /// Estimate the rendered prose at the compact window's real text width. The
    /// SwiftUI content probe above is authoritative; this is only a floor for the
    /// streamed case, where a geometry report can be coalesced or arrive a beat
    /// late — so it must never come out ABOVE the real layout, or the window
    /// wears the difference as dead space (growth here is one-way within a round,
    /// see `resizeCompactThread`).
    ///
    /// It measures the answer ONE LINE PER BLOCK. `MarkdownParser.plainText` is
    /// the clipboard serialization: it joins every block — each bullet of a list
    /// included — with a BLANK line, which the renderer never draws (blocks sit
    /// 8pt apart, see `MarkdownBlocks`). Measuring that text charged a phantom
    /// line per bullet: a six-bullet answer measured 480pt against a real 367pt.
    private func estimatedCompactWindowHeight(for answer: String) -> CGFloat {
        guard compactShortcut else { return 0 }
        return Self.estimatedCompactWindowHeight(for: answer)
    }

    /// The view-free form of that estimate — what a saved answer will need once
    /// it is laid out in this window (see `openForceTouchHistoryThread`).
    static func estimatedCompactWindowHeight(for answer: String) -> CGFloat {
        let plain = MarkdownParser.plainText(answer)
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        // Nothing written yet: the waiting card's own floor governs (see
        // `compactInitialHeight`) — this estimate has nothing to say yet.
        guard !plain.isEmpty else { return 0 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 15 * 0.45
        let bounds = (plain as NSString).boundingRect(
            with: NSSize(width: Self.compactAnswerTextWidth,
                         height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: NSFont.systemFont(ofSize: 15),
                .paragraphStyle: paragraph,
            ])
        // Same arithmetic the real measurement goes through (chrome, card
        // padding, and whichever pair of gaps the stack rests between) — the two
        // must agree on the rhythm, or the backstop would ask for a scrolling
        // card's height while the layout is resting and the window would wear
        // the difference as dead space.
        return compactWindowHeight(
            forContentHeight: ceil(bounds.height) + compactFooterHeight
        )
    }

    /// The width the answer's prose actually wraps at: the compact window, less
    /// the face's margins and the card's own horizontal padding. Measured at the
    /// widest a compact window gets (a shortcut that opens straight into an
    /// answer). A card that grew out of the composer is narrower, so the same
    /// text wraps to MORE lines there than this predicts — which is the safe
    /// direction: this number is only ever a floor (see above).
    private static let compactAnswerTextWidth: CGFloat =
        DetachedSessionWindowController.compactWidth
            - CompactShortcutMetrics.inset * 2 - cardHorizontalPadding * 2

    /// The same follow-up line the panel's result view carries — a submit here
    /// runs the round through the panel pipeline, headless (see
    /// `NotchModel.submitDetachedFollowUp`), and streams back into this window.
    /// Disabled while a round streams: the tear-off dropped the round's task
    /// handle, so a mid-stream line couldn't supersede it.
    private var followUpRow: some View {
        // THE panel's composer, not a copy of it: `ComposerBox` is the same box
        // the notch's own follow-up line is, down to the growing silhouette, the
        // focus-lit recess and the glass `SendButton` — a torn-off session is
        // the same conversation in a bigger frame, so its input can't be a
        // different control. (It used to be a single-line SwiftUI `TextField` on
        // a flat, never-lit `Capsule`: it couldn't grow with a wrapped line and
        // its placeholder sat under composing pinyin.)
        VStack(alignment: .leading, spacing: 8) {
            if !followUpImages.isEmpty {
                ComposeImagesAttachedLine(images: followUpImages) { index in
                    guard followUpImages.indices.contains(index) else { return }
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        followUpImages.remove(at: index)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                ComposerBox(
                    text: $followUp,
                    onSubmit: sendFollowUp,
                    onPasteImage: pasteFollowUpImage,
                    placeholder: { Text(L("result.followUp")) },
                    trailing: {
                        if hasFollowUpInput {
                            SendButton(compact: true, action: sendFollowUp)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    })
                    .opacity(streaming ? 0.45 : 1)
                    .disabled(streaming)

                if hasAgentMetadata {
                    GlassIconButton(systemName: "command", help: L("agent.detail"),
                                    size: 39, glyphSize: 13,
                                    showsTooltip: false) {
                        metadataMenuOpen.toggle()
                    }
                    .modifier(MenuCardWindow(
                        open: metadataMenuOpen,
                        upperLeading: true,
                        onDismiss: { _ in metadataMenuOpen = false },
                        card: {
                            AnyView(AgentRunMetadataMenu(
                                engine: agentRunCaption,
                                folderPath: store.agentFolderPath,
                                completedAt: store.completedAt,
                                onOpenFolder: {
                                    metadataMenuOpen = false
                                    if let path = store.agentFolderPath {
                                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                                    }
                                })
                                .manageMenuCardBackground())
                        }))
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.78),
                   value: hasAgentMetadata)
    }

    private func sendFollowUp() {
        var line = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = followUpImages
        guard !streaming else { return }
        if line.isEmpty {
            guard !images.isEmpty else { return }
            line = NotchModel.agentImageOnlyPrompt(count: images.count)
        }
        followUp = ""
        followUpImages = []
        onFollowUp(line, images)
    }

    private var hasFollowUpInput: Bool {
        !followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !followUpImages.isEmpty
    }

    private func pasteFollowUpImage() -> Bool {
        guard store.followUpSupportsImages,
              let image = NotchModel.pasteboardImage() else { return false }
        guard followUpImages.count < NotchModel.composeImageLimit else { return true }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            followUpImages.append(image)
        }
        return true
    }

    /// One header for every detached thread, pointer-side shortcut answers
    /// included: the window's own actions — pin, close — as two bare glyphs on
    /// the trailing edge, and nothing else. Content
    /// actions — copy, plain copy, regenerate, ⓘ — never live here; they belong
    /// to the answer and ride its footer (`AssistantTurnView`). The compact face
    /// used to float a copy+pin pill outside the card instead, which put the
    /// same copy button in two different places in two windows.
    private var header: some View {
        HStack(spacing: 10) {
            // Width only. A `maxHeight: .infinity` here makes the header row
            // itself greedy, and in a VStack against a ScrollView the two split
            // the window between them — the card opened with a band of nothing
            // above the answer and the pin/close marks floating in its middle.
            // The row is exactly `headerHeight`, which is also what the window's
            // height arithmetic budgets for it (`CompactShortcutMetrics
            // .answerChrome`), so the two can't disagree.
            Color.clear
                .frame(maxWidth: .infinity)
            // On the compact face this row is empty on purpose: its two marks
            // are the composer's, still standing where the composer left them
            // (`DetachedSessionRootView.compactChips`).
            if !compactShortcut {
                WindowTrailingCluster(pinned: pinned, togglePin: onTogglePin,
                                      close: onClose)
            }
        }
        .frame(height: Self.headerHeight)
    }

    private func replaceLatestAnswer() -> Bool {
        let answer = latestAnswerText
        guard !answer.isEmpty else { return false }
        return onReplaceOriginal(answer)
    }

    @ViewBuilder
    private func turnView(_ turn: NotchModel.Turn) -> some View {
        if turn.role == "user" {
            VStack(alignment: .leading, spacing: 5) {
                if !turn.imageFiles.isEmpty {
                    SavedTurnImages(files: turn.imageFiles)
                        .padding(.leading, 12)
                } else if turn.usedClipboard {
                    Text(L("result.basedOnCopied"))
                        .font(.sf(11))
                        .tracking(0.2)
                        .foregroundStyle(Tokens.text4)
                        .padding(.leading, 12)
                }
                UserQuestionBubble(text: turn.text)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let log = turn.agentLog?.droppingTrailingAnswer(turn.text), !log.isEmpty {
                    AgentWorkTrailView(entries: log)
                }
                assistantTurn(turn)
            }
        }
    }

    /// The panel's full answer view — wait line, sources badge, and the settled
    /// footer (copy · plain copy · regenerate · model ⓘ) — so the torn-out
    /// thread keeps every action the panel offers. Regenerate belongs only to the
    /// last answer and stays disabled while that answer is still streaming.
    private func assistantTurn(_ turn: NotchModel.Turn) -> some View {
        let isLastTurn = store.turns.last?.id == turn.id
        let canRegenerate = isLastTurn && !turn.isAgent
        return AssistantTurnView(
            text: turn.text,
            streaming: turn.streaming,
            activity: turn.toolActivity,
            orbState: turn.thinkingOrbState ?? .composing,
            thinkingWord: turn.thinkingWord ?? "",
            thinkingSince: turn.streaming ? turn.thinkingStartedAt : nil,
            sources: turn.sources,
            hoveredSourceID: $hoveredSourceID,
            sourceCloseWork: $sourceCloseWork,
            isAgent: turn.isAgent,
            completedAt: (turn.isAgent && isLastTurn) ? store.completedAt : nil,
            // Compact shortcut answers carry the footer too now — copy lives
            // with the answer in every window, not on a pill beside one of them.
            // It rides UNDER the answer, in the scroll, in every face; the compact
            // card only shows it earlier (see `stabilizesFooterWhileStreaming`).
            showsFooter: true,
            stabilizesFooterWhileStreaming: compactShortcut,
            showsFooterMetadata: !turn.isAgent,
            onInAppCopy: onInAppCopy,
            onRegenerate: canRegenerate ? onRegenerate : nil,
            regenerateModels: canRegenerate ? regenerateOptions() : [],
            onRegenerateWith: canRegenerate ? onRegenerateWith : nil,
            regenModel: turn.regenModel,
            answerModel: turn.answerModel,
            pendingQuestion: turn.streaming ? turn.pendingQuestion : nil,
            onChooseOption: onChooseOption
        )
    }

}

// MARK: - Agent task window body

/// A detached agent run: the full work trail writing itself live, the report on
/// settle, and a follow-up line — the complete card, running in its own window
/// while the notch goes back to resting.
struct DetachedAgentTaskView: View {
    let taskID: UUID
    var pinned: Bool
    var onTogglePin: () -> Void
    var onClose: () -> Void

    @ObservedObject private var manager = AgentTaskManager.shared
    @State private var followUp = ""
    @State private var followUpImages: [NSImage] = []
    /// The task's last seen value — keeps the window readable if the task is
    /// dismissed from the tray while this window is open.
    @State private var lastKnown: AgentTaskManager.AgentTask?
    /// The tail-follow release, same rule the panel's detail page uses: chase the
    /// newest line only while the reader is still at the bottom. Measured rather
    /// than assumed, because this window's viewport is resizable.
    @State private var followsTail = true
    @State private var contentBottom: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    private static let bottomID = "detached-agent-bottom"
    private static let scrollSpace = "detached-agent-scroll"
    private static let tailSlack: CGFloat = 28

    private var task: AgentTaskManager.AgentTask? {
        manager.tasks.first { $0.id == taskID } ?? lastKnown
    }

    var body: some View {
        Group {
            if let task {
                content(task)
                    .onChange(of: manager.tasks.first(where: { $0.id == taskID })) { _, latest in
                        if let latest { lastKnown = latest }
                    }
                    .onAppear { lastKnown = manager.tasks.first { $0.id == taskID } }
            } else {
                Text(L("detached.task.gone"))
                    .font(.sf(13))
                    .foregroundStyle(Tokens.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // Same rhythm as the panel's agent detail page (NotchBody's uniform 15pt
    // inset, header then the quiet gap), so the tear doesn't reflow the trail.
    private func content(_ task: AgentTaskManager.AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(task)
            ScrollViewReader { proxy in
                ScrollView {
                    // The panel detail page's own record body, shared verbatim
                    // (`AgentRecordBody`): every settled round's prompt, trail
                    // and report, then the round in flight. This window used to
                    // render the flat trail plus only the LATEST answer, so a
                    // multi-round run lost every earlier report the moment it
                    // was torn out of the notch.
                    AgentRecordBody(task: task, bottomID: Self.bottomID)
                    // Runways: the trail rests between the header and the
                    // follow-up line, then scrolls into these empty bands — up
                    // behind the header, down behind the input — to fade +
                    // frost out on both edges (see ThreadScroll).
                    .padding(.top, ThreadScroll.runway)
                    .padding(.bottom, ThreadScroll.runway)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { geo in
                        Color.clear.preference(
                            key: DetachedAgentContentBottomKey.self,
                            value: geo.frame(in: .named(Self.scrollSpace)).maxY)
                    })
                }
                .coordinateSpace(name: Self.scrollSpace)
                // Overlay, not a wrapper: the viewport's height is needed to know
                // where "the bottom" is, and measuring it must not touch layout.
                .overlay(GeometryReader { geo in
                    Color.clear.preference(key: DetachedAgentViewportKey.self,
                                           value: geo.size.height)
                })
                .onPreferenceChange(DetachedAgentViewportKey.self) { height in
                    viewportHeight = height
                    refreshTailFollow()
                }
                .onPreferenceChange(DetachedAgentContentBottomKey.self) { bottom in
                    contentBottom = bottom
                    refreshTailFollow()
                }
                // Sticky affordances inside the record (a code block's copy
                // button) park below the top fade band, not in it.
                .environment(\.stickyScrollTopInset, ThreadScroll.runway)
                .scrollEdgeFade(top: true, bottom: true, fade: ThreadScroll.runway)
                .progressiveEdgeBlur(top: ThreadScroll.band, bottom: ThreadScroll.band,
                                     topRadius: ThreadScroll.blurRadius)
                .onChange(of: task.log.count) { _, _ in followTail(proxy) }
                // The trailing block GROWS token by token, which moves the tail
                // without changing the row count.
                .onChange(of: task.log.last?.title) { _, _ in followTail(proxy) }
                .onAppear {
                    followsTail = true
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
                .overlay(alignment: .bottom) {
                    if !followsTail {
                        GlassIconButton(systemName: "arrow.down",
                                        help: L("agent.trail.toBottom"),
                                        size: 26, glyphSize: 11,
                                        showsTooltip: false) {
                            followsTail = true
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(Self.bottomID, anchor: .bottom)
                            }
                        }
                        .padding(.bottom, 4)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: followsTail)
            }
            VStack(alignment: .leading, spacing: 8) {
                if !followUpImages.isEmpty {
                    ComposeImagesAttachedLine(images: followUpImages) { index in
                        guard followUpImages.indices.contains(index) else { return }
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            followUpImages.remove(at: index)
                        }
                    }
                }
                followUpRow(task)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, DetachedThreadView.cardHorizontalPadding)
        .padding(.top, DetachedThreadView.cardTopPadding)
        .padding(.bottom, DetachedThreadView.cardBottomPadding)
    }

    private func header(_ task: AgentTaskManager.AgentTask) -> some View {
        HStack(spacing: 10) {
            AgentStatusDot(running: task.isRunning, outcome: task.outcome)
            Text("\(task.engine.displayName) · \(task.folder.lastPathComponent)")
                .font(.sf(14, weight: .medium))
                .foregroundStyle(Tokens.text2)
                .lineLimit(1)
            Color.clear
                .frame(maxWidth: .infinity)
            if task.isRunning {
                TimelineView(.periodic(from: task.startedAt, by: 1)) { context in
                    elapsedLabel(context.date.timeIntervalSince(task.startedAt))
                }
                Button(action: { manager.cancel(taskID: task.id) }) {
                    Image(systemName: "stop.circle")
                        .font(.sf(13, weight: .semibold))
                        .foregroundStyle(Tokens.text3)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                elapsedLabel(task.elapsed)
            }
            WindowTrailingCluster(pinned: pinned, togglePin: onTogglePin,
                                  close: onClose)
        }
    }

    private func elapsedLabel(_ elapsed: TimeInterval) -> some View {
        let seconds = max(0, Int(elapsed))
        return Text(NotchModel.formatAgentElapsed(TimeInterval(seconds)))
            .font(.sf(11))
            .monospacedDigit()
            .foregroundStyle(Tokens.text4)
            .lineLimit(1)
            .fixedSize()
    }

    /// Whether the content's end still sits at (or just below) the viewport's
    /// bottom edge — the one thing that decides if the page keeps chasing the
    /// tail. Both measurements arrive independently, so this runs on either.
    private func refreshTailFollow() {
        guard viewportHeight > 0 else { return }
        let atTail = contentBottom - viewportHeight <= Self.tailSlack
        if atTail != followsTail { followsTail = atTail }
    }

    private func followTail(_ proxy: ScrollViewProxy) {
        guard followsTail else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    private func followUpRow(_ task: AgentTaskManager.AgentTask) -> some View {
        // Mid-run the field stays live: Enter queues the line and the manager
        // dispatches it as the next round on settle — typed input is never
        // dropped. Only a run that settled without ever reporting a session id
        // (nothing to resume, ever) goes dead.
        let dead = !task.isRunning && task.sessionID == nil
        // The panel agent page's own composer (`ComposerBox`), not a second one:
        // same growing silhouette, same focus-lit recess, same ⏎/⌘⏎ hints — the
        // page reads identically on both sides of a tear.
        return ComposerBox(
            text: $followUp,
            onSubmit: { sendFollowUp(task) },
            onPasteImage: { pasteFollowUpImage(task) },
            onCommandSubmit: {
                guard task.isRunning, task.sessionID != nil,
                      hasFollowUpInput
                else { return false }
                sendFollowUp(task, interrupting: true)
                return true
            },
            placeholder: {
                Text(L(task.isRunning ? "agent.followUp.queue"
                                      : "agent.followUp.placeholder"))
            },
            trailing: {
                if hasFollowUpInput {
                    AgentFollowUpKeyHints(
                        showsInterrupt: task.isRunning && task.sessionID != nil)
                        .transition(.opacity)
                }
            })
        .opacity(dead ? 0.45 : 1)
        .disabled(dead)
    }

    /// `interrupting` stops the round in flight and re-opens the session with
    /// this line straight away; the plain path queues it for the next round.
    private func sendFollowUp(_ task: AgentTaskManager.AgentTask,
                              interrupting: Bool = false) {
        var line = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = followUpImages
        if line.isEmpty {
            guard !images.isEmpty else { return }
            line = NotchModel.agentImageOnlyPrompt(count: images.count)
        }
        followUp = ""
        followUpImages = []
        // Sending says you want to watch what happens next.
        followsTail = true
        Task {
            let jpegs = await Task.detached(priority: .userInitiated) {
                images.compactMap { NotchModel.encodeJPEGForVision($0) }
            }.value
            if interrupting {
                manager.interrupt(taskID: task.id, prompt: line, imagesJPEG: jpegs)
            } else {
                manager.followUp(taskID: task.id, prompt: line, imagesJPEG: jpegs)
            }
        }
    }

    private var hasFollowUpInput: Bool {
        !followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !followUpImages.isEmpty
    }

    private func pasteFollowUpImage(_ task: AgentTaskManager.AgentTask) -> Bool {
        guard task.engine.supportsImageInput,
              let image = NotchModel.pasteboardImage() else { return false }
        guard followUpImages.count < NotchModel.composeImageLimit else { return true }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            followUpImages.append(image)
        }
        return true
    }
}

/// Where the detached agent window's scroll content ends, and how tall its
/// viewport is — together they say whether the page is still at the tail.
private struct DetachedAgentContentBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next != 0 { value = next }
    }
}

private struct DetachedAgentViewportKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next != 0 { value = next }
    }
}
