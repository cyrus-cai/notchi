import Foundation

/// A model backend that shells out to the user's locally-installed **Grok CLI**
/// (xAI's `grok`, "Grok Build") and streams its answer back — the xAI twin of
/// `CodexCLIService` / `ClaudeCLIService`.
///
/// Like Codex and Claude Code, Grok carries **no API key of ours**: it reuses the
/// sign-in the user already did (`grok login` → browser OAuth against `auth.x.ai`,
/// tokens cached in `~/.grok/auth.json`), or the `XAI_API_KEY` env var if they set
/// one. Either way usage bills against the user's own xAI / SuperGrok plan, not an
/// account of Notch's — the whole point of a "use the Grok I already pay for"
/// backend.
///
/// **Compliance posture (mirrors the other CLI backends):** the Grok chat path
/// talks to a private proxy (`cli-chat-proxy.grok.com`) behind an OAuth session,
/// so rather than reimplement and impersonate that handshake we let the official
/// `grok` binary do it — the documented, supported headless interface. Notch
/// speaks no HTTP to xAI, never reads the tokens in `~/.grok/auth.json` (sign-in
/// detection is an existence check on the file's account key, never the token),
/// and only ever executes the genuine binary. Sign-in / re-authorize spawns
/// `grok login`, which opens the user's own browser OAuth flow — the same command
/// they'd run in a terminal (this is why the account row offers it, unlike the
/// Claude row: `grok login` is a first-class user-facing subcommand).
///
/// Shape of the integration (mirrors the twins):
///  · one turn = one `grok` headless process. The persona rides
///    `--system-prompt-override` (Grok's documented `--system-prompt` analog), so
///    the stdin/prompt-file carries only the folded conversation.
///  · `--prompt-file` feeds the folded prompt (no argv-length limit, no stdin
///    merge surprise — a bare `grok -p` also splices piped stdin into the prompt).
///  · `--output-format streaming-json` prints NDJSON: `{"type":"text","data":…}`
///    answer deltas (token-level, so this stream yields as it types), interleaved
///    `{"type":"thought",…}` reasoning we drop, and a terminal `{"type":"end",…}`.
///  · `--tools web_search,web_fetch` leaves exactly the read-only web pair
///    available (the Claude `--tools WebSearch,WebFetch` analog) — no filesystem,
///    no shell — and `--always-approve` lets those run unattended without a TTY
///    approval prompt. `--no-memory` / `--no-subagents` / `--no-plan` keep the
///    turn from touching cross-session memory, spawning helpers, or planning; an
///    ephemeral temp `--cwd` isolates it from the user's project.
///
/// Grok runs its own agent loop (web search, reasoning) internally, so this
/// conforms to `AIService` only — like Codex/Claude it deliberately does NOT adopt
/// the tool harness, so Notch's tools stay out of its way.
struct GrokCLIService: AIService {
    /// The `--model` (`-m`) to pass. `nil` means "Grok's own default model" —
    /// always valid whatever the account exposes.
    let model: String?

    /// The picker's Grok row carries the id "grok" — a sentinel for "Grok's own
    /// default", not a real `-m` value. Normalize that (and empty) to `nil`.
    init(model: String? = nil) {
        let m = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = (m.isEmpty || m == "grok") ? nil : m
    }

    // MARK: - Availability

    /// Absolute paths the `grok` binary lives at, in priority order: the native
    /// installer's location (`~/.grok/bin`) first, then a `~/.local/bin` symlink
    /// and the package managers.
    private static let candidatePaths: [String] = {
        let home = NSHomeDirectory()
        return [
            "\(home)/.grok/bin/grok",
            "\(home)/.local/bin/grok",
            "/opt/homebrew/bin/grok",
            "/usr/local/bin/grok",
        ]
    }()

    private static let resolveLock = NSLock()
    /// Double-optional cache: `nil` = never resolved; `.some(nil)` = resolved to
    /// "no binary". Resolution shells out (`--version`), so it's cached for the
    /// process lifetime — warm it off-main at launch via `warmUp()`.
    private static var cachedBinary: String??
    /// Guards `warmingUp` only. Deliberately NOT `resolveLock`: that one is held for
    /// the whole probe, so taking it here would put the render right back into the
    /// wait this exists to avoid. This one is never held across work.
    private static let warmLock = NSLock()
    /// Set once a `warmUp()` is in flight, so repeated availability reads during the
    /// first resolution don't each queue another probe.
    private static var warmingUp = false

    /// The resolved `grok` binary path, or `nil` if none works. Cached.
    ///
    /// **Blocking** — a cold cache spawns `--version` (and may probe the shell PATH),
    /// and it waits on the lock the launch warm-up holds while doing exactly that.
    /// Never call it on the main thread: renders use `resolvedBinaryIfReady()`.
    static func resolveBinary() -> String? {
        resolveLock.lock(); defer { resolveLock.unlock() }
        if let cached = cachedBinary { return cached }
        let resolved = locateBinary()
        cachedBinary = .some(resolved)
        return resolved
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
    /// anything that acts destructively on a negative: a caller that DISCARDS
    /// state when an engine looks dead has to ask this first, or the first hover
    /// after a relaunch throws away a perfectly live pick.
    static var isAvailabilityResolved: Bool {
        guard resolveLock.try() else { return false }
        defer { resolveLock.unlock() }
        return cachedBinary != nil
    }

    /// Resolve the binary and read the model cache off the main thread, so the
    /// first `isAvailable` / `defaultModel` call during a SwiftUI render reads a
    /// warm cache instead of shelling out (or hitting disk) on the main thread.
    /// Idempotent: a second call while the first is still probing is a no-op.
    static func warmUp() {
        warmLock.lock()
        guard !warmingUp else { warmLock.unlock(); return }
        warmingUp = true
        warmLock.unlock()
        DispatchQueue.global(qos: .utility).async {
            _ = resolveBinary()
            warmLock.lock(); warmingUp = false; warmLock.unlock()
            refreshModels()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .cliAvailabilityResolved, object: nil)
            }
        }
    }

    private static func locateBinary() -> String? {
        let fm = FileManager.default
        for p in candidatePaths where fm.isExecutableFile(atPath: p) {
            if smokeTest(p) { return p }
        }
        // Fall back to the user's shell PATH (honours a non-standard or
        // version-manager install) — see `ShellEnvironment`.
        if let p = ShellEnvironment.which(["grok"]), smokeTest(p) { return p }
        return nil
    }

    /// A candidate is real only if `--version` exits cleanly — skips broken shims.
    private static func smokeTest(_ path: String) -> Bool {
        let p = ShellEnvironment.makeProcess(path, ["--version"])
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// The Grok home directory (`~/.grok`) where OAuth tokens and the model cache
    /// live after `grok login`.
    private static var grokHome: String { "\(NSHomeDirectory())/.grok" }

    /// Whether the user has signed in — either an `XAI_API_KEY` env var is set, or
    /// `~/.grok/auth.json` exists with at least one account entry. Only the
    /// *existence* of the marker is read, never the token itself.
    static func authExists() -> Bool {
        if let key = ProcessInfo.processInfo.environment["XAI_API_KEY"],
           !key.trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        let authPath = "\(grokHome)/auth.json"
        guard let data = FileManager.default.contents(atPath: authPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return !json.isEmpty
    }

    /// Whether Grok can actually answer right now: the binary resolves AND the user
    /// has signed in. Drives the picker (Grok is selectable only when true) and the
    /// Settings status row. Reads the resolution non-blockingly (this runs inside
    /// `body`); until the launch probe lands it answers "no" and
    /// `.cliAvailabilityResolved` redraws.
    static var isAvailable: Bool { resolvedBinaryIfReady() != nil && authExists() }

    // MARK: - Model

    private static let modelLock = NSLock()
    /// The account's models (id + display name), read from
    /// `~/.grok/models_cache.json` (the file the CLI itself maintains). `nil` =
    /// not read yet; an empty array = read but the file was missing/unparsable,
    /// so we fall back to the "grok" sentinel and don't re-scan on every render.
    private static var cachedModels: [(id: String, name: String)]?

    /// Every model id Grok offers, for the picker. Read from the CLI's own model
    /// cache; falls back to the single "grok" sentinel (→ Grok's built-in default,
    /// no `-m`) until that read lands or if it's unavailable.
    static var availableModelIDs: [String] {
        let models = fetchedModels()
        return models.isEmpty ? ["grok"] : models.map(\.id)
    }

    /// id + human display name for the picker rows — the cache's own `name` field
    /// ("grok-4.5" → "Grok 4.5"), so the row says what xAI calls the model rather
    /// than a bare version tail. Empty until the cache read lands (callers fall
    /// back to the sentinel default entry), mirroring `CodexCLIService.listedModels`.
    static var listedModels: [(id: String, displayName: String)] {
        fetchedModels().map { ($0.id, $0.name) }
    }

    /// The model to use when the user hasn't picked one: the model named in
    /// `~/.grok/config.toml`, else the first cached id, else the "grok" sentinel.
    static var defaultModel: String {
        if let configured = readConfiguredModel() { return configured }
        return fetchedModels().first?.id ?? "grok"
    }

    private static func fetchedModels() -> [(id: String, name: String)] {
        modelLock.lock(); defer { modelLock.unlock() }
        return cachedModels ?? []
    }

    /// Re-read the model cache off the main thread and store it. Called from
    /// `warmUp()` at launch so the picker reads a warm cache. No-op once populated
    /// — unless `force`, the manual-refresh route, which re-reads the CLI's cache
    /// file (what a `grok` run refreshes) and keeps the old list if it reads empty.
    static func refreshModels(force: Bool = false) {
        modelLock.lock()
        let alreadyHave = (cachedModels?.isEmpty == false)
        modelLock.unlock()
        if alreadyHave, !force { return }
        let models = readModelCache()
        if force, models.isEmpty { return }
        modelLock.lock(); cachedModels = models; modelLock.unlock()
    }

    /// Pull the visible models out of `~/.grok/models_cache.json` — the `models`
    /// map keyed by id, skipping any marked `hidden` or not `supported_in_api`.
    /// Each entry carries the cache's own display `name` ("Grok 4.5"), falling
    /// back to the id when absent.
    private static func readModelCache() -> [(id: String, name: String)] {
        let path = "\(grokHome)/models_cache.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [String: Any]
        else { return [] }
        var out: [(id: String, name: String)] = []
        for (id, value) in models {
            let info = (value as? [String: Any])?["info"] as? [String: Any]
            if (info?["hidden"] as? Bool) == true { continue }
            if (info?["supported_in_api"] as? Bool) == false { continue }
            let name = (info?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            out.append((id: id, name: name))
        }
        return out.sorted { $0.id < $1.id }
    }

    /// The first root-level `model = "…"` in `~/.grok/config.toml`, if any. Same
    /// line-scan-until-first-table shape as `CodexCLIService.readConfiguredModel`.
    private static func readConfiguredModel() -> String? {
        guard let text = try? String(contentsOfFile: "\(grokHome)/config.toml", encoding: .utf8)
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

    // MARK: - Re-authorize

    /// Kick off a fresh xAI sign-in by spawning `grok login`, which opens the
    /// browser OAuth flow and writes new tokens to `~/.grok/auth.json`. Detached —
    /// grok opens the browser itself; output is discarded so a full pipe can't
    /// block the child. Returns false if the binary can't be found. Doubles as the
    /// first-time "Sign in" action. We deliberately do NOT `logout` first: if the
    /// user cancels the browser flow, clearing the old tokens would leave them
    /// signed out — worse than before.
    @discardableResult
    static func reauthorize() -> Bool {
        guard let binary = resolveBinary() else { return false }
        let p = ShellEnvironment.makeProcess(binary, ["login"])
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        return true
    }

    // MARK: - Streaming

    /// How long a single turn may run before we terminate it. Grok is agentic (it
    /// may search/reason), so this is generous — the real stop signal is the
    /// surrounding `Task` being cancelled when the panel closes.
    private static let timeout: TimeInterval = 180

    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let binary = Self.resolveBinary() else {
                continuation.finish(throwing: GrokError.notInstalled); return
            }
            guard Self.authExists() else {
                continuation.finish(throwing: GrokError.notSignedIn); return
            }

            // Unified searcher (XII: "grok must use MY search tool"). When the
            // user picked a client-side search backend in
            // Settings, that promise — one searcher replaces every provider's
            // native search — must hold for grok too. Grok's own agent loop can't
            // be handed a harness tool, but it CAN be handed an MCP server, so:
            //  · the workdir becomes a STABLE dir (not per-turn ephemeral) whose
            //    `.grok/config.toml` declares an MCP stdio server = this very app
            //    binary relaunched headless (`GrokSearchMCPServer`), bridging to
            //    the same search tools the harness uses;
            //  · `--trust` marks that dir trusted (repo-level MCP config only
            //    applies to trusted folders; headless can't prompt). The dir is
            //    stable precisely so the trust-store gains ONE entry, not one per
            //    turn — and it's a dir Notch itself owns, so trusting it is safe;
            //  · grok's own search is cut: web_search drops out of the allowlist
            //    AND onto the denylist, and the system prompt names the MCP tool
            //    (grok reaches MCP tools via its search_tool/use_tool meta-tools).
            //    web_fetch stays — reading a result URL is how search completes.
            // With no unified backend, everything below is the pre-existing path
            // (grok's own web pair, ephemeral cwd) — bit-for-bit.
            let unifiedBackend = APIKeyStore.resolvedSearchBackend()

            let workDir: URL
            if unifiedBackend != nil, let stable = Self.unifiedSearchWorkDir() {
                workDir = stable
            } else {
                workDir = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("notch-grok-\(UUID().uuidString)", isDirectory: true)
            }
            // The stable dir must never be bulk-deleted on settle (another turn
            // may be mid-flight in it); only the per-turn prompt file is cleaned.
            let workDirIsEphemeral = unifiedBackend == nil || Self.unifiedSearchWorkDir() == nil

            // The persona rides --system-prompt-override, so the prompt file is
            // just the folded conversation (reuse Codex's folding, minus system).
            let prompt = CodexCLIService.composePrompt(system: "", messages: messages)
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let promptFile = workDir.appendingPathComponent("prompt-\(UUID().uuidString).txt")
            let cleanup = {
                if workDirIsEphemeral {
                    try? FileManager.default.removeItem(at: workDir)
                } else {
                    try? FileManager.default.removeItem(at: promptFile)
                }
            }
            do {
                try prompt.data(using: .utf8)?.write(to: promptFile)
            } catch {
                cleanup()
                continuation.finish(throwing: GrokError.spawnFailed(error.localizedDescription))
                return
            }

            // Everything explicit — never inherited from the user's own config: the
            // available tool set is exactly the read-only web pair, those run
            // unattended (--always-approve, no TTY to confirm at), memory /
            // subagents / plan mode are off, and an ephemeral cwd isolates the
            // filesystem. --system-prompt-override replaces Grok's coding-agent
            // persona with Notch's chat persona.
            //
            // --disallowed-tools run_terminal_cmd is load-bearing, not redundant:
            // with a --tools allowlist, grok (v0.2.93) STILL constructs and
            // validates the shell tool during agent-building even though it's
            // filtered out, and its default `auto_background_on_timeout=true` is
            // illegal headless (`enabled_background=false`), which aborts the whole
            // session ("agent building failed: … run_terminal_cmd"). Denylisting it
            // drops it before validation runs. Verified: allowlist alone fails,
            // allowlist + this denylist succeeds.
            var args = ["--prompt-file", promptFile.path,
                        "--output-format", "streaming-json",
                        "--always-approve",
                        "--no-memory", "--no-subagents", "--no-plan",
                        "--no-auto-update",
                        "--cwd", workDir.path]
            if unifiedBackend != nil, !workDirIsEphemeral,
               Self.writeMCPConfig(in: workDir) {
                args += ["--tools", "web_fetch",
                         "--disallowed-tools", "run_terminal_cmd,web_search",
                         "--trust",
                         "--system-prompt-override",
                         system + Self.searchDirective()]
            } else {
                args += ["--tools", "web_search,web_fetch",
                         "--disallowed-tools", "run_terminal_cmd",
                         "--system-prompt-override", system]
            }
            if let model { args += ["-m", model] }

            let process = ShellEnvironment.makeProcess(binary, args, cwd: workDir)

            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardInput = FileHandle.nullDevice
            process.standardError = errPipe

            let state = GrokStreamState()

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
                cleanup()

                let snapshot = state.finish()
                if let msg = snapshot.failure {
                    continuation.finish(throwing: GrokError.classify(msg))
                } else if !snapshot.yieldedAny {
                    if proc.terminationStatus != 0 {
                        continuation.finish(throwing: GrokError.classify(snapshot.stderrTail))
                    } else {
                        continuation.finish(throwing: GrokError.noOutput)
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
                cleanup()
                continuation.finish(throwing: GrokError.spawnFailed(error.localizedDescription))
            }
        }
    }
}

// MARK: - Unified-searcher plumbing

extension GrokCLIService {
    /// The MCP server name declared in the per-turn `.grok/config.toml`. Grok
    /// namespaces MCP tools as `<server>__<tool>`, so the model sees the search
    /// tool as `notch_search__<backend>_search`.
    private static let mcpServerName = "notch_search"

    /// The stable working directory for unified-search turns —
    /// `~/Library/Caches/<bundle-id>/grok-chat`. Stable (vs the ephemeral
    /// per-turn temp dir) so grok's folder-trust store gains exactly one entry
    /// for it, ever; the per-turn artifacts inside (prompt files) are uniquely
    /// named and individually cleaned. `nil` only if Caches can't be resolved —
    /// then the caller falls back to the native-search path.
    static func unifiedSearchWorkDir() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory,
                                                    in: .userDomainMask).first
        else { return nil }
        return caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Notch", isDirectory: true)
            .appendingPathComponent("grok-chat", isDirectory: true)
    }

    /// Write the repo-scoped MCP config (`<workDir>/.grok/config.toml`) that
    /// points grok at this app binary in MCP-server mode. Rewritten every turn
    /// (the executable path can change across app updates); concurrent turns
    /// write identical bytes, so the race is harmless. Returns false when the
    /// executable path is unknown or the write fails — the caller then leaves
    /// grok's own search enabled rather than cutting search off entirely.
    static func writeMCPConfig(in workDir: URL) -> Bool {
        guard let exe = Bundle.main.executablePath else { return false }
        let dir = workDir.appendingPathComponent(".grok", isDirectory: true)
        // TOML basic-string escaping for the one interpolated value.
        let escaped = exe
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let toml = """
        # Written by Notch on every Grok chat turn — do not edit.
        [mcp_servers.\(mcpServerName)]
        command = "\(escaped)"
        args = ["\(GrokSearchMCPServer.launchFlag)"]
        enabled = true

        """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try toml.data(using: .utf8)?
                .write(to: dir.appendingPathComponent("config.toml"))
            return true
        } catch { return false }
    }

    /// The system-prompt suffix that makes the constraint stick. Denying
    /// web_search removes the capability, but grok then improvises — observed
    /// live: it pointed web_fetch at DuckDuckGo's results page instead. So the
    /// prompt names the one sanctioned searcher (reachable via grok's
    /// search_tool/use_tool MCP meta-tools) and explicitly bans the workaround.
    static func searchDirective() -> String {
        let tool = "\(mcpServerName)__\(WebSearchTool.toolName)"
        return """
        \n\nWeb search: the built-in web_search tool is disabled in this session. \
        The ONLY way to search the web is the MCP tool `\(tool)` — discover it \
        with search_tool, then invoke it with use_tool. Use it whenever the \
        answer depends on current information. Never simulate a search by \
        pointing web_fetch at a search engine's results page; use web_fetch \
        only to read a specific page that a search result surfaced.
        """
    }

}

// MARK: - MCP stdio server mode

/// The headless personality of this very app binary: launched as
/// `Notch --grok-search-mcp` it speaks MCP over stdio and serves exactly one
/// tool — the selected unified web searcher, backed by the *same*
/// tool implementations and stored keys the in-app agent harness uses. Grok
/// spawns it per session from the config `GrokCLIService.writeMCPConfig` lays
/// down; it must never touch AppKit (see `NotchGlassMain`). Protocol surface is
/// the minimum a client needs: initialize, tools/list, tools/call; everything
/// else gets an empty result (requests) or silence (notifications). Exits on
/// stdin EOF — grok closing the pipe is the shutdown signal.
enum GrokSearchMCPServer {
    static let launchFlag = "--grok-search-mcp"

    static func runAndExit() -> Never {
        let out = FileHandle.standardOutput
        func send(_ obj: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
            data.append(0x0A)
            out.write(data)
        }
        func reply(id: Any, result: [String: Any]) {
            send(["jsonrpc": "2.0", "id": id, "result": result])
        }

        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String
            else { continue }
            let id = obj["id"]
            switch method {
            case "initialize":
                let params = obj["params"] as? [String: Any]
                let version = (params?["protocolVersion"] as? String) ?? "2025-03-26"
                guard let id else { break }
                reply(id: id, result: [
                    "protocolVersion": version,
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "notch-search", "version":
                        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"],
                ])
            case "tools/list":
                guard let id else { break }
                let toolName = APIKeyStore.resolvedSearchBackend() == nil
                    ? "search_unavailable" : WebSearchTool.toolName
                reply(id: id, result: ["tools": [[
                    "name": toolName,
                    "description": webSearchToolDescription,
                    "inputSchema": [
                        "type": "object",
                        "properties": ["query": ["type": "string",
                                                 "description": "The search query."]],
                        "required": ["query"],
                    ],
                ]]])
            case "tools/call":
                guard let id else { break }
                let params = obj["params"] as? [String: Any]
                let query = ((params?["arguments"] as? [String: Any])?["query"] as? String) ?? ""
                let text = runSearch(query: query)
                reply(id: id, result: ["content": [["type": "text", "text": text]]])
            default:
                // Unknown request → empty result so the client never stalls on a
                // missing reply; notifications (no id) need no answer.
                if let id { reply(id: id, result: [:]) }
            }
        }
        exit(0)
    }

    /// Run the resolved backend's search synchronously (the stdio loop is a
    /// plain blocking read loop; the tools are async). The semaphore hand-off
    /// happens-before the read, and the box exists only to satisfy the
    /// sendability of the detached task.
    private static func runSearch(query: String) -> String {
        final class Box: @unchecked Sendable { var text = "" }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        let backend = APIKeyStore.resolvedSearchBackend()
        Task.detached {
            defer { sem.signal() }
            do {
                if let backend {
                    box.text = try await backend.searchProvider.search(["query": query]).text
                } else {
                    box.text = "Error: no search backend is configured; tell the user "
                             + "to pick one in Notch's settings."
                }
            } catch {
                box.text = "Search failed: \(error.localizedDescription)"
            }
        }
        sem.wait()
        return box.text
    }
}

// MARK: - Stream state (thread-safe)

/// Line-buffers Grok's streaming-json stdout. Answer text arrives as
/// `{"type":"text","data":…}` deltas; `{"type":"thought",…}` is reasoning we drop;
/// `{"type":"error",…}` (or a non-`EndTurn` `{"type":"end",…}` with no text) is a
/// failure. Lock-guarded — the readability and termination handlers run on
/// different queues. Mirrors `ClaudeStreamState`.
private final class GrokStreamState {
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrTail = ""
    private var yieldedAny = false
    private var failure: String?

    struct Snapshot { let yieldedAny: Bool; let failure: String?; let stderrTail: String }

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
            case "text":
                if let text = obj["data"] as? String, !text.isEmpty {
                    yieldedAny = true
                    out.append(text)
                }
            case "error":
                // Defensive: capture whatever human-readable field the error carries.
                failure = (obj["message"] as? String)
                    ?? (obj["data"] as? String)
                    ?? (obj["error"] as? String)
                    ?? "unknown error"
            case "end":
                // The turn's real token cost, when the CLI reports it.
                if let usage = obj["usage"] as? [String: Any] {
                    TokenMeter.shared.record(input: usage["input_tokens"] as? Int ?? 0,
                                             output: usage["output_tokens"] as? Int ?? 0)
                }
                // A terminal event whose stopReason names an error, with no text
                // produced, is a failure worth surfacing (auth, quota, refusal).
                if !yieldedAny, let reason = obj["stopReason"] as? String {
                    let r = reason.lowercased()
                    if r.contains("error") || r.contains("refus") || r.contains("cancel") {
                        failure = reason
                    }
                }
            default:
                break   // "thought" reasoning and any other event types
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

/// User-facing failures from the Grok path. Mirrors `ClaudeCodeError`.
enum GrokError: LocalizedError {
    case notInstalled
    case notSignedIn
    case authExpired
    case sessionFailed
    case spawnFailed(String)
    case runFailed(String)
    case noOutput

    /// Whether a CLI failure string is the broken-sign-in class (expired /
    /// unrefreshable OAuth session, missing credentials, signed out). The wording
    /// varies, but every variant names authentication or the sign-in command.
    static func isAuthFailure(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("grok login")
            || m.contains("not authenticated")
            || m.contains("unauthenticated")
            || m.contains("failed to authenticate")
            || m.contains("sign in")
            || m.contains("signed out")
            || (m.contains("oauth") && (m.contains("expired") || m.contains("revoked")))
            || (m.contains("session") && m.contains("expired"))
    }

    /// Whether a CLI failure string is a session/agent-build failure — a grok-side
    /// internal error (often a CLI-version bug or bad tool config) that dumps a raw
    /// Rust struct no user can act on. These are surfaced as actionable "update the
    /// CLI and retry" guidance rather than the debug text.
    static func isSessionBuildFailure(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("couldn't create session")
            || m.contains("could not create session")
            || m.contains("agent building failed")
            || m.contains("requirements unsatisfied")
    }

    /// Wrap a CLI failure string in the right case: auth failures become sign-in
    /// guidance, session-build failures become update/retry guidance, everything
    /// else stays verbatim.
    static func classify(_ message: String) -> GrokError {
        if isAuthFailure(message) { return .authExpired }
        if isSessionBuildFailure(message) { return .sessionFailed }
        return .runFailed(message)
    }

    var errorDescription: String? {
        switch self {
        case .notInstalled: return L("grok.error.notInstalled")
        case .notSignedIn:  return L("grok.error.notSignedIn")
        case .authExpired:  return L("grok.error.authExpired")
        case .sessionFailed: return L("grok.error.sessionFailed")
        case .noOutput:     return L("grok.error.noOutput")
        case .spawnFailed(let d):
            let base = L("grok.error.spawnFailed")
            return d.isEmpty ? base : "\(base) (\(d))"
        case .runFailed(let d):
            let base = L("grok.error.runFailed")
            return d.isEmpty ? base : "\(base) \(d)"
        }
    }
}
