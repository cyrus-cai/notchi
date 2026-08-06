import Foundation

/// A model backend that shells out to the user's locally-installed **Claude Code
/// CLI** (`claude -p --output-format stream-json`) and streams the answer back —
/// the Claude twin of `CodexCLIService`.
///
/// **Compliance posture (deliberate, load-bearing — do not loosen):** Anthropic's
/// enforcement line distinguishes spawning the *genuine* `claude` binary under
/// the user's own sign-in (permitted; how every CLI-wrapper app operates) from
/// extracting OAuth tokens and impersonating Claude Code against the API
/// (banned). Notch stays squarely on the permitted side:
///  · only the official binary is ever executed — Notch speaks no HTTP to
///    Anthropic and never reads `~/.claude/.credentials.json` or the Keychain;
///  · sign-in detection is an existence check on the `oauthAccount` *metadata*
///    marker in `~/.claude.json` — never a token;
///  · there is NO in-app "sign in to Claude" flow (unlike Codex's re-authorize):
///    the user signs in in their own terminal by running `claude`. Usage bills
///    to their own Claude plan.
///
/// Shape of the integration (mirrors Codex):
///  · one turn = one `claude -p` process; the running conversation is folded
///    into a single stdin prompt, the persona rides `--system-prompt`.
///  · `--safe-mode` isolates the turn from the user's customizations (CLAUDE.md,
///    plugins, MCP servers, hooks) — the Codex `--ignore-user-config` analog.
///    Verified locally: without it, a loaded setup adds ~10k tokens of context
///    to every turn.
///  · `--no-session-persistence` keeps quick chats out of `~/.claude` session
///    history (the agent path is the opposite: it persists for `--resume`).
///  · `--tools WebSearch WebFetch` leaves exactly the web tools available, so a
///    time-sensitive question can be searched — everything else (file access,
///    bash) is off for a chat turn.
///  · `--output-format stream-json` (requires `--verbose`) prints JSONL; answer
///    text arrives as complete `assistant` message events (whole blocks, not
///    token deltas), and the final `result` event carries success/failure.
///
/// Conforms to `AIService` only — like Codex, Claude Code runs its own agent
/// loop, so Notch's tool harness stays out of its way.
struct ClaudeCLIService: AIService {
    /// The `--model` to pass. `nil` means "the account's default model" — always
    /// valid whatever the user's plan exposes. Aliases (`opus`, `sonnet`, …) and
    /// full ids both work.
    let model: String?

    /// "claude" is the retired account-default sentinel (the picker no longer
    /// offers it, and `APIKeyStore` resolves a stored one to a concrete alias) —
    /// never a real `--model` value. Normalize it, and empty, to `nil`.
    init(model: String? = nil) {
        let m = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = (m.isEmpty || m == "claude") ? nil : m
    }

    // MARK: - Availability

    /// Absolute paths the `claude` binary lives at, in priority order: the native
    /// installer's location first (the current default), then the migrated local
    /// install and package managers.
    private static let candidatePaths: [String] = {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
    }()

    private static let resolveLock = NSLock()
    /// Double-optional cache: `nil` = never resolved; `.some(nil)` = resolved to
    /// "no binary". Resolution shells out (`--version`), so it's cached for the
    /// process lifetime — warm it off-main at launch via `warmUp()`.
    private static var cachedBinary: String??
    /// `--version` output of the resolved binary, captured by the same spawn that
    /// vetted it — see `binaryFingerprint()`.
    private static var cachedVersion: String?

    /// The resolved `claude` binary path, or `nil` if none works. Cached.
    static func resolveBinary() -> String? {
        resolveLock.lock(); defer { resolveLock.unlock() }
        if let cached = cachedBinary { return cached }
        let resolved = locateBinary()
        cachedBinary = .some(resolved?.path)
        cachedVersion = resolved?.version
        return resolved?.path
    }

    /// Identity of the CLI that will actually be spawned: path **and** version.
    /// The alias→model mapping is only valid for one such identity — a CLI update
    /// moves the version, switching installs (native → homebrew) moves the path —
    /// so this is what the resolved-model cache keys on instead of a clock.
    /// Free: the version comes from the `--version` spawn that vetted the binary.
    static func binaryFingerprint() -> String? {
        guard let path = resolveBinary() else { return nil }
        resolveLock.lock(); defer { resolveLock.unlock() }
        guard let version = cachedVersion else { return nil }
        return "\(path)|\(version)"
    }

    /// Resolve the binary off the main thread so the first `isAvailable` read
    /// during a SwiftUI render hits a warm cache.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            _ = resolveBinary()
        }
    }

    private static func locateBinary() -> (path: String, version: String)? {
        let fm = FileManager.default
        for p in candidatePaths where fm.isExecutableFile(atPath: p) {
            if let v = smokeTest(p) { return (p, v) }
        }
        // Fall back to the user's shell PATH (npm-global, a node version manager,
        // and other non-standard installs) — see `ShellEnvironment`.
        if let p = ShellEnvironment.which(["claude"]), let v = smokeTest(p) { return (p, v) }
        return nil
    }

    /// A candidate is real only if `--version` exits cleanly — skips broken shims.
    /// Returns that version string (the caller keys the resolved-model cache on
    /// it); `"unknown"` when the binary is fine but prints nothing, so a quiet
    /// build is still accepted. `nil` means "not a working `claude`".
    private static func smokeTest(_ path: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--version"]
        p.environment = ShellEnvironment.childEnvironment(for: path)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let version = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return version.isEmpty ? "unknown" : version
    }

    /// Whether the user has signed in to Claude Code. This checks only the
    /// `oauthAccount` **metadata marker** in `~/.claude.json` (account email /
    /// display info the CLI stores about the signed-in user) — deliberately never
    /// the credentials file or Keychain, which hold the actual tokens Notch must
    /// never touch.
    static func authExists() -> Bool {
        let configPath = "\(NSHomeDirectory())/.claude.json"
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["oauthAccount"] != nil
    }

    /// Whether Claude Code can answer right now: binary resolves AND signed in.
    static var isAvailable: Bool { resolveBinary() != nil && authExists() }

    // MARK: - Resolved model names

    /// The picker lists the CLI's `--model` aliases ("opus", "sonnet", …), but the
    /// concrete model each alias points at ("claude-opus-4-8") lives inside the CLI
    /// and drifts as new models ship — there is no static source to bundle. The
    /// `init` event on `claude -p`'s stream-json stdout carries the resolved id and
    /// is printed *before* the turn runs, so probing is nearly free: spawn, read the
    /// first line, kill. Probes run off-main behind a UserDefaults cache — the
    /// picker only ever reads the cache (see `ModelCatalogStore.loadAll`).
    ///
    /// The cache is keyed on `binaryFingerprint()`, not on a clock. Only two
    /// things move this mapping: the CLI updating (fingerprint catches it the
    /// moment it happens) and the account's default model changing (invisible to
    /// a version, which is what the TTL below is left for). Keying on time alone
    /// used to mean a CLI update took up to a day to show up in the picker.
    private static let resolvedModelsLock = NSLock()
    private static var cachedResolvedModels: [String: String]?
    private static let resolvedModelsKey = "claudeCode.resolvedModels"
    private static let resolvedModelsFetchedAtKey = "claudeCode.resolvedModels.fetchedAt"
    private static let resolvedModelsFingerprintKey = "claudeCode.resolvedModels.fingerprint"
    /// Backstop for the one change the fingerprint can't see — the account's
    /// default model. A week: CLI updates land via the fingerprint instead, so
    /// this no longer has to be the freshness mechanism.
    private static let resolvedModelsTTL: TimeInterval = 7 * 24 * 3600

    /// A resolved id as a display name: "claude-opus-4-8" → "Claude Opus 4.8".
    /// Family words capitalized, numeric tokens joined into a dotted version,
    /// 8-digit date stamps dropped ("claude-haiku-4-5-20251001" → "Claude Haiku
    /// 4.5"). Token-order-agnostic, so legacy version-first ids
    /// ("claude-3-7-sonnet-…" → "Claude Sonnet 3.7") come out right too.
    static func displayName(forResolved id: String) -> String {
        // The CLI can suffix an id with a bracketed capability marker
        // ("claude-opus-4-8[1m]" = the 1M-context variant) — not part of the name.
        let bare = id.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "",
                                           options: .regularExpression)
        var tokens = bare.split(separator: "-").map(String.init)
        if tokens.first?.lowercased() == "claude" { tokens.removeFirst() }
        var words: [String] = []
        var digits: [String] = []
        for t in tokens {
            if t.allSatisfy(\.isNumber) {
                if t.count < 8 { digits.append(t) }
            } else {
                words.append(t.capitalized)
            }
        }
        let version = digits.joined(separator: ".")
        let parts = ["Claude"] + words + (version.isEmpty ? [] : [version])
        return parts.joined(separator: " ")
    }

    /// The same name without the vendor word — "claude-opus-5" → "Opus 5". What
    /// the chips and menu rows use: they already carry the Anthropic mark (or the
    /// provider's name beside them), so repeating "Claude" costs width and says
    /// nothing.
    static func shortDisplayName(forResolved id: String) -> String {
        let full = displayName(forResolved: id)
        let vendor = "Claude "
        guard full.hasPrefix(vendor), full.count > vendor.count else { return full }
        return String(full.dropFirst(vendor.count))
    }

    /// alias → concrete model id, from the freshest probe that has landed (this
    /// session's, else the persisted one — stale beats blank for display). Empty
    /// until a probe has ever succeeded.
    static var resolvedModels: [String: String] {
        resolvedModelsLock.lock(); defer { resolvedModelsLock.unlock() }
        if let cached = cachedResolvedModels { return cached }
        let stored = UserDefaults.standard.dictionary(forKey: resolvedModelsKey) as? [String: String] ?? [:]
        cachedResolvedModels = stored
        return stored
    }

    /// Probe the CLI for what each alias resolves to and cache the mapping.
    /// Blocking (seconds); call off the main thread. Cheap on a hit — it returns
    /// without spawning anything while the persisted cache was written by *this*
    /// CLI build, is inside the TTL, and already covers every alias. Callers are
    /// meant to call it freely rather than gate it themselves.
    static func refreshResolvedModels(aliases: [String]) {
        let defaults = UserDefaults.standard
        let known = resolvedModels
        let fingerprint = binaryFingerprint()
        if fingerprint != nil,
           fingerprint == defaults.string(forKey: resolvedModelsFingerprintKey),
           let fetched = defaults.object(forKey: resolvedModelsFetchedAtKey) as? Date,
           Date().timeIntervalSince(fetched) < resolvedModelsTTL,
           aliases.allSatisfy({ known[$0] != nil }) {
            return
        }

        // One spawn per alias, all at once: they're independent processes and each
        // is a cold node boot, so serially this ran to 4× the wall clock of the
        // slowest one. Rare now that the fingerprint gates it, but no reason to wait.
        let landedLock = NSLock()
        var landed: [String: String] = [:]
        let group = DispatchGroup()
        for alias in aliases {
            DispatchQueue.global(qos: .utility).async(group: group) {
                // "claude" is the account-default sentinel — probe it with no --model.
                guard let id = probeResolvedModel(alias: alias == "claude" ? nil : alias)
                else { return }
                landedLock.lock(); landed[alias] = id; landedLock.unlock()
            }
        }
        group.wait()

        guard !landed.isEmpty else { return }
        var merged = known   // keep stale entries for aliases whose probe failed
        merged.merge(landed) { _, fresh in fresh }
        resolvedModelsLock.lock()
        cachedResolvedModels = merged
        resolvedModelsLock.unlock()
        defaults.set(merged, forKey: resolvedModelsKey)
        defaults.set(Date(), forKey: resolvedModelsFetchedAtKey)
        if let fingerprint {
            defaults.set(fingerprint, forKey: resolvedModelsFingerprintKey)
        } else {
            defaults.removeObject(forKey: resolvedModelsFingerprintKey)
        }
    }

    /// One probe: spawn `claude -p` exactly as a real turn would, read the first
    /// stdout line — the `system/init` event, emitted before the model is called,
    /// with the alias already resolved to a concrete id — and terminate the
    /// process. No turn completes, so nothing meaningful bills to the user's plan.
    private static func probeResolvedModel(alias: String?) -> String? {
        guard let binary = resolveBinary() else { return nil }
        var args = ["-p", "--verbose", "--output-format", "stream-json",
                    "--safe-mode", "--no-session-persistence",
                    "--permission-mode", "default"]
        if let alias { args += ["--model", alias] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        var env = ShellEnvironment.childEnvironment(for: binary)
        env["DISABLE_AUTOUPDATER"] = "1"
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice

        let sem = DispatchSemaphore(value: 0)
        let state = FirstLineState()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if state.ingest(data) { sem.signal() }   // signals once a full line lands
        }

        do { try p.run() } catch { return nil }
        // `-p` reads the prompt from stdin; write a throwaway one and close so the
        // CLI proceeds to print init instead of waiting on EOF.
        let writer = inPipe.fileHandleForWriting
        writer.write(Data("hi".utf8))
        try? writer.close()

        // Generous: CLI startup is a node boot and can crawl on a cold disk cache.
        let timedOut = sem.wait(timeout: .now() + 20) == .timedOut
        outPipe.fileHandleForReading.readabilityHandler = nil
        if p.isRunning { p.terminate() }

        guard !timedOut,
              let line = state.firstLine,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "system",
              obj["subtype"] as? String == "init",
              let model = obj["model"] as? String, !model.isEmpty
        else { return nil }
        return model
    }

    /// Lock-guarded first-line collector for the probe's stdout — the readability
    /// handler runs on a background queue.
    private final class FirstLineState {
        private let lock = NSLock()
        private var buffer = Data()
        private(set) var firstLine: Data?

        /// Append `data`; returns true once the first complete line is captured.
        func ingest(_ data: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if firstLine != nil { return true }
            buffer.append(data)
            guard let nl = buffer.firstIndex(of: 0x0A) else { return false }
            firstLine = buffer.subdata(in: buffer.startIndex..<nl)
            return true
        }
    }

    // MARK: - Streaming

    /// How long a single chat turn may run. Claude may search the web mid-turn,
    /// so this is generous; the real stop signal is task cancellation.
    private static let timeout: TimeInterval = 180

    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let binary = Self.resolveBinary() else {
                continuation.finish(throwing: ClaudeCodeError.notInstalled); return
            }
            guard Self.authExists() else {
                continuation.finish(throwing: ClaudeCodeError.notSignedIn); return
            }

            // The persona rides --system-prompt, so the stdin prompt is just the
            // folded conversation (reuse Codex's transcript folding, minus system).
            let prompt = CodexCLIService.composePrompt(system: "", messages: messages)
            let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("notch-claude-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            // Everything is explicit — never inherited from the user's own
            // settings.json (their defaultMode could be anything): the available
            // tool set is exactly the web pair (CSV form, verified), those two are
            // pre-authorized so a search actually runs unattended, and everything
            // else is `default` mode = auto-denied without a TTY. NOT `--bare`:
            // bare skips the OAuth/Keychain read and would break subscription
            // sign-in (verified live) — `--safe-mode` is the right isolation, it
            // drops customizations (plugins/MCP/CLAUDE.md, ~10× context) while
            // keeping the user's login.
            var args = ["-p", "--verbose", "--output-format", "stream-json",
                        "--safe-mode", "--no-session-persistence",
                        "--permission-mode", "default",
                        "--tools", "WebSearch,WebFetch",
                        "--allowedTools", "WebSearch,WebFetch",
                        "--system-prompt", system]
            if let model { args += ["--model", model] }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args
            process.currentDirectoryURL = workDir
            // A GUI app inherits launchd's environment: no proxy, and a PATH that
            // can't find the CLI's own `node`. `ShellEnvironment` fixes both, and
            // guarantees HOME so the CLI finds its auth file.
            var env = ShellEnvironment.childEnvironment(for: binary)
            // Don't let an embedded one-shot turn kick off the CLI's background
            // auto-update check.
            env["DISABLE_AUTOUPDATER"] = "1"
            process.environment = env

            let outPipe = Pipe(), inPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardInput = inPipe
            process.standardError = errPipe

            let state = ClaudeStreamState()

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
                    continuation.finish(throwing: ClaudeCodeError.classify(msg))
                } else if !snapshot.yieldedAny {
                    if proc.terminationStatus != 0 {
                        continuation.finish(throwing: ClaudeCodeError.classify(snapshot.stderrTail))
                    } else {
                        continuation.finish(throwing: ClaudeCodeError.noOutput)
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
                continuation.finish(throwing: ClaudeCodeError.spawnFailed(error.localizedDescription))
                return
            }

            let writer = inPipe.fileHandleForWriting
            writer.write(Data(prompt.utf8))
            try? writer.close()
        }
    }
}

// MARK: - Stream state (thread-safe)

/// Line-buffers the `claude -p` JSONL stdout. Answer text arrives as complete
/// `assistant` message events (each with `message.content` blocks); the final
/// `result` event carries `is_error` + a failure description. Lock-guarded —
/// the readability and termination handlers run on different queues.
private final class ClaudeStreamState {
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrTail = ""
    private var yieldedAny = false
    private var failure: String?

    struct Snapshot { let yieldedAny: Bool; let failure: String?; let stderrTail: String }

    /// Append `data` and return the text blocks in newly-completed JSONL lines.
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
            case "assistant":
                // One event per completed assistant message; a turn that used a
                // tool (web search) can produce several. Yield each text block —
                // interleave two with a paragraph break so they don't concatenate
                // mid-sentence.
                guard let message = obj["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                for block in content where block["type"] as? String == "text" {
                    if let text = block["text"] as? String, !text.isEmpty {
                        out.append(yieldedAny ? "\n\n" + text : text)
                        yieldedAny = true
                    }
                }
            case "result":
                // The run's verdict. On failure the `result` string (or subtype)
                // is the best human-readable reason available.
                if (obj["is_error"] as? Bool) == true {
                    failure = (obj["result"] as? String)
                        ?? (obj["subtype"] as? String)
                        ?? "unknown error"
                }
            default:
                break   // system/init, rate_limit_event, post_turn_summary, …
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
        return Snapshot(yieldedAny: yieldedAny, failure: failure, stderrTail: tail)
    }
}

// MARK: - Errors

/// User-facing failures from the Claude Code path. Mirrors `CodexError`.
enum ClaudeCodeError: LocalizedError {
    case notInstalled
    case notSignedIn
    case authExpired
    case spawnFailed(String)
    case runFailed(String)
    case noOutput

    /// Whether a CLI failure string is the broken-sign-in class (expired or
    /// unrefreshable OAuth session, cleared Keychain credential, `/logout`).
    /// The CLI's wording varies — "Failed to authenticate: OAuth session
    /// expired and could not be refreshed", "Invalid API key · Please run
    /// /login", "Login expired." — but every variant either names `/login` or
    /// the authentication failure itself.
    static func isAuthFailure(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("/login")
            || m.contains("failed to authenticate")
            || m.contains("login expired")
            || (m.contains("oauth") && (m.contains("expired") || m.contains("revoked")))
    }

    /// Wrap a CLI failure string in the right case: auth failures become the
    /// actionable /login guidance, everything else stays verbatim.
    static func classify(_ message: String) -> ClaudeCodeError {
        isAuthFailure(message) ? .authExpired : .runFailed(message)
    }

    var errorDescription: String? {
        switch self {
        case .notInstalled: return L("claudecode.error.notInstalled")
        case .notSignedIn:  return L("claudecode.error.notSignedIn")
        case .authExpired:  return L("claudecode.error.authExpired")
        case .noOutput:     return L("claudecode.error.noOutput")
        case .spawnFailed(let d):
            let base = L("claudecode.error.spawnFailed")
            return d.isEmpty ? base : "\(base) (\(d))"
        case .runFailed(let d):
            let base = L("claudecode.error.runFailed")
            return d.isEmpty ? base : "\(base) \(d)"
        }
    }
}
