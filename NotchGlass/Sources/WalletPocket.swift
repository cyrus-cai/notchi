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
/// cards add one row of height.
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
    private static var strip: CGFloat { 26 }
    /// Taller than `strip`, so each card's bottom stays tucked behind the pocket.
    private static var cardHeight: CGFloat { 50 }
    private static var cardInset: CGFloat { 12 }
    private static var pocketShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

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
                Self.pocketShape
                    // Opaque, so the cards' lower halves stay hidden behind it.
                    .fill(LinearGradient(colors: [Color(white: 0.12), Color(white: 0.095)],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.55), radius: 5, y: -2)
            }
            .overlay {
                Self.pocketShape
                    .strokeBorder(Tokens.recessRim, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .brandAura(in: Self.pocketShape, lineWidth: 1.2)
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
                .frame(width: 11, height: 11)
                .opacity(0.8)
            Text(card.name)
                .font(.sf(Tokens.TypeSize.meta - 0.5))
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
