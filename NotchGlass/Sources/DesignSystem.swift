import AppKit
import SwiftUI

/// The one type + color system the whole notch references — a direct port of the
/// prototype's tokens (native San Francisco + a 4-level label scale that mirrors
/// macOS dark-mode label opacities). Nothing in the UI uses ad-hoc rgba values.
enum Tokens {
    /// Base "ink" for all text — a clean near-white. The idle prompt and labels
    /// live in the *upper, dark* part of the panel, so the scale is kept bright:
    /// opacity-on-dark below ~0.7 turns to muddy gray (the washed-out look we're
    /// fixing). Every level derives from this one ink so the text reads as one
    /// family, but no level drops so far that it greys out against the glass.
    static let ink = Color.white

    // Label scale — one ink, four levels (label / secondary / tertiary /
    // quaternary). Tuned brighter than stock macOS because our surface goes from
    // near-black at top to translucent glass at the bottom, and text must stay
    // crisp across both — a flat dim gray reads as broken on this material.
    static let text1 = ink.opacity(0.96)   // primary content (answers)
    static let text2 = ink.opacity(0.74)   // secondary (question echo)
    static let text3 = ink.opacity(0.55)   // labels (RECENT / Recent)
    static let text4 = ink.opacity(0.40)   // meta (timestamps)
    static let hairline = Color.white.opacity(0.12)

    // MARK: Recessed surface
    //
    // The flat chip surface worn by controls that sit INSIDE a panel rather than
    // floating on it — the settings menus, the onboarding connect cards, the
    // "set up a model" card, the follow-up composer box. (Controls that float ON
    // the glass — the round icon chips, the filter pills, the send button — wear
    // `glassCapsule` instead; that's a different, translucent species.)
    //
    // Two states, one recipe: a faint white floor with a hairline rim at rest,
    // both lifting together when the control is hovered/focused. Every site used
    // to carry its own hand-picked pair (0.05/0.06 floors, 0.10/0.12/0.16 rims,
    // 0.20/0.22/0.24 lit rims) — near-identical numbers that read as drift, not
    // as intent. Route new recessed controls through `recessedSurface`.
    static let recessFill    = Color.white.opacity(0.06)
    static let recessFillLit = Color.white.opacity(0.10)
    static let recessRim     = Color.white.opacity(0.12)
    static let recessRimLit  = Color.white.opacity(0.22)

    /// The same surface one step louder, for the *primary* action of a screen —
    /// the onboarding's Next/Ask, Settings' "Connect OpenRouter". One rung above
    /// the recessed rest so the eye lands on it first, and — unlike before — it
    /// still answers a hover, which those two buttons alone in the app did not.
    static let prominentFill    = Color.white.opacity(0.12)
    static let prominentFillLit = Color.white.opacity(0.18)
    static let prominentRim     = Color.white.opacity(0.22)
    static let prominentRimLit  = Color.white.opacity(0.32)

    /// The one duration every *chip's* hover brighten runs at — buttons, pills,
    /// glass capsules, the ⓘ marks. Long enough to read as a fade rather than a
    /// flick, short enough to feel immediate.
    static let hoverFade: TimeInterval = 0.18
    /// The faster twin, for *list rows* — Recent, the archive, the settings
    /// sidebar, the model pickers. A cursor sweeping a list crosses several rows a
    /// second, so the wash has to keep up; at chip speed it smears behind the
    /// pointer. (These two used to be five values between 0.12 and 0.18, assigned
    /// per-site rather than per-species.)
    static let rowFade: TimeInterval = 0.12

    // Danger accent — used sparingly for genuine errors and destructive actions
    // (update failure, a destructive menu item). Success/confirmation states stay
    // neutral ink instead: no coloured dots, no green pills.
    static let danger  = Color(red: 1.00, green: 0.42, blue: 0.42)

    // Connect accent — the one positive-action tint, used on the onboarding
    // "Connect OpenRouter" CTA. A soft, low-saturation blue that reads as the
    // primary path without shouting against the dark glass.
    static let accent  = Color(red: 0.40, green: 0.62, blue: 1.00)
    // Success — the brief checkmark when a connection lands. Muted to match the
    // glass; shown only for the ~0.6s confirmation beat, never as a standing pill.
    static let success = Color(red: 0.40, green: 0.82, blue: 0.55)

    // MARK: Source / intent palette
    //
    // The ONE table every surface reads for "which kind of thing is this" — the
    // Ask/Note/Remind/Agent destination pill, the Recent filter chips, the
    // capture jump pills, the archive window's chips and bubbles. Each kind has
    // TWO faces: a saturated `…Tint` body for the low-opacity glass WASHES (where
    // saturation survives dilution), and the same hue lifted toward white as
    // `…Ink` for TEXT and glows — a fully saturated colour used as ink sinks into
    // the dark glass (blue especially reads as a murky shadow), while these
    // luminous pastels read as coloured *light*.
    //
    // Read through `NotchModel.HistoryItem.Source.tint` / `NotchModel.Panel`'s
    // `intentTint` / `intentInk` rather than reaching for the raw values — those
    // are the mappings, this is the palette. Never hand-roll a fourth copy.
    static let askTint      = Color.blue
    static let askInk       = Color(red: 0.66, green: 0.80, blue: 1.00)
    static let noteTint     = Color.yellow
    static let noteInk      = Color(red: 1.00, green: 0.89, blue: 0.58)
    static let reminderTint = Color.orange
    static let reminderInk  = Color(red: 1.00, green: 0.78, blue: 0.56)
    static let agentTint    = Color(red: 0.64, green: 0.44, blue: 1.00)
    static let agentInk     = Color(red: 0.82, green: 0.72, blue: 1.00)

    /// Placeholder text for the prompt — a soft, faint hint, clearly LIGHTER than
    /// real typed text so it reads as a transient suggestion rather than content.
    /// Kept low on the scale so "Ask anything" whispers instead of shouting.
    static let placeholder = ink.opacity(0.38)

    // Resting notch dimensions — matched to the real MacBook hardware notch
    // (≈185pt wide × 32pt tall, ~9pt bottom corner radius) so the resting form
    // sits exactly over the bezel cutout rather than looking like a fat pill.
    static let notchWidth: CGFloat = 192
    static let notchTopHeight: CGFloat = 32        // constant black "hardware" zone
    static let notchRestRadius: CGFloat = 9        // resting bottom corner radius

    // Open widths per state — the island grows wider as content gets richer.
    static let openWidthIdle: CGFloat = 540
    static let openWidthLoad: CGFloat = 560
    static let openWidthResult: CGFloat = 600
    static let openWidthSettings: CGFloat = 580   // inline settings form
    static let openWidthWhatsNew: CGFloat = 600   // release-notes reading column
}

/// The panel's **recessed** control surface: a faint white floor plus a hairline
/// rim, both lifting together when `lit` (hovered, focused, or open). The flat
/// counterpart to `glassCapsule` — that one is for chips floating ON the glass,
/// this one for controls sunk INTO a panel. See `Tokens.recessFill` for why the
/// numbers live in one place.
struct RecessedSurface<S: InsettableShape>: ViewModifier {
    var shape: S
    var lit: Bool
    /// The louder rung, for a screen's primary action. Same recipe, brighter pair.
    var prominent: Bool = false

    private var fill: Color {
        if prominent { return lit ? Tokens.prominentFillLit : Tokens.prominentFill }
        return lit ? Tokens.recessFillLit : Tokens.recessFill
    }
    private var rim: Color {
        if prominent { return lit ? Tokens.prominentRimLit : Tokens.prominentRim }
        return lit ? Tokens.recessRimLit : Tokens.recessRim
    }

    func body(content: Content) -> some View {
        content
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(rim, lineWidth: 0.5))
    }
}

extension View {
    /// Wear the shared recessed-control surface (see `RecessedSurface`). Pass the
    /// control's own shape so the floor, the rim and the hit area agree.
    func recessedSurface<S: InsettableShape>(in shape: S, lit: Bool) -> some View {
        modifier(RecessedSurface(shape: shape, lit: lit))
    }

    /// The prominent rung of the same surface — a screen's ONE primary action.
    func prominentSurface<S: InsettableShape>(in shape: S, lit: Bool) -> some View {
        modifier(RecessedSurface(shape: shape, lit: lit, prominent: true))
    }
}

/// Trackpad haptics — the native macOS confirmation channel (the same taps
/// Finder gives on snap-align and QuickTime on trim boundaries). Fired only on
/// *user-initiated* moments, per the HIG: the island snapping open under the
/// cursor, a drop landing, a copy confirmed, a switch flipped. Passive motion
/// (auto-collapse on leave, streaming) stays silent. No-ops on Macs without a
/// Force Touch trackpad.
enum Haptics {
    /// Something snapped into place: the island opening, a folder drop landing.
    static func alignment() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    /// A control changed level: a settings switch flipped.
    static func levelChange() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
    /// A quiet confirmation for actions with no visible result (copy).
    static func confirm() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

extension View {
    /// The panel's ONE small-caps caption register: the title over a full-panel
    /// module (SETTINGS / WHAT'S NEW) and the section headings inside one
    /// (FEATURES / FIXES, the model picker's provider groups). 10pt semibold,
    /// tracked out, at meta weight — quiet enough to label without competing with
    /// the content it sits over.
    ///
    /// Four surfaces used to spell this out by hand and had drifted to 10/0.8 in
    /// three of them and 9.5/0.7 in the fourth — a difference nobody chose and
    /// nobody can see, which is exactly how a register stops being a register.
    func captionLabel() -> some View {
        font(.sf(10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Tokens.text4)
    }
}

extension Font {
    /// Native SF Text with optical sizing handled by the system. SwiftUI's
    /// `.system` already maps to San Francisco, so we just size/weight it.
    static func sf(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// The brand wordmark voice — Prompt (Medium / 500), bundled and registered
    /// via `ATSApplicationFontsPath` so it matches the "Notch" wordmark on the
    /// landing page (its `--brand` family). Used only for the name of the thing.
    static func brand(_ size: CGFloat) -> Font {
        .custom("Prompt-Medium", fixedSize: size)
    }
}

/// Geometry shared with the SwiftUI tree via the environment so views know how
/// wide the transparent canvas is and can center the notch within it.
///
/// Each panel (one per screen — see `AppDelegate`) injects its own copy, which is
/// how the same `ContentView` renders a hardware-notch-hugging island on the
/// built-in display and a menu-bar-height "virtual notch" on external ones.
struct NotchMetrics {
    var canvasWidth: CGFloat
    /// Stable identifier of the display this canvas sits on (`CGDirectDisplayID`).
    /// `nil` only in previews / the environment default; live panels always set it.
    var displayID: CGDirectDisplayID? = nil
    /// Height of the resting black zone: the hardware notch height on the built-in
    /// screen, the menu-bar height on external (notch-less) screens — so the
    /// virtual notch nests inside the menu bar instead of poking below it.
    var restHeight: CGFloat = Tokens.notchTopHeight
    /// Whether this screen has a real camera housing. Drives the camera dot —
    /// drawing a fake lens on an external monitor reads as a mistake.
    var hasHardwareNotch: Bool = true
}

private struct NotchMetricsKey: EnvironmentKey {
    static let defaultValue = NotchMetrics(canvasWidth: 760)
}

extension EnvironmentValues {
    var notchMetrics: NotchMetrics {
        get { self[NotchMetricsKey.self] }
        set { self[NotchMetricsKey.self] = newValue }
    }
}

// MARK: - Scroll edge fade

/// The one soft-fade treatment every scrolling region in the panel shares, so
/// overflowing content dissolves into the glass instead of ending on a hard
/// horizontal cut. Applied as a luminance mask: a long, gentle taper at the top
/// and/or bottom edge, sized in *points* (so the dissolve looks the same whatever
/// the content height) and converted to the gradient's 0–1 space using the view's
/// own measured height. Reused by the conversation thread and the RECENT list —
/// don't hand-roll a per-view gradient; route every scroll area through here.
struct ScrollEdgeFade: ViewModifier {
    /// Whether to taper the top / bottom edge. A region pinned under a header
    /// (so its top never overflows) can fade only the bottom, and vice versa.
    var top: Bool
    var bottom: Bool
    /// Height of each taper, in points — set independently per edge so one edge can
    /// fade over a long gradient while the other only feathers a thin sliver.
    /// Generous by default so a fade reads as a gradient, not a hard cut.
    var topFade: CGFloat = 64
    var bottomFade: CGFloat = 64

    func body(content: Content) -> some View {
        content.mask(
            GeometryReader { geo in
                let h = max(geo.size.height, 1)
                // Clamp each taper independently, and cap the pair so they can't
                // overlap and punch a hole through a short area.
                let ft = min(topFade / h, 0.45)
                let fb = min(bottomFade / h, 0.45)
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(top ? 0 : 1), location: 0),
                        .init(color: .black, location: top ? ft : 0),
                        .init(color: .black, location: bottom ? 1 - fb : 1),
                        .init(color: .black.opacity(bottom ? 0 : 1), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
        )
    }
}

extension View {
    /// Apply the shared scroll edge fade (see `ScrollEdgeFade`). Pass `top` /
    /// `bottom` to choose which edges taper; usually gated on whether the content
    /// actually overflows, so a short list/thread stays crisp. `topFade` /
    /// `bottomFade` set each taper's length independently (default 64pt both).
    func scrollEdgeFade(
        top: Bool,
        bottom: Bool,
        topFade: CGFloat = 64,
        bottomFade: CGFloat = 64
    ) -> some View {
        modifier(ScrollEdgeFade(top: top, bottom: bottom, topFade: topFade, bottomFade: bottomFade))
    }

    /// Convenience: the same taper length on both edges (the common case).
    func scrollEdgeFade(top: Bool, bottom: Bool, fade: CGFloat = 64) -> some View {
        scrollEdgeFade(top: top, bottom: bottom, topFade: fade, bottomFade: fade)
    }
}

// MARK: - Progressive top blur

/// A variable ("progressive") blur on the TOP band of a view — sharp at the
/// bottom, blurring harder the closer a pixel sits to the top edge. SwiftUI has
/// no native variable blur on the 14.0 baseline, so we approximate the smooth
/// ramp with ONE uniformly-blurred copy of the content masked to a gradient
/// band: the mask is fully opaque at the very top and tapers to clear at the
/// band's lower edge, so the frost reads as deepening upward — the look of rows
/// dissolving *behind* the floating input header — while the un-blurred original
/// shows through below. (An earlier version stacked four blurred copies for a
/// stepped ramp; that rebuilt the whole up-to-50-row list four times per edge on
/// every open and was the multi-second click-to-expand stall. The gradient mask
/// already carries the ramp, so the single flattened copy reads the same.)
///
/// This is the partner to `ScrollEdgeFade`: that mask handles *opacity* (rows
/// thin out toward the top), this handles *focus* (rows frost out toward the
/// top). Used together, content scrolling up under the input stays faintly
/// perceivable — present, but pushed back — instead of hard-clipping.
///
/// The blurred copy is a full render of the content (flattened once via
/// `.drawingGroup()`), so this is only worth applying to a region that actually
/// overflows and scrolls under a header. A short list that fits needs neither.
///
/// **The band must end ABOVE the first resting row, or its blurred glyphs halo.**
/// This frost works by blurring the content itself — there is no separate material
/// layer between the rows and the panel glass to blur instead (the rows draw
/// straight onto the whole-panel glass). So the only way to keep the row text out
/// of the blur is geometric: the band reaches only across the *runway* — the empty
/// inset above the first row (`immersiveTopReach`) that rows scroll up into behind
/// the floating input — and tapers fully to clear before it touches the first row's
/// resting position. At idle no row is inside the band, so nothing white is sampled
/// into a blurred copy and there is no halo. As the user scrolls, rows travel up
/// into the runway band and frost on the way out — which is the whole point. The
/// earlier bug was a band (`immersiveBlurReach = 130` over a 320pt viewport) that
/// reached ~140pt down, well past the first row at ~84pt, so the light-grey glyphs
/// (`Tokens.text2`, white@0.74) blurred at radius 26 stacked into a bright text-shaped
/// wash parked behind the top rows. Keep the band's deepest reach short of the
/// runway height; see `immersiveBlurReach` for the exact budget.
struct ProgressiveTopBlur: ViewModifier {
    /// Height of the blur band, in points, measured from the top edge down.
    /// Below this the content is fully sharp.
    var height: CGFloat
    /// Peak blur radius at the very top edge. Each layer steps up toward this.
    var maxRadius: CGFloat = 7

    func body(content: Content) -> some View {
        // `.overlay` (taking the content's own size, so it never disturbs layout)
        // lays a blurred copy on top, so a row scrolling up INTO the band reads as
        // frosting out. That only haloes if a resting row sits inside the band —
        // which the caller prevents by keeping the band above the first row (see the
        // doc comment). Within the runway there is no text to brighten.
        content.overlay(
            GeometryReader { geo in
                let h = max(geo.size.height, 1)
                // The blur band as a fraction of the view height, clamped so it
                // never swallows the whole region on a short view.
                let band = min(height / h, 0.9)
                // ONE blurred copy, not a stack of four. The earlier version
                // re-rendered the entire (up-to-50-row) `content` four times — a
                // ForEach(0..<4) where each iteration built, laid out and blurred the
                // whole list. That 4× tree build landed on the main thread the instant
                // the immersive list mounted (plus a matching 4× in the bottom mirror =
                // 8 full-list renders per open), which is what stalled the click-to-
                // expand for seconds on a long history. The smooth top-deepening ramp
                // is already carried by the gradient MASK below, so a single uniform
                // blur masked by that ramp reads the same as the stepped stack at a
                // quarter of the cost. `.drawingGroup()` flattens this one copy into a
                // single Metal texture so the blur runs on a cached raster (constant
                // cost, independent of row count) rather than re-rasterizing the live
                // tree every frame — safe here because this overlay copy never
                // hit-tests or animates the rows; the live, sharp `content` underneath
                // owns all interaction.
                content
                    .drawingGroup()
                    .blur(radius: maxRadius)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: max(band - band * 0.5, 0)),
                                .init(color: .clear, location: band),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    // The frost base must not intercept clicks — the live, sharp
                    // content on top owns all hit-testing (taps on rows).
                    .allowsHitTesting(false)
            }
        )
    }
}

extension View {
    /// Frost the top band of a scrolling region so rows passing behind a floating
    /// header blur out progressively (see `ProgressiveTopBlur`). Pair with
    /// `scrollEdgeFade(top:)` for the matching opacity taper.
    func progressiveTopBlur(height: CGFloat, maxRadius: CGFloat = 7) -> some View {
        modifier(ProgressiveTopBlur(height: height, maxRadius: maxRadius))
    }

    /// Frost the BOTTOM band — the mirror of `progressiveTopBlur`, for rows passing
    /// behind floating bottom chrome (the manage bar). Pair with
    /// `scrollEdgeFade(bottom:)` for the matching opacity taper.
    func progressiveBottomBlur(height: CGFloat, maxRadius: CGFloat = 7) -> some View {
        modifier(ProgressiveBottomBlur(height: height, maxRadius: maxRadius))
    }
}

/// The bottom-edge mirror of `ProgressiveTopBlur`: a variable blur on the BOTTOM
/// band — sharp above, blurring harder the closer a pixel sits to the bottom edge.
/// Used so rows scrolling DOWN into the runway behind the floating manage bar frost
/// out the same way rows scrolling UP behind the input do. Same stacked-layer
/// approximation, just with the gradient flipped (strongest layer hugs the bottom).
///
/// **The band must end BELOW the last resting row**, or its blurred glyphs halo —
/// the same rule as the top, mirrored: the band reaches only across the bottom
/// *runway* (the empty inset below the last row that rows scroll down into behind
/// the manage bar), and tapers fully to clear before it touches the last row's
/// resting position. At idle no row is inside the band, so nothing haloes.
struct ProgressiveBottomBlur: ViewModifier {
    /// Height of the blur band, in points, measured from the bottom edge up.
    /// Above this the content is fully sharp.
    var height: CGFloat
    /// Peak blur radius at the very bottom edge. Each layer steps up toward this.
    var maxRadius: CGFloat = 7

    func body(content: Content) -> some View {
        // Mirror of `ProgressiveTopBlur`: ONE flattened blurred copy, gradient-masked
        // to the bottom band, not a four-deep stack. See the top variant for why the
        // 4× full-list re-render was the click-to-expand stall and why a single
        // `.drawingGroup()`-rasterized blur reads identically here.
        content.overlay(
            GeometryReader { geo in
                let h = max(geo.size.height, 1)
                let band = min(height / h, 0.9)
                content
                    .drawingGroup()
                    .blur(radius: maxRadius)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: 1 - band),
                                .init(color: .black, location: min(1 - band + band * 0.5, 1)),
                                .init(color: .black, location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .allowsHitTesting(false)
            }
        )
    }
}

/// Apply `ProgressiveBottomBlur` only when `active`, mounting/unmounting the blur
/// stack (mirror of `ConditionalTopBlur`) so the compact list never pays for it.
struct ConditionalBottomBlur: ViewModifier {
    var active: Bool
    var height: CGFloat
    var maxRadius: CGFloat = 7

    func body(content: Content) -> some View {
        if active {
            content.progressiveBottomBlur(height: height, maxRadius: maxRadius)
        } else {
            content
        }
    }
}

/// Apply `ProgressiveTopBlur` only when `active` — and, crucially, mount/unmount
/// the blur stack rather than just zeroing its radius, so the compact list never
/// pays for the extra renders. A plain `if active` inside a `ViewModifier` would
/// change the view's identity; wrapping the toggle here keeps it contained.
struct ConditionalTopBlur: ViewModifier {
    var active: Bool
    var height: CGFloat
    var maxRadius: CGFloat = 7

    func body(content: Content) -> some View {
        if active {
            content.progressiveTopBlur(height: height, maxRadius: maxRadius)
        } else {
            content
        }
    }
}

// MARK: - Scroll offset observer

/// Reports a SwiftUI `ScrollView`'s live vertical scroll offset by reaching the
/// AppKit `NSScrollView` underneath it. The pure-SwiftUI routes (a GeometryReader
/// preference probe, or an onAppear/onDisappear sentinel) are unreliable on the
/// classic macOS 14 `ScrollView` — it neither exposes a stable offset nor recycles
/// off-screen children — so we observe the real clip view's bounds instead, which
/// is exact and immune to how SwiftUI composes (e.g. the blur overlay's content
/// copies). Drop this as a zero-size `background` on the scroll *content*; it finds
/// its enclosing scroll view at runtime and calls `onChange` with `bounds.origin.y`
/// (0 at the top, growing as the user scrolls down).
struct ScrollOffsetObserver: NSViewRepresentable {
    var onChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // Defer the hookup: the view isn't in the window's hierarchy yet during
        // make, so the enclosing NSScrollView can't be found until the next runloop.
        DispatchQueue.main.async { context.coordinator.attach(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onChange = onChange
        // Re-attach if the scroll view wasn't ready at make time (or got replaced).
        if context.coordinator.clipView == nil {
            DispatchQueue.main.async { context.coordinator.attach(from: nsView) }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var onChange: (CGFloat) -> Void
        weak var clipView: NSClipView?

        init(onChange: @escaping (CGFloat) -> Void) { self.onChange = onChange }

        func attach(from view: NSView) {
            guard let scrollView = view.enclosingScrollView else { return }
            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            clipView = clip
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clip
            )
            // Report the initial offset so a list that opens already-scrolled is
            // classified correctly on first paint.
            report(clip)
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            clipView = nil
        }

        @objc private func boundsChanged(_ note: Notification) {
            guard let clip = note.object as? NSClipView else { return }
            report(clip)
        }

        private func report(_ clip: NSClipView) {
            onChange(clip.bounds.origin.y)
        }
    }
}

extension View {
    /// Observe the enclosing scroll view's vertical offset (see `ScrollOffsetObserver`).
    func onScrollOffsetChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        background(ScrollOffsetObserver(onChange: action))
    }
}

// MARK: - Tooltip

/// Name of the **clip box** a tooltip keeps itself inside — published by each
/// surface that actually clips its content: the island (`ContentView`, right on
/// the `.frame(width:)` the `NotchShape` clip follows), the detached session
/// window, and the archive window. A tooltip clamps its horizontal position to
/// this box so the capsule never runs off the edge and gets chopped.
///
/// It must be registered on the CLIPPING view, not on the hosting canvas. It used
/// to sit on `AppDelegate.makePanel`'s root frame — but that frame is the full
/// *screen-wide* canvas the island floats in, so clamping to it never moved
/// anything: a capsule spilling off the 600pt island was still comfortably inside
/// the 1512pt canvas. Same trap as `.scrollView` below; see `resolvedBounds`.
enum TooltipCoordinateSpace {
    static let clipBox = "notchTooltipClipBox"
}

/// A hover tooltip drawn in the notch's own visual language instead of AppKit's
/// stock yellow `.help()` bubble — the flat OS tooltip that hasn't changed in
/// decades and reads as a foreign chip on the dark glass. This one is a small
/// dark capsule (a whisper of glass, a hairline rim, a soft drop shadow) with the
/// label in the same SF/text-token scale as the rest of the island, so a hover
/// hint over the answer's action icons feels like part of the surface.
///
/// Behaviour matches a real tooltip: it waits a beat (`delay`) after the cursor
/// settles before fading in — so brushing past an icon doesn't flash it — and
/// dismisses the instant the cursor leaves. It floats ABOVE the anchor (the
/// action icons live at the panel's bottom edge, so up is where the room is),
/// centred on it, as a zero-footprint overlay that never disturbs layout and
/// never intercepts the click underneath.
private struct NotchTooltip: ViewModifier {
    let text: String
    /// Which side of the control the tip floats on. Footer icons live at the
    /// panel's bottom, so `.top` (up, into the answer) is the default; controls
    /// pinned near the top edge pass `.bottom` so the tip drops down instead of
    /// running off the panel.
    var edge: VerticalEdge = .top
    /// Seconds the cursor must rest on the control before the tip appears.
    var delay: TimeInterval = 0.45

    @State private var hovering = false
    @State private var shown = false
    /// Measured height of the capsule, so the offset clears the control exactly.
    @State private var tipHeight: CGFloat = 24
    /// Measured width of the capsule laid out on ONE line, with no wall in the
    /// way. Compared against `availableWidth` to decide whether this tip has to
    /// wrap at all; when it doesn't, this is the capsule's drawn width.
    @State private var naturalWidth: CGFloat = 0
    /// The anchor's own width, and the horizontal bounds of its clip container
    /// (see `resolvedBounds`) — both in the anchor's local space, so
    /// `horizontalNudge` can keep the centred capsule inside the walls.
    @State private var anchorWidth: CGFloat = 0
    @State private var boundMinX: CGFloat = -.greatestFiniteMagnitude
    @State private var boundMaxX: CGFloat = .greatestFiniteMagnitude
    /// Cancels a pending show if the cursor leaves before `delay` elapses.
    @State private var showTask: Task<Void, Never>?

    /// Wall-to-wall room the capsule may occupy, minus the same 6pt margin
    /// `horizontalNudge` clamps to. `.infinity` when no clip box answered — the
    /// tip then sizes to its text on one line, as it always has.
    private var availableWidth: CGFloat {
        guard boundMinX > -.greatestFiniteMagnitude,
              boundMaxX < .greatestFiniteMagnitude,
              boundMaxX > boundMinX else { return .infinity }
        return max(boundMaxX - boundMinX - 12, 80)
    }

    /// A tip whose one-line form is wider than the room between the walls has to
    /// wrap: sliding it sideways can clear one wall, but nothing fits a capsule
    /// wider than the box inside the box. The intro row's CC BY credit is a full
    /// sentence and lands here; every short hint keeps its one-line capsule.
    private var wraps: Bool { naturalWidth > 0 && naturalWidth > availableWidth }

    /// The capsule's drawn width — its natural one-line width, or exactly the
    /// available room when it has to wrap.
    private var tipWidth: CGFloat { wraps ? availableWidth : naturalWidth }

    /// How far to shift the capsule horizontally so it never spills past its clip
    /// container. Zero when the naturally-centred capsule already fits; positive =
    /// nudge right (off the left wall), negative = nudge left (off the right wall).
    /// This is what stops the left-most footer icon's tip from being cut off at the
    /// panel edge — it slides right until it clears.
    private var horizontalNudge: CGFloat {
        guard tipWidth > 0, boundMaxX > boundMinX else { return 0 }
        let margin: CGFloat = 6
        let center = anchorWidth / 2            // the capsule is centred on the anchor
        let tipMinX = center - tipWidth / 2
        let tipMaxX = center + tipWidth / 2
        let availMin = boundMinX + margin
        let availMax = boundMaxX - margin
        // Wider than the container even when clamped: centre it in what's available.
        guard availMax - availMin >= tipWidth else { return (availMin + availMax) / 2 - center }
        if tipMinX < availMin { return availMin - tipMinX }   // push right, off the left wall
        if tipMaxX > availMax { return availMax - tipMaxX }   // push left, off the right wall
        return 0
    }

    /// The horizontal walls the capsule must stay inside, in the anchor's own
    /// space. The `clipBox` (island / detached window / archive window) is the
    /// authority — that's the view whose clip actually chops the capsule.
    ///
    /// A ScrollView around the anchor can clip *tighter* than that, so it narrows
    /// the box further — but only when the scroll box is actually the anchor's own.
    /// That guard is the whole point: `bounds(of: .scrollView)` answers for the
    /// nearest scroll view in the ANCESTRY, and returns a box even when the anchor
    /// sits outside its visible rect. The header cluster (which lives above the
    /// conversation scroll, not in it) was getting back a box lying entirely to
    /// its left — `maxX` negative — and dutifully shoving its tip ~180pt off
    /// target. Reading the scroll view alone, as this used to, also silently
    /// dropped the island wall on the footer icons: the scroll box measured wider
    /// than the 600pt island, so the left-most tip "fit" and was never nudged —
    /// which is exactly how it ended up sliced off at the island's edge.
    ///
    /// The test is OVERLAP, not containment. Containment (`minX <= 0 && maxX >=
    /// width`) looks stricter and safer, but it dropped the scroll wall on exactly
    /// the icon that needs it: the answer footer's left-most button carries a -5pt
    /// lead inset (it optically aligns its 11pt glyph in a 22pt hit-frame with the
    /// text above), so the icon starts 5pt LEFT of the scroll's own left edge. The
    /// scroll box then failed "straddles it on both sides", the capsule clamped to
    /// the island instead — 14pt outside the scroll viewport — and the long-answer
    /// (scrolling) layout chopped its left cap off against the scroll's clip. An
    /// overlap test keeps rejecting the header case (a box entirely to one side)
    /// while still claiming a scroll the anchor merely straddles by a few points.
    private static func resolvedBounds(_ g: GeometryProxy) -> (minX: CGFloat, maxX: CGFloat) {
        guard let clip = g.bounds(of: .named(TooltipCoordinateSpace.clipBox)) else {
            return (-.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        }
        var minX = clip.minX, maxX = clip.maxX
        // `0..<g.size.width` × `0..<g.size.height` IS the anchor in this space, so
        // "this scroll is the one clipping me" is: its box overlaps the anchor on
        // both axes. A box lying off to one side (the header cluster's) doesn't.
        if let scroll = g.bounds(of: .scrollView),
           scroll.maxX > 0, scroll.minX < g.size.width,
           scroll.maxY > 0, scroll.minY < g.size.height {
            minX = max(minX, scroll.minX)
            maxX = min(maxX, scroll.maxX)
        }
        return (minX, maxX)
    }

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                showTask?.cancel()
                if inside {
                    let d = delay
                    showTask = Task {
                        try? await Task.sleep(for: .seconds(d))
                        if !Task.isCancelled, hovering {
                            if ProcessInfo.processInfo.environment["NOTCH_TIP_DEBUG"] == "1" {
                                FileHandle.standardError.write(Data("[tip] box=\(boundMinX)…\(boundMaxX) anchor=\(anchorWidth) natural=\(naturalWidth) avail=\(availableWidth) wraps=\(wraps) h=\(tipHeight) nudge=\(horizontalNudge)\n".utf8))
                            }
                            withAnimation(.easeOut(duration: 0.14)) { shown = true }
                        }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.10)) { shown = false }
                }
            }
            // Track the clip container the capsule must stay inside (see
            // `resolvedBounds`) in the anchor's own coordinate space, so
            // `horizontalNudge` can measure how close the anchor sits to each
            // wall. Zero-footprint (a clear backdrop).
            .background(
                GeometryReader { g in
                    let box = Self.resolvedBounds(g)
                    Color.clear.preference(
                        key: TooltipBoundsKey.self,
                        value: TooltipBounds(minX: box.minX,
                                             maxX: box.maxX,
                                             anchorWidth: g.size.width))
                }
            )
            .onPreferenceChange(TooltipBoundsKey.self) { b in
                boundMinX = b.minX; boundMaxX = b.maxX; anchorWidth = b.anchorWidth
            }
            // Measure the capsule BEFORE it is ever shown — a hidden, zero-footprint
            // copy that only exists to report its size. The measurement used to live
            // on the visible capsule inside the overlay, which meant `tipWidth` was
            // still 0 on the frame the tip appeared: `horizontalNudge` had nothing to
            // clamp with, so the capsule was drawn CENTRED on its icon and only
            // slid clear on a later pass. On the left-most footer icon that first
            // frame hangs ~50pt off the island's edge and gets chopped — the
            // "left side is cut off" bug. Measuring up front means the very first
            // frame is already in its clamped place. (`.hidden()` still lays out,
            // and a background never affects the anchor's own layout.)
            //
            // Two twins, because "does this even fit?" and "how tall is it once
            // it doesn't" are different measurements. The first lays the text out
            // on one line with no wall in the way (`.fixedSize()`, so it reports
            // the size it WANTS rather than the 11pt icon it hangs off) — that
            // width decides `wraps`. The second is the capsule as it will
            // actually be drawn, and reports the height the offset must clear.
            .background(
                TooltipLabel.sizedText(text)
                    .fixedSize()
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: TooltipWidthKey.self,
                                                   value: g.size.width)
                        }
                    )
                    .hidden()
                    .allowsHitTesting(false)
            )
            .background(
                TooltipLabel.sizedText(text, width: wraps ? availableWidth : nil)
                    .fixedSize()
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: TooltipHeightKey.self,
                                                   value: g.size.height)
                        }
                    )
                    .hidden()
                    .allowsHitTesting(false)
            )
            .onPreferenceChange(TooltipHeightKey.self) { if $0 > 0 { tipHeight = $0 } }
            .onPreferenceChange(TooltipWidthKey.self) { if $0 > 0 { naturalWidth = $0 } }
            // Anchor the tip's near edge to the control's matching edge, then push
            // it fully CLEAR of the control by its own measured height plus a gap —
            // so the capsule sits above (or below) the icon, never on top of it.
            // `.top` alignment pins their top edges together; the negative offset
            // then lifts the whole capsule up past the icon. (Mirror for `.bottom`.)
            .overlay(alignment: edge == .top ? .top : .bottom) {
                if shown {
                    TooltipLabel(text: text, width: wraps ? availableWidth : nil)
                        // Let it size to its text without being clipped to the
                        // anchor's width; the hidden twin above already reported
                        // that size, so the offsets below are right from frame one.
                        .fixedSize()
                        // Clear the control entirely (height + a 6pt gap), and slide
                        // sideways by `horizontalNudge` so a capsule centred on a
                        // near-the-edge icon doesn't spill off the panel.
                        .offset(x: horizontalNudge,
                                y: edge == .top ? -(tipHeight + 6) : (tipHeight + 6))
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        // Sit above sibling chrome so a neighbouring icon never
                        // paints over the tip.
                        .zIndex(1000)
                }
            }
    }
}

/// Carries the measured tooltip capsule height up so the offset can clear the
/// control by its exact height rather than a guessed constant.
private struct TooltipHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Carries the measured capsule width up so it can be nudged clear of a wall.
private struct TooltipWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The anchor's width plus its clip-container walls (in the anchor's own space),
/// carried up together so the horizontal clamp has everything it needs at once.
private struct TooltipBounds: Equatable {
    var minX: CGFloat = -.greatestFiniteMagnitude
    var maxX: CGFloat = .greatestFiniteMagnitude
    var anchorWidth: CGFloat = 0
}

private struct TooltipBoundsKey: PreferenceKey {
    static let defaultValue = TooltipBounds()
    static func reduce(value: inout TooltipBounds, nextValue: () -> TooltipBounds) {
        value = nextValue()
    }
}

/// The capsule itself — factored out so the shadow/rim/material live in one place.
///
/// Built in the island's **Liquid Glass** language rather than as a flat dark
/// wafer: real `.glassEffect(.clear)` on macOS 26+ (blurred `NSVisualEffectView`
/// below) so the wafer refracts what's behind it, plus the two touches that make
/// glass read as glass instead of a painted board — a top-down sheen and a
/// directional specular rim, bright along the top edge and fading down the sides.
/// Same recipe as `GlassCard` / `glassCapsule`; don't hand-roll a third one.
///
/// The veil over the glass is deliberate, not a leftover. Bare `.clear` glass
/// composites to only ~0.34 and 11pt text sitting on arbitrary wallpaper or body
/// copy goes to mud; 0.30 over the 0.34 baked tint lands ≈0.54 — a touch airier
/// than the old flat 0.62 while still occluding enough to stay legible.
private struct TooltipLabel: View {
    let text: String
    /// An exact capsule width for a tip that has to wrap, or `nil` for the
    /// ordinary one-line capsule that sizes to its own text.
    let width: CGFloat?

    init(text: String, width: CGFloat? = nil) {
        self.text = text
        self.width = width
    }

    /// Horizontal padding inside the capsule, on each side.
    static let hPadding: CGFloat = 9

    /// The capsule's content at its exact final size, without the glass behind it.
    /// Split out so `NotchTooltip` can pre-measure a tip it isn't showing yet
    /// (see its hidden measuring backdrops) without building a whole glass wafer —
    /// and so the measured size can never drift from the drawn one.
    ///
    /// With no `width`, the old behaviour exactly: one line, sized to the text.
    /// With one, an EXACT frame — not `maxWidth`, which is the trap here: a
    /// flexible frame under `.fixedSize()` gets a nil proposal, hands the Text a
    /// nil proposal too, and the Text answers with its full one-line width; the
    /// frame then reports the clamped width while the text inside it stays laid
    /// out long and spills out both ends. A fixed frame proposes its own width
    /// down no matter what the parent proposed, so the text actually wraps.
    @ViewBuilder
    static func sizedText(_ text: String, width: CGFloat? = nil) -> some View {
        let base = Text(text)
            .font(.sf(11, weight: .medium))
            .tracking(0.1)
            .foregroundStyle(Tokens.text2)
        if let width {
            base
                .multilineTextAlignment(.leading)
                .frame(width: max(width - hPadding * 2, 80), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, hPadding)
                .padding(.vertical, 5)
        } else {
            base
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, hPadding)
                .padding(.vertical, 5)
        }
    }

    var body: some View {
        // A rounded rect at the one-line capsule's own radius — identical to
        // `Capsule` for a single line, but a two-line tip keeps square-ish ends
        // instead of blowing its corners out into half-circles that eat into the
        // text.
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Self.sizedText(text, width: width)
            .background(
                ZStack {
                    shape.fill(.clear)
                        .nativeGlass(in: shape, tintOpacity: GlassMaterial.bakedTint)
                        .overlay(shape.fill(Color.black.opacity(0.30)))
                    shape
                        .fill(LinearGradient(colors: [.white.opacity(0.12), .clear],
                                             startPoint: .top, endPoint: .center))
                        .blendMode(.plusLighter)
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.08)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.6)
                }
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }
}

extension View {
    /// Attach a `NotchTooltip` — the in-house replacement for `.help()`. Use it on
    /// the answer-footer action icons (copy / save / regenerate / info / pin) and
    /// any other island control that wants a hover hint in the panel's own voice.
    func notchTooltip(_ text: String, edge: VerticalEdge = .top, delay: TimeInterval = 0.45) -> some View {
        modifier(NotchTooltip(text: text, edge: edge, delay: delay))
    }
}

// MARK: - Grab cursor

/// The hand cursor for a tear-off grip. The grips are deliberately invisible —
/// transparent sheets behind the content (see `NotchBody.detachGrip`) — so
/// without a cursor change the only way to find one is to guess and pull. The
/// open hand is the affordance: cross the strip, the pointer says "pull me."
///
/// Push/pop rather than `NSCursor.set()`: a bare `set` is undone by the next
/// mouse-moved event that finds no cursor rect under the pointer, so the hand
/// flickers back to the arrow while the cursor is still sitting on the grip.
/// The `pushed` flag keeps that stack balanced — `onHover` can repeat a value,
/// and the panel folds (unmounting the grip mid-hover) on every mouse-out,
/// which would otherwise leave the hand cursor pushed system-wide.
private struct GrabCursor: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                guard inside != pushed else { return }
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                pushed = inside
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}

/// The plain arrow, re-asserted for a control that sits INSIDE a `grabCursor()`
/// strip. The grip's hand is pushed for the whole strip, so a button riding on it
/// inherits "pull me" when it means "click me". Pushing the arrow on top of that
/// stack wins while the pointer is on the control and pops straight back to the
/// hand on the way out — same balanced push/pop discipline as `GrabCursor`.
private struct ArrowCursor: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                guard inside != pushed else { return }
                if inside { NSCursor.arrow.push() } else { NSCursor.pop() }
                pushed = inside
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}

extension View {
    /// Mark a strip as draggable: the pointer becomes an open hand over it.
    /// Layout-free — it only changes the cursor, never the hit-testing or the
    /// frame, so it can ride the same transparent sheets the tear-off grips use.
    func grabCursor() -> some View {
        modifier(GrabCursor())
    }

    /// Keep the normal pointer over a control that lives on a `grabCursor()` strip.
    func arrowCursor() -> some View {
        modifier(ArrowCursor())
    }
}
