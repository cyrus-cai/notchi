import Foundation

/// A model backend that shells out to the user's locally-installed **Codex CLI**
/// (`codex exec --json`) and streams its answer back.
///
/// Unlike every other `Provider`, Codex carries no API key: it reuses the ChatGPT
/// sign-in the user already did with `codex login` (the OAuth tokens cached in
/// `~/.codex/auth.json`), so usage is billed against their ChatGPT plan, not an API
/// account. That's the whole point — a keyless "use the ChatGPT I already pay for"
/// backend.
///
/// Why a subprocess and not an HTTP client: the ChatGPT-subscription path talks to a
/// private backend (`chatgpt.com/backend-api/codex`) behind an undocumented,
/// client-attested handshake (a whitelisted `originator`, exact headers, a fixed
/// instructions preamble). Rather than reimplement and impersonate that, we let the
/// official `codex` binary do it — the documented, supported headless interface.
///
/// Shape of the integration:
///  · one turn = one `codex exec` process. The persona (`system`) and the running
///    conversation are folded into a single prompt fed on stdin.
///  · `--json` prints JSONL events; the agent's answer arrives as a single
///    `item.completed` event with `item.type == "agent_message"` (the whole text,
///    not token deltas), so this stream yields once.
///  · `--ignore-user-config` isolates Notch from the user's global codex config
///    (skills / MCP / model / reasoning-effort) for a fast, predictable answer;
///    `-s read-only` plus an ephemeral temp working directory keep it from touching
///    the filesystem, and `--skip-git-repo-check` lets it run outside a repo.
///
/// Codex runs its own agent loop (web search, reasoning) internally, so this conforms
/// to `AIService` only — it deliberately does NOT adopt `AgentCapableService`, so
/// Notch's own tool harness stays out of its way (the turn dispatcher falls back to
/// the plain `stream` path for a non-agent service).
///
/// Known v1 limitation: pasted images (`ChatMessage.images`) are not forwarded — Codex
/// is text-only here. The picker's Codex row uses the id "codex", which reads as
/// non-vision, so no image thumbnail is offered for it in the first place.
struct CodexCLIService: AIService {
    /// The model to pass to `codex exec -m`. `nil` means "let codex use its own
    /// default model", which always works regardless of what this codex version or
    /// ChatGPT plan exposes — the robust default.
    let model: String?

    /// The picker's single Codex row carries the id "codex" — a sentinel for "codex's
    /// own default", not a real `-m` value. Normalize that (and empty) to `nil`.
    init(model: String? = nil) {
        let m = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = (m.isEmpty || m == "codex") ? nil : m
    }

    // MARK: - Availability

    /// Absolute paths we look for the `codex` binary at, in priority order. The
    /// ChatGPT desktop app bundles one, and on a Mac where `codex` was never added to
    /// the shell PATH that's often the only working copy — so it leads the list.
    private static let candidatePaths: [String] = {
        let home = NSHomeDirectory()
        return [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.codex/plugins/.plugin-appserver/codex",
        ]
    }()

    private static let resolveLock = NSLock()
    /// Double-optional cache: `nil` = never resolved; `.some(nil)` = resolved to "no
    /// binary". Resolution shells out (a `--version` smoke test), so it's cached for
    /// the process lifetime — warm it off-main at launch via `warmUp()`.
    private static var cachedBinary: String??

    /// The resolved `codex` binary path, or `nil` if none works. Cached.
    static func resolveBinary() -> String? {
        resolveLock.lock(); defer { resolveLock.unlock() }
        if let cached = cachedBinary { return cached }
        let resolved = locateBinary()
        cachedBinary = .some(resolved)
        return resolved
    }

    /// Resolve the binary and read the configured model off the main thread, so the
    /// first `isAvailable` / `defaultModel` call during a SwiftUI render reads a warm
    /// cache instead of spawning `--version` (or hitting disk) on the main thread.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            _ = resolveBinary()
            refreshModels()
        }
    }

    private static func locateBinary() -> String? {
        let fm = FileManager.default
        for p in candidatePaths where fm.isExecutableFile(atPath: p) {
            if smokeTest(p) { return p }
        }
        // Fall back to the user's login-shell PATH (honours a homebrew/npm install
        // that isn't at a standard absolute location).
        if let p = loginShellWhich(), smokeTest(p) { return p }
        return nil
    }

    /// A candidate is real only if `--version` exits cleanly — this is what skips a
    /// non-working shim (e.g. the `superset` wrapper, which prints "not found" and
    /// exits non-zero) that `command -v` might otherwise hand back.
    private static func smokeTest(_ path: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--version"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static func loginShellWhich() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lc", "command -v codex"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }

    /// The Codex home directory (`$CODEX_HOME`, else `~/.codex`) where the OAuth
    /// tokens live after `codex login`.
    private static var codexHome: String {
        ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "\(NSHomeDirectory())/.codex"
    }

    /// Whether the user has signed in — an `auth.json` exists under the Codex home.
    static func authExists() -> Bool {
        FileManager.default.fileExists(atPath: "\(codexHome)/auth.json")
    }

    /// Whether Codex can actually answer right now: the binary resolves AND the user
    /// has signed in. Drives the picker (Codex is selectable only when true) and the
    /// Settings status row.
    static var isAvailable: Bool { resolveBinary() != nil && authExists() }

    // MARK: - Model

    /// One model Codex offers this account, from the app-server's `model/list`.
    struct Model: Equatable {
        let id: String
        let displayName: String
        let isDefault: Bool
        /// The reasoning-effort levels this model accepts (`supportedReasoningEfforts`
        /// in the wire response) — they differ per model, so the effort menu must
        /// come from here, not a fixed set.
        let efforts: [String]
    }

    private static let modelLock = NSLock()
    /// The account's model list, fetched once from `codex app-server` and cached.
    /// `nil` = not fetched yet; an empty array = fetched but the query failed (so we
    /// fall back to the configured model and don't refetch on every render).
    private static var cachedModels: [Model]?

    /// Every model id Codex offers, for the picker. The app-server's `model/list` is
    /// the authoritative, per-account source; until it's fetched (or if it fails) we
    /// fall back to the single model named in `~/.codex/config.toml`.
    static var availableModelIDs: [String] {
        let models = fetchedModels()
        if !models.isEmpty { return models.map(\.id) }
        return [configuredModel]
    }

    /// The model to use when the user hasn't picked one: the account's default from
    /// `model/list`, else the configured model, else the "codex" sentinel (no `-m`).
    static var defaultModel: String {
        let models = fetchedModels()
        return models.first(where: \.isDefault)?.id ?? models.first?.id ?? configuredModel
    }

    private static func fetchedModels() -> [Model] {
        modelLock.lock(); defer { modelLock.unlock() }
        return cachedModels ?? []
    }

    /// The account's fetched model list (empty until `refreshModels()` has landed).
    /// The agent feature builds its Codex menu entries from this, so the pinnable
    /// models are always the ones this account can actually run.
    static var listedModels: [Model] { fetchedModels() }

    /// Fetch the account's model list off the main thread and cache it. Called from
    /// `warmUp()` at launch so the picker reads a warm cache. No-op once cached.
    static func refreshModels() {
        modelLock.lock()
        let alreadyHave = (cachedModels?.isEmpty == false)
        modelLock.unlock()
        if alreadyHave { return }
        let models = queryModelList() ?? []
        modelLock.lock(); cachedModels = models; modelLock.unlock()
    }

    /// The single model named in `~/.codex/config.toml` — the fallback when the
    /// app-server list isn't available. Falls back further to the "codex" sentinel
    /// (→ codex's built-in default, no `-m`) when the config names no model.
    static var configuredModel: String { readConfiguredModel() ?? "codex" }

    /// The first root-level `model = "…"` in `config.toml`. Codex puts this key at the
    /// top of the file, so a line scan that stops at the first `[table]` header is
    /// enough — no full TOML parse, and no risk of picking up a nested table's `model`.
    private static func readConfiguredModel() -> String? {
        guard let text = try? String(contentsOfFile: "\(codexHome)/config.toml", encoding: .utf8)
        else { return nil }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }               // entered a table — root keys are above
            guard line.hasPrefix("model"), let eq = line.firstIndex(of: "=") else { continue }
            guard line[..<eq].trimmingCharacters(in: .whitespaces) == "model" else { continue }
            let value = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// Ask `codex app-server` for the account's model list over JSON-RPC (stdio):
    /// `initialize` handshake, then `model/list`. Returns nil on any failure so the
    /// caller falls back to the configured model. Bounded by a short timeout and the
    /// app-server is always torn down before returning.
    private static func queryModelList() -> [Model]? {
        guard let binary = resolveBinary() else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        ProxyConfig.apply(to: &env)
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice

        let sem = DispatchSemaphore(value: 0)
        let box = ModelQueryState()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            if box.ingest(d) { sem.signal() }   // signals once the id:2 response lands
        }

        do { try p.run() } catch { return nil }

        let initReq = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"notch","title":"Notch","version":"1.0"}}}"# + "\n"
        let listReq = #"{"jsonrpc":"2.0","id":2,"method":"model/list","params":{}}"# + "\n"
        let writer = inPipe.fileHandleForWriting
        writer.write(Data(initReq.utf8))
        writer.write(Data(listReq.utf8))

        let timedOut = sem.wait(timeout: .now() + 8) == .timedOut
        outPipe.fileHandleForReading.readabilityHandler = nil
        if p.isRunning { p.terminate() }
        try? writer.close()
        return timedOut ? nil : box.models
    }

    // MARK: - Re-authorize

    /// Kick off a fresh ChatGPT sign-in by spawning `codex login`, which runs the
    /// browser OAuth flow (the same one you'd get from `codex login` in a terminal)
    /// and writes new tokens to `~/.codex/auth.json`. Detached — we don't wait on it;
    /// codex opens the browser itself. Output is discarded so a full pipe can't block
    /// the child. Returns false if the binary can't be found. This is also how a
    /// first-time sign-in happens, so it doubles as the "Sign in" action.
    ///
    /// We deliberately do NOT `logout` first: if the user cancels the browser flow,
    /// clearing the old tokens first would leave them signed out — worse than before.
    /// `codex login` re-runs the flow and overwrites the tokens on success.
    @discardableResult
    static func reauthorize() -> Bool {
        guard let binary = resolveBinary() else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["login"]
        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        ProxyConfig.apply(to: &env)
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        return true
    }

    // MARK: - Streaming

    /// How long a single `codex exec` may run before we terminate it. Codex is an
    /// agentic backend (it may search/reason), so this is generous — the real stop
    /// signal is the surrounding `Task` being cancelled when the panel closes.
    private static let timeout: TimeInterval = 180

    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let binary = Self.resolveBinary() else {
                continuation.finish(throwing: CodexError.notInstalled); return
            }
            guard Self.authExists() else {
                continuation.finish(throwing: CodexError.notSignedIn); return
            }

            let prompt = Self.composePrompt(system: system, messages: messages)
            let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("notch-codex-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            var args = ["exec", "--json", "--skip-git-repo-check", "--ephemeral",
                        "--ignore-user-config", "-s", "read-only", "--color", "never",
                        "-C", workDir.path]
            if let model { args += ["-m", model] }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args
            process.currentDirectoryURL = workDir
            // Inherit the environment but guarantee HOME so codex finds ~/.codex/auth.json
            // even when launched from a GUI context with a sparse environment. Same
            // reason the proxy has to be injected: `--ignore-user-config` means the
            // proxy keys in ~/.codex/config.toml don't apply either, so the
            // environment is the only channel left.
            var env = ProcessInfo.processInfo.environment
            if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
            ProxyConfig.apply(to: &env)
            process.environment = env

            let outPipe = Pipe(), inPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardInput = inPipe
            process.standardError = errPipe

            // All mutable stream state lives behind a lock — the stdout/stderr
            // readability handlers and the termination handler fire on separate
            // queues, so a plain captured `var` would be a data race.
            let state = StreamState()

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

            // Terminate a runaway process; cancelled below on clean exit.
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: watchdog)

            process.terminationHandler = { proc in
                watchdog.cancel()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                try? FileManager.default.removeItem(at: workDir)

                let snapshot = state.finish()
                if let msg = snapshot.failure {
                    continuation.finish(throwing: CodexError.runFailed(msg))
                } else if !snapshot.yieldedAny {
                    // No answer text: a non-zero exit is a real failure (surface the
                    // stderr tail); a clean exit with nothing is an empty response.
                    if proc.terminationStatus != 0 {
                        continuation.finish(throwing: CodexError.runFailed(snapshot.stderrTail))
                    } else {
                        continuation.finish(throwing: CodexError.noOutput)
                    }
                } else {
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                // Panel collapsed / round superseded → kill the process.
                if process.isRunning { process.terminate() }
            }

            do {
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: workDir)
                continuation.finish(throwing: CodexError.spawnFailed(error.localizedDescription))
                return
            }

            // Feed the prompt on stdin, then close it so codex reads it as the whole
            // prompt (no arg ⇒ stdin is the instruction). Short prompts sit well under
            // the pipe buffer, so this never blocks.
            let writer = inPipe.fileHandleForWriting
            writer.write(Data(prompt.utf8))
            try? writer.close()
        }
    }

    /// Fold the persona and running conversation into one prompt. `codex exec` has no
    /// system slot, so the persona leads as context, prior turns follow as a
    /// transcript, and the latest user message is the actual task.
    static func composePrompt(system: String, messages: [ChatMessage]) -> String {
        var parts: [String] = []
        let sys = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty { parts.append(sys) }

        let convo = messages.filter { !$0.content.trimmingCharacters(in: .whitespaces).isEmpty }
        if convo.count > 1 {
            var lines = ["Conversation so far:"]
            for m in convo.dropLast() {
                lines.append("\(m.role == "assistant" ? "Assistant" : "User"): \(m.content)")
            }
            parts.append(lines.joined(separator: "\n"))
        }
        if let last = convo.last {
            parts.append(convo.count > 1 ? "User: \(last.content)" : last.content)
        }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Stream state (thread-safe)

/// Line-buffers Codex's JSONL stdout and accumulates a stderr tail, guarded by a lock
/// because the readability/termination handlers run on different queues. `ingest`
/// returns the answer chunks parsed out of the data just read.
private final class StreamState {
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrTail = ""
    private var yieldedAny = false
    private var failure: String?

    struct Snapshot { let yieldedAny: Bool; let failure: String?; let stderrTail: String }

    /// Append `data` to the stdout buffer and return the `agent_message` texts in any
    /// newly-completed JSONL lines.
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
            case "item.completed":
                // The agent's answer. Ignore reasoning / command / other item types.
                if let item = obj["item"] as? [String: Any],
                   item["type"] as? String == "agent_message",
                   let text = item["text"] as? String, !text.isEmpty {
                    yieldedAny = true
                    out.append(text)
                }
            case "error":
                if let msg = obj["message"] as? String { failure = msg }
            case "turn.failed":
                if let err = obj["error"] as? [String: Any],
                   let msg = err["message"] as? String { failure = msg }
            default:
                break
            }
        }
        return out
    }

    func appendStderr(_ data: Data) {
        guard let s = String(data: data, encoding: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        stderrTail += s
        // Keep only a short tail — enough for an error message, never unbounded.
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

// MARK: - app-server model/list parsing

/// Line-buffers the `codex app-server` JSON-RPC stdout and pulls the model list out
/// of the `model/list` response (the request sent with id 2). Lock-guarded because
/// the readability handler runs on its own queue.
private final class ModelQueryState {
    private let lock = NSLock()
    private var buffer = Data()
    private(set) var models: [CodexCLIService.Model] = []

    /// Append `data`, parse complete JSONL lines, and return true once the `model/list`
    /// (id == 2) response has been parsed into `models`.
    func ingest(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (obj["id"] as? Int) == 2,
                  let result = obj["result"] as? [String: Any],
                  let data = result["data"] as? [[String: Any]]
            else { continue }
            models = data.compactMap { entry in
                guard let id = entry["id"] as? String, !id.isEmpty,
                      (entry["hidden"] as? Bool) != true
                else { return nil }
                let name = (entry["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let efforts = (entry["supportedReasoningEfforts"] as? [[String: Any]])?
                    .compactMap { $0["reasoningEffort"] as? String } ?? []
                return CodexCLIService.Model(id: id, displayName: name ?? id,
                                             isDefault: (entry["isDefault"] as? Bool) == true,
                                             efforts: efforts)
            }
            return true
        }
        return false
    }
}

// MARK: - Errors

/// User-facing failures from the Codex path. Messages are localized; the raw
/// underlying detail (stderr tail / spawn error) is only appended where it helps.
enum CodexError: LocalizedError {
    case notInstalled
    case notSignedIn
    case spawnFailed(String)
    case runFailed(String)
    case noOutput

    var errorDescription: String? {
        switch self {
        case .notInstalled: return L("codex.error.notInstalled")
        case .notSignedIn:  return L("codex.error.notSignedIn")
        case .noOutput:     return L("codex.error.noOutput")
        case .spawnFailed(let d):
            let base = L("codex.error.spawnFailed")
            return d.isEmpty ? base : "\(base) (\(d))"
        case .runFailed(let d):
            let base = L("codex.error.runFailed")
            return d.isEmpty ? base : "\(base) \(d)"
        }
    }
}
