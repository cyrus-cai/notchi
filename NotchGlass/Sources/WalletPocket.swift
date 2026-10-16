import SwiftUI

/// One model card standing in the wallet: the vendor's mark and the lineup's
/// name.
struct WalletCard: Identifiable, Equatable {
    let id: String
    let name: String
    let vendor: String
}

/// Settings' credit card, drawn as a pocket with the lineup's model cards
/// standing side by side in it. The balance is what the pocket holds;
/// the cards are what it pays for. Only each card's top edge shows, so the
/// cards add one row of height. The pocket's top edge has a cut shaped like
/// the MacBook notch, under the middle card.
///
/// Clicking a card calls `onCard`.
struct WalletPocket<Content: View>: View {
    let cards: [WalletCard]
    var cardHelp: String = ""
    var onCard: (WalletCard) -> Void
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String?
    @State private var drawn = false

    /// How much of each card shows above the pocket.
    private static var strip: CGFloat { 28 }
    /// Tall enough that the middle card still fills the notch.
    private static var cardHeight: CGFloat { 50 }
    private static var cardInset: CGFloat { 12 }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: cards.isEmpty ? 0 : Self.strip)
            pocket
        }
        .background(alignment: .top) { cardRow }
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
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                PocketShape()
                    // Opaque, so the cards' lower halves stay hidden behind it.
                    .fill(LinearGradient(colors: [Color(white: 0.12), Color(white: 0.095)],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.55), radius: 5, y: -2)
            }
            .overlay {
                PocketShape()
                    .strokeBorder(Tokens.recessRim, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .brandAura(in: PocketShape(), lineWidth: 1.2)
    }

    private var cardRow: some View {
        HStack(spacing: 6) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                let lift: CGFloat = hovered == card.id ? -5 : 0
                // Before the first draw every card waits inside the pocket.
                let tucked: CGFloat = drawn ? 0 : Self.strip + 6
                cardView(card, lit: hovered == card.id)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.cardHeight, alignment: .top)
                    .offset(y: lift + tucked)
                    .animation(reduceMotion ? nil
                               : .spring(response: 0.45, dampingFraction: 0.8)
                                   .delay(drawn ? Double(index) * 0.05 : 0),
                               value: drawn)
                    .onHover { inside in
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75)) {
                            hovered = inside ? card.id : (hovered == card.id ? nil : hovered)
                        }
                    }
                    .onTapGesture { onCard(card) }
                    .help(cardHelp)
            }
        }
        .padding(.horizontal, Self.cardInset)
    }

    private func cardView(_ card: WalletCard, lit: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        let tone = lit ? 0.31 : 0.24
        return HStack(spacing: 6) {
            VendorLogo(vendor: card.vendor, fallback: card.name)
                .frame(width: 12, height: 12)
                .opacity(0.9)
            Text(card.name)
                .font(.sf(Tokens.TypeSize.meta, weight: .medium))
                .foregroundStyle(lit ? Tokens.text1 : Tokens.text2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
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
        .overlay { shape.strokeBorder(Color.white.opacity(lit ? 0.24 : 0.14), lineWidth: 0.5) }
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A rounded rectangle with a cut in the middle of its top edge shaped like
/// the MacBook notch: flared top corners, straight sides, rounded bottom.
struct PocketShape: InsettableShape {
    var cornerRadius: CGFloat = 18
    var notchWidth: CGFloat = 76
    var notchDepth: CGFloat = 11
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let radius = max(0, cornerRadius - insetAmount)
        let depth = max(0, notchDepth - insetAmount)
        let flare: CGFloat = 4
        let bottom: CGFloat = min(5, depth)
        let left = r.midX - notchWidth / 2
        let right = r.midX + notchWidth / 2
        var p = Path()
        p.move(to: CGPoint(x: r.minX + radius, y: r.minY))
        if depth > 0 {
            p.addArc(tangent1End: CGPoint(x: left, y: r.minY),
                     tangent2End: CGPoint(x: left, y: r.minY + depth), radius: flare)
            p.addArc(tangent1End: CGPoint(x: left, y: r.minY + depth),
                     tangent2End: CGPoint(x: right, y: r.minY + depth), radius: bottom)
            p.addArc(tangent1End: CGPoint(x: right, y: r.minY + depth),
                     tangent2End: CGPoint(x: right, y: r.minY), radius: bottom)
            p.addArc(tangent1End: CGPoint(x: right, y: r.minY),
                     tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: flare)
        }
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
