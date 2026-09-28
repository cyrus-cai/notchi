import AppKit
import Combine
import SwiftUI

// MARK: - Policy

/// Which installed versions get the update prompt, read from
/// `https://notch.website/update-policy.json` so it can change without a
/// release. A version no rule names keeps the quiet behaviour: the chip only.
///
///     { "prompt": [
///         { "versions": ["0.8.3", "0.8.4"], "message": "…",
///           "interval_hours": 24, "max_shows": 3 },
///         { "below": "0.8.0" } ] }
///
/// Every failure (offline, 404, malformed JSON) reads as "no rules".
struct UpdatePolicy: Decodable {
    struct Rule: Decodable {
        let versions: [String]?
        /// Every version older than this one.
        let below: String?
        /// Replaces the default body line.
        let message: String?
        let interval_hours: Double?
        let max_shows: Int?

        var interval: TimeInterval { (interval_hours ?? 24) * 3600 }
        var maxShows: Int { max_shows ?? 3 }

        func matches(_ version: String) -> Bool {
            if versions?.contains(version) == true { return true }
            if let below { return Self.isOlder(version, than: below) }
            return false
        }

        /// Dot-component comparison, the same as `UpdaterService.isNewer`.
        private static func isOlder(_ a: String, than b: String) -> Bool {
            let x = a.split(separator: ".").map { Int($0) ?? 0 }
            let y = b.split(separator: ".").map { Int($0) ?? 0 }
            for i in 0..<max(x.count, y.count) {
                let l = i < x.count ? x[i] : 0
                let r = i < y.count ? y[i] : 0
                if l != r { return l < r }
            }
            return false
        }
    }

    let prompt: [Rule]

    func rule(for version: String) -> Rule? {
        prompt.first { $0.matches(version) }
    }

    private static let url = URL(string: "https://notch.website/update-policy.json")!

    static func fetch() async -> UpdatePolicy? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let result = try? await ProxyConfig.urlSession.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(UpdatePolicy.self, from: result.0)
    }
}

// MARK: - Scheduler

/// Shows the update card from the resting notch, unasked, for versions the
/// policy names. It waits until the build is downloaded, the user is at the
/// Mac, and nothing would be lost to a restart; then the notch unfolds into
/// the card on the screen under the pointer. The card never takes focus.
@MainActor
final class UpdatePrompt: ObservableObject {
    static let shared = UpdatePrompt()

    struct Showing: Equatable {
        let display: CGDirectDisplayID
        let version: String
        let message: String?
    }

    @Published private(set) var showing: Showing?

    private weak var model: NotchModel?
    /// The display to show on, or nil when none is fit to (see AppDelegate).
    private var pickDisplay: (() -> CGDirectDisplayID?)?
    private var timer: Timer?
    private var subscriptions: Set<AnyCancellable> = []

    private var policy: UpdatePolicy?
    private var policyFetchedAt: Date?
    private var fetchingPolicy = false
    private static let policyTTL: TimeInterval = 3600
    private static let tickInterval: TimeInterval = 60
    /// The user counts as present when the last keyboard or mouse event is
    /// newer than this.
    private static let presenceWindow: TimeInterval = 30

    private let updater = UpdaterService.shared

    func start(model: NotchModel, pickDisplay: @escaping () -> CGDirectDisplayID?) {
        self.model = model
        self.pickDisplay = pickDisplay
        // The panel opening takes the notch over; the chip inside it carries
        // the update from there.
        model.$open
            .filter { $0 }
            .sink { [weak self] _ in self?.hide() }
            .store(in: &subscriptions)
        // A failed install falls back to the chip, which shows the failure.
        updater.$phase
            .filter { $0 == .failed }
            .sink { [weak self] _ in self?.hide() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .updateWillRelaunch)
            .sink { [weak self] _ in self?.hide() }
            .store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { _ in
            Task { @MainActor in UpdatePrompt.shared.tick() }
        }
        tick()
    }

    func dismiss() { hide() }

    func restart() {
        guard showing != nil else { return }
        updater.update()
    }

    private func hide() {
        guard showing != nil else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { showing = nil }
    }

    private func tick() {
        guard showing == nil, let model else { return }
        refreshPolicyIfDue()
        let current = UpdaterService.currentVersion
        guard let rule = policy?.rule(for: current) else { return }
        // A named version checks for releases hourly instead of daily.
        updater.check(ifOlderThan: 3600)
        guard case .available(let version) = updater.phase else { return }
        guard updater.hasPrefetched(version) else {
            updater.prefetch()
            return
        }

        let defaults = UserDefaults.standard
        let countKey = "updatePrompt.shown.\(version)"
        let lastKey = "updatePrompt.lastShown.\(version)"
        guard defaults.integer(forKey: countKey) < rule.maxShows else { return }
        if let last = defaults.object(forKey: lastKey) as? Date,
           Date().timeIntervalSince(last) < rule.interval { return }

        guard Self.userIsPresent,
              !model.open,
              model.roundsInFlight == 0,
              !AgentTaskManager.shared.isRunning,
              !OnboardingService.shared.showIntro,
              let display = pickDisplay?()
        else { return }

        defaults.set(defaults.integer(forKey: countKey) + 1, forKey: countKey)
        defaults.set(Date(), forKey: lastKey)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            showing = Showing(display: display, version: version, message: rule.message)
        }
    }

    private func refreshPolicyIfDue() {
        if let at = policyFetchedAt, Date().timeIntervalSince(at) < Self.policyTTL { return }
        guard !fetchingPolicy else { return }
        fetchingPolicy = true
        Task {
            let fetched = await UpdatePolicy.fetch()
            fetchingPolicy = false
            policyFetchedAt = Date()
            // Offline keeps the last good copy.
            if let fetched { policy = fetched }
        }
    }

    private static var userIsPresent: Bool {
        guard let any = CGEventType(rawValue: ~0) else { return false }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
            < presenceWindow
    }

    #if DEBUG
    /// Screenshot aid (`NOTCH_DEMO_UPDATE_PROMPT=<version>`): show the card on
    /// `display` now, skipping every condition.
    func _debugShow(on display: CGDirectDisplayID, version: String) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            showing = Showing(display: display, version: version, message: nil)
        }
    }
    #endif
}

// MARK: - Card

/// The update card the resting notch unfolds into. Drawn inside `NotchIsland`,
/// below the notch zone, on the island's own glass.
struct UpdatePromptCard: View {
    let showing: UpdatePrompt.Showing
    @ObservedObject private var updater = UpdaterService.shared
    @ObservedObject private var prompt = UpdatePrompt.shared
    @State private var restartHovered = false
    @State private var closeHovered = false

    static let width: CGFloat = 400

    private var restarting: Bool { updater.phase == .updating }

    var body: some View {
        VStack(spacing: 0) {
            Text(L("updatePrompt.title"))
                .font(.sf(15))
                .foregroundStyle(Tokens.text1)
            Text(showing.message ?? L("updatePrompt.body"))
                .font(.sf(Tokens.TypeSize.form))
                .foregroundStyle(Tokens.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            restartButton
                .padding(.top, 16)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(width: Self.width)
        .overlay(alignment: .topTrailing) { closeButton }
    }

    private var restartButton: some View {
        Button { prompt.restart() } label: {
            HStack(spacing: 6) {
                if restarting {
                    ProgressView()
                        .controlSize(.small)
                        .environment(\.colorScheme, .light)
                }
                Text(L(restarting ? "updatePrompt.restarting" : "updatePrompt.restart"))
                    .font(.sf(Tokens.TypeSize.form, weight: .semibold))
            }
            .foregroundStyle(Color.black)
            .padding(.horizontal, 20)
            .frame(minWidth: 112)
            .frame(height: 32)
            .background(Capsule().fill(Color.white.opacity(restartHovered && !restarting ? 0.9 : 1)))
            .shadow(color: .white.opacity(0.14), radius: 5, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .allowsHitTesting(!restarting)
        .onHover { restartHovered = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: restartHovered)
        .animation(.easeOut(duration: Tokens.hoverFade), value: restarting)
    }

    private var closeButton: some View {
        Button { prompt.dismiss() } label: {
            Image(systemName: "xmark")
                .font(.sf(Tokens.TypeSize.caption, weight: .semibold))
                .foregroundStyle(closeHovered ? Tokens.text1 : Tokens.text4)
                .frame(width: Tokens.Control.inline, height: Tokens.Control.inline)
                .background(Circle().fill(Color.white.opacity(closeHovered ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .help(L("updatePrompt.dismiss"))
        .opacity(restarting ? 0 : 1)
        .allowsHitTesting(!restarting)
        .onHover { closeHovered = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: closeHovered)
        .padding(.top, 2)
        .padding(.trailing, 12)
    }
}
