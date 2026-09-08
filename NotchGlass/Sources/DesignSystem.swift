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
    /// Cards fanning out of — or gathering back into — a stack, the way a
    /// Notification Center group opens. Springy enough that the pile reads as
    /// physical, damped enough that it never wobbles.
    static let stackSpring = Animation.spring(response: 0.34, dampingFraction: 0.86)

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
    // Capture — the merged Note/Remind destination. Note and Remind keep their
    // own faces where a single leaf is named (the Recent chips, the leaf word
    // trailing the caret); the *mode* itself sits exactly between them, an amber
    // halfway along yellow→orange, so the destination pill doesn't advertise
    // itself as Note when Enter might file a reminder.
    static let captureTint  = Color(red: 1.00, green: 0.71, blue: 0.02)
    static let captureInk   = Color(red: 1.00, green: 0.84, blue: 0.57)
    static let agentTint    = Color(red: 0.64, green: 0.44, blue: 1.00)
    static let agentInk     = Color(red: 0.82, green: 0.72, blue: 1.00)

    // MARK: Prism
    //
    // The hues glass refracts, in the order they run around a rim. Deliberately
    // desaturated and few: real glass splits light into a narrow band, and four
    // pale hues at low alpha read as that, where a full spectrum reads as a toy.
    // The list closes on its first colour so an angular sweep of it has no seam.
    //
    // Two surfaces read this — the confirmation slab's edge glow and the
    // first-party aura (`BrandAura`). Both are the same idea, light caught in a
    // rim; keeping one list is what stops them drifting into two palettes.
    static let prismHues: [Color] = [
        Color(red: 0.52, green: 0.80, blue: 1.00),   // cool blue
        Color(red: 0.72, green: 0.58, blue: 1.00),   // violet
        Color(red: 1.00, green: 0.62, blue: 0.78),   // rose
        Color(red: 1.00, green: 0.84, blue: 0.60),   // warm amber
        Color(red: 0.52, green: 0.80, blue: 1.00),   // back to the start
    ]

    /// Placeholder text for the prompt — a soft, faint hint, clearly LIGHTER than
    /// real typed text so it reads as a transient suggestion rather than content.
    /// Kept low on the scale so "Ask anything" whispers instead of shouting.
    static let placeholder = ink.opacity(0.38)

    // Resting notch dimensions — matched to the real MacBook hardware notch
    // (≈185pt wide × 32pt tall, ~9pt bottom corner radius) so the resting form
    // sits exactly over the bezel cutout rather than looking like a fat pill.
    static let notchWidth: CGFloat = 192
    static let notchTopHeight: CGFloat = 32        // constant black "hardware" zone
    /// The island's bottom corner radius while it's the notch — resting and under
    /// the click level's hover peek. Pinned by the hardware: the resting island's
    /// corners are drawn a point below the cutout, so they have to trace it
    /// exactly. The expanded panel keeps its own, much rounder corner
    /// (`NotchIsland.bottomRadius`).
    static let notchRestRadius: CGFloat = 9
    /// Radius of the expanded island's concave top shoulders — the flare that
    /// melts the form into the menu bar the way the physical cutout's own
    /// corners do, instead of ending in a vertical cut. Kept small and hardware-
    /// sized: a wide sweep here reads as a bite taken out of the panel, not as
    /// the bezel transition it's imitating.
    static let notchShoulderFlare: CGFloat = 7

    // Open widths per state — the island grows wider as content gets richer.
    static let openWidthIdle: CGFloat = 540
    static let openWidthLoad: CGFloat = 560
    static let openWidthResult: CGFloat = 600
    static let openWidthSettings: CGFloat = 580   // inline settings form
    static let openWidthWhatsNew: CGFloat = 600   // release-notes reading column
}

/// Experiments that must never leak into a release build. Each flag is false by
/// default and can only be enabled from a Debug executable, so an ordinary local
/// reinstall and every shipped build keep the established UI unchanged.
enum DebugFeatureFlags {
    static let historySplitView: Bool = {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "NotchiHistorySplitView")
        #else
        false
        #endif
    }()
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

    /// Wear the first-party aura (see `BrandAura`) when `active`. Off, it costs
    /// nothing — no layer, no animation.
    func brandAura<S: InsettableShape>(in shape: S, active: Bool = true,
                                       lineWidth: CGFloat = 1) -> some View {
        overlay {
            if active { BrandAura(shape: shape, lineWidth: lineWidth) }
        }
    }
}

/// The mark of a **first-party** surface: prism light caught in the rim. Worn
/// only by nono — the one backend Notchi hosts itself — so that in a list of a
/// dozen third-party vendors, ours is the one that is visibly lit.
///
/// This is the confirmation slab's edge glow (see `ConfirmationDialogGlass`) at
/// control scale, and nothing more: the same `Tokens.prismHues` sweep, stroked
/// into the shape's own border in two passes and added with `plusLighter` so it
/// brightens the surface instead of painting a coloured line on it. The blur
/// radii scale off `lineWidth` so a 30pt capsule and a 22pt-radius card each get
/// a rim proportional to themselves.
///
/// It does not move. An earlier version rotated the sweep, which read as a stripe
/// travelling across the panel rather than as light in an edge.
struct BrandAura<S: InsettableShape>: View {
    var shape: S
    var lineWidth: CGFloat = 1

    var body: some View {
        let sweep = AngularGradient(colors: Tokens.prismHues,
                                    center: .center, angle: .degrees(-45))
        ZStack {
            // The hairline itself, softened just enough to lose its drawn edge.
            shape.strokeBorder(sweep, lineWidth: lineWidth)
                .blur(radius: lineWidth * 1.2)
            // A wider, fainter pass that bleeds a point or two inward — the part
            // that reads as glow rather than as border. Kept tight: spread past
            // that and the chip stops looking lit and starts looking hazy.
            shape.strokeBorder(sweep, lineWidth: lineWidth * 2.4)
                .blur(radius: lineWidth * 2.6)
                .opacity(0.3)
        }
        // Clipped to the shape, so the glow lives INSIDE the surface. A blurred
        // stroke otherwise spreads past the border, and what escapes gets cut by
        // the view's rectangular bounds — which are tangent to the straight edges
        // but stand well clear of the corners. The result was a halo that
        // vanished along the sides and squared off at every corner.
        .clipShape(shape)
        .blendMode(.plusLighter)
        .opacity(0.55)
        .allowsHitTesting(false)
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
    ///
    /// `color` exists for the one caller whose captions are also a CONTROL — the
    /// template picker's category tabs, where the selected group has to read as
    /// selected. It is the register's ink that varies there, never its size,
    /// weight, tracking, or case; anything wanting a different shape of caption
    /// wants a different register, not an argument here.
    func captionLabel(color: Color = Tokens.text4) -> some View {
        font(.sf(10, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(color)
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
    /// Width of the REAL cutout on this screen, measured from the gap between the
    /// menu bar's two auxiliary areas (185pt on a 14"); nil where there is none.
    var hardwareNotchWidth: CGFloat? = nil

    /// The width the RESTING island draws at — the measured cutout wherever there
    /// is one, the drawing constant only on notch-less screens (there the island
    /// *is* the notch, so the constant defines it).
    ///
    /// It used to be `Tokens.notchWidth` (192) everywhere, overhanging the real
    /// 185pt cutout by ~3.5pt per side. Those points land on live screen, and the
    /// island's straight side edges painted them black — covering the hardware's
    /// own curved shoulders, so the notch ended in a hard vertical cut instead of
    /// the rounded transition macOS draws. Drawn at the cutout's exact width the
    /// resting island sits entirely *inside* it and the transition survives.
    var restWidth: CGFloat { hardwareNotchWidth ?? Tokens.notchWidth }
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

/// How far below a thread ScrollView's viewport top a *sticky* affordance must
/// park to stay legible. A code block's copy button rides the visible top edge of
/// its island (see `CodeBlockView`), and every thread scroller tops out in a
/// dissolve band — a floating header in the panel's clipped layout, a fade/blur
/// runway in a detached window. Parking at the bare viewport top would slide the
/// button under that band. Each host sets its own reach; 0 is right for content
/// that doesn't scroll.
private struct StickyScrollTopInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var stickyScrollTopInset: CGFloat {
        get { self[StickyScrollTopInsetKey.self] }
        set { self[StickyScrollTopInsetKey.self] = newValue }
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
    enum Axis {
        case vertical
        case horizontal
    }

    /// Whether to taper the top / bottom edge. A region pinned under a header
    /// (so its top never overflows) can fade only the bottom, and vice versa.
    var top: Bool
    var bottom: Bool
    /// Height of each taper, in points — set independently per edge so one edge can
    /// fade over a long gradient while the other only feathers a thin sliver.
    /// Generous by default so a fade reads as a gradient, not a hard cut.
    var topFade: CGFloat = 64
    var bottomFade: CGFloat = 64
    var axis: Axis = .vertical

    func body(content: Content) -> some View {
        content.mask(
            GeometryReader { geo in
                let length = max(axis == .vertical ? geo.size.height : geo.size.width, 1)
                // Clamp each taper independently, and cap the pair so they can't
                // overlap and punch a hole through a short area.
                let ft = min(topFade / length, 0.45)
                let fb = min(bottomFade / length, 0.45)
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(top ? 0 : 1), location: 0),
                        .init(color: .black, location: top ? ft : 0),
                        .init(color: .black, location: bottom ? 1 - fb : 1),
                        .init(color: .black.opacity(bottom ? 0 : 1), location: 1),
                    ],
                    startPoint: axis == .vertical ? .top : .leading,
                    endPoint: axis == .vertical ? .bottom : .trailing
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

    /// The same shared dissolve for a horizontal scroller. `leading` and
    /// `trailing` map to the vertical helper's start/end edges, so the gradient
    /// math and softness stay identical in both orientations.
    func scrollEdgeFade(
        leading: Bool,
        trailing: Bool,
        leadingFade: CGFloat = 64,
        trailingFade: CGFloat = 64
    ) -> some View {
        modifier(ScrollEdgeFade(top: leading, bottom: trailing,
                                topFade: leadingFade, bottomFade: trailingFade,
                                axis: .horizontal))
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

/// **Both** runways frosted in ONE copy of the content — use this instead of
/// stacking `progressiveTopBlur` + `progressiveBottomBlur` whenever the two
/// bands share a radius.
///
/// Why it exists: each progressive blur overlays a *rebuilt* copy of the content
/// (that's how the blurred layer is produced), so stacking the two modifiers
/// doesn't cost 2 copies — it costs **4**. The bottom modifier's `content` is
/// already `original + top-blur-overlay`, i.e. two instantiations, and it
/// overlays a second copy of that pair. On a long thread every one of those
/// copies re-runs the full view build + text layout of every turn on the main
/// thread the instant the view mounts, which is what made opening a long agent
/// record stall. One modifier = 2 instantiations (the live one plus its single
/// blurred copy), rendering identically: the gradient mask below simply carries
/// both tapers — opaque at each edge, clear across the middle — instead of one.
struct ProgressiveEdgeBlur: ViewModifier {
    /// Band heights in points, measured inward from each edge.
    var topHeight: CGFloat
    var bottomHeight: CGFloat
    /// Peak blur radius at each edge. **Equal radii collapse to a single copy**
    /// — one blurred layer carrying both tapers in its mask. Unequal radii need
    /// two blurred layers, but they're laid as *siblings over the same base*,
    /// never nested, so it's 3 instantiations rather than the stacked pair's 4.
    var topRadius: CGFloat = 7
    var bottomRadius: CGFloat = 7

    func body(content: Content) -> some View {
        if topRadius == bottomRadius {
            content.overlay(band(content, top: true, bottom: true, radius: topRadius))
        } else {
            // Both overlays copy the ORIGINAL `content`, not each other's result.
            // (Blurring the top layer along with the content in the bottom band is
            // a no-op anyway: the top layer's own mask is already clear down there.)
            content
                .overlay(band(content, top: true, bottom: false, radius: topRadius))
                .overlay(band(content, top: false, bottom: true, radius: bottomRadius))
        }
    }

    /// One flattened, blurred copy of the content, masked to the requested edge
    /// band(s) — opaque at the edge, tapering to clear at the band's inner lip.
    private func band(_ content: Content, top: Bool, bottom: Bool,
                      radius: CGFloat) -> some View {
        GeometryReader { geo in
            let h = max(geo.size.height, 1)
            // Clamp each band to under half the view so the two tapers can never
            // cross and blur the whole region on a short viewport.
            let t = top ? min(topHeight / h, 0.45) : 0
            let b = bottom ? min(bottomHeight / h, 0.45) : 0
            content
                .drawingGroup()
                .blur(radius: radius)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: top ? .black : .clear, location: 0),
                            .init(color: top ? .black : .clear, location: max(t - t * 0.5, 0)),
                            .init(color: .clear, location: t),
                            .init(color: .clear, location: max(1 - b, t)),
                            .init(color: bottom ? .black : .clear, location: min(1 - b + b * 0.5, 1)),
                            .init(color: bottom ? .black : .clear, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .allowsHitTesting(false)
        }
    }
}

/// Mount/unmount `ProgressiveEdgeBlur` (the merged partner to
/// `ConditionalTopBlur` / `ConditionalBottomBlur`), so a resting or streaming
/// surface pays for no blurred copy at all.
struct ConditionalEdgeBlur: ViewModifier {
    var active: Bool
    var topHeight: CGFloat
    var bottomHeight: CGFloat
    var topRadius: CGFloat = 7
    /// Defaults to `topRadius` — leave it off whenever both edges share a radius,
    /// which is what lets the two bands ride one blurred copy.
    var bottomRadius: CGFloat? = nil

    func body(content: Content) -> some View {
        if active {
            content.progressiveEdgeBlur(top: topHeight, bottom: bottomHeight,
                                        topRadius: topRadius,
                                        bottomRadius: bottomRadius ?? topRadius)
        } else {
            content
        }
    }
}

extension View {
    /// Frost the top band of a scrolling region so rows passing behind a floating
    /// header blur out progressively (see `ProgressiveTopBlur`). Pair with
    /// `scrollEdgeFade(top:)` for the matching opacity taper.
    func progressiveTopBlur(height: CGFloat, maxRadius: CGFloat = 7) -> some View {
        modifier(ProgressiveTopBlur(height: height, maxRadius: maxRadius))
    }

    /// Frost BOTH runways (see `ProgressiveEdgeBlur`). Prefer this over stacking
    /// the top and bottom modifiers — stacking quadruples the content copies.
    /// Omit `bottomRadius` when both edges share a radius; that's the case that
    /// collapses to a single blurred copy.
    func progressiveEdgeBlur(top: CGFloat, bottom: CGFloat,
                             topRadius: CGFloat = 7,
                             bottomRadius: CGFloat? = nil) -> some View {
        modifier(ProgressiveEdgeBlur(topHeight: top, bottomHeight: bottom,
                                     topRadius: topRadius,
                                     bottomRadius: bottomRadius ?? topRadius))
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
/// its enclosing scroll view at runtime and calls `onChange` with the clip view's
/// origin along `axis` — `bounds.origin.y` (0 at the top, growing as the user
/// scrolls down) or, for a horizontal rail, `bounds.origin.x`.
struct ScrollOffsetObserver: NSViewRepresentable {
    var axis: ScrollEdgeFade.Axis = .vertical
    var onChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(axis: axis, onChange: onChange) }

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
        let axis: ScrollEdgeFade.Axis
        var onChange: (CGFloat) -> Void
        weak var clipView: NSClipView?

        init(axis: ScrollEdgeFade.Axis, onChange: @escaping (CGFloat) -> Void) {
            self.axis = axis
            self.onChange = onChange
        }

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
            onChange(axis == .vertical ? clip.bounds.origin.y : clip.bounds.origin.x)
        }
    }
}

extension View {
    /// Observe the enclosing scroll view's offset along `axis` (see
    /// `ScrollOffsetObserver`). Vertical by default; pass `.horizontal` for a rail,
    /// where the reported value is `bounds.origin.x` (0 at the leading edge).
    func onScrollOffsetChange(
        axis: ScrollEdgeFade.Axis = .vertical,
        _ action: @escaping (CGFloat) -> Void
    ) -> some View {
        background(ScrollOffsetObserver(axis: axis, onChange: action))
    }
}

// MARK: - Tooltip

/// Hover hints are drawn ONCE PER WINDOW, by a layer that sits above the whole
/// surface — not by an overlay hanging off each control. `notchTooltipClipBox()`
/// installs that layer (the island, the detached window, the archive window);
/// `notchTooltip(_:)` on a control only publishes "here is my rectangle, here is
/// my text".
///
/// That split is the fix for the capsule that kept getting sliced at the panel's
/// left and right edge. Earlier versions drew the capsule inside the control's
/// own subtree and tried to work out, from down there, how much room was left:
/// they recovered an ancestor's bounds through a named coordinate space or an
/// environment value (either can arrive a frame late, or not at all), guessed
/// whether an enclosing ScrollView was the thing really clipping it, and
/// pre-measured the capsule in a hidden twin so the first frame landed clamped.
/// Any one of those going wrong drew the capsule outside the clip and the glass
/// cut it in half — which is why the bug came back each time from a new
/// direction.
///
/// Three things keep this version honest:
///
/// - the control publishes a SwiftUI **`Anchor`**, not a rectangle. An anchor is
///   resolved BY the layer, in the layer's own space (`geo[request.anchor]`), so
///   there is no global-frame arithmetic to get wrong and no copy of the
///   control's position to keep in sync — scroll it, resize the window, and the
///   next layout pass simply resolves somewhere else;
/// - the layer is a SIBLING of the clipped content, not a descendant, so neither
///   the island's shape nor any ScrollView can chop it. A clamp that is off by a
///   few points now reads as slightly off-centre instead of losing half the text;
/// - the capsule is placed with `alignmentGuide`, which hands the layer the
///   capsule's real laid-out size DURING the same pass that positions it — no
///   measure-then-place round trip, so the first frame is already in place.
///
/// The one number the layer can't derive is how far inside its own layout frame
/// the DRAWN wall sits — the island's frame carries the two shoulder flares its
/// glass body doesn't (`ContentView.topFlare`), the detached window keeps a
/// transparent margin for its shadow. Each surface passes that as `inset`.

/// What a hovered control publishes: the text, the side it wants, and its own
/// bounds as an anchor for the layer to resolve.
private struct TooltipRequest {
    let text: String
    let edge: VerticalEdge
    let anchor: Anchor<CGRect>
}

/// Carries the request up to the window's layer. Only a hovered control
/// publishes one, so the reduce is simply "the last non-nil wins".
private struct TooltipRequestKey: PreferenceKey {
    static let defaultValue: TooltipRequest? = nil
    static func reduce(value: inout TooltipRequest?, nextValue: () -> TooltipRequest?) {
        if let next = nextValue() { value = next }
    }
}

/// Draws the capsule for whichever control currently owns the tip, clamped
/// inside this layer's own box.
private struct TooltipLayerView: View {
    let request: TooltipRequest
    /// How far inside this view's frame the drawn wall sits (see the note above).
    let inset: CGFloat

    /// Space between the capsule and the control it describes.
    private static let gap: CGFloat = 6
    /// Space between the capsule and the wall.
    private static let margin: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            // The control's rectangle, resolved in THIS view's coordinates.
            let anchor = geo[request.anchor]
            let wall = inset + Self.margin
            let available = max(geo.size.width - wall * 2, 80)
            let wraps = TooltipTextMetrics.oneLineWidth(request.text) > available
            ZStack(alignment: .topLeading) {
                // Fills the layer, so the guides below measure against the whole
                // surface rather than against the capsule itself.
                Color.clear
                TooltipLabel(text: request.text, width: wraps ? available : nil)
                    // Size to the text (or to the wrap width), never to the
                    // layer it is drawn in.
                    .fixedSize()
                    // `alignmentGuide` is what makes this exact: `d.width` /
                    // `d.height` ARE the capsule's laid-out size, in the same
                    // pass that places it. Returning `-x` puts its origin at x.
                    .alignmentGuide(HorizontalAlignment.leading) { d in
                        -Self.originX(width: d.width, anchor: anchor,
                                      wall: wall, host: geo.size)
                    }
                    .alignmentGuide(VerticalAlignment.top) { d in
                        -Self.originY(height: d.height, anchor: anchor,
                                      edge: request.edge, wall: wall, host: geo.size)
                    }
                    // A hint handed to another control is a new capsule, not one
                    // sliding across the panel.
                    .id(request.text)
                    .transition(.opacity)
            }
        }
        // Purely a readout: it never takes the click meant for the control.
        .allowsHitTesting(false)
    }

    /// Centred on the control, then pushed off whichever wall it would cross.
    private static func originX(width: CGFloat, anchor: CGRect,
                                wall: CGFloat, host: CGSize) -> CGFloat {
        let lower = wall
        let upper = host.width - wall - width
        // Wider than the room even after wrapping: centre it, both ends as far
        // in as they can be.
        guard upper > lower else { return (host.width - width) / 2 }
        return min(max(anchor.midX - width / 2, lower), upper)
    }

    /// The requested side when it fits, the other side when it doesn't — a
    /// control near the top edge gets its hint below rather than half off the
    /// panel.
    private static func originY(height: CGFloat, anchor: CGRect, edge: VerticalEdge,
                                wall: CGFloat, host: CGSize) -> CGFloat {
        let above = anchor.minY - gap - height
        let below = anchor.maxY + gap
        let fitsAbove = above >= wall
        let fitsBelow = below + height <= host.height - wall
        let y: CGFloat
        switch edge {
        case .top:    y = (fitsAbove || !fitsBelow) ? above : below
        case .bottom: y = (fitsBelow || !fitsAbove) ? below : above
        }
        return min(max(y, wall), max(host.height - wall - height, wall))
    }
}

/// One-line width of a tip, measured through AppKit with the same font the
/// capsule draws in.
///
/// It answers ONE question — does this text still fit on a single line between
/// the walls — so a fraction of a point of disagreement with SwiftUI's own
/// layout is harmless: either answer looks right, and the capsule is placed from
/// its real size regardless. That is the whole reason the old hidden measuring
/// twins are gone: they existed to feed the POSITION, and a stale measurement
/// there put the capsule off the edge.
@MainActor
private enum TooltipTextMetrics {
    private static var cache: [String: CGFloat] = [:]

    static func oneLineWidth(_ text: String) -> CGFloat {
        if let hit = cache[text] { return hit }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .kern: 0.1,
        ]
        let width = (text as NSString).size(withAttributes: attrs).width.rounded(.up)
            + TooltipLabel.hPadding * 2
        if cache.count > 400 { cache.removeAll(keepingCapacity: true) }
        cache[text] = width
        return width
    }
}

/// Posted when a menu, popover, or menu card becomes the front chrome — hover
/// hints (tooltips, the source popup) should get out of its way. Depth is tracked
/// by `TooltipOverlayGate`; this fires only on the 0→1 edge.
extension Notification.Name {
    static let notchOverlayChromePresented = Notification.Name("notchOverlayChromePresented")
}

/// Counts live overlay chrome (NSMenu, NSPopover, the island's menu cards) so a
/// hover hint can refuse to show — and can hide — while one of those is up.
/// Hover stays true on the control that opened the overlay, and a brief
/// mouse-exited/entered flicker as the overlay window appears would otherwise
/// reschedule the tip on top of it.
@MainActor
enum TooltipOverlayGate {
    private(set) static var depth = 0
    static var blocked: Bool { depth > 0 }
    private static var installed = false

    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in enter() }
        }
        nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in exit() }
        }
        nc.addObserver(forName: NSPopover.willShowNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in enter() }
        }
        nc.addObserver(forName: NSPopover.didCloseNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in exit() }
        }
    }

    static func enter() {
        depth += 1
        if depth == 1 {
            NotificationCenter.default.post(name: .notchOverlayChromePresented, object: nil)
        }
    }

    static func exit() {
        depth = max(0, depth - 1)
    }
}

/// A hover tooltip drawn in the notch's own visual language instead of AppKit's
/// stock yellow `.help()` bubble — the flat OS tooltip that hasn't changed in
/// decades and reads as a foreign chip on the dark glass. This one is a small
/// dark capsule (a whisper of glass, a hairline rim, a soft drop shadow) with the
/// label in the same SF/text-token scale as the rest of the island, so a hover
/// hint over the answer's action icons feels like part of the surface.
///
/// Behaviour matches a real tooltip: it waits a beat (`delay`) after the cursor
/// settles before appearing — so brushing past an icon doesn't flash it — and
/// dismisses the instant the cursor leaves, the instant the user clicks, or the
/// instant overlay chrome (a menu, a popover, a menu card) presents. Hover stays
/// true while a menu is open under the pointer, so leave alone would leave the
/// capsule sitting on top of its own menu; a click also suppresses the tip until
/// the pointer actually leaves, so a hover flicker as the menu appears cannot
/// bring it back.
///
/// This modifier draws nothing: while the pointer rests here it publishes a
/// request, and the window's layer (see `notchTooltipClipBox`) does the drawing
/// and the clamping.
private struct NotchTooltip: ViewModifier {
    let text: String
    /// Which side of the control the tip floats on. Footer icons live at the
    /// panel's bottom, so `.top` (up, into the answer) is the default; controls
    /// pinned near the top edge pass `.bottom`. Either way the layer flips it
    /// when the chosen side has no room.
    var edge: VerticalEdge = .top
    /// Seconds the cursor must rest on the control before the tip appears.
    var delay: TimeInterval = 0.45

    @State private var hovering = false
    @State private var shown = false
    /// True after a click or overlay presentation, until the pointer leaves.
    @State private var suppressed = false
    /// Cancels a pending show if the cursor leaves before `delay` elapses.
    @State private var showTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            // The whole contribution from down here: this control's own bounds,
            // as an anchor the layer resolves into its own space, and only while
            // the tip is actually up.
            .anchorPreference(key: TooltipRequestKey.self, value: .bounds) { anchor in
                shown ? TooltipRequest(text: text, edge: edge, anchor: anchor) : nil
            }
            .onHover { inside in
                hovering = inside
                showTask?.cancel()
                if inside {
                    scheduleShow()
                } else {
                    suppressed = false
                    withAnimation(.easeOut(duration: 0.10)) { shown = false }
                }
            }
            // A control can leave while its hint is up (a row scrolls away, the
            // panel folds under the pointer): take the capsule with it.
            .onDisappear {
                showTask?.cancel()
                hovering = false
                suppressed = false
                shown = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .notchOverlayChromePresented)) { _ in
                hide()
            }
            .background {
                TooltipClickDismiss(enabled: hovering, hide: hide)
            }
    }

    private func scheduleShow() {
        guard !suppressed, !TooltipOverlayGate.blocked else { return }
        let d = delay
        showTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(d))
            guard !Task.isCancelled, hovering, !suppressed, !TooltipOverlayGate.blocked else { return }
            withAnimation(.easeOut(duration: 0.14)) { shown = true }
        }
    }

    private func hide() {
        showTask?.cancel()
        suppressed = true
        guard shown else { return }
        withAnimation(.easeOut(duration: 0.10)) { shown = false }
    }
}

/// Drops the tip on mouse-down without eating the click, so the Menu / Button
/// still receives it. Installed only while the pointer is on this control.
private struct TooltipClickDismiss: NSViewRepresentable {
    var enabled: Bool
    var hide: () -> Void

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.hide = hide
        context.coordinator.setEnabled(enabled)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.setEnabled(false)
    }

    final class Coordinator {
        var hide: () -> Void = {}
        private var monitor: Any?

        func setEnabled(_ enabled: Bool) {
            if enabled {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                    self?.hide()
                    return event
                }
            } else if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { setEnabled(false) }
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
    ///
    /// With no `width`, one line, sized to the text. With one, an EXACT frame —
    /// not `maxWidth`, which is the trap here: a flexible frame under
    /// `.fixedSize()` gets a nil proposal, hands the Text a nil proposal too, and
    /// the Text answers with its full one-line width; the frame then reports the
    /// clamped width while the text inside it stays laid out long and spills out
    /// both ends. A fixed frame proposes its own width down no matter what the
    /// parent proposed, so the text actually wraps.
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
    /// Installs the window's tooltip layer. Apply once per independently drawn
    /// surface (island, detached window, archive window), as far OUT as it goes —
    /// past the surface's own `clipShape`, so the capsule it draws can't be cut.
    ///
    /// `inset` is how far inside this view's layout frame the drawn wall sits:
    /// the island's frame carries the shoulder flares its glass body doesn't, the
    /// compact detached window keeps a transparent margin for its shadow. Pass
    /// that and every hint below stops at the glass, not at the frame.
    func notchTooltipClipBox(inset: CGFloat = 0) -> some View {
        overlayPreferenceValue(TooltipRequestKey.self) { request in
            if let request {
                TooltipLayerView(request: request, inset: inset)
            }
        }
        .onAppear { TooltipOverlayGate.installIfNeeded() }
    }

    /// Attach a `NotchTooltip` — the in-house replacement for `.help()`. Use it on
    /// the answer-footer action icons (copy / save / regenerate / info / pin) and
    /// any other island control that wants a hover hint in the panel's own voice.
    /// Pass `shows: false` to keep the control a silent chip (hover shows nothing)
    /// while the accessibility label still rides the caller's own `.accessibilityLabel`.
    @ViewBuilder
    func notchTooltip(_ text: String, edge: VerticalEdge = .top, delay: TimeInterval = 0.45, shows: Bool = true) -> some View {
        if shows {
            modifier(NotchTooltip(text: text, edge: edge, delay: delay))
        } else {
            self
        }
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
