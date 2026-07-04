import AppKit
import QuartzCore

/// Keeps a tiny ring buffer of recent global mouse positions so that the moment
/// a hover opens the island we can ask "how was the cursor moving just before it
/// arrived?" — the entry vector that lets the unfurl inherit the mouse's
/// momentum (see `NotchIsland`'s entry kick).
///
/// Sampling has to run *before* the hover fires: `.onHover` only reports the
/// instant the cursor touches the island shape, by which time the approach is
/// already history. So this listens to mouse-moved events app-wide via NSEvent
/// monitors — the global monitor covers movement over other apps' windows, the
/// local one covers our own panels. Mouse-move monitors need no Accessibility /
/// Input Monitoring permission (that gate is for keyboards), and each event
/// costs one append to a small array, so the tracker is effectively free.
@MainActor
final class MouseVelocityTracker {
    static let shared = MouseVelocityTracker()

    private struct Sample {
        var t: TimeInterval
        var p: CGPoint   // AppKit global coords: origin bottom-left, +y up
    }

    /// How far back the velocity read looks. Long enough to smooth out jitter,
    /// short enough that an earlier flick across the screen doesn't bleed into
    /// the entry reading.
    private let window: TimeInterval = 0.12

    private var samples: [Sample] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private init() {}

    /// Install the mouse-moved monitors. Idempotent — called once at launch.
    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { _ in
            // NSEvent monitors deliver on the main thread; hop is a formality
            // for the compiler, not a real thread switch.
            MainActor.assumeIsolated {
                MouseVelocityTracker.shared.record()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            MainActor.assumeIsolated {
                MouseVelocityTracker.shared.record()
            }
            return event
        }
    }

    private func record() {
        samples.append(Sample(t: CACurrentMediaTime(), p: NSEvent.mouseLocation))
        // Batch-trim so the steady drip of move events never grows the buffer
        // unbounded, without paying a removeFirst on every event.
        if samples.count > 200 {
            samples.removeFirst(100)
        }
    }

    /// Whether the cursor has genuinely moved within the last `window` seconds
    /// (net displacement above `threshold` points). This is what tells a hover
    /// EXIT apart by cause: "the pointer crossed the boundary" (it was moving —
    /// fold the panel) versus "the boundary shrank away from a parked pointer"
    /// (⌘N folding a tall thread back to the short idle prompt, a list
    /// collapsing — the user didn't leave; don't fold). Move monitors only fire
    /// on movement, so a parked cursor simply has no recent samples.
    func cursorMoved(within window: TimeInterval, threshold: CGFloat = 3) -> Bool {
        let now = CACurrentMediaTime()
        let recent = samples.filter { now - $0.t <= window }
        guard let first = recent.first, let last = recent.last else { return false }
        let dx = last.p.x - first.p.x
        let dy = last.p.y - first.p.y
        return (dx * dx + dy * dy).squareRoot() >= threshold
    }

    /// The cursor's velocity over the last ~120ms, in *SwiftUI* orientation
    /// (+x right, +y down), points/second. `.zero` when there isn't enough
    /// recent movement to read a direction — which downstream renders as the
    /// standard calm unfurl, so a missing reading can never look broken.
    func entryVelocity() -> CGVector {
        let now = CACurrentMediaTime()
        let recent = samples.filter { now - $0.t <= window }
        guard let first = recent.first, let last = recent.last else { return .zero }
        let dt = last.t - first.t
        // Below ~20ms of span the division amplifies sensor noise into wild
        // speeds; treat it as "no reading" instead.
        guard dt >= 0.02 else { return .zero }
        return CGVector(
            dx: (last.p.x - first.p.x) / dt,
            dy: -(last.p.y - first.p.y) / dt   // flip AppKit's +y-up to SwiftUI's +y-down
        )
    }
}
