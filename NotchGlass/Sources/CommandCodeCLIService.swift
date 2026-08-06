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
        var known: String?? = nil
        if resolveLock.try() {
            known = cachedBinary
            resolveLock.unlock()
        }
        if let known { return known }
        warmUp()
        return nil
    }

    /// Resolve the binary (and, with it, the model catalog) off the main thread, so
    /// the first `isAvailable` / `defaultModel` call during a SwiftUI render reads a
    /// warm cache instead of spawning a process on the main thread. Idempotent: a
    /// second call while the first is still probing is a no-op.
    static func warmUp() {
        warmLock.lock()
        guard !warmingUp else { warmLock.unlock(); return }
        warmingUp = true
        warmLock.unlock()
        DispatchQueue.global(qos: .utility).async {
            _ = resolveBinary()
            warmLock.lock(); warmingUp = false; warmLock.unlock()
            // Anything that read `isAvailable` as "not yet known" while this ran now
            // has a real answer to redraw with.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .cliAvailabilityResolved, object: nil)
            }
        }
    }

    /// Find the binary by *identity*, not by name. Every candidate is asked for its
    /// model catalog (`--list-models`); only a process that exits cleanly AND prints
    /// the catalog Command Code prints is accepted. That matters for the `cmd` alias,
    /// which is a name any tool could have claimed — and it is free, because the same
    /// spawn fills the model cache the picker needs (one process, both answers).
    private static func locateBinary() -> String? {
        let fm = FileManager.default
        for p in candidatePaths where fm.isExecutableFile(atPath: p) {
            if let models = probeModels(p) { adopt(models); return p }
        }
        // Fall back to the user's shell PATH — a node version manager (nvm / fnm /
        // volta / hermes) keeps its global bin dir out of a GUI app's inherited PATH
        // entirely, and out of the fixed list above (`ShellEnvironment`).
        if let p = ShellEnvironment.which(["command-code", "commandcode", "cmd"]),
           let models = probeModels(p) {
            adopt(models)
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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--list-models", "--no-auto-update"]
        var env = ShellEnvironment.childEnvironment(for: path)
        // No colour: the CLI only emits SGR codes on a TTY, but a forced-colour
        // environment would otherwise wrap every id in escape sequences.
        env["NO_COLOR"] = "1"
        p.environment = env
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

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args
            process.currentDirectoryURL = workDir
            // Guarantees HOME (so the CLI finds ~/.commandcode/auth.json from a GUI
            // context), a node-reachable PATH (the shebang needs it), and the proxy
            // (a GUI app inherits launchd's environment, which carries none — without
            // it the CLI connects directly and fails behind a proxy).
            process.environment = ShellEnvironment.childEnvironment(for: binary)

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
                guard let event = obj["event"] as? [String: Any],
                      event["type"] as? String == "text_delta",
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
