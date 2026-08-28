import AppKit
import SwiftUI

/// In-app self-updater — `install.sh`'s flow, in-process. Checks GitHub for a
/// newer release tag, downloads the zip asset, swaps the installed bundle, and
/// relaunches. Same trust model as the curl installer (HTTPS to github.com, no
/// extra signing), so updating in-app is exactly as safe as installing was.
///
/// Quietness is the contract: checks are silent and failures are swallowed —
/// the only signals are the dot on the settings gear and the Version row in
/// settings. An update cue must never interrupt hover-ask-leave.
///
/// Note: URLSession downloads carry no quarantine flag (the app doesn't opt
/// into `LSFileQuarantineEnabled`), so unlike the curl path no `xattr` step is
/// strictly needed — one is run on the staged bundle anyway as belt-and-braces.
@MainActor
final class UpdaterService: ObservableObject {
    static let shared = UpdaterService()

    /// Where the update story currently is — drives the Version row and the gear dot.
    enum Phase: Equatable {
        case unknown            // never checked (or check failed): show just the version
        case upToDate           // checked; this build is the latest
        case available(String)  // a newer version (e.g. "1.0.2") is published
        case updating           // download/swap in flight
        case failed             // an attempted update failed; offer the releases page
    }

    @Published private(set) var phase: Phase = .unknown

    /// How far a running update has got — what the chip's fill draws.
    /// `.downloading` carries the byte fraction (0…1) reported by the transfer;
    /// `.installing` covers the extract-and-swap that follows, which has no
    /// measurable progress but is short. Only meaningful while `phase == .updating`.
    enum Stage: Equatable {
        case downloading(Double)
        case installing
    }

    @Published private(set) var stage: Stage = .downloading(0)

    /// A user-initiated "Check for updates" in flight, and its momentary result.
    /// Separate from `phase` so the manual button can show a spinner and a brief
    /// "up to date" confirmation without touching the silent auto-check contract
    /// (which stays quiet — no "up to date" chrome unless the user asked).
    enum ManualCheck: Equatable {
        case idle       // no manual check happening; show the plain "Check for updates" link
        case checking   // request in flight — show a spinner
        case upToDate   // just confirmed current — show a fading "You're up to date"
    }

    @Published private(set) var manualCheck: ManualCheck = .idle

    static let repo = "cyrus-cai/notchi"
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }
    /// The canonical, complete release-note history on the Notchi website.
    static let releaseNotesPage = URL(string: "https://www.notch.website/releases")!

    /// The running app's marketing version. CI stamps the release tag into
    /// Info.plist via `MARKETING_VERSION`; local builds carry the pbxproj value.
    /// `NOTCH_FAKE_VERSION` overrides it — debug aid for exercising the update
    /// flow against a real release without building an older binary.
    static var currentVersion: String {
        if let fake = ProcessInfo.processInfo.environment["NOTCH_FAKE_VERSION"], !fake.isEmpty {
            return fake
        }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Optional GitHub token (`NOTCH_GITHUB_TOKEN` / `GITHUB_TOKEN`). Unauthenticated
    /// works once the repo is public; the token makes check + download work against
    /// the private repo (asset downloads there must go through the API URL).
    private static var token: String? {
        let env = ProcessInfo.processInfo.environment
        return env["NOTCH_GITHUB_TOKEN"] ?? env["GITHUB_TOKEN"]
    }

    private enum UpdateError: Error {
        case badResponse, badArchive, toolFailed
        /// The new bundle failed to copy in AND restoring the old one failed —
        /// `/Applications/Notch.app` is gone. Carries both the original swap
        /// failure and the rollback failure so neither is silently dropped.
        case rollbackFailed(swap: Error, rollback: Error)
    }

    // MARK: - Check

    private let lastCheckKey = "updater_last_check"
    private var checking = false
    /// A release lookup is tiny and should finish quickly. Without an explicit
    /// bound, `URLSession` can leave the manual spinner up for its much longer
    /// default timeout when GitHub or a configured proxy is unreachable.
    private static let checkTimeout: TimeInterval = 10

    /// Silent daily check — called at launch and whenever the panel opens, so a
    /// long-running agent still notices releases. Throttled to once per 24h.
    func checkIfDue() {
        if let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 3600 {
            return
        }
        check()
    }

    /// Un-throttled check — run when settings opens, so the Version row reflects
    /// reality while the user is actually looking at it. One HEAD-sized request;
    /// failures leave the phase untouched (the cue is strictly nice-to-have).
    func check() {
        guard !checking, !demoPinned, phase != .updating else { return }
        checking = true
        Task {
            defer { checking = false }
            guard let release = try? await Self.fetchLatest() else { return }
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            // A check landing mid-update must not flip the phase under the swap.
            guard phase != .updating else { return }
            let latest = release.version
            phase = Self.isNewer(latest, than: Self.currentVersion)
                ? .available(latest)
                : .upToDate
        }
    }

    /// User-initiated check — the "Check for updates" button. Same request as
    /// `check()`, but surfaces feedback the silent path deliberately hides: a
    /// spinner while it runs, and a momentary "up to date" when this is already
    /// the latest. If a newer version turns up, `phase` flips to `.available` and
    /// the normal Update button takes over (no separate confirmation needed).
    func checkManually() {
        guard manualCheck != .checking, phase != .updating else { return }
        manualCheck = .checking
        Task {
            // Keep the spinner up for a beat even on a cached/instant response,
            // so the check reads as an action that happened rather than a flash.
            async let minDwell: () = Self.sleep(nanoseconds: 650_000_000)
            let release = try? await Self.fetchLatest()
            await minDwell
            // A real update superseding the check mid-flight wins.
            guard phase != .updating else { manualCheck = .idle; return }
            guard let release else {
                // Network/API failure: no confirmation to show, just stop the
                // spinner. Failures stay quiet, same as the silent path.
                manualCheck = .idle
                return
            }
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            let latest = release.version
            if Self.isNewer(latest, than: Self.currentVersion) {
                phase = .available(latest)
                manualCheck = .idle       // the Update button now carries the signal
            } else {
                phase = .upToDate
                manualCheck = .upToDate    // the UI clears this back to .idle after a beat
            }
        }
    }

    /// Dismiss the momentary "up to date" confirmation, returning the button to
    /// its resting "Check for updates" label. The view schedules this after a
    /// short delay so the reassurance shows, then quietly recedes.
    func clearManualConfirmation() {
        if manualCheck == .upToDate { manualCheck = .idle }
    }

    /// Non-throwing sleep — swallows the cancellation error so callers can
    /// `await` it as plain `Void` (used to floor the manual-check spinner time).
    private static func sleep(nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    #if DEBUG
    /// Screenshot aid (`NOTCH_DEMO_UPDATE=<version>`): pin the phase to "a build
    /// is waiting" without a real release to find. The pin also mutes the real
    /// checks, which would otherwise flip the phase back to `.upToDate` a second
    /// or two later, mid-pose. Debug builds only — see `AppDelegate`.
    func _debugPinAvailable(_ version: String) {
        demoPinned = true
        phase = .available(version)
    }
    private var demoPinned = false

    /// Sim hook (`NOTCH_DEMO_UPDATE_FLOW=<version>`): pin a waiting build and, when
    /// the chip is actually tapped, play the whole update story — the download
    /// filling, the install, and the ending — with no real release to fetch and
    /// nothing on disk touched. So the flow can be *clicked* through rather than
    /// only posed.
    ///
    /// It plays the SUCCESS ending by default: the real quit-and-relaunch, which
    /// is the one part of the flow that can't be faked convincingly by holding a
    /// phase. `NOTCH_DEMO_UPDATE_FAIL=1` plays the failure ending instead, which
    /// loops back to the waiting build a few seconds later so the next tap
    /// replays it. Debug builds only.
    /// `NOTCH_DEMO_UPDATE_AUTO=1` also presses the chip itself after a beat, so
    /// the whole run can be recorded without driving the pointer.
    func _debugRunFlow(_ version: String, failing: Bool, auto: Bool = false) {
        demoPinned = true
        demoSim = version
        demoSimFails = failing
        phase = .available(version)
        guard auto else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            update()
        }
    }

    private var demoSimFails = false

    /// Non-nil while the sim hook is armed — makes `update()` play the timeline
    /// instead of downloading and swapping anything.
    private var demoSim: String?

    private func runSimulatedUpdate(_ version: String) {
        stage = .downloading(0)
        phase = .updating
        Task { @MainActor in
            // ~7s of download, long enough for the fill to read as a fill.
            for i in 1...70 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                stage = .downloading(Double(i) / 70)
            }
            stage = .installing
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard demoSimFails else {
                // The real ending, not a mimed one — the app quits and reopens.
                await finishAndRelaunch(Bundle.main.bundleURL)
                return
            }
            phase = .failed
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            phase = .available(version)
        }
    }
    #else
    private let demoPinned = false
    #endif

    /// Numeric dot-component comparison: "1.0.10" beats "1.0.9", "1.1" beats "1.0.2".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Update

    /// Download the latest release and swap it in. Runs the file work off the
    /// main actor; on success the app relaunches itself (this call never returns
    /// to a UI that needs cleaning up), on failure the old bundle is rolled back
    /// and the chip offers a retry.
    func update() {
        guard case .available(let version) = phase else { return }
        attemptedVersion = version
        #if DEBUG
        if let version = demoSim { runSimulatedUpdate(version); return }
        #endif
        stage = .downloading(0)
        phase = .updating
        Task {
            do {
                let release = try await Self.fetchLatest()
                guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
                      // Private repos only serve assets through the API URL
                      // (with the token); the browser URL is the public path.
                      let url = URL(string: Self.token != nil ? asset.url : asset.browser_download_url)
                else { throw UpdateError.badResponse }

                // The zip is tens of megabytes on an ordinary connection — long
                // enough that an unmarked wait reads as nothing happening. The
                // download reports its byte count back so the chip can fill as it
                // arrives, and hands back a zip already parked at a stable path.
                let (zip, resp) = try await Downloader.run(
                    Self.request(url, accept: "application/octet-stream")
                ) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.phase == .updating,
                              case .downloading = self.stage else { return }
                        self.stage = .downloading(fraction)
                    }
                }
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    try? FileManager.default.removeItem(at: zip)
                    throw UpdateError.badResponse
                }
                stage = .installing
                let dest = Bundle.main.bundleURL
                try await Task.detached(priority: .userInitiated) {
                    try Self.swapBundle(zip: zip, dest: dest)
                }.value
                await finishAndRelaunch(dest)
            } catch {
                phase = .failed
            }
        }
    }

    /// The updater's download, run as a classic `URLSessionDownloadTask` on a
    /// session this object owns.
    ///
    /// Not `URLSession.download(for:delegate:)`: a *per-task* delegate handed to
    /// that async call never receives `didWriteData`, so the progress the chip
    /// draws would stay at zero for the whole transfer (verified — zero callbacks
    /// against the real release asset). Owning the session is what makes the
    /// progress callbacks arrive.
    ///
    /// The finished file is moved to a stable path inside the delegate callback,
    /// because URLSession deletes it the moment that callback returns.
    private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let onFraction: @Sendable (Double) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(URL, URLResponse), Error>?

        private init(onFraction: @escaping @Sendable (Double) -> Void) {
            self.onFraction = onFraction
        }

        /// Downloads `request`, reporting 0…1 as the bytes land. Returns the zip
        /// at a path the caller owns (and must clean up) plus the response.
        static func run(_ request: URLRequest,
                        onFraction: @escaping @Sendable (Double) -> Void)
        async throws -> (URL, URLResponse) {
            let downloader = Downloader(onFraction: onFraction)
            let session = ProxyConfig.session(delegate: downloader)
            defer { session.finishTasksAndInvalidate() }
            return try await withCheckedThrowingContinuation { continuation in
                downloader.lock.lock()
                downloader.continuation = continuation
                downloader.lock.unlock()
                session.downloadTask(with: request).resume()
            }
        }

        /// Resume the continuation exactly once — both the finish and the
        /// completion callback fire, in either order, on a failed transfer.
        private func settle(_ result: Result<(URL, URLResponse), Error>) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            // A server that doesn't send a length reports -1; leave the chip on
            // its last known fill rather than jumping around.
            guard totalBytesExpectedToWrite > 0 else { return }
            onFraction(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            let parked = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("notch-update-\(ProcessInfo.processInfo.globallyUniqueString).zip")
            do {
                try FileManager.default.moveItem(at: location, to: parked)
                settle(.success((parked, downloadTask.response ?? URLResponse())))
            } catch {
                settle(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            guard let error else { return }   // success already settled above
            settle(.failure(error))
        }
    }

    /// The version the running attempt is for. Kept so a failure can be tried
    /// again in place — the failed chip retries rather than sending the user out
    /// to a web page.
    private var attemptedVersion: String?

    /// Try the same update again after a failure. Falls back to a fresh check if
    /// we've somehow lost which version it was.
    func retry() {
        guard phase == .failed else { return }
        if let version = attemptedVersion {
            phase = .available(version)
            update()
        } else {
            check()
        }
    }

    // MARK: - GitHub API

    private struct Release: Decodable {
        let tag_name: String
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let url: String                    // API asset URL (token path)
            let browser_download_url: String   // public download URL
        }
        /// The tag with its `v` prefix dropped — the comparable version string.
        var version: String {
            tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name
        }
    }

    private static func request(_ url: URL, accept: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(accept, forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private static func fetchLatest() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var req = request(url, accept: "application/vnd.github+json")
        req.timeoutInterval = checkTimeout
        let (data, resp) = try await ProxyConfig.urlSession.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.badResponse
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    // MARK: - Swap & relaunch

    /// Extract the zip and swap the installed bundle — the running app replaces
    /// itself, which macOS is fine with (the executing binary is already mapped).
    /// The old bundle is moved aside first and restored if the copy fails, so a
    /// botched download can never leave the user appless.
    private nonisolated static func swapBundle(zip: URL, dest: URL) throws {
        let fm = FileManager.default
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notch-update-\(ProcessInfo.processInfo.globallyUniqueString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: zip) }

        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        try runTool("/usr/bin/ditto", "-x", "-k", zip.path, extracted.path)
        guard let staged = findApp(in: extracted, fm: fm) else { throw UpdateError.badArchive }
        // Defensive only — see the class comment on quarantine.
        try? runTool("/usr/bin/xattr", "-dr", "com.apple.quarantine", staged.path)

        let backup = work.appendingPathComponent("previous.app")
        try fm.moveItem(at: dest, to: backup)
        do {
            try runTool("/usr/bin/ditto", staged.path, dest.path)
        } catch let swap {
            // Restore the old bundle. If rollback itself fails the app is gone,
            // so surface that distinctly instead of swallowing it — the caller
            // must know the install location is now empty.
            do {
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.moveItem(at: backup, to: dest)
            } catch let rollback {
                throw UpdateError.rollbackFailed(swap: swap, rollback: rollback)
            }
            throw swap
        }
    }

    /// The app bundle inside the extracted archive — at the root (CI zips with
    /// `--keepParent`) or one folder down, same tolerance as `install.sh`.
    private nonisolated static func findApp(in dir: URL, fm: FileManager) -> URL? {
        // Current name first, then pre-rename bundle names, so an update keeps
        // working across the Notch → Notchi rename — same tolerance as `install.sh`.
        let names = ["Notchi.app", "Notch.app", "NotchGlass.app"]
        for name in names {
            let direct = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: direct.path) { return direct }
        }
        let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for kid in kids {
            if names.contains(kid.lastPathComponent) { return kid }
            for name in names {
                let nested = kid.appendingPathComponent(name)
                if fm.fileExists(atPath: nested.path) { return nested }
            }
        }
        return nil
    }

    private nonisolated static func runTool(_ path: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.toolFailed }
    }

    /// Fold the panel, let that motion land, then quit and reopen. The pause is
    /// the whole point: terminating straight out of "Installing…" reads as a
    /// crash, while an island that closes first makes the relaunch look like the
    /// end of the action it was.
    private func finishAndRelaunch(_ bundle: URL) async {
        NotificationCenter.default.post(name: .updateWillRelaunch, object: nil)
        try? await Task.sleep(nanoseconds: 420_000_000)
        Self.relaunch(bundle)
    }

    /// Spawn a detached `open` for the (new) bundle and quit. The half-second
    /// sleep lets this process fully exit so `open` launches the fresh binary
    /// rather than focusing the dying one.
    private static func relaunch(_ bundle: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(bundle.path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}
