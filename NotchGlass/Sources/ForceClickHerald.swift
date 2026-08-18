import AppKit
import SwiftUI

/// What a force click looks like while it is still being decided — and how it
/// turns into the composer.
///
/// The gesture used to be invisible until the instant it fired: nothing on screen
/// said "keep pushing", "that was enough", or "that wasn't" — so pressing read as
/// a coin flip, and a press that fell just short felt like the app had ignored it.
///
/// **There is exactly one glass surface for the whole gesture: the composer's own
/// input capsule.** This object does not draw anything. It owns no window, no
/// panel and no view — it converts the trackpad's pressure stream into calls on
/// the real composer window, which is born at the press and stretches into itself
/// when the press fires.
///
/// That is not a refactor for tidiness; it is the whole fix. The cue used to be a
/// second `.screenSaver`-level panel drawing the same capsule, which handed over
/// to the window once it had stretched. Two Liquid Glass surfaces cannot hand over
/// invisibly: `.clear` glass multiplies, so the frames where both stood measured
/// 47/255 against 94 for either alone — a pill more than twice as dark as the
/// thing on both sides of the swap. That flash read as "the panel opened opaque",
/// and the cue's 0.13s fade-out then read as "…and only now turns into glass".
/// Neither was an animation anyone wrote. One surface has nothing to hand over.
///
/// The press phase is driven straight from the trackpad's ~125Hz pressure frames
/// through the hosting layer's transform, with implicit animation off: the
/// pressure stream *is* the animation, and neither Core Animation interpolation
/// nor a SwiftUI re-layout per frame belongs between the finger and the screen.
/// The stretch is the one part that animates on its own, because it is the one
/// part the finger isn't driving.
@MainActor
final class ForceClickHerald {
    static let shared = ForceClickHerald()

    /// Below this fraction of the threshold nothing is drawn. Every ordinary click
    /// passes through the bottom of the pressure range, and a cue that blinked on
    /// each of those would be far worse than no cue at all.
    private static let floor: Double = 0.32
    /// Off. The growing cap read as a stray pill often enough that it explained
    /// less than it interrupted; a press now stays invisible until it fires, and
    /// the fire path (`expand` with no live window, `whenExpanded` un-latched)
    /// degrades on its own to the composer's normal pointer entrance. The drawing
    /// path below stays dormant rather than deleted, same deal as
    /// `ForceClickFeature`.
    private static let drawsCue = false
    /// The cap's diameter at `floor`, as a fraction of its full size — a cursor's
    /// worth of ink, so it reads as the pointer thickening rather than as a window
    /// opening.
    static let seedScale: Double = 0.3
    /// The stretch: a real spring with a little overshoot, so the trailing edge
    /// arrives like liquid finding its shape instead of a box being resized.
    static let stretch = SwiftUI.Animation.spring(response: 0.4,
                                                  dampingFraction: 0.74)
    /// How long that spring needs before the shape is settled enough to let the
    /// captured selection land in it.
    private static let stretchSettle: TimeInterval = 0.42

    /// The composer being pressed into existence. Weak: the window owns itself and
    /// may be closed from anywhere (Escape, ⌘W, another shortcut retiring it).
    private weak var composer: DetachedSessionWindowController?
    /// The last depth pushed to the window — the pressure stream repeats itself and
    /// re-writing identical geometry every frame is pure cost.
    private var shown: Double = 0
    /// Set from the moment the press fires until the selection has landed, so a
    /// trailing pressure frame or the mouse-up that follows can't retract a capsule
    /// that is already stretching.
    private var stretching = false
    /// Work waiting on the stretch to settle — the selection, which may otherwise
    /// be ready earlier (a native app's selection answers instantly).
    private var pendingHandoff: (() -> Void)?
    private var settleAt: Date?

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// True while the press owns the screen — the composer skips its own entrance
    /// in that case, because its capsule is already standing there.
    var isPresenting: Bool { composer?.isDrawingPressure == true }

    // MARK: - The press

    /// Report how far the current press has come, 0…1, where 1 is the pressure
    /// that fires. Called for every trackpad frame while the button is held.
    func update(progress: Double, model: NotchModel) {
        dropStaleStretch()
        guard Self.drawsCue, !stretching, !reduceMotion else { return }
        let t = (progress - Self.floor) / (1 - Self.floor)
        guard t > 0 else {
            if shown > 0 { retract() }
            return
        }
        let clamped = min(1, t)
        let eased = clamped * clamped * (3 - 2 * clamped) // smoothstep
        let pointer = NSEvent.mouseLocation
        guard let c = composer ?? Self.begin(model: model, at: pointer) else { return }
        composer = c
        guard abs(eased - shown) > 0.004 || !c.isDrawingPressure else { return }
        shown = eased
        c.drawPressure(eased, at: pointer)
    }

    /// Open the composer in its pressure phase, unless something says this press
    /// must not draw one.
    private static func begin(model: NotchModel, at pointer: NSPoint)
        -> DetachedSessionWindowController? {
        // A shortcut configured to answer in the notch is not opening anything at
        // the pointer, so there is nothing here for a press to grow into. Drawing
        // the capsule anyway would mean building a window purely to throw it away
        // (which is what the old cue did, via `abort`).
        guard SelectedTextShortcutStore.current.opensInPointerWindow else { return nil }
        return DetachedSessionWindowController.beginPressureComposer(
            shortcutID: SelectedTextShortcutStore.actionID, model: model, at: pointer)
    }

    /// The press ended without firing (or the fingers left the pad). The capsule
    /// retreats the way it came — falling short is information too.
    func cancel() {
        dropStaleStretch()
        guard !stretching else { return }
        retract()
    }

    /// `stretching` latches the press stream out so a trailing pressure frame can't
    /// retract a capsule that is already on its way into a window. It is only ever
    /// legitimate while the shape is ON SCREEN — if the window is gone and the flag
    /// is still set, some path let go without saying so, and keeping the latch
    /// would kill the cue for the rest of the session.
    private func dropStaleStretch() {
        guard stretching, composer?.isPressureAlive != true else { return }
        stretching = false
        pendingHandoff = nil
        settleAt = nil
        shown = 0
        composer = nil
    }

    // MARK: - The stretch

    /// The press fired. Stretch the cap out into the full capsule — the same
    /// capsule, in the same window, so there is no handover to hide.
    func expand() {
        guard !reduceMotion, let c = composer, c.isDrawingPressure else { return }
        stretching = true
        settleAt = Date().addingTimeInterval(Self.stretchSettle)
        c.openFromPressure()
    }

    /// Run `handoff` once the stretched capsule is standing at its full geometry,
    /// so the selection's badge and field arrive into a shape that has stopped
    /// moving. Runs immediately if no press is up (keyboard chord, Reduce Motion, a
    /// press that was already dismissed).
    func whenExpanded(_ handoff: @escaping () -> Void) {
        guard stretching, let settleAt else { return handoff() }
        let wait = settleAt.timeIntervalSinceNow
        guard wait > 0 else { return handoff() }
        pendingHandoff = handoff
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, let pending = self.pendingHandoff else { return }
            self.pendingHandoff = nil
            pending()
        }
    }

    /// The press fired, but nothing is going to open after all — no selection under
    /// the pointer, accessibility denied, another capture already running. Let the
    /// stretch go and take the capsule back off screen.
    ///
    /// This is not a nicety. The window is opened *before* anyone knows whether
    /// there is a selection, it ignores mouse events and holds no focus while the
    /// press is being decided: left standing it is a capsule on top of every window
    /// that takes no click and no key. And `stretching` latches out `update`/
    /// `cancel`, so every later press would be dead too.
    func abort() {
        pendingHandoff = nil
        settleAt = nil
        stretching = false
        shown = 0
        guard let c = composer else { return }
        composer = nil
        // Collapse back to the cap as it fades, so a press that found nothing reads
        // as the capsule letting go — the same way falling short does.
        c.dismissPressure(collapsing: true)
    }

    /// The selection landed and the window is a real composer now. Nothing is
    /// swapped and nothing is faded: the capsule the press stretched IS the
    /// composer's capsule, so this only drops the bookkeeping.
    func handOff() {
        pendingHandoff = nil
        settleAt = nil
        stretching = false
        shown = 0
        composer = nil
    }

    private func retract() {
        shown = 0
        guard let c = composer else { return }
        composer = nil
        c.dismissPressure(collapsing: false)
    }
}
