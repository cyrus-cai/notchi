import AppKit
import SwiftUI

/// The answer written by hand instead of typeset — Settings → Appearance,
/// "Handwritten answers".
///
/// # Why a second voice at all
///
/// Everything else in the panel is a machine surface: SF, tight tracking, glass.
/// That is right for a tool, and wrong for the one moment the app is *talking to
/// you*. Handwriting mode re-voices only that moment — the assistant's prose —
/// so an answer reads like a note somebody left on your desk rather than a
/// printout. Nothing structural changes: same parser, same blocks, same copy
/// output. Only the ink changes.
///
/// # The stack
///
/// Chinese isn't set in a font at all — it is *drawn*, stroke by stroke in stroke
/// order, by `StrokeInk`. Read that file for why; the short version is that
/// writing a character in stroke order needs its stroke shapes and its stroke
/// centrelines to come from the same source, and a shipped font only has the
/// first. So the ink is the centreline, and the "typeface" for Chinese is a
/// rounded marker whose weight is a number we choose.
///
/// Latin/digits: **Caveat** (SIL OFL, bundled, 400 KB) — a casual, near-monoline
/// hand, picked to read as the *same pen* as that marker. A modulated script like
/// Dancing Script sits beside the ink as an obviously different instrument. Caveat
/// also carries a real `wght` axis from 400 to 700, which matters more than it
/// sounds: single-weight handwriting faces leave `**bold**` with nothing to
/// resolve to (see below).
///
/// Anything neither covers — kana, Hangul, rare hanzi, punctuation, symbols —
/// falls through Core Text to the system face and simply arrives as type. The
/// answer stays readable; it just isn't handwritten.
///
/// # Why every face is resolved explicitly, never by trait
///
/// Pinning variation coordinates pins the font instance, and **trait promotion
/// then stops working**: `convert(toHaveTrait: .bold)` on a pinned face returns
/// the same regular instance, and `.italic` on one comes back with a matrix
/// shear of exactly 0. Both were measured, not assumed. So SwiftUI's implicit
/// emphasis — the thing that renders `**bold**` and `*italic*` — would silently
/// do nothing, and every emphasis in an answer would flatten into body text.
/// Bold, italic and inline code are therefore each resolved to a concrete font
/// here and applied as explicit per-run attributes (see `InlineMarkdownText`).
///
/// Keeps the unfinished handwriting path dormant without discarding its
/// implementation or the user's saved preference. Mirrors `ForceClickFeature`.
enum HandwritingFeature {
    static let isEnabled = false
}

enum Handwriting {
    // MARK: - Faces

    /// The bundled Latin family. Registered automatically at launch via
    /// `ATSApplicationFontsPath` (Info.plist → `Fonts`), same as the brand face.
    ///
    /// **Caveat**, chosen to match the marker that `StrokeInk` draws Chinese with:
    /// near-monoline, rounded, casual. The alternatives all failed on one of two
    /// counts — Dancing Script and other modulated scripts read as a different
    /// instrument beside flat marker ink, and Gochi Hand and Patrick Hand match
    /// the pen but ship a single weight, which would leave `**bold**` with nothing
    /// to resolve to.
    private static let latinFamily = "Caveat"

    /// CJK faces, used only for *metrics* and as the fallback when a character has
    /// no stroke data. The ink normally draws over these glyphs' positions without
    /// ever drawing the glyphs themselves — see `StrokeInk`.
    private static let cjkRegular = ["HanziPenSC-W3", "STKaitiSC-Regular", "HannotateSC-W5"]
    private static let cjkBold = ["HanziPenSC-W5", "STKaitiSC-Bold", "HannotateSC-W7"]

    // MARK: - Size and slant

    /// Points added to a handwritten run over the nominal prose size — Latin and
    /// CJK separately, because they do not lift together.
    ///
    /// Caveat's x-height is 0.40 em against SF's 0.53, so set at the nominal size
    /// its lowercase reads a third smaller than the interface around it; +5 brings
    /// the x-heights level. The CJK number is the em the stroke ink is scaled to,
    /// tuned to sit level with that.
    ///
    /// The two are measured, not shared: the previous pairings needed +0/+1.5 and
    /// +3/+3, and a mixed sentence set at one size read visibly lopsided every
    /// time the faces changed.
    private static let latinLift: CGFloat = 7
    private static let cjkLift: CGFloat = 4

    /// Slant applied to italic runs, as a fraction of the em.
    ///
    /// Sheared rather than swapped for an italic face, because there isn't one —
    /// Caveat is a single upright family. And the trait can't do
    /// it either: asking a variation-pinned descriptor for `.italic` returns the
    /// upright face unchanged (measured — the resulting font's matrix shear is
    /// exactly 0), so `*italic*` would silently render as body text, the same way
    /// `**bold**` would without the explicit weights below. A small real shear is
    /// the honest option left; on a script that already flows it reads as a lean,
    /// not as a synthetic slant.
    private static let italicSlant: CGFloat = 0.16

    /// Weight axis positions. Caveat's `wght` runs 400–700; its default 400 is
    /// lighter than the marker ink beside it, so even "regular" sits at 500.
    private static func axisWeight(for weight: Font.Weight) -> CGFloat {
        switch weight {
        case .ultraLight, .thin, .light: return 400
        case .medium:                    return 600
        case .semibold:                  return 650
        case .bold, .heavy, .black:      return 700
        default:                         return 500
        }
    }

    // MARK: - Public resolution

    /// The handwriting face for Latin prose at the nominal `size`.
    static func font(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        guard latinAvailable else { return .sf(size, weight: weight) }
        return Font(nsFont(size + latinLift, weight: weight, italic: italic) as CTFont)
    }

    /// The em CJK is actually set at, for the nominal prose `size`. The stroke
    /// ink scales to this, so it lands exactly where the glyph would have.
    static func cjkEm(_ size: CGFloat) -> CGFloat { size + cjkLift }

    /// The same hand at the size CJK needs to sit level with it.
    static func cjkFont(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        guard latinAvailable else { return .sf(size, weight: weight) }
        return Font(nsFont(size + cjkLift, weight: weight, italic: italic) as CTFont)
    }

    /// Whether the bundled Latin family actually registered.
    ///
    /// Worth checking explicitly, because the failure is silent otherwise:
    /// descriptor matching is fuzzy, so `NSFont(descriptor:size:)` for a family
    /// that isn't installed doesn't return nil — it returns *something*, and the
    /// mode would render every answer in a system fallback while claiming to be
    /// handwriting. Falling back to the printed voice is the honest outcome: the
    /// user sees the toggle do nothing, which is a bug they can report, rather
    /// than an answer quietly set in the wrong face.
    ///
    /// Computed once. `availableFontFamilies` walks every font on the machine.
    private static let latinAvailable: Bool =
        NSFontManager.shared.availableFontFamilies.contains(latinFamily)

    /// Inline `code` inside a handwritten answer. Code is machine text even when
    /// the prose around it isn't, so it stays monospaced — but a shade smaller,
    /// because SF Mono's x-height overshoots the hand it's embedded in.
    static func codeFont(_ size: CGFloat) -> Font {
        .system(size: size - 0.5, weight: .regular, design: .monospaced)
    }

    /// Extra leading a handwritten line takes over the typeset one, as a multiple
    /// of the base size.
    ///
    /// Script faces reach further above and below the baseline than SF does —
    /// 行楷's descending strokes especially — and both lifts above make the line
    /// box taller again. This keeps a dense paragraph's strokes from tangling
    /// with the line under it.
    static let extraLineSpacing: CGFloat = 0.2

    /// Where the setting lives. Named here rather than at either reader because
    /// it has two: `NotchModel.handwrittenAnswers` for the panel, which observes
    /// the model, and an `@AppStorage` in the detached window, which deliberately
    /// does not (see `DetachedSessionRootView`).
    static let defaultsKey = "handwrittenAnswers"

    // MARK: - Construction

    private struct Key: Hashable {
        let size: CGFloat
        let weight: Int
        let italic: Bool
    }

    /// Resolved fonts, memoized. A streaming answer re-renders every ~33ms across
    /// several mounted copies of the same turn, and each render asks for the same
    /// handful of (size, weight, italic) combinations — building the descriptor
    /// and matching the cascade every time would put font matching on the main
    /// thread at flush rate. The set of distinct keys an answer uses is tiny
    /// (body, four heading sizes, bold, italic), so this never grows.
    ///
    /// Guarded by a lock rather than confined to the main actor: the font is also
    /// asked for from `MarkdownParser`-adjacent code paths that SwiftUI may
    /// evaluate off the main thread.
    private static let cacheLock = NSLock()
    private static var cache: [Key: NSFont] = [:]

    private static func nsFont(_ size: CGFloat, weight: Font.Weight, italic: Bool) -> NSFont {
        let key = Key(size: size, weight: Int(axisWeight(for: weight)), italic: italic)
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        let built = build(size: size, axis: CGFloat(key.weight), italic: italic)
        cacheLock.lock()
        cache[key] = built
        cacheLock.unlock()
        return built
    }

    private static func build(size: CGFloat, axis: CGFloat, italic: Bool) -> NSFont {
        // The CJK cascade tracks the Latin weight: a bold run should be bold in
        // both scripts, and 翩翩体 ships a real W5 for exactly that.
        let cjk = axis >= 600 ? cjkBold : cjkRegular

        var attributes: [NSFontDescriptor.AttributeName: Any] = [.family: latinFamily]
        attributes[.init(rawValue: kCTFontVariationAttribute as String)] = [fourCC("wght"): axis]
        // A cascade list REPLACES Core Text's default one, but not its last-resort
        // pass — a glyph none of these faces covers still falls through to the
        // system font rather than rendering as tofu.
        attributes[.init(rawValue: kCTFontCascadeListAttribute as String)] =
            cjk.map { NSFontDescriptor(fontAttributes: [.name: $0]) }

        var descriptor = NSFontDescriptor(fontAttributes: attributes)
        if italic {
            // Normalised matrix — Core Text scales it by the point size, so m11
            // and m22 stay at 1 and only the shear term is set. Building the
            // matrix at point size instead makes the font come back at size².
            descriptor = descriptor.addingAttributes([
                .matrix: AffineTransform(m11: 1, m12: 0, m21: italicSlant, m22: 1, tX: 0, tY: 0)
            ])
        }

        // Falling back to the system face keeps a missing/unregistered bundle font
        // from taking the whole answer down to nothing.
        return NSFont(descriptor: descriptor, size: size)
            ?? .systemFont(ofSize: size, weight: axis >= 600 ? .semibold : .regular)
    }

    /// OpenType axis tags are four-character codes packed into an int — the form
    /// `kCTFontVariationAttribute` wants as its dictionary key.
    private static func fourCC(_ tag: String) -> Int {
        var value: UInt32 = 0
        for byte in tag.utf8 { value = (value << 8) | UInt32(byte) }
        return Int(value)
    }
}

// MARK: - Drawn marks

/// The non-letter marks of an answer, drawn instead of ruled — the horizontal
/// rule, the block-quote bar, the list bullet, the task checkbox.
///
/// # Why these exist
///
/// Re-facing the letters alone gets you handwriting inside a machine's ruling: a
/// paragraph in somebody's hand, and then a 0.5pt geometric hairline under it. The
/// rule reads as the seam of the illusion — it is the one mark on screen that a
/// person could not have made. Four small shapes close it.
///
/// # What they deliberately keep
///
/// Every one of these takes the *same* colour, weight and footprint as the
/// geometric version it replaces (`Tokens.hairline` at 0.5pt, the 3pt quote bar,
/// the 16pt marker gutter). Only the path changes. A drawn mark that also grew
/// heavier or moved would be a second, unasked-for design change riding along
/// with this one.
///
/// # Why the wobble is seeded, not random
///
/// A shape re-runs its `path(in:)` on every layout pass — while an answer streams,
/// that is tens of times a second. Wobble from a live RNG would make every rule on
/// screen crawl, which reads as a rendering fault rather than as a hand. Each
/// shape therefore takes a `seed` and derives its jitter from a tiny deterministic
/// generator: the same mark draws identically forever, and two different marks in
/// the same answer still differ from each other.
enum Ink {
    /// A small deterministic generator. Not a good RNG and doesn't need to be —
    /// it needs to be *stable*, cheap, and to decorrelate neighbouring marks.
    struct Wobble {
        private var state: UInt64
        init(seed: Int) { state = UInt64(bitPattern: Int64(seed)) | 1 }
        /// Next value in `-1...1`. The `* 2 - 1` matters: dividing a non-negative
        /// draw by its own maximum yields `0...1`, and subtracting one from that
        /// gives `-1...0` — every mark would then lean the same way instead of
        /// wobbling, which is exactly what a hand doesn't do.
        mutating func next() -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 33) / Double(UInt32.max >> 1)
            return CGFloat(unit * 2 - 1)
        }
    }

    /// The `---` rule, drawn as one pass of a pen: a shallow wave through a few
    /// control points, tilted a hair off level, overshooting at each end the way
    /// a hand does when it doesn't stop exactly on the mark.
    ///
    /// The tilt is doing most of the work. A wave alone, at the amplitude a
    /// hairline can carry, is invisible across a 400pt panel — but a rule that
    /// isn't quite level reads as drawn instantly, at any width.
    struct Rule: Shape {
        var seed: Int = 0

        func path(in rect: CGRect) -> Path {
            var wobble = Wobble(seed: seed)
            // Amplitude and tilt both stay near a point: enough that the eye
            // reads "drawn", not enough to look like a damaged line.
            let amplitude: CGFloat = 1.1
            let tilt = wobble.next() * 1.3
            let segments = max(4, Int(rect.width / 46))
            let step = rect.width / CGFloat(segments)
            let overshoot = 2 + abs(wobble.next()) * 2

            func y(at fraction: CGFloat) -> CGFloat {
                rect.midY + tilt * (fraction - 0.5) * 2 + wobble.next() * amplitude
            }

            var path = Path()
            var previous = CGPoint(x: rect.minX - overshoot, y: y(at: 0))
            path.move(to: previous)
            for index in 1...segments {
                let point = CGPoint(x: rect.minX + step * CGFloat(index),
                                    y: y(at: CGFloat(index) / CGFloat(segments)))
                // Curve through the midpoint of each pair so the joins stay
                // smooth — a polyline would read as a zigzag, not a wave.
                let control = CGPoint(x: (previous.x + point.x) / 2, y: previous.y)
                path.addQuadCurve(to: point, control: control)
                previous = point
            }
            path.addLine(to: CGPoint(x: rect.maxX + overshoot,
                                     y: previous.y + wobble.next() * 0.5))
            return path
        }
    }

    /// The block-quote bar: one downward stroke, bowed and leaning slightly, the
    /// way a margin line drawn freehand alongside a paragraph does.
    struct Stroke: Shape {
        var seed: Int = 0

        func path(in rect: CGRect) -> Path {
            var wobble = Wobble(seed: seed)
            // Kept inside the 3pt band the ruled bar occupies: the overlay this
            // sits in is that wide, and a bow that leaves it gets clipped flat —
            // which is exactly how a "drawn" bar ends up looking ruled again.
            let bow = wobble.next() * 1.0
            let lean = wobble.next() * 0.5
            let x = rect.midX
            var path = Path()
            path.move(to: CGPoint(x: x - lean, y: rect.minY + 1))
            path.addQuadCurve(
                to: CGPoint(x: x + lean, y: rect.maxY - 1),
                control: CGPoint(x: x + bow, y: rect.midY))
            return path
        }
    }

    /// A list bullet as a pen would leave it: a blob, not a circle. Five points
    /// around a small radius, each pushed in or out a little.
    struct Dot: Shape {
        var seed: Int = 0

        func path(in rect: CGRect) -> Path {
            var wobble = Wobble(seed: seed)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2
            var points: [CGPoint] = []
            for index in 0..<5 {
                let angle = Double(index) / 5 * 2 * .pi + Double(wobble.next()) * 0.2
                let reach = radius * (1 + wobble.next() * 0.22)
                points.append(CGPoint(x: center.x + reach * CGFloat(cos(angle)),
                                      y: center.y + reach * CGFloat(sin(angle))))
            }
            var path = Path()
            path.move(to: points[0])
            for index in 0..<points.count {
                let current = points[index]
                let next = points[(index + 1) % points.count]
                path.addQuadCurve(to: CGPoint(x: (current.x + next.x) / 2,
                                              y: (current.y + next.y) / 2),
                                  control: current)
            }
            path.closeSubpath()
            return path
        }
    }

    /// A task item's box — four strokes that *overshoot* the corners rather than
    /// mitring into them. The crossing ends are the whole tell: a square whose
    /// corners meet exactly reads as a rectangle primitive no matter how much the
    /// sides wobble.
    struct Box: Shape {
        var seed: Int = 0

        func path(in rect: CGRect) -> Path {
            var wobble = Wobble(seed: seed)
            let inset = rect.insetBy(dx: 1.5, dy: 1.5)
            var path = Path()

            /// One side, extended past both ends by up to a point and a half and
            /// bowed slightly in the middle.
            func side(from: CGPoint, to: CGPoint) {
                let dx = to.x - from.x, dy = to.y - from.y
                let length = max(sqrt(dx * dx + dy * dy), 0.001)
                let ux = dx / length, uy = dy / length
                let head = 0.4 + abs(wobble.next()) * 1.2
                let tail = 0.4 + abs(wobble.next()) * 1.2
                let start = CGPoint(x: from.x - ux * head, y: from.y - uy * head)
                let end = CGPoint(x: to.x + ux * tail, y: to.y + uy * tail)
                // Bow perpendicular to the side, so the wobble bends the line
                // rather than shortening it.
                let bulge = wobble.next() * 0.7
                let control = CGPoint(x: (start.x + end.x) / 2 - uy * bulge,
                                      y: (start.y + end.y) / 2 + ux * bulge)
                path.move(to: start)
                path.addQuadCurve(to: end, control: control)
            }

            let slip = { wobble.next() * 0.8 }
            let topLeft = CGPoint(x: inset.minX + slip(), y: inset.minY + slip())
            let topRight = CGPoint(x: inset.maxX + slip(), y: inset.minY + slip())
            let bottomRight = CGPoint(x: inset.maxX + slip(), y: inset.maxY + slip())
            let bottomLeft = CGPoint(x: inset.minX + slip(), y: inset.maxY + slip())
            side(from: topLeft, to: topRight)
            side(from: topRight, to: bottomRight)
            side(from: bottomRight, to: bottomLeft)
            side(from: bottomLeft, to: topLeft)
            return path
        }
    }

    /// The tick in a checked task — two strokes, the second longer and steeper,
    /// breaking out past the box like a real one does.
    struct Tick: Shape {
        var seed: Int = 0

        func path(in rect: CGRect) -> Path {
            var wobble = Wobble(seed: seed)
            let width = rect.width, height = rect.height
            let elbow = CGPoint(x: rect.minX + width * 0.42 + wobble.next() * 0.6,
                                y: rect.minY + height * 0.78)
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + width * 0.08,
                                  y: rect.minY + height * 0.52 + wobble.next() * 0.6))
            path.addQuadCurve(to: elbow,
                              control: CGPoint(x: rect.minX + width * 0.24,
                                               y: rect.minY + height * 0.68))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - width * 0.02,
                            y: rect.minY + height * 0.1 + wobble.next() * 0.6),
                control: CGPoint(x: rect.minX + width * 0.7, y: rect.minY + height * 0.34))
            return path
        }
    }
}

// MARK: - Environment

/// Whether the prose in this subtree is handwritten.
///
/// Carried in the environment rather than passed down every call site because
/// the answer renderer is reached through half a dozen containers (panel thread,
/// detached thread, height probe, blur overlay copies). The *rows* still take it
/// as a stored property — see `MarkdownBlockRow`, which is `.equatable()` and so
/// would not otherwise re-evaluate when the setting flips.
private struct HandwritingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var handwritten: Bool {
        get { self[HandwritingKey.self] }
        set { self[HandwritingKey.self] = newValue }
    }
}

/// The one place a font is chosen for answer prose, so printed and handwritten
/// can never drift apart in how they respond to size and weight.
///
/// `hand == false` returns exactly what the call site used before this feature
/// existed, which is why turning the mode off is a true no-op rather than an
/// approximation of the old look.
func proseFont(_ size: CGFloat, weight: Font.Weight = .regular, hand: Bool) -> Font {
    hand ? Handwriting.font(size, weight: weight) : .sf(size, weight: weight)
}
