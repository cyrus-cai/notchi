import SwiftUI

/// A bottom-rounded rectangle — the island's silhouette. Top corners are square
/// (flush with the screen edge, like the hardware notch); only the bottom
/// corners round as the form grows.
struct NotchShape: InsettableShape {
    var bottomRadius: CGFloat
    /// Inset applied by `.strokeBorder` (and `inset(by:)`) so a stroked edge
    /// stays fully inside the fill instead of being clipped in half.
    var inset: CGFloat = 0

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        let r = min(bottomRadius, min(rect.width, rect.height) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
                 radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
                 radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.inset += amount
        return copy
    }
}

/// The island background — modeled on the iOS Control-Center / Now-Playing
/// **uniform dark Liquid Glass** look: one even slab of translucent dark glass
/// that refracts the wallpaper/app icons behind it across its *whole* surface
/// (the top included), wrapped in a continuous soft specular rim that reads as
/// the thickness of the glass.
///
/// Layers, back to front:
///  1. High-transparency native `.glassEffect(.clear)` over the whole shape —
///     real, strong refraction so the background bleeds through everywhere.
///  2. A single **even** dark veil (no top-to-bottom gradient) that tints the
///     whole slab so it reads as dark smoked glass and keeps text legible —
///     plus a faint top-edge sheen for a touch of depth, like the reference.
///  3. A thin camera-zone darkening at the very top so the hardware notch /
///     lens area stays discreet without going to a hard black band.
///  4. A continuous, soft **edge rim** all the way around — the signature look:
///     a bright fine line that wraps the entire perimeter, strongest at top and
///     bottom, fading on the straight sides.
struct GlassMaterial: View {
    var bottomRadius: CGFloat
    /// Whether the island is expanded. Resting (false) blends with the physical
    /// black bezel → near-opaque dark; expanded (true) becomes the translucent
    /// Control-Center glass that refracts the background.
    var expanded: Bool = false
    /// Height of the camera/lens zone at the very top that gets extra darkening
    /// so the hardware notch stays discreet over a transparent slab.
    var cameraZone: CGFloat = Tokens.notchTopHeight

    /// Drives the one-shot light sweep that plays as the panel expands. Flipped
    /// by `.onChange(of: expanded)` so the shimmer travels exactly once per open.
    @State private var sweep = false

    /// The base darkening baked into the native glass material as a tint (see
    /// `nativeGlass(in:)`) — chosen to match the panel's *lightest* veil value
    /// (the bottom edge), so along the bottom and corners, where the animation
    /// desync was most visible, escaped glass is indistinguishable from the
    /// settled panel. The veil subtracts this via `veilAlpha` to keep every
    /// composite target unchanged.
    static let bakedTint: Double = 0.34

    /// Whether the macOS 26 native glass (and therefore the baked tint) is in
    /// play; the legacy backdrop keeps the original full-strength veil.
    private var tintBaked: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// The veil opacity that, layered over the baked glass tint, composites to
    /// the originally tuned darkness: 1−(1−tint)(1−veil) = target.
    private func veilAlpha(_ target: Double) -> Double {
        guard tintBaked else { return target }
        return max(0, (target - GlassMaterial.bakedTint) / (1 - GlassMaterial.bakedTint))
    }

    var body: some View {
        let shape = NotchShape(bottomRadius: bottomRadius)

        // Build the whole material — glass + tint + cap + rim — then HARD-CUT it
        // to the shape as the final step. Clipping the composited group (rather
        // than letting the system glass draw its own soft luminous edge) removes
        // the "outer ring of glass": no refraction or glow bleeds past the
        // rounded corners, so the edge is crisp and the corner reads as solid.
        // `.clipShape` alone does the hard cut — a second same-shape `.mask` was
        // a redundant offscreen pass per animation frame and is gone.
        ZStack {
            shape.fill(.clear).nativeGlass(in: shape)
            darkVeil
            // The raking diagonal gloss over the lower body — faded in when
            // open. Both decorations stay MOUNTED at rest (opacity 0) instead
            // of being `if expanded`-inserted: each is a blurred offscreen
            // layer, and allocating those buffers on the open's very first
            // frame cost that frame its budget — a visible hitch right as the
            // expansion starts. An opacity flip under the open spring reads
            // identically to the old insertion fade.
            diagonalGloss(shape).opacity(expanded ? 1 : 0)
            blackCap(shape)
            expandShimmer(shape).opacity(expanded ? 1 : 0)
            // NOTE: the edge rim is intentionally NOT drawn here. It's stamped over
            // the island as a separate overlay *after* the bottom/left/right edge
            // fade (see `NotchIsland`), so the specular highlight keeps tracing the
            // edges crisply while the dark glass + content dissolve into them. If it
            // lived inside this masked group it would dissolve along with the fill.
        }
        .compositingGroup()
        .clipShape(shape)
        // A tight, downward-only drop shadow for separation — small radius so it
        // doesn't smear into a halo around the corners on a bright wallpaper.
        .background(
            shape
                .fill(.black.opacity(0.30))
                .blur(radius: 9)
                // Flatten the blurred shadow to one offscreen texture: its content is
                // a fixed solid fill (no height-derived gradient stops), so only the
                // geometry springs as the panel grows. Without this the radius-9
                // offscreen blur re-renders every frame of the expand; with it the
                // frame just scales the cached texture. Pixel-identical.
                .drawingGroup()
                .offset(y: 5)
                .allowsHitTesting(false)
        )
        .onChange(of: expanded) { _, isOpen in
            if isOpen {
                // Reset to the top instantly, then drive the sweep down on the
                // next runloop tick so the animation always plays from the start.
                sweep = false
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.7)) { sweep = true }
                }
            } else {
                sweep = false
            }
        }
    }

    /// A one-shot specular highlight that glides down the glass as it opens — a
    /// soft diagonal band of light, brightest mid-panel, that travels from the
    /// black lip to the bottom edge once and settles. Purely cosmetic; ignores
    /// hits. Clipped to the shape by the parent's mask.
    private func expandShimmer(_ shape: NotchShape) -> some View {
        GeometryReader { geo in
            let h = max(geo.size.height, 1)
            // Travel from just above the panel to just below it.
            let travel = h + 80
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.0),  location: 0.0),
                    .init(color: .white.opacity(0.10), location: 0.45),
                    .init(color: .white.opacity(0.18), location: 0.5),
                    .init(color: .white.opacity(0.10), location: 0.55),
                    .init(color: .white.opacity(0.0),  location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 110)
            .blur(radius: 6)
            // Flatten the blurred band to one offscreen texture (same trick as
            // the drop shadow below): its content is fixed — a 110pt gradient,
            // stops in fractions — so the 0.7s sweep animates a cached raster
            // via the offset transform instead of re-running the radius-6 blur
            // on every frame of the travel. Pixel-identical.
            .drawingGroup()
            .offset(y: sweep ? travel - 55 : -110)
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }

    /// A soft diagonal **specular gloss** raking across the lower body — the bright
    /// streak of light reflecting off a thick glass slab in the reference. A wide,
    /// blurred bright band angled across the panel and pushed toward the lower-right,
    /// kept low and `.plusLighter` so it reads as a gloss on the obsidian rather than
    /// a white wedge. Clipped to the shape by the parent's mask; purely cosmetic.
    private func diagonalGloss(_ shape: NotchShape) -> some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.0),  location: 0.0),
                    .init(color: .white.opacity(0.0),  location: 0.42),
                    .init(color: .white.opacity(0.06), location: 0.5),
                    .init(color: .white.opacity(0.10), location: 0.56),
                    .init(color: .white.opacity(0.0),  location: 0.66),
                    .init(color: .white.opacity(0.0),  location: 1.0),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            // Oversize + rotate so the band sweeps the lower-right corner area at a
            // shallow diagonal, like raking light, then blur it to a soft gloss.
            .frame(width: w * 1.8, height: h * 1.8)
            // Blur BEFORE the rotation (a gaussian is isotropic, so blur∘rotate
            // and rotate∘blur are the same picture) and flatten to one offscreen
            // texture — the drop-shadow trick. The radius-14 blur over a 1.8×
            // oversized band was the panel's biggest filter pass, re-run on every
            // frame of the open/close spring; flattened, the rotation and offset
            // ride the cached raster as plain transforms.
            .blur(radius: 14)
            .drawingGroup()
            .rotationEffect(.degrees(-18))
            .offset(x: w * 0.12, y: h * 0.30)
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }

    /// A hard, **true #000** cap painted over the camera/notch zone, sitting
    /// ABOVE the glass and the veil. The system glass adds a faint frosted blue
    /// cast that kept the top from matching the pure-black hardware bezel; an
    /// explicit opaque black here guarantees the top fuses seamlessly with the
    /// physical notch. It fades out over the melt band so the seam into the glass
    /// below stays smooth.
    private func blackCap(_ shape: NotchShape) -> some View {
        GeometryReader { geo in
            let h = max(geo.size.height, cameraZone + 1)
            let solidEnd = min(cameraZone / h, 0.985)
            let fadeEnd = min(solidEnd + 46 / h, 0.999)
            LinearGradient(
                stops: [
                    .init(color: .black,               location: 0.0),
                    .init(color: .black,               location: solidEnd),
                    .init(color: .black.opacity(0.0),  location: fadeEnd),
                    .init(color: .black.opacity(0.0),  location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        // No own `.clipShape` here: the parent `GlassMaterial.body` already clips
        // the whole composited group to `shape`, so a second cut is redundant.
        .allowsHitTesting(false)
    }

    /// The veil that tints the slab. Two behaviours:
    ///
    ///  · **Resting** — nearly opaque everywhere so the small notch blends into
    ///    the physical black bezel.
    ///  · **Expanded** — a *solid black top that melts into uniform glass*:
    ///    fully-opaque black across the camera/notch zone (so it fuses with the
    ///    hardware notch — no wallpaper showing through up there), then easing
    ///    over a soft band into the even ~0.55 smoked-glass tint that holds for
    ///    the rest of the panel. The black zone is anchored in *absolute points*
    ///    via the rendered height so it stays a constant size as the panel grows.
    private var darkVeil: some View {
        GeometryReader { geo in
            let h = max(geo.size.height, cameraZone + 1)
            // Opaque-black through the notch zone, then a melt band down to the
            // glass tint.
            let solidEnd = min(cameraZone / h, 0.985)
            let meltEnd = min(solidEnd + 60 / h, 0.999)   // ~60pt melt band
            // The glass is darkest just under the black notch lip and eases more
            // translucent toward the bottom — matching real dark Liquid Glass, where
            // the top reads near-solid and the lower body lets more of the
            // background warmth bleed through. Two values: the tint right after the
            // melt (`glassTop`) and the lighter tint at the very bottom edge
            // (`glassBottom`), ramped between so the panel grows clearer downward
            // without ever going fully clear (text keeps a dark backing throughout).
            let glassTop = 0.62
            let glassBottom = 0.34

            ZStack {
                if expanded {
                    // Targets pass through `veilAlpha`, which discounts the
                    // darkening already baked into the glass tint — the
                    // composite stays exactly the tuned values above.
                    LinearGradient(
                        stops: [
                            .init(color: .black,                                  location: 0.0),
                            .init(color: .black,                                  location: solidEnd),
                            .init(color: .black.opacity(veilAlpha(glassTop)),     location: meltEnd),
                            .init(color: .black.opacity(veilAlpha(glassBottom)),  location: 1.0),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                } else {
                    Color.black.opacity(veilAlpha(0.92))
                }

                // Subtle brighter sheen just under the black lip — depth.
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.05), location: solidEnd),
                        .init(color: .white.opacity(0.0),  location: min(solidEnd + 40 / h, 1.0)),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .blendMode(.plusLighter)
            }
        }
    }

}

/// The island's specular edge — a **lit, beveled rim** that wraps the bottom and
/// both sides, brightest where the glass is thickest at the rounded corners. This
/// is what gives the form its "slab of glass" depth in place of fading the fill to
/// nothing: the dark body holds (text stays legible) and the *edge* catches light.
/// The top shows no rim at all — it fuses with the black hardware notch.
///
/// Two passes make the bevel read as thickness, not a drawn outline:
///  • a crisp bright **outer hairline** right on the perimeter, and
///  • a soft **inner glow** just inside it (a blurred, inset stroke) so the light
///    falls off into the glass rather than stopping at a hard line.
/// Both ride a top→bottom gradient (dark at top, bright along the bottom curve),
/// so the corners — where bottom meets side — read brightest, like the reference.
///
/// Lives as its own view (not a layer inside `GlassMaterial`'s masked group) so it
/// can be stamped over the island after the body is composited — the highlight
/// traces the edge crisply instead of being masked away with the fill.
struct IslandRim: View {
    var shape: NotchShape

    var body: some View {
        ZStack {
            // Soft inner glow — a blurred stroke set in from the edge, giving the
            // bevel its luminous thickness so the light eases into the glass.
            shape
                .inset(by: 1.0)
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.0),  location: 0.0),
                            .init(color: .white.opacity(0.04), location: 0.5),
                            .init(color: .white.opacity(0.13), location: 1.0),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 2.5
                )
                .blur(radius: 2.5)
                .blendMode(.plusLighter)

            // Crisp outer hairline right on the perimeter — the bright edge of the
            // glass catching light. Brightest along the bottom; absent at the top.
            shape
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.0),  location: 0.0),
                            .init(color: .white.opacity(0.08), location: 0.5),
                            .init(color: .white.opacity(0.26), location: 1.0),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.9
                )
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// Apply genuine system Liquid Glass on macOS 26+, with a graceful blurred
    /// fallback on older systems. We use the **high-transparency** `.clear`
    /// variant so the wallpaper / app icons refract strongly through the whole
    /// slab (the iOS Control-Center look); our own even dark veil supplies the
    /// smoked tint and keeps text legible. Reused by the quick-tools popover so it
    /// shares the panel's glass instead of an opaque slab.
    @ViewBuilder
    func nativeGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            // The tint bakes the panel's BASE darkening into the glass material
            // itself instead of leaving it all to the SwiftUI veil above. The
            // system renders the glass in its own backdrop layer whose geometry
            // animates out of sync with SwiftUI's per-frame spring layout (the
            // window server interpolates it independently) — during the open
            // spring, slivers of glass routinely escape the veil along the
            // growing edges. A tinted material can never desync from itself, so
            // an escaped sliver now reads as the same smoked glass as the panel
            // body instead of a bright unveiled band. `darkVeil` subtracts this
            // tint from its own stops so the settled look is unchanged.
            self.glassEffect(.clear.tint(.black.opacity(GlassMaterial.bakedTint)), in: shape)
        } else {
            self.background(LegacyGlassBackdrop().clipShape(shape))
        }
    }
}

/// Pre-macOS 26 fallback: an `NSVisualEffectView` dark blur (best we can do
/// without the native Liquid Glass material).
struct LegacyGlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .vibrantDark)
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
