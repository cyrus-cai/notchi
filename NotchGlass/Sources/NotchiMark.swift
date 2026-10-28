import SwiftUI

/// Notchi's mark from the app icon: two rounded eyes, each with a wide curve on
/// its top-left corner and a tight one on its top-right. Inside the open panel
/// it stands in for every "thinking" indicator: the wait line beside the status
/// word, the pending bubble, a Recent row whose answer is still streaming.
///
/// While it waits the mark does not loop one move. A director (`NotchiDirector`)
/// plays a run of forms (`NotchiForm`): the two eyes glancing, pondering,
/// rolling or tilting, and between those the eyes turning into something else —
/// fused into one body, split into three dots, flipped into quote marks, one
/// circling the other, equalizer bars, bouncing balls. Every form is the same
/// four shapes (`NotchiBlob`) in a different arrangement, so a change of form
/// is the shapes flowing from one arrangement into the next, not a cut. Each
/// mood draws from its own set of forms.
///
/// Draws per frame while on screen, like the dotted orb it replaced; it is only
/// on screen while a round is working.
struct NotchiMark: View {
    enum Mood: Hashable {
        /// Waiting with nothing to say yet; the same set as `.composing`.
        case waiting
        /// Thinking with no tool running.
        case composing
        /// Searching or reading a page.
        case searching
        /// A repeat search round ("digging deeper").
        case solving
        /// Any other tool running.
        case working
        /// Translating.
        case connecting

        init(_ state: OrbState) {
            switch state {
            case .composing: self = .composing
            case .searching: self = .searching
            case .solving: self = .solving
            case .working: self = .working
            case .connecting: self = .connecting
            }
        }
    }

    var mood: Mood = .composing
    /// Height of one open eye. The mark lays out 1.78× as wide; forms that
    /// travel further draw past that box without moving the layout.
    var eyeHeight: CGFloat = 10
    /// Whole-mark opacity, for homes quieter than the wait line.
    var dim: Double = 1
    /// A director shared with other marks, so they play the same forms at the
    /// same moment. Nil gives the mark its own.
    var shared: NotchiDirector? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var own = NotchiDirector()
    private var director: NotchiDirector { shared ?? own }

    var body: some View {
        let h = eyeHeight
        Color.clear
            .frame(width: h * NotchiBlob.markWidth, height: h)
            .overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { ctx, size in
                        let blobs = reduceMotion
                            ? NotchiForm.restingEyes
                            : director.blobs(at: t, mood: mood)
                        NotchiBlob.draw(blobs, in: &ctx, size: size, unit: h)
                    }
                }
                .frame(width: h * NotchiBlob.canvasSpan, height: h * NotchiBlob.canvasSpan)
                .opacity(dim)
                .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Shapes

/// One of the four shapes every form is made of, in units of the eye height,
/// centred on the mark (x right, y down). The icon's eye is one setting of it;
/// a dot, a bar and a fused body are others.
struct NotchiBlob {
    var x: Double = 0
    var y: Double = 0
    var w: Double = 0
    var h: Double = 0
    /// Corner radii: top-left, top-right, bottom-right, bottom-left.
    var tl: Double = 0
    var tr: Double = 0
    var br: Double = 0
    var bl: Double = 0
    /// Rotation in radians about the shape's own centre.
    var rot: Double = 0
    var alpha: Double = 1
    /// Draw order: higher draws on top. Lets a shape pass behind another.
    var z: Double = 0

    /// The mark's layout width, in eye heights: two eyes and the gap.
    static let markWidth: CGFloat = 1.78
    /// The square the forms are drawn in, in eye heights. Every form stays
    /// inside ±1.1 of the centre.
    static let canvasSpan: CGFloat = 2.4

    // The icon's eye, traced from the 200pt master: 56 × 72, 28 radius on the
    // top-left and both bottom corners, 10 on the top-right.
    static let eyeW = 56.0 / 72.0
    static let bigR = 28.0 / 72.0
    static let smallR = 10.0 / 72.0
    /// Centre-to-centre distance of the two eyes: one eye width plus the gap.
    static let pitch = 1.0

    /// An eye. `lid` is the open fraction, `s` a uniform scale.
    static func eye(_ x: Double, _ y: Double = 0, s: Double = 1, lid: Double = 1,
                    sx: Double = 1, rot: Double = 0, alpha: Double = 1, z: Double = 0) -> NotchiBlob {
        NotchiBlob(x: x, y: y, w: eyeW * s * sx, h: max(0.06, lid) * s,
                   tl: bigR * s, tr: smallR * s, br: bigR * s, bl: bigR * s,
                   rot: rot, alpha: alpha, z: z)
    }

    /// A round dot of diameter `d`.
    static func dot(_ x: Double, _ y: Double, d: Double, alpha: Double = 1, z: Double = 0) -> NotchiBlob {
        NotchiBlob(x: x, y: y, w: d, h: d, tl: d / 2, tr: d / 2, br: d / 2, bl: d / 2,
                   alpha: alpha, z: z)
    }

    /// A capsule `w` wide and `h` tall.
    static func pill(_ x: Double, _ y: Double, w: Double, h: Double,
                     smallTopRight: Bool = false, alpha: Double = 1, z: Double = 0) -> NotchiBlob {
        let r = min(w, h) / 2
        return NotchiBlob(x: x, y: y, w: w, h: h, tl: r, tr: smallTopRight ? r * 0.36 : r,
                          br: r, bl: r, alpha: alpha, z: z)
    }

    /// Nothing, parked at a point so it can grow out of (or shrink into) it.
    static func hidden(_ x: Double = 0, _ y: Double = 0) -> NotchiBlob {
        NotchiBlob(x: x, y: y, alpha: 0)
    }

    static func lerp(_ a: NotchiBlob, _ b: NotchiBlob, _ f: Double) -> NotchiBlob {
        func m(_ p: Double, _ q: Double) -> Double { p + (q - p) * f }
        // Turn the short way: a form that ends after whole turns (`spin`)
        // must not unwind them while it blends into the next.
        var turn = (b.rot - a.rot).truncatingRemainder(dividingBy: 2 * .pi)
        if turn > .pi { turn -= 2 * .pi } else if turn < -.pi { turn += 2 * .pi }
        return NotchiBlob(x: m(a.x, b.x), y: m(a.y, b.y), w: m(a.w, b.w), h: m(a.h, b.h),
                          tl: m(a.tl, b.tl), tr: m(a.tr, b.tr), br: m(a.br, b.br), bl: m(a.bl, b.bl),
                          rot: a.rot + turn * f, alpha: m(a.alpha, b.alpha), z: m(a.z, b.z))
    }

    /// Top of each shape: warm off-white, the same ink as `NotchiFace`. Bottom:
    /// the icon's gradient mirrored for a dark surface, cooler and dimmer.
    static func draw(_ blobs: [NotchiBlob], in ctx: inout GraphicsContext, size: CGSize, unit: CGFloat) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let gradient = Gradient(colors: [NotchiMarkPose.ink, NotchiMarkPose.inkLow])
        for b in blobs.sorted(by: { $0.z < $1.z }) {
            let w = CGFloat(b.w) * unit, h = CGFloat(b.h) * unit
            guard w > 0.05, h > 0.05, b.alpha > 0.01 else { continue }
            let cap = min(w, h) / 2
            func r(_ v: Double) -> CGFloat { min(CGFloat(v) * unit, cap) }
            let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
            let shape = UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: r(b.tl), bottomLeading: r(b.bl),
                                   bottomTrailing: r(b.br), topTrailing: r(b.tr)),
                style: .continuous
            ).path(in: rect)
            let move = CGAffineTransform(translationX: c.x + CGFloat(b.x) * unit,
                                         y: c.y + CGFloat(b.y) * unit)
                .rotated(by: CGFloat(b.rot))
            var layer = ctx
            layer.opacity = b.alpha
            layer.fill(shape.applying(move),
                       with: .linearGradient(gradient,
                                             startPoint: CGPoint(x: 0, y: -h / 2).applying(move),
                                             endPoint: CGPoint(x: 0, y: h / 2).applying(move)))
        }
    }
}

// MARK: - Forms

/// One arrangement of the four shapes, as a function of time since the form
/// began. Slots 0 and 1 are the left and right eye in every eye form, so the
/// eyes are what turns into the dots, the bars or the body; slots 2 and 3 are
/// the extras those need.
enum NotchiForm: CaseIterable {
    // Eye forms: the two eyes doing something.
    case glance, ponder, squint, roll, tilt, stretch, peek
    // Transformations: the eyes become something else, then come back.
    case fuse, dots, quotes, orbit, bars, bounce, spin, swap, scanner, relay, bridge

    var isEyes: Bool {
        switch self {
        case .glance, .ponder, .squint, .roll, .tilt, .stretch, .peek: return true
        default: return false
        }
    }

    /// How long the form holds before the next one.
    var duration: Double {
        switch self {
        case .glance: return 2.8
        case .ponder: return 2.6
        case .squint: return 2.6
        case .roll: return 2.2
        case .tilt: return 2.4
        case .stretch: return 2.0
        case .peek: return 2.0
        case .fuse: return 3.0
        case .dots: return 2.9
        case .quotes: return 2.6
        case .orbit: return 3.0
        case .bars: return 2.6
        case .bounce: return 2.48
        case .spin: return 2.6
        case .swap: return 2.6
        case .scanner: return 2.8
        case .relay: return 2.8
        case .bridge: return 2.6
        }
    }

    /// The forms each mood plays. Eye forms and transformations alternate.
    static func pool(for mood: NotchiMark.Mood) -> (eyes: [NotchiForm], turns: [NotchiForm]) {
        switch mood {
        case .waiting, .composing:
            return ([.glance, .ponder, .roll, .tilt, .peek], [.fuse, .dots, .quotes, .orbit, .stretch, .spin])
        case .searching:
            return ([.glance, .squint, .roll], [.scanner, .orbit, .dots])
        case .solving:
            return ([.squint, .ponder, .tilt], [.spin, .fuse, .bars, .quotes])
        case .working:
            return ([.glance, .peek, .tilt], [.bars, .bounce, .spin, .dots, .stretch, .relay])
        case .connecting:
            return ([.glance, .tilt, .roll], [.swap, .quotes, .orbit, .fuse, .relay, .bridge])
        }
    }

    static let restingEyes: [NotchiBlob] = [
        .eye(-0.5), .eye(0.5), .hidden(), .hidden(),
    ]

    /// The shapes at `t` seconds into the form. `seed` (0..<1) varies the
    /// form between plays: which way it looks, which eye moves first.
    func blobs(_ t: Double, seed: Double) -> [NotchiBlob] {
        let side: Double = seed < 0.5 ? 1 : -1
        switch self {

        case .glance:
            // Three looks, each reached with a quick saccade and held.
            let spots: [(Double, Double)] = [(1, -1), (-1, -1), (1, 0), (-1, 0), (0, -1), (1, 1), (-1, 1), (0, 0)]
            func spot(_ i: Int) -> (Double, Double) {
                spots[Int(Double(spots.count) * Self.hash(seed, i)) % spots.count]
            }
            let hold = 0.9
            let i = min(Int(t / hold), 2)
            let local = t - Double(i) * hold
            let from = i == 0 ? (0.0, 0.0) : spot(i - 1)
            let to = spot(i)
            let f = Self.smooth(local / 0.14)
            let lx = from.0 + (to.0 - from.0) * f
            let ly = from.1 + (to.1 - from.1) * f
            let lid = Self.blink(t, at: 0.5 + Self.hash(seed, 9) * 1.6)
            return Self.eyes(lookX: lx, lookY: ly, lid: lid)

        case .ponder:
            // Up and to one side, drifting, with one slow thinking blink.
            let f = Self.smooth(t / 0.3)
            // Half shut, not closed: closed eyes read as asleep.
            let lid = 1 - 0.55 * Self.plateau(t, 1.0, 1.35, 1.75, 2.0)
            return Self.eyes(lookX: side * (0.9 + 0.3 * t / 2.6) * f, lookY: -f, lid: lid)

        case .squint:
            // Narrowed, looking down, reading across a line.
            let f = Self.smooth(t / 0.3) * (1 - Self.smooth((t - 2.3) / 0.3))
            let lx = 0.8 * sin(2 * .pi * t / 1.3) * f
            return Self.eyes(lookX: lx, lookY: 0.8 * f, lid: 1 - 0.45 * f, spread: 1 - 0.06 * f)

        case .roll:
            // One roll of the eyes, round and back to centre.
            let p = Self.smooth((t - 0.3) / 1.2)
            let a = -Double.pi / 2 + side * 2 * .pi * p
            let amount = sin(.pi * p)
            let lid = Self.blink(t, at: 1.75)
            return Self.eyes(lookX: cos(a) * amount, lookY: sin(a) * amount, lid: lid)

        case .tilt:
            // The head tilts one way, holds, then the other.
            let a = 0.24 * (Self.smooth(t / 0.4) - 2 * Self.smooth((t - 1.1) / 0.45) + Self.smooth((t - 2.0) / 0.35))
            let r = side * a
            return [
                .eye(-0.5 * cos(r), -0.5 * sin(r), rot: r),
                .eye(0.5 * cos(r), 0.5 * sin(r), rot: r),
                .hidden(), .hidden(),
            ]

        case .stretch:
            // Jelly: one eye tall and thin while the other goes short and wide.
            let k = sin(2 * .pi * t / 0.9) * (1 - Self.smooth((t - 1.6) / 0.4))
            func jelly(_ x: Double, _ k: Double) -> NotchiBlob {
                var b = NotchiBlob.eye(x, sx: 1 - 0.2 * k)
                b.h = 1 + 0.24 * k
                b.y = (1 - b.h) / 2
                return b
            }
            return [jelly(-0.5, k), jelly(0.5, -k), .hidden(), .hidden()]

        case .peek:
            // Squash down, then pop up wide-eyed, as if an idea landed.
            let down = Self.smooth(t / 0.3) * (1 - Self.smooth((t - 0.45) / 0.12))
            let pop = Self.smooth((t - 0.45) / 0.12)
            let ring = pop * exp(-4 * max(0, t - 0.57)) * cos(14 * max(0, t - 0.57))
            let settle = Self.smooth((t - 1.5) / 0.4)
            let s = 1 + (0.14 * pop + 0.08 * ring) * (1 - settle)
            let lid = 1 - 0.42 * down
            let y = 0.21 * down - 0.2 * pop * (1 - settle)
            return [
                .eye(-0.5 * (1 + 0.1 * pop * (1 - settle)), y, s: s, lid: lid, sx: 1 + 0.2 * down),
                .eye(0.5 * (1 + 0.1 * pop * (1 - settle)), y, s: s, lid: lid, sx: 1 + 0.2 * down),
                .hidden(), .hidden(),
            ]

        case .fuse:
            // The eyes slide together into one body that breathes, then split.
            let into = Self.smooth(t / 0.55) * (1 - Self.smooth((t - 2.45) / 0.55))
            let breathe = 1 + 0.07 * sin(2 * .pi * max(0, t - 0.55) / 1.2) * into
            let body = NotchiBlob.pill(0, 0, w: 1.5 * breathe, h: 0.92 * breathe, smallTopRight: true)
            return [
                NotchiBlob.lerp(.eye(-0.5), body, into),
                NotchiBlob.lerp(.eye(0.5), body, into),
                .hidden(), .hidden(),
            ]

        case .dots:
            // Three dots, the middle one grown out of the gap, in a wave.
            func dot(_ i: Int, _ x: Double) -> NotchiBlob {
                let wave = max(0, sin(2 * .pi * t / 0.95 - Double(i) * 0.8))
                let p = pow(wave, 1.5)
                return .dot(x, -0.24 * p, d: 0.42, alpha: 0.55 + 0.45 * p)
            }
            return [dot(0, -0.62), dot(2, 0.62), dot(1, 0), .hidden()]

        case .quotes:
            // Each eye flips over into a closing quote mark, one after the
            // other, holds, and flips back.
            func flip(_ t0: Double) -> Double {
                .pi * (Self.smooth((t - t0) / 0.38) - Self.smooth((t - t0 - 1.5) / 0.38))
            }
            // Flipped, they ride smaller and higher, where quote marks sit.
            func eye(_ x: Double, _ r: Double) -> NotchiBlob {
                let over = (1 - cos(r)) / 2
                return .eye(x * (1 - 0.12 * over), -0.18 * over,
                            s: 1 - 0.2 * over - 0.12 * abs(sin(r)), rot: r)
            }
            let first = side > 0 ? 0.1 : 0.25, second = side > 0 ? 0.25 : 0.1
            return [eye(-0.5, flip(first)), eye(0.5, flip(second)), .hidden(), .hidden()]

        case .orbit:
            // One eye stays, the other shrinks to a moon and circles it,
            // passing behind.
            let into = Self.smooth(t / 0.5) * (1 - Self.smooth((t - 2.5) / 0.5))
            let a = 2 * .pi * max(0, t - 0.3) / 1.4
            let front = sin(a)
            let moon = NotchiBlob.dot(0.88 * cos(a) * side, 0.6 * sin(a), d: 0.3 + 0.06 * front,
                                      alpha: 0.7 + 0.3 * front, z: front)
            let stay = side > 0 ? -0.5 : 0.5
            let held = NotchiBlob.lerp(.eye(stay), .eye(0, s: 1.05), into)
            let moving = NotchiBlob.lerp(.eye(-stay), moon, into)
            return side > 0 ? [held, moving, .hidden(), .hidden()] : [moving, held, .hidden(), .hidden()]

        case .bars:
            // An equalizer: four bars standing on one line.
            let into = Self.smooth(t / 0.4)
            func bar(_ i: Int, _ x: Double) -> NotchiBlob {
                let speed = [0.62, 0.81, 0.7, 0.9][i]
                let level = 0.5 + 0.5 * sin(2 * .pi * t / speed + Double(i) * 1.7)
                let h = (0.3 + 0.7 * level) * into + 0.06
                return .pill(x, 0.5 - h / 2, w: 0.24, h: h)
            }
            return [bar(0, -0.54), bar(3, 0.54), bar(1, -0.18), bar(2, 0.18)]

        case .bounce:
            // Two balls bouncing in turn, squashing where they land.
            func ball(_ x: Double, _ phase: Double) -> NotchiBlob {
                let s = abs(sin(.pi * t / 0.62 + phase))
                let contact = pow(1 - s, 6)
                let d = 0.5
                var b = NotchiBlob.dot(x, 0, d: d)
                b.w = d * (1 + 0.24 * contact)
                b.h = d * (1 - 0.2 * contact)
                b.y = 0.36 - b.h / 2 - 0.66 * s
                return b
            }
            return [ball(-0.42, 0), ball(0.42, .pi / 2), .hidden(), .hidden()]

        case .spin:
            // The pair turns half a revolution, so the eyes trade places, each
            // turning a full circle on the way and landing upright. They ride
            // a circle, not a flat ellipse, so they never stack mid-turn.
            let p = Self.smooth((t - 0.2) / 0.9) + Self.smooth((t - 1.5) / 0.9)
            let a = .pi * p * side
            let shrink = 1 - 0.14 * abs(sin(a))
            func eye(_ base: Double) -> NotchiBlob {
                .eye(0.5 * cos(base + a), 0.5 * sin(base + a), s: shrink, rot: 2 * a)
            }
            return [eye(.pi), eye(0), .hidden(), .hidden()]

        case .swap:
            // The eyes trade places twice, one passing in front of the other.
            let p = Self.smooth((t - 0.3) / 0.62) - Self.smooth((t - 1.55) / 0.62)
            let pass = sin(.pi * p)
            return [
                .eye(-0.5 + p, s: 1 + 0.16 * pass, z: 1),
                .eye(0.5 - p, s: 1 - 0.16 * pass, alpha: 1 - 0.4 * pass, z: -1),
                .hidden(), .hidden(),
            ]

        case .relay:
            // A small dot hops from one eye to the other and back, over an arc.
            let into = Self.smooth(t / 0.4) * (1 - Self.smooth((t - 2.4) / 0.4))
            let cycle = (max(0, t - 0.3) / 1.0).truncatingRemainder(dividingBy: 2)
            let p = Self.smooth(cycle < 1 ? cycle : 2 - cycle) * side
            let x = -0.62 * p
            let hop = sin(.pi * abs(p))
            let s = 1 - 0.18 * into
            return [
                .eye(-0.5 - 0.12 * into, s: s, lid: 1 - 0.1 * into * hop),
                .eye(0.5 + 0.12 * into, s: s, lid: 1 - 0.1 * into * hop),
                // Fades as it lands, so it sinks into the eye rather than
                // sitting on it.
                .dot(x, -0.62 * hop - 0.05, d: 0.26 * into, alpha: into * Self.smooth(hop / 0.3), z: 1),
                .hidden(),
            ]

        case .bridge:
            // The eyes step apart, a bar grows across the gap and links
            // them, pulses, then lets go and the eyes come back.
            let apart = Self.plateau(t, 0, 0.35, 2.15, 2.55)
            let link = Self.plateau(t, 0.35, 0.75, 1.75, 2.15)
            let pulse = 0.7 + 0.3 * sin(2 * .pi * max(0, t - 0.75) / 0.6)
            let x = 0.5 + 0.26 * apart
            let s = 1 - 0.16 * apart
            return [
                .eye(-x, s: s),
                .eye(x, s: s),
                .pill(0, 0.06, w: 0.95 * link + 0.01, h: 0.22, alpha: link * pulse, z: -1),
                .hidden(),
            ]

        case .scanner:
            // Three dim dots with a bright pill sweeping across them.
            let into = Self.smooth(t / 0.4)
            let x = 0.6 * sin(2 * .pi * max(0, t - 0.2) / 1.5)
            return [
                .dot(-0.6, 0, d: 0.32, alpha: 0.35),
                .dot(0.6, 0, d: 0.32, alpha: 0.35),
                .dot(0, 0, d: 0.32, alpha: 0.35),
                .pill(x, 0, w: 0.56, h: 0.42, alpha: into, z: 1),
            ]
        }
    }

    // MARK: Helpers

    /// Both eyes looking somewhere: `lookX`/`lookY` of 1 move them 0.28 and
    /// 0.16 eye heights — at least a point at the smallest size, so a look
    /// never lands between pixels.
    private static func eyes(lookX: Double, lookY: Double, lid: Double = 1,
                             spread: Double = 1) -> [NotchiBlob] {
        let dx = lookX * 0.28, dy = lookY * 0.16
        return [
            .eye(-0.5 * spread + dx, dy, lid: lid),
            .eye(0.5 * spread + dx, dy, lid: lid),
            .hidden(dx, dy), .hidden(dx, dy),
        ]
    }

    static func smooth(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }

    /// 0 → 1 → 1 → 0 across four times.
    private static func plateau(_ t: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
        smooth((t - a) / (b - a)) * (1 - smooth((t - c) / (d - c)))
    }

    /// The open fraction for a blink starting at `at`: shuts in 0.08s, opens
    /// in 0.14s.
    private static func blink(_ t: Double, at: Double) -> Double {
        let d = t - at
        if d < 0 || d > 0.22 { return 1 }
        if d < 0.08 { return 1 - 0.94 * d / 0.08 }
        return 0.06 + 0.94 * (d - 0.08) / 0.14
    }

    /// A stable 0..<1 from a seed and an index.
    static func hash(_ seed: Double, _ i: Int) -> Double {
        let v = sin(seed * 12.9898 + Double(i) * 78.233) * 43758.5453
        return v - v.rounded(.down)
    }
}

// MARK: - Director

/// Picks which form plays when, and blends one into the next. A reference
/// type held in `@State` so the canvas can advance it while drawing.
final class NotchiDirector {
    /// The background work's eyes: the resting notch's ear on every display
    /// and the menu bar icon draw from this one, so they move together.
    static let work = NotchiDirector()

    private struct Play {
        let form: NotchiForm
        let start: Double
        let seed: Double
    }

    /// How long one form takes to flow into the next.
    static let blend: Double = 0.45

    private var rng: SystemRandomNumberGenerator
    private var seedOverride: [Double]
    private var current: Play?
    private var previous: Play?
    private var mood: NotchiMark.Mood?
    private var recent: [NotchiForm] = []
    /// The latest time asked for. Callers on different clocks (a TimelineView,
    /// a Timer) ask a few ms apart; time never runs backwards inside one play.
    private var latest: Double = -.infinity

    init() {
        rng = SystemRandomNumberGenerator()
        seedOverride = []
    }

    /// A director whose choices come from `seeds` in order — for rendering
    /// the same run twice.
    init(seeds: [Double]) {
        rng = SystemRandomNumberGenerator()
        seedOverride = seeds
    }

    private func random() -> Double {
        if !seedOverride.isEmpty { return seedOverride.removeFirst() }
        return Double.random(in: 0..<1, using: &rng)
    }

    func blobs(at time: Double, mood: NotchiMark.Mood) -> [NotchiBlob] {
        // Nobody drew for a while (the work ended): start fresh instead of
        // playing through every form that would have run meanwhile.
        if time - latest > 1 { current = nil; previous = nil }
        let time = max(time, latest)
        latest = time
        if current == nil || mood != self.mood {
            // First frame, or the mood changed: start a form of the new mood
            // now, blending from wherever the old one was.
            self.mood = mood
            begin(next(eyes: current == nil || current?.form.isEyes == false, mood: mood), at: time)
        }
        guard var play = current else { return NotchiForm.restingEyes }
        while time >= play.start + play.form.duration {
            begin(next(eyes: !play.form.isEyes, mood: mood), at: play.start + play.form.duration)
            play = current!
        }
        let now = play.form.blobs(time - play.start, seed: play.seed)
        guard let prev = previous, time - play.start < Self.blend else { return now }
        // The outgoing form holds its last frame while the incoming one takes
        // over.
        let then = prev.form.blobs(min(time - prev.start, prev.form.duration), seed: prev.seed)
        let f = NotchiForm.smooth((time - play.start) / Self.blend)
        return zip(then, now).map { NotchiBlob.lerp($0, $1, f) }
    }

    private func begin(_ form: NotchiForm, at time: Double) {
        previous = current.map { Play(form: $0.form, start: $0.start, seed: $0.seed) }
        current = Play(form: form, start: time, seed: random())
        recent.append(form)
        if recent.count > 8 { recent.removeFirst() }
    }

    /// The next form: from the eye set or the transformation set, never one
    /// of the last few played from that same set.
    private func next(eyes: Bool, mood: NotchiMark.Mood) -> NotchiForm {
        let pool = NotchiForm.pool(for: mood)
        let set = eyes ? pool.eyes : pool.turns
        let played = recent.filter { set.contains($0) }.suffix(min(set.count - 1, 3))
        let fresh = set.filter { !played.contains($0) }
        let choices = fresh.isEmpty ? set : fresh
        return choices[min(Int(random() * Double(choices.count)), choices.count - 1)]
    }
}

/// The resting notch face's eye parameters (`NotchiFace`). Offsets are in units
/// of the eye height times `NotchiMarkPose.travel`; lids are the open fraction
/// of each eye.
struct NotchiMarkPose: Equatable {
    var lookX: CGFloat = 0
    var lookY: CGFloat = 0
    var lidL: CGFloat = 1
    var lidR: CGFloat = 1
    var hopL: CGFloat = 0
    var hopR: CGFloat = 0
    var spread: CGFloat = 1

    /// How far a look of 1 moves the eyes, as a fraction of the eye height.
    static let travel: CGFloat = 0.16
    /// Top of each eye: warm off-white, the same ink as `NotchiFace`.
    static let ink = Color(red: 0xEC / 255, green: 0xEB / 255, blue: 0xE6 / 255)
    /// Bottom of each eye: the icon's gradient mirrored for a dark surface,
    /// cooler and dimmer. Opaque, so a shape passing in front hides the one
    /// behind it.
    static let inkLow = Color(red: 0x9A / 255, green: 0x9A / 255, blue: 0xA2 / 255)
}

/// Draws the two eyes for a pose. Separate from `NotchiFace` so a pose can be
/// rendered without its loop.
struct NotchiMarkEyes: View {
    var pose: NotchiMarkPose
    var blink: CGFloat = 1
    var eyeHeight: CGFloat
    var dim: Double = 1

    var body: some View {
        let h = eyeHeight
        let w = h * NotchiEyeShape.aspect
        let pitch = (w + h * NotchiEyeShape.gap) * pose.spread
        let t = h * NotchiMarkPose.travel
        ZStack {
            eye(lid: pose.lidL, hop: pose.hopL, h: h, w: w)
                .offset(x: -pitch / 2)
            eye(lid: pose.lidR, hop: pose.hopR, h: h, w: w)
                .offset(x: pitch / 2)
        }
        .offset(x: pose.lookX * t, y: pose.lookY * t)
        .frame(width: w * 2 + h * NotchiEyeShape.gap, height: h)
        .compositingGroup()
        .opacity(dim)
    }

    private func eye(lid: CGFloat, hop: CGFloat, h: CGFloat, w: CGFloat) -> some View {
        NotchiEyeShape()
            .fill(LinearGradient(colors: [NotchiMarkPose.ink, NotchiMarkPose.inkLow],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: w, height: h)
            .scaleEffect(x: 1, y: max(0.06, lid * blink), anchor: .center)
            .offset(y: hop * h)
    }
}

/// One eye of the icon, traced from the 200pt master: 56 × 72, a 28 radius on
/// the top-left and both bottom corners, 10 on the top-right. The eyes sit 16
/// apart.
struct NotchiEyeShape: Shape {
    static let aspect: CGFloat = 56.0 / 72.0
    static let gap: CGFloat = 16.0 / 72.0

    func path(in rect: CGRect) -> Path {
        let h = rect.height
        let big = min(rect.width / 2, h * 28 / 72)
        let small = h * 10 / 72
        return UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: big, bottomLeading: big,
                               bottomTrailing: big, topTrailing: small),
            style: .continuous
        ).path(in: rect)
    }
}
