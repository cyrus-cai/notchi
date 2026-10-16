import SwiftUI

/// One model card standing in the wallet: the lineup's name on the left, the
/// vendor's mark and name on the right.
struct WalletCard: Identifiable, Equatable {
    let id: String
    let name: String
    let vendor: String
}

/// Settings' credit card, drawn as a stitched pocket with the lineup's model
/// cards standing in it. The balance is what the pocket holds; the cards are
/// what it pays for. A thumb notch in the pocket's lip shows the front card.
///
/// `cards` is front-first: the first entry sits nearest the pocket. Clicking a
/// card calls `onCard`.
struct WalletPocket<Content: View>: View {
    let cards: [WalletCard]
    var onCard: (WalletCard) -> Void
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String?
    @State private var drawn = false

    /// How much of each card shows above the one in front of it.
    private static var strip: CGFloat { 26 }
    /// Tall enough that the front card still fills the notch.
    private static var cardHeight: CGFloat { 56 }
    private static var cardInset: CGFloat { 12 }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Self.strip * CGFloat(cards.count))
            pocket
        }
        .background(alignment: .top) { cardStack }
        .onAppear {
            guard !drawn else { return }
            if reduceMotion { drawn = true; return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.08)) {
                drawn = true
            }
        }
    }

    private var pocket: some View {
        content
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                PocketShape()
                    .fill(LinearGradient(colors: [Color(white: 0.135), Color(white: 0.075)],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.55), radius: 5, y: -2)
            }
            .overlay {
                PocketShape()
                    .inset(by: 6)
                    .stroke(Color.white.opacity(0.16),
                            style: StrokeStyle(lineWidth: 0.8, lineCap: .round, dash: [4, 3]))
                    .allowsHitTesting(false)
            }
            .overlay {
                PocketShape()
                    .strokeBorder(Tokens.recessRim, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .brandAura(in: PocketShape(), lineWidth: 1.2)
    }

    /// Back card first in the ZStack, so the front card draws over the rest.
    private var cardStack: some View {
        let count = cards.count
        return ZStack(alignment: .top) {
            ForEach(Array(cards.enumerated().reversed()), id: \.element.id) { index, card in
                // Row 0 is the back of the stack, at the top.
                let row = count - 1 - index
                let lift: CGFloat = hovered == card.id ? -6 : 0
                // Before the first draw every card waits inside the pocket.
                let tucked: CGFloat = drawn ? 0 : Self.strip * CGFloat(count - row) + 6
                cardView(card, depth: index)
                    .frame(height: Self.cardHeight, alignment: .top)
                    .offset(y: Self.strip * CGFloat(row) + lift + tucked)
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

    /// `depth` 0 is the front card, the brightest; each card behind is darker.
    private func cardView(_ card: WalletCard, depth: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let tone = max(0.13, 0.30 - Double(depth) * 0.07)
        return HStack(spacing: 8) {
            Text(card.name)
                .font(.sf(Tokens.TypeSize.label, weight: .medium))
                .foregroundStyle(Tokens.text1)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(card.vendor.uppercased())
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Tokens.text3)
                .lineLimit(1)
            VendorLogo(vendor: card.vendor, fallback: card.name)
                .frame(width: 12, height: 12)
                .opacity(0.85)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.strip)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            shape.fill(LinearGradient(colors: [Color(white: tone + 0.05), Color(white: tone)],
                                      startPoint: .top, endPoint: .bottom))
        }
        .overlay {
            // A faint sheen across the right end, as on a printed card.
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.07), .clear],
                                      startPoint: .topTrailing, endPoint: .center))
                .allowsHitTesting(false)
        }
        .overlay { shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5) }
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A rounded rectangle with a thumb notch dipped into the middle of its top
/// edge, the cut a card pocket has so the card inside can be pushed out.
struct PocketShape: InsettableShape {
    var cornerRadius: CGFloat = 18
    var notchWidth: CGFloat = 84
    var notchDepth: CGFloat = 15
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let radius = max(0, cornerRadius - insetAmount)
        let depth = max(0, notchDepth - insetAmount * 0.4)
        let half = notchWidth / 2
        let midX = r.midX
        var p = Path()
        p.move(to: CGPoint(x: r.minX + radius, y: r.minY))
        p.addLine(to: CGPoint(x: midX - half, y: r.minY))
        p.addCurve(to: CGPoint(x: midX, y: r.minY + depth),
                   control1: CGPoint(x: midX - half * 0.45, y: r.minY),
                   control2: CGPoint(x: midX - half * 0.55, y: r.minY + depth))
        p.addCurve(to: CGPoint(x: midX + half, y: r.minY),
                   control1: CGPoint(x: midX + half * 0.55, y: r.minY + depth),
                   control2: CGPoint(x: midX + half * 0.45, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY),
                 tangent2End: CGPoint(x: r.maxX, y: r.minY + radius), radius: radius)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY),
                 tangent2End: CGPoint(x: r.maxX - radius, y: r.maxY), radius: radius)
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY),
                 tangent2End: CGPoint(x: r.minX, y: r.maxY - radius), radius: radius)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY),
                 tangent2End: CGPoint(x: r.minX + radius, y: r.minY), radius: radius)
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> PocketShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}
