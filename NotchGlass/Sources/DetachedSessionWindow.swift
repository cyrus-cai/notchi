import AppKit
import SwiftUI

// MARK: - What a detached window holds

/// One session torn out of the notch into its own window: either a chat thread
/// (Ask, or a reopened agent-run thread) identified by its history id, or a live
/// agent task identified by its `AgentTaskManager` id.
enum DetachedSession: Equatable {
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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// LSUIElement app: there is no menu-bar Close item to catch ⌘W, so the
    /// window answers the equivalent itself — same path as the close chip.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
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

    let session: DetachedSession
    private let face: DetachedCardFace
    private weak var model: NotchModel?
    private var window: NSWindow!
    private let state = DetachedWindowState()
    private var threadStore: DetachedThreadStore?

    /// Mid-drag machinery (tear-off path only).
    private var dragMonitor: Any?
    private var grabOffset = NSPoint.zero          // mouse → window-origin delta, keeps the grip point
    private var lastMouse = NSPoint.zero
    private var lastMouseAt: TimeInterval = 0

    /// Merge-back machinery (settled phase).
    private var moveObserver: NSObjectProtocol?
    private var mergeArmed = false

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
        c.makeWindow(at: spawnRect ?? c.centeredDefaultRect())
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
        c.makeWindow(at: spawnRect)
        c.beginRide()
    }

    private init(session: DetachedSession, face: DetachedCardFace, model: NotchModel) {
        self.session = session
        self.face = face
        self.model = model
        super.init()
        if let threadID = session.threadID {
            let store = model.adoptDetachedThread(threadID)
            self.threadStore = store
        }
    }

    // MARK: Window construction

    private func makeWindow(at rect: NSRect) {
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
        w.minSize = NSSize(width: 420, height: 320)
        // While being carried it floats above everything, like a piece of the
        // island in the hand. `finishSettle` drops it to its pinned level.
        w.level = .statusBar

        // Thread actions read the store's threadID at CALL time (not capture
        // time): a regenerate can re-id the thread, and the store's key is
        // kept current by the model (`runDetachedRound`).
        let root = DetachedSessionRootView(
            state: state,
            session: session,
            threadStore: threadStore,
            onReattach: { [weak self] in self?.mergeBack(animated: true) },
            onTogglePin: { [weak self] in self?.togglePin() },
            onClose: { [weak self] in self?.window.close() },
            onInAppCopy: { [weak self] in
                self?.model?.rebaselineClipboardAfterInAppWrite()
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
            })
            .environmentObject(Localization.shared)
            // This window's own edges are the wall its hover tooltips clamp to —
            // the island's coordinate space doesn't reach here.
            .coordinateSpace(.named(TooltipCoordinateSpace.clipBox))
        w.contentView = NSHostingView(rootView: root)
        w.delegate = self
        window = w
        w.orderFrontRegardless()
    }

    private func centeredDefaultRect() -> NSRect {
        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        return NSRect(x: screen.midX - 320, y: screen.midY - 280,
                      width: 640, height: 560)
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

    func windowWillClose(_ notification: Notification) {
        endRide()
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
}

/// Root view: the glass slab, wearing the tear-off card while riding the drag
/// and crossfading into the full session view on landing.
struct DetachedSessionRootView: View {
    @ObservedObject var state: DetachedWindowState
    let session: DetachedSession
    let threadStore: DetachedThreadStore?
    var onReattach: () -> Void
    var onTogglePin: () -> Void
    var onClose: () -> Void
    // Thread-window actions (unused by the agent-task face, which talks to
    // `AgentTaskManager` directly).
    var onInAppCopy: () -> Void = {}
    var onFollowUp: (String) -> Void = { _ in }
    var onRegenerate: () -> Void = {}
    var onRegenerateWith: (String) -> Void = { _ in }
    var regenerateOptions: () -> [(model: String, isCurrent: Bool)] = { [] }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The window's own silhouette — the glass draws it (the window is
    /// borderless), continuous-rounded like the island's bottom corners.
    static let cornerRadius: CGFloat = 16

    var body: some View {
        ZStack {
            DetachedWindowGlass()
            // The full session from frame one — riding and settled look the
            // same; merging just dissolves on the way home.
            sessionBody
                .opacity(state.phase == .merging ? 0 : 1)
        }
        // The glass carves the window's rounded form itself; the rim rides on
        // top of the clipped result so the edge highlight stays crisp.
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Tokens.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .rotationEffect(.degrees(state.tilt), anchor: .top)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.62), value: state.tilt)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: state.phase)
    }

    @ViewBuilder
    private var sessionBody: some View {
        if let taskID = session.taskID {
            DetachedAgentTaskView(taskID: taskID, pinned: state.pinned,
                                  onTogglePin: onTogglePin, onReattach: onReattach,
                                  onClose: onClose)
        } else if let threadStore {
            DetachedThreadView(store: threadStore, pinned: state.pinned,
                               onTogglePin: onTogglePin, onReattach: onReattach,
                               onClose: onClose,
                               onInAppCopy: onInAppCopy,
                               onFollowUp: onFollowUp,
                               onRegenerate: onRegenerate,
                               onRegenerateWith: onRegenerateWith,
                               regenerateOptions: regenerateOptions)
        }
    }
}

/// The window header's leading control — the NATIVE red traffic light on the
/// top-left. The window is borderless, so AppKit gives it no titlebar buttons;
/// a standalone standard close button is hosted here instead and wired to the
/// same close path as the ⌘W equivalent. The fixed frames matter: without
/// them SwiftUI treats the representable as flexible and lets it swallow the
/// whole header (the light is ~14×16pt; the outer 26pt square keeps the
/// header's chip rhythm).
private struct WindowCloseButton: View {
    var close: () -> Void

    var body: some View {
        TrafficLightClose(close: close)
            .frame(width: 14, height: 16)
            .frame(width: 26, height: 26)
    }
}

private struct TrafficLightClose: NSViewRepresentable {
    var close: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(close: close) }

    func makeNSView(context: Context) -> TrafficLightHostView {
        let host = TrafficLightHostView()
        if let button = NSWindow.standardWindowButton(.closeButton,
                                                      for: [.titled, .closable]) {
            button.target = context.coordinator
            button.action = #selector(Coordinator.fire)
            host.install(button)
        }
        return host
    }

    func updateNSView(_ view: TrafficLightHostView, context: Context) {
        context.coordinator.close = close
    }

    @MainActor final class Coordinator: NSObject {
        var close: () -> Void
        init(close: @escaping () -> Void) { self.close = close }
        @objc func fire() { close() }
    }
}

/// Hosts the standalone traffic light and answers AppKit's `_mouseInGroup:`
/// from its own hover tracking — that's what lights the × glyph inside the
/// red disc on hover, exactly as in a real titlebar (a lone standard button
/// has no titlebar group to ask, so without this the glyph never appears).
private final class TrafficLightHostView: NSView {
    private var hovering = false
    private weak var button: NSButton?

    func install(_ button: NSButton) {
        self.button = button
        addSubview(button)
        setFrameSize(button.frame.size)
    }

    override var intrinsicContentSize: NSSize { button?.frame.size ?? .zero }

    /// Whatever size SwiftUI settles on, the light itself sits dead center.
    override func layout() {
        super.layout()
        guard let button else { return }
        button.setFrameOrigin(NSPoint(x: (bounds.width - button.frame.width) / 2,
                                      y: (bounds.height - button.frame.height) / 2))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        button?.needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        button?.needsDisplay = true
    }

    @objc private func _mouseInGroup(_ button: NSButton) -> Bool { hovering }
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
                  tooltip: L(pinned ? "result.unpin" : "result.pin"),
                  action: togglePin) {
                Image(systemName: "pin")
                    .font(.sf(12.5, weight: .semibold))
                    .rotationEffect(.degrees(pinned ? 0 : 32))
            },
        ])
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
    var onFollowUp: (String) -> Void
    var onRegenerate: () -> Void
    var onRegenerateWith: (String) -> Void
    var regenerateOptions: () -> [(model: String, isCurrent: Bool)]

    @State private var followUp = ""
    @State private var hoveredSourceID: UUID?
    @State private var sourceCloseWork: DispatchWorkItem?

    private static let bottomID = "detached-thread-bottom"

    private var streaming: Bool { store.turns.contains { $0.streaming } }

    // The panel body's exact rhythm (NotchBody: horizontal 20 / top 15, header
    // then an 18pt quiet gap, turns at 14pt spacing) — so the first frame after
    // the tear lays out where the panel's last frame did, and the question
    // bubble is the title; the header carries no text of its own.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(store.turns) { turn in
                            turnView(turn)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    // Runways: rows rest between the header and the follow-up
                    // line, then scroll into these empty bands — up behind the
                    // header, down behind the input — to fade + frost out on
                    // both edges (see ThreadScroll).
                    .padding(.top, ThreadScroll.runway)
                    .padding(.bottom, ThreadScroll.runway)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollEdgeFade(top: true, bottom: true, fade: ThreadScroll.runway)
                .progressiveTopBlur(height: ThreadScroll.band, maxRadius: ThreadScroll.blurRadius)
                .progressiveBottomBlur(height: ThreadScroll.band, maxRadius: ThreadScroll.blurRadius)
                .onChange(of: store.turns.last?.text.count ?? 0) { _, _ in
                    guard streaming else { return }
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            followUpRow
                .padding(.top, 8)
        }
        .padding(.horizontal, 20)
        .padding(.top, 15)
        .padding(.bottom, 14)
    }

    /// The same follow-up line the panel's result view carries — a submit here
    /// runs the round through the panel pipeline, headless (see
    /// `NotchModel.submitDetachedFollowUp`), and streams back into this window.
    /// Disabled while a round streams: the tear-off dropped the round's task
    /// handle, so a mid-stream line couldn't supersede it.
    private var followUpRow: some View {
        // Same composer the panel carries, down to the type size, the recessed
        // surface and the glass `SendButton` — a torn-off session is the same
        // conversation in a bigger frame, so its input can't be a different
        // control. (It used to be a bare `arrow.up.circle.fill` with no hover,
        // no press-give and no entrance, over a flat 1pt-rimmed box.)
        HStack(spacing: 10) {
            TextField(L("result.followUp"), text: $followUp)
                .textFieldStyle(.plain)
                .font(.sf(NotchBody.followUpFontSize))
                .foregroundStyle(Tokens.text1)
                .onSubmit(sendFollowUp)
            if !followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SendButton(compact: true, action: sendFollowUp)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(minHeight: 27)
        .padding(.leading, 13)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .recessedSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                         lit: false)
        .animation(.spring(response: 0.3, dampingFraction: 0.7),
                   value: followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .opacity(streaming ? 0.45 : 1)
        .disabled(streaming)
    }

    private func sendFollowUp() {
        let line = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !streaming else { return }
        followUp = ""
        onFollowUp(line)
    }

    private var header: some View {
        HStack(spacing: 10) {
            WindowCloseButton(close: onClose)
            if streaming {
                CrossfadeText(text: L("busy.writing"), font: 12, color: Tokens.text4)
            }
            Spacer(minLength: 0)
            WindowTrailingCluster(pinned: pinned, togglePin: onTogglePin,
                                  reattach: onReattach)
        }
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
            thinkingWord: L("busy.thinking"),
            sources: turn.sources,
            hoveredSourceID: $hoveredSourceID,
            sourceCloseWork: $sourceCloseWork,
            isAgent: turn.isAgent,
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

    private static let bottomID = "detached-agent-bottom"

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

    // Same rhythm as the panel's agent detail page (NotchBody: horizontal 20 /
    // top 15, header then the quiet gap), so the tear doesn't reflow the trail.
    private func content(_ task: AgentTaskManager.AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(task)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        UserQuestionBubble(text: task.prompt)
                        // Once settled, the trail's last narration entry is the report
                        // shown below — drop it so it isn't printed twice. While running
                        // no report shows, so the whole trail stands (empty answer = no
                        // strip). See `droppingTrailingAnswer`.
                        let settledAnswer = task.isRunning ? "" : (task.exchanges.last?.answer ?? "")
                        let trail = task.log.droppingTrailingAnswer(settledAnswer)
                        if !trail.isEmpty {
                            AgentWorkTrailView(entries: trail)
                        }
                        if task.isRunning {
                            CrossfadeText(text: task.activity ?? L("agent.thinking"),
                                          font: 14, color: Tokens.text3)
                                .tracking(-0.1)
                                .lineLimit(1)
                                .padding(.vertical, 2)
                        } else if let answer = task.exchanges.last?.answer, !answer.isEmpty {
                            MarkdownBlocks(source: answer, baseFont: 15)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    // Runways: the trail rests between the header and the
                    // follow-up line, then scrolls into these empty bands — up
                    // behind the header, down behind the input — to fade +
                    // frost out on both edges (see ThreadScroll).
                    .padding(.top, ThreadScroll.runway)
                    .padding(.bottom, ThreadScroll.runway)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollEdgeFade(top: true, bottom: true, fade: ThreadScroll.runway)
                .progressiveTopBlur(height: ThreadScroll.band, maxRadius: ThreadScroll.blurRadius)
                .progressiveBottomBlur(height: ThreadScroll.band, maxRadius: ThreadScroll.blurRadius)
                .onChange(of: task.log.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
                .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            followUpRow(task)
                .padding(.top, 8)
        }
        .padding(.horizontal, 20)
        .padding(.top, 15)
        .padding(.bottom, 14)
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

    private func followUpRow(_ task: AgentTaskManager.AgentTask) -> some View {
        // Mid-run the field stays live: Enter queues the line and the manager
        // dispatches it as the next round on settle — typed input is never
        // dropped. Only a run that settled without ever reporting a session id
        // (nothing to resume, ever) goes dead.
        let dead = !task.isRunning && task.sessionID == nil
        return HStack(spacing: 10) {
            TextField(L(task.isRunning ? "agent.followUp.queue"
                                       : "agent.followUp.placeholder"),
                      text: $followUp)
                .textFieldStyle(.plain)
                .font(.sf(NotchBody.followUpFontSize))
                .foregroundStyle(Tokens.text1)
                .onSubmit { sendFollowUp(task) }
            if !followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SendButton(compact: true) { sendFollowUp(task) }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(minHeight: 27)
        .padding(.leading, 13)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .recessedSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                         lit: false)
        .animation(.spring(response: 0.3, dampingFraction: 0.7),
                   value: followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .opacity(dead ? 0.45 : 1)
        .disabled(dead)
    }

    private func sendFollowUp(_ task: AgentTaskManager.AgentTask) {
        let line = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        followUp = ""
        manager.followUp(taskID: task.id, prompt: line)
    }
}

