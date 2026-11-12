import AppKit
import Combine
import SwiftUI

// MARK: - State

/// The Notchi license: one $19 payment that makes the free models and Jev
/// available to this account (`backend/src/license.ts`).
///
/// Everything here is behind the gateway's switch. `/v1/me` sends
/// `license.live`; while it is false, `status` is `.hidden` and no surface in
/// the app mentions a license. An account registered before the cutoff never
/// sees a purchase either: it is `.included`, or `.active` once its key is
/// issued.
///
/// Where it shows:
///   - Settings → Model, the card: one license card stands in the pocket (an
///     empty slot until there is a key; clicking a held one copies the key),
///     and the pocket's face has Buy and the key field while this account
///     needs one. An account registered before the cutoff reads "Free for
///     good" there, switch on or off.
///   - Balances: the purchase as a line.
///   - The resting notch: a card after a chat round was refused, and Notchi's
///     nod with "License activated" when one arrives (`RestingResult`).
///
/// Local review, with the payment simulated and Stripe untouched:
///
///     defaults write com.notchglass.app NotchiLicensePreview -bool YES
///
/// A real test purchase goes through the staging gateway, where the switch is
/// on and the cutoff is in the past:
///
///     defaults write com.notchglass.app NoNoBaseURL <staging url>/v1
@MainActor
final class NotchiLicense: ObservableObject {
    static let shared = NotchiLicense()

    enum Status: Equatable {
        /// The switch is off: show nothing.
        case hidden
        /// This account has to buy one.
        case needed
        /// This account holds a key. `source` is `purchase`, `early` or `grant`.
        case active(key: String, source: String)
        /// Registered before the cutoff; the key is issued once the switch is on.
        case included
    }

    enum Phase: Equatable {
        case idle
        /// Asking the gateway for the checkout page. Once it is open the phase
        /// goes back to idle and the wait runs behind it: clicking Buy again
        /// reopens the same checkout (the gateway reuses an open session).
        case buying
        case activating
        case failed(String)
    }

    @Published private(set) var status: Status = .hidden
    @Published private(set) var phase: Phase = .idle
    /// The checkout page is open in the browser and the payment has not
    /// landed yet. The card and the Settings row say so.
    @Published private(set) var awaitingPayment = false
    /// Set by the card's "Enter key": Settings opens with the key field out.
    @Published var wantsKeyEntry = false

    static var preview: Bool { UserDefaults.standard.bool(forKey: "NotchiLicensePreview") }
    /// The key a simulated payment produced. Not persisted.
    private var previewKey: String?

    private let account = NoNoAccount.shared
    private var subscriptions: Set<AnyCancellable> = []
    private var waitTask: Task<Void, Never>?

    private init() {
        account.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &subscriptions)
        recompute()
    }

    var priceUSD: Double { account.snapshot?.license?.priceUSD ?? 19 }

    var priceText: String {
        let price = priceUSD
        return price.rounded() == price ? "$\(Int(price))" : String(format: "$%.2f", price)
    }

    /// When the license was bought, for the Balances line. Nil unless bought.
    var purchasedAt: Date? {
        guard case .active(_, "purchase") = status else { return nil }
        if Self.preview { return Date() }
        guard let ms = account.snapshot?.license?.issuedAt else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    var key: String? {
        if case .active(let key, _) = status, !key.isEmpty { return key }
        return nil
    }

    /// Registered before the cutoff: free for good, whether or not the
    /// gateway's switch is on. The card in Settings says so.
    var freeForGood: Bool {
        if Self.preview { return false }
        if status == .included { return true }
        if case .active(_, "early") = status { return true }
        return account.snapshot?.license?.status == "included"
    }

    /// The cutoff's year, for "Downloaded before 2027".
    var freeBeforeYear: String? {
        guard let text = account.snapshot?.license?.freeBefore,
              let date = ISO8601DateFormatter().date(from: text) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return String(calendar.component(.year, from: date))
    }

    /// The key with all but its last group hidden, for the card.
    var maskedKey: String? {
        guard let key else { return nil }
        let groups = key.split(separator: "-")
        guard groups.count == 5 else { return key }
        return "NOTCHI-•••••-•••••-•••••-" + groups[4]
    }

    private func recompute() {
        let next = computeStatus()
        guard next != status else { return }
        let was = status
        status = next
        if case .active = next, was == .needed {
            // Paid in the browser, or a key typed in Settings, while this
            // process was watching.
            waitTask?.cancel()
            waitTask = nil
            awaitingPayment = false
            phase = .idle
            wantsKeyEntry = false
            LicensePrompt.shared.activated()
        }
    }

    private func computeStatus() -> Status {
        if Self.preview {
            if let previewKey { return .active(key: previewKey, source: "purchase") }
            return .needed
        }
        guard let license = account.snapshot?.license, license.live else { return .hidden }
        switch license.status {
        case "active": return .active(key: license.key ?? "", source: license.source ?? "purchase")
        case "included": return .included
        default: return .needed
        }
    }

    // MARK: Buying

    /// Open Stripe's checkout and wait for the license to land. It arrives with
    /// Stripe's webhook, so this polls `/v1/me` until it does.
    func buy() async {
        guard status == .needed, phase != .buying, phase != .activating else { return }
        phase = .buying
        if Self.preview {
            try? await Task.sleep(nanoseconds: 600_000_000)
            phase = .idle
            awaitingPayment = true
            waitTask?.cancel()
            waitTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                guard !Task.isCancelled, let self else { return }
                self.previewKey = Self.sampleKey()
                self.recompute()
            }
            return
        }
        do {
            let url = try await account.openLicenseCheckout()
            NSWorkspace.shared.open(url)
            phase = .idle
            awaitingPayment = true
            waitForLicense()
        } catch {
            phase = .failed(message(for: error))
        }
    }

    private func waitForLicense() {
        waitTask?.cancel()
        waitTask = Task { [weak self] in
            // A card form, 3-D Secure, a delayed method: fifteen minutes,
            // every three seconds.
            let deadline = Date().addingTimeInterval(15 * 60)
            while Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.account.reloadQuietly()
                if case .active = self.status { return }
            }
            // Not a verdict: a payment that clears later shows on the next
            // refresh.
            if !Task.isCancelled { self?.awaitingPayment = false }
        }
    }

    // MARK: Activating a key

    /// Hold `key` on this account. A failure leaves its message in `phase`.
    @discardableResult
    func activate(_ key: String) async -> Bool {
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, phase != .activating else { return false }
        phase = .activating
        if Self.preview {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let normalized = Self.normalize(typed) else {
                phase = .failed(L("license.error.invalidKey"))
                return false
            }
            previewKey = normalized
            recompute()
            return true
        }
        do {
            try await account.activateLicense(typed)
            await account.reloadQuietly()
            if phase == .activating { phase = .idle }
            return true
        } catch {
            phase = .failed(message(for: error))
            return false
        }
    }

    func clearFailure() {
        if case .failed = phase { phase = .idle }
    }

    /// The gateway's refusal in the app's language.
    private func message(for error: Error) -> String {
        switch account.errorCode(error) {
        case "invalid_key": return L("license.error.invalidKey")
        case "unknown_key": return L("license.error.unknownKey")
        case "license_revoked": return L("license.error.revoked")
        case "too_many_attempts": return L("license.error.tooManyAttempts")
        case "too_many_moves": return L("license.error.tooManyMoves")
        case "already_licensed": return L("license.error.alreadyLicensed")
        default: return account.describe(error)
        }
    }

    // MARK: Refusals

    private static let lastOfferKey = "license.offer.lastShown"

    /// A chat round was refused with `license_required`. Offer the license from
    /// the resting notch, at most once a day. Jev's background calls do not
    /// come here: they fall back on-device, and a card nobody asked for would
    /// interrupt a copy.
    func noteRefusal() {
        guard status == .needed else { return }
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: Self.lastOfferKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 3600 { return }
        defaults.set(Date(), forKey: Self.lastOfferKey)
        LicensePrompt.shared.offer()
    }

    // MARK: Keys

    /// `NOTCHI-XXXXX-XXXXX-XXXXX-XXXXX`, or nil when `text` cannot be a key.
    /// The same rules as the gateway's `normalizeKey`.
    static func normalize(_ text: String) -> String? {
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var body = text.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if body.hasPrefix("NOTCHI"), body.count == 26 { body = String(body.dropFirst(6)) }
        body = String(body.map { $0 == "O" ? "0" : ($0 == "I" || $0 == "L") ? "1" : $0 })
        guard body.count == 20, body.allSatisfy({ alphabet.contains($0) }) else { return nil }
        var groups: [String] = []
        var rest = Substring(body)
        while !rest.isEmpty {
            groups.append(String(rest.prefix(5)))
            rest = rest.dropFirst(5)
        }
        return "NOTCHI-" + groups.joined(separator: "-")
    }

    static func sampleKey() -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        return normalize(String((0..<20).map { _ in alphabet.randomElement()! }))!
    }

    #if DEBUG
    /// `NOTCH_DEMO_LICENSE=offer|activated`.
    func _debugPresent(offer: Bool) {
        if offer {
            LicensePrompt.shared.offer()
        } else {
            if status != .needed { previewKey = nil; recompute() }
            previewKey = Self.sampleKey()
            recompute()
        }
    }

    /// `NOTCH_DEMO_LICENSE_RENDER=<dir>`: the card and the Settings row, on
    /// black, as PNGs. Screenshot aid only.
    func _debugRender(to dir: String, model: NotchModel) {
        func write<V: View>(_ view: V, _ name: String) {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
            renderer.scale = 2
            guard let cg = renderer.cgImage else { return }
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("license-\(name).png"))
        }
        previewKey = nil
        recompute()
        write(LicensePromptCard(display: 0, model: model).padding(.top, 30).background(Color.black), "offer")
        write(InlineSettingsView._debugLicenseRow(model: model).padding(20).frame(width: 520)
                .background(Color(white: 0.08)), "settings")
        write(InlineSettingsView._debugLicenseRow(model: model, entering: true).padding(20).frame(width: 520)
                .background(Color(white: 0.08)), "settings-key")
        _ = InlineSettingsView._debugLicenseRow(model: model, entering: false)
        write(RestingLicenseEar().padding(10).background(Color.black), "ear")
        write(SettingsPassport(shut: true, stamp: nil, keyText: nil, note: nil, onCover: {}, onKey: {})
                .padding(30).background(Color(white: 0.08)), "pane-shut")
        write(SettingsPassport(shut: false, stamp: L("license.state.activated"),
                               keyText: "NOTCHI-•••••-•••••-•••••-7KQ2M", note: nil, onCover: {}, onKey: {})
                .padding(30).background(Color(white: 0.08)), "pane-active")
        write(SettingsPassport(shut: false, stamp: L("license.stamp.founding"), keyText: nil,
                               note: nil, onCover: {}, onKey: {})
                .padding(30).background(Color(white: 0.08)), "pane-free")
        write(LicenseOfferCard(openProgress: 1, debugResultKey: Self.sampleKey()) {}
                .padding(32).background(Color(white: 0.3)), "result")
        for p in [0, 0.25, 0.5, 0.75, 1] as [CGFloat] {
            write(LicenseOfferCard(openProgress: p) {}.padding(32).background(Color(white: 0.3)),
                  "passport-\(Int(p * 100))")
        }
    }
    #endif
}

// MARK: - Presenter

/// The two things the resting notch says about a license.
///
/// The offer is a card the notch unfolds into, like `UpdatePrompt`'s. An
/// activation is Notchi's nod with one line, held a few seconds like a
/// finished task (`RestingResult`). Neither shows while the panel is open; an
/// activation that lands then waits for the next rest.
@MainActor
final class LicensePrompt: ObservableObject {
    static let shared = LicensePrompt()

    /// The display the offer card is up on.
    @Published private(set) var offerDisplay: CGDirectDisplayID?

    private weak var model: NotchModel?
    private var pickDisplay: (() -> CGDirectDisplayID?)?
    private var pendingOffer = false
    private var pendingActivation = false
    private var subscriptions: Set<AnyCancellable> = []

    func start(model: NotchModel, pickDisplay: @escaping () -> CGDirectDisplayID?) {
        self.model = model
        self.pickDisplay = pickDisplay
        model.$open
            .removeDuplicates()
            .sink { [weak self] open in
                guard let self else { return }
                if open {
                    self.hideOffer()
                } else {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        self.showPending()
                    }
                }
            }
            .store(in: &subscriptions)
    }

    func offer() {
        pendingOffer = true
        showPending()
    }

    func activated() {
        // The offer has nothing left to sell.
        pendingOffer = false
        hideOffer()
        pendingActivation = true
        showPending()
    }

    func dismissOffer() {
        pendingOffer = false
        hideOffer()
    }

    private func hideOffer() {
        guard offerDisplay != nil else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { offerDisplay = nil }
    }

    private func showPending() {
        guard let model, !model.open, !OnboardingService.shared.showIntro else { return }
        if pendingActivation {
            pendingActivation = false
            RestingResult.shared.show(L("license.activated"), failed: false, kind: .license)
            return
        }
        guard pendingOffer, offerDisplay == nil, UpdatePrompt.shared.showing == nil,
              let display = pickDisplay?() else { return }
        pendingOffer = false
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { offerDisplay = display }
    }
}

// MARK: - Offer card

/// The card the resting notch unfolds into after a refused round: a title,
/// one line, the price on the button, and a way in for someone who already bought.
/// `UpdatePromptCard`'s layout, button and close control.
struct LicensePromptCard: View {
    let display: CGDirectDisplayID
    weak var model: NotchModel?

    @ObservedObject private var license = NotchiLicense.shared
    @State private var keyHovered = false

    static let width: CGFloat = UpdatePromptCard.width

    private var buying: Bool { license.phase == .buying }

    var body: some View {
        VStack(spacing: 0) {
            Text(L("license.offer.title"))
                .font(.sf(15))
                .foregroundStyle(Tokens.text1)
            // One line under the title, as the update card has: what the
            // purchase includes, then where the purchase stands.
            Group {
                if case .failed(let why) = license.phase {
                    Text(why)
                } else if license.awaitingPayment {
                    Text(L("connector.waiting"))
                } else {
                    Text(L("license.offer.body"))
                }
            }
            .font(.sf(Tokens.TypeSize.form))
            .foregroundStyle(Tokens.text2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
            buyButton
                .padding(.top, 16)
            Button(action: enterKey) {
                Text(L("license.enterKey"))
                    .font(.sf(Tokens.TypeSize.meta, weight: .medium))
                    .foregroundStyle(keyHovered ? Tokens.text1 : Tokens.text4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { keyHovered = $0 }
            .animation(.easeOut(duration: Tokens.rowFade), value: keyHovered)
            .padding(.top, 12)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .frame(width: Self.width)
        .overlay(alignment: .topTrailing) {
            GlassIconButton(systemName: "xmark",
                            help: L("updatePrompt.dismiss"),
                            tipEdge: .bottom,
                            size: Tokens.Control.inline,
                            glyphSize: Tokens.TypeSize.caption) {
                LicensePrompt.shared.dismissOffer()
            }
            .padding(.top, 2)
            .padding(.trailing, 12)
        }
    }

    /// The update card's Restart button, busy while Stripe has the browser.
    private var buyButton: some View {
        BuyButtonFace(title: license.priceText, busy: buying) {
            license.clearFailure()
            Task { await license.buy() }
        }
    }

    private func enterKey() {
        LicensePrompt.shared.dismissOffer()
        guard let model else { return }
        license.wantsKeyEntry = true
        model.settingsSection = InlineSettingsView.Section.model.rawValue
        model.openSettings()
    }
}

/// `UpdatePromptCard`'s white Restart capsule.
struct BuyButtonFace: View {
    let title: String
    let busy: Bool
    var fullWidth = false
    /// A second, quieter line under the title.
    var subtitle: String? = nil
    /// The teal gradient button (`LicenseTeal`) with white text, the same in
    /// light and dark.
    var gradient = false
    let action: () -> Void
    @State private var hovered = false
    /// White on dark glass, black on a light card.
    @Environment(\.colorScheme) private var colorScheme
    private var light: Bool { colorScheme == .light }

    /// The popup's full-width button is a touch taller with tighter corners;
    /// the compact one stays a capsule.
    private var height: CGFloat { subtitle != nil ? 46 : (fullWidth ? 36 : 32) }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: fullWidth ? 14 : height / 2, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .environment(\.colorScheme, gradient || light ? .dark : .light)
                }
                VStack(spacing: 1) {
                    Text(title)
                        .font(.sf(Tokens.TypeSize.form))
                    if let subtitle {
                        Text(subtitle)
                            .font(.sf(Tokens.TypeSize.meta))
                            .foregroundStyle((light ? Color.white : Color.black).opacity(0.55))
                    }
                }
            }
            .foregroundStyle(gradient || light ? Color.white : Color.black)
            .padding(.horizontal, 20)
            .frame(minWidth: 112, maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .background {
                if gradient {
                    BuyButtonGradient(dimmed: hovered && !busy, shape: shape)
                } else {
                    BuyButtonFlow(dimmed: hovered && !busy, shape: shape, base: light ? .black : .white)
                }
            }
            .shadow(color: gradient ? LicenseTeal.teal.opacity(0.35)
                        : (light ? .black.opacity(0.12) : .white.opacity(0.14)),
                    radius: gradient ? 10 : 5, y: gradient ? 4 : 1)
            .contentShape(shape)
        }
        .buttonStyle(GlassPressStyle())
        .allowsHitTesting(!busy)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovered)
        .animation(.easeOut(duration: Tokens.hoverFade), value: busy)
    }
}

/// The buy button's fill: white, with a soft tinted band that sweeps across it
/// on a loop (the same sweep as `WaitShimmer`, drawn under the label instead
/// of over it). Static white under Reduce Motion.
private struct BuyButtonFlow: View {
    var dimmed: Bool
    var shape: RoundedRectangle
    var base: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One pass, edge to edge, in seconds.
    private static let period: Double = 3.2

    var body: some View {
        shape
            .fill(base.opacity(dimmed ? 0.85 : 1))
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: Self.period) / Self.period
                        GeometryReader { geo in
                            let band = geo.size.width * 0.6
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: Color(red: 0.80, green: 0.86, blue: 1.0).opacity(0.55), location: 0.35),
                                    .init(color: Color(red: 0.93, green: 0.82, blue: 1.0).opacity(0.55), location: 0.65),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            // −band parks it off the left edge, width off the right.
                            .offset(x: -band + (geo.size.width + band) * t)
                        }
                    }
                    // Softer over the black light-mode button, where the
                    // full band reads as a smudge.
                    .opacity(base == .black ? 0.35 : 1)
                    .clipShape(shape)
                    .allowsHitTesting(false)
                }
            }
    }
}

// MARK: - Activation ear

/// The left ear's content when a license lands: Notchi's nod (`.saved`, the
/// copy-sense ears' write verdict) and one faint line in the copy-sense
/// hint's type.
struct RestingLicenseEar: View {
    static let gap: CGFloat = NotchIsland.faceTextGap

    var body: some View {
        HStack(spacing: 0) {
            NotchiFace(expression: .saved)
                .frame(width: NotchiFace.slotWidth)
            Text(L("license.activated"))
                .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                .tracking(0.3)
                .foregroundStyle(Tokens.text2)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, Self.gap)
        }
    }

    /// The text's width, for the ear's slot. Measured rather than read back
    /// from layout because the island sizes the ear before it is drawn.
    static var textWidth: CGFloat {
        let text = L("license.activated")
        let font = NSFont.systemFont(ofSize: Tokens.TypeSize.meta)
        let width = (text as NSString).size(withAttributes: [.font: font, .kern: 0.3]).width
        return ceil(width)
    }
}

// MARK: - Buy License popup

/// The Buy License popup from the Settings sidebar. Drawn in its own window
/// (`LicenseOfferWindow`) so it can run past the island's edges instead of
/// being cut off by them.
struct LicenseOfferCard: View {
    var startWithKeyField = false
    var onClose: () -> Void

    @ObservedObject private var license = NotchiLicense.shared
    @State private var enteringKey = false
    @State private var keyDraft = ""
    @State private var activateHovering = false
    /// Where the pointer is over the left page, -1...1 from the mark; nil
    /// when it is elsewhere.
    @State private var markPointer: CGSize?
    /// The photo page's own director, so the thanks line can change with it.
    @State private var markDirector = NotchiDirector()
    @State private var stamped = false
    @State private var keyCopied = false
    /// A debug render's stand-in key, to draw the result page.
    private var debugResultKey: String?
    /// Holds how far the passport is open; the window folds it shut on close.
    @ObservedObject private var presentation: LicenseOfferPresentation
    @FocusState private var keyFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// One page; the open passport is two.
    static let pageWidth: CGFloat = 350
    /// Rounder than the standard modal (22).
    static let cornerRadius: CGFloat = 30
    /// A page is taller than wide, like a passport's (88 × 125 mm, near enough).
    static let pageHeight: CGFloat = 470
    /// The bound edge of each page.
    static let spineRadius: CGFloat = 6
    private static let surface = RoundedRectangle(cornerRadius: 12, style: .continuous)

    static let leftShape = UnevenRoundedRectangle(
        topLeadingRadius: cornerRadius, bottomLeadingRadius: cornerRadius,
        bottomTrailingRadius: spineRadius, topTrailingRadius: spineRadius, style: .continuous)
    static let rightShape = UnevenRoundedRectangle(
        topLeadingRadius: spineRadius, bottomLeadingRadius: spineRadius,
        bottomTrailingRadius: cornerRadius, topTrailingRadius: cornerRadius, style: .continuous)

    init(startWithKeyField: Bool = false, presentation: LicenseOfferPresentation? = nil,
         openProgress: CGFloat? = nil, debugResultKey: String? = nil, onClose: @escaping () -> Void) {
        self.startWithKeyField = startWithKeyField
        self.debugResultKey = debugResultKey
        self.onClose = onClose
        let presentation = presentation ?? LicenseOfferPresentation()
        let still = startWithKeyField || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        presentation.openProgress = openProgress ?? (still ? 1 : 0)
        _presentation = ObservedObject(wrappedValue: presentation)
    }

    var body: some View {
        PassportSpread(progress: presentation.openProgress, pageWidth: Self.pageWidth,
                       left: leftPage, right: rightPage,
                       cover: PassportCover(shape: Self.rightShape),
                       back: pageBack)
            .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82), value: enteringKey)
            .onExitCommand { onClose() }
            .onAppear {
                license.clearFailure()
                if startWithKeyField { openKeyField() }
                guard presentation.openProgress == 0 else { return }
                // Shut while the card rises in, then the cover swings open.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard !presentation.closing else { return }
                    withAnimation(LicenseOfferMotion.open) { presentation.openProgress = 1 }
                }
            }
    }

    /// The photo page: Notchi's mark and who makes it.
    private var leftPage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            // The website hero's mark: Notchi's eyes running through every form.
            TiltingMark(pointer: markPointer) {
                NotchiMark(mood: .waiting, eyeHeight: 30, shared: markDirector)
                    // The eyes are light ink; on the light card they read dark.
                    .modifier(LightInvert(on: colorScheme == .light))
            }
            .padding(.bottom, 28)
            if resultKey != nil && !license.freeForGood {
                ThanksRotation(director: markDirector)
                    .padding(.horizontal, 36)
            } else {
                Text(L("license.page.intro"))
                    .font(.sf(Tokens.TypeSize.form))
                    .foregroundStyle(Tokens.text1)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 36)
            }
            Spacer(minLength: 0)
        }
        .frame(width: Self.pageWidth, height: Self.pageHeight)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                let cx = Self.pageWidth / 2, cy = Self.pageHeight * 0.44
                markPointer = CGSize(width: max(-1, min(1, (p.x - cx) / cx)),
                                     height: max(-1, min(1, (p.y - cy) / cy)))
            case .ended:
                markPointer = nil
            }
        }
        // Four-point sparkles drifting out from the mark.
        .background(SparkleField())
        .background { PassportPageSurface(shape: Self.leftShape, spine: .trailing, rosette: true) }
    }

    /// What comes with it, and the purchase; once bought or activated, the
    /// result in its place.
    private var rightPage: some View {
        ZStack {
            if resultKey != nil || license.status == .included {
                resultContent(resultKey)
                    .transition(.opacity)
            } else {
                offerContent
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: resultKey)
        .padding(.horizontal, 16)
        .padding(.top, 44)
        .padding(.bottom, 22)
        .frame(width: Self.pageWidth, height: Self.pageHeight)
        .background { PassportPageSurface(shape: Self.rightShape, spine: .leading, rosette: false) }
        .overlay(alignment: .topTrailing) {
            // The license prompt card's close control. The result has Done.
            if resultKey == nil && license.status != .included {
                GlassIconButton(systemName: "xmark",
                                help: L("updatePrompt.dismiss"),
                                tipEdge: .bottom,
                                size: Tokens.Control.inline,
                                glyphSize: Tokens.TypeSize.caption) {
                    onClose()
                }
                .padding(.top, 12)
                .padding(.trailing, 12)
                .transition(.opacity)
            }
        }
    }

    /// The key this account now holds, once the purchase or a typed key went
    /// through while the card is open.
    private var resultKey: String? {
        #if DEBUG
        if let debugResultKey { return debugResultKey }
        #endif
        return license.key
    }

    /// After the purchase: the stamp, the whole key with Copy (it is what a
    /// reinstall or another Mac asks for), where else it is kept, and Done.
    private func resultContent(_ key: String?) -> some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            PassportStamp(text: L(license.freeForGood ? "license.stamp.founding" : "license.state.activated"))
                .scaleEffect(stamped ? 1 : 1.8)
                .opacity(stamped ? 1 : 0)
            if key != nil {
                // Placeholder counts and action until the server tracks
                // activations.
                HStack(spacing: 12) {
                    Text(String(format: L("license.devicesLeft"), 2, 3))
                        .monospacedDigit()
                        .foregroundStyle(Tokens.text3)
                    UnderlineLink(title: L("license.deactivate")) {}
                        .fixedSize()
                }
                .font(.sf(Tokens.TypeSize.meta))
                .padding(.top, 14)
            }
            Spacer(minLength: 0)
            if let key { VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(key)
                        .font(.system(size: Tokens.TypeSize.label, design: .monospaced))
                        .foregroundStyle(Tokens.text1)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    UnderlineLink(title: keyCopied ? L("license.copied") : L("license.copy")) {
                        copy(key)
                    }
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .recessedSurface(in: RoundedRectangle.control, lit: false)
                if license.purchasedAt != nil {
                    Text(L("license.receiptEmail"))
                        .font(.sf(Tokens.TypeSize.meta))
                        .foregroundStyle(Tokens.text3)
                        .padding(.horizontal, 4)
                }
            } }
            BuyButtonFace(title: L("shortcuts.promptAction.done"), busy: false, fullWidth: true,
                          gradient: true) { onClose() }
                .padding(.top, 10)
        }
        .onAppear {
            guard !stamped else { return }
            if reduceMotion { stamped = true; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.55)) { stamped = true }
            }
        }
    }

    private func copy(_ key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        keyCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            keyCopied = false
        }
    }

    /// The price, what comes with it, and Buy.
    private var offerContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer(minLength: 0)
            Text(L("license.sidebar.buy"))
                .font(.sf(Tokens.TypeSize.form + 2))
                .foregroundStyle(Tokens.text1)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)

            // What the price buys: the app.
            VStack(alignment: .leading, spacing: 12) {
                feature("checkmark", L("license.page.updates"))
                feature("checkmark", L("license.line.devices"))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            // A plain list on the page itself: no panel behind it, no rules
            // between rows.
            VStack(alignment: .leading, spacing: 12) {
                // The price buys the app; these come with it at no cost.
                Text(L("license.page.gifts"))
                    .font(.sf(Tokens.TypeSize.meta + 0.5))
                    .foregroundStyle(Tokens.text3)
                feature("checkmark", L("license.line.credit"))
                feature("checkmark", L("license.line.models"))
                feature("checkmark", L("license.line.jev"))
                Text(L("license.line.fairUse"))
                    .font(.sf(Tokens.TypeSize.meta))
                    .foregroundStyle(Tokens.text4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            Spacer(minLength: 0)
            Spacer(minLength: 0)

            VStack(spacing: 10) {
                if enteringKey {
                    HStack(spacing: 8) {
                        keyField
                        if license.phase == .activating {
                            ProgressView().controlSize(.small)
                                .frame(width: 30, height: 30)
                        } else {
                            Button { activate() } label: {
                                AddCreditButtonFace(title: L("license.activate"), lit: activateHovering,
                                                    compact: true, height: 30)
                            }
                            .buttonStyle(GlassPressStyle())
                            .onHover { activateHovering = $0 }
                            .animation(.easeOut(duration: Tokens.hoverFade), value: activateHovering)
                        }
                    }
                    // Back to the purchase, in the place "Enter key" held.
                    UnderlineLink(title: L("license.back")) { closeKeyField() }
                        .fixedSize()
                } else {
                    BuyButtonFace(title: String(format: L("license.page.buyOnce"), license.priceText),
                                  busy: license.phase == .buying, fullWidth: true,
                                  gradient: true) {
                        license.clearFailure()
                        Task { await license.buy() }
                    }
                    UnderlineLink(title: L("license.alreadyPurchased")) { openKeyField() }
                        .fixedSize()
                }
                if case .failed(let why) = license.phase {
                    Text(why)
                        .font(.sf(Tokens.TypeSize.meta))
                        .foregroundStyle(Tokens.text2)
                } else if license.awaitingPayment {
                    Text(L("connector.waiting"))
                        .font(.sf(Tokens.TypeSize.meta))
                        .foregroundStyle(Tokens.text3)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The inside of the cover while it swings over: blank paper.
    private var pageBack: some View {
        Self.rightShape.fill(Tokens.adaptive(dark: NSColor(white: 0.07, alpha: 1),
                                             light: NSColor(white: 0.97, alpha: 1)))
    }

    /// The feature icons take the buy button's hues (`LicenseTeal`).
    private static let iconColor = LinearGradient(
        colors: [LicenseTeal.blue, LicenseTeal.green],
        startPoint: .bottomLeading, endPoint: .topTrailing)

    private func feature(_ symbol: String, _ text: String) -> some View {
        featureRow(Image(systemName: symbol)
                       .font(.system(size: 14, weight: .semibold)), text)
    }


    private func featureRow<Icon: View>(_ icon: Icon, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            icon
                .foregroundStyle(Self.iconColor)
                .frame(width: 24)
            Text(text)
                .font(.sf(Tokens.TypeSize.meta + 1))
                .foregroundStyle(Tokens.text1)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var keyField: some View {
        ZStack(alignment: .leading) {
            if keyDraft.isEmpty {
                Text(L("license.keyPlaceholder"))
                    .font(.sf(Tokens.TypeSize.label))
                    .foregroundStyle(Tokens.text4)
                    .allowsHitTesting(false)
            }
            TextField("", text: $keyDraft)
                .textFieldStyle(.plain)
                .font(.system(size: Tokens.TypeSize.label, design: .monospaced))
                .foregroundStyle(Tokens.text1)
                .focused($keyFocused)
                .onSubmit { activate() }
                .onExitCommand { closeKeyField() }
                .onChange(of: keyDraft) { license.clearFailure() }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .recessedSurface(in: RoundedRectangle.control, lit: keyFocused)
    }

    private func openKeyField() {
        license.clearFailure()
        enteringKey = true
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            keyFocused = true
        }
    }

    private func closeKeyField() {
        enteringKey = false
        keyDraft = ""
        license.clearFailure()
    }

    private func activate() {
        let draft = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return closeKeyField() }
        license.clearFailure()
        Task { _ = await license.activate(draft) }
    }
}

/// Whether the card is in its shown state; driven by `LicenseOfferWindow`.
@MainActor
final class LicenseOfferPresentation: ObservableObject {
    @Published var shown = false
    /// Set before the close motion: the passport folds shut, then flies off.
    @Published var closing = false
    /// 0 = the passport is shut (cover only), 1 = open on both pages.
    @Published var openProgress: CGFloat = 0
}

/// The card's open and close motion: it grows from 94% with a small rise and
/// fades in; on close (once folded shut) it flies off, shrinking upward into
/// the distance.
struct LicenseOfferEntrance<Content: View>: View {
    @ObservedObject var presentation: LicenseOfferPresentation
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = presentation.shown
        content
            .scaleEffect(reduceMotion || shown ? 1 : (presentation.closing ? 0.55 : 0.94),
                         anchor: .center)
            .offset(y: reduceMotion || shown ? 0 : (presentation.closing ? -36 : 10))
            .blur(radius: reduceMotion || shown ? 0 : (presentation.closing ? 6 : 4))
            .opacity(shown ? 1 : 0)
    }
}

enum LicenseOfferMotion {
    static var enter: Animation { .spring(response: 0.38, dampingFraction: 0.8) }
    static var exitDuration: Double { 0.3 }
    static var exit: Animation { .easeIn(duration: exitDuration) }
    /// The cover swinging back shut before the card leaves.
    static var foldDuration: Double { 0.55 }
    static var fold: Animation { .timingCurve(0.45, 0, 0.3, 1, duration: foldDuration) }
    /// The cover swinging open.
    static var open: Animation { .timingCurve(0.55, 0, 0.2, 1, duration: 0.85) }
}

/// A borderless panel that can take key focus, for the key field.
private final class LicenseOfferPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The window `LicenseOfferCard` is drawn in: a child of the window Settings
/// sits in, centered on it, and kept on screen.
@MainActor
final class LicenseOfferWindow {
    static let shared = LicenseOfferWindow()

    /// Clear room around the card for its shadow.
    private static let margin: CGFloat = 32

    private var panel: LicenseOfferPanel?
    private var presentation: LicenseOfferPresentation?
    private weak var host: NSWindow?
    private var observers: [NSObjectProtocol] = []

    var isOpen: Bool { panel != nil }

    func show(over host: NSWindow, startWithKeyField: Bool, onClose: @escaping () -> Void) {
        close(animated: false)
        let presentation = LicenseOfferPresentation()
        let card = LicenseOfferEntrance(presentation: presentation) {
            LicenseOfferCard(startWithKeyField: startWithKeyField, presentation: presentation,
                             onClose: onClose)
        }
        .padding(Self.margin)
        let hosting = NSHostingView(rootView: AnyView(card))
        let panel = LicenseOfferPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                                      styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        // Dark over the notch (pinned dark Aqua); over the Settings window it
        // takes that window's light or dark.
        panel.appearance = host.effectiveAppearance
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = hosting
        panel.alphaValue = 0
        host.addChildWindow(panel, ordered: .above)
        self.panel = panel
        self.host = host
        position()
        panel.makeKey()
        let center = NotificationCenter.default
        for (name, object) in [(NSWindow.didMoveNotification, host as NSWindow),
                               (NSWindow.didResizeNotification, host),
                               (NSWindow.didResizeNotification, panel)] {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.position() }
            })
        }
        self.presentation = presentation
        // The card sits off the island in its own window; reaching it reads as
        // leaving the island, so the leave-fold stands down while it is open.
        InfoPopoverGate.enter()
        panel.alphaValue = 1
        // Set on the next pass so the card is first drawn in its start state.
        DispatchQueue.main.async {
            withAnimation(LicenseOfferMotion.enter) { presentation.shown = true }
        }
    }

    /// Plays the card out, then removes the panel. `animated: false` removes
    /// it at once (used when a new card replaces the old one).
    func close(animated: Bool = true) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard let panel else { return }
        self.panel = nil
        InfoPopoverGate.exit()
        let presentation = self.presentation
        self.presentation = nil
        if let host, host.isVisible { host.makeKey() }
        let remove = {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        guard animated, let presentation,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return remove() }
        panel.ignoresMouseEvents = true
        presentation.closing = true
        // Fold the cover back over the right page, then fly the shut book off.
        let fold = presentation.openProgress > 0 ? LicenseOfferMotion.foldDuration : 0
        if fold > 0 {
            withAnimation(LicenseOfferMotion.fold) { presentation.openProgress = 0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + fold) {
            withAnimation(LicenseOfferMotion.exit) { presentation.shown = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + fold + LicenseOfferMotion.exitDuration) { remove() }
    }

    /// Centered on the host, then pulled back inside the screen.
    private func position() {
        guard let panel, let host else { return }
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        var origin = NSPoint(x: host.frame.midX - size.width / 2,
                             y: host.frame.midY - size.height / 2)
        if let screen = host.screen ?? NSScreen.main {
            let bounds = screen.frame
            origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
            origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        }
        let frame = NSRect(origin: origin, size: size)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

// MARK: - Passport

/// The open passport: two pages side by side, and a cover hinged on the
/// spine. At `progress` 0 the cover lies over the right page and the shut
/// book sits centered; by 1 the cover has swung over to become the left page.
private struct PassportSpread<Left: View, Right: View, Cover: View, Back: View>: View, Animatable {
    var progress: CGFloat
    let pageWidth: CGFloat
    let left: Left
    let right: Right
    let cover: Cover
    let back: Back

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let p = min(max(progress, 0), 1)
        // The left page shows through as the cover's inside lands on it.
        let landing = max(0, (p - 0.82) / 0.18)
        HStack(alignment: .top, spacing: 0) {
            left.opacity(landing)
            right
        }
        .overlay(alignment: .trailing) {
            if p < 1 {
                ZStack {
                    if p < 0.5 { cover } else { back.opacity(1 - landing) }
                }
                .frame(width: pageWidth)
                .rotation3DEffect(.degrees(-180 * p), axis: (x: 0, y: 1, z: 0),
                                  anchor: .leading, perspective: 0.28)
            }
        }
        // Shut, the right page (under the cover) is the one centered.
        .offset(x: -(1 - p) * pageWidth / 2)
    }
}

/// The front cover: the buy button's teal, Notchi's eyes, the name.
private struct PassportCover: View {
    let shape: UnevenRoundedRectangle
    /// The smaller passport in Settings.
    var compact = false

    var body: some View {
        ZStack {
            shape.fill(LinearGradient(colors: LicenseTeal.hues,
                                      startPoint: .bottomLeading, endPoint: .topTrailing))
            shape.fill(LinearGradient(colors: [.white.opacity(0.14), .clear],
                                      startPoint: .top, endPoint: .center))
                .blendMode(.plusLighter)
            // Pressed into the cover: the pages' linework in white, and a
            // frame inset from the edge.
            PassportGuilloche(ink: .white, rosette: true)
                .opacity(0.16)
                .clipShape(shape)
            shape.inset(by: compact ? 9 : 14)
                .stroke(.white.opacity(0.22), lineWidth: 0.75)
            shape.inset(by: compact ? 12 : 18)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)],
                                              startPoint: .top, endPoint: .bottom),
                               lineWidth: 0.75)
            VStack(spacing: compact ? 14 : 22) {
                NotchiMark(mood: .waiting, eyeHeight: compact ? 26 : 40, shared: nil)
                Text(verbatim: "Notchi License")
                    .font(.brand(18))
                    .foregroundStyle(.white)
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.3), radius: compact ? 10 : 18, y: compact ? 5 : 10)
    }
}

/// One page of the open passport: the card's glass, with a little shade
/// along the spine.
private struct PassportPageSurface: View {
    let shape: UnevenRoundedRectangle
    let spine: HorizontalEdge
    /// The photo page carries a rosette behind Notchi's mark.
    let rosette: Bool
    /// The smaller passport in Settings: a lighter shadow.
    var compact = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            shape.fill(.clear).nativeGlass(in: shape)
            // Smoked in dark mode, frosted white in light.
            // Nearly opaque: a page, not a pane of glass.
            shape.fill(Tokens.adaptive(dark: NSColor(white: 0.07, alpha: 0.92),
                                       light: NSColor(white: 0.97, alpha: 0.95)))
            shape.fill(LinearGradient(colors: [.white.opacity(0.04), .clear],
                                      startPoint: .top, endPoint: .center))
                .blendMode(.plusLighter)
            // Saffiano leather: cross-hatch grain and a stitch line along the edge.
            PaperGrain()
                .opacity(colorScheme == .light ? 0.45 : 0.7)
                .clipShape(shape)
            shape.inset(by: 5)
                .stroke(colorScheme == .light ? Color.black.opacity(0.16) : Color.white.opacity(0.16),
                        style: StrokeStyle(lineWidth: 0.8, lineCap: .round, dash: [3, 2.2]))
            // Security print: fine teal linework, as on a passport page.
            PassportGuilloche(ink: .teal, rosette: rosette, moving: rosette && !compact)
                .opacity(colorScheme == .light ? 0.16 : 0.2)
                .clipShape(shape)
            shape.fill(LinearGradient(colors: [.black.opacity(colorScheme == .light ? 0.07 : 0.22), .clear],
                                      startPoint: spine == .leading ? .leading : .trailing,
                                      endPoint: spine == .leading ? UnitPoint(x: 0.08, y: 0.5)
                                                                  : UnitPoint(x: 0.92, y: 0.5)))
            shape.strokeBorder(
                LinearGradient(colors: colorScheme == .light
                                   ? [.black.opacity(0.10), .black.opacity(0.06)]
                                   : [.white.opacity(0.34), .white.opacity(0.08)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(colorScheme == .light ? (compact ? 0.14 : 0.22) : (compact ? 0.35 : 0.45)),
                radius: compact ? 10 : 22, y: compact ? 5 : 12)
    }
}

/// "Thanks for your purchase." in ten languages, starting with the app's own
/// language and moving to the next each time Notchi's eyes change form.
private struct ThanksRotation: View {
    let director: NotchiDirector
    private static let others = [
        "Thanks for your purchase.", "感谢你的购买。", "感謝你的購買。",
        "ご購入ありがとうございます。", "구매해 주셔서 감사합니다.", "Merci pour votre achat.",
        "Gracias por tu compra.", "Danke für deinen Kauf.", "Grazie per l'acquisto.",
        "Obrigado/Obrigada pela sua compra.",
    ]
    private let lines: [String] = {
        let own = L("license.page.thanks")
        return [own] + others.filter { $0 != own }
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            CrossfadeText(text: lines[max(0, director.formsStarted - 1) % lines.count],
                          font: Tokens.TypeSize.form, color: Tokens.text1, shimmers: false)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Saffiano texture for the passport pages, after a real passport holder:
/// fine diagonal cross-hatch ridges with slight unevenness. A seamless 240 px
/// tile drawn once from a fixed seed, shown at 2x.
private struct PaperGrain: View {
    private static let tile: NSImage = {
        let side = 240, period = 4
        var rng = SplitMix64(seed: 0x9E37_79B9)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 2, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceWhite,
                                         bytesPerRow: side * 2, bitsPerPixel: 16),
              let data = rep.bitmapData else { return NSImage() }
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 2
                let jitter = UInt8(rng.next() % 14)
                let ridge = (x + y) % period == 0          // lit edge of one hatch
                let groove = (x - y + side) % period == 0  // shaded edge of the other
                // Premultiplied: a white pixel's value equals its alpha.
                let (white, alpha): (Bool, UInt8) =
                    ridge && groove ? (true, 10 + jitter)
                    : ridge ? (true, 26 + jitter)
                    : groove ? (false, 40 + jitter)
                    : (rng.next() & 1 == 0, jitter / 2)
                data[i] = white ? alpha : 0
                data[i + 1] = alpha
            }
        }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }()

    var body: some View {
        Rectangle()
            .fill(ImagePaint(image: Image(nsImage: Self.tile), scale: 0.5))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Passport security print, drawn once in a Canvas: two bands of interleaved
/// waves along the top and bottom edges and, optionally, a rosette of
/// overlapping loops centered where the page's mark sits.
private struct PassportGuilloche: View {
    enum Ink { case teal, white }
    let ink: Ink
    let rosette: Bool
    /// The rosette turns slowly and its loops swell and settle. Still under
    /// Reduce Motion.
    var moving = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !moving || reduceMotion)) { timeline in
            draw(time: moving && !reduceMotion ? timeline.date.timeIntervalSinceReferenceDate : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(time: Double) -> some View {
        Canvas { context, size in
            let shading: GraphicsContext.Shading = ink == .white
                ? .color(.white)
                : .linearGradient(Gradient(colors: LicenseTeal.hues),
                                  startPoint: CGPoint(x: 0, y: size.height),
                                  endPoint: CGPoint(x: size.width, y: 0))
            for center in [size.height * 0.1, size.height * 0.9] {
                context.stroke(Self.band(width: size.width, centerY: center, scale: size.height / 470),
                               with: shading, lineWidth: 0.5)
            }
            if rosette {
                let c = CGPoint(x: size.width / 2, y: size.height * 0.44)
                context.stroke(Self.rosette(center: c, radius: min(size.width, size.height) * 0.3, time: time),
                               with: shading, lineWidth: 0.5)
            }
        }
    }

    /// Fourteen waves, each a little out of phase with the last, so the
    /// strands cross and part along the band.
    private static func band(width: CGFloat, centerY: CGFloat, scale: CGFloat) -> Path {
        var path = Path()
        let strands = 14
        for j in 0..<strands {
            let phase = Double(j) / Double(strands) * .pi * 2
            var x: CGFloat = 0
            while x <= width {
                let t = Double(x / width) * .pi * 2
                let y = centerY + (CGFloat(sin(t * 5 + phase)) * 14 + CGFloat(sin(t * 2 - phase / 2)) * 6) * scale
                if x == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                x += 2
            }
        }
        return path
    }

    /// Eighteen closed loops, r(t) = R + A·sin(9t + φ), each turned a little
    /// from the last.
    private static func rosette(center: CGPoint, radius: CGFloat, time: Double) -> Path {
        var path = Path()
        let loops = 18
        // A full turn in about two minutes; the loops breathe every ~8 s.
        let turn = time * 0.05
        let swell = 1 + 0.12 * sin(time * 0.8)
        for j in 0..<loops {
            let phase = Double(j) / Double(loops) * .pi * 2 / 9 + turn
            for step in 0...360 {
                let t = Double(step) / 360 * .pi * 2
                let rr = Double(radius) * (0.78 + 0.22 * swell * sin(9 * t + phase * 9 / 2) * cos(3 * t - phase))
                let p = CGPoint(x: center.x + CGFloat(cos(t + phase) * rr),
                                y: center.y + CGFloat(sin(t + phase) * rr))
                if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Passport in Settings

/// The License pane: the same passport, smaller. Shut while this account has
/// to buy (a click on the cover opens the purchase card). Open once it holds
/// a license: the key on the left page, a click copies it; the stamp on the
/// right. It swings open, and the stamp lands, when a purchase goes through
/// with the pane in view.
struct SettingsPassport: View {
    let shut: Bool
    /// The stamp's words: Activated, or Founding Activated. None: no stamp.
    let stamp: String?
    /// The masked key (or "Copied"), clickable.
    let keyText: String?
    /// A grey line in place of the key ("Downloaded before 2027").
    let note: String?
    var onCover: () -> Void
    var onKey: () -> Void

    @State private var progress: CGFloat
    @State private var stamped: Bool
    @State private var keyHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    static let pageWidth: CGFloat = 190
    static let pageHeight: CGFloat = 250
    static let leftShape = UnevenRoundedRectangle(
        topLeadingRadius: 18, bottomLeadingRadius: 18,
        bottomTrailingRadius: 4, topTrailingRadius: 4, style: .continuous)
    static let rightShape = UnevenRoundedRectangle(
        topLeadingRadius: 4, bottomLeadingRadius: 4,
        bottomTrailingRadius: 18, topTrailingRadius: 18, style: .continuous)

    init(shut: Bool, stamp: String?, keyText: String?, note: String?,
         onCover: @escaping () -> Void, onKey: @escaping () -> Void) {
        self.shut = shut
        self.stamp = stamp
        self.keyText = keyText
        self.note = note
        self.onCover = onCover
        self.onKey = onKey
        _progress = State(initialValue: shut ? 0 : 1)
        _stamped = State(initialValue: !shut)
    }

    var body: some View {
        PassportSpread(progress: progress, pageWidth: Self.pageWidth,
                       left: leftPage, right: rightPage,
                       cover: PassportCover(shape: Self.rightShape, compact: true)
                           .contentShape(Self.rightShape)
                           .onTapGesture { onCover() },
                       back: Self.rightShape.fill(Tokens.adaptive(dark: NSColor(white: 0.07, alpha: 1),
                                                                  light: NSColor(white: 0.97, alpha: 1))))
            .frame(width: Self.pageWidth * 2, height: Self.pageHeight)
            .onChange(of: shut) { _, nowShut in
                if nowShut {
                    progress = 0
                    stamped = false
                    return
                }
                guard !reduceMotion else { progress = 1; stamped = true; return }
                withAnimation(LicenseOfferMotion.open) { progress = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.55)) { stamped = true }
                }
            }
    }

    private var leftPage: some View {
        VStack(spacing: 18) {
            NotchiMark(mood: .waiting, eyeHeight: 22, shared: nil)
                .modifier(LightInvert(on: colorScheme == .light))
            if let keyText {
                Button(action: onKey) {
                    Text(keyText)
                        .font(.system(size: Tokens.TypeSize.meta - 1, design: .monospaced))
                        .foregroundStyle(keyHovered ? Tokens.text1 : Tokens.text2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .buttonStyle(.plain)
                .onHover { keyHovered = $0 }
                .animation(.easeOut(duration: Tokens.hoverFade), value: keyHovered)
            } else if let note {
                Text(note)
                    .font(.sf(Tokens.TypeSize.meta))
                    .foregroundStyle(Tokens.text3)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: Self.pageWidth, height: Self.pageHeight)
        .background { PassportPageSurface(shape: Self.leftShape, spine: .trailing, rosette: true, compact: true) }
    }

    private var rightPage: some View {
        ZStack {
            if let stamp, stamped {
                PassportStamp(text: stamp)
                    .transition(reduceMotion ? .opacity
                                : .scale(scale: 1.8).combined(with: .opacity))
            }
        }
        .frame(width: Self.pageWidth, height: Self.pageHeight)
        .background { PassportPageSurface(shape: Self.rightShape, spine: .leading, rosette: false, compact: true) }
    }
}

/// A visa stamp in the license teal: the words in a double-ruled frame, set
/// at a slant.
private struct PassportStamp: View {
    let text: String

    var body: some View {
        let frame = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Text(text.uppercased())
            .font(.sf(Tokens.TypeSize.label, weight: .bold))
            .tracking(1.6)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .overlay(frame.inset(by: 3).stroke(lineWidth: 0.75))
            .overlay(frame.stroke(lineWidth: 2))
            .foregroundStyle(LinearGradient(colors: [LicenseTeal.blue, LicenseTeal.green],
                                            startPoint: .bottomLeading, endPoint: .topTrailing))
            .opacity(0.9)
            .rotationEffect(.degrees(-9))
            .accessibilityLabel(text.replacingOccurrences(of: "\n", with: " "))
    }
}

/// Notchi's eyes turned in space: they lean toward the pointer while it is
/// over the page, and sway slowly on their own otherwise, with a shadow that
/// falls away from the lean. Flat under Reduce Motion.
private struct TiltingMark<Content: View>: View {
    var pointer: CGSize?
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        if reduceMotion {
            content
        } else {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSince(start)
                let idle = CGSize(width: sin(t * 0.7) * 0.4, height: sin(t * 0.45) * 0.25)
                let lean = pointer ?? idle
                content
                    .rotation3DEffect(.degrees(lean.width * 28), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                    .rotation3DEffect(.degrees(-lean.height * 22), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                    .shadow(color: .black.opacity(0.45), radius: 5,
                            x: -lean.width * 7, y: 7 - lean.height * 4)
                    .animation(.spring(response: 0.5, dampingFraction: 0.75), value: pointer)
            }
        }
    }
}

/// Inverts the content's colors in light mode.
private struct LightInvert: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.colorInvert() } else { content }
    }
}

/// The purchase card's one color family: teal, from the shortcut cards'
/// translation hue (`PromptShortcutCardPalette`), leaning blue at one end and
/// green at the other. The buy button, the feature icons and the sparkles all
/// draw from it.
enum LicenseTeal {
    static let blue  = Color(red: 0.10, green: 0.56, blue: 0.80)
    static let teal  = Color(red: 0.07, green: 0.62, blue: 0.62)
    static let green = Color(red: 0.12, green: 0.70, blue: 0.50)
    static let hues: [Color] = [blue, teal, green]
}

/// The gradient buy button's fill: `LicenseTeal` from blue at the
/// bottom-leading corner to green at the top-trailing one, drifting slowly
/// along the diagonal. Still under Reduce Motion.
private struct BuyButtonGradient: View {
    var dimmed: Bool
    var shape: RoundedRectangle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let hues = LicenseTeal.hues

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let sway = CGFloat(sin(t * 0.6)) * 0.18
            shape.fill(LinearGradient(colors: Self.hues,
                                      startPoint: UnitPoint(x: 0 + sway, y: 1),
                                      endPoint: UnitPoint(x: 1 + sway, y: 0)))
        }
        .overlay(shape.fill(Color.white.opacity(dimmed ? 0.10 : 0)))
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)],
                                                   startPoint: .top, endPoint: .bottom),
                                    lineWidth: 0.75))
    }
}

/// Four-point sparkles drifting outward from the center, each fading in, then
/// out, in the buy button's hues. Drawn in one Canvas. Nothing under
/// Reduce Motion.
private struct SparkleField: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    private static let count = 46
    private static let hues = LicenseTeal.hues

    /// A stable pseudo-random number in 0..<1 for sparkle `i`, channel `k`.
    private static func unit(_ i: Int, _ k: Int) -> Double {
        let x = sin(Double(i * 97 + k * 31) * 12.9898) * 43758.5453
        return x - x.rounded(.down)
    }

    private static func star(at p: CGPoint, size r: CGFloat) -> Path {
        var path = Path()
        let w = r * 0.28
        path.move(to: CGPoint(x: p.x, y: p.y - r))
        path.addQuadCurve(to: CGPoint(x: p.x + r, y: p.y), control: CGPoint(x: p.x + w, y: p.y - w))
        path.addQuadCurve(to: CGPoint(x: p.x, y: p.y + r), control: CGPoint(x: p.x + w, y: p.y + w))
        path.addQuadCurve(to: CGPoint(x: p.x - r, y: p.y), control: CGPoint(x: p.x - w, y: p.y + w))
        path.addQuadCurve(to: CGPoint(x: p.x, y: p.y - r), control: CGPoint(x: p.x - w, y: p.y - w))
        path.closeSubpath()
        return path
    }

    var body: some View {
        if reduceMotion {
            Color.clear
        } else {
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let t = timeline.date.timeIntervalSince(start)
                    let center = CGPoint(x: size.width / 2, y: size.height * 0.42)
                    let reach = hypot(size.width, size.height) * 0.55
                    for i in 0..<Self.count {
                        let duration = 3.2 + Self.unit(i, 1) * 2.8
                        let phase = (t / duration + Self.unit(i, 2))
                            .truncatingRemainder(dividingBy: 1)
                        let angle = Self.unit(i, 3) * .pi * 2
                        // Starts a little way out from the mark, so nothing is
                        // drawn over the eyes, and eases outward.
                        let distance = 26 + (1 - pow(1 - phase, 2)) * reach * (0.55 + Self.unit(i, 4) * 0.45)
                        let p = CGPoint(x: center.x + cos(angle) * distance,
                                        y: center.y + sin(angle) * distance * 0.62)
                        let fade = sin(phase * .pi)
                        let r = 1.6 + Self.unit(i, 5) * 3.4
                        let hue = Self.hues[Int(Self.unit(i, 6) * Double(Self.hues.count)) % Self.hues.count]
                        context.fill(Self.star(at: p, size: r * (0.7 + 0.3 * fade)),
                                     with: .color(hue.opacity(0.85 * fade)))
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
