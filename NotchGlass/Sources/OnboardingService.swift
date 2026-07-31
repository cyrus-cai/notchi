import AppKit
import SwiftUI

/// First-run state for the very first time someone launches Notch.
///
/// There is exactly one first-run beat, and it isn't a tour: the screen goes
/// black, the mark appears as a real 3D object, turns once and flies into the
/// notch, and the panel opens on the chat prompt (see `IntroAnimation`). No
/// steps, no cards, no "connect a model" wizard — the app introduces itself by
/// showing you where it lives, then gets out of the way.
///
/// The "once, ever" behaviour mirrors `WhatsNewService`: a `UserDefaults` flag,
/// resolved at launch, flipped once the intro has played. First-run and What's
/// New stay independent (cold install vs. update) but cooperate at one seam: a
/// brand-new install must not stack the What's New panel on top of the intro (see
/// `WhatsNewService`'s "first-ever launch stays quiet" rule, which already
/// suppresses it).
@MainActor
final class OnboardingService: ObservableObject {
    static let shared = OnboardingService()

    /// Whether the intro animation should play at launch. Cleared the moment it
    /// has run (or been skipped) — it never leads twice.
    @Published private(set) var showIntro: Bool

    /// The key recording that the intro has played.
    private let introDoneKey = "onboarding_intro_done"

    /// The keys the previous (guided, multi-step) first run wrote. Either one
    /// means this Mac has already used Notch, so an update must not greet a
    /// long-time user with a first-launch animation.
    private let legacyOpenedKey = "onboarding_opened_once"
    private let legacyGuideKey = "onboarding_guide_done"

    /// Debug switch: when on, the intro plays at every launch and never records
    /// "done", so it can be inspected any number of times. Off by default. Flip it
    /// without a rebuild via either:
    ///   · `defaults write com.notchglass.app onboarding_always_show -bool YES`
    ///   · launching with the `NOTCH_ONBOARDING_ALWAYS=1` environment variable
    /// (Set the default back to NO / unset the env var to restore normal
    /// once-ever behaviour.)
    static let alwaysShowKey = "onboarding_always_show"
    static var alwaysShow: Bool {
        if let env = ProcessInfo.processInfo.environment["NOTCH_ONBOARDING_ALWAYS"],
           env == "1" || env.lowercased() == "true" {
            return true
        }
        return UserDefaults.standard.bool(forKey: alwaysShowKey)
    }

    private init() {
        let defaults = UserDefaults.standard
        let alreadyRun = defaults.bool(forKey: introDoneKey)
            || defaults.bool(forKey: legacyOpenedKey)
            || defaults.bool(forKey: legacyGuideKey)
        showIntro = Self.alwaysShow || !alreadyRun
    }

    /// Record that the intro has played (or been skipped), so it never leads
    /// again. With the debug switch on it still clears the flag for THIS run, but
    /// doesn't write it down — the next launch plays it again.
    func markIntroDone() {
        showIntro = false
        guard !Self.alwaysShow else { return }
        UserDefaults.standard.set(true, forKey: introDoneKey)
    }
}
