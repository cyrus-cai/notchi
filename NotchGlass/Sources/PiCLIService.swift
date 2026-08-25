import Foundation

/// A model backend that shells out to the user's locally-installed **pi** CLI
/// (`pi -p --mode json`) and streams its answer back — the fifth of the same family
/// as `CodexCLIService` / `ClaudeCLIService` / `GrokCLIService` /
/// `CommandCodeCLIService`.
///
/// Like the other four, pi carries **no API key of ours**: it reuses whatever the
/// user already signed in with (`/login` inside pi's own TUI → OAuth tokens in
/// `~/.pi/agent/auth.json`, or any of the ~40 provider API-key env vars pi reads).
/// Usage bills against the user's own accounts — the whole point of a "use the CLI I
/// already pay for" backend.
///
/// What makes it different from its four siblings: pi is a **multi-account
/// aggregator**. Command Code fronts ~50 models under ONE account; pi fronts every
/// provider the user has separately signed into — a ChatGPT subscription, a Claude
/// Pro plan, a Command Code account, an xAI key — side by side in a single catalog.
/// So a pi model is only fully named by the pair *(provider, model)*: this Mac's
/// catalog carries `gpt-5.4` twice, once under `commandcode` and once under
/// `openai-codex`. The ids this service hands the rest of the app are therefore
/// `"<pi-provider>/<model-id>"`, split back apart into `--provider` / `--model` at
/// spawn time (see `spawnArgs`).
///
/// **Compliance posture (mirrors the other CLI backends):** only the official binary
/// is ever executed. Notch speaks no HTTP to any pi provider, never reads the tokens
/// in `~/.pi/agent/auth.json`, and offers **no in-app sign-in**: pi's `/login` is a
/// slash command inside its interactive TUI (an ink app reading a real TTY), so like
/// Claude Code and Command Code — and unlike `grok login` — it cannot be driven
/// headlessly. The account row tells the user to run `pi` in their own terminal.
///
/// Shape of the integration (mirrors the twins):
///  · one turn = one `pi -p` process; the running conversation is folded into a
///    single stdin prompt. The persona rides `--system-prompt` (pi's documented
///    flag), so the prompt carries only the folded conversation.
///  · `--mode json` prints NDJSON: a `{"type":"session",…}` header, then
///    `{"type":"message_update","assistantMessageEvent":{"type":"text_delta",…}}`
///    answer deltas (token-level, so this stream yields as it types), interleaved
///    `thinking_delta` reasoning we drop, and `{"type":"message_end",…}` frames
///    carrying the turn's real usage. See pi's own `docs/json.md`.
///  · a chat turn runs with **no tools at all** (`-nt`). pi's built-ins are
///    `read`/`write`/`edit`/`bash`/`ls`/`grep`/`find` — a filesystem/shell set with
///    no web search in it, so none of it can help answer a chat question and all of
///    it would run unattended. `--no-extensions` / `--no-skills` /
///    `--no-context-files` / `--no-prompt-templates` / `--no-themes` /
///    `--no-approve` plus an ephemeral cwd keep the turn out of the user's own pi
///    configuration, and `--no-session` keeps quick chats out of their history.
///
/// pi runs its own agent loop internally, so this conforms to `AIService` only —
/// like the twins it deliberately does NOT adopt the tool harness. Note that pi is
/// the one CLI backend with **no web search of any kind** (see
/// `Provider.supportsWebSearch`), so a pi chat answers from training data alone.
struct PiCLIService: AIService {
    /// The `"<pi-provider>/<model-id>"` pick, or `nil` for "pi's own configured
    /// default" (no `--provider` / `--model` flags at all).
    let model: String?

    /// The picker's row carries the id "pi" — a sentinel for "the CLI's own default",
    /// not a real model. Normalize that (and empty) to `nil`.
    init(model: String? = nil) {
        let m = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = (m.isEmpty || m == Self.defaultSentinel) ? nil : m
    }

    /// The "use the CLI's own default model" placeholder id, used wherever a real
    /// model id is expected before the catalog read lands.
    static let defaultSentinel = "pi"

    // MARK: - Availability

    /// Absolute paths the CLI lives at, in priority order. `pi` is an npm global, so
    /// there is no product-named installer directory to look in first — and `pi` is
    /// a two-letter name anything could take, which is why the smoke test below
    /// decides rather than the name (see `locateBinary`).
    private static let candidatePaths: [String] = {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin/pi",
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
        ]
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

    /// The resolved pi binary path, or `nil` if none works. Cached.
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
    /// already landed, else `nil` (and a warm-up kicked off), never a block. The
    /// render-safe read — `pi --list-models` is a Node cold start plus a catalog
    /// refresh (~2s measured), exactly the spawn
    /// `CommandCodeCLIService.resolvedBinaryIfReady()` exists to keep out of `body`.
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

    /// Where the previous launch's resolution lives. Same reasoning as
    /// `CommandCodeCLIService`'s: everything about this engine — is it available,
    /// which models does it serve, which of them take a thinking level — comes from
    /// one ~2s spawn, so with an in-memory-only cache every launch would have a
    /// two-second window where pi read as unconfigured (missing from the agent
    /// picker, its chip falling back to the bare engine name). Writing the answer
    /// down closes that window.
    ///
    /// pi's catalog is more volatile than Command Code's, though: it is not baked
    /// into the CLI build but assembled from *which providers the user is signed
    /// into*, and a `/login` in another terminal changes it without touching the
    /// binary. So the fingerprint below is a floor, not the freshness mechanism —
    /// the short TTL is.
    private static let storedPathKey = "pi.binaryPath"
    private static let storedCatalogKey = "pi.catalog"
    private static let storedFingerprintKey = "pi.catalog.fingerprint"
    private static let storedFetchedAtKey = "pi.catalog.fetchedAt"
    /// Half a day. Short precisely because signing into a new provider is a normal
    /// thing to do between launches and must not take a week to show up; a relaunch
    /// re-probes anyway, so this only bounds a long-lived session.
    private static let catalogTTL: TimeInterval = 12 * 3600

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
    /// executable"; whether it is still a working pi build, and whether its catalog
    /// still looks like this, is settled in the background by `revalidateSeed()`.
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
    }

    /// Re-vet the remembered binary off-main, and re-read its catalog when there is
    /// anything new to learn: the binary changed (an npm update), or the seed has
    /// aged past the TTL (the user may have signed into another provider).
    ///
    /// If the remembered binary has stopped answering — uninstalled, replaced by
    /// something else wearing the two-letter `pi` name, broken by a bad update — the
    /// seed is thrown away and the full resolution runs, exactly as a cold launch
    /// would.
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
            resolveLock.lock(); seededFromDisk = false; resolveLock.unlock()
            return
        }
        // The remembered install is gone or no longer pi — forget it whole (path AND
        // catalog) and resolve from scratch.
        resolveLock.lock()
        cachedBinary = nil
        seededFromDisk = false
        resolveLock.unlock()
        modelLock.lock(); cachedModels = nil; modelLock.unlock()
        forgetStored()
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
    /// modification date, taken through any symlink. pi installs as a `bin/pi` shim
    /// pointing at the package's `dist/cli.js`, and it is the *target* an update
    /// rewrites — a fingerprint of the link itself would never move.
    private static func fingerprint(of path: String) -> String? {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: real),
              let size = attrs[.size] as? Int
        else { return nil }
        let stamp = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(real)|\(size)|\(Int(stamp))"
    }

    /// One catalog row as a line. Tab-separated because a provider slug and a model
    /// id can both carry slashes and dashes, but neither carries a tab.
    private static func encode(_ e: CatalogEntry) -> String {
        "\(e.provider)\t\(e.model)\t\(e.thinking ? "1" : "0")"
    }

    private static func decode(_ line: String) -> CatalogEntry? {
        let parts = line.components(separatedBy: "\t")
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return CatalogEntry(provider: parts[0], model: parts[1], thinking: parts[2] == "1")
    }

    /// Find the binary by *identity*, not by name. Every candidate is asked for its
    /// model catalog (`--list-models`); only a process that exits cleanly AND prints
    /// something pi prints is accepted. That matters for `pi`, a two-letter name any
    /// tool could have claimed — and it is free, because the same spawn fills the
    /// model cache the picker needs (one process, both answers).
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
        if let p = ShellEnvironment.which(["pi"]), let models = probeModels(p) {
            adopt(models)
            remember(path: p, models: models)
            return p
        }
        return nil
    }

    /// Whether the user has signed pi into anything. pi's `--list-models` lists
    /// **only** models whose credentials are configured (docs/models.md: "If no auth
    /// is configured, the models load but stay unavailable in `/model` and
    /// `--list-models`"), so a non-empty catalog *is* the sign-in check — and it is
    /// the only one that can be right, given pi reads ~40 different env vars and an
    /// OAuth store. The tokens in `~/.pi/agent/auth.json` are never read.
    static func authExists() -> Bool { !fetchedModels().isEmpty }

    /// Whether pi can actually answer right now: the binary resolves AND at least one
    /// provider is signed in. Drives the picker (the provider is selectable only when
    /// true) and the Settings status row.
    ///
    /// Reads the resolution **non-blockingly** — this is called from `body`. Until the
    /// launch probe lands it answers "no"; `.cliAvailabilityResolved` then redraws
    /// whoever asked.
    static var isAvailable: Bool { resolvedBinaryIfReady() != nil && authExists() }

    /// Whether the binary is installed, regardless of sign-in — what the Settings
    /// account row needs to tell "install pi" apart from "run `/login` in pi".
    static var isInstalled: Bool { resolvedBinaryIfReady() != nil }

    // MARK: - Model catalog

    /// One row of `pi --list-models`.
    struct CatalogEntry {
        /// pi's provider slug (`commandcode`, `openai-codex`, `anthropic`, `xai`, …) —
        /// the `--provider` value.
        let provider: String
        /// The model id *within* that provider — the `--model` value. May itself
        /// contain slashes (`deepseek/deepseek-v4-flash`).
        let model: String
        /// Whether the catalog marks this model as supporting extended thinking —
        /// the gate for offering `--thinking` rungs (see `AgentEffortCatalog`).
        let thinking: Bool

        /// The app-level id: provider and model are only unique together (this Mac's
        /// catalog carries `gpt-5.4` under two providers).
        var id: String { "\(provider)/\(model)" }
    }

    private static let modelLock = NSLock()
    /// The signed-in providers' models, from the catalog the resolved binary printed.
    /// `nil` = not read yet; an empty array = read but nothing available, so we fall
    /// back to the sentinel and don't re-scan on every render.
    private static var cachedModels: [CatalogEntry]?

    private static func adopt(_ models: [CatalogEntry]) {
        modelLock.lock(); cachedModels = models; modelLock.unlock()
    }

    private static func fetchedModels() -> [CatalogEntry] {
        modelLock.lock(); defer { modelLock.unlock() }
        return cachedModels ?? []
    }

    /// Every model id pi offers, for the picker. Falls back to the single sentinel
    /// (→ pi's own configured default, no flags) until the catalog read lands.
    static var availableModelIDs: [String] {
        let models = fetchedModels()
        return models.isEmpty ? [defaultSentinel] : models.map(\.id)
    }

    /// id + display name for the agent picker's rows. The catalog prints no display
    /// names, so the app's own id→name shaping does the work — on the model half of
    /// the id, since the provider half is routing, not a name.
    static var listedModels: [(id: String, displayName: String)] {
        fetchedModels().map { ($0.id, displayName(forID: $0.id)) }
    }

    /// The row/chip title for a pi id: the model, then the account it runs through
    /// (`commandcode/claude-opus-5` → "Claude-opus-5 · commandcode").
    ///
    /// Every row names its provider, not just the ones that collide. Which account
    /// serves a model is a different bill and a different rate limit — `gpt-5.4`
    /// through Command Code and `gpt-5.4` through a ChatGPT subscription are not
    /// interchangeable — and a suffix that appears only on the duplicates makes the
    /// bare rows read as "no account in particular" rather than as the one account
    /// they actually are. Say whose it is on every row.
    static func displayName(forID id: String) -> String {
        guard let slash = id.firstIndex(of: "/") else { return ModelRatings.prettyName(for: id) }
        let provider = String(id[..<slash])
        return "\(shortDisplayName(forID: id)) · \(provider)"
    }

    /// The same title without the account — what the **chips** wear (the Settings
    /// model chip, the compose chip, a shortcut's pin). A chip is one line naming
    /// what answers right now, next to a Provider row that already says pi; the
    /// account belongs in the list you pick from, not in the badge you end up with.
    static func shortDisplayName(forID id: String) -> String {
        guard let slash = id.firstIndex(of: "/") else { return ModelRatings.prettyName(for: id) }
        return ModelRatings.prettyName(for: String(id[id.index(after: slash)...]))
    }

    /// The model a flag-less run uses: whatever `~/.pi/agent/settings.json` names,
    /// else the first catalog row, else the sentinel.
    static var defaultModel: String {
        let models = fetchedModels()
        if let configured = readConfiguredModel(),
           models.isEmpty || models.contains(where: { $0.id == configured }) {
            return configured
        }
        return models.first?.id ?? defaultSentinel
    }

    /// Whether this pick takes a `--thinking` level, per the catalog's own column.
    /// An unknown id (a stale pin, or the sentinel before the catalog lands) answers
    /// false — no rung is offered rather than one that might be refused.
    static func supportsThinking(_ id: String?) -> Bool {
        guard let id, id != defaultSentinel else {
            return fetchedModels().first { $0.id == defaultModel }?.thinking ?? false
        }
        return fetchedModels().first { $0.id == id }?.thinking ?? false
    }

    /// The vendor label for a pi id — the key `VendorLogos` looks a mark up by.
    ///
    /// The leading segment is pi's *provider slug*, which is routing rather than a
    /// brand: `commandcode/deepseek/deepseek-v4-flash` is a DeepSeek model reached
    /// through a Command Code account, and stamping it with Command Code's mark
    /// would be exactly the house-brand mislabelling the Command Code integration
    /// avoids. So the slug is dropped and the rest of the id — which always names
    /// its own vendor — is asked. A slug that fronts its own models only
    /// (`openai-codex/gpt-5.4`) still resolves right, because the model half does.
    static func vendor(forID id: String) -> String {
        guard let slash = id.firstIndex(of: "/") else {
            return ModelRatings.vendor(for: id)
        }
        let rest = String(id[id.index(after: slash)...])
        let resolved = ModelRatings.vendor(for: rest)
        if !resolved.isEmpty { return resolved }
        // The model half named nobody (a bare `inkling`, a local llama.cpp id) — fall
        // back to the provider slug, which at least says where it came from.
        let slug = String(id[..<slash])
        return ModelRatings.vendorNames[slug.lowercased()] ?? slug.capitalized
    }

    /// Re-read the catalog off the main thread. No-op once populated — a relaunch
    /// re-resolves, and `revalidateSeed` handles the TTL. Kept for parity with the
    /// other CLI backends' picker path. `force` (the manual-refresh route) re-spawns
    /// `--list-models` regardless; a failed probe leaves the cached catalog alone.
    static func refreshModels(force: Bool = false) {
        modelLock.lock()
        let alreadyHave = (cachedModels?.isEmpty == false)
        modelLock.unlock()
        if alreadyHave, !force { return }
        guard let binary = resolveBinary(), let models = probeModels(binary) else { return }
        adopt(models)
        remember(path: binary, models: models)
    }

    /// Spawn `<binary> --list-models` and parse its catalog. `nil` means "this is not
    /// a working pi binary" — a non-zero exit, or output that doesn't look like
    /// either thing pi prints (which is how the two-letter `pi` name is vetted).
    ///
    /// The printed shape is a header row then one row per available model, columns
    /// separated by runs of spaces:
    ///
    ///     provider      model                       context  max-out  thinking  images
    ///     commandcode   claude-opus-5               1M       65.5K    yes       yes
    ///     openai-codex  gpt-5.4                     272K     128K     yes       yes
    ///
    /// A pi that is installed but signed into nothing prints "No models available."
    /// instead — still proof of identity, and an EMPTY catalog rather than a failed
    /// resolution, which is what lets the Settings row say "installed, not signed in".
    private static func probeModels(_ path: String) -> [CatalogEntry]? {
        // No `--offline` here, deliberately: this is the one spawn that SHOULD be
        // allowed to refresh the provider catalogs it caches.
        let p = ShellEnvironment.makeProcess(path, ["--list-models"])
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        // Signed into nothing — a real pi, an empty catalog.
        if text.contains("No models available") { return [] }
        let models = parseCatalog(text)
        // Neither marker: not pi (or too broken to pick from).
        return models.isEmpty ? nil : models
    }

    /// Parse `--list-models` output. Exposed as a pure function of a string because
    /// the column format is the one brittle seam in this file — same treatment as
    /// `CommandCodeCLIService.parseCatalog`.
    static func parseCatalog(_ text: String) -> [CatalogEntry] {
        var out: [CatalogEntry] = []
        var sawHeader = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let cols = String(raw)
                .components(separatedBy: "  ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // The header names the columns; everything before it is noise (a warning,
            // an update banner), everything after it is a row.
            guard sawHeader else {
                if cols.first == "provider", cols.dropFirst().first == "model" {
                    sawHeader = true
                }
                continue
            }
            // provider · model · context · max-out · thinking · images
            guard cols.count >= 5,
                  !cols[0].contains(" "), !cols[1].contains(" ")
            else { continue }
            out.append(CatalogEntry(provider: cols[0], model: cols[1],
                                    thinking: cols[4].lowercased() == "yes"))
        }
        return out
    }

    /// The `defaultProvider` / `defaultModel` pair pi records in
    /// `~/.pi/agent/settings.json` — what a flag-less `pi` actually runs. `nil` when
    /// the file is missing or names only half the pair.
    private static func readConfiguredModel() -> String? {
        let path = "\(NSHomeDirectory())/.pi/agent/settings.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = json["defaultProvider"] as? String, !provider.isEmpty,
              let model = json["defaultModel"] as? String, !model.isEmpty
        else { return nil }
        return "\(provider)/\(model)"
    }

    // MARK: - Spawn arguments

    /// The `--provider` / `--model` pair for an app-level id, or `[]` for the
    /// sentinel / an unset pick (→ pi's own configured default). Splitting on the
    /// FIRST slash is what makes `commandcode/deepseek/deepseek-v4-flash` resolve to
    /// provider `commandcode`, model `deepseek/deepseek-v4-flash`.
    static func modelArgs(for id: String?) -> [String] {
        guard let id, !id.isEmpty, id != defaultSentinel else { return [] }
        guard let slash = id.firstIndex(of: "/") else { return ["--model", id] }
        let provider = String(id[..<slash])
        let model = String(id[id.index(after: slash)...])
        guard !provider.isEmpty, !model.isEmpty else { return ["--model", id] }
        return ["--provider", provider, "--model", model]
    }

    // MARK: - Streaming

    /// How long a single turn may run before we terminate it. pi is agentic, so this
    /// is generous — the real stop signal is the surrounding `Task` being cancelled
    /// when the panel closes.
    private static let timeout: TimeInterval = 180

    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let binary = Self.resolveBinary() else {
                continuation.finish(throwing: PiError.notInstalled); return
            }
            guard Self.authExists() else {
                continuation.finish(throwing: PiError.notSignedIn); return
            }

            // The persona rides --system-prompt, so the folded prompt is the
            // conversation alone (reuse Codex's folding, minus system).
            let prompt = CodexCLIService.composePrompt(system: "", messages: messages)
            let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("notch-pi-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            // Everything explicit — never inherited from the user's own pi setup:
            // no tools at all (pi's built-ins are filesystem/shell, none of which can
            // answer a chat question), no skills / AGENTS.md / prompt templates /
            // themes, no project-local trust, no saved session, and an empty cwd.
            // `--offline` keeps a startup version check off the turn's critical path
            // (the twin of the other CLIs' --no-auto-update).
            //
            // `--no-extensions` is deliberately NOT here, and must not be added: in
            // pi an extension package is how a *provider* is registered, not just a
            // tool. Passing it kills the very model the user picked — verified live,
            // where `--no-extensions --provider commandcode` died with
            // `Unknown provider "commandcode"`. The reason it was wanted (a project's
            // own extension code running unbidden) is already covered twice over —
            // `-nt` disables extension tools along with the built-ins, and the cwd is
            // an empty temp dir with `--no-approve` on top.
            var args = ["-p", "--mode", "json",
                        "--no-session", "-nt",
                        "--no-skills", "--no-context-files",
                        "--no-prompt-templates", "--no-themes",
                        "--no-approve", "--offline",
                        "--system-prompt", system]
            args += Self.modelArgs(for: model)

            let process = ShellEnvironment.makeProcess(binary, args, cwd: workDir)

            let outPipe = Pipe(), inPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardInput = inPipe
            process.standardError = errPipe

            let state = PiStreamState()

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
                    continuation.finish(throwing: PiError.classify(msg))
                } else if snapshot.yieldedAny {
                    continuation.finish()
                } else if let tail = snapshot.finalText, !tail.isEmpty {
                    // A run whose answer never arrived as deltas (a short reply the
                    // provider returned whole) still has its text on the final message.
                    continuation.yield(tail)
                    continuation.finish()
                } else if proc.terminationStatus != 0 {
                    continuation.finish(throwing: PiError.classify(snapshot.stderrTail))
                } else {
                    continuation.finish(throwing: PiError.noOutput)
                }
            }

            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }

            do {
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: workDir)
                continuation.finish(throwing: PiError.spawnFailed(error.localizedDescription))
                return
            }

            // `-p` with no positional message reads the prompt from stdin.
            let writer = inPipe.fileHandleForWriting
            writer.write(Data(prompt.utf8))
            try? writer.close()
        }
    }
}

// MARK: - Stream state (thread-safe)

/// Line-buffers pi's `--mode json` NDJSON stdout. Answer text arrives as
/// `{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":…}}`
/// (token-level, so this stream yields as it types); `thinking_delta` is reasoning we
/// drop; the assistant's `{"type":"message_end",…}` carries the authoritative text,
/// the turn's usage, and — when the provider refused — `stopReason: "error"` plus an
/// `errorMessage`. Lock-guarded: the readability and termination handlers run on
/// different queues. Mirrors `CommandCodeStreamState`.
private final class PiStreamState {
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
            case "message_update":
                guard let event = obj["assistantMessageEvent"] as? [String: Any],
                      event["type"] as? String == "text_delta",
                      let delta = event["delta"] as? String, !delta.isEmpty
                else { continue }
                yieldedAny = true
                out.append(delta)
            case "message_end":
                guard let message = obj["message"] as? [String: Any],
                      message["role"] as? String == "assistant"
                else { continue }
                // One `message_end` per model call, carrying that call's real usage —
                // Stats' token figure is the sum of these and nothing else.
                if let usage = message["usage"] as? [String: Any] {
                    TokenMeter.shared.record(input: usage["input"] as? Int ?? 0,
                                             output: usage["output"] as? Int ?? 0)
                }
                if let text = Self.text(in: message["content"]), !text.isEmpty {
                    finalText = text
                }
                if message["stopReason"] as? String == "error" {
                    failure = (message["errorMessage"] as? String)
                        .flatMap { $0.isEmpty ? nil : $0 } ?? "unknown error"
                }
            default:
                break   // session / agent_* / turn_* / tool_execution_* / …
            }
        }
        return out
    }

    /// Flatten an assistant message's content blocks into its answer text, dropping
    /// the `thinking` and `toolCall` blocks that share the array.
    private static func text(in content: Any?) -> String? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        return parts.isEmpty ? nil : parts.joined()
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

/// User-facing failures from the pi path. Mirrors `CommandCodeError` — pi is an
/// aggregator too, so it has the same rate-limit / spent-balance failures a
/// single-vendor CLI doesn't, except that here they belong to whichever upstream
/// account the picked model runs on.
enum PiError: LocalizedError {
    case notInstalled
    case notSignedIn
    case authExpired
    case rateLimited
    case outOfCredits
    case spawnFailed(String)
    case runFailed(String)
    case noOutput

    /// Whether a failure string is the broken-sign-in class. pi surfaces the
    /// upstream provider's own message verbatim, so this matches on what those say
    /// rather than on anything pi words itself.
    static func isAuthFailure(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("/login")
            || m.contains("not authenticated")
            || m.contains("unauthenticated")
            || m.contains("unauthorized")
            || m.contains("invalid api key")
            || m.contains("no credentials")
            || m.contains("401")
            || (m.contains("session") && m.contains("expired"))
    }

    /// Wrap a failure string in the right case: the three actionable classes are
    /// recognized by wording (pi has no documented exit-code contract to lean on the
    /// way Command Code does), everything else is surfaced verbatim.
    static func classify(_ message: String) -> PiError {
        let m = message.lowercased()
        if isAuthFailure(message) { return .authExpired }
        if m.contains("rate limit") || m.contains("429") { return .rateLimited }
        if m.contains("insufficient") || m.contains("out of credit")
            || m.contains("quota") || m.contains("balance") { return .outOfCredits }
        return .runFailed(message)
    }

    var errorDescription: String? {
        switch self {
        case .notInstalled: return L("pi.error.notInstalled")
        case .notSignedIn:  return L("pi.error.notSignedIn")
        case .authExpired:  return L("pi.error.authExpired")
        case .rateLimited:  return L("pi.error.rateLimited")
        case .outOfCredits: return L("pi.error.outOfCredits")
        case .noOutput:     return L("pi.error.noOutput")
        case .spawnFailed(let d):
            let base = L("pi.error.spawnFailed")
            return d.isEmpty ? base : "\(base) (\(d))"
        case .runFailed(let d):
            let base = L("pi.error.runFailed")
            return d.isEmpty ? base : "\(base) \(d)"
        }
    }
}
