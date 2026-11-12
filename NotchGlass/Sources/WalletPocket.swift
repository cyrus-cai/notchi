import SwiftUI

/// One card standing in the pocket. A model card carries the vendor's mark
/// and the lineup's name. The license (`plain`) is drawn as a paper receipt:
/// light paper with a torn top edge, printed in the monospaced face, its
/// name on the left and `details` on the right, each its own text.
struct WalletCard: Identifiable, Equatable {
    let id: String
    let name: String
    let vendor: String
    /// Text only, no vendor mark.
    var plain = false
    /// Right-aligned texts on the card.
    var details: [String] = []
    /// A slot nothing stands in yet: a dashed outline, dimmer.
    var empty = false
}

/// Settings' credit card, drawn as a pocket with the lineup's model cards
/// standing side by side in it. The balance is what the pocket holds; the
/// cards are what it pays for.
///
/// At rest only a sliver of each card shows above the pocket. With the
/// pointer over the wallet the cards rise and fan out with their names, and
/// the pocket tilts a little toward the pointer with a light that follows it.
/// Clicking a card calls `onCard`.
struct WalletPocket<Content: View>: View {
    let cards: [WalletCard]
    var onCard: (WalletCard) -> Void
    /// The pointer came over the wallet, or left it.
    var onHover: (Bool) -> Void = { _ in }
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Dark leather in dark mode; a light gray pocket in light mode, with white
    /// cards and an outlined receipt.
    @Environment(\.colorScheme) private var colorScheme
    private var light: Bool { colorScheme == .light }
    @State private var hovered: String?
    @State private var open = false
    /// The pointer over the wallet, in unit space: (0, 0) top-leading to
    /// (1, 1) bottom-trailing. Nil when it is elsewhere.
    @State private var pointer: CGPoint?
    @State private var size: CGSize = .zero

    /// Height above the pocket the risen cards take.
    private static var strip: CGFloat { 26 }
    /// How far below their risen place the cards rest.
    private static var restDrop: CGFloat { 16 }
    /// Taller than `strip`, so each card's bottom stays tucked behind the pocket.
    private static var cardHeight: CGFloat { 50 }
    private static var cardInset: CGFloat { 14 }
    private static var pocketShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    /// Cards are raised whenever motion is reduced, so the names stay readable.
    private var raised: Bool { open || reduceMotion }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: cards.isEmpty ? 0 : Self.strip)
            pocket
        }
        .background(alignment: .top) { cardRow }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { size = geo.size }
                    .onChange(of: geo.size) { _, new in size = new }
            }
        }
        .rotation3DEffect(.degrees(tilt.x), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .rotation3DEffect(.degrees(tilt.y), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                guard size.width > 0, size.height > 0 else { return }
                let unit = CGPoint(x: min(max(location.x / size.width, 0), 1),
                                   y: min(max(location.y / size.height, 0), 1))
                withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.8)) {
                    pointer = unit
                }
                if !open {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.72)) {
                        open = true
                    }
                    onHover(true)
                }
            case .ended:
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                    pointer = nil
                    open = false
                }
                onHover(false)
            }
        }
    }

    /// Degrees about the y and x axes. A couple of degrees at most: enough to
    /// read as a physical card, not enough to blur the text.
    private var tilt: CGPoint {
        guard let pointer, !reduceMotion else { return .zero }
        return CGPoint(x: (pointer.x - 0.5) * 4, y: (0.5 - pointer.y) * 3)
    }

    private var pocket: some View {
        content
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                Self.pocketShape
                    // Opaque, so the cards' lower halves stay hidden behind it.
                    .fill(LinearGradient(colors: light
                                             ? [Color(white: 0.955), Color(white: 0.925)]
                                             : [Color(white: 0.12), Color(white: 0.095)],
                                         startPoint: .top, endPoint: .bottom))
                    // Kept tight so the shadow stays at the edge, not as a haze around the card.
                    .shadow(color: .black.opacity(light ? 0.10 : 0.4), radius: 1.5, y: -1)
            }
            .overlay {
                // Light that follows the pointer across the surface.
                if let pointer, !reduceMotion {
                    Self.pocketShape
                        .fill(RadialGradient(colors: [Color.white.opacity(light ? 0.6 : 0.09), .clear],
                                             center: UnitPoint(x: pointer.x, y: pointer.y),
                                             startRadius: 0, endRadius: 220))
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay {
                Self.pocketShape
                    .strokeBorder(Tokens.recessRim, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .brandAura(in: Self.pocketShape, lineWidth: 1.2)
    }

    private var cardRow: some View {
        let mid = Double(cards.count - 1) / 2
        return HStack(spacing: 6) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                let spread = Double(index) - mid
                let lift: CGFloat = hovered == card.id ? -5 : 0
                cardView(card, lit: hovered == card.id, named: raised)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.cardHeight, alignment: .top)
                    // Fanned like a hand of cards when raised.
                    .rotationEffect(.degrees(raised && !reduceMotion ? spread * 2.5 : 0),
                                    anchor: .bottom)
                    .offset(x: raised && !reduceMotion ? spread * 3 : 0,
                            y: (raised ? 0 : Self.restDrop) + lift)
                    .animation(reduceMotion ? nil
                               : .spring(response: 0.42, dampingFraction: 0.72)
                                   .delay(Double(index) * 0.035),
                               value: open)
                    .onHover { inside in
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75)) {
                            hovered = inside ? card.id : (hovered == card.id ? nil : hovered)
                        }
                    }
                    .onTapGesture { onCard(card) }
            }
        }
        .padding(.horizontal, Self.cardInset)
    }

    @ViewBuilder
    private func cardView(_ card: WalletCard, lit: Bool, named: Bool) -> some View {
        if card.plain && !card.empty {
            receiptView(card, lit: lit, named: named)
        } else {
            modelCardView(card, lit: lit, named: named)
        }
    }

    /// A paper receipt standing in the pocket: off-white paper, a torn top
    /// edge, dark monospaced print.
    private func receiptView(_ card: WalletCard, lit: Bool, named: Bool) -> some View {
        let shape = ReceiptShape()
        let ink = Color.black
        return HStack(spacing: 6) {
            Text(card.name)
                .font(.system(size: Tokens.TypeSize.meta - 0.5, weight: .medium, design: .monospaced))
                .foregroundStyle(ink.opacity(0.82))
                .lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                ForEach(card.details, id: \.self) { detail in
                    Text(detail)
                        .font(.system(size: Tokens.TypeSize.meta - 0.5, design: .monospaced))
                        .foregroundStyle(ink.opacity(0.6))
                        .lineLimit(1)
                }
            }
        }
        .opacity(named ? 1 : 0)
        .padding(.horizontal, 12)
        .padding(.top, ReceiptShape.tooth)
        .frame(height: Self.strip)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            shape.fill(LinearGradient(colors: [Color(white: lit ? 0.97 : 0.93), Color(white: lit ? 0.9 : 0.85)],
                                      startPoint: .top, endPoint: .bottom))
        }
        .overlay {
            // On the light pocket the paper needs an edge to stand apart.
            if light {
                shape.stroke(Color.black.opacity(0.10), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func modelCardView(_ card: WalletCard, lit: Bool, named: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        let tone = light ? (lit ? 0.95 : 0.99) : (lit ? 0.31 : 0.24)
        return HStack(spacing: 6) {
            if !card.plain {
                VendorLogo(vendor: card.vendor, fallback: card.name)
                    .frame(width: 11, height: 11)
                    .opacity(0.8)
            }
            Text(card.name)
                .font(.sf(Tokens.TypeSize.meta - 0.5))
                .foregroundStyle(lit ? Tokens.text1 : Tokens.text2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                ForEach(card.details, id: \.self) { detail in
                    Text(detail)
                        .font(.sf(Tokens.TypeSize.meta - 0.5))
                        .foregroundStyle(lit ? Tokens.text2 : Tokens.text3)
                        .lineLimit(1)
                }
            }
        }
        .opacity(named ? 1 : 0)
        .padding(.horizontal, 10)
        .frame(height: Self.strip)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            shape.fill(LinearGradient(colors: [Color(white: tone + 0.05), Color(white: tone)],
                                      startPoint: .top, endPoint: .bottom))
                .opacity(card.empty ? 0.35 : 1)
        }
        .overlay {
            // A faint sheen across the right end, as on a printed card.
            if !card.empty {
                shape.fill(LinearGradient(colors: [Color.white.opacity(0.07), .clear],
                                          startPoint: .topTrailing, endPoint: .center))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            shape.strokeBorder(Tokens.ink.opacity(light ? (lit ? 0.22 : (card.empty ? 0.22 : 0.10))
                                                      : (lit ? 0.3 : (card.empty ? 0.22 : 0.14))),
                               style: StrokeStyle(lineWidth: card.empty ? 1 : 0.5,
                                                  dash: card.empty ? [4, 3] : []))
        }
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A receipt's outline: straight sides and bottom, a zigzag top edge where
/// it was torn off.
private struct ReceiptShape: Shape {
    static let tooth: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = max(Int(rect.width / (Self.tooth * 2)), 1)
        let step = rect.width / CGFloat(count)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + Self.tooth))
        for i in 0..<count {
            let x = rect.minX + CGFloat(i) * step
            path.addLine(to: CGPoint(x: x + step / 2, y: rect.minY))
            path.addLine(to: CGPoint(x: x + step, y: rect.minY + Self.tooth))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Paper confetti falling over the whole Settings page while the pointer is
/// on a held license. White scraps only, the receipt's paper. Drawn in one
/// Canvas; the timeline is paused while it is off. Nothing under Reduce
/// Motion.
struct PaperConfetti: View {
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// White scraps vanish on a light page; there they are gray.
    @Environment(\.colorScheme) private var colorScheme
    @State private var start = Date()
    /// The timeline is running: while active, and after it until the scraps
    /// already in the air have landed.
    @State private var running = false
    /// Seconds from `start` at which the pointer left. Scraps whose fall
    /// began before it finish; none begin after it.
    @State private var stopped: Double?
    /// Spans within this run when the pointer was away. A fall that would
    /// have begun inside one is not drawn, so coming back does not put scraps
    /// in mid-air.
    @State private var gaps: [ClosedRange<Double>] = []

    /// The longest delay-free fall, so a run can end once every scrap has landed.
    private static let longestFall = 4.8

    private static let count = 90

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation(paused: !running)) { timeline in
                Canvas { context, size in
                    let t = timeline.date.timeIntervalSince(start)
                    for i in 0..<Self.count {
                        let delay = Self.unit(i, 1) * 1.6
                        let duration = 2.6 + Self.unit(i, 2) * 2.2
                        let phase = (t - delay) / duration
                        guard phase > 0 else { continue }
                        // When this fall began.
                        let began = delay + phase.rounded(.down) * duration
                        if let stopped, began > stopped { continue }
                        if gaps.contains(where: { $0.contains(began) }) { continue }
                        let fall = phase.truncatingRemainder(dividingBy: 1)
                        let seed = Self.unit(i, 3) * 6.28
                        let x = Self.unit(i, 4) * size.width
                            + sin(t * (1 + Self.unit(i, 5) * 2) + seed) * 14
                        let y = -20 + fall * (size.height + 40)
                        let turn = t * (1 + Self.unit(i, 6) * 3) * (Self.unit(i, 7) > 0.5 ? 1 : -1)
                        // The scrap turning edge-on as it falls.
                        let flutter = max(0.25, abs(cos(t * (2 + Self.unit(i, 8) * 3) + seed)))
                        let w = 5 + Self.unit(i, 9) * 4
                        let h = (3 + Self.unit(i, 10) * 3) * flutter
                        let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
                        var scrap = context
                        scrap.translateBy(x: x, y: y)
                        scrap.rotate(by: .radians(turn))
                        scrap.fill(Self.unit(i, 11) < 0.65 ? Path(rect) : Path(ellipseIn: rect),
                                   with: .color(colorScheme == .light
                                       ? Color.black.opacity(0.10 + Self.unit(i, 12) * 0.18)
                                       : Color.white.opacity(0.25 + Self.unit(i, 12) * 0.5)))
                    }
                }
            }
            .onChange(of: active) { _, on in
                let now = Date().timeIntervalSince(start)
                if on {
                    if running, let left = stopped {
                        gaps.append(left...max(left, now))
                        stopped = nil
                    } else if !running {
                        start = Date()
                        gaps = []
                        stopped = nil
                        running = true
                    }
                } else if running {
                    stopped = now
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(Self.longestFall + 0.2))
                        // Still the same departure: every scrap has landed.
                        if stopped == now { running = false }
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// A fixed value in 0..<1 for scrap `i`, so every frame draws the same scraps.
    private static func unit(_ i: Int, _ salt: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: i &* 73_856_093 ^ salt &* 19_349_663)
        x ^= x >> 33
        x = x &* 0xff51_afd7_ed55_8ccd
        x ^= x >> 33
        return Double(x % 10_000) / 10_000
    }
}
