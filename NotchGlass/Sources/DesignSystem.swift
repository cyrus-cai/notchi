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
    static let openWidthOnboarding: CGFloat = 720  // first-run guide: left controls + right demo pane
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
    /// Cancels a pending show if the cursor leaves before `delay` elapses.
    @State private var showTask: Task<Void, Never>?

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
                            withAnimation(.easeOut(duration: 0.14)) { shown = true }
                        }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.10)) { shown = false }
                }
            }
            // Anchor the tip's near edge to the control's matching edge, then push
            // it fully CLEAR of the control by its own measured height plus a gap —
            // so the capsule sits above (or below) the icon, never on top of it.
            // `.top` alignment pins their top edges together; the negative offset
            // then lifts the whole capsule up past the icon. (Mirror for `.bottom`.)
            .overlay(alignment: edge == .top ? .top : .bottom) {
                if shown {
                    TooltipLabel(text: text)
                        // Let it size to its text without being clipped to the
                        // anchor's width, and measure that height for the offset.
                        .fixedSize()
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(key: TooltipHeightKey.self,
                                                        value: g.size.height)
                            }
                        )
                        .onPreferenceChange(TooltipHeightKey.self) { tipHeight = $0 }
                        // Clear the control entirely: shift by the full capsule
                        // height + a 6pt breathing gap, in the away direction.
                        .offset(y: edge == .top ? -(tipHeight + 6) : (tipHeight + 6))
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

/// The capsule itself — factored out so the shadow/rim/material live in one place.
private struct TooltipLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.sf(11, weight: .medium))
            .tracking(0.1)
            .foregroundStyle(Tokens.text2)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                ZStack {
                    // A near-black glass wafer, not the stock yellow bubble.
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.62))
                        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                    Capsule(style: .continuous)
                        .strokeBorder(Tokens.hairline, lineWidth: 0.5)
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
