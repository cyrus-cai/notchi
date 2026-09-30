import Foundation

// MARK: - Features

/// The switches a nudge may offer to turn on. A policy entry names one of these
/// by raw value; an entry naming anything else is dropped, so an older build
/// skips a feature it does not have. `NotchModel` holds what each one needs and
/// how it is switched on.
enum NudgeFeature: String, CaseIterable {
    case emojiReactions
    case linkPrecheck
}

// MARK: - Policy

/// Which features the app invites the user to turn on, read from
/// `https://notch.website/nudges.json` so it can change without a release.
///
///     { "min_gap_hours": 48, "grace_hours": 24,
///       "nudges": [
///         { "id": "link-precheck-1", "feature": "linkPrecheck", "priority": 10,
///           "min_version": "0.9.3", "requires": ["gift"],
///           "interval_hours": 72, "max_shows": 2, "reaction": "👌",
///           "text": { "en": { "invite": "…", "confirm": "Turn on", "title": "…",
///                             "messages": ["…", "…", "…"] } } } ] }
///
/// `text` is keyed by language (`en`, `zh-Hans`, `zh-Hant`, `ja`, `ko`, `fr`,
/// `es`) and falls back to `en`. `invite` is the message shown with the
/// confirm button; `messages` are the bubbles written into the thread once it
/// is pressed.
///
/// An entry that does not decode is dropped alone. Every fetch failure
/// (offline, 404, malformed JSON) reads as "no nudges".
struct NudgePolicy: Decodable {
    struct Copy: Decodable {
        let invite: String
        let confirm: String
        let title: String?
        let messages: [String]
    }

    struct Nudge: Decodable {
        let id: String
        let feature: String
        let priority: Int?
        let min_version: String?
        let max_version: String?
        /// Conditions besides the feature's own: `gift`, `unifiedThreads`. An
        /// unknown one is never met.
        let requires: [String]?
        let interval_hours: Double?
        let max_shows: Int?
        /// The emoji put on the confirm line in the thread.
        let reaction: String?
        let text: [String: Copy]

        var interval: TimeInterval { (interval_hours ?? 72) * 3600 }
        var maxShows: Int { max_shows ?? 2 }

        @MainActor func matches(_ version: String) -> Bool {
            if let min_version, UpdaterService.isNewer(min_version, than: version) { return false }
            if let max_version, UpdaterService.isNewer(version, than: max_version) { return false }
            return true
        }
    }

    /// The least time between any two nudges.
    let minGap: TimeInterval
    /// The time after a first launch or an update in which none is shown.
    let grace: TimeInterval
    let nudges: [Nudge]

    private enum CodingKeys: String, CodingKey { case min_gap_hours, grace_hours, nudges }

    private struct Lossy: Decodable {
        let nudge: Nudge?
        init(from decoder: Decoder) { nudge = try? Nudge(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minGap = ((try? c.decode(Double.self, forKey: .min_gap_hours)) ?? 48) * 3600
        grace = ((try? c.decode(Double.self, forKey: .grace_hours)) ?? 24) * 3600
        nudges = try c.decode([Lossy].self, forKey: .nudges).compactMap(\.nudge)
    }
}

// MARK: - Scheduler

/// Holds the policy and decides which nudge is due. At most one nudge per
/// `min_gap_hours`; each entry at most `max_shows` times, `interval_hours`
/// apart; the highest `priority` first, file order among equals. A feature the
/// user declined, with the invitation's × or by switching it off, is never
/// offered again under any entry.
@MainActor
final class FeatureNudges {
    static let shared = FeatureNudges()

    struct Pick {
        let nudge: NudgePolicy.Nudge
        let feature: NudgeFeature
        let copy: NudgePolicy.Copy
    }

    private var policy: NudgePolicy?
    private var fetchedAt: Date?
    private var fetching = false
    private static let ttl: TimeInterval = 3600
    private static let url = URL(string: "https://notch.website/nudges.json")!

    private static let lastAnyKey = "nudge.lastShownAt"
    private static let versionKey = "nudge.version"
    private static let versionSinceKey = "nudge.versionSince"
    /// Set by the emoji reactions guide that shipped before nudges. It counts
    /// as one show of that feature.
    private static let legacyReactionsKey = "emojiReactionsIntroShown"

    /// `NOTCH_DEMO_NUDGE=<path to a policy file>` reads the policy from disk
    /// and shows its first entry on every launch, skipping every condition.
    let forced: Bool

    private init() {
        if let path = ProcessInfo.processInfo.environment["NOTCH_DEMO_NUDGE"], !path.isEmpty {
            forced = true
            policy = (try? Data(contentsOf: URL(fileURLWithPath: path)))
                .flatMap { try? JSONDecoder().decode(NudgePolicy.self, from: $0) }
        } else {
            forced = false
        }
    }

    func refreshIfDue() async {
        guard !forced, !fetching else { return }
        if let at = fetchedAt, Date().timeIntervalSince(at) < Self.ttl { return }
        fetching = true
        var req = URLRequest(url: Self.url)
        req.timeoutInterval = 10
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let result = try? await ProxyConfig.urlSession.data(for: req)
        fetching = false
        fetchedAt = Date()
        // Offline keeps the last good copy.
        guard let result, (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let fetched = try? JSONDecoder().decode(NudgePolicy.self, from: result.0)
        else { return }
        policy = fetched
    }

    /// The nudge to show now, or nil. `usable` says whether a feature is off
    /// and its conditions are met.
    func pick(usable: (NudgeFeature, [String]) -> Bool) -> Pick? {
        guard let policy else { return nil }
        let defaults = UserDefaults.standard
        let now = Date()
        let version = UpdaterService.currentVersion

        if !forced {
            if defaults.string(forKey: Self.versionKey) != version {
                defaults.set(version, forKey: Self.versionKey)
                defaults.set(now, forKey: Self.versionSinceKey)
            }
            if let since = defaults.object(forKey: Self.versionSinceKey) as? Date,
               now.timeIntervalSince(since) < policy.grace { return nil }
            if let last = defaults.object(forKey: Self.lastAnyKey) as? Date,
               now.timeIntervalSince(last) < policy.minGap { return nil }
        }

        let due = policy.nudges.compactMap { nudge -> Pick? in
            guard let feature = NudgeFeature(rawValue: nudge.feature),
                  let copy = nudge.text[Self.languageKey] ?? nudge.text["en"],
                  !copy.messages.isEmpty
            else { return nil }
            if !forced {
                guard nudge.matches(version),
                      !isDeclined(feature),
                      usable(feature, nudge.requires ?? []),
                      shows(of: nudge, feature: feature) < nudge.maxShows
                else { return nil }
                if let last = defaults.object(forKey: "nudge.lastShown.\(nudge.id)") as? Date,
                   now.timeIntervalSince(last) < nudge.interval { return nil }
            }
            return Pick(nudge: nudge, feature: feature, copy: copy)
        }
        // `max(by:)` returns the last of equals; reversed, that is the first in the file.
        return due.reversed().max { ($0.nudge.priority ?? 0) < ($1.nudge.priority ?? 0) }
    }

    func noteShown(_ nudge: NudgePolicy.Nudge) {
        guard !forced else { return }
        let defaults = UserDefaults.standard
        let countKey = "nudge.shown.\(nudge.id)"
        defaults.set(defaults.integer(forKey: countKey) + 1, forKey: countKey)
        defaults.set(Date(), forKey: "nudge.lastShown.\(nudge.id)")
        defaults.set(Date(), forKey: Self.lastAnyKey)
    }

    /// The invitation's ×.
    func decline(_ feature: NudgeFeature) {
        guard !forced else { return }
        UserDefaults.standard.set(true, forKey: "nudge.declined.\(feature.rawValue)")
    }

    /// Declined with ×, or switched off by hand: the switch's key is written
    /// only when the switch changes, so a stored `false` means it was on once.
    private func isDeclined(_ feature: NudgeFeature) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "nudge.declined.\(feature.rawValue)") { return true }
        return defaults.object(forKey: Self.switchKey(feature)) as? Bool == false
    }

    private func shows(of nudge: NudgePolicy.Nudge, feature: NudgeFeature) -> Int {
        let defaults = UserDefaults.standard
        let legacy = feature == .emojiReactions && defaults.bool(forKey: Self.legacyReactionsKey)
        return defaults.integer(forKey: "nudge.shown.\(nudge.id)") + (legacy ? 1 : 0)
    }

    private static func switchKey(_ feature: NudgeFeature) -> String {
        switch feature {
        case .emojiReactions: return "emojiReactionsEnabled"
        case .linkPrecheck: return LinkGate.defaultsKey
        }
    }

    private static var languageKey: String {
        switch Localization.shared.language.resolved {
        case .en: return "en"
        case .zhHans: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        case .ja: return "ja"
        case .ko: return "ko"
        case .fr: return "fr"
        case .es: return "es"
        }
    }
}
