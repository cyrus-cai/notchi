import Foundation
import AppKit

/// The locally-installed **dsh** CLI (DeepSeek Harness, `@deepseek-ai/dsh`), as a
/// chat backend (`Provider.dshCode`) and an agent engine (`AgentEngine.dsh`).
///
/// Same compliance posture as the other CLI engines: only the user's own binary is
/// spawned, and it runs under the user's own dsh configuration. To tell "has a
/// key" from "installed", `authExists` looks at which entries dsh's credential
/// store (`$DSH_HOME/.credentials.yaml`, `$DSH_HOME/.env`) and the launch
/// environment name; it never keeps or passes on a value. A run that still fails
/// for a key gets dsh's own message, which `DshError.isAuthFailure` turns into a
/// sign-in hint.
///
/// Both paths spawn `dsh --profile headless --json` with the prompt on stdin.
/// Headless has no model flag, so the picked model rides a `--patch` overlay that
/// sets dsh's default-model entry (`modelArgs`). The models are DeepSeek's own
/// route (`deepseek-official`), the catalog dsh ships for it.
///
/// A chat turn runs in an empty temp directory. Headless has no flag to turn tools
/// off, so the agent may still use them there, inside dsh's workspace-write
/// sandbox. Each turn is saved as a session in dsh's own history; headless has no
/// flag to skip that either.
struct DshCLIService: AIService {
    /// The model id stored before dsh had a model list. Read as `defaultModel`.
    static let defaultSentinel = "dsh"

    /// dsh's catalog for the `deepseek-official` route, default first.
    static let models = ["deepseek-flash", "deepseek-v4-pro"]
    static var defaultModel: String { models[0] }

    let model: String?

    init(model: String? = nil) {
        self.model = model
    }

    /// The flags that run `model` instead of dsh's saved default: a one-entry patch
    /// overlay on the `agent-default-model` entry. Empty for no model or an id
    /// outside the catalog, which leaves dsh on its own default.
    static func modelArgs(for model: String?) -> [String] {
        guard let model, models.contains(model) else { return [] }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notch-dsh-patch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(model).yml")
        let yaml = """
        - id: agent-default-model
          config:
            provider: deepseek-official
            model: \(model)
        """
        guard (try? yaml.write(to: file, atomically: true, encoding: .utf8)) != nil else { return [] }
        return ["--patch", file.path]
    }

    /// Absolute paths the CLI may live at, in priority order. `dsh` is an npm
    /// global; a version manager's bin dir is covered by the shell PATH fallback.
    private static let candidatePaths: [String] = {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin/dsh",
            "/opt/homebrew/bin/dsh",
            "/usr/local/bin/dsh",
        ]
    }()

    private static let resolveLock = NSLock()
    /// `nil` = never resolved; `.some(nil)` = resolved to "no binary".
    private static var cachedBinary: String??
    private static let warmLock = NSLock()
    private static var warmingUp = false

    private static let storedPathKey = "dsh.binaryPath"
    private static let primeLock = NSLock()
    private static var primed = false
    /// True while the process runs on the remembered path and no spawn has
    /// re-checked it yet.
    private static var seededFromDisk = false

    /// The resolved binary path, or `nil`. **Blocking** on a cold cache (a Node
    /// cold start); never call from the main thread.
    static func resolveBinary() -> String? {
        primeFromDisk()
        resolveLock.lock(); defer { resolveLock.unlock() }
        if let cached = cachedBinary { return cached }
        let resolved = locateBinary()
        cachedBinary = .some(resolved)
        remember(resolved)
        return resolved
    }

    /// The resolved binary without waiting: the answer if it has landed, else
    /// `nil` and a warm-up started.
    static func resolvedBinaryIfReady() -> String? {
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

    static var isAvailabilityResolved: Bool {
        primeFromDisk()
        guard resolveLock.try() else { return false }
        defer { resolveLock.unlock() }
        return cachedBinary != nil
    }

    /// Installed and holding a model key.
    static var isAvailable: Bool { resolvedBinaryIfReady() != nil && authExists() }

    private static var dshHome: String {
        if let home = ProcessInfo.processInfo.environment["DSH_HOME"], !home.isEmpty {
            return (home as NSString).expandingTildeInPath
        }
        return "\(NSHomeDirectory())/.dsh"
    }

    private static let apiKeyName = "DEEPSEEK_API_KEY"

    private static let authCacheLock = NSLock()
    private static var authCache: (credentials: Date?, env: Date?, exists: Bool)?

    /// Whether dsh has a DeepSeek credential: `DEEPSEEK_API_KEY` in the launch
    /// environment, under `refs` in `.credentials.yaml`, or in dsh's home `.env`,
    /// or a DeepSeek account record under `records`. Only entry names are matched.
    static func authExists() -> Bool {
        if let key = ProcessInfo.processInfo.environment[apiKeyName],
           !key.trimmingCharacters(in: .whitespaces).isEmpty { return true }

        let credentialsPath = "\(dshHome)/.credentials.yaml"
        let envPath = "\(dshHome)/.env"
        let fm = FileManager.default
        let credentialsDate = (try? fm.attributesOfItem(atPath: credentialsPath))?[.modificationDate] as? Date
        let envDate = (try? fm.attributesOfItem(atPath: envPath))?[.modificationDate] as? Date

        authCacheLock.lock(); defer { authCacheLock.unlock() }
        if let cached = authCache, cached.credentials == credentialsDate, cached.env == envDate {
            return cached.exists
        }
        let exists = (credentialsDate != nil && credentialsHaveKey(at: credentialsPath))
            || (envDate != nil && envFileHasKey(at: envPath))
        authCache = (credentialsDate, envDate, exists)
        return exists
    }

    private static func credentialsHaveKey(at path: String) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        var section = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                section = trimmed.hasSuffix(":") ? String(trimmed.dropLast()) : ""
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let name = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            let rest = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch section {
            case "refs":
                if name == apiKeyName, !rest.isEmpty { return true }
            case "records":
                // A record key is `<owner>/<id>`; DeepSeek's routes are owned by the
                // `llm-deepseek` entries.
                if name.hasPrefix("llm-deepseek") { return true }
            default:
                break
            }
        }
        return false
    }

    private static func envFileHasKey(at path: String) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        for raw in text.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if name == apiKeyName, !value.isEmpty { return true }
        }
        return false
    }

    static var isInstalled: Bool { resolvedBinaryIfReady() != nil }

    // MARK: - Settings

    /// dsh's Web UI address with the shipped profile's defaults.
    private static let webURL = URL(string: "http://127.0.0.1:3080")!

    /// Open dsh's Web UI, where its Models page sets the provider and key. Reuses a
    /// server already listening; otherwise starts `dsh --profile web`, which opens
    /// the browser itself and keeps serving after Notch quits.
    static func openSettings() {
        var request = URLRequest(url: webURL)
        request.timeoutInterval = 1
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if response != nil {
                DispatchQueue.main.async { NSWorkspace.shared.open(webURL) }
                return
            }
            guard let binary = resolveBinary() else { return }
            let p = ShellEnvironment.makeProcess(binary, ["--profile", "web"])
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }.resume()
    }

    /// Resolve the binary off the main thread. Idempotent while one is in flight.
    static func warmUp() {
        primeFromDisk()
        warmLock.lock()
        guard !warmingUp else { warmLock.unlock(); return }
        warmingUp = true
        warmLock.unlock()
        DispatchQueue.global(qos: .utility).async {
            _ = resolveBinary()
            revalidateSeed()
            warmLock.lock(); warmingUp = false; warmLock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .cliAvailabilityResolved, object: nil)
            }
        }
    }

    /// Adopt the previous launch's path if the file is still executable, so the
    /// engine is listed before this launch's probe finishes.
    private static func primeFromDisk() {
        primeLock.lock()
        guard !primed else { primeLock.unlock(); return }
        primed = true
        primeLock.unlock()
        guard let path = UserDefaults.standard.string(forKey: storedPathKey),
              FileManager.default.isExecutableFile(atPath: path)
        else { return }
        resolveLock.lock()
        if cachedBinary == nil {
            cachedBinary = .some(path)
            seededFromDisk = true
        }
        resolveLock.unlock()
    }

    /// Re-check a remembered path; if it no longer answers as dsh, resolve again.
    private static func revalidateSeed() {
        resolveLock.lock()
        let seeded = seededFromDisk
        let path = cachedBinary ?? nil
        seededFromDisk = false
        resolveLock.unlock()
        guard seeded, let path, !isHarness(path) else { return }
        resolveLock.lock()
        cachedBinary = nil
        resolveLock.unlock()
        _ = resolveBinary()
    }

    private static func remember(_ path: String?) {
        if let path {
            UserDefaults.standard.set(path, forKey: storedPathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storedPathKey)
        }
    }

    private static func locateBinary() -> String? {
        let fm = FileManager.default
        for p in candidatePaths where fm.isExecutableFile(atPath: p) && isHarness(p) {
            return p
        }
        if let p = ShellEnvironment.which(["dsh"]), isHarness(p) { return p }
        return nil
    }

    /// Whether `path` is DeepSeek Harness. `dsh` is also the name of an unrelated
    /// distributed-shell tool, so the help text decides, not the file name.
    private static func isHarness(_ path: String) -> Bool {
        let p = ShellEnvironment.makeProcess(path, ["--help"])
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("DeepSeek Harness")
    }
}

// MARK: - Chat

extension DshCLIService {
    /// A chat turn may still run tools, so the limit is generous; the real stop
    /// signal is the surrounding `Task` being cancelled.
    private static let timeout: TimeInterval = 180

    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let binary = Self.resolveBinary() else {
                continuation.finish(throwing: DshError.notInstalled); return
            }
            // Headless has no system-prompt flag, so the persona is folded into
            // the prompt with the conversation.
            let prompt = CodexCLIService.composePrompt(system: system, messages: messages)
            let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("notch-dsh-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            let process = ShellEnvironment.makeProcess(
                binary, ["--profile", "headless", "--json"] + Self.modelArgs(for: model),
                cwd: workDir)
            let outPipe = Pipe(), inPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardInput = inPipe
            process.standardError = errPipe

            let audit = RequestAudit.shared.begin(provider: Provider.dshCode.displayName,
                                                  model: model ?? "",
                                                  host: "dsh",
                                                  transport: .cli)
            audit.attempt()
            audit.command(binary, ["--profile", "headless", "--json"] + Self.modelArgs(for: model), stdin: prompt)
            let state = DshChatStreamState()
            state.audit = audit
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { state.ingest(data) }
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
                // Pick up whatever the handler had not read yet.
                state.ingest(outPipe.fileHandleForReading.readDataToEndOfFile())
                try? FileManager.default.removeItem(at: workDir)

                let snapshot = state.finish()
                if let msg = snapshot.failure {
                    audit.finish(.failed, kind: "cli")
                    continuation.finish(throwing: DshError.classify(msg))
                } else if !snapshot.answer.isEmpty {
                    // dsh's `--json` carries whole blocks, not token deltas, so the
                    // answer arrives in one piece.
                    audit.firstToken()
                    continuation.yield(snapshot.answer)
                    audit.finish(.ok)
                    continuation.finish()
                } else if proc.terminationStatus != 0 {
                    audit.finish(.failed, kind: "cli")
                    continuation.finish(throwing: DshError.classify(snapshot.stderrTail))
                } else {
                    audit.finish(.failed, kind: "cli")
                    continuation.finish(throwing: DshError.noOutput)
                }
            }

            continuation.onTermination = { _ in
                if process.isRunning {
                    audit.finish(.cancelled)
                    process.terminate()
                }
            }

            do {
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: workDir)
                audit.finish(.failed, kind: "spawn")
                continuation.finish(throwing: DshError.spawnFailed(error.localizedDescription))
                return
            }

            // With no positional task, headless reads it from stdin.
            let writer = inPipe.fileHandleForWriting
            writer.write(Data(prompt.utf8))
            try? writer.close()
        }
    }
}

/// Line-buffers a chat turn's `--json` stream. The answer is the `final` event's
/// text; a failed turn ends with an empty `final` and an error `turn_end` reason,
/// and a failure outside a turn writes an `error` event instead.
private final class DshChatStreamState: @unchecked Sendable {
    /// The request this stream is answering, so reported usage lands on its
    /// audit record as well as the running token total.
    var audit: RequestAudit.Ticket?
    private let lock = NSLock()
    private var buffer = Data()
    private var stderrTail = ""
    private var answer = ""
    private var failure: String?
    private var turnFailure: String?

    struct Snapshot {
        let answer: String
        let failure: String?
        let stderrTail: String
    }

    func ingest(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }
            switch type {
            case "status":
                if obj["phase"] as? String == "step_end",
                   let usage = obj["usage"] as? [String: Any] {
                    let input = (usage["inputTokens"] as? Int ?? 0)
                        + (usage["cacheReadTokens"] as? Int ?? 0)
                        + (usage["cacheWriteTokens"] as? Int ?? 0)
                    TokenMeter.shared.record(input: input,
                                             output: usage["outputTokens"] as? Int ?? 0)
                    audit?.tokens(input: input, output: usage["outputTokens"] as? Int ?? 0)
                } else if obj["phase"] as? String == "turn_end" {
                    let reason = obj["reason"] as? [String: Any]
                    switch reason?["kind"] as? String {
                    case "completed":
                        turnFailure = nil
                    case "error":
                        let err = reason?["error"] as? [String: Any]
                        turnFailure = (err?["message"] as? String)
                            .flatMap { $0.isEmpty ? nil : $0 } ?? "unknown error"
                    default:
                        turnFailure = (reason?["kind"] as? String) ?? "unknown error"
                    }
                }
            case "final":
                answer = (obj["text"] as? String) ?? ""
            case "error":
                failure = (obj["message"] as? String)
                    .flatMap { $0.isEmpty ? nil : $0 } ?? "unknown error"
            default:
                break
            }
        }
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
        return Snapshot(answer: answer.trimmingCharacters(in: .whitespacesAndNewlines),
                        failure: failure ?? turnFailure, stderrTail: tail)
    }
}

// MARK: - Errors

enum DshError: LocalizedError {
    case notInstalled
    case authMissing
    case noOutput
    case spawnFailed(String)
    case runFailed(String)

    /// dsh reports a missing or rejected key as the provider's own error, or as a
    /// credential lookup failure naming the variable.
    static func isAuthFailure(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("deepseek_api_key")
            || m.contains("credential")
            || m.contains("unauthorized")
            || m.contains("invalid api key")
            || m.contains("authentication")
            || m.contains("401")
    }

    static func classify(_ message: String) -> DshError {
        isAuthFailure(message) ? .authMissing : .runFailed(message)
    }

    var errorDescription: String? {
        switch self {
        case .notInstalled: return L("dsh.error.notInstalled")
        case .authMissing:  return L("dsh.error.auth")
        case .noOutput:     return L("dsh.error.noOutput")
        case .spawnFailed(let detail):
            return L("dsh.error.spawnFailed") + (detail.isEmpty ? "" : " " + detail)
        case .runFailed(let detail):
            return L("dsh.error.runFailed") + (detail.isEmpty ? "" : " " + detail)
        }
    }
}
