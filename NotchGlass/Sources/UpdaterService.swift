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

    static let repo = "cyrus-cai/notch"
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

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
        guard !checking, phase != .updating else { return }
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
            let release = try? await Self.fetchLatest()
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
    /// and the Version row shows the releases-page fallback.
    func update() {
        guard case .available = phase else { return }
        phase = .updating
        Task {
            do {
                let release = try await Self.fetchLatest()
                guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
                      // Private repos only serve assets through the API URL
                      // (with the token); the browser URL is the public path.
                      let url = URL(string: Self.token != nil ? asset.url : asset.browser_download_url)
                else { throw UpdateError.badResponse }

                let (tmp, resp) = try await URLSession.shared.download(
                    for: Self.request(url, accept: "application/octet-stream"))
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    throw UpdateError.badResponse
                }
                // URLSession's temp file may be reclaimed once this scope moves
                // on — park the zip somewhere stable before the detached work.
                let zip = tmp.deletingLastPathComponent()
                    .appendingPathComponent("notch-update-\(ProcessInfo.processInfo.globallyUniqueString).zip")
                try FileManager.default.moveItem(at: tmp, to: zip)

                let dest = Bundle.main.bundleURL
                try await Task.detached(priority: .userInitiated) {
                    try Self.swapBundle(zip: zip, dest: dest)
                }.value
                Self.relaunch(dest)
            } catch {
                phase = .failed
            }
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
        let (data, resp) = try await URLSession.shared.data(
            for: request(url, accept: "application/vnd.github+json"))
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
        let name = "Notch.app"
        let direct = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: direct.path) { return direct }
        let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for kid in kids {
            if kid.lastPathComponent == name { return kid }
            let nested = kid.appendingPathComponent(name)
            if fm.fileExists(atPath: nested.path) { return nested }
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
