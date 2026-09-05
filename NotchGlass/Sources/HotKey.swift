import AppKit
import ApplicationServices
import Carbon
import Darwin

/// A thin wrapper over Carbon's `RegisterEventHotKey` — a process-wide hot key
/// that fires even when the app isn't frontmost, with no Accessibility
/// permission required (unlike a CGEvent tap). Used for ⌘, → Settings, since
/// this accessory app has no menu bar to host the standard shortcut.
///
/// The handler is dispatched to the main actor. Hold a strong reference for as
/// long as the shortcut should stay live; deinit unregisters it.
final class HotKey {
    private var ref: EventHotKeyRef?

    // A unique id so the global Carbon dispatcher can route events to us.
    private static var nextID: UInt32 = 1
    private let id: UInt32
    /// id → what to run. Deliberately the *closure*, never the `HotKey` itself:
    /// a strong `[id: HotKey]` entry would keep every instance alive forever
    /// (nothing but `deinit` clears it, and `deinit` can't run while the table
    /// holds a reference), so `UnregisterEventHotKey` would never fire and a
    /// rebound chord would keep triggering its previous action for the whole
    /// session while the new one failed to register (`eventHotKeyExistsErr`).
    private static var actions: [UInt32: () -> Void] = [:]

    /// The process-wide Carbon dispatcher. Installed exactly once and never
    /// removed: Carbon refuses a duplicate (proc, target) install, so a
    /// per-instance handler would leave one arbitrary `HotKey` owning the only
    /// registration — and dropping *that* one would silently stop dispatching
    /// events for every other hot key still registered.
    private static var dispatcher: EventHandlerRef? = {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            if let action = HotKey.actions[hkID.id] {
                DispatchQueue.main.async { action() }
            }
            return noErr
        }, 1, &eventType, nil, &ref)
        return ref
    }()

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.id = HotKey.nextID
        HotKey.nextID += 1
        _ = HotKey.dispatcher

        let signature: OSType = 0x4E4F5443 // 'NOTC'
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode,
                                         modifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        guard status == noErr else { return nil }
        HotKey.actions[id] = action
    }

    /// Probe whether Carbon can claim a global chord (including conflicts with
    /// macOS and other apps). The temporary registration is released as soon as
    /// this function returns.
    static func isAvailable(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let probe = HotKey(keyCode: keyCode, modifiers: modifiers, action: {})
        return probe != nil
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.actions[id] = nil
    }
}

/// Whether the Shortcuts pane is currently listening for a chord.
///
/// Recording reads keys through a *local* `NSEvent` monitor, which is the last
/// link in the chain: a Carbon hot key swallows its chord system-wide before any
/// app ever sees a key event, and an earlier-installed local monitor that
/// consumes an event hides it from every monitor behind it. Without this flag the
/// recorder simply never observes the chords Notch itself owns — pressing one
/// fires the old shortcut instead of being recorded, which reads as "this key
/// can't be set".
///
/// While recording: `AppDelegate` drops every global registration, and the
/// in-app key handlers stand down so the recorder sees the raw key event.
enum ShortcutRecording {
    private(set) static var isActive = false

    static func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        NotificationCenter.default.post(name: .shortcutRecordingChanged, object: nil)
    }
}

/// Fires `action` when the user double-taps a *bare* modifier key (e.g. ⌥⌥),
/// the way Raycast/CleanShot summon on a double-tapped ⌘. Carbon's
/// `RegisterEventHotKey` can't represent a lone modifier, so this watches
/// `flagsChanged` through a global+local `NSEvent` monitor. It also observes
/// `keyDown` so a chord such as ⌘C invalidates the candidate tap instead of
/// masquerading as a bare ⌘ press.
///
/// A "tap" is the target modifier going down and back up with no *other*
/// modifier held at any point; two taps inside `window` seconds fire the action.
/// Hold a strong reference for as long as it should stay live; deinit removes
/// the monitors.
final class DoubleTapModifierMonitor {
    private let flag: NSEvent.ModifierFlags
    private let action: () -> Void
    private let window: TimeInterval
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Timestamp of the last completed tap (a down→up of the lone modifier),
    /// taken from the event's own `timestamp` so it's immune to dispatch jitter.
    private var lastTapTime: TimeInterval?
    /// Whether the target modifier is currently the only one held — set on the
    /// down edge, so the matching up edge knows the tap was "clean".
    private var pendingTap = false

    /// - Parameters:
    ///   - carbonModifier: the modifier to watch, as a Carbon mask (`optionKey`…).
    ///   - window: max seconds between the two taps (default 0.30 — Raycast-ish).
    init(carbonModifier: UInt32, window: TimeInterval = 0.30, action: @escaping () -> Void) {
        self.flag = DoubleTapModifierMonitor.cocoaFlag(forCarbon: carbonModifier)
        self.action = action
        self.window = window

        // Global monitor: catches taps while another app is frontmost. Local
        // monitor: catches them while our own (settings) window has focus —
        // global monitors don't see events delivered to our process.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
    }

    /// The four modifiers a double-tap cares about. Caps-lock and fn are
    /// deliberately excluded — otherwise an engaged Caps Lock would sit in every
    /// flag set and the "only the target is held" test could never be true.
    private static let watched: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    private func handle(_ event: NSEvent) {
        // A double-tap must consist of two *bare* modifier taps. Any ordinary key
        // between or during them dirties the whole sequence. In particular this
        // prevents habitual repeated ⌘C presses from firing the action.
        if event.type == .keyDown {
            pendingTap = false
            lastTapTime = nil
            return
        }

        // An unmappable modifier (empty `flag`) can never be the sole one held, so
        // bail — otherwise `active == flag` would match every plain key-up.
        guard !flag.isEmpty else { return }

        let active = event.modifierFlags.intersection(DoubleTapModifierMonitor.watched)
        let onlyTargetHeld = active == flag

        if onlyTargetHeld {
            // Down edge: the target modifier just became the sole one held.
            pendingTap = true
            return
        }

        // Any other held modifier dirties both the pending press and the previous
        // completed tap, even if it joined before the target did.
        guard active.isEmpty else {
            pendingTap = false
            lastTapTime = nil
            return
        }

        // Empty flags are the release edge that can complete a clean tap.
        guard pendingTap else { return }
        pendingTap = false

        let now = event.timestamp
        if let last = lastTapTime, now - last <= window {
            lastTapTime = nil
            action()
        } else {
            lastTapTime = now
        }
    }

    /// Map a Carbon modifier mask to the Cocoa flag `NSEvent` reports. Only the
    /// four real modifiers can be double-tapped; anything else yields an empty
    /// set (never matches), which is the safe no-op.
    private static func cocoaFlag(forCarbon carbon: UInt32) -> NSEvent.ModifierFlags {
        switch carbon {
        case UInt32(cmdKey):     return .command
        case UInt32(optionKey):  return .option
        case UInt32(controlKey): return .control
        case UInt32(shiftKey):   return .shift
        default:                 return []
        }
    }
}

/// Gates the Force Touch path so it can be parked without discarding its
/// implementation or the user's saved pressure preference.
enum ForceClickFeature {
    static let isEnabled = true
}

/// Observes a Force Touch trackpad globally and fires once when a click continues
/// into the second pressure rung. AppKit's `.pressure` stream is window-local —
/// its global event monitor silently receives nothing — so the raw pressure comes
/// from macOS's private MultitouchSupport framework. Ordinary mouse-down/up events
/// still delimit the gesture and remain owned by the app under the pointer.
final class ForceClickMonitor {
    private let action: () -> Void
    /// How far the press has come, 0…1, where 1 is the pressure that fires. Fed
    /// live so the UI can show the gesture building instead of only its result
    /// (`ForceClickHerald`); `nil` progress means the press is over.
    private let progress: (Double?) -> Void
    private var pressureSource: RawTrackpadPressureSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var mouseIsDown = false
    private var latestPressure: Float = 0
    private var clickPressure: Float?
    private var peakPressure: Float = 0
    private var firedForCurrentPress = false
    /// Observer for the wake notification that re-arms the pressure client.
    private var wakeObserver: NSObjectProtocol?
    /// When the last raw contact frame arrived, and when the client was last
    /// rebuilt. The MultitouchSupport registration does not survive a sleep/wake
    /// cycle (or the trackpad re-enumerating): the callback simply stops being
    /// called, with no error and no way to notice from the inside. Both re-arm
    /// paths below key off these.
    private var lastFrameAt: Date?
    private var lastRearmAt = Date.distantPast
    /// Where the current press went down, and whether it has since travelled far
    /// enough to be a drag rather than a click held in place.
    private var pressOrigin: NSPoint?
    private var pressMoved = false
    /// Where the pointer was at the last sample, how far it has travelled along
    /// its actual path since the press went down, and when it last moved by more
    /// than hand tremor. Straight-line distance from the origin alone misses a
    /// drag that curves back near where it started, and says nothing about
    /// whether the hand is moving *right now* — which is the question that
    /// separates a force click from someone leaning into a drag.
    private var lastPointerPoint: NSPoint?
    private var pressTravel: CGFloat = 0
    private var lastMovedAt = Date.distantPast
    /// The press has met the pressure bar and is serving out `fireHold`: where
    /// the pointer was when it qualified, and when. Any movement before the hold
    /// is up means this was the start of a drag, and the press is disarmed
    /// instead of fired.
    private var pendingFireAt: Date?
    private var pendingFirePoint: NSPoint?
    /// The press started on one of Notchi's own windows, so it is not a gesture
    /// on someone else's text — see `pressIsOnOwnWindow`.
    private var pressOnOwnWindow = false

    /// How long a click may find the pressure stream silent before the client is
    /// treated as dead. A click means fingers are on the pad, so frames should be
    /// arriving at ~125Hz; a second of silence at that moment is not a still hand.
    private static let staleFrameWindow: TimeInterval = 1
    /// Floor between rebuilds, so clicking with an external mouse (no contact
    /// frames, ever) doesn't rebuild the client on every click.
    private static let rearmCooldown: TimeInterval = 10
    /// How far the pointer may travel before the press stops being a candidate
    /// for the gesture. A drag keeps the finger down on the pad and the hand
    /// naturally leans into it, so without this every window drag crosses the
    /// firing pressure somewhere across the screen and gets the shortcut fired
    /// out from under it — the window is dropped and a composer opens instead.
    /// macOS's own force click draws the same line: once the press starts moving
    /// what is under it, it is a drag and nothing else.
    private static let dragSlop: CGFloat = 6
    /// How far the pointer may shift between two samples and still count as a
    /// hand held in place. Below this the step is tremor: it neither adds to the
    /// travelled path nor restarts the settle timer, so a long firm press can't
    /// disarm itself by accumulating noise.
    private static let stillSlop: CGFloat = 1.5
    /// How long the pointer must be still before pressure counts again. Pressing
    /// harder while the pointer is on its way somewhere is how a drag feels — the
    /// hand leans in to keep hold — so pressure only builds toward the gesture
    /// once the pointer has actually settled.
    private static let settleWindow: TimeInterval = 0.12
    /// How long the pointer must stay put *after* the pressure threshold is met
    /// before the gesture actually fires. Reaching the threshold says the finger
    /// pressed hard; only the next instant says whether it pressed hard to look
    /// at something or to pick something up. A drag that starts with a firm press
    /// — grabbing a window, a file, a text selection — crosses the threshold
    /// before the pointer has moved at all, so a threshold test alone can never
    /// tell the two apart. This window is what tells them apart, and it is short
    /// enough to stay invisible in a press that really is a press.
    private static let fireHold: TimeInterval = 0.11

    /// Whether this machine actually feeds pressure. False on a mouse, an old
    /// non-Force-Touch trackpad, or if the private framework ever stops loading —
    /// in which case the pressure setting has nothing to act on and its test pad
    /// says so instead of waiting for a press that can never register.
    var isSupported: Bool { pressureSource != nil }

    init(progress: @escaping (Double?) -> Void = { _ in },
         action: @escaping () -> Void) {
        self.action = action
        self.progress = progress

        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp,
                                                  .leftMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) {
            [weak self] event in
            self?.handleMouse(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) {
            [weak self] event in
            self?.handleMouse(event)
            return event
        }
        openPressureSource()
#if DEBUG
        if pressureSource == nil {
            NSLog("[ForceClick] raw trackpad pressure source unavailable")
        }
#endif
        // Waking is where the registration dies. Rebuilding it here is what keeps
        // the gesture alive past the first sleep of a session — without it the
        // monitor is only ever as good as the app's uptime, and the failure is
        // invisible: pressing simply stops doing anything.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.rearmPressureSource()
        }
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    /// (Re)open the raw contact-frame client. The private framework hands out one
    /// registration per device and a dead one never revives, so recovery is always
    /// a fresh source — dropping the old one first, since it still owns the
    /// device's single callback slot until it deinits.
    private func openPressureSource() {
        pressureSource = nil
        pressureSource = RawTrackpadPressureSource { [weak self] pressure, hasTouches in
            self?.handlePressure(pressure, hasTouches: hasTouches)
        }
        lastFrameAt = nil
        lastRearmAt = Date()
    }

    /// Rebuild the client unless one was just built — see `rearmCooldown`.
    private func rearmPressureSource() {
        guard Date().timeIntervalSince(lastRearmAt) > Self.rearmCooldown else { return }
        openPressureSource()
    }

    private func handleMouse(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // The wake notification covers the common death, but not every one:
            // the client also goes quiet when the trackpad re-enumerates, and a
            // missed notification would park the gesture for the rest of the
            // session. A click with nothing on the pressure stream is that state,
            // observed from the one moment it matters.
            if let lastFrameAt,
               Date().timeIntervalSince(lastFrameAt) > Self.staleFrameWindow {
                rearmPressureSource()
            }
            mouseIsDown = true
            firedForCurrentPress = false
            // Screen coordinates on purpose: the global monitor reports another
            // app's window, and this only ever asks how far the pointer went.
            pressOrigin = NSEvent.mouseLocation
            pressMoved = false
            lastPointerPoint = pressOrigin
            pressTravel = 0
            lastMovedAt = .distantPast
            pendingFireAt = nil
            pendingFirePoint = nil
            pressOnOwnWindow = Self.pressIsOnOwnWindow()
            peakPressure = latestPressure
            // The raw frame normally arrives just before mouse-down. If it races
            // behind, the first pressure frame below becomes the baseline instead.
            clickPressure = latestPressure > 1 ? latestPressure : nil
        case .leftMouseDragged:
            // The press is moving something. Disarm it for good — pressure
            // reported for the rest of this drag belongs to holding on, not to
            // pressing in.
            guard mouseIsDown, !pressMoved else { break }
            guard noteMotion() == .drag else { break }
            pressMoved = true
            progress(nil)
        case .leftMouseUp:
            // Letting go inside the hold window settles it the other way: the
            // press ended where it started, so it was a press. Fire now rather
            // than swallow it — the pressure stream stops being consulted the
            // moment the button is up.
            if pendingFireAt != nil, !pressMoved, noteMotion() != .drag {
                fire()
            }
#if DEBUG
            NSLog("[ForceClick] baseline=%.1f peak=%.1f travel=%.1f fired=%@%@",
                  clickPressure ?? 0, peakPressure, pressTravel,
                  firedForCurrentPress ? "yes" : "no",
                  pressMoved ? " (drag)" : "")
#endif
            resetPress()
        default:
            break
        }
    }

    private func handlePressure(_ pressure: Float, hasTouches: Bool) {
        // Liveness is recorded before any gate: a frame arriving at all is what
        // says the client is alive, whether or not this press is one we act on.
        lastFrameAt = Date()
        // The rung can be switched off entirely — then pressure is ignored and
        // the herald never draws, so a plain click stays a plain click.
        guard ForceClickPressure.current.isEnabled else { return }
        latestPressure = pressure
        peakPressure = max(peakPressure, pressure)
        guard hasTouches else {
            if !mouseIsDown { resetPress() }
            return
        }
        guard mouseIsDown, !firedForCurrentPress, !pressMoved, !pressOnOwnWindow
        else { return }
        // The dragged event above is the fast signal, but not a reliable one:
        // a window drag (`performDrag(with:)`, or AppKit's own
        // `isMovableByWindowBackground` tracking) pulls events straight off the
        // queue, so the local monitor is never called for the whole ride. The
        // pressure stream is not on that loop — it keeps arriving at ~125Hz —
        // so the same question is asked here against the live pointer, which is
        // what actually disarms a drag of one of our own windows.
        let motion = noteMotion()
        // A press already waiting out its hold answers only one question: did the
        // pointer move? Any movement at all — not just enough to clear the drag
        // slop — means the hand was on its way somewhere, so the press is a drag
        // and stays disarmed for the rest of it.
        if let pendingFireAt, let pendingFirePoint {
            let now = NSEvent.mouseLocation
            let drift = hypot(now.x - pendingFirePoint.x, now.y - pendingFirePoint.y)
            if motion == .drag || drift > Self.stillSlop {
                pressMoved = true
                self.pendingFireAt = nil
                self.pendingFirePoint = nil
                progress(nil)
                return
            }
            if Date().timeIntervalSince(pendingFireAt) >= Self.fireHold { fire() }
            return
        }
        switch motion {
        case .drag:
            pressMoved = true
            progress(nil)
            return
        case .moving:
            // Still going somewhere. Don't let this frame count, and drop the
            // baseline so the pressure being held to keep hold of whatever is
            // under the pointer becomes the new floor once the hand settles —
            // firing then takes a fresh push, not the weight already there.
            clickPressure = nil
            progress(nil)
            return
        case .still:
            break
        }
        guard let baseline = clickPressure else {
            if pressure > 1 { clickPressure = pressure }
            return
        }

        let reached = ForceClickPressure.current.progress(of: pressure, from: baseline)
        progress(reached)
        guard reached >= 1 else { return }
        // Qualified on pressure. Hold it for a beat and see whether the pointer
        // stays — `fireHold`.
        pendingFireAt = Date()
        pendingFirePoint = NSEvent.mouseLocation
    }

    /// Commit the gesture. Guarded so the two paths into it — the hold expiring
    /// on the pressure stream, and the button coming up mid-hold — can't both
    /// land for one press.
    private func fire() {
        guard !firedForCurrentPress else { return }
        firedForCurrentPress = true
        pendingFireAt = nil
        pendingFirePoint = nil
        action()
    }

    /// What the pointer is doing this instant, from the press's point of view.
    private enum PressMotion {
        /// Held in place — pressure may build toward the gesture.
        case still
        /// Moving, but not yet far enough to call the press a drag.
        case moving
        /// Travelled far enough that this press belongs to a drag for good.
        case drag
    }

    /// Sample the pointer and fold it into the press's motion state. Called from
    /// both the drag events and the ~125Hz pressure stream — the latter is the
    /// one that matters, since a window drag pulls mouse events straight off the
    /// queue and the monitors never see them.
    private func noteMotion() -> PressMotion {
        let now = NSEvent.mouseLocation
        if let last = lastPointerPoint {
            let step = hypot(now.x - last.x, now.y - last.y)
            if step > Self.stillSlop {
                pressTravel += step
                lastMovedAt = Date()
            }
        }
        lastPointerPoint = now
        if let pressOrigin,
           hypot(now.x - pressOrigin.x, now.y - pressOrigin.y) > Self.dragSlop {
            return .drag
        }
        if pressTravel > Self.dragSlop { return .drag }
        return Date().timeIntervalSince(lastMovedAt) < Self.settleWindow
            ? .moving : .still
    }

    /// Is the pointer over one of our own windows?
    ///
    /// The gesture reads the selection in the app the user is pressing INSIDE
    /// of, so a press on Notchi's own surfaces has nothing to act on. Left
    /// unguarded it acts anyway, and the surface it lands on is almost always
    /// the pointer-side box the last press just opened: grabbing that box to
    /// move it presses it hard enough to fire again, which re-summons the very
    /// window under the hand — it snaps back to the pointer, churns, and dies.
    /// macOS's own force click doesn't act on the app you are pressing in
    /// either.
    ///
    /// Asked of the window server rather than by which monitor delivered the
    /// event: a click on a window of an inactive app is consumed by the
    /// activation, so the local monitor cannot be relied on to see it.
    ///
    /// And asked as "what would this click actually hit", NOT "is the pointer
    /// inside one of our frames". The island's canvas is a 760×640 transparent
    /// panel pinned to the top of every screen: by frame it covers most of the
    /// upper middle of the display, which is exactly where text gets selected,
    /// so frame containment disqualified the gesture almost everywhere. The
    /// window server hit-tests through the transparent pixels and names the
    /// window the press really lands on.
    @MainActor private static func ownWindowUnderPointer() -> Bool {
        let number = NSWindow.windowNumber(at: NSEvent.mouseLocation,
                                           belowWindowWithWindowNumber: 0)
        return NSApp.window(withWindowNumber: number) != nil
    }

    private static func pressIsOnOwnWindow() -> Bool {
        MainActor.assumeIsolated { ownWindowUnderPointer() }
    }

    private func resetPress() {
        let wasTracking = mouseIsDown || clickPressure != nil
        mouseIsDown = false
        clickPressure = nil
        firedForCurrentPress = false
        pressOrigin = nil
        pressMoved = false
        lastPointerPoint = nil
        pressTravel = 0
        lastMovedAt = .distantPast
        pendingFireAt = nil
        pendingFirePoint = nil
        pressOnOwnWindow = false
        if wasTracking { progress(nil) }
    }
}

/// macOS's own force-click lookup — System Settings → Trackpad → "Look up &
/// data detectors" set to *Force Click with One Finger*. It listens for exactly
/// the press `ForceClickMonitor` watches, so while it is on a hard click on
/// selected text opens the system's dictionary panel over ours. The system
/// offers no way to turn it off programmatically, so all Notchi can do is read
/// it and ask.
///
/// The popup's three positions map to two preferences: *Force Click with One
/// Finger* sets `com.apple.trackpad.forceClick` in the global domain, *Tap with
/// Three Fingers* sets `TrackpadThreeFingerTapGesture` in the trackpad domains,
/// and *Off* clears both. Only the force-click one collides — a three-finger tap
/// is a different gesture entirely — so that is the only one read here.
enum SystemLookupGesture {
    private static let key = "com.apple.trackpad.forceClick" as CFString

    /// Read through `CFPreferences`, not `UserDefaults.standard`: System
    /// Settings writes the global domain while Notchi is already running, and
    /// the standard defaults serve a snapshot taken at launch. The explicit
    /// synchronize picks up a change made moments ago in the other app.
    static var usesForceClick: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let value = CFPreferencesCopyValue(key,
                                           kCFPreferencesAnyApplication,
                                           kCFPreferencesCurrentUser,
                                           kCFPreferencesAnyHost)
        return (value as? NSNumber)?.boolValue ?? false
    }
}

/// How firmly a normal click must continue before Notchi treats it as a Force
/// Click. Each rung combines an absolute pressure floor with the rise from the
/// first click, so a late raw frame cannot make an ordinary click look forced.
enum ForceClickPressure: String, CaseIterable, Identifiable {
    case off
    case light
    case medium
    case firm

    var id: String { rawValue }

    /// Whether the gesture should respond at all. `off` disarms the monitor so
    /// pressing harder on selected text does nothing.
    var isEnabled: Bool { self != .off }

    var label: String {
        switch self {
        case .off:    return L("forceClick.off")
        case .light:  return L("forceClick.light")
        case .medium: return L("forceClick.medium")
        case .firm:   return L("forceClick.firm")
        }
    }

    fileprivate var ratio: Float {
        switch self {
        case .off:    return 1
        case .light:  return 1.70
        case .medium: return 2.00
        case .firm:   return 2.45
        }
    }

    fileprivate var minimumRise: Float {
        switch self {
        case .off:    return 1
        case .light:  return 65
        case .medium: return 95
        case .firm:   return 140
        }
    }

    fileprivate var minimumPressure: Float {
        switch self {
        case .off:    return 1
        case .light:  return 200
        case .medium: return 260
        case .firm:   return 360
        }
    }

    /// How far a press at `pressure` has come toward this rung, 0…1, where 1 means
    /// it fires. Raw pressure is reported in gram-force; Apple's own second-click
    /// threshold is private and adapts by hardware/settings, so each rung combines
    /// an absolute floor with the rise from the first click, tuned around the
    /// medium values validated on a real Force Touch pad.
    ///
    /// The three terms are combined with `min` — the slowest one to be satisfied
    /// is what the user still has to push through, so this hits exactly 1 at the
    /// same moment all three conditions hold. That makes it the single definition
    /// of the gesture: the cue can't promise a fire the monitor won't deliver.
    func progress(of pressure: Float, from baseline: Float) -> Double {
        let absolute = Double(pressure / minimumPressure)
        let proportional = baseline > 0
            ? Double(pressure / (baseline * ratio))
            : 0
        let risen = Double((pressure - baseline) / minimumRise)
        return max(0, min(1, min(absolute, min(proportional, risen))))
    }

    private static let key = "forceClickPressure"

    /// Unset means **off** — a fresh install never arms the gesture. It collides
    /// with macOS's own force-click lookup, which ships on, so an implicit
    /// default of `.medium` handed brand-new users two panels on one press
    /// before they had ever heard of the setting. Now the gate in Settings is
    /// the only way it turns on: you pick a rung, the dialog walks you through
    /// switching Apple's lookup off, and it arms.
    static var current: ForceClickPressure {
        get {
            UserDefaults.standard.string(forKey: key)
                .flatMap(ForceClickPressure.init(rawValue:)) ?? .off
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Keep the old implicit default for Macs that already had it. Before this
    /// change an unset key meant `.medium`, so someone who has been using the
    /// gesture since 0.6.x never wrote anything down — flipping the default
    /// alone would silently disarm them on update. Anyone who has launched Notchi
    /// before (the same signals `OnboardingService` reads) gets `.medium`
    /// stamped once; a true first run is left unset, i.e. off.
    static func seedDefaultForExistingInstalls() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: key) == nil else { return }
        let launchedBefore = defaults.bool(forKey: "onboarding_intro_done")
            || defaults.bool(forKey: "onboarding_opened_once")
            || defaults.bool(forKey: "onboarding_guide_done")
        guard launchedBefore else { return }
        defaults.set(ForceClickPressure.medium.rawValue, forKey: key)
    }
}

/// Minimal, dynamically-linked reader for the system trackpad's contact frames.
/// Loading at runtime keeps the app build independent of private SDK headers and
/// makes unsupported machines a clean no-op.
private final class RawTrackpadPressureSource {
    private typealias DeviceRef = UnsafeMutableRawPointer
    private typealias FrameCallback = @convention(c) (
        DeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32
    ) -> Void
    private typealias IsAvailable = @convention(c) () -> Bool
    private typealias CreateDefault = @convention(c) () -> DeviceRef?
    private typealias RegisterCallback = @convention(c) (DeviceRef?, FrameCallback?) -> Void
    private typealias StartDevice = @convention(c) (DeviceRef?, Int32) -> Int32
    private typealias StopDevice = @convention(c) (DeviceRef?) -> Int32
    private typealias ReleaseDevice = @convention(c) (DeviceRef?) -> Void

    private static weak var active: RawTrackpadPressureSource?
    private static let touchStride = 96
    private static let pressureOffset = 52

    private let framework: UnsafeMutableRawPointer
    private let device: DeviceRef
    private let unregister: RegisterCallback
    private let stop: StopDevice
    private let release: ReleaseDevice
    private let onFrame: (Float, Bool) -> Void

    init?(onFrame: @escaping (Float, Bool) -> Void) {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let framework = dlopen(path, RTLD_LAZY | RTLD_LOCAL),
              let isAvailable: IsAvailable = Self.symbol("MTDeviceIsAvailable", in: framework),
              isAvailable(),
              let create: CreateDefault = Self.symbol("MTDeviceCreateDefault", in: framework),
              let device = create(),
              let register: RegisterCallback = Self.symbol(
                "MTRegisterContactFrameCallback", in: framework),
              let unregister: RegisterCallback = Self.symbol(
                "MTUnregisterContactFrameCallback", in: framework),
              let start: StartDevice = Self.symbol("MTDeviceStart", in: framework),
              let stop: StopDevice = Self.symbol("MTDeviceStop", in: framework),
              let release: ReleaseDevice = Self.symbol("MTDeviceRelease", in: framework)
        else {
            return nil
        }

        self.framework = framework
        self.device = device
        self.unregister = unregister
        self.stop = stop
        self.release = release
        self.onFrame = onFrame

        Self.active = self
        register(device, rawTrackpadFrameCallback)
        guard start(device, 0) == 0 else {
            unregister(device, rawTrackpadFrameCallback)
            release(device)
            Self.active = nil
            dlclose(framework)
            return nil
        }
    }

    deinit {
        unregister(device, rawTrackpadFrameCallback)
        _ = stop(device)
        release(device)
        if Self.active === self { Self.active = nil }
        dlclose(framework)
    }

    fileprivate static func receive(
        touches: UnsafeMutableRawPointer?, count: Int32
    ) {
        guard let source = active else { return }
        var maximum: Float = 0
        if let touches, count > 0 {
            for index in 0..<Int(count) {
                let address = touches
                    .advanced(by: index * touchStride + pressureOffset)
                    .assumingMemoryBound(to: Float.self)
                maximum = max(maximum, address.pointee)
            }
        }
        DispatchQueue.main.async { [weak source] in
            source?.onFrame(maximum, count > 0)
        }
    }

    private static func symbol<T>(_ name: String,
                                  in framework: UnsafeMutableRawPointer) -> T? {
        guard let address = dlsym(framework, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }
}

private func rawTrackpadFrameCallback(
    _ device: UnsafeMutableRawPointer?,
    _ touches: UnsafeMutableRawPointer?,
    _ count: Int32,
    _ timestamp: Double,
    _ frame: Int32
) {
    RawTrackpadPressureSource.receive(touches: touches, count: count)
}

/// The user-configurable global shortcut that summons (toggles) the notch panel.
/// Persisted in `UserDefaults` as a `keyCode`/`modifiers` pair plus an enabled
/// flag, edited in Settings → General, registered by `AppDelegate`.
///
/// `keyCode` is a virtual key code (Carbon `kVK_*`); `modifiers` are Carbon hot
/// key modifier masks (`cmdKey`/`optionKey`/`controlKey`/`shiftKey`), which is
/// what `RegisterEventHotKey` wants.
///
/// There are two flavours of trigger, distinguished by `doubleTapModifier`:
///
/// - **Double-tap a bare modifier** (`doubleTapModifier != 0`) — the shipped
///   default is a double-tap of ⌥. `RegisterEventHotKey` can't see a lone
///   modifier, so this is detected by watching `flagsChanged` (see
///   `DoubleTapModifierMonitor`); `keyCode`/`modifiers` are unused.
/// - **A chord** (`doubleTapModifier == 0`) — e.g. ⌥Space or ⌘⇧K, recorded in
///   Settings and registered through Carbon. The original mechanism.
struct SummonHotKey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// Non-zero ⇒ this shortcut is a double-tap of a *bare* modifier, and the
    /// value is that modifier's Carbon mask (e.g. `optionKey`). Zero ⇒ it's a
    /// Carbon chord described by `keyCode`/`modifiers`.
    var doubleTapModifier: UInt32 = 0
    /// When false the shortcut isn't registered at all — hover stays the only
    /// way in, for users who don't want a global key grabbing the summon.
    var enabled: Bool

    /// Whether this config triggers on a double-tapped bare modifier.
    var isDoubleTap: Bool { doubleTapModifier != 0 }

    /// Double-tap ⌥ — the shipped default. Reachable one-handed, taken by no
    /// system shortcut, and never collides with a typed character.
    static let defaultConfig = SummonHotKey(
        keyCode: 0,
        modifiers: 0,
        doubleTapModifier: UInt32(optionKey),
        enabled: true
    )

    private static let keyCodeKey = "summonHotKey.keyCode"
    private static let modifiersKey = "summonHotKey.modifiers"
    private static let doubleTapKey = "summonHotKey.doubleTapModifier"
    private static let enabledKey = "summonHotKey.enabled"

    static var current: SummonHotKey {
        get {
            let defaults = UserDefaults.standard
            // No stored config at all (neither a recorded chord nor a double-tap
            // choice) → first run → ship the default (double-tap ⌥).
            guard defaults.object(forKey: keyCodeKey) != nil
                    || defaults.object(forKey: doubleTapKey) != nil else {
                return .defaultConfig
            }
            let code = UInt32(bitPattern: Int32(defaults.integer(forKey: keyCodeKey)))
            let mods = UInt32(bitPattern: Int32(defaults.integer(forKey: modifiersKey)))
            let dbl = UInt32(bitPattern: Int32(defaults.integer(forKey: doubleTapKey)))
            // `enabled` defaults to true when the flag was never written (e.g. a
            // config saved before the flag existed); only an explicit false disables.
            let enabled = defaults.object(forKey: enabledKey) as? Bool ?? true
            return SummonHotKey(keyCode: code, modifiers: mods,
                                doubleTapModifier: dbl, enabled: enabled)
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(Int(Int32(bitPattern: newValue.keyCode)), forKey: keyCodeKey)
            defaults.set(Int(Int32(bitPattern: newValue.modifiers)), forKey: modifiersKey)
            defaults.set(Int(Int32(bitPattern: newValue.doubleTapModifier)), forKey: doubleTapKey)
            defaults.set(newValue.enabled, forKey: enabledKey)
        }
    }

    /// A human-readable rendering for the settings row: a double-tapped modifier
    /// shows the glyph twice (e.g. `⌥⌥`); a chord shows modifiers + key (`⌘⇧K`).
    var displayString: String {
        if isDoubleTap {
            let glyph = SummonHotKey.modifierSymbols(doubleTapModifier)
            return glyph + glyph
        }
        return SummonHotKey.modifierSymbols(modifiers) + SummonHotKey.keyName(keyCode)
    }

    /// Carbon modifier mask → the glyphs macOS users expect, in the canonical
    /// ⌃⌥⇧⌘ order.
    static func modifierSymbols(_ modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s
    }

    /// Translate a Cocoa modifier-flags set (what `NSEvent` reports while
    /// recording) into the Carbon mask `RegisterEventHotKey` needs.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        return mods
    }

    /// A short printable name for a virtual key code. Covers the special keys a
    /// shortcut commonly lands on; everything else falls back to the uppercased
    /// character the key produces, and an unknown code to "Key".
    static func keyName(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space:        return "Space"
        case kVK_Return:       return "↩"
        case kVK_Tab:          return "⇥"
        case kVK_Escape:       return "⎋"
        case kVK_Delete:       return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow:    return "←"
        case kVK_RightArrow:   return "→"
        case kVK_UpArrow:      return "↑"
        case kVK_DownArrow:    return "↓"
        case kVK_F1:  return "F1";  case kVK_F2:  return "F2";  case kVK_F3:  return "F3"
        case kVK_F4:  return "F4";  case kVK_F5:  return "F5";  case kVK_F6:  return "F6"
        case kVK_F7:  return "F7";  case kVK_F8:  return "F8";  case kVK_F9:  return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default:
            return printableKeyName(keyCode) ?? "Key"
        }
    }

    /// The character a key produces with no modifiers, uppercased — so the W key
    /// reads as "W", the 5 key as "5". Resolved through the current keyboard
    /// layout so non-US layouts label correctly. `nil` when the key has no
    /// printable output (e.g. a dead modifier), letting the caller fall back.
    private static func printableKeyName(_ keyCode: UInt32) -> String? {
        guard let layoutData = TISGetInputSourceProperty(
            TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue(),
            kTISPropertyUnicodeKeyLayoutData
        ) else { return nil }
        let layout = unsafeBitCast(layoutData, to: CFData.self)
        guard let keyLayoutPtr = CFDataGetBytePtr(layout) else { return nil }
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = keyLayoutPtr.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { ptr in
            UCKeyTranslate(
                ptr,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0, // no modifiers
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let result = String(utf16CodeUnits: chars, count: length).uppercased()
        return result.isEmpty ? nil : result
    }
}

/// A local, user-editable keyboard chord. Unlike `SummonHotKey`, these only act
/// while a Notch panel is the key window, so they never steal a key from another
/// app. The stored representation intentionally matches the summon chord's
/// Carbon key-code/modifier pair, which keeps recording, rendering and conflict
/// checks identical across the whole Shortcuts pane.
struct ShortcutChord: Codable, Equatable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32
    /// Non-nil for a global double-tap of a bare modifier. Optional keeps every
    /// previously persisted prompt shortcut decodable without a migration.
    let doubleTapModifier: UInt32?

    init(keyCode: UInt32, modifiers: UInt32, doubleTapModifier: UInt32? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.doubleTapModifier = doubleTapModifier
    }

    static func doubleTap(_ modifier: UInt32) -> ShortcutChord {
        ShortcutChord(keyCode: 0, modifiers: 0, doubleTapModifier: modifier)
    }

    var isDoubleTap: Bool { doubleTapModifier != nil }

    var displayString: String {
        if let doubleTapModifier {
            let glyph = SummonHotKey.modifierSymbols(doubleTapModifier)
            return glyph + glyph
        }
        return SummonHotKey.modifierSymbols(modifiers) + SummonHotKey.keyName(keyCode)
    }

    func matches(_ event: NSEvent) -> Bool {
        guard !isDoubleTap else { return false }
        guard UInt32(event.keyCode) == keyCode else { return false }
        return modifiers == SummonHotKey.carbonModifiers(from: event.modifierFlags)
    }
}

/// One backend to run a round on: a model id and the provider that serves it.
/// A bare model id is not enough — the same name can exist at two providers, and
/// only the pair says which key/endpoint the request goes to.
struct ModelPin: Hashable {
    var provider: Provider
    var model: String
}

/// One user-authored instruction bound directly to a global shortcut. The prompt
/// is the row's identity and always acts on the current text selection; an
/// optional AI-suggested `name` lets the shortcut surface as a named, switchable
/// mode in the `/` menu. `name` is `nil` for shortcuts created before naming
/// existed — `displayName` falls back to the prompt so those rows stay readable.
struct PromptShortcut: Codable, Equatable, Identifiable {
    var id: UUID
    var shortcut: ShortcutChord?
    var prompt: String
    /// AI-generated display name for the `/` menu. Decodes to `nil` for old
    /// persisted rows (optional Codable = zero-migration), so already-added
    /// shortcuts work without any data rewrite.
    var name: String?
    /// Legacy destination value retained only so rows saved by older builds keep
    /// decoding. Prompt shortcuts now always open beside the pointer.
    var opensBesidePointer: Bool?
    /// Whether this row is offered as a button in the force click box
    /// (`CompactShortcutPromptView.quickPicks`). That box holds four rows at
    /// most, so a shortcut that isn't wanted under the pointer can step out and
    /// leave the slot to one that is. `nil` — every row saved before this
    /// existed — means shown, which is the behaviour those rows already had.
    var showsInForceTouch: Bool?
    /// Pins this shortcut to one backend — a translation chord can stay on a cheap
    /// fast model at one provider while the notch's default answers everything
    /// else. Stored as two optionals (`Provider.rawValue` + model id) so an older
    /// row simply decodes to no pin. Read/written through `pin`; a half-set pair
    /// means no pin, since a model id only means anything under its provider.
    var providerID: String?
    var model: String?
    /// The id of the template this shortcut was added from, kept only to choose
    /// its colour (`PromptShortcutCardSurface`). Without it the card is re-rolled
    /// against its fresh UUID and changes hue the instant it is saved — the same
    /// action, a different colour on either side of one tap. `nil` for hand-written
    /// rows and for everything saved before templates existed, which keeps their
    /// established colours exactly where they are.
    var paletteKey: String?

    /// The key that actually chooses this shortcut's colour. Rows saved before
    /// `paletteKey` existed carry none, so the instruction itself is matched back
    /// against the template library — otherwise two identical actions, one added
    /// last week and one added today, would sit side by side in different colours.
    var paletteSeed: String? {
        if let paletteKey, !paletteKey.isEmpty { return paletteKey }
        return RemoteModelManifest.templateCategory(forPrompt: prompt)
    }

    /// Snapshot the app's current backend into a concrete shortcut pin. Prompt
    /// shortcuts are saved actions, so their model must not drift when the app's
    /// default provider or model changes later.
    static var currentModelPin: ModelPin {
        let provider = APIKeyStore.selectedProvider
        let model = APIKeyStore.effectiveModel(for: provider) ?? provider.defaultModel
        return ModelPin(provider: provider, model: model)
    }

    init(id: UUID = UUID(), shortcut: ShortcutChord? = nil, prompt: String = "",
         name: String? = nil, opensBesidePointer: Bool? = true,
         showsInForceTouch: Bool? = nil,
         pin: ModelPin? = PromptShortcut.currentModelPin,
         paletteKey: String? = nil) {
        self.id = id
        self.shortcut = shortcut
        self.prompt = prompt
        self.name = name
        self.opensBesidePointer = opensBesidePointer
        self.showsInForceTouch = showsInForceTouch
        self.providerID = pin?.provider.rawValue
        self.model = pin?.model
        self.paletteKey = paletteKey
    }

    /// The pinned backend as one value — the form every caller wants, since the
    /// provider and the model are only meaningful together.
    var pin: ModelPin? {
        get {
            // A pin to a backend the app no longer offers (`Provider.offered`)
            // reads as no pin, so the shortcut runs on the current provider
            // instead of a backend nothing in the UI can reach.
            guard let providerID, let provider = Provider(rawValue: providerID),
                  Provider.offered.contains(provider),
                  let model, !model.isEmpty
            else { return nil }
            return ModelPin(provider: provider, model: model)
        }
        set {
            providerID = newValue?.provider.rawValue
            model = newValue?.model
        }
    }

    /// What the row/menu shows: the name when one has been generated, else a
    /// truncated slice of the prompt — the same fallback old rows get before
    /// their first AI naming pass runs.
    var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 24 ? String(trimmed.prefix(24)) + "…" : trimmed
    }

    /// Nothing has been set on it: no chord, no prompt. A row added with `+` and
    /// left untouched is exactly this, and it is never worth keeping.
    var isBlank: Bool {
        shortcut == nil && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isReady: Bool {
        shortcut != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var opensInPointerWindow: Bool { true }

    /// Shown in the force click box unless the row was explicitly taken out of it.
    var appearsInForceTouch: Bool { showsInForceTouch != false }

    var canRunFromHotKey: Bool { isReady }
}

/// Small versionless store for the equally small `[shortcut, prompt]` list.
/// `Codable` keeps the persisted shape explicit and makes a later migration easy
/// without introducing a database for a handful of settings rows.
enum PromptShortcutStore {
    private static let key = "promptShortcuts"

    #if DEBUG
    /// Rows for a screenshot run (`NOTCH_DEMO_FORCE=menu`), held in this process
    /// only. Writing them to disk used to leave the demo's `prompt: "Demo"` rows
    /// standing in the user's real shortcuts after the run ended.
    static var debugOverride: [PromptShortcut]?
    #endif

    static var current: [PromptShortcut] {
        #if DEBUG
        if let debugOverride { return debugOverride }
        #endif
        guard let data = UserDefaults.standard.data(forKey: key),
              let shortcuts = try? JSONDecoder().decode([PromptShortcut].self, from: data)
        else { return [] }

        // Rows saved before model pinning (and rows that used the former
        // "Default model" option) have no complete provider/model pair. Freeze
        // the default that is in effect on first load after this update so they
        // stop changing with the app-wide setting from then on.
        let fallback = PromptShortcut.currentModelPin
        var migrated = shortcuts
        var changed = false
        for index in migrated.indices where migrated[index].pin == nil {
            migrated[index].pin = fallback
            changed = true
        }
        if changed { save(migrated) }
        return migrated
    }

    static func save(_ shortcuts: [PromptShortcut]) {
        guard let data = try? JSONEncoder().encode(shortcuts) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func shortcut(id: UUID) -> PromptShortcut? {
        current.first { $0.id == id }
    }
}

/// The fixed global action that opens a one-off instruction field with the
/// current selection already attached. Unlike `PromptShortcut`, this has no
/// prompt field by design: its identity never depends on leaving an editor blank.
struct SelectedTextShortcut: Codable, Equatable {
    var opensBesidePointer = false

    var opensInPointerWindow: Bool { opensBesidePointer }
}

enum SelectedTextShortcutStore {
    static let actionID = UUID(uuidString: "7A6EA903-8EAE-4A72-BA61-184947183A9F")!
    private static let key = "selectedTextShortcut"

    static var current: SelectedTextShortcut {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(SelectedTextShortcut.self, from: data)
        else { return SelectedTextShortcut() }
        return value
    }

    static func save(_ value: SelectedTextShortcut) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// Reads the selection owned by the app that is currently focused. This must run
/// before Notch opens and activates itself; after activation, the focused element
/// would be Notch's own prompt field and the outside selection would be lost.
///
/// Native controls usually expose `AXSelectedText` directly;
/// browser/Electron/PDF surfaces commonly expose only a selected character range
/// or a WebKit text-marker range, sometimes on an ancestor of the focused node.
/// Try those representations first. The asynchronous, user-invoked read adds one
/// final compatibility edge: while the source app still owns focus, briefly send
/// Command-C, read the copied string, then restore the user's previous pasteboard.
/// The synchronous and ambient reads remain Accessibility-only.
enum SelectedTextCapture {
    enum CaptureResult {
        case text(String)
        case permissionRequired
        case noSelection
    }

    /// Kept private so callers still see the intentionally small three-result
    /// contract above. A secure field is a distinct internal result because an
    /// empty Accessibility answer there must NEVER fall through to Command-C.
    private enum AXCaptureResult {
        case text(String)
        case permissionRequired
        case noSelection
        case secure
    }

    /// Eager representations from before the temporary copy. Pasteboard owners
    /// can offer several forms of one item (plain text, RTF, HTML, file URLs); keep
    /// all readable forms instead of restoring only a flattened string.
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
                for (type, data) in representations {
                    item.setData(data, forType: type)
                }
                return item
            }
            _ = pasteboard.writeObjects(restored)
        }
    }

    /// The one-shot read. Answers instantly from whatever tree exists right now —
    /// which is everything a native app needs, and (see `current(completion:)`)
    /// not always enough for web content.
    static func current(promptForPermission: Bool = true,
                        front: NSRunningApplication? = nil,
                        appScoped: Bool = false) -> CaptureResult {
        switch currentAX(promptForPermission: promptForPermission,
                         front: front,
                         appScoped: appScoped) {
        case .text(let selected): return .text(selected)
        case .permissionRequired: return .permissionRequired
        case .noSelection, .secure: return .noSelection
        }
    }

    private static func currentAX(promptForPermission: Bool,
                                  front: NSRunningApplication?,
                                  appScoped: Bool) -> AXCaptureResult {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptForPermission
        ] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            return .permissionRequired
        }

        guard let element = focusedElement(front: front, appScoped: appScoped) else {
            return selectionInFocusedWindow(of: front).map(AXCaptureResult.text) ?? .noSelection
        }

        switch selectionWalkingUp(from: element) {
        case .found(let selected): return .text(selected)
        case .secure: return .secure
        case .none: break
        }
        // Focus can sit on a node that owns no selection of its own and whose
        // ancestors are plain containers — a Chromium window whose tree has only
        // just been built puts focus on the window itself, with the selection on
        // the web area a level or two below. Sweep down for it.
        return selectionInFocusedWindow(of: front).map(AXCaptureResult.text) ?? .noSelection
    }

    /// The reliable read, for the prompt shortcut. Chromium and Electron ship with
    /// their web-content accessibility tree switched OFF and only build it once an
    /// assistive client asks — which is exactly why a shortcut fired over Chrome
    /// "sometimes" comes back empty: in a browser process nobody has queried yet,
    /// there is no tree to read, and the read that finds nothing is itself what
    /// turns it on (so the *next* chord works, and the bug reads as random).
    ///
    /// So: try once (native apps answer immediately and pay nothing). If that finds
    /// nothing, start waking the web tree and, while the source app still owns
    /// focus, run a short Command-C probe. That is the representation apps such as
    /// Preview, Office and non-standard web canvases most consistently support.
    /// The user's pasteboard is restored immediately and only if nobody else
    /// changed it during the probe. If copy still finds nothing, re-read the
    /// warming Accessibility tree on a background queue.
    ///
    /// `firstPassEmpty` fires on the main queue after the short copy probe also
    /// finds nothing, BEFORE the browser wake-up ladder runs. A caller that has
    /// something to put on screen either way can put it there then and take a late
    /// AX selection when it lands. `completion` always lands on the main queue and
    /// arrives exactly once.
    ///
    /// The re-reads are app-scoped precisely because of that: by then the caller
    /// has usually opened a window and taken focus, so the system-wide focused
    /// element is no longer the app the user pressed in.
    ///
    /// `pointedAt` is where a *pointed* gesture landed — a force click, which is
    /// aimed at a spot on screen the user can miss. It gates the Command-C probe
    /// (see `nothingToCopy(under:)`); a chord passes `nil`, because a chord is
    /// aimed at whatever owns focus and there is no meaningful pointer to read.
    static func current(promptForPermission: Bool = true,
                        pointedAt: NSPoint? = nil,
                        firstPassEmpty: (() -> Void)? = nil,
                        pasteboardDidChange: (() -> Void)? = nil,
                        completion: @escaping (CaptureResult) -> Void) {
        let front = NSWorkspace.shared.frontmostApplication
        let first = currentAX(promptForPermission: promptForPermission,
                              front: front,
                              appScoped: false)
        switch first {
        case .text(let selected):
            completion(.text(selected))
            return
        case .permissionRequired:
            completion(.permissionRequired)
            return
        case .secure:
            // Never synthesize Copy while a password field owns focus.
            completion(.noSelection)
            return
        case .noSelection:
            break
        }

        // Start Chromium/Electron's lazy tree in parallel with the copy probe.
        // If the probe fails, much of the tree's cold-start cost has already elapsed.
        DispatchQueue.global(qos: .userInitiated).async {
            enableWebAccessibility(for: front)
        }
        // What happens when no copied selection arrives: open on nothing, then keep
        // re-reading the tree that is still warming up.
        let keepReading = {
            firstPassEmpty?()
            DispatchQueue.global(qos: .userInitiated).async {
                for wait in webTreeRetryWaits {
                    Thread.sleep(forTimeInterval: wait)
                    switch currentAX(promptForPermission: false,
                                     front: front,
                                     appScoped: true) {
                    case .text(let selected):
                        DispatchQueue.main.async { completion(.text(selected)) }
                        return
                    case .secure:
                        DispatchQueue.main.async { completion(.noSelection) }
                        return
                    case .permissionRequired, .noSelection:
                        break
                    }
                }
                DispatchQueue.main.async { completion(.noSelection) }
            }
        }

        // A press that landed where there is provably nothing to copy never sends
        // Command-C — that key is what makes the error tone.
        if let pointedAt, nothingToCopy(under: pointedAt) { return keepReading() }

        copiedSelection(from: front) { copied, changedByProbe in
            if changedByProbe { pasteboardDidChange?() }
            if let copied {
                completion(.text(copied))
                return
            }
            keepReading()
        }
    }

    /// Is there provably nothing under the pointer for Command-C to copy?
    ///
    /// The probe below posts a real key equivalent into another app, and an app
    /// with nothing to copy does not ignore it: the keystroke falls off the end of
    /// its responder chain and the app sounds the system's error tone. That beep
    /// is what a force click on a blank stretch of a window made — the press still
    /// opened the composer (an empty Ask is a perfectly normal outcome), so the
    /// gesture worked and sounded like it had failed.
    ///
    /// Answers true only on positive evidence: a text surface that reports an
    /// empty selection, or something that owns no text at all. Anything
    /// unreadable — no element, no role, a cold web tree, a plain group — stays a
    /// probe, because that is exactly the case the probe exists for.
    private static func nothingToCopy(under pointer: NSPoint) -> Bool {
        // Accessibility hit-tests in flipped screen coordinates, measured from the
        // top of the primary display.
        guard let primary = NSScreen.screens.first else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(pointer.x),
                                               Float(primary.frame.maxY - pointer.y),
                                               &hit) == .success,
              let element = hit
        else { return false }
        AXUIElementSetMessagingTimeout(element, 0.2)
        if isSecureTextField(element) { return true }
        guard let role = attribute(kAXRoleAttribute, of: element) as? String
        else { return false }
        // A text surface owns its selection and answers for it, so an empty answer
        // here is the real thing rather than a tree that hasn't been built.
        if textRoles.contains(role) { return selectedText(in: element) == nil }
        return barrenRoles.contains(role)
    }

    private static let textRoles: Set<String> = [
        kAXTextAreaRole as String, kAXTextFieldRole as String,
        kAXComboBoxRole as String, "AXWebArea"
    ]

    /// Roles that hold no copyable text of their own. A press on one of these is
    /// the ordinary miss — the pointer was on a button, an icon, a scroller.
    private static let barrenRoles: Set<String> = [
        kAXButtonRole as String, kAXCheckBoxRole as String,
        kAXRadioButtonRole as String, kAXPopUpButtonRole as String,
        kAXMenuButtonRole as String, kAXImageRole as String,
        kAXSliderRole as String, kAXIncrementorRole as String,
        kAXProgressIndicatorRole as String, kAXScrollBarRole as String,
        kAXSplitterRole as String, kAXToolbarRole as String,
        kAXTabGroupRole as String, kAXDisclosureTriangleRole as String,
        kAXColorWellRole as String, kAXMenuRole as String,
        kAXMenuItemRole as String, kAXMenuBarRole as String,
        kAXMenuBarItemRole as String
    ]

    /// Bob-style selection fallback: preserve the complete pasteboard, replace it
    /// with a private sentinel, send Command-C to the still-frontmost source app,
    /// and wait briefly for that app to replace the sentinel. Restoration is
    /// conditional on `changeCount`, so a real clipboard change made by the user
    /// during the probe always wins.
    private static func copiedSelection(from front: NSRunningApplication?,
                                        completion: @escaping (String?, Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let front,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                == front.processIdentifier
        else { return completion(nil, false) }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)
        let markerType = NSPasteboard.PasteboardType("com.notchi.selected-text-probe")
        let marker = UUID().uuidString.data(using: .utf8)!
        pasteboard.clearContents()
        guard pasteboard.setData(marker, forType: markerType) else {
            snapshot.restore(to: pasteboard)
            return completion(nil, true)
        }
        let probeChangeCount = pasteboard.changeCount

        guard postCopyShortcut() else {
            let restored: Bool
            if pasteboard.changeCount == probeChangeCount {
                snapshot.restore(to: pasteboard)
                restored = true
            } else {
                restored = false
            }
            return completion(nil, restored)
        }

        let deadline = ProcessInfo.processInfo.systemUptime + Self.copyProbeDeadline
        func finish(_ selected: String?, observedChangeCount: Int) {
            let restored: Bool
            if pasteboard.changeCount == observedChangeCount {
                snapshot.restore(to: pasteboard)
                restored = true
            } else {
                restored = false
            }
            completion(selected, restored)
        }
        func poll() {
            // If the user moved to another app during the probe, stop observing.
            // Restore only when our sentinel is still the clipboard's last change;
            // any later content belongs to the user or another app.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == front.processIdentifier else {
                if pasteboard.changeCount == probeChangeCount {
                    snapshot.restore(to: pasteboard)
                    completion(nil, true)
                } else {
                    completion(nil, false)
                }
                return
            }

            let observed = pasteboard.changeCount
            if observed != probeChangeCount {
                let copied = pasteboard.string(forType: .string)
                let selected = copied.flatMap {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
                }
                finish(selected, observedChangeCount: observed)
                return
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                finish(nil, observedChangeCount: probeChangeCount)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.copyProbeInterval,
                                          execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.copyProbeFirstPoll,
                                      execute: poll)
    }

    /// How long the Command-C probe waits for the source app to answer.
    ///
    /// This is dead time the user watches: a press that lands on *no* selection
    /// never gets an answer, so it burns the whole budget before the composer is
    /// allowed to open. The old 0.32s was set to be generous, and it is what a
    /// force click on blank space felt like.
    private static let copyProbeDeadline: TimeInterval = 0.15
    /// When to look for the first time.
    ///
    /// Measured, not guessed: the fastest responder that can exist — a second
    /// process holding a real NSTextView selection, answering ⌘C through the
    /// normal key-equivalent path — answers in **31–40ms** (p50 ≈ 35ms, 40 runs).
    /// Most of that is the synthetic key's trip through the HID event tap and the
    /// window server, which every app pays before its own copy path even starts,
    /// so nothing can beat it. Looking at 15ms was therefore always a wasted pass,
    /// and looking sooner would only add more of them; the win is the opposite —
    /// start just under the floor, then sample tightly, so a 32ms answer is seen
    /// at ~36ms instead of at the old grid's 45ms.
    private static let copyProbeFirstPoll: TimeInterval = 0.024
    private static let copyProbeInterval: TimeInterval = 0.006

    private static func postCopyShortcut() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: CGKeyCode(kVK_ANSI_C),
                                 keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(kVK_ANSI_C),
                               keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// The **ambient** read, for the panel opening on its own rather than on a
    /// chord aimed at a selection. Same bounded lookup, three deliberate
    /// differences — because this one runs on *every* open, unasked:
    ///
    ///   · **Never prompts.** Accessibility not granted → nothing happens, quietly.
    ///     Summoning the notch is not the moment to demand a privacy permission.
    ///   · **Never wakes a browser's tree.** No `AXManualAccessibility`, no retry
    ///     ladder: `current(completion:)` turns Chromium's web-content tree on to
    ///     make a shortcut reliable, which is a cost worth paying for a gesture the
    ///     user aimed. Paying it on every summon would tax their browser forever
    ///     for a convenience they may never use. One pass, whatever is already there.
    ///   · **Reads the app, not the system.** By the time this answers, the panel
    ///     has activated and the system-wide focused element is Notchi's own prompt
    ///     field — so the lookup starts from `front`'s application element instead.
    ///     Off the main thread, so a wedged app's AX timeouts can't stall the open.
    ///
    /// `completion` always lands on the main queue; `nil` means "nothing to carry".
    static func ambient(front: NSRunningApplication?,
                        completion: @escaping (String?) -> Void) {
        guard let front,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              AXIsProcessTrusted()
        else { return completion(nil) }
        DispatchQueue.global(qos: .userInitiated).async {
            let selected = selection(ownedBy: front)
            DispatchQueue.main.async { completion(selected) }
        }
    }

    /// One app's selection, read without consulting the system-wide focused
    /// element (see `ambient`). Its focused node first, then the same bounded
    /// sweep of its focused window that covers a browser whose focus sits on the
    /// window itself.
    private static func selection(ownedBy app: NSRunningApplication) -> String? {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        if let focused = axElement(attribute(kAXFocusedUIElementAttribute, of: application)) {
            switch selectionWalkingUp(from: focused) {
            case .found(let selected): return selected
            case .secure: return nil
            case .none: break
            }
        }
        return selectionInFocusedWindow(of: app)
    }

    private enum Walk {
        case found(String)
        /// A password field owned the focus — the walk stops dead (see below).
        case secure
        case none
    }

    /// The selected-text representation is often owned by the focused node's
    /// WebArea/scroll-area parent rather than the leaf itself. Walk upward only
    /// (bounded) — scanning a whole browser accessibility tree can contain tens
    /// of thousands of nodes and would make a shortcut visibly stall.
    private static func selectionWalkingUp(from start: AXUIElement) -> Walk {
        var element = start
        for _ in 0..<12 {
            AXUIElementSetMessagingTimeout(element, 0.25)

            // Secure text fields must never become model input. Stop entirely,
            // rather than walking to a parent that might expose the same value in
            // a less explicitly protected representation.
            if isSecureTextField(element) { return .secure }
            if let selected = selectedText(in: element) { return .found(selected) }

            guard let parent = axElement(attribute(kAXParentAttribute, of: element)),
                  !CFEqual(parent, element)
            else { break }
            element = parent
        }
        return .none
    }

    /// Gaps between re-reads while a web tree is being built — tight at first (an
    /// already-warm renderer answers in one hop), spreading out to cover a cold
    /// browser process. ~0.8s in total, and only ever paid on the path that
    /// currently returns nothing at all.
    private static let webTreeRetryWaits: [TimeInterval] = [0.06, 0.09, 0.15, 0.2, 0.3]

    /// Chromium's documented opt-in for non-VoiceOver assistive clients: setting
    /// `AXManualAccessibility` on the application element makes it build the web
    /// content tree. Electron inherits it. A native app answers "unsupported", so
    /// this is safe to set blind rather than sniffing bundle identifiers — and it
    /// is only ever sent to an app whose selection the user just asked for, so no
    /// browser pays the cost of an always-on tree for a feature they never use.
    private static func enableWebAccessibility(for app: NSRunningApplication?) {
        guard let app else { return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString,
                                     kCFBooleanTrue)
    }

    /// Bounded top-down sweep of the front app's focused window for a node that
    /// owns a selection. Strictly capped (breadth, depth, and total nodes visited):
    /// a web area sits one to three levels under the window, while an uncapped walk
    /// of a browser tree is tens of thousands of nodes and would stall the chord.
    private static func selectionInFocusedWindow(of app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let window = axElement(attribute(kAXFocusedWindowAttribute, of: application))
                ?? axElement(attribute(kAXMainWindowAttribute, of: application))
        else { return nil }

        var frontier = [window]
        var visited = 0
        for _ in 0..<5 {
            var next: [AXUIElement] = []
            for element in frontier {
                visited += 1
                if visited > 60 { return nil }
                AXUIElementSetMessagingTimeout(element, 0.25)
                if isSecureTextField(element) { continue }
                if let selected = selectedText(in: element) { return selected }
                guard let children = attribute(kAXChildrenAttribute, of: element) as? [AnyObject]
                else { continue }
                for child in children.prefix(12) {
                    if let element = axElement(child as CFTypeRef) { next.append(element) }
                }
            }
            if next.isEmpty { return nil }
            frontier = Array(next.prefix(20))
        }
        return nil
    }

    /// Resolve the element that belonged to the foreground app at the instant the
    /// global shortcut fired. The system-wide focused element is the fast path;
    /// the application-level query covers frameworks that omit it there.
    /// `appScoped` skips the system-wide focused element and asks `front`
    /// directly. That matters for a re-read that happens AFTER Notchi has taken
    /// focus (the deferred half of `current(firstPassEmpty:completion:)`): the
    /// system-wide focus is then Notchi's own field, so the system-wide answer
    /// would be our composer's empty box rather than the selection we are still
    /// looking for.
    private static func focusedElement(front: NSRunningApplication? = nil,
                                       appScoped: Bool = false) -> AXUIElement? {
        if !appScoped {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.25)
            if let focused = axElement(attribute(kAXFocusedUIElementAttribute, of: system)) {
                return focused
            }
        }
        guard let app = front ?? NSWorkspace.shared.frontmostApplication else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        return axElement(attribute(kAXFocusedUIElementAttribute, of: application))
    }

    private static func isSecureTextField(_ element: AXUIElement) -> Bool {
        (attribute(kAXSubroleAttribute, of: element) as? String)
            == (kAXSecureTextFieldSubrole as String)
    }

    /// Read each representation used by macOS text providers. The public range
    /// API covers native editors that omit `AXSelectedText`; WebKit/Chromium expose
    /// their document selection as a text-marker range instead.
    private static func selectedText(in element: AXUIElement) -> String? {
        if let selected = nonEmptyString(attribute(kAXSelectedTextAttribute, of: element)) {
            return selected
        }

        if let range = attribute(kAXSelectedTextRangeAttribute, of: element),
           let selected = string(forCharacterRange: range, in: element) {
            return selected
        }

        if let ranges = attribute(kAXSelectedTextRangesAttribute, of: element) as? [Any] {
            let selections = ranges.compactMap { item -> String? in
                string(forCharacterRange: item as CFTypeRef, in: element)
            }
            let combined = selections.joined(separator: "\n")
            if !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return combined
            }
        }

        // Text-marker attributes are the representation used by web content.
        // Their names are stable Accessibility protocol names, but are not exposed
        // as constants in the macOS 14 SDK.
        if let markerRange = attribute("AXSelectedTextMarkerRange", of: element) {
            if let selected = nonEmptyString(parameterizedAttribute(
                "AXStringForTextMarkerRange", parameter: markerRange, of: element
            )) {
                return selected
            }
            if let selected = nonEmptyString(parameterizedAttribute(
                "AXAttributedStringForTextMarkerRange", parameter: markerRange, of: element
            )) {
                return selected
            }
        }
        return nil
    }

    private static func string(forCharacterRange range: CFTypeRef,
                               in element: AXUIElement) -> String? {
        if let selected = nonEmptyString(parameterizedAttribute(
            kAXStringForRangeParameterizedAttribute, parameter: range, of: element
        )) {
            return selected
        }
        if let selected = nonEmptyString(parameterizedAttribute(
            kAXAttributedStringForRangeParameterizedAttribute, parameter: range, of: element
        )) {
            return selected
        }

        // Some third-party controls expose the range and full value but omit the
        // parameterized substring attribute. Slice their value as a final public-
        // API fallback, using NSString because AX ranges are UTF-16 character ranges.
        guard let value = attribute(kAXValueAttribute, of: element) as? String,
              let selectedRange = cfRange(from: range),
              selectedRange.location >= 0, selectedRange.length > 0
        else { return nil }
        let string = value as NSString
        guard selectedRange.location <= string.length,
              selectedRange.length <= string.length - selectedRange.location
        else { return nil }
        let selected = string.substring(with: NSRange(
            location: selectedRange.location, length: selectedRange.length
        ))
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return selected
    }

    private static func cfRange(from value: CFTypeRef) -> CFRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func nonEmptyString(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        let string: String?
        if let plain = value as? String {
            string = plain
        } else if let attributed = value as? NSAttributedString {
            string = attributed.string
        } else {
            string = nil
        }
        guard let string,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return string
    }

    private static func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value
    }

    private static func parameterizedAttribute(_ name: String, parameter: CFTypeRef,
                                               of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, name as CFString, parameter, &value
        ) == .success else { return nil }
        return value
    }
}

/// Prompt-flow keys whose meaning is structural rather than personal. Keeping
/// these fixed preserves the fast keyboard grammar of the composer and prevents
/// editable actions (including the global summon chord) from claiming them.
enum ReservedAppShortcut {
    static let sendOther = ShortcutChord(keyCode: UInt32(kVK_Return),
                                         modifiers: UInt32(cmdKey))
    static let cycleIntent = ShortcutChord(keyCode: UInt32(kVK_Tab), modifiers: 0)
    static let bucket = ShortcutChord(keyCode: UInt32(kVK_Tab), modifiers: UInt32(shiftKey))
}

/// Product actions whose chords are useful to personalize. Editing conventions
/// such as Return to submit, arrows to move/recall, `/` to open commands, and
/// ⌘V to paste stay fixed: changing those would make the prompt stop behaving
/// like a Mac text field.
enum AppShortcutAction: String, CaseIterable, Identifiable, Hashable {
    case copyAnswer
    case regenerate
    case pin
    case newChat
    case filter
    case picker
    case detach

    var id: String { rawValue }

    var label: String {
        switch self {
        case .copyAnswer:  return L("shortcuts.copyAnswer")
        case .regenerate:  return L("shortcuts.regenerate")
        case .pin:         return L("shortcuts.pin")
        case .newChat:     return L("shortcuts.newChat")
        case .filter:      return L("shortcuts.filter")
        case .picker:      return L("shortcuts.picker")
        case .detach:      return L("shortcuts.detach")
        }
    }

    /// The stable snake_case id the settings tool speaks — chat can say
    /// "copy_answer" in any interface language and land on the same action the
    /// Shortcuts pane edits. Never localized, never renamed.
    var token: String {
        switch self {
        case .copyAnswer: return "copy_answer"
        case .regenerate: return "regenerate"
        case .pin:        return "pin"
        case .newChat:    return "new_chat"
        case .filter:     return "filter"
        case .picker:     return "picker"
        case .detach:     return "detach"
        }
    }

    /// Accepts the canonical token plus the spellings a model reaches for first.
    static func parse(_ raw: String) -> AppShortcutAction? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch token {
        case "copy_answer", "copyanswer", "copy": return .copyAnswer
        case "regenerate", "retry": return .regenerate
        case "pin": return .pin
        case "new_chat", "newchat", "new": return .newChat
        case "filter", "search": return .filter
        case "picker", "model_picker", "modelpicker": return .picker
        case "detach", "detached_window": return .detach
        default: return nil
        }
    }

    var defaultChord: ShortcutChord {
        switch self {
        case .copyAnswer:  return ShortcutChord(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey))
        case .regenerate:  return ShortcutChord(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey))
        case .pin:         return ShortcutChord(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey))
        case .newChat:     return ShortcutChord(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey))
        case .filter:      return ShortcutChord(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey))
        case .picker:
            return ShortcutChord(keyCode: UInt32(kVK_ANSI_I),
                                 modifiers: UInt32(cmdKey) | UInt32(shiftKey))
        case .detach:
            return ShortcutChord(keyCode: UInt32(kVK_ANSI_Equal),
                                 modifiers: UInt32(controlKey) | UInt32(shiftKey))
        }
    }
}

/// Persistence and validation for all in-app editable shortcuts. Each action is
/// stored independently so future actions can be added without migrating a
/// serialized blob. Validation is shared by the UI and intent-driven settings
/// changes, preventing two paths from accepting different combinations.
enum AppShortcutStore {
    private static let prefix = "appShortcut."
    /// Key events arrive for every character typed. Keep the resolved values in
    /// memory instead of consulting `UserDefaults` up to ten times per key-down;
    /// all writes flow through `set`/`reset`, which update this cache in lockstep.
    private static var cache: [AppShortcutAction: ShortcutChord] =
        Dictionary(uniqueKeysWithValues: AppShortcutAction.allCases.map {
            ($0, storedChord(for: $0))
        })

    static func chord(for action: AppShortcutAction) -> ShortcutChord {
        cache[action] ?? action.defaultChord
    }

    private static func storedChord(for action: AppShortcutAction) -> ShortcutChord {
        let defaults = UserDefaults.standard
        let base = prefix + action.rawValue
        guard defaults.object(forKey: base + ".keyCode") != nil else {
            return action.defaultChord
        }
        return ShortcutChord(
            keyCode: UInt32(bitPattern: Int32(defaults.integer(forKey: base + ".keyCode"))),
            modifiers: UInt32(bitPattern: Int32(defaults.integer(forKey: base + ".modifiers")))
        )
    }

    static var current: [AppShortcutAction: ShortcutChord] {
        cache
    }

    static func set(_ chord: ShortcutChord, for action: AppShortcutAction) {
        let base = prefix + action.rawValue
        UserDefaults.standard.set(Int(Int32(bitPattern: chord.keyCode)), forKey: base + ".keyCode")
        UserDefaults.standard.set(Int(Int32(bitPattern: chord.modifiers)), forKey: base + ".modifiers")
        cache[action] = chord
    }

    static func reset(_ action: AppShortcutAction) {
        let base = prefix + action.rawValue
        UserDefaults.standard.removeObject(forKey: base + ".keyCode")
        UserDefaults.standard.removeObject(forKey: base + ".modifiers")
        cache[action] = action.defaultChord
    }

    static func matches(_ action: AppShortcutAction, event: NSEvent) -> Bool {
        chord(for: action).matches(event)
    }

    /// Returns the name of the existing owner when a chord cannot be assigned.
    /// `nil` means it is safe to commit.
    static func conflictOwner(
        for proposed: ShortcutChord,
        editingAction: AppShortcutAction? = nil,
        editingSummon: Bool = false
    ) -> String? {
        // Fixed app commands which must retain their conventional meaning.
        let fixed: [(ShortcutChord, String)] = [
            (ReservedAppShortcut.sendOther, L("shortcuts.sendOther")),
            (ReservedAppShortcut.cycleIntent, L("shortcuts.cycleIntent")),
            (ReservedAppShortcut.bucket, L("shortcuts.bucket")),
            (ShortcutChord(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(cmdKey)),
             L("shortcuts.reserved.settings")),
            (ShortcutChord(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey)),
             L("shortcuts.pasteImage")),
        ]
        if let match = fixed.first(where: { $0.0 == proposed }) { return match.1 }

        // Combinations owned by macOS or the standard app/window menu should not
        // become a control that appears editable but never fires reliably.
        let systemReserved: [ShortcutChord] = [
            ShortcutChord(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey)),
            ShortcutChord(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey)),
            ShortcutChord(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey)),
            ShortcutChord(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey)),
            ShortcutChord(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)),
            ShortcutChord(keyCode: UInt32(kVK_Space),
                          modifiers: UInt32(cmdKey) | UInt32(optionKey)),
            ShortcutChord(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey)),
            ShortcutChord(keyCode: UInt32(kVK_Tab),
                          modifiers: UInt32(cmdKey) | UInt32(shiftKey)),
            ShortcutChord(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(controlKey)),
            ShortcutChord(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(controlKey)),
            ShortcutChord(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(controlKey)),
            ShortcutChord(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(controlKey)),
            ShortcutChord(keyCode: UInt32(kVK_ANSI_Q),
                          modifiers: UInt32(controlKey) | UInt32(cmdKey)),
        ]
        if systemReserved.contains(proposed) { return L("shortcuts.reserved.system") }

        for action in AppShortcutAction.allCases where action != editingAction {
            if chord(for: action) == proposed { return action.label }
        }

        let summon = SummonHotKey.current
        if !editingSummon, summon.enabled {
            if let modifier = proposed.doubleTapModifier,
               summon.isDoubleTap, summon.doubleTapModifier == modifier {
                return L("shortcuts.summon")
            }
            if !proposed.isDoubleTap, !summon.isDoubleTap,
               ShortcutChord(keyCode: summon.keyCode, modifiers: summon.modifiers) == proposed {
                return L("shortcuts.summon")
            }
        }
        return nil
    }
}

enum EditableShortcut: Hashable {
    case summon
    case action(AppShortcutAction)
    case prompt(UUID)
}

/// Replaces a legacy, hard-coded trailing chord in localized tooltip copy with
/// the action's live chord. This preserves the existing translation while making
/// every affordance agree with the Shortcuts settings pane immediately.
func shortcutHelp(_ localizationKey: String, action: AppShortcutAction) -> String {
    var base = L(localizationKey)
    if base.hasSuffix(")"), let open = base.lastIndex(of: "(") {
        base = String(base[..<open]).trimmingCharacters(in: .whitespaces)
    } else if base.hasSuffix("）"), let open = base.lastIndex(of: "（") {
        base = String(base[..<open]).trimmingCharacters(in: .whitespaces)
    }
    return "\(base) (\(AppShortcutStore.chord(for: action).displayString))"
}

/// The single source of truth for the keyboard-shortcut reference shown both in
/// Settings and to the model when somebody asks about shortcuts in chat. Keep
/// fixed chords here beside the one live, user-configurable summon shortcut so
/// those two surfaces can never drift apart.
struct AppShortcutReference {
    struct Group {
        let title: String
        let entries: [Entry]
    }

    struct Entry {
        let label: String
        let chords: [String]
        let editable: EditableShortcut?
        /// Shown instead of keycaps when the shortcut is currently disabled.
        let note: String?

        init(_ label: String, _ chords: [String], note: String? = nil,
             editable: EditableShortcut? = nil) {
            self.label = label
            self.chords = chords
            self.note = note
            self.editable = editable
        }
    }

    static func groups(
        summonHotKey: SummonHotKey = .current,
        shortcuts: [AppShortcutAction: ShortcutChord] = AppShortcutStore.current
    ) -> [Group] {
        func editable(_ action: AppShortcutAction) -> Entry {
            Entry(action.label,
                  [(shortcuts[action] ?? action.defaultChord).displayString],
                  editable: .action(action))
        }
        return [
            Group(title: L("shortcuts.group.summon"), entries: [
                Entry(L("shortcuts.summon"),
                      summonHotKey.enabled ? [summonHotKey.displayString] : [],
                      note: summonHotKey.enabled ? nil : L("general.shortcut.off"),
                      editable: .summon),
            ]),
            Group(title: L("shortcuts.group.prompt"), entries: [
                Entry(L("shortcuts.send"), ["↵"]),
                Entry(L("shortcuts.sendOther"), [ReservedAppShortcut.sendOther.displayString]),
                Entry(L("shortcuts.cycleIntent"), [ReservedAppShortcut.cycleIntent.displayString]),
                Entry(L("shortcuts.bucket"), [ReservedAppShortcut.bucket.displayString]),
                Entry(L("shortcuts.recall"), ["↑", "↓"]),
                Entry(L("shortcuts.slash"), ["/"]),
                Entry(L("shortcuts.pasteImage"), ["⌘V"]),
            ]),
            Group(title: L("shortcuts.group.answer"), entries: [
                editable(.copyAnswer),
                editable(.regenerate),
                editable(.pin),
                editable(.newChat),
                Entry(L("shortcuts.back"), ["←"]),
            ]),
            Group(title: L("shortcuts.group.panel"), entries: [
                editable(.filter),
                editable(.picker),
                editable(.detach),
            ]),
        ]
    }
}
