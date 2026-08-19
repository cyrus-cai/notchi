import AppKit
import SwiftUI

// MARK: - Interaction Kit ports (imageexpand + imagemodal)

/// Two interactions ported from **Interaction Kit** (https://interactionkit.org,
/// MIT, © Armond Schneider) into SwiftUI:
///
/// * `ImageExpandStack` ← `MultipleImageExpand.tsx` — a pile of images that fans
///   out into a spatial layout on click, then gathers back.
/// * `ImageLightbox` ← `ImageModal.tsx` — a card opened into a focused, draggable
///   overlay that flicks away to dismiss.
///
/// The numbers are the web components' own, kept verbatim: card 190×126, expanded
/// offsets (∓96, ∓54) / (∓78, ±54), rotations −10 / 7 / −4 / 11 (×0.7 collapsed,
/// ×1.2 expanded), spring 180 / 24 / 0.75, hover 1.025 → 1.04, press 0.98, modal
/// view transition 0.32s on [0.22, 1, 0.36, 1], drag constrained to ±90 with 0.22
/// elasticity, dismissed past 140pt or 650pt/s.
///
/// What a macOS panel forced to change: the fan scales down to whatever width the
/// answer column actually has (the web container is a fixed 440×260), the
/// collapsed pile only reserves the height it uses rather than the expanded box,
/// the fan generalises past four images (two per row, same offsets for the first
/// four), and the modal is hosted inside the island instead of the page — the
/// island's own `.overlay` layer, next to the clear-history confirm.

/// One `![alt](url)` an answer references. The gallery's unit.
struct AnswerImageRef: Equatable, Identifiable {
    let alt: String
    let urlString: String
    var id: String { urlString }
}

/// Open a media reference in the default app — http/https only, matching the
/// answer renderer's link policy (answer text comes from an LLM).
private func openImageURL(_ urlString: String) {
    guard let url = URL(string: urlString),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else { return }
    NSWorkspace.shared.open(url)
}

// MARK: - The stack

/// A run of images in one answer, as a pile that fans open. Collapsed it reads as
/// one object (tap anywhere to open it); expanded, each card is its own target and
/// tapping one lifts it into `ImageLightbox`. Tapping the empty space around the
/// fan gathers it back.
struct ImageExpandStack: View {
    let images: [AnswerImageRef]

    /// The card, and the pile/fan geometry — Interaction Kit's numbers.
    private static let cardW: CGFloat = 190
    private static let cardH: CGFloat = 126
    /// Vertical distance between fanned rows: the demo's −54 → +54.
    private static let rowStep: CGFloat = 108
    /// How far each card in the collapsed pile peeks below the one above.
    private static let collapsedStep: CGFloat = 13
    /// Horizontal spread, alternating per row like the demo's ±96 then ±78.
    private static let spreadWide: CGFloat = 96
    private static let spreadNarrow: CGFloat = 78
    /// Room for the shadow to land outside the cards' bounding box.
    private static let shadowSlack: CGFloat = 10
    /// The demo's container width, which the fan is laid out against before it is
    /// scaled to the column it actually got.
    private static let designWidth: CGFloat = 440
    private static let rotations: [Double] = [-10, 7, -4, 11]
    /// The largest a card ever gets: fanned (1.015) and hovered (1.04). The box is
    /// sized for that, so a hover never pushes a card past the edge and into the
    /// thread's clip.
    private static let maxCardScale: CGFloat = 1.015 * 1.04

    private static let spring = Animation.interpolatingSpring(mass: 0.75,
                                                              stiffness: 180,
                                                              damping: 24)

    @State private var expanded = false
    @State private var columnWidth: CGFloat = designWidth

    private var rowCount: Int { (images.count + 1) / 2 }

    /// A lone image has nothing to fan out to — it is a card that opens straight
    /// into the lightbox.
    private var fannable: Bool { images.count > 1 }

    /// Fanned position for `index`: two per row, the wide pair on even rows and the
    /// narrow pair on odd ones, rows centred on the container. For four images this
    /// is exactly the demo's (−96,−54) (96,−54) (−78,54) (78,54).
    private func expandedOffset(_ index: Int) -> CGSize {
        let row = index / 2
        let magnitude = row.isMultiple(of: 2) ? Self.spreadWide : Self.spreadNarrow
        let x = index.isMultiple(of: 2) ? -magnitude : magnitude
        let y = (CGFloat(row) - CGFloat(rowCount - 1) / 2) * Self.rowStep
        return CGSize(width: x, height: y)
    }

    private func offset(_ index: Int) -> CGSize {
        expanded ? expandedOffset(index)
                 : CGSize(width: 0, height: CGFloat(index) * Self.collapsedStep)
    }

    /// −10 / 7 / −4 / 11, cycled past the fourth card, damped in the pile and
    /// pushed in the fan.
    private func rotation(_ index: Int) -> Double {
        let base = Self.rotations[index % Self.rotations.count]
        return expanded ? base * 1.2 : base * 0.7
    }

    /// How far a rotated, scaled card reaches from its own centre. A card tilted
    /// 11° is ~17pt taller than its 126pt box, and the pile only offsets *downward*
    /// — sizing the container to the cards' plain height (as the fixed-size web
    /// container could afford to) is what cropped the bottom card.
    private func halfExtent(_ index: Int) -> CGSize {
        let radians = abs(rotation(index)) * .pi / 180
        let sin = abs(Foundation.sin(radians)), cos = abs(Foundation.cos(radians))
        return CGSize(
            width: (Self.cardW * cos + Self.cardH * sin) / 2 * Self.maxCardScale,
            height: (Self.cardW * sin + Self.cardH * cos) / 2 * Self.maxCardScale)
    }

    /// The pile's true vertical span, top and bottom, around the ZStack's centre.
    private var verticalBounds: (min: CGFloat, max: CGFloat) {
        var low = CGFloat.greatestFiniteMagnitude
        var high = -CGFloat.greatestFiniteMagnitude
        for index in images.indices {
            let y = offset(index).height
            let extent = halfExtent(index).height
            low = min(low, y - extent)
            high = max(high, y + extent)
        }
        guard low <= high else { return (0, 0) }
        return (low - Self.shadowSlack, high + Self.shadowSlack)
    }

    private var contentHeight: CGFloat {
        let bounds = verticalBounds
        return bounds.max - bounds.min
    }

    /// Slide the cards so their span — not the ZStack's own centre — sits in the
    /// middle of the box the layout reserved.
    private var centeringShift: CGFloat {
        let bounds = verticalBounds
        return -(bounds.min + bounds.max) / 2
    }

    /// The fan is drawn at the demo's scale and shrunk to fit a narrower answer
    /// column, so the whole interaction keeps its proportions on any panel width.
    private var scale: CGFloat { min(1, columnWidth / Self.designWidth) }

    var body: some View {
        ZStack {
            // The gather target: the empty space the fan opened into. Only live
            // while expanded, so a collapsed pile never eats clicks meant for the
            // answer around it.
            if expanded {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Self.spring) { expanded = false }
                    }
            }

            ForEach(Array(images.enumerated()), id: \.element.id) { index, _ in
                ImageStackCard(images: images,
                               index: index,
                               width: Self.cardW,
                               height: Self.cardH,
                               expanded: expanded,
                               onTap: {
                                   // A fanned card (or a lone one) opens; a card in
                                   // the pile spends the tap fanning the pile out.
                                   if expanded || !fannable { return false }
                                   withAnimation(Self.spring) { expanded = true }
                                   return true
                               })
                    .rotationEffect(.degrees(rotation(index)))
                    .scaleEffect(expanded ? 1.015 : 1)
                    .offset(offset(index))
                    .zIndex(Double(expanded ? 20 + index : 10 + index))
            }
        }
        .offset(y: centeringShift)
        .frame(width: Self.designWidth, height: contentHeight)
        .scaleEffect(scale, anchor: .center)
        .frame(height: contentHeight * scale)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { columnWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, width in columnWidth = width }
            }
        )
        .animation(Self.spring, value: expanded)
        // A streaming answer grows its pile one image at a time: the box springs
        // to the new height instead of jumping.
        .animation(Self.spring, value: images.count)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L(expanded ? "gallery.collapse" : "gallery.expand"))
    }
}

/// One card in the pile: its own download, its own hover/press feedback, and its
/// own way into the lightbox. Keeping the load here means a card that fails is a
/// single dud in the fan rather than a hole in the answer.
private struct ImageStackCard: View {
    /// The pile this card belongs to, and where in it this card sits — opening a
    /// card opens the whole set, positioned on this one.
    let images: [AnswerImageRef]
    let index: Int
    let width: CGFloat
    let height: CGFloat
    let expanded: Bool
    /// Returns true when the tap was spent expanding the pile — the card then
    /// stays put instead of opening.
    let onTap: () -> Bool

    /// The border the web component draws outside the picture (3px), and the
    /// radius it rounds to (rounded-xl).
    private static let border: CGFloat = 3
    private static let radius: CGFloat = 12

    @Environment(\.imageLightboxHostID) private var hostID

    @State private var outcome: AnswerMediaLoader.Outcome?
    @State private var hovering = false

    private var image: AnswerImageRef { images[index] }

    var body: some View {
        Button {
            guard !onTap() else { return }
            if case .image = outcome, let hostID {
                ImageLightboxCenter.shared.present(
                    .init(images: images, index: index, host: hostID)
                )
            } else {
                openImageURL(image.urlString)
            }
        } label: {
            Group {
                switch outcome {
                case .image(let loaded):
                    Image(nsImage: loaded)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .pdf, .failed:
                    Image(systemName: "photo")
                        .font(.sf(15, weight: .medium))
                        .foregroundStyle(Tokens.text4)
                case nil:
                    ProgressView().controlSize(.small).tint(.white.opacity(0.4))
                }
            }
            .frame(width: width - Self.border * 2, height: height - Self.border * 2)
            .background(Color(white: 0.15))
            .clipShape(RoundedRectangle(cornerRadius: Self.radius - Self.border,
                                        style: .continuous))
            .padding(Self.border)
            .background(
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(Color(white: 0.25))
            )
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        }
        .buttonStyle(ImageStackCardButtonStyle(hovering: hovering, expanded: expanded))
        .onHover { inside in
            withAnimation(.interpolatingSpring(mass: 0.75, stiffness: 180, damping: 24)) {
                hovering = inside
            }
        }
        .accessibilityLabel(image.alt.isEmpty ? "image" : image.alt)
        .task(id: image.urlString) {
            outcome = await AnswerMediaLoader.shared.image(for: image.urlString)
        }
    }
}

/// The card's own scale ladder: 1.025 on hover in the pile, 1.04 in the fan, and
/// 0.98 while held — the web component's `whileHover` / `whileTap`.
private struct ImageStackCardButtonStyle: ButtonStyle {
    let hovering: Bool
    let expanded: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(scale(pressed: configuration.isPressed))
            .animation(.interpolatingSpring(mass: 0.75, stiffness: 180, damping: 24),
                       value: configuration.isPressed)
    }

    private func scale(pressed: Bool) -> CGFloat {
        if pressed { return 0.98 }
        if hovering { return expanded ? 1.04 : 1.025 }
        return 1
    }
}

// MARK: - The lightbox

/// Which image the island is currently showing full-size. One shared store so any
/// card, on any surface, opens into the same overlay — the panel hosts exactly one
/// lightbox at a time, like the clear-history confirm.
@MainActor
final class ImageLightboxCenter: ObservableObject {
    static let shared = ImageLightboxCenter()

    struct Item: Identifiable, Equatable {
        let id = UUID()
        /// The whole pile the picture came out of — the lightbox walks it with the
        /// arrow keys and the two chevrons, so opening one card opens the set.
        let images: [AnswerImageRef]
        /// Which of them is on screen.
        let index: Int
        /// Which surface opened it — the panel, or one detached window. Only that
        /// host renders it, so an image tapped in a torn-out session never also
        /// appears over the notch panel behind it.
        let host: UUID

        var current: AnswerImageRef? {
            images.indices.contains(index) ? images[index] : images.first
        }
    }

    @Published private(set) var item: Item?

    /// The web component's view transition — 0.32s on [0.22, 1, 0.36, 1].
    static let viewTransition = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.32)

    var isPresented: Bool { item != nil }

    func present(_ item: Item) {
        withAnimation(Self.viewTransition) { self.item = item }
    }

    /// Installed by the presented lightbox: how a page turn should actually be
    /// performed, so a turn asked for from outside (the arrow keys) slides the
    /// rail exactly like a swipe does instead of cutting to the next picture.
    var pager: ((Int) -> Bool)?

    /// Walk the open pile, wrapping at both ends. Returns true when it moved — the
    /// arrow-key handler reads that to decide whether the key was spent here.
    @discardableResult
    func step(_ delta: Int) -> Bool {
        if let pager { return pager(delta) }
        return commit(delta)
    }

    /// The index change itself, with no motion of its own — the lightbox owns the
    /// animation, since only it knows where the rail currently sits.
    @discardableResult
    func commit(_ delta: Int) -> Bool {
        guard let item, item.images.count > 1 else { return false }
        let count = item.images.count
        let next = ((item.index + delta) % count + count) % count
        self.item = Item(images: item.images, index: next, host: item.host)
        return true
    }

    /// Returns true when there was something to close — the Esc handler reads this
    /// to decide whether the key was spent here.
    @discardableResult
    func dismiss() -> Bool {
        guard item != nil else { return false }
        withAnimation(Self.viewTransition) { item = nil }
        return true
    }
}

/// The surface an image tapped inside this subtree opens into. Nil means nothing
/// hosts a lightbox here (settings copy, previews) — those fall back to opening
/// the source in the browser.
private struct ImageLightboxHostKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    var imageLightboxHostID: UUID? {
        get { self[ImageLightboxHostKey.self] }
        set { self[ImageLightboxHostKey.self] = newValue }
    }
}

extension View {
    /// Hosts the lightbox over this surface. Applied once per window root, inside
    /// that window's own clip so the overlay stays inside the glass.
    ///
    /// `topInset` is the strip at the top of this surface the picture must stay
    /// clear of — on the panel, the island's black hardware zone, which sits under
    /// the physical notch and would eat the top of the image. The backdrop still
    /// covers it; only the picture steps down.
    func imageLightboxHost(topInset: CGFloat = 0) -> some View {
        modifier(ImageLightboxHost(topInset: topInset))
    }
}

private struct ImageLightboxHost: ViewModifier {
    let topInset: CGFloat

    @ObservedObject private var center = ImageLightboxCenter.shared
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .environment(\.imageLightboxHostID, id)
            .overlay {
                if let item = center.item, item.host == id {
                    ImageLightbox(item: item, topInset: topInset)
                        .transition(.opacity)
                }
            }
    }
}

/// The opened image: a blurred, darkened backdrop and the picture floating over
/// it. Two gestures live here and they do not overlap — a **drag** throws the
/// picture away (Interaction Kit's dismiss), a **two-finger swipe** pages through
/// the pile it came from. The pile is laid out as three pages (previous, current,
/// next) that ride the swipe, so a half-swipe shows half the next picture and
/// releasing either carries it home or puts it back.
private struct ImageLightbox: View {
    let item: ImageLightboxCenter.Item
    /// Headroom the picture keeps clear — the notch's black zone on the panel.
    var topInset: CGFloat = 0

    /// Interaction Kit's drag numbers.
    private static let constraint: CGFloat = 90
    private static let elasticity: CGFloat = 0.22
    private static let closeDistance: CGFloat = 140
    private static let closeVelocity: CGFloat = 650
    /// The tilt the drag imparts: ±2.5° across ±300pt, in both axes.
    private static let tiltRange: CGFloat = 300
    private static let tiltDegrees: Double = 2.5

    /// Space between pages, so the neighbour arriving under the finger reads as a
    /// separate picture rather than a seam.
    private static let pageGap: CGFloat = 24
    /// How far a swipe has to carry before releasing lands on the next picture
    /// instead of springing back — a quarter of the page, within reason.
    private static func commitDistance(_ width: CGFloat) -> CGFloat {
        min(90, max(40, width * 0.25))
    }
    /// A flick: still moving this fast when the fingers lift, so a short fast
    /// swipe pages even though it never covered the distance.
    private static let flickSpeed: CGFloat = 6
    /// The page settle — same family as the stack's fan.
    private static let pageSpring = Animation.interpolatingSpring(mass: 0.75,
                                                                  stiffness: 180,
                                                                  damping: 24)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var drag: CGSize = .zero
    @State private var dragging = false
    /// Set the instant a throw is judged a dismissal, so the card keeps flying
    /// while the overlay fades rather than snapping back first.
    @State private var leaving = false

    /// Every picture the three visible pages need, decoded. They are already in
    /// the loader's cache (the pile downloaded them), so this is a lookup, not a
    /// download — which is what lets the neighbour be on screen mid-swipe.
    @State private var decoded: [String: NSImage] = [:]

    /// How far the pages are currently pushed sideways. Follows the fingers while
    /// a swipe is under way, springs to 0 once the page has changed hands.
    @State private var pageDrag: CGFloat = 0
    @State private var pageWidth: CGFloat = 1
    /// The scroll-wheel monitor that carries the swipe, alive only while a
    /// picture is open.
    @State private var swipeMonitor: Any?
    /// The last sideways delta of the swipe under way — its speed at release.
    @State private var swipeSpeed: CGFloat = 0
    /// A page has already been handed over in this gesture; the coast that
    /// follows must not buy a second one.
    @State private var swipeSpent = false

    private var current: AnswerImageRef? { item.current }
    private var multiple: Bool { item.images.count > 1 }

    private var host: String? {
        current.flatMap { URL(string: $0.urlString)?.host }
    }

    /// The three pages on the rail: what was, what is, what's next. With exactly
    /// two pictures the outer two are the same one, which is why the slot — not
    /// the URL — is the identity here.
    private var pages: [(slot: Int, ref: AnswerImageRef)] {
        guard let current else { return [] }
        guard multiple else { return [(0, current)] }
        let count = item.images.count
        let index = item.index
        return [(-1, item.images[(index - 1 + count) % count]),
                (0, current),
                (1, item.images[(index + 1) % count])]
    }

    /// Past ±90 the card still moves, at 0.22 of the distance — `dragElastic`.
    private func constrained(_ value: CGFloat) -> CGFloat {
        let magnitude = abs(value)
        guard magnitude > Self.constraint else { return value }
        let overshoot = (magnitude - Self.constraint) * Self.elasticity
        return (value < 0 ? -1 : 1) * (Self.constraint + overshoot)
    }

    private func tilt(_ value: CGFloat) -> Double {
        let clamped = max(-Self.tiltRange, min(Self.tiltRange, value))
        return Double(clamped / Self.tiltRange) * Self.tiltDegrees
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.4))
                .contentShape(Rectangle())
                .onTapGesture { ImageLightboxCenter.shared.dismiss() }
                .transition(.opacity)

            VStack(spacing: 10) {
                rail
                    // The two ways through the pile that don't need a trackpad.
                    // Only out when there IS a pile — one picture has nowhere to
                    // go.
                    .overlay(alignment: .leading) {
                        if multiple { pageButton("chevron.left", by: -1) }
                    }
                    .overlay(alignment: .trailing) {
                        if multiple { pageButton("chevron.right", by: 1) }
                    }

                if multiple || host != nil {
                    HStack(spacing: 8) {
                        if multiple {
                            Text("\(item.index + 1) / \(item.images.count)")
                                .font(.sf(12))
                                .monospacedDigit()
                                .foregroundStyle(Tokens.text4)
                        }
                        if let host {
                            // The way out to the source, in the same chip grammar
                            // the degraded media reference uses — tapping the
                            // picture is the dismiss gesture now, so the link
                            // needs its own target.
                            MediaLinkChip(label: host) {
                                current.map { openImageURL($0.urlString) }
                            }
                        }
                    }
                }
            }
            .padding(16)
            .padding(.top, topInset)
            .scaleEffect(dragging ? 1.01 : 1)
            .offset(x: constrained(drag.width), y: constrained(drag.height))
            .rotationEffect(.degrees(tilt(drag.width)))
            .rotation3DEffect(.degrees(-tilt(drag.height)),
                              axis: (x: 1, y: 0, z: 0),
                              perspective: 1 / 1200)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !dragging {
                            withAnimation(.easeOut(duration: 0.12)) { dragging = true }
                        }
                        drag = value.translation
                    }
                    .onEnded { value in
                        dragging = false
                        if shouldClose(value) {
                            leaving = true
                            withAnimation(.easeOut(duration: 0.16)) {
                                drag = CGSize(width: value.translation.width + value.velocity.width * 0.08,
                                              height: value.translation.height + value.velocity.height * 0.08)
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                                ImageLightboxCenter.shared.dismiss()
                            }
                        } else {
                            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.22)) {
                                drag = .zero
                            }
                        }
                    }
            )
            .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.94)))
        }
        .accessibilityLabel(current.map { $0.alt.isEmpty ? "image" : $0.alt } ?? "image")
        .onAppear {
            installSwipeMonitor()
            // Page turns asked for from outside (the arrow keys, via the panel's
            // key catcher) land here too, so they slide like a swipe instead of
            // cutting.
            ImageLightboxCenter.shared.pager = { delta in slide(by: delta) }
        }
        .onDisappear {
            removeSwipeMonitor()
            ImageLightboxCenter.shared.pager = nil
        }
        .task(id: pages.map(\.ref.urlString)) {
            for page in pages where decoded[page.ref.urlString] == nil {
                if case .image(let image) = await AnswerMediaLoader.shared.image(for: page.ref.urlString) {
                    decoded[page.ref.urlString] = image
                }
            }
        }
    }

    /// The three-page rail the swipe rides.
    private var rail: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(pages, id: \.slot) { page in
                    picture(page.ref, maxWidth: geo.size.width, maxHeight: geo.size.height)
                        .offset(x: CGFloat(page.slot) * (geo.size.width + Self.pageGap) + pageDrag)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { pageWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, width in pageWidth = width }
        }
    }

    @ViewBuilder
    private func picture(_ ref: AnswerImageRef, maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        if let image = decoded[ref.urlString] {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Tokens.hairline, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        } else {
            ProgressView().controlSize(.small).tint(.white.opacity(0.4))
        }
    }

    /// Hand the rail over to the neighbour in `delta`, from wherever it is right
    /// now. The incoming page is already drawn one page-width away, so putting
    /// that width into `pageDrag` at the moment the index changes leaves it
    /// exactly where it was — and the spring back to 0 finishes the motion the
    /// fingers started.
    private func slide(by delta: Int) -> Bool {
        guard multiple else { return false }
        // Beat one, no animation: the index changes and the rail is pushed by
        // exactly one page, which draws the same frame as before — the incoming
        // picture stays under the fingers rather than cutting into place.
        var instant = Transaction()
        instant.disablesAnimations = true
        var moved = false
        withTransaction(instant) {
            pageDrag += CGFloat(delta) * (pageWidth + Self.pageGap)
            moved = ImageLightboxCenter.shared.commit(delta)
        }
        guard moved else {
            withAnimation(Self.pageSpring) { pageDrag = 0 }
            return false
        }
        // Beat two, next tick so beat one has actually been drawn: the rail
        // springs home, finishing the motion the fingers started.
        DispatchQueue.main.async {
            withAnimation(Self.pageSpring) { pageDrag = 0 }
        }
        return true
    }

    /// Thrown far enough, or fast enough, to mean "away".
    private func shouldClose(_ value: DragGesture.Value) -> Bool {
        guard !leaving else { return true }
        return abs(value.translation.width) > Self.closeDistance
            || abs(value.translation.height) > Self.closeDistance
            || abs(value.velocity.width) > Self.closeVelocity
            || abs(value.velocity.height) > Self.closeVelocity
    }

    /// Two-finger swipe = paging, and it tracks the fingers the whole way. AppKit
    /// delivers a trackpad swipe as a scroll, and a scroll goes to whatever view
    /// is under the pointer — so this is a local event monitor rather than a
    /// view: the picture itself has to stay a drag target (that gesture is the
    /// dismiss) and the backdrop has to stay a click target.
    ///
    /// The deltas are taken as reported, so the direction follows the system's
    /// own natural-scrolling setting: the pile moves with the fingers either way.
    private func installSwipeMonitor() {
        guard swipeMonitor == nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard multiple else { return event }

            // A mouse wheel has no phases: it can only ever be a discrete nudge,
            // so it pages a step at a time instead of dragging the rail.
            guard event.phase != [] || event.momentumPhase != [] else {
                guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
                if abs(event.scrollingDeltaX) > 1 {
                    _ = slide(by: event.scrollingDeltaX < 0 ? 1 : -1)
                }
                return nil
            }

            // The coast after the fingers lift belongs to the gesture that already
            // ended — swallow it rather than let it page again.
            guard event.momentumPhase == [] else { return nil }

            switch event.phase {
            case .began:
                swipeSpeed = 0
                swipeSpent = false
                return nil
            case .ended, .cancelled:
                finishSwipe()
                return nil
            default:
                break
            }

            // A vertical scroll is not a page turn — let it pass untouched.
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
            guard !swipeSpent else { return nil }

            swipeSpeed = event.scrollingDeltaX
            pageDrag += event.scrollingDeltaX
            return nil
        }
    }

    /// The fingers lifted: either the rail carries on to the neighbour it was
    /// already showing, or it springs back to where it started.
    private func finishSwipe() {
        defer { swipeSpeed = 0; swipeSpent = false }
        guard !swipeSpent, pageDrag != 0 else {
            if pageDrag != 0 { withAnimation(Self.pageSpring) { pageDrag = 0 } }
            return
        }
        let carried = abs(pageDrag) >= Self.commitDistance(pageWidth)
        let flicked = abs(swipeSpeed) >= Self.flickSpeed && abs(pageDrag) > 12
        if carried || flicked {
            swipeSpent = true
            _ = slide(by: pageDrag < 0 ? 1 : -1)
        } else {
            withAnimation(Self.pageSpring) { pageDrag = 0 }
        }
    }

    private func removeSwipeMonitor() {
        if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
        swipeMonitor = nil
        pageDrag = 0
        swipeSpeed = 0
        swipeSpent = false
    }

    /// One page-turn chevron, in the panel's own glass-chip language.
    private func pageButton(_ glyph: String, by delta: Int) -> some View {
        GlassIconButton(systemName: glyph,
                        help: L(delta < 0 ? "gallery.previous" : "gallery.next"),
                        size: 30,
                        glyphSize: 12,
                        showsTooltip: false) {
            _ = slide(by: delta)
        }
        .padding(8)
    }
}

// MARK: - Grouping answer images

/// What a rendered answer is actually made of: its blocks, except that a **run of
/// images** collapses into one gallery. A column of separate image islands reads
/// as an accident of markdown; a pile reads as a set.
///
/// One image is a gallery too, deliberately: an answer streams its images in one
/// at a time, and if a lone first image rendered as a full-width island it would
/// have to jump into a card the moment the second one landed. The first image
/// arrives already in its final shape, and every image after it just joins the
/// pile.
enum MarkdownRenderItem: Identifiable {
    case block(index: Int, block: MarkdownBlock)
    case gallery(index: Int, images: [AnswerImageRef])

    var id: Int {
        switch self {
        case .block(let index, _), .gallery(let index, _): return index
        }
    }
}

/// Fold consecutive `.image` blocks into galleries, keeping every other block
/// exactly where it was. The index each item carries is its position in the
/// original block list, so the streaming tail still knows which row is last.
func markdownRenderItems(_ blocks: [MarkdownBlock]) -> [MarkdownRenderItem] {
    var items: [MarkdownRenderItem] = []
    var index = 0
    while index < blocks.count {
        guard case .image(let alt, let url) = blocks[index] else {
            items.append(.block(index: index, block: blocks[index]))
            index += 1
            continue
        }
        var run = [AnswerImageRef(alt: alt, urlString: url)]
        var next = index + 1
        while next < blocks.count, case .image(let a, let u) = blocks[next] {
            run.append(AnswerImageRef(alt: a, urlString: u))
            next += 1
        }
        items.append(.gallery(index: index, images: run))
        index = next
    }
    return items
}
