import Foundation

/// A chat backend on the user's own **Command Code** account (commandcode.ai), plus
/// the CLI-side plumbing the agent engine and the picker use.
///
/// Notch holds no key of its own: a chat turn uses the key `cmd login` stored in
/// `~/.commandcode/auth.json` (or `COMMAND_CODE_API_KEY`) and bills against the
/// user's own plan. Sign-in stays in the user's terminal: `cmd login` is an
/// interactive TUI, so the account row tells the user to run it there.
///
/// Command Code is an **aggregator** (one account fronts ~50 models across
/// Anthropic / OpenAI / Google / xAI / Qwen / Kimi / GLM / DeepSeek / …). The model
/// list comes from the installed CLI (`cmd --list-models`), never a bundled table.
///
/// **Chat goes straight to the gateway.** A turn is one `POST /alpha/generate`, the
/// endpoint `cmd` itself calls (the Go plan has no Provider API access), with the
/// conversation as real messages, Notch's system prompt as `system`, and Notch's
/// own tools driven by `AgentHarness`. The earlier shape, one `cmd -p` process per
/// turn, cost a Node boot (~1.1s) and wrapped every question in the CLI's agent
/// prompt (~14k input tokens for "say hi"); measured 2026-10-20 on
/// `deepseek-v4.1-flash`, first text came at 7–30s through `cmd -p` against ~2s
/// direct. Same approach as `@jiesou/dsh-commandcode-go-provider`.
///
/// The agent engine (`AgentEngine.commandCode`) still runs the CLI: there the
/// CLI's own agent loop, tools and sessions are the point.
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

    /// Switch for the whole integration. With this true, nothing lists Command
    /// Code, nothing spawns `cmd`, and the engine reads as *resolved* unavailable —
    /// the difference that matters, because a remembered pick only repoints itself
    /// off a resolved "no" (see `AgentEngine.isKnownUnavailable`), never off a
    /// probe still in flight.
    static let isRetired = false

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
        guard !isRetired else { return nil }
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
    /// This is the render-safe read: warming up off-main only moves who holds
    /// `resolveLock`, so a `body` calling `resolveBinary()` during the launch probe
    /// (`cmd --list-models`, seconds long) would block the first hover after a
    /// relaunch for the whole spawn.
    static func resolvedBinaryIfReady() -> String? {
        guard !isRetired else { return nil }
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
        // Retired is a FINAL no, not a pending one — see `isRetired`.
        if isRetired { return true }
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
        guard !isRetired else { return }
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

    /// Manual re-detection (the arrow on the Settings account row). The resolution is
    /// otherwise cached for the whole process, so a CLI installed or repaired after
    /// launch stays invisible until a relaunch. This probes the candidates again off
    /// the main thread and swaps the answer in only once it lands, so the row keeps
    /// showing the old state during the multi-second `--list-models` spawn.
    static func redetect(completion: @escaping () -> Void) {
        guard !isRetired else { completion(); return }
        primeFromDisk()
        DispatchQueue.global(qos: .userInitiated).async {
            let found = locateBinary()
            resolveLock.lock()
            cachedBinary = .some(found)
            seededFromDisk = false
            resolveLock.unlock()
            if found == nil {
                modelLock.lock(); cachedModels = nil; modelLock.unlock()
                forgetStored()
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .cliAvailabilityResolved, object: nil)
                completion()
            }
        }
    }

    // MARK: - Remembering the last launch's answer

    /// Where the previous launch's resolution lives. The vetting spawn,
    /// `cmd --list-models`, takes **8-11 seconds** (network-bound) and answers both
    /// "is it available" and "which models", so without a disk copy every launch
    /// would show Command Code as unconfigured for that long. The answer is written
    /// here and read back at the next launch before anything renders.
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
        guard !isRetired else { return false }
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
    /// backends' picker path. `force` (the manual-refresh route) re-spawns
    /// `--list-models` regardless; a failed probe leaves the cached catalog alone.
    static func refreshModels(force: Bool = false) {
        guard !isRetired else { return }
        modelLock.lock()
        let alreadyHave = (cachedModels?.isEmpty == false)
        modelLock.unlock()
        if alreadyHave, !force { return }
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

    // MARK: - Streaming (direct gateway)

    /// The gateway every Command Code plan answers on. The Go plan has no Provider
    /// API access (`/provider/v1/*` answers 403 `upgrade_required`), so a chat turn
    /// goes to the CLI's own `POST /alpha/generate`, as `cmd` itself does.
    static let gatewayURL = URL(string: "https://api.commandcode.ai/alpha/generate")!

    /// `x-command-code-version` when the installed CLI's `package.json` can't be
    /// read. The gateway refuses a request without a version.
    private static let fallbackCLIVersion = "1.84.0"

    /// Output ceiling sent on every request. The gateway's request schema carries
    /// `max_tokens`, and on a reasoning model it covers reasoning plus answer, so it
    /// is set high enough that nothing reaches it (the CLI sends the same 64000).
    private static let maxTokens = 64_000

    /// How long the response may go without a byte. The gateway holds the
    /// connection open while a reasoning model thinks before its first delta.
    private static let idleTimeout: TimeInterval = 180

    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in gatewayTurn(system: system,
                                                       wireMessages: Self.wireMessages(messages),
                                                       tools: []) {
                        if case .text(let t) = event { continuation.yield(t) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func streamEvents(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in gatewayTurn(system: system,
                                                       wireMessages: Self.wireMessages(messages),
                                                       tools: []) {
                        switch event {
                        case .text(let t): continuation.yield(.text(t))
                        case .reasoningDelta(let t): continuation.yield(.reasoning(t))
                        default: break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One `/alpha/generate` round trip, as harness events. Retries the connect /
    /// first-event phase on a transient failure, only while nothing has reached
    /// the caller (same rule as `AnthropicAIService.streamTurn`).
    fileprivate func gatewayTurn(system: String,
                                 wireMessages: [[String: Any]],
                                 tools: [ToolSpec]) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let apiKey = Self.apiKey() else {
                    continuation.finish(throwing: CommandCodeError.notSignedIn); return
                }
                guard let picked = Self.requestModel(model) else {
                    continuation.finish(throwing: CommandCodeError.runFailed("no model")); return
                }
                let modelID = await Self.wireModelID(picked, apiKey: apiKey)
                let schemas = Dictionary(tools.map { ($0.name, $0.schema) },
                                         uniquingKeysWith: { a, _ in a })
                var emittedAny = false
                var attempt = 0
                while true {
                    do {
                        var req = URLRequest(url: Self.gatewayURL)
                        req.httpMethod = "POST"
                        req.timeoutInterval = Self.idleTimeout
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                        req.setValue(Self.cliVersion, forHTTPHeaderField: "x-command-code-version")
                        req.setValue("production", forHTTPHeaderField: "x-cli-environment")
                        req.setValue("false", forHTTPHeaderField: "x-co-flag")
                        req.httpBody = try JSONSerialization.data(
                            withJSONObject: Self.requestBody(model: modelID, system: system,
                                                             messages: wireMessages, tools: tools),
                            options: [.sortedKeys])

                        let (bytes, response) = try await ProxyConfig.urlSession.bytes(for: req)
                        guard let http = response as? HTTPURLResponse else {
                            throw OpenAICompatAIService.ServiceError.malformedResponse(provider: "Command Code")
                        }
                        guard (200..<300).contains(http.statusCode) else {
                            let body = await OpenAICompatAIService.drainErrorBody(bytes.lines)
                            throw Self.httpError(status: http.statusCode, body: body, response: http)
                        }

                        var reportedReasoning = false
                        var finishReason: String?
                        var terminated = false
                        for try await line in bytes.lines {
                            if Task.isCancelled { break }
                            let trimmed = line.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty, !trimmed.hasPrefix(":"),
                                  let data = trimmed.data(using: .utf8),
                                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  let type = obj["type"] as? String
                            else { continue }
                            switch type {
                            case "text-delta":
                                if let t = obj["text"] as? String, !t.isEmpty {
                                    emittedAny = true
                                    continuation.yield(.text(t))
                                }
                            case "reasoning-delta":
                                if let t = obj["text"] as? String, !t.isEmpty {
                                    if !reportedReasoning {
                                        reportedReasoning = true
                                        continuation.yield(.reasoningStarted)
                                    }
                                    continuation.yield(.reasoningDelta(t))
                                }
                            case "tool-call":
                                // The gateway sends each call whole, arguments included.
                                let name = obj["toolName"] as? String ?? ""
                                guard !name.isEmpty else { break }
                                let id = (obj["toolCallId"] as? String) ?? (obj["id"] as? String)
                                    ?? "call_\(UUID().uuidString.prefix(8))"
                                var input: [String: Any] = [:]
                                if let dict = (obj["input"] ?? obj["args"]) as? [String: Any] {
                                    input = dict
                                } else if let raw = (obj["input"] ?? obj["arguments"]) as? String,
                                          let d = raw.data(using: .utf8),
                                          let dict = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                                    input = dict
                                }
                                if let schema = schemas[name] {
                                    input = Self.dropNullArguments(input, schema: schema) as? [String: Any] ?? input
                                }
                                emittedAny = true
                                continuation.yield(.toolCallStarted(name: name))
                                continuation.yield(.toolCall(id: id, name: name, input: input))
                            case "finish":
                                if let usage = obj["totalUsage"] as? [String: Any] ?? obj["usage"] as? [String: Any] {
                                    TokenMeter.shared.record(input: usage["inputTokens"] as? Int ?? 0,
                                                             output: usage["outputTokens"] as? Int ?? 0)
                                }
                                finishReason = (obj["finishReason"] as? String)
                                    ?? (obj["rawFinishReason"] as? String)
                                terminated = true
                            case "error":
                                throw Self.streamError(obj)
                            default:
                                break
                            }
                            if terminated { break }
                        }
                        if Task.isCancelled { continuation.finish(); return }
                        if !terminated {
                            throw OpenAICompatAIService.ServiceError.cutOff(provider: "Command Code")
                        }
                        if !emittedAny {
                            if attempt < StreamRetry.maxRetries {
                                attempt += 1
                                try await StreamRetry.waitBeforeRetry(attempt)
                                continue
                            }
                            throw CommandCodeError.noOutput
                        }
                        continuation.yield(.finished(stopReason: Self.harnessStopReason(finishReason)))
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        continuation.finish()
                        return
                    } catch {
                        if !emittedAny, attempt < StreamRetry.maxRetries,
                           StreamRetry.isRetryable(error) {
                            attempt += 1
                            do { try await StreamRetry.waitBeforeRetry(attempt, after: error) }
                            catch { continuation.finish(); return }
                            continue
                        }
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Request

    /// The key `cmd login` stored, or `COMMAND_CODE_API_KEY`. Read per request so a
    /// re-login takes effect on the next turn.
    private static func apiKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["COMMAND_CODE_API_KEY"]?
            .trimmingCharacters(in: .whitespaces), !key.isEmpty {
            return key
        }
        guard let data = FileManager.default.contents(atPath: "\(commandCodeHome)/auth.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = (json["apiKey"] as? String)?.trimmingCharacters(in: .whitespaces),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// The model id to send. The sentinel means the CLI's default: the catalog's
    /// `(default)` row, else the model in `~/.commandcode/config.json`.
    private static func requestModel(_ picked: String?) -> String? {
        if let picked { return picked }
        let catalog = defaultModel
        if catalog != defaultSentinel { return catalog }
        guard let data = FileManager.default.contents(atPath: "\(commandCodeHome)/config.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let m = json["model"] as? String, !m.isEmpty
        else { return nil }
        return m
    }

    // MARK: Wire model ids

    /// `cmd --list-models` prints ids lowercased (`moonshotai/kimi-k2.6`) while the
    /// gateway matches them case-sensitively (`moonshotai/Kimi-K2.6`); a lowercased
    /// id answers 403 "Model/provider not recognized". The gateway's own model list
    /// has the exact spelling, so ids are looked up there, case-insensitively.
    static let modelsURL = URL(string: "https://api.commandcode.ai/provider/v1/models")!
    private static let wireIDsKey = "commandcode.wireModelIDs"
    private static let wireIDLock = NSLock()
    /// lowercased id → gateway id. Seeded from the last launch's list.
    private static var wireIDs: [String: String] =
        UserDefaults.standard.dictionary(forKey: wireIDsKey) as? [String: String] ?? [:]
    private static var wireIDsFetched = false

    /// The id the gateway accepts for `id`. Fetches the gateway's list on the first
    /// turn of a process: awaited when nothing is stored yet, otherwise in the
    /// background while the stored list answers. Unknown ids go out unchanged.
    private static func wireModelID(_ id: String, apiKey: String) async -> String {
        let (known, needsFetch) = wireIDLock.withLock {
            defer { wireIDsFetched = true }
            return (wireIDs, !wireIDsFetched)
        }
        if needsFetch {
            if known.isEmpty {
                await fetchWireIDs(apiKey: apiKey)
            } else {
                Task.detached(priority: .utility) { await fetchWireIDs(apiKey: apiKey) }
            }
        }
        return wireIDLock.withLock { wireIDs[id.lowercased()] } ?? id
    }

    private static func fetchWireIDs(apiKey: String) async {
        var req = URLRequest(url: modelsURL)
        req.timeoutInterval = 10
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(cliVersion, forHTTPHeaderField: "x-command-code-version")
        guard let (data, response) = try? await ProxyConfig.urlSession.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]]
        else {
            // Try again on the next turn.
            wireIDLock.withLock { wireIDsFetched = false }
            return
        }
        var map: [String: String] = [:]
        for row in rows {
            if let id = row["id"] as? String, !id.isEmpty { map[id.lowercased()] = id }
        }
        guard !map.isEmpty else { return }
        wireIDLock.withLock { wireIDs = map }
        UserDefaults.standard.set(map, forKey: wireIDsKey)
    }

    private static let versionLock = NSLock()
    private static var cachedVersion: String?

    /// The installed CLI's version, from the `package.json` next to its entry
    /// script, so the gateway sees the same client version `cmd` itself sends.
    private static var cliVersion: String {
        versionLock.lock(); defer { versionLock.unlock() }
        if let cachedVersion { return cachedVersion }
        var version = fallbackCLIVersion
        if let binary = resolvedBinaryIfReady() {
            var dir = URL(fileURLWithPath: binary).resolvingSymlinksInPath().deletingLastPathComponent()
            for _ in 0..<3 {
                let pkg = dir.appendingPathComponent("package.json")
                if let data = FileManager.default.contents(atPath: pkg.path),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["name"] as? String == "command-code",
                   let v = json["version"] as? String, !v.isEmpty {
                    version = v
                    break
                }
                dir = dir.deletingLastPathComponent()
            }
        }
        cachedVersion = version
        return version
    }

    /// The `/alpha/generate` envelope, in the shape the CLI sends. The `config`
    /// block describes an empty workspace: Notch has no project to report.
    private static func requestBody(model: String, system: String,
                                    messages: [[String: Any]], tools: [ToolSpec]) -> [String: Any] {
        #if arch(arm64)
        let environment = "darwin-arm64"
        #else
        let environment = "darwin-x64"
        #endif
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                              formatOptions: [.withFullDate])
        let wireTools: [[String: Any]] = tools.map {
            ["name": $0.name, "description": $0.description,
             "input_schema": clientSchema($0.schema)]
        }
        return [
            "config": [
                "workingDir": NSTemporaryDirectory(),
                "date": day,
                "environment": environment,
                "structure": [String](),
                "isGitRepo": false,
                "currentBranch": "",
                "mainBranch": "",
                "gitStatus": "",
                "recentCommits": [String](),
            ] as [String: Any],
            "memory": "",
            "taste": "",
            "skills": NSNull(),
            "permissionMode": "standard",
            "params": [
                "model": model,
                "messages": messages,
                "tools": wireTools,
                "system": system,
                "max_tokens": maxTokens,
                "stream": true,
            ] as [String: Any],
        ]
    }

    /// Plain chat turns as gateway messages. A text-only turn is a flat string; a
    /// turn with pasted images is a part list, images as data URIs.
    fileprivate static func wireMessages(_ messages: [ChatMessage]) -> [[String: Any]] {
        messages.map { m in
            guard m.role == "user", !m.images.isEmpty else {
                return ["role": m.role, "content": m.content]
            }
            var parts: [[String: Any]] = m.images.map {
                ["type": "image",
                 "image": "data:\($0.mediaType);base64,\($0.base64)",
                 "mimeType": $0.mediaType]
            }
            if !m.content.isEmpty { parts.append(["type": "text", "text": m.content]) }
            return ["role": "user", "content": parts]
        }
    }

    /// Harness conversation as gateway messages. A tool call is an assistant
    /// `tool-call` part; its result is a `tool` turn whose `tool-result` names the
    /// same call id and tool.
    fileprivate static func wireMessages(_ messages: [AgentMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var toolNames: [String: String] = [:]
        for m in messages {
            switch m.kind {
            case .text(let role, let text):
                out.append(["role": role, "content": text])
            case .assistantToolCalls(let text, let calls):
                var parts: [[String: Any]] = []
                if !text.isEmpty { parts.append(["type": "text", "text": text]) }
                for c in calls {
                    toolNames[c.id] = c.name
                    parts.append(["type": "tool-call", "toolCallId": c.id,
                                  "toolName": c.name, "input": c.input])
                }
                out.append(["role": "assistant", "content": parts])
            case .toolResults(let results):
                let parts: [[String: Any]] = results.map { r in
                    let value = r.result.isEmpty ? (r.isError ? "Execution denied" : "(no output)") : r.result
                    return ["type": "tool-result", "toolCallId": r.id,
                            "toolName": toolNames[r.id] ?? r.name,
                            "output": ["type": r.isError ? "error-text" : "text", "value": value]]
                }
                out.append(["role": "tool", "content": parts])
            }
        }
        return out
    }

    // MARK: Tool schemas

    /// The gateway forwards tools to OpenAI-style function calling with `strict`
    /// left at its default (true), so the upstream treats every declared property
    /// as required and invents values for optional ones. Optional properties are
    /// therefore sent as nullable, and `dropNullArguments` removes the nulls from
    /// the model's call. Ported from `@jiesou/dsh-commandcode-go-provider`.
    private static let nullArgumentHint =
        "Leave this out by passing null unless you need a value other than the default."

    private static func allowsNull(_ schema: Any) -> Bool {
        guard let s = schema as? [String: Any] else { return false }
        if let t = s["type"] as? String, t == "null" { return true }
        if let t = s["type"] as? [String], t.contains("null") { return true }
        if s.keys.contains("const"), s["const"] is NSNull { return true }
        if let e = s["enum"] as? [Any], e.contains(where: { $0 is NSNull }) { return true }
        if let any = s["anyOf"] as? [Any] { return any.contains(where: allowsNull) }
        return false
    }

    private static func optionalAsNull(_ property: [String: Any]) -> [String: Any] {
        var described = property
        if let d = property["description"] as? String, !d.isEmpty {
            described["description"] = "\(d) \(nullArgumentHint)"
        } else {
            described["description"] = nullArgumentHint
        }
        return ["anyOf": [described,
                          ["type": "null", "description": "Use null when you do not need this argument."]]]
    }

    static func clientSchema(_ parameters: Any) -> Any {
        guard let params = parameters as? [String: Any] else { return parameters }
        var schema = params
        if let properties = params["properties"] as? [String: Any] {
            let required = Set(params["required"] as? [String] ?? [])
            var out: [String: Any] = [:]
            for (name, property) in properties {
                let declared = clientSchema(property)
                if !required.contains(name), let dict = declared as? [String: Any], !allowsNull(dict) {
                    out[name] = optionalAsNull(dict)
                } else {
                    out[name] = declared
                }
            }
            schema["properties"] = out
        }
        if let items = params["items"] { schema["items"] = clientSchema(items) }
        if let any = params["anyOf"] as? [Any] { schema["anyOf"] = any.map(clientSchema) }
        return schema
    }

    static func dropNullArguments(_ value: Any, schema: Any?) -> Any {
        let s = schema as? [String: Any]
        if let array = value as? [Any] {
            return array.map { dropNullArguments($0, schema: s?["items"]) }
        }
        guard let dict = value as? [String: Any] else { return value }
        let properties = s?["properties"] as? [String: Any]
        let required = Set(s?["required"] as? [String] ?? [])
        var out: [String: Any] = [:]
        for (name, entry) in dict {
            if entry is NSNull, let declared = properties?[name],
               !required.contains(name), !allowsNull(declared) {
                continue
            }
            out[name] = dropNullArguments(entry, schema: properties?[name])
        }
        return out
    }

    // MARK: Response

    /// The gateway's finish reasons in the spelling the harness checks.
    private static func harnessStopReason(_ raw: String?) -> String? {
        switch raw {
        case "tool-calls": return "tool_calls"
        case "max-output-tokens", "max_tokens": return "max_tokens"
        default: return raw
        }
    }

    /// The readable part of a gateway error body: `{"error":{"message","code"}}`,
    /// or the body itself when it is not that shape (an edge HTML page is dropped).
    private static func errorDetail(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return trimmed.hasPrefix("<") ? "" : String(trimmed.prefix(400)) }
        let envelope = json["error"] as? [String: Any] ?? json
        if let m = envelope["message"] as? String, !m.isEmpty { return m }
        if let m = json["error"] as? String, !m.isEmpty { return m }
        return String(trimmed.prefix(400))
    }

    /// A non-2xx answer. 429 and 5xx stay `ServiceError.http` so `StreamRetry`
    /// retries them; the rest map to the Command Code cases the UI already explains.
    private static func httpError(status: Int, body: String, response: HTTPURLResponse) -> Error {
        let detail = errorDetail(body)
        switch status {
        case 401: return CommandCodeError.authExpired
        case 402: return CommandCodeError.outOfCredits
        case 429, 500..<600:
            return OpenAICompatAIService.ServiceError.http(provider: "Command Code", status: status,
                                                           body: body,
                                                           retryAfter: StreamRetry.retryAfter(response))
        default:
            if CommandCodeError.isAuthFailure(detail) { return CommandCodeError.authExpired }
            return CommandCodeError.runFailed(detail.isEmpty ? "HTTP \(status)" : detail)
        }
    }

    /// An in-stream `{"type":"error","error":{message,statusCode,responseBody}}`,
    /// sent when the upstream fails after the headers went out.
    private static func streamError(_ event: [String: Any]) -> Error {
        let error = event["error"] as? [String: Any] ?? event
        let status = error["statusCode"] as? Int
        var message = (error["message"] as? String) ?? ""
        if message.isEmpty, let body = error["responseBody"] as? String { message = errorDetail(body) }
        if status == 429 { return CommandCodeError.rateLimited }
        if status == 402 { return CommandCodeError.outOfCredits }
        if status == 401 || CommandCodeError.isAuthFailure(message) { return CommandCodeError.authExpired }
        return CommandCodeError.runFailed(message.isEmpty ? "unknown error" : message)
    }
}

extension CommandCodeCLIService: AgentCapableService {
    /// `requiredTool` is ignored: the gateway envelope has no `tool_choice` field.
    func streamTurn(system: String,
                    messages: [AgentMessage],
                    tools: [ToolSpec],
                    requiredTool: String?) -> AsyncThrowingStream<TurnEvent, Error> {
        gatewayTurn(system: system, wireMessages: Self.wireMessages(messages), tools: tools)
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
