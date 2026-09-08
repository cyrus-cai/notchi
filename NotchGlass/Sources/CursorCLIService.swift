import Foundation
import AppKit

/// A model backend that shells out to the user's locally-installed **Cursor CLI**
/// (`cursor-agent -p --output-format stream-json`) and streams its answer back —
/// the sixth of the same family as `CodexCLIService` / `ClaudeCLIService` /
/// `GrokCLIService` / `CommandCodeCLIService` / `PiCLIService`.
///
/// Like the others, Cursor carries **no API key of ours**: it reuses the sign-in
/// the user already did (`cursor-agent login` → browser OAuth, credentials in the
/// system Keychain), or the `CURSOR_API_KEY` env var if they set one. Usage bills
/// against their own Cursor plan — the whole point of a "use the CLI I already pay
/// for" backend.
///
/// Like Command Code and pi it is an **aggregator**: one account fronts models
/// from several labs (`gpt-5.x`, `claude-*`, `gemini-*`, `glm-*`, `kimi-*`)
/// alongside Cursor's own line — the `auto` router, `composer-*`, and the
/// `cursor-…` models it tunes and serves under its own name. So the ids name their
/// own vendor and `Provider.cursorCode.vendorName` is nil; `vendor(forID:)` covers
/// the two shapes that don't.
///
/// **Compliance posture (mirrors the other CLI backends):** only the official
/// binary is ever executed. Notch speaks no HTTP to Cursor, never reads the
/// credentials — not the legacy `~/.cursor/auth.json` (an existence check on its
/// account keys, never the token), and emphatically not the Keychain items the
/// current CLI writes, which is why the sign-in signal is the CLI's own answer to
/// `--list-models` rather than anything dug out of a token store. The in-app Sign
/// in / Re-authorize action spawns `cursor-agent login` — the same first-class
/// subcommand the user would run in their own terminal, which opens their own
/// browser OAuth flow. That action exists here for the same reason it does on the
/// Grok row and not the Claude one: `login` is a documented headless-safe
/// subcommand, not a slash command inside a TUI that needs a real TTY.
///
/// Shape of the integration (mirrors the siblings):
///  · one turn = one `cursor-agent -p` process; the running conversation is
///    folded into a single prompt (reusing Codex's folding).
///  · the persona rides **inside** that prompt rather than a flag: Cursor's
///    `--system-prompt` is gated to Anysphere/OpenAI accounts, so it is not a
///    surface Notch can use.
///  · the prompt is the trailing positional argument. Cursor reads no prompt from
///    stdin and has no `--prompt-file`, so argv is the only channel there is.
///  · `--mode ask` is Cursor's read-only Q&A mode (the server sees it as
///    "search") — the analog of Claude's tool allowlist: the turn can read and
///    search, never write or run a shell.
///  · an ephemeral temp `--workspace` isolates the turn from the user's projects,
///    and `--trust` marks that throwaway directory trusted so a headless run
///    never stalls on a workspace-trust prompt it cannot answer.
///  · `--output-format stream-json` prints the same NDJSON dialect Claude Code
///    speaks: a `system`/`init` header, `assistant` message events carrying the
///    answer text, `tool_call` / `thinking` events we drop, and a terminal
///    `result` with the verdict and this turn's token usage.
///
/// Deliberately NOT passed: `--stream-partial-output`. It makes Cursor emit each
/// token as its own `assistant` event, which is what a streaming UI wants — but
/// the CLI keeps accumulating those same deltas and flushes the whole run as one
/// more `assistant` event at the end (verified in the shipped bundle), so every
/// answer would arrive twice. Buffered events are the correct read until that is
/// fixed; it also leaves this exactly where the Claude Code path already is.
///
/// Cursor runs its own agent loop, so this conforms to `AIService` only — like
/// its siblings it deliberately does NOT adopt Notch's tool harness.
struct CursorCLIService: AIService {
    /// The `--model` to pass. `nil` means "whatever Cursor itself is configured to
    /// run" — always valid whatever the account exposes.
    let model: String?

    /// The picker's Cursor row carries the id "cursor" — a sentinel for "the CLI's
    /// own default", not a real `--model` value. Normalize that (and empty) to nil.
    init(model: String? = nil) {
        let m = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = (m.isEmpty || m == Self.defaultSentinel) ? nil : m
    }

    /// The "use the CLI's own default model" model id — never a real `--model`.
    static let defaultSentinel = "cursor"

    // MARK: - Availability

    /// Absolute paths the Cursor CLI lives at, in priority order: the official
    /// installer's location first, then the package managers.
    ///
    /// Only the `cursor-agent` name is ever looked for. The current installer also
    /// lays down a shorter `agent` symlink beside it, but that name is not Cursor's
    /// to own — on a machine with xAI's CLI installed, `~/.local/bin/agent` is
    /// Grok's — so accepting it would let one vendor's binary answer as another's.
    private static let candidatePaths: [String] = {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin/cursor-agent",
            "/opt/homebrew/bin/cursor-agent",
            "/usr/local/bin/cursor-agent",
        ]
    }()

    private static let resolveLock = NSLock()
    /// Double-optional cache: `nil` = never resolved; `.some(nil)` = resolved to
    /// "no binary". Resolution shells out (`--help`), so it's cached for the
    /// process lifetime — warm it off-main at launch via `warmUp()`.
    private static var cachedBinary: String??
    /// Whether the resolved binary is a build Notch can actually drive — see
    /// `probeBinary`. False for an install too old to have the flags a chat turn
    /// passes; meaningless until `cachedBinary` is set.
    private static var cachedModern = false
    /// The outdated build's own version string, for the row that has to name it.
    /// Only read when the capability probe says the install is too old, so a
    /// healthy launch never pays the second spawn.
    private static var cachedVersion: String?
    /// Guards `warmingUp` only. Deliberately NOT `resolveLock`: that one is held for
    /// the whole probe, so taking it here would put the render right back into the
    /// wait this exists to avoid. This one is never held across work.
    private static let warmLock = NSLock()
    /// Set once a `warmUp()` is in flight, so repeated availability reads during the
    /// first resolution don't each queue another probe.
    private static var warmingUp = false

    /// The resolved `cursor-agent` binary path, or `nil` if none works. Cached.
    ///
    /// **Blocking** — a cold cache spawns `--help` (and may probe the shell PATH),
    /// and it waits on the lock the launch warm-up holds while doing exactly that.
    /// Never call it on the main thread: renders use `resolvedBinaryIfReady()`.
    static func resolveBinary() -> String? {
        resolveLock.lock(); defer { resolveLock.unlock() }
        if let cached = cachedBinary { return cached }
        let resolved = locateBinary()
        cachedBinary = .some(resolved?.path)
        cachedModern = resolved?.modern ?? false
        cachedVersion = resolved?.version
        return resolved?.path
    }

    /// Whether the installed CLI is a build too old for Notch to drive. An install
    /// that answers to the name but predates the flags a chat turn needs would fail
    /// every single turn on an unknown-option error, so it is treated as its own
    /// state — not as "installed and fine", and not as "not installed", both of
    /// which send the user somewhere that doesn't fix it.
    ///
    /// Non-blocking, like `isAvailable`: false until the probe lands, so a launch
    /// never flashes an "out of date" warning it hasn't earned.
    static var isOutdated: Bool {
        guard resolveLock.try() else { return false }
        defer { resolveLock.unlock() }
        guard let resolved = cachedBinary, resolved != nil else { return false }
        return !cachedModern
    }

    /// The outdated build's version string ("2025.09.18-7ae6800"), when one was
    /// read. Empty otherwise — the row then says the same thing without the number.
    static var installedVersion: String {
        guard resolveLock.try() else { return "" }
        defer { resolveLock.unlock() }
        return cachedVersion ?? ""
    }

    /// The resolved binary **without ever waiting**: the answer if the resolution has
    /// already landed, else `nil` (and a warm-up kicked off), never a block. The
    /// render-safe read — see `CommandCodeCLIService.resolvedBinaryIfReady()` for why
    /// warming up off-main is not by itself enough to keep `body` out of the probe.
    static func resolvedBinaryIfReady() -> String? {
        var known: String?? = nil
        if resolveLock.try() {
            known = cachedBinary
            resolveLock.unlock()
        }
        if let known { return known }
        warmUp()
        return nil
    }

    /// Whether the resolution has actually LANDED — the difference between "no"
    /// and "not yet". `isAvailable` collapses the two on purpose (it's read from
    /// `body`, so it can never block), which is fine for drawing but wrong for
    /// anything that acts destructively on a negative.
    static var isAvailabilityResolved: Bool {
        guard resolveLock.try() else { return false }
        defer { resolveLock.unlock() }
        return cachedBinary != nil
    }

    /// Resolve the binary and read the model catalog off the main thread, so the
    /// first `isAvailable` / `defaultModel` call during a SwiftUI render reads a
    /// warm cache instead of shelling out on the main thread. Idempotent: a second
    /// call while the first is still probing is a no-op.
    static func warmUp() {
        warmLock.lock()
        guard !warmingUp else { warmLock.unlock(); return }
        warmingUp = true
        warmLock.unlock()
        DispatchQueue.global(qos: .utility).async {
            _ = resolveBinary()
            warmLock.lock(); warmingUp = false; warmLock.unlock()
            primeFromDisk()
            refreshModels()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .cliAvailabilityResolved, object: nil)
            }
        }
    }

    // MARK: - Re-check

    private static let recheckLock = NSLock()
    private static var rechecking = false

    /// Whether a re-check is running. The row draws it, so it must never block.
    static var isRechecking: Bool {
        recheckLock.lock(); defer { recheckLock.unlock() }
        return rechecking
    }

    /// Throw away everything this process learned about the install and probe
    /// again.
    ///
    /// The resolution is cached for the process lifetime, which is right for every
    /// other read — the binary does not usually move under a running app. It does
    /// move in exactly one case, and it is the case the account row is *asking* the
    /// user to create: they go install or update the CLI in a terminal and come
    /// back. Without this the row keeps reporting the state from launch, and the
    /// only way out is quitting Notch — which nothing on screen would tell them.
    static func recheck() {
        recheckLock.lock()
        guard !rechecking else { recheckLock.unlock(); return }
        rechecking = true
        recheckLock.unlock()
        announce()
        DispatchQueue.global(qos: .userInitiated).async {
            resolveLock.lock()
            cachedBinary = nil
            cachedModern = false
            cachedVersion = nil
            resolveLock.unlock()
            // The verdict describes an install that may no longer be the one on
            // disk; the forced probe below reaches a new one.
            modelLock.lock(); cachedSignedIn = nil; modelLock.unlock()
            // Same for a failure left over from a previous sign-in.
            signInLock.lock(); signInMessage = nil; signInLock.unlock()

            _ = resolveBinary()
            // The catalog is deliberately NOT cleared first: `refreshModels`
            // overwrites it on success and leaves it alone on a failed probe, so a
            // re-check that finds nothing keeps the rows it already had.
            refreshModels(force: true)

            recheckLock.lock(); rechecking = false; recheckLock.unlock()
            announce()
        }
    }

    private static func locateBinary() -> (path: String, modern: Bool, version: String?)? {
        let fm = FileManager.default
        for p in candidatePaths where fm.isExecutableFile(atPath: p) {
            if let probed = probeBinary(p) { return probed }
        }
        // Fall back to the user's shell PATH (a non-standard install, or a
        // `~/.local/bin` a GUI app doesn't inherit) — see `ShellEnvironment`.
        if let p = ShellEnvironment.which(["cursor-agent"]), let probed = probeBinary(p) {
            return probed
        }
        return nil
    }

    /// Vet a candidate and decide whether Notch can drive it, from one `--help`.
    ///
    /// `--help` rather than `--version` because it answers both questions at once,
    /// and answers the second one *exactly*. The flags a chat turn passes
    /// (`--mode`, `--output-format stream-json`) and the ones the picker needs
    /// (`--list-models`) all arrived in the CLI at some point Notch has no business
    /// guessing a date for — so this asks the installed build what it can do rather
    /// than comparing version numbers against a hardcoded floor that would go stale
    /// or, worse, be wrong from the start.
    ///
    /// `nil` = not a working Cursor CLI (a broken shim, or some other tool wearing
    /// the name). A hit with `modern == false` is a real Cursor CLI that is simply
    /// too old; the version is read then — and only then — so the row can name it.
    private static func probeBinary(_ path: String) -> (path: String, modern: Bool, version: String?)? {
        let p = ShellEnvironment.makeProcess(path, ["--help"])
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let help = String(data: data, encoding: .utf8),
              help.contains("Start the Cursor Agent")
        else { return nil }
        // "--mode <" and not "--mode": the old builds carry `--model`, which
        // contains the shorter string.
        let modern = help.contains("--list-models") && help.contains("--mode <")
        return (path, modern, modern ? nil : readVersion(path))
    }

    /// The build's own version string, for the out-of-date message.
    private static func readVersion(_ path: String) -> String? {
        let p = ShellEnvironment.makeProcess(path, ["--version"])
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let version = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return version.isEmpty ? nil : version
    }

    /// The Cursor home directory (`~/.cursor`).
    private static var cursorHome: String { "\(NSHomeDirectory())/.cursor" }

    /// Whether the user has signed in.
    ///
    /// **Not a file check.** On macOS the current CLI keeps its tokens in the
    /// system Keychain — "Authentication tokens stored securely" is `login`'s own
    /// success line — so `~/.cursor/auth.json` is simply absent on a perfectly
    /// signed-in machine, and Notch is not going to rummage through another app's
    /// Keychain items to find out. What it asks instead is the question it actually
    /// needs answered: does this CLI hand back an account's model catalog?
    /// `--list-models` prints one only for a signed-in account and an
    /// authentication error otherwise, and that is a probe Notch already runs and
    /// caches (`refreshModels`). Same shape as `PiCLIService.authExists`.
    ///
    /// The env var and the legacy file still count outright — an install carrying
    /// either is signed in whatever the catalog probe has managed to learn yet.
    static func authExists() -> Bool {
        if let key = ProcessInfo.processInfo.environment["CURSOR_API_KEY"],
           !key.trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        if legacyAuthFileExists() { return true }
        modelLock.lock(); defer { modelLock.unlock() }
        // Before any probe has landed, a catalog restored from the last launch is
        // the best evidence available — stale beats blank, and `warmUp` corrects it
        // within seconds of launch.
        return cachedSignedIn ?? (cachedModels?.isEmpty == false)
    }

    /// The pre-Keychain credential file, still written by older builds and by
    /// installs where the Keychain is unavailable. Only the *presence* of a marker
    /// is read, never the token itself.
    private static func legacyAuthFileExists() -> Bool {
        let authPath = "\(cursorHome)/auth.json"
        guard let data = FileManager.default.contents(atPath: authPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["accessToken"] != nil || json["refreshToken"] != nil || json["apiKey"] != nil
    }

    /// Whether Cursor can actually answer right now: the binary resolves, it is a
    /// build Notch can drive, AND the user has signed in. Drives the picker (Cursor
    /// is selectable only when true) and the Settings status row. Reads the
    /// resolution non-blockingly (this runs inside `body`); until the launch probe
    /// lands it answers "no" and `.cliAvailabilityResolved` redraws.
    static var isAvailable: Bool {
        resolvedBinaryIfReady() != nil && !isOutdated && authExists()
    }

    // MARK: - Model catalog

    /// One row of `cursor-agent --list-models`.
    struct CatalogEntry {
        let id: String
        /// The name the CLI printed beside the id ("OpenAI GPT-5"), or the id when
        /// the row carried none.
        let name: String
        /// The row the CLI marked `(default)` — what a flag-less run uses.
        let isDefault: Bool
    }

    private static let modelLock = NSLock()
    /// The account's models, from the catalog the resolved binary printed. `nil` =
    /// not read yet; an empty array = read but unparsable, so we fall back to the
    /// sentinel and don't re-scan on every render.
    private static var cachedModels: [CatalogEntry]?
    /// What the last catalog probe said about the account: true = it printed a
    /// catalog, false = it answered "not authenticated", `nil` = no probe has
    /// reached a verdict (never run, or it failed for some other reason). This is
    /// the sign-in signal — see `authExists`.
    private static var cachedSignedIn: Bool?

    /// Where the last successful catalog read lives. `--list-models` is
    /// network-bound (it asks Cursor what this account may run), so paying it on
    /// every launch would leave the picker showing a bare "Cursor" row for the
    /// seconds it takes. Same rationale, and the same fingerprint + TTL gate, as
    /// `CommandCodeCLIService`'s stored catalog.
    private static let storedCatalogKey = "cursorCode.catalog"
    private static let storedFingerprintKey = "cursorCode.catalog.fingerprint"
    private static let storedFetchedAtKey = "cursorCode.catalog.fetchedAt"
    /// Backstop for the one change the fingerprint can't see — the account's own
    /// lineup moving (a plan change, or Cursor adding a model to an unchanged CLI
    /// build). A week, exactly as `ClaudeCLIService.resolvedModelsTTL`.
    private static let catalogTTL: TimeInterval = 7 * 24 * 3600

    private static let primeLock = NSLock()
    private static var primed = false

    /// Adopt the previous launch's catalog. A `UserDefaults` read and nothing else —
    /// no spawn, no lock held across work — and it runs exactly once per process.
    /// Whether that catalog is still current is settled by `refreshModels()`; showing
    /// last launch's rows until then is the point, since stale beats blank.
    static func primeFromDisk() {
        primeLock.lock()
        guard !primed else { primeLock.unlock(); return }
        primed = true
        primeLock.unlock()

        let models = (UserDefaults.standard.stringArray(forKey: storedCatalogKey) ?? [])
            .compactMap(decode)
        guard !models.isEmpty else { return }
        modelLock.lock()
        // Only the rows are restored, never a verdict: a catalog on disk is last
        // launch's evidence, and `authExists` already reads it as exactly that
        // until a live probe reaches one.
        if cachedModels == nil { cachedModels = models }
        modelLock.unlock()
    }

    private static func adopt(_ models: [CatalogEntry], signedIn: Bool) {
        modelLock.lock()
        cachedModels = models
        cachedSignedIn = signedIn
        modelLock.unlock()
    }

    private static func fetchedModels() -> [CatalogEntry] {
        modelLock.lock(); defer { modelLock.unlock() }
        return cachedModels ?? []
    }

    /// Every model id Cursor offers, for the picker. Falls back to the single
    /// sentinel (→ the CLI's own default, no `--model`) until the catalog lands.
    static var availableModelIDs: [String] {
        let models = fetchedModels()
        return models.isEmpty ? [defaultSentinel] : models.map(\.id)
    }

    /// id + display name for the picker's rows — the catalog's own names ("OpenAI
    /// GPT-5"), since Cursor's bare ids (`sonnet-4.5`, `composer-1`) name a model
    /// without naming its lab. Empty until the catalog read lands, mirroring
    /// `GrokCLIService.listedModels`.
    static var listedModels: [(id: String, displayName: String)] {
        fetchedModels().map { ($0.id, $0.name) }
    }

    /// The model a flag-less run uses: the catalog's `(default)` row, else the first
    /// id, else the sentinel.
    static var defaultModel: String {
        let models = fetchedModels()
        return (models.first(where: \.isDefault) ?? models.first)?.id ?? defaultSentinel
    }

    /// Re-read the catalog off the main thread and store it. Called from `warmUp()`
    /// at launch so the picker reads a warm cache. Cheap on a hit — it returns
    /// without spawning while the persisted catalog was written by *this* CLI build
    /// and is inside the TTL. `force` (the manual refresh) skips that gate and
    /// re-probes; a failed probe leaves the cached catalog alone.
    /// Re-read the catalog off the main thread and store it. This is also the
    /// sign-in probe (see `authExists`), so it is deliberately NOT gated on being
    /// signed in — that would be circular, and a signed-out account is one of the
    /// answers it exists to get.
    ///
    /// Cheap on a hit: it returns without spawning while the persisted catalog was
    /// written by *this* CLI build and is inside the TTL. `force` (a manual refresh
    /// or a re-check) skips that gate.
    static func refreshModels(force: Bool = false) {
        // `--list-models` is one of the flags an old build doesn't have; asking it
        // only produces an unknown-option error.
        guard let binary = resolveBinary(), !isOutdated else { return }
        let defaults = UserDefaults.standard
        if !force,
           !fetchedModels().isEmpty,
           fingerprint(of: binary) == defaults.string(forKey: storedFingerprintKey),
           let fetched = defaults.object(forKey: storedFetchedAtKey) as? Date,
           Date().timeIntervalSince(fetched) < catalogTTL {
            return
        }
        switch probeCatalog(binary) {
        case .list(let models):
            adopt(models, signedIn: true)
            remember(path: binary, models: models)
        case .unauthenticated:
            // A definite answer, so it must clear a catalog left over from a
            // session that WAS signed in — otherwise a logout would keep reading as
            // signed in for a week.
            adopt([], signedIn: false)
            forgetStored()
        case .failed:
            // Says nothing about the account: leave both the catalog and the
            // verdict exactly as they were.
            break
        }
    }

    private static func remember(path: String, models: [CatalogEntry]) {
        let defaults = UserDefaults.standard
        defaults.set(models.map(encode), forKey: storedCatalogKey)
        defaults.set(Date(), forKey: storedFetchedAtKey)
        if let fp = fingerprint(of: path) {
            defaults.set(fp, forKey: storedFingerprintKey)
        } else {
            defaults.removeObject(forKey: storedFingerprintKey)
        }
    }

    /// Drop the persisted catalog, so a later launch doesn't restore rows for an
    /// account that has since signed out.
    private static func forgetStored() {
        let defaults = UserDefaults.standard
        for key in [storedCatalogKey, storedFingerprintKey, storedFetchedAtKey] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Identity of the build that will actually run: the executable's size and
    /// modification date, taken through any symlink. The CLI installs as a symlink
    /// into a versioned directory, and an update repoints it — a fingerprint of the
    /// link itself would never move.
    private static func fingerprint(of path: String) -> String? {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: real),
              let size = attrs[.size] as? Int
        else { return nil }
        let stamp = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(real)|\(size)|\(Int(stamp))"
    }

    /// One catalog row as a line. Tab-separated because an id and a display name can
    /// both carry spaces and punctuation, but neither carries a tab.
    private static func encode(_ e: CatalogEntry) -> String {
        "\(e.id)\t\(e.name)\t\(e.isDefault ? "1" : "0")"
    }

    private static func decode(_ line: String) -> CatalogEntry? {
        let parts = line.components(separatedBy: "\t")
        guard parts.count == 3, !parts[0].isEmpty else { return nil }
        return CatalogEntry(id: parts[0], name: parts[1], isDefault: parts[2] == "1")
    }

    /// What one `--list-models` run established.
    enum CatalogProbe {
        case list([CatalogEntry])
        /// The CLI answered that nobody is signed in — a verdict about the
        /// account, not a failure of the probe.
        case unauthenticated
        /// Told us nothing: a crash, a network problem, unparsable output.
        case failed
    }

    /// Spawn `<binary> --list-models` and read its answer. Separating
    /// "not signed in" from "didn't work" is the whole point: the first is the
    /// signal `authExists` runs on, and acting on the second as though it were the
    /// first would sign the user out every time their network hiccuped.
    private static func probeCatalog(_ path: String) -> CatalogProbe {
        let p = ShellEnvironment.makeProcess(path, ["--list-models"])
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .failed }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return .failed }
        if CursorError.isAuthFailure(text) { return .unauthenticated }
        guard p.terminationStatus == 0, text.contains("Available models") else { return .failed }
        let models = parseCatalog(text)
        return models.isEmpty ? .failed : .list(models)
    }

    /// Parse `--list-models` output. Kept a pure function of a string — the format
    /// is the one brittle seam in this file.
    ///
    /// The printed shape is a header, then one row per model, then a usage trailer:
    ///
    ///     Available models
    ///
    ///     gpt-5 - OpenAI GPT-5 (current, default)
    ///     sonnet-4.5 - Claude Sonnet 4.5
    ///     …
    ///     Tip: use --model <id> to switch.
    static func parseCatalog(_ text: String) -> [CatalogEntry] {
        var out: [CatalogEntry] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("Available models") { continue }
            if line.hasPrefix("Tip:") { break }
            // The trailing `(current, default)` marker, when present, is the row's
            // status rather than part of its name.
            var isDefault = false
            if line.hasSuffix(")"), let open = line.lastIndex(of: "(") {
                let tags = line[line.index(after: open)..<line.index(before: line.endIndex)]
                if tags.split(separator: ",")
                    .allSatisfy({ ["current", "default"].contains(
                        $0.trimmingCharacters(in: .whitespaces)) }) {
                    isDefault = tags.contains("default")
                    line = String(line[..<open]).trimmingCharacters(in: .whitespaces)
                }
            }
            // `id - Display Name`, or a bare id when the CLI printed no name.
            let id: String, name: String
            if let dash = line.range(of: " - ") {
                id = String(line[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
                name = String(line[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                id = line
                name = line
            }
            // Anything with whitespace left in the id is prose, not a model row.
            guard !id.isEmpty, !id.contains(" ") else { continue }
            out.append(CatalogEntry(id: id, name: name.isEmpty ? id : name, isDefault: isDefault))
        }
        return out
    }

    // MARK: - Naming

    /// The lab behind a Cursor model id.
    ///
    /// Cursor is an aggregator, so its ids are meant to name their own vendor — and
    /// most do (`gpt-5.3-codex`, `claude-opus-5-thinking-high`, `gemini-3.7-flash`,
    /// `glm-5.2-max`, `kimi-*`). Two shapes don't:
    ///
    ///  · Cursor's own line — the `auto` router, `composer-*`, `cheetah`, and the
    ///    `cursor-…` models. The prefix there is a brand, not routing: the catalog
    ///    carries no bare `grok-*` at all, only `cursor-grok-4.6-*`, and Cursor's
    ///    own display name for those rows is "Cursor Grok 4.6". They are its
    ///    product, tuned and served under its name, so they wear its mark.
    ///  · bare `sonnet-*` / `opus-*` / `haiku-*` — some builds print Anthropic's
    ///    families without the `claude-` prefix, which would read as no vendor at
    ///    all and land on a monogram tile.
    static func vendor(forID id: String) -> String {
        let l = id.lowercased()
        if l.hasPrefix("cursor-") || l.hasPrefix("composer") || l.hasPrefix("cheetah")
            || l == defaultSentinel || l == "auto" {
            return "Cursor"
        }
        if l.hasPrefix("sonnet") || l.hasPrefix("opus") || l.hasPrefix("haiku") {
            return "Anthropic"
        }
        return ModelRatings.vendor(for: id)
    }

    // MARK: - Sign in / re-authorize

    /// How long the browser half of a sign-in may take before we give up on it.
    private static let signInTimeout: TimeInterval = 5 * 60
    /// How long the CLI gets to print its login URL. It is a node boot plus one
    /// round-trip to Cursor, so this is generous — but bounded, because a CLI too
    /// old to print one at all must not leave the row spinning forever.
    private static let loginURLTimeout: TimeInterval = 30

    private static let signInLock = NSLock()
    private static var signInRunning = false
    private static var signInMessage: String?

    /// Whether a sign-in this app started is still waiting on the browser. The
    /// account row draws it, so it must never block.
    static var isSigningIn: Bool {
        signInLock.lock(); defer { signInLock.unlock() }
        return signInRunning
    }

    /// Why the last sign-in did not finish, or nil if none has failed. Cleared when
    /// the next attempt starts.
    static var lastSignInFailure: String? {
        signInLock.lock(); defer { signInLock.unlock() }
        return signInMessage
    }

    /// Kick off a fresh Cursor sign-in and see it through: spawn
    /// `cursor-agent login`, open the URL it prints, and wait for the credentials to
    /// land in `~/.cursor/auth.json`. Returns false only when the binary can't be
    /// found; everything after that is reported through `isSigningIn` /
    /// `lastSignInFailure` and a `.cliAvailabilityResolved` post. Doubles as the
    /// first-time "Sign in" action.
    ///
    /// **Notch opens the browser, not the CLI.** Left to itself the CLI opens the
    /// login page by shelling out to `open`, behind two checks it makes about its
    /// own environment — and from a GUI-spawned child, with no terminal and a PATH
    /// Notch assembled, either check can quietly decline. The failure mode is the
    /// worst kind: the button does nothing and says nothing. So `NO_OPEN_BROWSER`
    /// turns that off, the URL is read off the CLI's own stdout, and `NSWorkspace`
    /// opens it the way a Mac app opens a link.
    ///
    /// The child is kept alive deliberately — it is the half that polls Cursor and
    /// writes the credentials once the browser flow completes, so killing it at
    /// spawn time (or letting a full pipe stall it) is exactly how a sign-in
    /// finishes in the browser and never arrives in the app.
    ///
    /// We deliberately do NOT `logout` first: if the user cancels the browser flow,
    /// clearing the old credentials would leave them signed out — worse than before.
    @discardableResult
    static func reauthorize() -> Bool {
        guard let binary = resolveBinary() else { return false }
        signInLock.lock()
        if signInRunning { signInLock.unlock(); return true }
        signInRunning = true
        signInMessage = nil
        signInLock.unlock()
        announce()
        DispatchQueue.global(qos: .userInitiated).async { runSignIn(binary) }
        return true
    }

    private static func finishSignIn(_ failure: String?) {
        signInLock.lock()
        signInRunning = false
        signInMessage = failure
        signInLock.unlock()
        announce()
    }

    /// Tell every surface that draws CLI state to redraw.
    private static func announce() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .cliAvailabilityResolved, object: nil)
        }
    }

    private static func runSignIn(_ binary: String) {
        let process = ShellEnvironment.makeProcess(binary, ["login"])
        process.environment?["NO_OPEN_BROWSER"] = "1"
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let reader = LoginOutput()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let url = reader.ingest(data) {
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
        }

        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            finishSignIn(error.localizedDescription)
            return
        }

        // The child's own exit is the verdict, not anything on disk: the CLI stores
        // its tokens in the Keychain, so watching for a credential file to appear
        // would wait out the full timeout on a sign-in that had already succeeded.
        let started = Date()
        var opened = false
        var failure: String?
        while process.isRunning {
            if !opened, reader.url != nil { opened = true }
            // A CLI that never prints a URL cannot be driven from here — a build
            // whose sign-in is an interactive screen, or one that failed before it
            // got that far. Say so instead of waiting out the browser timeout.
            if !opened, Date().timeIntervalSince(started) > loginURLTimeout {
                failure = L("cursor.error.signInNoURL")
                break
            }
            if Date().timeIntervalSince(started) > signInTimeout {
                failure = L("cursor.error.signInTimedOut")
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        if process.isRunning {
            process.terminate()
        } else if failure == nil {
            // It ran to completion. A clean exit means the tokens are stored — the
            // catalog probe below confirms it against the account, and only its
            // answer decides. The CLI's own last line is NOT used here: on the
            // success path that line reads "Authentication tokens stored securely",
            // and showing it as the reason a sign-in failed is nonsense.
            let clean = process.terminationStatus == 0
            refreshModels(force: true)
            if !authExists() {
                let tail = reader.lastLine
                failure = clean || tail.isEmpty ? L("cursor.error.signInFailed") : tail
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        finishSignIn(failure)
    }

    /// Collects `cursor-agent login`'s output and pulls the login URL out of it.
    /// Lock-guarded — the readability handler runs on its own queue while
    /// `runSignIn` polls from another.
    private final class LoginOutput {
        private let lock = NSLock()
        private var text = ""
        private var found: URL?

        /// The login URL, once it has been seen.
        var url: URL? {
            lock.lock(); defer { lock.unlock() }
            return found
        }

        /// The last non-empty line printed — the best failure text available when
        /// the CLI gives up.
        var lastLine: String {
            lock.lock(); defer { lock.unlock() }
            return text.split(separator: "\n").map(String.init)
                .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        }

        /// Append `data`; returns the login URL on the read that first completes it,
        /// and nil on every other read, so the caller opens the browser exactly once.
        func ingest(_ data: Data) -> URL? {
            guard let chunk = String(data: data, encoding: .utf8) else { return nil }
            lock.lock(); defer { lock.unlock() }
            text += chunk
            guard found == nil, let url = Self.loginURL(in: text) else { return nil }
            found = url
            return url
        }

        /// Find the login URL in the CLI's output.
        ///
        /// Not a plain "first https:// token": the CLI renders through a terminal UI
        /// that wraps to the assumed width, so on some builds the URL arrives split
        /// across several lines. A continuation line is recognizable — one
        /// whitespace-free run of URL characters — while the prose that follows the
        /// link ("Press q to show a QR code…") carries spaces, which is what ends
        /// the scan.
        static func loginURL(in raw: String) -> URL? {
            let stripped = raw.replacingOccurrences(
                of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            let lines = stripped.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let start = lines.firstIndex(where: { $0.contains("https://") }),
                  let scheme = lines[start].range(of: "https://")
            else { return nil }
            var text = String(lines[start][scheme.lowerBound...])
            var i = lines.index(after: start)
            while i < lines.endIndex, isContinuation(lines[i]) {
                text += lines[i]
                i = lines.index(after: i)
            }
            // Output arrives in chunks, and a chunk can end mid-URL — which still
            // parses, into a truncated link that opens on a dead page. So the URL
            // counts as complete only once a line after it exists; a buffer ending
            // in a newline supplies that as the empty trailing element.
            guard i < lines.endIndex else { return nil }
            // The CLI prints the link on its own line (or at the end of one), so a
            // trailing sentence period is punctuation, not part of the URL.
            while text.hasSuffix(".") { text.removeLast() }
            return URL(string: text)
        }

        private static let urlCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
                + "-._~:/?#[]@!$&'()*+,;=%")

        private static func isContinuation(_ line: String) -> Bool {
            !line.isEmpty && line.unicodeScalars.allSatisfy(urlCharacters.contains)
        }
    }

    // MARK: - Streaming

    /// How long a single chat turn may run before we terminate it. Cursor is agentic
    /// (it may search mid-turn), so this is generous — the real stop signal is the
    /// surrounding `Task` being cancelled when the panel closes.
    private static let timeout: TimeInterval = 180

    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let binary = Self.resolveBinary() else {
                continuation.finish(throwing: CursorError.notInstalled); return
            }
            // An old build would fail on the first unknown flag with a message
            // about argument parsing, which names neither the cause nor the fix.
            guard !Self.isOutdated else {
                continuation.finish(throwing: CursorError.outdated); return
            }
            guard Self.authExists() else {
                continuation.finish(throwing: CursorError.notSignedIn); return
            }

            // The persona has to ride inside the prompt: Cursor's `--system-prompt`
            // is gated to Anysphere/OpenAI accounts, so there is no flag to put it
            // on. `composePrompt` folds it in ahead of the conversation, exactly as
            // the Codex path does.
            let prompt = CodexCLIService.composePrompt(system: system, messages: messages)
            let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("notch-cursor-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            // Everything is explicit — never inherited from the user's own setup.
            // `--mode ask` is Cursor's read-only Q&A mode, so the turn can read and
            // search but never write or run a shell; the empty temp workspace means
            // there is nothing of the user's to read in the first place, and
            // `--trust` clears the workspace-trust prompt a headless run could not
            // answer. The prompt goes last, as the trailing positional argument.
            var args = ["-p",
                        "--output-format", "stream-json",
                        "--mode", "ask",
                        "--workspace", workDir.path,
                        "--trust"]
            if let model { args += ["--model", model] }
            args.append(prompt)

            let process = ShellEnvironment.makeProcess(binary, args, cwd: workDir)

            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardInput = FileHandle.nullDevice
            process.standardError = errPipe

            let state = CursorStreamState()

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for text in state.ingest(data) {
                    continuation.yield(text)
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { state.appendStderr(data) }
            }

            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: watchdog)

            process.terminationHandler = { proc in
                watchdog.cancel()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                try? FileManager.default.removeItem(at: workDir)

                let snapshot = state.finish()
                if let msg = snapshot.failure {
                    continuation.finish(throwing: CursorError.classify(msg))
                } else if !snapshot.yieldedAny {
                    if proc.terminationStatus != 0 {
                        continuation.finish(throwing: CursorError.classify(snapshot.stderrTail))
                    } else {
                        // A signed-out CLI prints its authentication error on stdout
                        // and still exits 0, so the tail is the only reason available.
                        let tail = snapshot.stdoutTail
                        if !tail.isEmpty, CursorError.isAuthFailure(tail) {
                            continuation.finish(throwing: CursorError.authExpired)
                        } else {
                            continuation.finish(throwing: CursorError.noOutput)
                        }
                    }
                } else {
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }

            do {
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: workDir)
                continuation.finish(throwing: CursorError.spawnFailed(error.localizedDescription))
            }
        }
    }
}

// MARK: - Stream state (thread-safe)

/// Line-buffers the `cursor-agent -p` NDJSON stdout. The dialect is Claude Code's:
/// answer text arrives as `assistant` message events carrying `message.content`
/// text blocks, and the terminal `result` event carries `is_error` plus this
/// turn's token usage. `tool_call`, `thinking` and `system` events are dropped.
/// Lock-guarded — the readability and termination handlers run on different
/// queues. Mirrors `ClaudeStreamState`.
private final class CursorStreamState {
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    /// Non-JSON stdout, kept for the one failure mode that reports itself there: a
    /// signed-out CLI prints a plain-text authentication error and exits 0.
    private var stdoutTail = ""
    private var stderrTail = ""
    private var yieldedAny = false
    private var failure: String?

    struct Snapshot {
        let yieldedAny: Bool
        let failure: String?
        let stderrTail: String
        let stdoutTail: String
    }

    /// Append `data` and return the text blocks in newly-completed NDJSON lines.
    func ingest(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        stdoutBuffer.append(data)
        var out: [String] = []
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard !line.isEmpty else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String
            else {
                // Not JSON — the CLI fell back to plain text, which is how it
                // reports a missing sign-in. Keep the tail for the error path.
                if let s = String(data: line, encoding: .utf8) {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        stdoutTail += (stdoutTail.isEmpty ? "" : "\n") + t
                        if stdoutTail.count > 2000 {
                            stdoutTail = String(stdoutTail.suffix(2000))
                        }
                    }
                }
                continue
            }
            switch type {
            case "assistant":
                // One event per flushed assistant message; a turn that used a tool
                // can produce several. Yield each text block — interleave two with a
                // paragraph break so they don't concatenate mid-sentence.
                guard let message = obj["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                for block in content where block["type"] as? String == "text" {
                    if let text = block["text"] as? String, !text.isEmpty {
                        out.append(yieldedAny ? "\n\n" + text : text)
                        yieldedAny = true
                    }
                }
            case "result":
                // The turn's real token cost. `inputTokens` is already net of the
                // cache columns (the CLI subtracts them before printing), so it is
                // taken as-is.
                if let usage = obj["usage"] as? [String: Any] {
                    TokenMeter.shared.record(input: usage["inputTokens"] as? Int ?? 0,
                                             output: usage["outputTokens"] as? Int ?? 0)
                }
                // The run's verdict. On failure the `result` string (or subtype) is
                // the best human-readable reason available.
                if (obj["is_error"] as? Bool) == true {
                    failure = (obj["result"] as? String)
                        ?? (obj["subtype"] as? String)
                        ?? "unknown error"
                }
            default:
                break   // system/init, tool_call, thinking, retry, …
            }
        }
        return out
    }

    func appendStderr(_ data: Data) {
        guard let s = String(data: data, encoding: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        stderrTail += s
        if stderrTail.count > 2000 { stderrTail = String(stderrTail.suffix(2000)) }
    }

    func finish() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let tail = stderrTail
            .split(separator: "\n")
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? ""
        return Snapshot(yieldedAny: yieldedAny, failure: failure,
                        stderrTail: tail, stdoutTail: stdoutTail)
    }
}

// MARK: - Errors

/// User-facing failures from the Cursor path. Mirrors `GrokError`.
enum CursorError: LocalizedError {
    case notInstalled
    /// Installed, but a build without the flags a chat turn passes.
    case outdated
    case notSignedIn
    case authExpired
    case spawnFailed(String)
    case runFailed(String)
    case noOutput

    /// Whether a CLI failure string is the broken-sign-in class (expired or revoked
    /// session, cleared credentials, `logout`). The CLI's own wording is
    /// "Authentication required. Run 'agent login', pass --api-key/--auth-token, or
    /// set CURSOR_API_KEY/CURSOR_AUTH_TOKEN." — every variant either names the
    /// authentication failure or the sign-in command.
    static func isAuthFailure(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("authentication required")
            || m.contains("authentication failed")
            || m.contains("not authenticated")
            || m.contains("unauthenticated")
            || m.contains("cursor_api_key")
            || m.contains("agent login")
            || m.contains("cursor-agent login")
            || (m.contains("credentials") && (m.contains("invalid") || m.contains("expired")))
    }

    /// Wrap a CLI failure string in the right case: auth failures become sign-in
    /// guidance, everything else stays verbatim.
    static func classify(_ message: String) -> CursorError {
        isAuthFailure(message) ? .authExpired : .runFailed(message)
    }

    var errorDescription: String? {
        switch self {
        case .notInstalled: return L("cursor.error.notInstalled")
        case .outdated:     return L("cursor.error.outdated")
        case .notSignedIn:  return L("cursor.error.notSignedIn")
        case .authExpired:  return L("cursor.error.authExpired")
        case .noOutput:     return L("cursor.error.noOutput")
        case .spawnFailed(let d):
            let base = L("cursor.error.spawnFailed")
            return d.isEmpty ? base : "\(base) (\(d))"
        case .runFailed(let d):
            let base = L("cursor.error.runFailed")
            return d.isEmpty ? base : "\(base) \(d)"
        }
    }
}
