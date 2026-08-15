import Foundation

/// The odometer behind Settings → Stats' **Tokens** figure.
///
/// One rule, and everything else follows from it: **this counts only what a
/// provider actually reported.** No estimate from character counts, no "about
/// four characters to a token" — a request whose response carries a `usage`
/// block adds its numbers here, and a request that reports nothing adds nothing.
/// A figure the user can't verify is worth having only if it's the real one.
///
/// The consequence is that the meter starts at zero on the version that
/// introduced it: nothing on disk from before then recorded a `usage` block, and
/// inventing one retroactively is exactly the estimate this refuses to make. The
/// tile's ⓘ says so, naming the version and the day counting began.
///
/// Unlike the rest of the pane, this is *not* derived from the archive — it's a
/// running total in `UserDefaults`, because the tokens a request spent are not a
/// property of the row it left behind (a title generation leaves no row; a
/// resumed agent run leaves one row for many calls). It only ever moves forward,
/// including across a Clear: the archive's Clear removes *rows*, and the tokens
/// those requests actually cost were still spent. An odometer, not a tally of
/// what's currently on disk.
final class TokenMeter: @unchecked Sendable {
    static let shared = TokenMeter()

    /// What the pane needs to draw the tile and write its note.
    struct Reading: Equatable {
        var total: Int
        /// When the first token was counted, and the app version it was counted
        /// on — the "counting started here" the ⓘ names. `nil` until the first
        /// request reports usage.
        var since: Date?
        var sinceVersion: String?
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var total: Int
    private var since: Date?
    private var sinceVersion: String?

    private enum Key {
        static let total = "stats.tokens.total"
        static let since = "stats.tokens.since"
        static let sinceVersion = "stats.tokens.sinceVersion"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        total = defaults.integer(forKey: Key.total)
        since = defaults.object(forKey: Key.since) as? Date
        sinceVersion = defaults.string(forKey: Key.sinceVersion)
    }

    /// Add one request's reported usage.
    ///
    /// `input` is everything the model read — prompt plus, on providers that
    /// bill them separately, cache reads and cache writes; the caller folds
    /// those in, because only it knows its provider's spelling. Both sides are
    /// summed into one figure: the tile says "tokens", and a user asking how
    /// much they've run through the notch means the whole exchange, not one
    /// direction of it.
    ///
    /// Safe to call from any thread — every provider reports from whatever queue
    /// its stream is being parsed on.
    func record(input: Int, output: Int) {
        let sum = max(0, input) + max(0, output)
        guard sum > 0 else { return }
        lock.lock()
        total += sum
        let stampNeeded = since == nil
        if stampNeeded {
            since = Date()
            sinceVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        }
        let (newTotal, stamp, version) = (total, since, sinceVersion)
        lock.unlock()

        defaults.set(newTotal, forKey: Key.total)
        if stampNeeded {
            defaults.set(stamp, forKey: Key.since)
            defaults.set(version, forKey: Key.sinceVersion)
        }
    }

    var reading: Reading {
        lock.lock(); defer { lock.unlock() }
        return Reading(total: total, since: since, sinceVersion: sinceVersion)
    }
}
