import SwiftUI
import CoreGraphics

/// The three glyphs the ⋯ manage menu wears, lifted from **Lucide** as raw `<path d="…">`
/// data and stroked at render time — the same "vector, no bitmap, tints with the palette"
/// approach `VendorLogos` takes, one file over.
///
/// Lucide rather than SF Symbols for one measurable reason: **stroke weight**. SF's
/// glyphs carry System-Settings optical mass, and Lucide's own 2px default (authored on
/// a 24-unit grid) lands at 1.08pt when drawn at 13pt — half again heavier than the
/// hairlines this app is built from (the manage card's own rim is 0.75pt, and most other
/// borders are 0.5pt). Because Lucide is *stroked*, its weight is a free parameter:
/// `weight` below is in the source's 24-unit grid, so 1.75 renders at 13 × 1.75 ÷ 24 =
/// 0.95pt — inside the app's line language instead of shouting over it.
///
/// ISC License. Copyright (c) for portions of Lucide are held by Cole Bemis 2013-2022 as
/// part of Feather (MIT). All other copyright (c) for Lucide are held by Lucide
/// Contributors 2022. Permission to use, copy, modify, and/or distribute this software
/// for any purpose with or without fee is hereby granted, provided that the above
/// copyright notice and this permission notice appear in all copies. THE SOFTWARE IS
/// PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE
/// INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
/// AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY
/// DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF
/// CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE
/// USE OR PERFORMANCE OF THIS SOFTWARE.
enum LucideIcons {
    struct Mark {
        /// Each source `<path>` kept as its own string rather than concatenated into one
        /// `d` the way `VendorLogos.table` does. Lucide's paths routinely open with a
        /// *relative* command (`m16 12-4-4-4 4`), which resolves against the current
        /// point — merged into a single string, every path after the first would re-anchor
        /// onto its predecessor's endpoint and the glyph would fly apart. Parsed
        /// separately and unioned into one `Path` instead; stroking traces each subpath
        /// independently, so the union is lossless (a *fill* would care about winding —
        /// which is exactly why the vendor marks can get away with the cheaper trick).
        let paths: [String]
        /// Source grid, square. Lucide authors on 24.
        let viewBox: CGFloat
    }

    /// lucide `circle-fading-arrow-up` — an arrow rising inside a ring that dissolves into
    /// dashes. Reads "there's a newer one up there" rather than `arrow.clockwise`'s "do it
    /// again", which is why it wears both faces of the update row (the resting check and
    /// the "Update to X" it becomes).
    static let circleFadingArrowUp = Mark(paths: [
        "M12 2a10 10 0 0 1 7.38 16.75",
        "m16 12-4-4-4 4",
        "M12 16V8",
        "M2.5 8.875a10 10 0 0 0-.5 3",
        "M2.83 16a10 10 0 0 0 2.43 3.4",
        "M4.636 5.235a10 10 0 0 1 .891-.857",
        "M8.644 21.42a10 10 0 0 0 7.631-.38",
    ], viewBox: 24)

    /// lucide `scroll-text` — a scroll with ruled lines.
    static let scrollText = Mark(paths: [
        "M15 12h-5",
        "M15 8h-5",
        "M19 17V5a2 2 0 0 0-2-2H4",
        "M8 21h12a2 2 0 0 0 2-2v-1a1 1 0 0 0-1-1H11a1 1 0 0 0-1 1v1a2 2 0 1 1-4 0V5a2 2 0 1 0-4 0v2a1 1 0 0 0 1 1h3",
    ], viewBox: 24)

    /// lucide `message-circle` — the Ask bucket, wherever it shows a face.
    static let messageCircle = Mark(paths: [
        "M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719",
    ], viewBox: 24)

    /// lucide `code-xml` — the Agent bucket. Replaces two different SF glyphs that used
    /// to split the same concept between surfaces (`chevron.left.forwardslash.chevron.right`
    /// on the bucket pill, `terminal` on the tear-off card).
    static let codeXml = Mark(paths: [
        "m18 16 4-4-4-4",
        "m6 8-4 4 4 4",
        "m14.5 4-5 16",
    ], viewBox: 24)

    /// lucide `settings` — the gear. The source ships this as a path plus a bare
    /// `<circle cx="12" cy="12" r="3">`; the hub is spelled out here as the equivalent
    /// two-arc path, since the parser speaks `d` strings and nothing else.
    static let settings = Mark(paths: [
        "M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 0 0 3.831 2.34 2.34 0 0 1-2.33 4.033 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3.32-1.915 2.34 2.34 0 0 1-2.33-4.033 2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051a2.34 2.34 0 0 0 3.319-1.915",
        "M9 12a3 3 0 1 0 6 0a3 3 0 1 0-6 0z",
    ], viewBox: 24)
}

/// A Lucide glyph at a given size and stroke weight. Takes its colour from the
/// environment's foreground style, so call sites tint it exactly like `Image(systemName:)`.
struct LucideIcon: View {
    let mark: LucideIcons.Mark
    /// Rendered side, in points.
    var size: CGFloat = 13
    /// Stroke weight **in the source's 24-unit grid**, not points — so it stays
    /// proportional if `size` changes. Lucide's own default is 2; see the enum's note on
    /// why this app runs it finer.
    var weight: CGFloat = 1.75

    var body: some View {
        LucideShape(mark: mark)
            .stroke(style: StrokeStyle(lineWidth: size * weight / mark.viewBox,
                                       lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

/// Parses a `LucideIcons.Mark`'s path strings and scales them into the given rect,
/// centered, preserving the square source grid. Meant to be `.stroke`d — the returned
/// path is a union of open subpaths and has no meaningful fill.
struct LucideShape: Shape {
    let mark: LucideIcons.Mark

    /// Memoized parse, same rationale as `SVGPathShape.parseCache`: SwiftUI re-asks a
    /// shape for `path(in:)` on every hover re-diff, and the manage menu's rows re-diff
    /// whenever the pointer crosses them — without this, `circle-fading-arrow-up`'s seven
    /// arc paths would re-run the endpoint→center trig on every frame of a hover. The
    /// parse is a pure function of the path strings, so the unit-space result keeps.
    private static let parseCache: NSCache<NSString, ParsedPath> = {
        let cache = NSCache<NSString, ParsedPath>()
        cache.countLimit = 16
        return cache
    }()

    private final class ParsedPath {
        let path: Path
        init(_ path: Path) { self.path = path }
    }

    func path(in rect: CGRect) -> Path {
        let key = mark.paths.joined(separator: "|") as NSString
        let raw: Path
        if let hit = Self.parseCache.object(forKey: key) {
            raw = hit.path
        } else {
            var merged = Path()
            for d in mark.paths { merged.addPath(SVGPath.parse(d)) }
            Self.parseCache.setObject(ParsedPath(merged), forKey: key)
            raw = merged
        }
        guard mark.viewBox > 0 else { return raw }
        let scale = min(rect.width, rect.height) / mark.viewBox
        let dx = (rect.width - mark.viewBox * scale) / 2
        let dy = (rect.height - mark.viewBox * scale) / 2
        return raw.applying(CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale))
    }
}
