import Foundation

/// A model backend that shells out to the user's locally-installed **Command Code
/// CLI** (`cmd -p --output-format json`) and streams its answer back — the
/// commandcode.ai twin of `CodexCLIService` / `ClaudeCLIService` / `GrokCLIService`.
///
/// Like the other three, Command Code carries **no API key of ours**: it reuses the
/// sign-in the user already did (`cmd login` → browser OAuth, key cached in
/// `~/.commandcode/auth.json`), or the `COMMAND_CODE_API_KEY` env var if they set
/// one. Usage bills against the user's own Command Code plan — the whole point of a
/// "use the CLI I already pay for" backend.
///
/// What makes it different from its three siblings: Command Code is an **aggregator**
/// (one account fronts ~50 models across Anthropic / OpenAI / Google / xAI / Qwen /
/// Kimi / GLM / DeepSeek / …), so its model list is the interesting surface, not a
/// single vendor's lineup. That list comes from the CLI itself — `cmd --list-models`
/// prints the catalog the installed build actually accepts — never a table bundled
/// here that would rot the day they ship a model.
///
/// **Compliance posture (mirrors the other CLI backends):** only the official binary
/// is ever executed. Notch speaks no HTTP to commandcode.ai, never reads the key in
/// `~/.commandcode/auth.json` (sign-in detection is a presence check on the file's
/// `apiKey` marker, never its value), and offers **no in-app sign-in**: `cmd login`
/// renders an interactive terminal UI (an ink app reading a real TTY), so unlike
/// `grok login` it cannot be driven headlessly — the account row tells the user to
/// run it in their own terminal, exactly like the Claude Code row.
///
/// Shape of the integration (mirrors the twins):
///  · one turn = one `cmd -p` process; the running conversation is folded into a
///    single stdin prompt. There is no `--system-prompt` flag, so the persona rides
///    at the head of that prompt (`CodexCLIService.composePrompt`, the Codex shape).
///  · `--output-format json` prints NDJSON: `{"type":"event","event":{…}}` frames —
///    including token-level `text_delta` deltas, so this stream yields as it types —
///    and one terminal `{"type":"result",…}` line carrying `subtype` / `finalText`.
///  · headless mode already denies file writes and shell commands by default; an
///    explicit `--permission-mode standard` keeps that true whatever the user's
///    `settings.json` says, so a chat turn keeps exactly the read-only tools
///    (including `web_search` / `web_fetch`, which is how a time-sensitive question
///    gets answered). `--no-skills` and an ephemeral `cwd` isolate the turn from the
///    user's skills / AGENTS.md / project config; `--no-session` keeps quick chats
///    out of their session history; `--trust` and `--skip-onboarding` stop it
///    blocking on a prompt no one is there to answer.
///
/// Command Code runs its own agent loop (search, reasoning, tools) internally, so
/// this conforms to `AIService` only — like the twins it deliberately does NOT adopt
/// the tool harness, so Notch's tools stay out of its way.
struct CommandCodeCLIService: AIService {
    /// The `--model` (`-m`) to pass. `nil` means "Command Code's own default model" —
    /// always valid whatever the account exposes.
    let model: String?

    /// The picker's row carries the id "commandcode" — a sentinel for "the CLI's own
    /// default", not a real `-m` value. Normalize that (and empty) to `nil`.
    init(model: String? = nil) {
        let m = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = (m.isEmpty || m == Self.defaultSentinel) ? nil : m
    }

    /// The "use the CLI's own default model" placeholder id, used wherever a real
    /// model id is expected before the catalog read lands.
    static let defaultSentinel = "commandcode"

    // MARK: - Availability

    /// Absolute paths the CLI lives at, in priority order. `command-code` and
    /// `commandcode` come first because they name the product; the short `cmd`
    /// alias comes last precisely because it is a name anything could take — the
    /// smoke test below is what actually decides (see `locateBinary`).
    private static let candidatePaths: [String] = {
        let home = NSHomeDirectory()
        let dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return ["command-code", "commandcode", "cmd"].flatMap { name in
            dirs.map { "\($0)/\(name)" }
        }
    }()

    private static let resolveLock = NSLock()
    /// Double-optional cache: `nil` = never resolved; `.some(nil)` = resolved to
    /// "no binary". Resolution shells out, so it's cached for the process lifetime —
    /// warm it off-main at launch via `warmUp()`.
    private static var cachedBinary: String??
    /// Guards `warmingUp` only. Deliberately NOT `resolveLock`: that one is held for
    /// the whole probe, so taking it here would put the render right back into the
    /// wait this exists to avoid. This one is never held across work.
    private static let warmLock = NSLock()
    /// Set once a `warmUp()` is in flight, so repeated availability reads during the
    /// first resolution don't each queue another probe.
    private static var warmingUp = false

    /// The resolved Command Code binary path, or `nil` if none works. Cached.
    ///
    /// **Blocking** — it spawns the CLI on a cold cache, and it waits on the lock the
    /// launch warm-up holds while its own spawn runs. Never call it from a SwiftUI
    /// render or anywhere else on the main thread: use `resolvedBinaryIfReady()`.
    static func resolveBinary() -> String? {
        primeFromDisk()
        resolveLock.lock(); defer { resolveLock.unlock() }
        if let cached = cachedBinary { return cached }
        let resolved = locateBinary()
        cachedBinary = .some(resolved)
        return resolved
    }

    /// The resolved binary **without ever waiting**: the answer if the resolution has
    /// already landed, else `nil` (and a warm-up kicked off), never a block.
    ///
    /// This is the render-safe read, and it exists because "warm it up off-main" does
    /// not on its own keep the main thread out of the resolution — it only moves who
    /// holds `resolveLock`. `probeModels` runs `cmd --list-models`, a Node CLI cold
    /// start of ~2s; a `body` that called `resolveBinary()` while that was in flight
    /// sat on the mutex for the whole spawn. That is exactly the first hover after a
    /// relaunch, and it read as the notch refusing to open.
    static func resolvedBinaryIfReady() -> String? {
        // Last launch's answer, if it's still on disk — a `UserDefaults` read and one
        // `stat`, so it is safe from a render and it makes the FIRST read of the
        // process the real one instead of "not yet" (see `primeFromDisk`).
        primeFromDisk()
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
    /// anything that acts destructively on a negative: a caller that DISCARDS
    /// state when an engine looks dead has to ask this first, or the first hover
    /// after a relaunch throws away a perfectly live pick.
    static var isAvailabilityResolved: Bool {
        primeFromDisk()
        guard resolveLock.try() else { return false }
        defer { resolveLock.unlock() }
        return cachedBinary != nil
    }

    /// Resolve the binary (and, with it, the model catalog) off the main thread, so
    /// the first `isAvailable` / `defaultModel` call during a SwiftUI render reads a
    /// warm cache instead of spawning a process on the main thread. Idempotent: a
    /// second call while the first is still probing is a no-op.
    static func warmUp() {
        // Free and synchronous: after this the app already knows what it knew when it
        // last quit, so nothing below is on the critical path of the first render.
        primeFromDisk()
        warmLock.lock()
        guard !warmingUp else { warmLock.unlock(); return }
        warmingUp = true
        warmLock.unlock()
        DispatchQueue.global(qos: .utility).async {
            _ = resolveBinary()
            revalidateSeed()
            warmLock.lock(); warmingUp = false; warmLock.unlock()
            // Anything that read `isAvailable` as "not yet known" while this ran now
            // has a real answer to redraw with.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .cliAvailabilityResolved, object: nil)
            }
        }
    }

    // MARK: - Remembering the last launch's answer

    /// Where the previous launch's resolution lives. Command Code is the one CLI
    /// backend whose vetting spawn is expensive: its siblings answer `--version` in
    /// under half a second, while `cmd --list-models` takes **8-11 seconds** on a
    /// normal machine (it is network-bound, not CPU-bound — node itself boots in
    /// 70ms). Everything is derived from that one spawn — is the engine available,
    /// what models does it serve — so with an in-memory-only cache EVERY launch had a
    /// ten-second window where Command Code read as unconfigured: the engine missing
    /// from the agent picker's list, its chip falling back to the bare engine name.
    /// That window is what these keys close: the answer is written to disk and read
    /// back at the next launch before anything renders.
    private static let storedPathKey = "commandCode.binaryPath"
    private static let storedCatalogKey = "commandCode.catalog"
    private static let storedFingerprintKey = "commandCode.catalog.fingerprint"
    private static let storedFetchedAtKey = "commandCode.catalog.fetchedAt"
    /// Backstop for the one change the fingerprint can't see — the account's own
    /// lineup moving (a plan change adds models the same CLI build already knew how
    /// to serve). A week, exactly as `ClaudeCLIService.resolvedModelsTTL`: CLI
    /// updates land via the fingerprint instead, so this isn't the freshness
    /// mechanism, just its floor.
    private static let catalogTTL: TimeInterval = 7 * 24 * 3600

    private static let primeLock = NSLock()
    private static var primed = false
    /// True while this process is running on the remembered answer and no spawn has
    /// re-vetted it yet — what `revalidateSeed()` acts on.
    private static var seededFromDisk = false

    /// Adopt the previous launch's resolution, if the binary it names is still there.
    /// A `UserDefaults` read plus one `stat` — no spawn, no lock held across work — so
    /// it is safe to call from a render, and it runs exactly once per process.
    ///
    /// A remembered path is only trusted as far as "this file still exists and is
    /// executable"; whether it is still a working Command Code build is settled in the
    /// background by `revalidateSeed()`. Showing last launch's catalog for the second
    /// it takes to confirm that is the whole point — stale beats blank.
    static func primeFromDisk() {
        primeLock.lock()
        guard !primed else { primeLock.unlock(); return }
        primed = true
        primeLock.unlock()

        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: storedPathKey),
              FileManager.default.isExecutableFile(atPath: path)
        else { return }
        let models = (defaults.stringArray(forKey: storedCatalogKey) ?? []).compactMap(decode)
        guard !models.isEmpty else { return }
        resolveLock.lock()
        if cachedBinary == nil {
            cachedBinary = .some(path)
            seededFromDisk = true
        }
        resolveLock.unlock()
        adopt(models)
        // The measured `--effort` sets ride the same remembered install, so the
        // first picker open of a process shows real rungs instead of re-probing
        // every model the user looks at.
        primeEffortsFromDisk(path: path)
    }

    /// Re-vet the remembered binary off-main, and re-read its catalog only when
    /// there is something new to learn. The catalog is baked into the installed CLI
    /// build, so the binary's own identity answers "has it moved?" for free — the
    /// eight-second spawn is paid on a CLI update (which the fingerprint sees the
    /// moment it happens; Command Code self-updates, so this is not rare) or once a
    /// week, never on a plain relaunch.
    ///
    /// If the remembered binary has stopped answering — uninstalled, replaced by
    /// something else wearing the `cmd` name, broken by a bad update — the seed is
    /// thrown away and the full resolution runs, exactly as a cold launch would.
    private static func revalidateSeed() {
        resolveLock.lock()
        let seeded = seededFromDisk
        let path = cachedBinary ?? nil
        resolveLock.unlock()
        guard seeded, let path else { return }

        let defaults = UserDefaults.standard
        let fetchedAt = defaults.object(forKey: storedFetchedAtKey) as? Date
        let fresh = fetchedAt.map { Date().timeIntervalSince($0) < catalogTTL } ?? false
        let rebuilt = fingerprint(of: path) != defaults.string(forKey: storedFingerprintKey)
        if fresh, !rebuilt {
            resolveLock.lock(); seededFromDisk = false; resolveLock.unlock()
            return
        }
        if let models = probeModels(path) {
            adopt(models)
            remember(path: path, models: models)
            // A NEW build can remap every model's effort set, so its measurements go
            // with the old catalog. The weekly TTL alone doesn't invalidate them —
            // same binary, same mapping — so this hangs off the fingerprint, not
            // freshness.
            if rebuilt { forgetEfforts() }
            resolveLock.lock(); seededFromDisk = false; resolveLock.unlock()
            return
        }
        // The remembered install is gone or no longer Command Code — forget it whole
        // (path AND catalog) and resolve from scratch.
        resolveLock.lock()
        cachedBinary = nil
        seededFromDisk = false
        resolveLock.unlock()
        modelLock.lock(); cachedModels = nil; modelLock.unlock()
        forgetStored()
        forgetEfforts()
        _ = resolveBinary()
    }

    /// Write a successful resolution down for the next launch.
    private static func remember(path: String, models: [CatalogEntry]) {
        let defaults = UserDefaults.standard
        defaults.set(path, forKey: storedPathKey)
        defaults.set(models.map(encode), forKey: storedCatalogKey)
        defaults.set(Date(), forKey: storedFetchedAtKey)
        if let fp = fingerprint(of: path) {
            defaults.set(fp, forKey: storedFingerprintKey)
        } else {
            defaults.removeObject(forKey: storedFingerprintKey)
        }
    }

    private static func forgetStored() {
        let defaults = UserDefaults.standard
        for key in [storedPathKey, storedCatalogKey,
                    storedFingerprintKey, storedFetchedAtKey] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Identity of the build that will actually run: the executable's size and
    /// modification date, taken through any symlink. Node CLIs install as a shim in
    /// `bin/` pointing at the package's entry file, and it is the *target* that an
    /// update rewrites — a fingerprint of the link itself would never move.
    private static func fingerprint(of path: String) -> String? {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: real),
              let size = attrs[.size] as? Int
        else { return nil }
        let stamp = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(real)|\(size)|\(Int(stamp))"
    }

    /// One catalog row as a line. Tab-separated because a model id and a vendor
    /// caption can both carry spaces and slashes, but neither carries a tab.
    private static func encode(_ e: CatalogEntry) -> String {
        "\(e.id)\t\(e.group)\t\(e.isDefault ? "1" : "0")"
    }

    private static func decode(_ line: String) -> CatalogEntry? {
        let parts = line.components(separatedBy: "\t")
        guard parts.count == 3, !parts[0].isEmpty else { return nil }
        return CatalogEntry(id: parts[0], group: parts[1], isDefault: parts[2] == "1")
    }

    /// Find the binary by *identity*, not by name. Every candidate is asked for its
    /// model catalog (`--list-models`); only a process that exits cleanly AND prints
    /// the catalog Command Code prints is accepted. That matters for the `cmd` alias,
    /// which is a name any tool could have claimed — and it is free, because the same
    /// spawn fills the model cache the picker needs (one process, both answers).
    private static func locateBinary() -> String? {
        let fm = FileManager.default
        for p in candidatePaths where fm.isExecutableFile(atPath: p) {
            if let models = probeModels(p) {
                adopt(models)
                remember(path: p, models: models)
                return p
            }
        }
        // Fall back to the user's shell PATH — a node version manager (nvm / fnm /
        // volta / hermes) keeps its global bin dir out of a GUI app's inherited PATH
        // entirely, and out of the fixed list above (`ShellEnvironment`).
        if let p = ShellEnvironment.which(["command-code", "commandcode", "cmd"]),
           let models = probeModels(p) {
            adopt(models)
            remember(path: p, models: models)
            return p
        }
        return nil
    }

    /// The Command Code home directory (`~/.commandcode`), where the auth file lands
    /// after `cmd login`.
    private static var commandCodeHome: String { "\(NSHomeDirectory())/.commandcode" }

    /// Whether the user has signed in — either a `COMMAND_CODE_API_KEY` env var is
    /// set, or `~/.commandcode/auth.json` carries an `apiKey` entry. Only the
    /// *presence* of that marker is read, never the key itself.
    static func authExists() -> Bool {
        if let key = ProcessInfo.processInfo.environment["COMMAND_CODE_API_KEY"],
           !key.trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        let authPath = "\(commandCodeHome)/auth.json"
        guard let data = FileManager.default.contents(atPath: authPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["apiKey"] != nil
    }

    /// Whether Command Code can actually answer right now: the binary resolves AND
    /// the user has signed in. Drives the picker (the provider is selectable only
    /// when true) and the Settings status row.
    ///
    /// Reads the resolution **non-blockingly** — this is called from `body`. Until the
    /// launch probe lands it answers "no"; `.cliAvailabilityResolved` then redraws
    /// whoever asked.
    static var isAvailable: Bool { resolvedBinaryIfReady() != nil && authExists() }

    // MARK: - Model catalog

    /// One row of `cmd --list-models`.
    struct CatalogEntry {
        let id: String
        /// The group the CLI printed it under ("Anthropic", "OpenAI", "Open Source").
        let group: String
        /// The row the CLI marked `(default)` — what a flag-less run uses.
        let isDefault: Bool
    }

    private static let modelLock = NSLock()
    /// The account's models, from the catalog the resolved binary printed. `nil` =
    /// not read yet; an empty array = read but unparsable, so we fall back to the
    /// sentinel and don't re-scan on every render.
    private static var cachedModels: [CatalogEntry]?

    private static func adopt(_ models: [CatalogEntry]) {
        modelLock.lock(); cachedModels = models; modelLock.unlock()
    }

    private static func fetchedModels() -> [CatalogEntry] {
        modelLock.lock(); defer { modelLock.unlock() }
        return cachedModels ?? []
    }

    /// Every model id Command Code offers, for the picker. Falls back to the single
    /// sentinel (→ the CLI's built-in default, no `-m`) until the catalog read lands.
    static var availableModelIDs: [String] {
        let models = fetchedModels()
        return models.isEmpty ? [defaultSentinel] : models.map(\.id)
    }

    /// id + display name for the agent picker's rows. The catalog prints no display
    /// names (only ids and one-line descriptions), so the app's own id→name shaping
    /// does the work — the same names every other provider's rows use. Empty until
    /// the catalog read lands, mirroring `GrokCLIService.listedModels`.
    static var listedModels: [(id: String, displayName: String)] {
        fetchedModels().map { ($0.id, ModelRatings.prettyName(for: $0.id)) }
    }

    /// The model a flag-less run uses: the catalog's `(default)` row, else the first
    /// id, else the sentinel.
    static var defaultModel: String {
        let models = fetchedModels()
        return (models.first(where: \.isDefault) ?? models.first)?.id ?? defaultSentinel
    }

    /// Re-read the catalog off the main thread. No-op once populated — the catalog is
    /// baked into the installed CLI build, so it only moves when the CLI updates (and
    /// a relaunch re-resolves the binary anyway). Kept for parity with the other CLI
    /// backends' picker path.
    static func refreshModels() {
        modelLock.lock()
        let alreadyHave = (cachedModels?.isEmpty == false)
        modelLock.unlock()
        if alreadyHave { return }
        guard let binary = resolveBinary(), let models = probeModels(binary) else { return }
        adopt(models)
        remember(path: binary, models: models)
    }

    /// Spawn `<binary> --list-models` and parse its catalog. `nil` means "this is not
    /// a working Command Code binary" — a non-zero exit, or output that doesn't look
    /// like the catalog (which is how the generic `cmd` name is vetted).
    ///
    /// The printed shape is a header, then vendor groups of `id  description` rows,
    /// then a usage trailer:
    ///
    ///     Available models  ·  52 models
    ///
    ///     Anthropic
    ///
    ///     claude-sonnet-5    best combo of speed & intelligence (recommended)
    ///     …
    ///     Pass the full id, or just the short name after the last "/":
    private static func probeModels(_ path: String) -> [CatalogEntry]? {
        let p = ShellEnvironment.makeProcess(path, ["--list-models", "--no-auto-update"])
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              text.contains("Available models")
        else { return nil }
        let models = parseCatalog(text)
        // A catalog with no rows isn't Command Code (or is too broken to pick from).
        return models.isEmpty ? nil : models
    }

    /// Parse `--list-models` output. Exposed for the parser's own sake — the format is
    /// the one brittle seam in this file, so it is kept a pure function of a string.
    static func parseCatalog(_ text: String) -> [CatalogEntry] {
        var out: [CatalogEntry] = []
        var group = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // The usage trailer closes the list.
            if trimmed.hasPrefix("Pass the full id") { break }
            if trimmed.hasPrefix("Available models") { continue }
            // A model row is `id` + two-or-more spaces + description. Anything else
            // with no such gap is the vendor group caption above the rows.
            guard let gap = line.range(of: "  ") else { group = trimmed; continue }
            let id = String(line[..<gap.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !id.contains(" ") else { group = trimmed; continue }
            let rest = String(line[gap.upperBound...])
            out.append(CatalogEntry(id: id, group: group,
                                    isDefault: rest.contains("(default)")))
        }
        return out
    }

    // MARK: - Reasoning-effort probe

    /// An `--effort` value no build will ever accept. Passing it makes the CLI
    /// print the model's real set and exit **before it opens a connection** —
    /// which is what turns "what does this model take?" into a question we can
    /// just ask, for free.
    private static let effortProbeSentinel = "__notch_probe__"

    /// How long the probe may take before we give up on it. Measured at ~1.3s
    /// (node cold start; no API call happens), so this is pure runaway insurance.
    private static let effortProbeTimeout: TimeInterval = 15

    private static let effortLock = NSLock()
    /// Model id → the levels that model accepts. `[]` is an answer ("no adjustable
    /// reasoning effort"), not an absence — a model simply not in the dictionary is
    /// the unknown case. `defaultSentinel` keys the flag-less run (`-m` omitted).
    private static var cachedEfforts: [String: [String]] = [:]
    /// Probes in flight, so a picker redrawing ten times a second can't queue ten
    /// spawns for the same model.
    private static var effortsInFlight: Set<String> = []

    private static let storedEffortsKey = "commandCode.efforts"
    private static let storedEffortsFingerprintKey = "commandCode.efforts.fingerprint"

    /// The `--effort` levels this model accepts, or `nil` if nobody has asked the
    /// binary yet. A lock-free-ish cache read: safe from a SwiftUI render, never
    /// spawns anything itself (see `probeEfforts`).
    static func effortLevels(for modelID: String?) -> [String]? {
        let key = effortKey(modelID)
        effortLock.lock(); defer { effortLock.unlock() }
        return cachedEfforts[key]
    }

    /// Ask the installed binary what `modelID` accepts, off the main thread, once.
    /// No-op when the answer is already known or a probe is already running for it.
    /// Posts `.cliAvailabilityResolved` when an answer lands, so a picker drawn
    /// while the set was unknown redraws with the real rungs.
    static func probeEfforts(for modelID: String?) {
        let key = effortKey(modelID)
        effortLock.lock()
        let skip = cachedEfforts[key] != nil || effortsInFlight.contains(key)
        if !skip { effortsInFlight.insert(key) }
        effortLock.unlock()
        guard !skip else { return }

        // Render-safe read: if the binary hasn't resolved yet this returns nil (and
        // kicks the warm-up), and the next picker open asks again.
        guard let binary = resolvedBinaryIfReady() else {
            effortLock.lock(); effortsInFlight.remove(key); effortLock.unlock()
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let levels = runEffortProbe(binary, modelID: modelID)
            effortLock.lock()
            if let levels { cachedEfforts[key] = levels }
            effortsInFlight.remove(key)
            let snapshot = cachedEfforts
            effortLock.unlock()
            guard levels != nil else { return }
            rememberEfforts(snapshot, path: binary)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .cliAvailabilityResolved, object: nil)
            }
        }
    }

    /// The cache key for a model pick: the id itself, or the sentinel standing for
    /// "no `-m` at all", which is a distinct question from any named model.
    private static func effortKey(_ modelID: String?) -> String {
        let m = (modelID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? defaultSentinel : m
    }

    /// Spawn the probe and read the answer out of the refusal. `nil` means the
    /// output wasn't either shape we understand — don't cache a guess.
    private static func runEffortProbe(_ path: String, modelID: String?) -> [String]? {
        var args = ["-p", "hi", "--effort", effortProbeSentinel,
                    "--no-auto-update", "--skip-onboarding", "--trust", "--no-session"]
        if let modelID, !modelID.isEmpty, modelID != defaultSentinel {
            args += ["-m", modelID]
        }
        let p = ShellEnvironment.makeProcess(path, args,
                                             cwd: FileManager.default.temporaryDirectory)
        let pipe = Pipe()
        // The refusal goes to **stderr** (verified on v1.26.0; exit status 1), but
        // both streams land in one pipe so a build that moves it to stdout doesn't
        // silently turn every model into "unknown".
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + effortProbeTimeout,
                                                       execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        deadline.cancel()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parseEffortRefusal(text)
    }

    /// Pull the accepted levels out of what the CLI printed. Two shapes, both
    /// verified against v1.26.0:
    ///
    ///     Unknown effort "__notch_probe__". Supported: low, medium, high.
    ///     Kimi K3 has no adjustable reasoning effort.
    ///
    /// Anything else (a network error, a renamed model, a future rewording) is
    /// `nil` — unknown, so the menu stays at Default and we ask again later rather
    /// than caching a wrong answer. Pure function of a string, like `parseCatalog`,
    /// because this is the other brittle seam in this file.
    static func parseEffortRefusal(_ text: String) -> [String]? {
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.contains("no adjustable reasoning effort") { return [] }
            guard let marker = line.range(of: "Supported:"),
                  line.hasPrefix("Unknown effort")
            else { continue }
            let list = line[marker.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            let levels = list.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return levels.isEmpty ? nil : levels
        }
        return nil
    }

    /// Persist the measured sets against the fingerprint of the build they were
    /// measured on, so they survive a relaunch but never outlive a CLI update —
    /// the effort mapping is baked into the build, exactly like the model catalog.
    private static func rememberEfforts(_ efforts: [String: [String]], path: String) {
        let defaults = UserDefaults.standard
        defaults.set(efforts.mapValues { $0.joined(separator: ",") }, forKey: storedEffortsKey)
        if let fp = fingerprint(of: path) {
            defaults.set(fp, forKey: storedEffortsFingerprintKey)
        } else {
            defaults.removeObject(forKey: storedEffortsFingerprintKey)
        }
    }

    /// Adopt the previous launch's measurements, but only if the binary hasn't
    /// changed underneath them. Called from `primeFromDisk`, so the first picker
    /// open of a process already shows real rungs instead of re-probing.
    private static func primeEffortsFromDisk(path: String) {
        let defaults = UserDefaults.standard
        guard let stored = defaults.dictionary(forKey: storedEffortsKey) as? [String: String],
              !stored.isEmpty,
              let fp = fingerprint(of: path),
              fp == defaults.string(forKey: storedEffortsFingerprintKey)
        else { return }
        // "" round-trips an empty set — the "no adjustable effort" answer.
        let restored = stored.mapValues { value in
            value.split(separator: ",").map(String.init)
        }
        effortLock.lock()
        for (k, v) in restored where cachedEfforts[k] == nil { cachedEfforts[k] = v }
        effortLock.unlock()
    }

    /// Drop every measured set — the binary is gone or has been replaced, so what
    /// it accepted is no longer a fact about anything.
    private static func forgetEfforts() {
        effortLock.lock(); cachedEfforts = [:]; effortLock.unlock()
        UserDefaults.standard.removeObject(forKey: storedEffortsKey)
        UserDefaults.standard.removeObject(forKey: storedEffortsFingerprintKey)
    }

    // MARK: - Streaming

    /// How long a single turn may run before we terminate it. Command Code is agentic
    /// (it may search and read), so this is generous — the real stop signal is the
    /// surrounding `Task` being cancelled when the panel closes.
    private static let timeout: TimeInterval = 180

    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let binary = Self.resolveBinary() else {
                continuation.finish(throwing: CommandCodeError.notInstalled); return
            }
            guard Self.authExists() else {
                continuation.finish(throwing: CommandCodeError.notSignedIn); return
            }

            // No --system-prompt flag exists, so the persona leads the folded prompt
            // (the Codex shape, system included).
            let prompt = CodexCLIService.composePrompt(system: system, messages: messages)
            let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("notch-commandcode-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            // Everything explicit — never inherited from the user's own settings:
            // `standard` is headless's read-only permission set (file writes and
            // shell denied, reads / grep / web search allowed), `--no-skills` and the
            // empty cwd keep their skills and AGENTS.md out of the turn, `--no-session`
            // keeps a quick chat out of their history, and `--trust` /
            // `--skip-onboarding` stop it waiting on a prompt with no TTY to answer at.
            var args = ["-p",
                        "--output-format", "json",
                        "--permission-mode", "standard",
                        "--no-session", "--no-skills",
                        "--skip-onboarding", "--trust",
                        "--no-auto-update"]
            if let model { args += ["-m", model] }

            let process = ShellEnvironment.makeProcess(binary, args, cwd: workDir)

            let outPipe = Pipe(), inPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardInput = inPipe
            process.standardError = errPipe

            let state = CommandCodeStreamState()

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
                    continuation.finish(
                        throwing: CommandCodeError.classify(msg, exitCode: proc.terminationStatus))
                } else if snapshot.yieldedAny {
                    continuation.finish()
                } else if let tail = snapshot.finalText, !tail.isEmpty {
                    // A run whose answer never arrived as deltas (a short reply the
                    // provider returned whole) still has its text on the result line.
                    continuation.yield(tail)
                    continuation.finish()
                } else if proc.terminationStatus != 0 {
                    continuation.finish(
                        throwing: CommandCodeError.classify(snapshot.stderrTail,
                                                            exitCode: proc.terminationStatus))
                } else {
                    continuation.finish(throwing: CommandCodeError.noOutput)
                }
            }

            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }

            do {
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: workDir)
                continuation.finish(throwing: CommandCodeError.spawnFailed(error.localizedDescription))
                return
            }

            // `-p` with no query argument reads the prompt from stdin (it times out
            // after 30s of silence, so this write must not be deferred).
            let writer = inPipe.fileHandleForWriting
            writer.write(Data(prompt.utf8))
            try? writer.close()
        }
    }
}

// MARK: - Stream state (thread-safe)

/// Line-buffers Command Code's NDJSON stdout. Answer text arrives as
/// `{"type":"event","event":{"type":"text_delta","delta":…}}` (token-level, so this
/// stream yields as it types); `thinking_delta` is reasoning we drop; the terminal
/// `{"type":"result",…}` line carries the verdict (`subtype`), the whole answer
/// (`finalText`) and, on failure, `error`. Lock-guarded — the readability and
/// termination handlers run on different queues. Mirrors `GrokStreamState`.
private final class CommandCodeStreamState {
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrTail = ""
    private var yieldedAny = false
    private var failure: String?
    private var finalText: String?

    struct Snapshot {
        let yieldedAny: Bool
        let failure: String?
        let finalText: String?
        let stderrTail: String
    }

    /// Append `data` and return the answer-text deltas in newly-completed lines.
    func ingest(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        stdoutBuffer.append(data)
        var out: [String] = []
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }
            switch type {
            case "event":
                guard let event = obj["event"] as? [String: Any] else { continue }
                // One `model_request_end` per model call, carrying that call's
                // real usage — Stats' token figure is the sum of these and
                // nothing else (see `TokenMeter`).
                if event["type"] as? String == "model_request_end",
                   let usage = event["usage"] as? [String: Any] {
                    TokenMeter.shared.record(input: usage["inputTokens"] as? Int ?? 0,
                                             output: usage["outputTokens"] as? Int ?? 0)
                }
                guard event["type"] as? String == "text_delta",
                      let delta = event["delta"] as? String, !delta.isEmpty
                else { continue }
                yieldedAny = true
                out.append(delta)
            case "result":
                finalText = obj["finalText"] as? String
                let subtype = obj["subtype"] as? String
                if subtype == "error" {
                    failure = (obj["error"] as? String)
                        .flatMap { $0.isEmpty ? nil : $0 } ?? "unknown error"
                }
            default:
                break   // forward-compatible: unknown top-level shapes are ignored
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
                        finalText: finalText, stderrTail: tail)
    }
}

// MARK: - Errors

/// User-facing failures from the Command Code path. Mirrors `GrokError`, plus the
/// two failures an aggregator has that a single-vendor CLI doesn't: a rate limit and
/// a spent balance.
enum CommandCodeError: LocalizedError {
    case notInstalled
    case notSignedIn
    case authExpired
    case rateLimited
    case outOfCredits
    case spawnFailed(String)
    case runFailed(String)
    case noOutput

    /// The CLI's documented exit codes — the most reliable classifier it offers,
    /// since the human-readable reason is free text that changes with every release.
    /// (`3` not authenticated, `5` rate limited, `9` no response, `10` out of credits.)
    private enum Exit {
        static let auth: Int32 = 3
        static let rateLimit: Int32 = 5
        static let noResponse: Int32 = 9
        static let credits: Int32 = 10
    }

    /// Whether a CLI failure string is the broken-sign-in class. Backstop for the
    /// exit code, which a killed / timed-out process never delivers.
    static func isAuthFailure(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("cmd login")
            || m.contains("not authenticated")
            || m.contains("unauthenticated")
            || m.contains("failed to authenticate")
            || m.contains("invalid api key")
            || (m.contains("session") && m.contains("expired"))
    }

    /// Wrap a CLI failure in the right case: the exit code decides when it says
    /// something (auth / rate limit / credits are all actionable in a way the raw
    /// text is not), otherwise the message is classified by wording and, failing
    /// that, surfaced verbatim.
    static func classify(_ message: String, exitCode: Int32 = 0) -> CommandCodeError {
        switch exitCode {
        case Exit.auth:      return .authExpired
        case Exit.rateLimit: return .rateLimited
        case Exit.credits:   return .outOfCredits
        case Exit.noResponse where message.isEmpty: return .noOutput
        default: break
        }
        if isAuthFailure(message) { return .authExpired }
        return .runFailed(message)
    }

    var errorDescription: String? {
        switch self {
        case .notInstalled: return L("commandcode.error.notInstalled")
        case .notSignedIn:  return L("commandcode.error.notSignedIn")
        case .authExpired:  return L("commandcode.error.authExpired")
        case .rateLimited:  return L("commandcode.error.rateLimited")
        case .outOfCredits: return L("commandcode.error.outOfCredits")
        case .noOutput:     return L("commandcode.error.noOutput")
        case .spawnFailed(let d):
            let base = L("commandcode.error.spawnFailed")
            return d.isEmpty ? base : "\(base) (\(d))"
        case .runFailed(let d):
            let base = L("commandcode.error.runFailed")
            return d.isEmpty ? base : "\(base) \(d)"
        }
    }
}
