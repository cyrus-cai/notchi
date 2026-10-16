import SwiftUI

/// One model card standing in the wallet: the vendor's mark and the lineup's
/// name.
struct WalletCard: Identifiable, Equatable {
    let id: String
    let name: String
    let vendor: String
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
    var cardHelp: String = ""
    var onCard: (WalletCard) -> Void
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                }
            case .ended:
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                    pointer = nil
                    open = false
                }
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
                    .fill(LinearGradient(colors: [Color(white: 0.12), Color(white: 0.095)],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.55), radius: 5, y: -2)
            }
            .overlay {
                // Light that follows the pointer across the surface.
                if let pointer, !reduceMotion {
                    Self.pocketShape
                        .fill(RadialGradient(colors: [Color.white.opacity(0.09), .clear],
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
                    .help(cardHelp)
            }
        }
        .padding(.horizontal, Self.cardInset)
    }

    private func cardView(_ card: WalletCard, lit: Bool, named: Bool) -> some View {
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
        .opacity(named ? 1 : 0)
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
