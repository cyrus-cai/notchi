import AppKit
import CoreGraphics

/// Chinese characters written the way a hand writes them: one stroke at a time,
/// in stroke order, each stroke laid down along its own centreline.
///
/// # Why the ink is drawn rather than typeset
///
/// The obvious approach — take a handwriting font's glyph and reveal it stroke by
/// stroke — does not work, and the reason is worth stating because it drove the
/// whole design. Revealing a glyph in stroke order needs two things from the same
/// source: the *shape* of each stroke and the *centreline* it was drawn along.
/// Stroke-order datasets carry centrelines for their own reference glyphs; a
/// shipped font carries shapes for its own. Masking one with the other misaligns —
/// measured against Kaiti SC, parts of a stroke reveal early and parts never
/// reveal at all, because the two designs simply place their strokes differently.
///
/// (This is why `ink-video`, the reference for this feature, rasterises its own
/// font, skeletonises it and has an agent group the skeleton edges into semantic
/// strokes. That pipeline produces matched shapes and centrelines — offline, per
/// character, with a human in the loop. None of that is available at runtime for
/// arbitrary answer text.)
///
/// So the ink here *is* the centreline: each stroke is drawn as a round-capped
/// line swept along its median. Shape and centreline are the same object by
/// construction, so alignment is exact and cannot drift. The character's look is
/// then ours to set — see `strokeWidth` — rather than a font's, which is what
/// makes it a rounded marker hand instead of 楷体.
///
/// # The data
///
/// `Resources/strokes.bin`: medians for all 9,574 characters of the
/// hanzi-writer/makemeahanzi dataset, quantised to a byte per coordinate over a
/// 1280-unit window and packed with a sorted index. 1.39 MB for full coverage —
/// small enough that no subsetting is needed, so there is no such thing as a
/// common character that fails to write itself.
///
/// A byte per coordinate is ~5 units of a 1024 em, about 0.09pt at body size, and
/// the medians are smoothed through a spline before they are stroked, so the
/// quantisation is well below anything visible.
enum StrokeInk {
    // MARK: - Look

    /// Stroke weight as a fraction of the em.
    ///
    /// The one number that decides whether this reads as cute or as a smudge.
    /// Measured at body size: below ~0.07 the hand turns spidery, and by ~0.15
    /// the enclosed counters of dense characters (爱, 稿, 签) have filled in and
    /// the character is a blob. 0.088 keeps every counter open at 18pt em while
    /// still reading as a fat marker rather than a pen.
    static let strokeWidth: CGFloat = 0.080

    /// What `**bold**` multiplies the stroke width by.
    ///
    /// Bold has to arrive as ink weight because there is no bold *face* to switch
    /// to — the ink is drawn, not set. 1.4 is about the ratio between a regular
    /// and a bold cut of a CJK face, and it stays clear of the width where dense
    /// characters fill in.
    static let boldWeight: CGFloat = 1.5

    // MARK: - Data

    private struct Table {
        let data: Data
        /// Byte offset of the blob, and the index entries before it.
        let count: Int
        let indexOffset = 9
        var blobOffset: Int { indexOffset + count * 8 }
    }

    private static let table: Table? = {
        guard let url = Bundle.main.url(forResource: "strokes", withExtension: "bin"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count > 9,
              data[0] == 0x4E, data[1] == 0x48, data[2] == 0x57, data[3] == 0x53,  // "NHWS"
              data[4] == 1
        else { return nil }
        let count = Int(data[5]) | Int(data[6]) << 8 | Int(data[7]) << 16 | Int(data[8]) << 24
        return Table(data: data, count: count)
    }()

    /// True when the stroke table loaded — the gate for offering stroke writing at
    /// all. A missing or corrupt resource must degrade to ordinary text, never to
    /// a blank answer.
    static var isAvailable: Bool { table != nil }

    private static func u32(_ data: Data, _ at: Int) -> UInt32 {
        UInt32(data[at]) | UInt32(data[at+1]) << 8 | UInt32(data[at+2]) << 16 | UInt32(data[at+3]) << 24
    }

    /// The medians for one character, in the dataset's 1024-unit em with y up and
    /// the baseline at y = 0. Nil for anything the dataset doesn't cover — kana,
    /// Hangul, Latin, punctuation, rare hanzi — which the caller renders as type.
    private static func rawMedians(_ scalar: UInt32) -> [[CGPoint]]? {
        guard let table else { return nil }
        let data = table.data
        // Binary search the sorted (scalar, offset) index.
        var low = 0, high = table.count - 1
        var found = -1
        while low <= high {
            let mid = (low + high) / 2
            let entry = table.indexOffset + mid * 8
            let key = u32(data, entry)
            if key == scalar { found = Int(u32(data, entry + 4)); break }
            if key < scalar { low = mid + 1 } else { high = mid - 1 }
        }
        guard found >= 0 else { return nil }

        var p = table.blobOffset + found
        guard p < data.count else { return nil }
        let strokeCount = Int(data[p]); p += 1
        var out: [[CGPoint]] = []
        out.reserveCapacity(strokeCount)
        for _ in 0..<strokeCount {
            guard p < data.count else { return nil }
            let pointCount = Int(data[p]); p += 1
            var points: [CGPoint] = []
            points.reserveCapacity(pointCount)
            for _ in 0..<pointCount {
                guard p + 1 < data.count else { return nil }
                points.append(CGPoint(x: dequantise(data[p]), y: dequantise(data[p+1])))
                p += 2
            }
            out.append(points)
        }
        return out
    }

    private final class Finished {
        let path: CGPath
        init(_ path: CGPath) { self.path = path }
    }

    /// Finished characters, keyed by character, size and weight. Bounded, and the
    /// set of live keys is tiny — a handful of type sizes times two weights.
    private static let finishedCache: NSCache<NSString, Finished> = {
        let cache = NSCache<NSString, Finished>()
        cache.countLimit = 4096
        return cache
    }()

    /// Inverse of the packer's quantisation: a byte back onto the [-128, 1152]
    /// window the medians were measured to fit.
    private static func dequantise(_ byte: UInt8) -> CGFloat {
        CGFloat(byte) / 255 * 1280 - 128
    }

    // MARK: - Geometry

    /// Medians smoothed and flattened to dense polylines, memoized per character.
    ///
    /// The raw medians are five or six points per stroke. Stroked directly they
    /// come out as bent wire — every direction change is a visible corner, which
    /// is the opposite of a hand. A Catmull-Rom pass through the control points
    /// fixes that, and it is far too expensive to redo per frame: a streaming
    /// answer redraws at display refresh, and every character on screen would be
    /// re-splined each time.
    private static let cacheLock = NSLock()
    private static var smoothCache: [UInt32: [[CGPoint]]] = [:]

    static func strokes(for character: Character) -> [[CGPoint]]? {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first?.value else { return nil }
        cacheLock.lock()
        if let hit = smoothCache[scalar] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        guard let raw = rawMedians(scalar) else { return nil }
        let smoothed = raw.map { spline($0) }
        cacheLock.lock()
        smoothCache[scalar] = smoothed
        cacheLock.unlock()
        return smoothed
    }

    /// Catmull-Rom through the control points, flattened.
    private static func spline(_ points: [CGPoint], per: Int = 8) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let padded = [points[0]] + points + [points[points.count - 1]]
        var out: [CGPoint] = []
        out.reserveCapacity((padded.count - 3) * per + 1)
        for i in 1..<(padded.count - 2) {
            let p0 = padded[i-1], p1 = padded[i], p2 = padded[i+1], p3 = padded[i+2]
            for s in 0..<per {
                let t = CGFloat(s) / CGFloat(per), t2 = t * t, t3 = t2 * t
                out.append(CGPoint(
                    x: 0.5 * (2*p1.x + (-p0.x + p2.x)*t + (2*p0.x - 5*p1.x + 4*p2.x - p3.x)*t2
                              + (-p0.x + 3*p1.x - 3*p2.x + p3.x)*t3),
                    y: 0.5 * (2*p1.y + (-p0.y + p2.y)*t + (2*p0.y - 5*p1.y + 4*p2.y - p3.y)*t2
                              + (-p0.y + 3*p1.y - 3*p2.y + p3.y)*t3)))
            }
        }
        out.append(points[points.count - 1])
        return out
    }

    // MARK: - Drawing

    /// How many strokes a character has, or nil when it isn't in the dataset.
    static func strokeCount(for character: Character) -> Int? { strokes(for: character)?.count }

    /// The ink of one character, written up to `progress` strokes.
    ///
    /// `progress` is fractional: `2.4` means the first two strokes are finished
    /// and the third is 40% laid down. `origin` is the character's baseline-left
    /// point in the destination context — exactly what
    /// `Text.Layout.RunSlice.typographicBounds.origin` reports — and `em` is the
    /// type size the character is set at.
    ///
    /// Returned as a single filled path rather than a stroked one: stroking is
    /// resolved here so the caller can fill it in one pass, and so round joins are
    /// baked in rather than depending on the caller's stroke style.
    static func path(for character: Character,
                     origin: CGPoint,
                     em: CGFloat,
                     progress: CGFloat,
                     weight: CGFloat = 1) -> CGPath? {
        guard let all = strokes(for: character), !all.isEmpty else { return nil }
        let scale = em / 1024
        let done = min(Int(progress), all.count)
        let fraction = progress - CGFloat(done)

        // A finished character is the overwhelmingly common case — every glyph on
        // screen except the one the hand is inside — and its path never varies for
        // a given size and weight. Building it fresh per glyph per frame is what
        // makes a long streaming answer expensive, so finished characters are
        // built once at the origin and translated into place.
        if done >= all.count {
            let key = "\(character)|\(Int(em * 4))|\(Int(weight * 100))" as NSString
            if let hit = finishedCache.object(forKey: key) {
                var move = CGAffineTransform(translationX: origin.x, y: origin.y)
                return hit.path.copy(using: &move)
            }
            let atOrigin = CGMutablePath()
            for stroke in all { append(stroke, to: atOrigin, origin: .zero, scale: scale, upTo: 1) }
            guard !atOrigin.isEmpty else { return nil }
            let stroked = atOrigin.copy(strokingWithWidth: strokeWidth * weight * em,
                                        lineCap: .round, lineJoin: .round, miterLimit: 4)
            finishedCache.setObject(Finished(stroked), forKey: key)
            var move = CGAffineTransform(translationX: origin.x, y: origin.y)
            return stroked.copy(using: &move)
        }

        let line = CGMutablePath()
        for index in 0..<done { append(all[index], to: line, origin: origin, scale: scale, upTo: 1) }
        if done < all.count, fraction > 0 {
            append(all[done], to: line, origin: origin, scale: scale, upTo: fraction)
        }
        if line.isEmpty { return nil }
        return line.copy(strokingWithWidth: strokeWidth * weight * em,
                         lineCap: .round, lineJoin: .round, miterLimit: 4)
    }

    /// One stroke's centreline, truncated to `upTo` of its length — the vector
    /// equivalent of animating `stroke-dashoffset` from 1 to 0, which is how the
    /// reference implementation reveals a stroke.
    private static func append(_ points: [CGPoint], to path: CGMutablePath,
                               origin: CGPoint, scale: CGFloat, upTo: CGFloat) {
        guard points.count > 1 else { return }
        // The dataset measures y upward from the baseline; every consumer here is
        // a SwiftUI `GraphicsContext`, whose y runs down the screen. Flipping in
        // the one place that touches coordinates keeps every caller in the space
        // Core Text already handed it.
        func place(_ p: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + p.x * scale, y: origin.y - p.y * scale)
        }
        guard upTo < 1 else {
            path.move(to: place(points[0]))
            for p in points.dropFirst() { path.addLine(to: place(p)) }
            return
        }
        var total: CGFloat = 0
        for i in 1..<points.count {
            total += hypot(points[i].x - points[i-1].x, points[i].y - points[i-1].y)
        }
        let want = total * max(upTo, 0)
        guard want > 0 else { return }
        path.move(to: place(points[0]))
        var walked: CGFloat = 0
        for i in 1..<points.count {
            let a = points[i-1], b = points[i]
            let segment = hypot(b.x - a.x, b.y - a.y)
            if walked + segment >= want {
                let t = (want - walked) / max(segment, 0.0001)
                path.addLine(to: place(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))
                return
            }
            path.addLine(to: place(b))
            walked += segment
        }
    }
}
