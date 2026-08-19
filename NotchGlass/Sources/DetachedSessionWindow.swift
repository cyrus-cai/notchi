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

    init(threadID: UUID, turns: [NotchModel.Turn]) {
        self.threadID = threadID
        self.turns = turns
    }

    /// The round finished (persisted to Recent) — freeze the mirror: no caret,
    /// no stale "searching…" line.
    func settle(with thread: [NotchModel.Turn]) {
        var cleaned = thread
        for i in cleaned.indices {
            cleaned[i].streaming = false
            cleaned[i].toolActivity = nil
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
                                               sourceApplication: NSRunningApplication?) {
        retirePointerWindows(besides: shortcutID)
        if let existing = controllers.first(where: {
            $0.compactShortcutID == shortcutID
        }) {
            existing.replaceCompactComposer(selectedText: selectedText,
                                             near: pointer,
                                             sourceApplication: sourceApplication)
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
        c.state.pressDepth = 0
        // The capsule is already standing by the time there is anything to put in
        // it, so the face must never replay its own swell on top of the stretch.
        c.state.grownIn = true
        c.state.phase = .settled
        c.summonPointer = pointer
        controllers.append(c)
        let rect = composerWindowRect(caretAt: pointer)
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
        let rect = Self.composerWindowRect(caretAt: pointer)
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
        replacementApplication = sourceApplication
        window.title = title
        window.minSize = Self.compactMinSize
        // A fresh round with no composer behind it waits at the card again.
        compactFloorHeight = Self.compactInitialHeight
        resizeCompactThread(to: Self.compactInitialHeight, reset: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Reusing the same empty-prompt shortcut replaces both pieces of transient
    /// state: the captured selection and any draft left in the field. If its
    /// previous invocation was still generating, that obsolete round is stopped
    /// before this window returns to its one-line composer face.
    private func replaceCompactComposer(selectedText: String,
                                        near pointer: NSPoint,
                                        sourceApplication: NSRunningApplication?) {
        guard compactShortcut, let model, let shortcutID = compactShortcutID else { return }
        summonPointer = pointer
        state.grownIn = ForceClickHerald.shared.isPresenting
        reanchorForInvocation(near: pointer, asComposer: true)
        if let oldStore = threadStore {
            model.cancelCompactRound(threadID: oldStore.threadID)
            model.releaseDetachedThread(oldStore.threadID)
        }
        state.threadStore = nil
        state.compactSourceText = selectedText
        state.compactPromptDraft = ""
        state.compactPromptGeneration += 1
        state.openingFromComposer = false
        state.session = .shortcutComposer(id: shortcutID)
        replacementApplication = sourceApplication
        window.title = L("shortcuts.promptAction.window.context")
        // Back to the capsule: drop the answer floor first, or AppKit clamps the
        // window at the taller size it was holding as a result view.
        window.minSize = Self.compactComposerMinSize
        compactFloorHeight = Self.compactInitialHeight
        resizeCompactThread(to: CompactShortcutPromptView.restingHeight, reset: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // The capsule the press stretched IS this window's capsule, so there is no
        // cue to take off screen — only the herald's bookkeeping to let go of.
        if state.grownIn { ForceClickHerald.shared.handOff() }
    }

    /// The transient instruction now has everything it needs. Start the same
    /// headless prompt-shortcut round as a saved instruction and let this exact
    /// compact window become its live result view in place.
    private func submitCompactShortcutPrompt(_ prompt: String) {
        guard compactShortcut,
              case .shortcutComposer = state.session,
              let model,
              let threadID = model.startPromptShortcutRound(
                prompt: prompt, selectedText: state.compactSourceText)
        else { return }
        // The line stays in the capsule while the capsule dissolves: clearing it
        // here brought the placeholder ("What should I do with it?") flashing
        // back for the length of the fade. The next invocation resets the draft
        // (`replaceCompactComposer`), and this face is leaving regardless.
        state.threadStore = model.adoptDetachedThread(threadID)
        // The card takes over the box in place — it does not arrive from
        // anywhere (`DetachedSessionRootView.compactShortcutFace`).
        state.openingFromComposer = true
        withAnimation(Self.reduceMotion ? nil : .easeOut(duration: 0.18)) {
            state.session = .thread(id: threadID)
        }
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
        compactFloorHeight = Self.compactInitialHeight
        resizeCompactThread(to: Self.compactInitialHeight, reset: true, animated: true)
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
            grown.origin.x = max(visible.minX + 8, min(grown.origin.x, visible.maxX - grown.width - 8))
            grown.origin.y = max(visible.minY + 8, min(grown.origin.y, visible.maxY - grown.height - 8))
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
        if let visible = window.screen?.visibleFrame, target.minY < visible.minY + 8 {
            target.origin.y = visible.minY + 8
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
                return
            }
            // One caller asks for this move to be seen: the capsule opening into
            // its own answer. Everything else (a fresh round, a wrapped draft)
            // lands the height at once.
            if animated && !Self.reduceMotion {
                glideCompact(to: measured)
            } else {
                stopCompactGlide()
                setCompactHeight(measured)
            }
            return
        }
        // Same hysteresis as the prompt editor's IME fix: growth is real and
        // immediate; a lower intermediate measurement is not. The floor is
        // deliberately reset only when this shortcut starts a new round.
        guard measured > compactRoundHeight + 0.5 else { return }
        compactRoundHeight = measured
        guard !Self.reduceMotion else {
            setCompactHeight(measured)
            return
        }
        glideCompact(to: measured)
    }

    /// Put the compact window at `height`, hanging from its own top edge and
    /// nudged back inside the screen at the bottom. Every compact resize — the
    /// hard sets and every frame of the glide — goes through here.
    private func setCompactHeight(_ height: CGFloat, reshadow: Bool = true) {
        guard window != nil else { return }
        let frame = window.frame
        var target = NSRect(x: frame.minX, y: frame.maxY - height,
                            width: frame.width, height: height)
        let visible = window.screen?.visibleFrame
            ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        if let visible {
            if target.minY < visible.minY + Self.screenMargin {
                target.origin.y = visible.minY + Self.screenMargin
            }
            if target.maxY > visible.maxY - Self.screenMargin {
                target.origin.y = visible.maxY - Self.screenMargin - target.height
            }
        }
        window.setFrame(target, display: true, animate: false)
        // The window's silhouette is its own glass, not its rect (the action pill
        // leaves a transparent band above the card), so AppKit has to re-derive
        // the shadow from what's drawn. Re-deriving it costs real work, so the
        // glide only asks for it every few frames (and always on its last one).
        if reshadow { window.invalidateShadow() }
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
            let current = self.window.frame.height
            var next = current + (self.compactTargetHeight - current)
                * (1 - exp(-dt / Self.compactGlideTau))
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
    static let compactWidth: CGFloat = 410
    /// The waiting card — what an answer window is before a word has landed: the
    /// window chrome an answered card carries (margins, header, follow-up row),
    /// its own top/bottom padding, the resting gaps the one orb row rests
    /// between, and that row. A single line never scrolls, so it wears the
    /// resting rhythm rather than the runways (`DetachedThreadView`) — budgeting
    /// two 28pt runways for it opened the wait 38pt taller than the card it
    /// becomes and left the orb floating in the middle of an empty box.
    private static let compactInitialHeight: CGFloat =
        CompactShortcutMetrics.answerChrome
            + DetachedThreadView.cardTopPadding + DetachedThreadView.cardBottomPadding
            + DetachedThreadView.restingTopGap + DetachedThreadView.restingBottomGap + 26
    fileprivate static let compactMaxHeight: CGFloat = 520
    private static let compactMinSize = NSSize(width: 340, height: 96)
    /// The bare prompt-shortcut composer is shorter than any answer window, so
    /// it carries its own floor — the shared one would have AppKit inflate it
    /// back into a half-empty slab the moment it's created.
    private static let compactComposerMinSize = NSSize(width: 340, height: 60)
    private static let pointerGap: CGFloat = 12
    private static let screenMargin: CGFloat = 8

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
                ? CompactShortcutPromptView.restingHeight
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
        w.isMovableByWindowBackground = true
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
            onReattach: { [weak self] in self?.mergeBack(animated: true) },
            onTogglePin: { [weak self] in self?.togglePin() },
            onClose: { [weak self] in self?.window.close() },
            onInAppCopy: { [weak self] in
                self?.model?.rebaselineClipboardAfterInAppWrite()
            },
            onReplaceOriginal: { [weak self] text in
                self?.replaceOriginalText(with: text) ?? false
            },
            onFollowUp: { [weak self] line in
                guard let self, let id = self.threadStore?.threadID else { return }
                self.model?.submitDetachedFollowUp(threadID: id, question: line)
            },
            onRegenerate: { [weak self] in
                guard let self, let id = self.threadStore?.threadID else { return }
                self.model?.regenerateDetachedAnswer(threadID: id)
            },
            onRegenerateWith: { [weak self] pick in
                guard let self, let id = self.threadStore?.threadID else { return }
                self.model?.regenerateDetachedAnswer(threadID: id, model: pick)
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
            onCompactPrompt: { [weak self] line in
                self?.submitCompactShortcutPrompt(line)
            },
            onCaretOffset: { [weak self] offset in self?.alignCaret(to: offset) },
            compactShortcut: compactShortcut,
            onThreadHeight: { [weak self] h in self?.resizeCompactThread(to: h) })
            .environmentObject(Localization.shared)
            // This window's own edges are the wall its hover tooltips clamp to —
            // the island's coordinate space doesn't reach here.
            .coordinateSpace(.named(TooltipCoordinateSpace.clipBox))
        w.contentView = NSHostingView(rootView: root)
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

    /// Where a pointer-side window is born.
    ///
    /// A composer (`asComposer`) is placed by its CARET: the window hangs so the
    /// text cursor lands exactly on the pointer that summoned it, which is what
    /// makes a force click read as "type here" instead of "a box appeared
    /// somewhere near where I pressed". Pinning the *top* edge is what keeps that
    /// true for the rest of the window's life — every compact resize hangs off
    /// that edge (`setCompactHeight`), so growing into the answer leaves the line
    /// the user typed on exactly where they aimed.
    ///
    /// An answer window has no caret, so it keeps the old placement: the
    /// pointer's right side, flipped left when that would cross the display.
    ///
    /// Both clamp to the usable screen frame. The display is
    /// `NSScreen.containing` — the app's single source of truth for "where is the
    /// mouse", so a chord fired at a screen seam or in the menu-bar row can't
    /// land the window on a different monitor.
    ///
    /// `size` lets an already-grown window be re-anchored without shrinking back
    /// to the opening size; it defaults to the size a fresh window is born at.
    private func compactRect(near pointer: NSPoint, size: NSSize? = nil,
                             asComposer: Bool = false) -> NSRect {
        let visible = NSScreen.containing(pointer)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(size?.width ?? Self.compactWidth,
                        visible.width - Self.screenMargin * 2)
        if asComposer { return Self.composerWindowRect(caretAt: pointer, size: size) }
        let height = size?.height ?? Self.compactInitialHeight
        let rightX = pointer.x + Self.pointerGap
        let leftX = pointer.x - Self.pointerGap - width
        let x = rightX + width <= visible.maxX - Self.screenMargin
            ? rightX
            : max(visible.minX + Self.screenMargin, leftX)
        let proposedTop = pointer.y + 18
        let top = min(visible.maxY - Self.screenMargin,
                      max(visible.minY + height + Self.screenMargin, proposedTop))
        return NSRect(x: x, y: top - height, width: width, height: height)
    }

    /// The composer's window frame for a caret at `pointer`, clamped to that
    /// pointer's display.
    ///
    /// Static and public to the module because `ForceClickHerald` has to land its
    /// pressure cue on the *same* geometry — including the clamp. Two places
    /// each doing their own version of this arithmetic is exactly how the cue and
    /// the capsule it becomes would drift apart at a screen edge.
    static func composerWindowRect(caretAt pointer: NSPoint,
                                   size: NSSize? = nil) -> NSRect {
        let visible = NSScreen.containing(pointer)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(size?.width ?? compactWidth, visible.width - screenMargin * 2)
        let height = size?.height ?? CompactShortcutPromptView.restingHeight
        let caret = CompactShortcutMetrics.caretOffset
        let x = min(max(pointer.x - caret.x, visible.minX + screenMargin),
                    visible.maxX - screenMargin - width)
        let top = min(max(pointer.y + caret.y, visible.minY + screenMargin + height),
                      visible.maxY - screenMargin)
        return NSRect(x: x, y: top - height, width: width, height: height)
    }

    /// The input capsule's own screen rect inside that window — what the pressure
    /// cue grows into, and what it must be indistinguishable from at handoff.
    static func composerCapsuleRect(caretAt pointer: NSPoint) -> NSRect {
        let window = composerWindowRect(caretAt: pointer)
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
        CompactShortcutMetrics.rememberCaret(offset)
        guard let summonPointer, window != nil, !state.pinned else { return }
        let frame = window.frame
        let target = NSPoint(x: summonPointer.x - offset.x,
                             y: summonPointer.y + offset.y - frame.height)
        guard abs(target.x - frame.minX) > 0.5 || abs(target.y - frame.minY) > 0.5
        else { return }
        // Only ever nudge within the display the window is already on: the clamped
        // placement in `composerWindowRect` had the last word on which screen.
        guard let visible = window.screen?.visibleFrame,
              visible.insetBy(dx: -1, dy: -1).contains(
                NSPoint(x: target.x + frame.width / 2, y: target.y + frame.height / 2))
        else { return }
        window.setFrameOrigin(target)
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
            ctx.duration = 0.2
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
        armMergeTracking()
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
            MainActor.assumeIsolated { self?.windowMoved() }
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
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        disarmMergeHint()
        if let threadStore { model?.releaseDetachedThread(threadStore.threadID) }
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
    var onReattach: () -> Void
    var onTogglePin: () -> Void
    var onClose: () -> Void
    // Thread-window actions (unused by the agent-task face, which talks to
    // `AgentTaskManager` directly).
    var onInAppCopy: () -> Void = {}
    var onReplaceOriginal: (String) -> Bool = { _ in false }
    var onFollowUp: (String) -> Void = { _ in }
    var onRegenerate: () -> Void = {}
    var onRegenerateWith: (String) -> Void = { _ in }
    var regenerateOptions: () -> [(model: String, isCurrent: Bool)] = { [] }
    /// Enter in the composer face: the line and where it reads as going.
    var onCompose: (String, NotchModel.Panel) -> Void = { _, _ in }
    /// The composer's wanted height as its draft wraps — the window follows it.
    var onComposeHeight: (CGFloat) -> Void = { _ in }
    /// Enter in an empty-prompt shortcut's one-line composer.
    var onCompactPrompt: (String) -> Void = { _ in }
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
    /// The card's header lands exactly in the transparent band the composer held
    /// above its capsule (8…40 from the window's top edge), so the morph still
    /// puts the answer's first line about where the typed line was — the band
    /// stopped being empty chrome and became the card's own header.
    @ViewBuilder
    private var compactShortcutFace: some View {
        if isBareComposer {
            compactComposerFace
                .transition(.opacity)
        } else {
            slab(corner: Self.cornerRadius)
                .padding(CompactShortcutMetrics.inset)
                .scaleEffect(entered ? 1 : 0.92, anchor: state.entranceAnchor)
                .opacity(entered ? 1 : 0)
                .offset(y: entered ? 0 : -4)
                // Enter in this window's OWN capsule is not an arrival: the card
                // is the box the user is already looking at, grown. Replaying the
                // pointer entrance here is what made it read as a second window
                // popping over the line just typed — the card stands where the
                // capsule stood and the window opens under it (see
                // `submitCompactShortcutPrompt`).
                .onAppear {
                    if state.openingFromComposer { entered = true } else { playEntrance() }
                }
                .onChange(of: state.entranceToken) { _, _ in playEntrance() }
                .transition(.opacity)
        }
    }

    /// The empty-prompt shortcut's one-line composer: a band held clear on top,
    /// the capsule, and the captured-context footnote under it.
    private var compactComposerFace: some View {
        // Explicit gaps, not VStack spacing: the badge is absent when nothing was
        // captured, and stack spacing around an absent row would quietly eat 8pt
        // out of a window that is frozen at `restingHeight`.
        VStack(alignment: .leading, spacing: 0) {
            // Carries nothing — it holds the capsule's top edge where the answer
            // card's header will land, and the window is transparent, so an empty
            // band shows nothing at all.
            Color.clear
                .frame(height: CompactShortcutMetrics.band)
            compactBox
                .padding(.top, CompactShortcutMetrics.gap)
            // Under the box: what this window is working on, said once.
            // Centred under the box: hanging off the leading edge it read as a
            // label attached to the corner, while the capsule above it is a
            // full-width object — the footnote belongs on that object's axis.
            HStack(spacing: 8) {
                if !state.compactSourceText.isEmpty {
                    CompactShortcutContextBadge {
                        withAnimation(.easeOut(duration: 0.18)) {
                            state.compactSourceText = ""
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9))
                        .animation(.easeOut(duration: 0.12)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: CompactShortcutMetrics.band)
            .padding(.top, CompactShortcutMetrics.gap)
            // The badge settles out from behind the box a beat later, so the
            // one move has a direction: the box opens, the context follows it.
            .opacity(entered ? 1 : 0)
            .offset(y: entered ? 0 : -7)
            .animation(reduceMotion ? nil
                       : .spring(response: 0.3, dampingFraction: 0.86)
                           .delay(entered ? 0.05 : 0),
                       value: entered)
        }
        .padding(CompactShortcutMetrics.inset)
        // The space the caret reports its position in: this view fills the window's
        // content, so an offset measured here is an offset from the window's corner
        // (`CompactShortcutMetrics.caretOffset`).
        .coordinateSpace(.named(CompactShortcutMetrics.faceSpace))
        // The whole face swells out of the corner the pointer summoned it from —
        // one continuous move, in the same breath as the window's own fade
        // (`DetachedSessionWindowController.playPointerEntrance`).
        .scaleEffect(entered || state.grownIn ? 1 : 0.92, anchor: state.entranceAnchor)
        .opacity(entered || state.grownIn ? 1 : 0)
        .offset(y: entered || state.grownIn ? 0 : -4)
        // Leaving. Only the shape moves here — the fade belongs to the window,
        // whose alpha takes the shadow with it (`fadeOutAndClose`); fading the
        // content too would multiply the two and cut the retreat in half.
        .scaleEffect(state.exiting ? 0.93 : 1, anchor: state.entranceAnchor)
        .animation(reduceMotion ? nil : .easeIn(duration: 0.24), value: state.exiting)
        .onAppear { playEntrance() }
        .onChange(of: state.entranceToken) { _, _ in playEntrance() }
    }

    /// Collapse the face to its seed and let it spring open. The collapsed state
    /// has to be drawn once before the spring, or a replay (same window, new
    /// pointer) would animate from the size it is already at — i.e. not at all.
    private func playEntrance() {
        guard !reduceMotion else { entered = true; return }
        entered = false
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                entered = true
            }
        }
    }

    /// The composer face's lower half: the instruction capsule. (The answer it
    /// becomes is no longer a box inside this frame — it is the window's own
    /// slab, see `compactShortcutFace`.)
    private var compactBox: some View { sessionBody }

    private func slab(corner: CGFloat) -> some View {
        ZStack {
            if !isBareComposer {
                DetachedWindowGlass()
                // Bare glass IS the window: pressing it moves the window, the
                // way pressing a titlebar does (see `WindowDragArea`). It lies
                // under everything, so the header chips, the thread and the
                // follow-up line keep their own clicks — this catches only the
                // presses none of them wanted.
                WindowDragArea()
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
            if !isBareComposer {
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
                onSubmit: onCompactPrompt,
                onDesiredHeight: onThreadHeight,
                onCaretOffset: onCaretOffset)
                .id(state.compactPromptGeneration)
        } else if state.session == .compose {
            DetachedComposeView(state: state, model: model, pinned: state.pinned,
                                onTogglePin: onTogglePin, onReattach: onReattach,
                                onClose: onClose, onSubmit: onCompose,
                                onDesiredHeight: onComposeHeight)
        } else if let taskID = state.session.taskID {
            DetachedAgentTaskView(taskID: taskID, pinned: state.pinned,
                                  onTogglePin: onTogglePin, onReattach: onReattach,
                                  onClose: onClose)
        } else if let threadStore = state.threadStore {
            DetachedThreadView(store: threadStore, pinned: state.pinned,
                               onTogglePin: onTogglePin, onReattach: onReattach,
                               onClose: onClose,
                               onInAppCopy: onInAppCopy,
                               onReplaceOriginal: onReplaceOriginal,
                               onFollowUp: onFollowUp,
                               onRegenerate: onRegenerate,
                               onRegenerateWith: onRegenerateWith,
                               regenerateOptions: regenerateOptions,
                               compactShortcut: compactShortcut,
                               onDesiredHeight: onThreadHeight)
        }
    }
}

/// The window header's leading control — the close ×. The window is
/// borderless, so AppKit gives it no titlebar buttons; this is wired to the
/// same close path as the ⌘W equivalent.
///
/// It used to host AppKit's *standard* red traffic light, the loudest pixel in
/// a header that is otherwise all quiet glass — and the one control here
/// speaking a different language than everything around it. It's now the same
/// species as `WindowTrailingCluster` on the other end: one glass segment,
/// same 26pt chip, same 11pt semibold glyph, so the two ends of the header
/// balance instead of clashing.
private struct WindowCloseButton: View {
    var close: () -> Void

    var body: some View {
        GlassSegmentCluster(segments: [
            .init(tooltip: L("detached.close"), action: close) {
                Image(systemName: "xmark")
                    .font(.sf(11, weight: .semibold))
            }
        ], showsTooltips: false)
    }
}

/// The window header's trailing control — reattach + pin in one glass capsule,
/// the same species as the panel's `ResultTrailingCluster`, so the torn-out
/// session keeps the chrome language it left with. Pin here means "float above
/// other windows" (on by default for a fresh tear-off). Close lives apart, on
/// the leading edge (see `WindowCloseButton`).
private struct WindowTrailingCluster: View {
    var pinned: Bool
    var togglePin: () -> Void
    var reattach: () -> Void

    var body: some View {
        GlassSegmentCluster(segments: [
            .init(tooltip: L("detached.continueInNotch.help"), action: reattach) {
                Image(systemName: "arrow.up.forward.and.arrow.down.backward")
                    .font(.sf(11, weight: .semibold))
            },
            .init(engaged: pinned,
                  tooltip: shortcutHelp(pinned ? "result.unpin" : "result.pin",
                                        action: .pin),
                  action: togglePin) {
                Image(systemName: "pin")
                    .font(.sf(12.5, weight: .semibold))
                    .rotationEffect(.degrees(pinned ? 0 : 32))
                    .animation(.easeOut(duration: 0.18), value: pinned)
            },
        ])
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
    /// The context badge's band under the capsule, and the gap over it.
    static var footer: CGFloat { gap + band }
    /// What an ANSWER window carries around its scrolling thread: the margin on
    /// both sides, the header, and the follow-up line under it — the same pieces
    /// a full session window carries, because it now IS one. The card's own
    /// top/bottom padding is added by the caller (`DetachedThreadView`).
    static var answerChrome: CGFloat {
        inset * 2 + DetachedThreadView.headerHeight
            + DetachedThreadView.compactFollowUpGap + DetachedThreadView.followUpHeight
    }

    // MARK: Where the caret lands
    //
    // The composer is placed by its text cursor, not by its corner: a force
    // click puts the caret exactly under the pointer
    // (`DetachedSessionWindowController.compactRect`). These are the offsets that
    // buys, and `ForceClickHerald` draws against the same numbers so the pressure
    // cue and the capsule it becomes occupy one spot.

    /// The capsule's own leading padding — box edge to the first glyph's cell.
    static let capsuleLeading: CGFloat = 18

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
        return CGPoint(x: inset + capsuleLeading + PromptField.textInset,
                       y: inset + band + gap + NotchBody.idleRowHeight / 2)
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

/// "Using copied text": what this window is working on, said once, on the band
/// under the capsule. Hovering it reveals an × that drops the captured selection —
/// the instruction then runs on its own, as a plain question — for when the
/// shortcut caught the wrong thing, or nothing worth carrying. At rest the badge
/// is a statement, not a control: the × only appears under the pointer, so the
/// resting window still reads as one line of context over one line of input.
private struct CompactShortcutContextBadge: View {
    var dismiss: () -> Void

    @State private var hovering = false
    @State private var hoveringDrop = false

    var body: some View {
        HStack(spacing: hovering ? 4 : 0) {
            Text(L("shortcuts.promptAction.window.context"))
                .font(.sf(11.5, weight: .medium))
                .foregroundStyle(Tokens.text3)
                .lineLimit(1)
            if hovering {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.sf(8.5, weight: .bold))
                        .foregroundStyle(hoveringDrop ? Tokens.text1 : Tokens.text4)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(.white.opacity(hoveringDrop ? 0.14 : 0)))
                        .contentShape(Circle())
                }
                .buttonStyle(GlassPressStyle())
                .onHover { hoveringDrop = $0 }
                .accessibilityLabel(L("shortcuts.promptAction.window.context.drop"))
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, hovering ? 6 : 10)
        .frame(height: 22)
        .background(CompactComposerGlass(shape: Capsule()))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.16)) { hovering = inside }
            if !inside { hoveringDrop = false }
        }
        .animation(.easeOut(duration: 0.15), value: hoveringDrop)
    }
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

/// The composer capsule's single trailing slot: the panel's own `SendButton`,
/// arriving with the first character — the identical control the idle prompt and
/// every follow-up row send with, so the arrow here is the app's send arrow, not
/// a second vocabulary. The slot holds its width empty-handed, so the arrow's
/// arrival never nudges the field. (The pin used to live here; it moved up to
/// the band's action pill, where it stays put across the ask.)
private struct CompactShortcutTrailingControl: View {
    var hasText: Bool
    var send: () -> Void

    /// The send button's footprint, held whether or not it's showing.
    private static let slot: CGFloat = 32

    var body: some View {
        ZStack {
            if hasText {
                SendButton(compact: true, action: send)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(width: Self.slot, height: Self.slot)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hasText)
    }
}

/// The same smoked glass the window slab wears (`DetachedWindowGlass`), cut to
/// an arbitrary shape. The bare composer has no slab to sit on, so its badge
/// and its input capsule each carry this themselves and still read as pieces of
/// the island rather than two foreign chips.
struct CompactComposerGlass<S: InsettableShape>: View {
    var shape: S

    var body: some View {
        Color.clear
            .nativeGlass(in: shape)
            .overlay(shape.fill(Color.black.opacity(0.30)))
            .allowsHitTesting(false)
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

/// The window's grab surface — its titlebar, in a window that has no titlebar.
///
/// A borderless window moves by `isMovableByWindowBackground`, and that only
/// fires when a mouse-down reaches the window itself unclaimed. In this card
/// almost nothing does: the answer is AppKit-backed selectable text
/// (`SelectionTextField`) and the follow-up line is a text view, and BOTH
/// answer `mouseDownCanMoveWindow = false` — so a press anywhere on the
/// answer, which is nearly the whole card, starts a text selection and the
/// window stays exactly where it was. Grabbing the card and moving it simply
/// did nothing.
///
/// This view is the explicit alternative, laid behind the content: whatever
/// SwiftUI would have done with the press, a press that lands on bare glass
/// drags the window. Content on top of it — the chips, the thread, the input —
/// still gets its own clicks; this only ever sees what nothing else claimed.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        /// The card is summoned beside the pointer while another app is
        /// frontmost, so the very first press on it is often the activating
        /// click — it has to move the window too, not be eaten by activation.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Empty prompt-shortcut window

/// A selected-text shortcut with no saved instruction. The selection is already
/// held by the controller; this face deliberately exposes only that fact and a
/// focused instruction field. Sending promotes the same shell into the compact
/// streaming result view.
///
/// It is the one face with no window slab behind it: the input is a single
/// full-rounded capsule — field plus one trailing control, nothing else on the
/// line. The band above it (the "Using copied text" badge and the pin) belongs
/// to the root view, which carries it unchanged into the answer face — this view
/// is ONLY the box, so asking grows that box in place and moves nothing else
/// (see `DetachedSessionRootView.compactShortcutFace`).
private struct CompactShortcutPromptView: View {
    @ObservedObject var state: DetachedWindowState
    var onSubmit: (String) -> Void
    var onDesiredHeight: (CGFloat) -> Void = { _ in }
    /// Where this face's text cursor actually landed, in the window's own
    /// coordinates. The window is placed by it (`alignCaret`).
    var onCaretOffset: (CGPoint) -> Void = { _ in }

    @State private var focused = false
    @State private var caretWidth: CGFloat = 0
    @State private var inputHeight: CGFloat = PromptField.lineHeight(for: NotchBody.idleFontSize)

    /// The window's height with a one-line prompt: the band's chrome, one capsule
    /// row, and the badge's own band under it (the same slot the answer's action
    /// pill lands in). A wrapped draft grows it from here.
    static let restingHeight: CGFloat =
        CompactShortcutMetrics.chrome + NotchBody.idleRowHeight
            + CompactShortcutMetrics.footer


    private var trimmed: String {
        state.compactPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The capsule's height — one line at rest, growing with a wrapping draft.
    private var rowHeight: CGFloat {
        max(NotchBody.idleRowHeight,
            inputHeight + NotchBody.idleRowHeight
              - PromptField.lineHeight(for: NotchBody.idleFontSize))
    }

    private var desiredHeight: CGFloat {
        CompactShortcutMetrics.chrome + rowHeight + CompactShortcutMetrics.footer
    }

    var body: some View {
        inputCapsule
            .onAppear {
                onDesiredHeight(desiredHeight)
                focused = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { focused = true }
            }
            .onChange(of: desiredHeight) { _, height in onDesiredHeight(height) }
    }

    /// The box itself: one full-rounded row — the field, then the send slot. At
    /// its resting one-line height the corner radius makes it a true pill; a
    /// wrapped draft keeps the same corners on a taller box, and so does the
    /// answer card it becomes.
    private var inputCapsule: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                PromptField(
                    text: $state.compactPromptDraft,
                    placeholder: "",
                    fontSize: NotchBody.idleFontSize,
                    focusTrigger: focused,
                    maxVisibleLines: NotchBody.promptMaxLines,
                    onSubmit: send,
                    onTab: { true },
                    onCaretWidth: { caretWidth = $0 },
                    onHeightChange: { inputHeight = $0 }
                )
                .frame(height: inputHeight)

                if state.compactPromptDraft.isEmpty && caretWidth == 0 {
                    // "What should I do with it?" only means something when there IS
                    // an "it". Pressed on nothing (or with the context dropped), this
                    // is the ordinary prompt and says what the notch's own box says.
                    Text(L(state.compactSourceText.isEmpty
                           ? "input.placeholder"
                           : "shortcuts.promptAction.window.placeholder"))
                        .font(.sf(NotchBody.idleFontSize))
                        .foregroundStyle(Tokens.placeholder)
                        .lineLimit(1)
                        .padding(.leading, PromptField.textInset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .background(CaretProbe(report: onCaretOffset))
            .animation(.easeOut(duration: 0.16), value: caretWidth == 0)
            .animation(.easeOut(duration: 0.16), value: state.compactPromptDraft.isEmpty)

            CompactShortcutTrailingControl(hasText: !trimmed.isEmpty, send: send)
        }
        // While a force click is still being decided the capsule is drawn as its own
        // cap, and a field laid out inside a 48pt circle is neither useful nor
        // cheap — the glass is the whole cue. The field keeps its full-width layout
        // underneath (it is the glass that is narrow, see `capsuleGlass`), so the
        // stretch never re-wraps a line of text.
        .opacity(state.pressDepth == nil ? 1 : 0)
        .padding(.leading, CompactShortcutMetrics.capsuleLeading)
        .padding(.trailing, 8)
        .frame(height: rowHeight)
        .background(capsuleGlass)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: inputHeight)
    }

    private var capsuleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: min(rowHeight / 2, CompactShortcutMetrics.corner),
                         style: .continuous)
    }

    /// The capsule's glass — and, while a force click is still being decided, the
    /// only thing this window draws at all.
    ///
    /// One view for both jobs is the point. The press narrows this glass to the
    /// capsule's own left cap and deepens its fill; firing springs it back to full
    /// width (`DetachedSessionWindowController.openFromPressure`). Because it is the
    /// same surface throughout, the moment the press becomes a composer has nothing
    /// to cross-fade — which is what the old cue-panel-plus-window pair could never
    /// manage, glass over glass being far darker than glass.
    private var capsuleGlass: some View {
        let pressing = state.pressDepth != nil
        let depth = state.pressDepth ?? 1
        return CompactComposerGlass(shape: capsuleShape)
            // The fill deepens with the press and is fully there by the time the
            // stretch begins, so the shape stops changing character mid-flight.
            .overlay(capsuleShape.fill(Color.black.opacity(0.34 * (1 - depth))))
            // A rim while it is a cue — the pointer thickening into an object —
            // easing to the composer's own bare capsule as it opens.
            .overlay(capsuleShape.strokeBorder(
                Color.white.opacity(pressing ? 0.16 + 0.16 * depth : 0), lineWidth: 1))
            .frame(width: pressing ? CompactShortcutMetrics.capDiameter : nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
    }

    private func send() {
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
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
    var onReattach: () -> Void
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
            WindowCloseButton(close: onClose)
            Spacer(minLength: 0)
            WindowTrailingCluster(pinned: pinned, togglePin: onTogglePin,
                                  reattach: onReattach)
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
    var onReattach: () -> Void
    var onClose: () -> Void
    var onInAppCopy: () -> Void
    var onReplaceOriginal: (String) -> Bool
    var onFollowUp: (String) -> Void
    var onRegenerate: () -> Void
    var onRegenerateWith: (String) -> Void
    var regenerateOptions: () -> [(model: String, isCurrent: Bool)]
    var compactShortcut = false
    var onDesiredHeight: (CGFloat) -> Void = { _ in }

    @State private var followUp = ""
    @State private var hoveredSourceID: UUID?
    @State private var sourceCloseWork: DispatchWorkItem?

    private static let bottomID = "detached-thread-bottom"

    private var streaming: Bool { store.turns.contains { $0.streaming } }
    private var renderedTurns: [NotchModel.Turn] {
        store.turns.filter { !$0.hidesUserBubble }
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
    /// The compact card keeps the panel's 18pt quiet gap above the thread, but
    /// leaves no reserved space below it or above the follow-up line. The
    /// pointer-side window needs the densest possible bottom edge; ordinary
    /// detached windows still use `ThreadScroll.runway` and `followUpGap`.
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
    /// The header pill's height (`GlassSegmentCluster` — a 26pt chip in 3pt of
    /// glass) and the follow-up row's, so the compact window can budget for the
    /// chrome it now carries (`CompactShortcutMetrics.answerChrome`).
    static let headerHeight: CGFloat = 32
    static let compactFollowUpGap: CGFloat = 0
    static let followUpGap: CGFloat = 8
    static let followUpHeight: CGFloat = 39
    /// The fade and frost bands are exactly the gaps the thread rests between —
    /// never deeper — so a card at rest is crisp edge to edge and only content
    /// that has actually travelled into a gap gets dissolved.
    private var topFade: CGFloat { scrollTopInset }
    private var bottomFade: CGFloat { scrollBottomInset }
    private var topBand: CGFloat { min(ThreadScroll.band, scrollTopInset) }
    private var bottomBand: CGFloat { min(ThreadScroll.band, scrollBottomInset) }


    /// The window height a compact card wants for a turn stack this tall — the
    /// one place that arithmetic lives, so the height the window is set to and
    /// the layout inside it can never disagree.
    private func compactWindowHeight(forContentHeight bare: CGFloat) -> CGFloat {
        bare + scrollTopInset + scrollBottomInset
            + Self.cardTopPadding + Self.cardBottomPadding
            + CompactShortcutMetrics.answerChrome
    }
    private var latestAnswerText: String {
        renderedTurns.last(where: { $0.role == "assistant" })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private var streamingAnswer: NotchModel.Turn? {
        store.turns.last(where: { $0.role == "assistant" && $0.streaming })
    }
    private var activeTaskStyle: (word: String, orb: OrbState)? {
        guard let answer = streamingAnswer,
              let answerIndex = store.turns.firstIndex(where: { $0.id == answer.id })
        else { return nil }
        let question = store.turns[..<answerIndex].last(where: { $0.role == "user" })?.text ?? ""
        return NotchModel.taskStyle(for: question)
    }
    private var activeTaskWord: String? { activeTaskStyle?.word }
    private var activeTaskOrb: OrbState { activeTaskStyle?.orb ?? .composing }
    // The panel body's exact rhythm (NotchBody: a uniform 15pt inset, header then
    // an 18pt quiet gap, turns at 14pt spacing) — so the first frame after the
    // tear lays out where the panel's last frame did, and the question bubble is
    // the title; the header carries no text of its own.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
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
            }
            // Every detached thread can be continued where it stands — a
            // pointer-side answer no longer dead-ends at "copy it or close it".
            followUpRow
                .padding(.top, compactShortcut ? Self.compactFollowUpGap
                                               : Self.followUpGap)
        }
        .padding(.horizontal, Self.cardHorizontalPadding)
        .padding(.top, Self.cardTopPadding)
        .padding(.bottom, Self.cardBottomPadding)
        .onPreferenceChange(DetachedThreadContentHeightKey.self) { measured in
            guard compactShortcut, measured > 0 else { return }
            // A wait is not a reason to move a window: the waiting card opens
            // once, to its own floor (`compactInitialHeight`), and only the
            // answer grows it past that (`compactFloorHeight`).
            guard !latestAnswerText.isEmpty else { return }
            // The turn stack, the gaps it rests between, the card's own padding,
            // and the window chrome an answered shortcut carries — the margins,
            // the header and the follow-up row.
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
    }

    /// The answer has outgrown the window's ceiling — past here the window stops
    /// opening and the ScrollView takes over, which is the only point at which a
    /// compact answer needs its tail followed.
    private var compactAnswerIsCapped: Bool {
        estimatedCompactWindowHeight(for: latestAnswerText)
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
        return compactWindowHeight(forContentHeight: ceil(bounds.height))
    }

    /// The width the answer's prose actually wraps at: the compact window, less
    /// the face's margins and the card's own horizontal padding.
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
        ComposerBox(
            text: $followUp,
            onSubmit: sendFollowUp,
            placeholder: { Text(L("result.followUp")) },
            trailing: {
                if !followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    SendButton(compact: true, action: sendFollowUp)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            })
        .opacity(streaming ? 0.45 : 1)
        .disabled(streaming)
    }

    private func sendFollowUp() {
        let line = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !streaming else { return }
        followUp = ""
        onFollowUp(line)
    }

    /// One header for every detached thread, pointer-side shortcut answers
    /// included: close on the leading edge, the window's own actions (continue
    /// in the notch, pin) in one glass capsule on the trailing edge. Content
    /// actions — copy, plain copy, regenerate, ⓘ — never live here; they belong
    /// to the answer and ride its footer (`AssistantTurnView`). The compact face
    /// used to float a copy+pin pill outside the card instead, which put the
    /// same copy button in two different places in two windows.
    private var header: some View {
        HStack(spacing: 10) {
            WindowCloseButton(close: onClose)
            Spacer(minLength: 0)
            WindowTrailingCluster(pinned: pinned, togglePin: onTogglePin,
                                  reattach: onReattach)
        }
    }

    private func replaceLatestAnswer() -> Bool {
        let answer = latestAnswerText
        guard !answer.isEmpty else { return false }
        return onReplaceOriginal(answer)
    }

    @ViewBuilder
    private func turnView(_ turn: NotchModel.Turn) -> some View {
        if turn.role == "user" {
            UserQuestionBubble(text: turn.text)
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
    /// thread keeps every action the panel offers. Regenerate only on the last
    /// settled answer, same gate as the panel.
    private func assistantTurn(_ turn: NotchModel.Turn) -> some View {
        let canRegenerate = store.turns.last?.id == turn.id && !turn.isAgent
            && !streaming
        return AssistantTurnView(
            text: turn.text,
            streaming: turn.streaming,
            activity: turn.toolActivity,
            orbState: activeTaskOrb,
            thinkingWord: turn.streaming ? (activeTaskWord ?? L("busy.thinking"))
                                         : L("busy.thinking"),
            sources: turn.sources,
            hoveredSourceID: $hoveredSourceID,
            sourceCloseWork: $sourceCloseWork,
            isAgent: turn.isAgent,
            // Compact shortcut answers carry the footer too now — copy lives
            // with the answer in every window, not on a pill beside one of them.
            showsFooter: true,
            onInAppCopy: onInAppCopy,
            onRegenerate: canRegenerate ? onRegenerate : nil,
            regenerateModels: canRegenerate ? regenerateOptions() : [],
            onRegenerateWith: canRegenerate ? onRegenerateWith : nil,
            regenModel: turn.regenModel,
            answerModel: turn.answerModel
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
    var onReattach: () -> Void
    var onClose: () -> Void

    @ObservedObject private var manager = AgentTaskManager.shared
    @State private var followUp = ""
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
            followUpRow(task)
                .padding(.top, 8)
        }
        .padding(.horizontal, DetachedThreadView.cardHorizontalPadding)
        .padding(.top, DetachedThreadView.cardTopPadding)
        .padding(.bottom, DetachedThreadView.cardBottomPadding)
    }

    private func header(_ task: AgentTaskManager.AgentTask) -> some View {
        HStack(spacing: 10) {
            WindowCloseButton(close: onClose)
            AgentStatusDot(running: task.isRunning, outcome: task.outcome)
            Text("\(task.engine.displayName) · \(task.folder.lastPathComponent)")
                .font(.sf(14, weight: .medium))
                .foregroundStyle(Tokens.text2)
                .lineLimit(1)
            Spacer(minLength: 0)
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
                                  reattach: onReattach)
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
            onCommandSubmit: {
                guard task.isRunning, task.sessionID != nil,
                      !followUp.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty
                else { return false }
                sendFollowUp(task, interrupting: true)
                return true
            },
            placeholder: {
                Text(L(task.isRunning ? "agent.followUp.queue"
                                      : "agent.followUp.placeholder"))
            },
            trailing: {
                if !followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
        let line = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        followUp = ""
        // Sending says you want to watch what happens next.
        followsTail = true
        if interrupting {
            manager.interrupt(taskID: task.id, prompt: line)
        } else {
            manager.followUp(taskID: task.id, prompt: line)
        }
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
