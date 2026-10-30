import Foundation
import AppKit

// MARK: - InstaBox HTTP

/// An error InstaBox answered with. `code` is `error.code`, the field its docs
/// say to branch on; the message is passed on to the model as written.
struct InstaBoxFailure: LocalizedError, Sendable {
    let status: Int
    let code: String
    let message: String
    let retryAfter: TimeInterval?

    var errorDescription: String? { "InstaBox: \(message) (\(code))" }

    static func parse(_ data: Data, status: Int) -> InstaBoxFailure {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        // The general shape nests the fields under `error`. The token poll is
        // modelled on the OAuth device flow, so a flat `error` string is read too.
        let nested = object["error"] as? [String: Any]
        let code = nested?["code"] as? String ?? object["error"] as? String ?? object["code"] as? String ?? "http_\(status)"
        let message = nested?["message"] as? String ?? object["message"] as? String ?? "HTTP \(status)"
        let retry = (nested?["retryAfterSeconds"] ?? object["retryAfterSeconds"]) as? NSNumber
        return InstaBoxFailure(status: status, code: code, message: message,
                               retryAfter: retry?.doubleValue)
    }
}

enum InstaBoxAPI {
    private static let base = "https://api.instabox.sh"

    static func request(_ method: String, _ path: String,
                        query: [URLQueryItem] = [],
                        key: String?,
                        idempotent: Bool = false,
                        timeout: TimeInterval = 40) -> URLRequest {
        var parts = URLComponents(string: base + path)!
        if !query.isEmpty { parts.queryItems = query }
        var req = URLRequest(url: parts.url!)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let key { req.setValue(key, forHTTPHeaderField: "X-API-Key") }
        if idempotent { req.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key") }
        return req
    }

    /// Send and return the body of a 2xx answer; anything else throws
    /// `InstaBoxFailure`. A rejected key disconnects the account.
    @discardableResult
    static func send(_ request: URLRequest, json: [String: Any]? = nil) async throws -> Data {
        var request = request
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await ProxyConfig.urlSession.data(for: request)
        try check(response, body: data, sentKey: request.value(forHTTPHeaderField: "X-API-Key") != nil)
        return data
    }

    static func check(_ response: URLResponse, body: Data, sentKey: Bool) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard !(200..<300).contains(status) else { return }
        if status == 401, sentKey {
            Task { @MainActor in InstaBoxAccount.shared.keyWasRejected() }
        }
        throw InstaBoxFailure.parse(body, status: status)
    }

    static func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

// MARK: - Account

/// The user's own InstaBox account. Connecting asks InstaBox for an API key
/// with `POST /v1/auth/agent`: the user approves it on InstaBox's page, in their
/// browser, and the poll below collects the key. Usage is billed to that account;
/// nothing passes through Notchi's backend.
@MainActor
final class InstaBoxAccount: ObservableObject {
    static let shared = InstaBoxAccount()

    enum State: Equatable {
        case off
        case claiming(code: String, page: URL)
        case connected(login: String)
        case failed
    }

    @Published private(set) var state: State = .off
    private var claim: Task<Void, Never>?

    private static let enabledKey = "instabox.enabled"
    private static let loginKey = "instabox.login"
    /// `machines:write` includes read and covers exec, files and ports. It does
    /// not reach deleting machines, which only the dashboard does.
    private static let scopes = ["machines:write"]

    /// Whether a round offers `cloud_machine`.
    nonisolated static var isAvailable: Bool {
        DebugFeatureFlags.cloudMachine
            && UserDefaults.standard.bool(forKey: enabledKey) && APIKeyStore.currentInstaBoxKey() != nil
    }

    private init() {
        if Self.isAvailable {
            state = .connected(login: UserDefaults.standard.string(forKey: Self.loginKey) ?? "")
        }
    }

    var isOn: Bool {
        if case .off = state { return false }
        if case .failed = state { return false }
        return true
    }

    func setOn(_ on: Bool) {
        claim?.cancel()
        claim = nil
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        guard on else {
            state = .off
            return
        }
        if APIKeyStore.currentInstaBoxKey() != nil {
            state = .connected(login: UserDefaults.standard.string(forKey: Self.loginKey) ?? "")
            refresh()
        } else {
            claim = Task { await runClaim() }
        }
    }

    /// Reads who the key belongs to. A key InstaBox rejects disconnects in
    /// `InstaBoxAPI.check`.
    func refresh() {
        guard Self.isAvailable, let key = APIKeyStore.currentInstaBoxKey() else { return }
        Task {
            guard let data = try? await InstaBoxAPI.send(InstaBoxAPI.request("GET", "/v1/me", key: key)),
                  let login = InstaBoxAPI.object(data)["login"] as? String else { return }
            UserDefaults.standard.set(login, forKey: Self.loginKey)
            if case .connected = state { state = .connected(login: login) }
        }
    }

    /// Removes the key from this Mac. The key stays listed on the account until
    /// it is revoked there, and so does the machine.
    func disconnect() {
        setOn(false)
        APIKeyStore.saveInstaBoxKey("")
        UserDefaults.standard.removeObject(forKey: Self.loginKey)
        Task { await InstaBoxMachine.shared.forget() }
    }

    func keyWasRejected() {
        guard APIKeyStore.currentInstaBoxKey() != nil else { return }
        disconnect()
        state = .failed
    }

    func openClaimPage() {
        if case .claiming(_, let page) = state { NSWorkspace.shared.open(page) }
    }

    func openDashboard() {
        if let url = URL(string: "https://dashboard.instabox.sh") { NSWorkspace.shared.open(url) }
    }

    private func runClaim() async {
        do {
            let data = try await InstaBoxAPI.send(
                InstaBoxAPI.request("POST", "/v1/auth/agent", key: nil),
                json: ["name": "Notchi", "scopes": Self.scopes])
            let reply = InstaBoxAPI.object(data)
            guard let token = reply["claimToken"] as? String,
                  let code = reply["userCode"] as? String,
                  let raw = reply["verificationUriComplete"] as? String,
                  let page = URL(string: raw) else {
                throw InstaBoxFailure(status: 0, code: "bad_reply", message: "Unexpected reply.", retryAfter: nil)
            }
            state = .claiming(code: code, page: page)
            NSWorkspace.shared.open(page)
            var wait = (reply["interval"] as? NSNumber)?.doubleValue ?? 5
            let deadline = Date().addingTimeInterval((reply["expiresIn"] as? NSNumber)?.doubleValue ?? 86_400)
            while Date() < deadline {
                try await Task.sleep(for: .seconds(wait))
                do {
                    let body = try await InstaBoxAPI.send(
                        InstaBoxAPI.request("POST", "/v1/auth/agent/token", key: nil),
                        json: ["claimToken": token])
                    try await finishClaim(body, token: token)
                    return
                } catch let failure as InstaBoxFailure {
                    switch failure.code {
                    case "authorization_pending":
                        if let next = failure.retryAfter { wait = next }
                    case "slow_down":
                        wait = failure.retryAfter ?? wait * 2
                    default:
                        throw failure
                    }
                } catch is URLError {
                    // A network drop during a wait of up to a day. The next poll tries again.
                }
            }
            throw InstaBoxFailure(status: 0, code: "expired_token", message: "The code expired.", retryAfter: nil)
        } catch is CancellationError {
        } catch {
            DiagnosticsLog.shared.record(provider: "InstaBox", kind: "claim-failed")
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            state = .failed
        }
    }

    private func finishClaim(_ body: Data, token: String) async throws {
        let reply = InstaBoxAPI.object(body)
        guard let key = reply["key"] as? String else {
            throw InstaBoxFailure(status: 0, code: "bad_reply", message: "Unexpected reply.", retryAfter: nil)
        }
        APIKeyStore.saveInstaBoxKey(key)
        let login = reply["login"] as? String ?? ""
        UserDefaults.standard.set(login, forKey: Self.loginKey)
        state = .connected(login: login)
        claim = nil
        // Ends the window in which the same token hands the key out again.
        _ = try? await InstaBoxAPI.send(InstaBoxAPI.request("POST", "/v1/auth/agent/token", key: nil),
                                        json: ["claimToken": token, "ack": true])
    }
}

// MARK: - Machine

/// The one machine Notchi keeps on the user's account, created on first use and
/// found again by its label. It pauses itself when idle and exec wakes it, so
/// Notchi never pauses it: a machine paused by request does not wake on use.
actor InstaBoxMachine {
    static let shared = InstaBoxMachine()

    private static let idKey = "instabox.machineID"
    private static let label = "app:notchi"
    private var machineID = UserDefaults.standard.string(forKey: InstaBoxMachine.idKey)
    /// Shared by callers that arrive while the machine is being prepared, so
    /// two rounds cannot create two machines.
    private var preparing: Task<String, Error>?

    private func key() throws -> String {
        guard let key = APIKeyStore.currentInstaBoxKey() else {
            throw InstaBoxFailure(status: 0, code: "not_connected",
                                  message: "The cloud machine is not connected.", retryAfter: nil)
        }
        return key
    }

    func forget() {
        machineID = nil
        UserDefaults.standard.removeObject(forKey: Self.idKey)
    }

    private func remember(_ id: String) {
        machineID = id
        UserDefaults.standard.set(id, forKey: Self.idKey)
    }

    /// The machine's ID, once a call to it can succeed.
    func ready() async throws -> String {
        if let preparing { return try await preparing.value }
        let task = Task { try await self.prepare() }
        preparing = task
        defer { preparing = nil }
        return try await task.value
    }

    private func prepare() async throws -> String {
        let key = try key()
        if machineID == nil { machineID = try await findLabelled(key: key) }
        guard let id = machineID else { return try await create(key: key) }

        let machine: [String: Any]
        do {
            machine = InstaBoxAPI.object(try await InstaBoxAPI.send(
                InstaBoxAPI.request("GET", "/v1/machines/\(id)", key: key)))
        } catch let failure as InstaBoxFailure where failure.status == 404 {
            forget()
            return try await create(key: key)
        }
        if let operation = machine["operationId"] as? String {
            try await follow(operation, key: key)
            return id
        }
        switch machine["state"] as? String {
        case "suspended":
            if machine["autoSuspendedAt"] is String { return id }
            try await change(id, "resume", key: key)
        case "stopped":
            try await change(id, "start", key: key)
        case "deleting":
            forget()
            return try await create(key: key)
        case "error":
            throw InstaBoxFailure(status: 0, code: "machine_error",
                                  message: "The machine is in an error state. Open the InstaBox dashboard to restart it.",
                                  retryAfter: nil)
        default:
            break
        }
        return id
    }

    private func findLabelled(key: String) async throws -> String? {
        let data = try await InstaBoxAPI.send(InstaBoxAPI.request(
            "GET", "/v1/machines",
            query: [URLQueryItem(name: "metadata", value: Self.label)], key: key))
        let machines = InstaBoxAPI.object(data)["machines"] as? [[String: Any]] ?? []
        guard let id = machines.first?["id"] as? String else { return nil }
        remember(id)
        return id
    }

    /// `vault` and `secrets` keep the account's stored credentials out of it:
    /// the model runs what it likes in this machine.
    private func create(key: String) async throws -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let data = try await InstaBoxAPI.send(
            InstaBoxAPI.request("POST", "/v1/machines", key: key, idempotent: true),
            json: ["name": "notchi-\(suffix)",
                   "templateId": "agent-browser",
                   "metadata": ["app": "notchi"],
                   "vault": false,
                   "secrets": [String]()])
        let reply = InstaBoxAPI.object(data)
        guard let id = reply["machineId"] as? String, let operation = reply["id"] as? String else {
            throw InstaBoxFailure(status: 0, code: "bad_reply", message: "Unexpected reply.", retryAfter: nil)
        }
        remember(id)
        try await follow(operation, key: key)
        return id
    }

    private func change(_ id: String, _ action: String, key: String) async throws {
        let data = try await InstaBoxAPI.send(
            InstaBoxAPI.request("POST", "/v1/machines/\(id)/\(action)", key: key, idempotent: true))
        guard let operation = InstaBoxAPI.object(data)["id"] as? String else { return }
        try await follow(operation, key: key)
    }

    private func follow(_ operation: String, key: String) async throws {
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            let data = try await InstaBoxAPI.send(InstaBoxAPI.request(
                "GET", "/v1/operations/\(operation)",
                query: [URLQueryItem(name: "wait", value: "25s")], key: key))
            let reply = InstaBoxAPI.object(data)
            switch reply["state"] as? String {
            case "succeeded":
                return
            case "failed":
                let error = reply["error"] as? [String: Any]
                throw InstaBoxFailure(status: 0, code: error?["code"] as? String ?? "operation_failed",
                                      message: error?["message"] as? String ?? "The machine could not start.",
                                      retryAfter: (error?["retryAfterSeconds"] as? NSNumber)?.doubleValue)
            default:
                continue
            }
        }
        throw InstaBoxFailure(status: 0, code: "operation_timeout",
                              message: "The machine took more than 5 minutes to get ready.", retryAfter: nil)
    }

    /// Run a request against the machine. Exec takes no idempotency key and a
    /// retry runs the command again, so only answers that say the request was
    /// refused are retried.
    private func withMachine<T: Sendable>(_ body: @Sendable (_ id: String, _ key: String) async throws -> T) async throws -> T {
        var attempt = 0
        var recovered = false
        while true {
            let id = try await ready()
            do {
                return try await body(id, try key())
            } catch let failure as InstaBoxFailure {
                attempt += 1
                switch failure.code {
                case "operation_conflict", "rate_limited", "quota_exceeded":
                    guard attempt < 4 else { throw failure }
                    try await Task.sleep(for: .seconds(min(failure.retryAfter ?? 3, 30)))
                case "machine_not_running", "not_found":
                    // `not_found` from exec is the machine; a file call's is the path.
                    guard !recovered, failure.code == "machine_not_running" else { throw failure }
                    recovered = true
                default:
                    throw failure
                }
            }
        }
    }

    func exec(_ command: String, env: [String: String] = [:], cwd: String?,
              timeout: TimeInterval) async throws -> (output: String, exitCode: Int, timedOut: Bool) {
        let data = try await withMachine { id, key in
            // Waking takes up to 45 seconds on top of the command's own time.
            var body: [String: Any] = ["cmd": command, "timeoutSeconds": Int(timeout)]
            if !env.isEmpty { body["envs"] = env }
            if let cwd { body["cwd"] = cwd }
            let request = InstaBoxAPI.request("POST", "/v1/machines/\(id)/exec", key: key,
                                              timeout: timeout + 75)
            return try await InstaBoxAPI.send(request, json: body)
        }
        let reply = InstaBoxAPI.object(data)
        var output = reply["stdout"] as? String ?? ""
        if let err = reply["stderr"] as? String, !err.isEmpty {
            output += (output.isEmpty || output.hasSuffix("\n") ? "" : "\n") + err
        }
        if reply["truncated"] as? Bool == true { output += "\n[Output cut at 1 MiB.]" }
        return (output, (reply["exitCode"] as? NSNumber)?.intValue ?? -1, reply["timedOut"] as? Bool ?? false)
    }

    func read(_ path: String) async throws -> Data {
        try await withMachine { id, key in
            try await InstaBoxAPI.send(InstaBoxAPI.request(
                "GET", "/v1/machines/\(id)/files/content",
                query: [URLQueryItem(name: "path", value: path)], key: key, timeout: 60))
        }
    }

    func write(_ data: Data, to path: String) async throws {
        try await withMachine { id, key in
            var request = InstaBoxAPI.request(
                "PUT", "/v1/machines/\(id)/files",
                query: [URLQueryItem(name: "path", value: path),
                        URLQueryItem(name: "parents", value: "true")], key: key, timeout: 120)
            request.httpBody = data
            try await InstaBoxAPI.send(request)
        }
    }

    func upload(_ file: URL, to path: String) async throws {
        try await withMachine { id, key in
            let request = InstaBoxAPI.request(
                "PUT", "/v1/machines/\(id)/files",
                query: [URLQueryItem(name: "path", value: path),
                        URLQueryItem(name: "parents", value: "true")], key: key, timeout: 120)
            let (body, response) = try await ProxyConfig.urlSession.upload(for: request, fromFile: file)
            try InstaBoxAPI.check(response, body: body, sentKey: true)
        }
    }

    /// The downloaded file, in the temp folder. The caller moves it.
    func download(_ path: String) async throws -> URL {
        try await withMachine { id, key in
            let request = InstaBoxAPI.request(
                "GET", "/v1/machines/\(id)/files/content",
                query: [URLQueryItem(name: "path", value: path)], key: key, timeout: 120)
            let (temp, response) = try await ProxyConfig.urlSession.download(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let body = (try? Data(contentsOf: temp)) ?? Data()
                try? FileManager.default.removeItem(at: temp)
                try InstaBoxAPI.check(response, body: body, sentKey: true)
                throw InstaBoxFailure.parse(body, status: status)
            }
            return temp
        }
    }

    func publish(port: Int) async throws -> String {
        let data = try await withMachine { id, key in
            try await InstaBoxAPI.send(InstaBoxAPI.request("POST", "/v1/machines/\(id)/ports", key: key),
                                       json: ["port": port])
        }
        return InstaBoxAPI.object(data)["url"] as? String ?? ""
    }
}

// MARK: - Tool

/// Runs work on the user's InstaBox machine instead of this Mac. Separate from
/// `run_shell` because the two reach different computers and the model has to
/// choose. Commands there touch nothing on this Mac, so `shell`, `read` and
/// `write` ask nothing. What crosses between the two, or opens the machine to the
/// internet, waits on a card; `confirm` is nil where no one is at the Mac, and
/// those actions are then refused.
struct CloudMachineTool: NotchTool {
    static let toolName = "cloud_machine"
    let name = CloudMachineTool.toolName
    let description = """
    Uses the user's own Linux machine in the cloud (Debian amd64, 4 vCPU, 8 GB, \
    passwordless sudo; Docker, Node, Python, Go, Rust, git, gh and Chromium installed). \
    It is not this Mac: it has none of the user's files or apps, and files on it stay \
    between calls. Home is /data/home. action=shell runs a bash command, up to 600 \
    seconds; background=true starts a longer job and returns a log path. \
    action=read and action=write handle text files on it. action=upload copies a file or \
    folder from this Mac to it and action=download saves a file from it to Downloads; \
    action=publish_port gives a port a public URL. These three ask the user first. \
    The first call can take a minute while the machine starts.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["shell", "read", "write", "upload", "download", "publish_port"]],
            "command": ["type": "string", "description": "action=shell: the bash command."],
            "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 600,
                                "description": "action=shell: seconds before it is stopped. Default 60."],
            "background": ["type": "boolean",
                           "description": "action=shell: start it and return at once with its log file."],
            "cwd": ["type": "string", "description": "action=shell: working directory. Default /data/home."],
            "path": ["type": "string",
                     "description": "read, write, download: the path on the machine. upload: where to put it there."],
            "content": ["type": "string", "description": "action=write: the file's full text."],
            "local_path": ["type": "string", "description": "action=upload: the file or folder on this Mac."],
            "port": ["type": "integer", "description": "action=publish_port: the port the server listens on."],
        ],
        "required": ["action"],
    ]

    /// Shows a question on the round's card; true when the user allowed it.
    let confirm: (@Sendable (String) async throws -> Bool)?

    private static let readLimit = 800_000
    private static let uploadLimit = 2_000_000_000
    /// Left out of a folder upload: rebuildable, or likely to hold credentials.
    private static let uploadExcludes = ["node_modules", ".build", "DerivedData", ".DS_Store",
                                         ".env", ".env.*", "*.pem", "*.key", "id_rsa", "id_ed25519"]

    func execute(_ input: [String: Any]) async throws -> String {
        switch input["action"] as? String {
        case "shell": return try await shell(input)
        case "read": return try await read(input)
        case "write": return try await write(input)
        case "upload": return try await upload(input)
        case "download": return try await download(input)
        case "publish_port": return try await publish(input)
        default: return "Error: action must be shell, read, write, upload, download or publish_port."
        }
    }

    private static func text(_ input: [String: Any], _ key: String) -> String? {
        guard let value = (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    /// File calls take absolute paths only.
    private static func remotePath(_ raw: String) -> String {
        if raw.hasPrefix("/") { return raw }
        if raw == "~" { return "/data/home" }
        if raw.hasPrefix("~/") { return "/data/home/" + raw.dropFirst(2) }
        return "/data/home/" + raw
    }

    private func shell(_ input: [String: Any]) async throws -> String {
        guard let command = Self.text(input, "command") else { return "Error: command is required." }
        let cwd = Self.text(input, "cwd")
        if (input["background"] as? Bool) == true || (input["background"] as? String) == "true" {
            // The command rides an env var, so it needs no quoting. A job's output
            // must go to a file: its later writes to exec's output fail once exec returns.
            let log = "/data/home/.notchi/jobs/job-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).log"
            let start = """
            mkdir -p /data/home/.notchi/jobs && nohup bash -c 'bash -lc "$NOTCHI_JOB"; echo "[exit code: $?]"' >\(log) 2>&1 </dev/null & echo $!
            """
            let result = try await InstaBoxMachine.shared.exec(start, env: ["NOTCHI_JOB": command],
                                                               cwd: cwd, timeout: 60)
            let pid = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return """
            Started on the cloud machine, pid \(pid). Output goes to \(log); the last line reads \
            [exit code: N] once it ends. Check it with action=shell (tail \(log)), stop it with kill \(pid). \
            The machine pauses after 30 idle minutes, and a job that only waits can pause with it.
            """
        }
        let timeout = (input["timeout_seconds"] as? NSNumber).map { min(max($0.doubleValue, 1), 600) } ?? 60
        let result = try await InstaBoxMachine.shared.exec(command, cwd: cwd, timeout: timeout)
        let head = result.timedOut ? "[stopped after \(Int(timeout)) seconds]" : "[exit code: \(result.exitCode)]"
        return result.output.isEmpty ? head : head + "\n" + result.output
    }

    private func read(_ input: [String: Any]) async throws -> String {
        guard let raw = Self.text(input, "path") else { return "Error: path is required." }
        let data = try await InstaBoxMachine.shared.read(Self.remotePath(raw))
        guard let text = String(data: data.prefix(Self.readLimit), encoding: .utf8) else {
            return "This is not a text file (\(data.count) bytes). Use action=download."
        }
        return data.count > Self.readLimit ? text + "\n[Cut at \(Self.readLimit) bytes of \(data.count).]" : text
    }

    private func write(_ input: [String: Any]) async throws -> String {
        guard let raw = Self.text(input, "path") else { return "Error: path is required." }
        guard let content = input["content"] as? String else { return "Error: content is required." }
        let path = Self.remotePath(raw)
        try await InstaBoxMachine.shared.write(Data(content.utf8), to: path)
        return "Saved \(path) on the cloud machine."
    }

    private func upload(_ input: [String: Any]) async throws -> String {
        guard let confirm else { return "Uploading needs the user at their Mac. It was not done." }
        guard let raw = Self.text(input, "local_path") else { return "Error: local_path is required." }
        let local = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        let lowered = local.path.lowercased()
        if ShellRisk.credentialPaths.contains(where: { lowered.contains($0) }) {
            return "This path holds credentials. It was not uploaded."
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isFolder) else {
            return "Error: \(local.path) does not exist."
        }
        let destination = Self.remotePath(Self.text(input, "path") ?? local.lastPathComponent)
        guard try await confirm(L("cloud.confirm.upload", local.path, destination)) else {
            return "The user did not approve this upload. It was not done. Do not retry it."
        }
        guard isFolder.boolValue else {
            try Self.checkSize(local)
            try await InstaBoxMachine.shared.upload(local, to: destination)
            return "Uploaded \(local.lastPathComponent) to \(destination)."
        }
        let archive = try await Self.pack(local)
        defer { try? FileManager.default.removeItem(at: archive) }
        try Self.checkSize(archive)
        let remoteArchive = "/data/home/.notchi/uploads/\(UUID().uuidString).tgz"
        try await InstaBoxMachine.shared.upload(archive, to: remoteArchive)
        let unpack = try await InstaBoxMachine.shared.exec(
            "mkdir -p \"$NOTCHI_DEST\" && tar xzf \"$NOTCHI_ARCHIVE\" -C \"$NOTCHI_DEST\"; code=$?; rm -f \"$NOTCHI_ARCHIVE\"; exit $code",
            env: ["NOTCHI_DEST": destination, "NOTCHI_ARCHIVE": remoteArchive], cwd: nil, timeout: 300)
        guard unpack.exitCode == 0 else { return "Error: unpacking failed: \(unpack.output)" }
        return "Uploaded the folder into \(destination). Left out: \(Self.uploadExcludes.joined(separator: ", "))."
    }

    private static func checkSize(_ file: URL) throws {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= uploadLimit else {
            throw InstaBoxFailure(status: 0, code: "too_large",
                                  message: "\(file.lastPathComponent) is over 2 GB.", retryAfter: nil)
        }
    }

    /// The folder's contents as a gzipped tar in the temp folder.
    private static func pack(_ folder: URL) async throws -> URL {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchi-upload-\(UUID().uuidString).tgz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = uploadExcludes.flatMap { ["--exclude", $0] }
            + ["-czf", archive.path, "-C", folder.path, "."]
        // No AppleDouble `._` files on the Linux side.
        process.environment = ["COPYFILE_DISABLE": "1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }
        guard status == 0 else {
            try? FileManager.default.removeItem(at: archive)
            throw InstaBoxFailure(status: 0, code: "pack_failed",
                                  message: "Could not pack \(folder.lastPathComponent).", retryAfter: nil)
        }
        return archive
    }

    private func download(_ input: [String: Any]) async throws -> String {
        guard confirm != nil else { return "Saving to this Mac needs the user at it. It was not done." }
        guard let raw = Self.text(input, "path") else { return "Error: path is required." }
        let path = Self.remotePath(raw)
        let temp = try await InstaBoxMachine.shared.download(path)
        let fm = FileManager.default
        let folder = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = (path as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var target = folder.appendingPathComponent(name)
        var copy = 1
        while fm.fileExists(atPath: target.path) {
            copy += 1
            target = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(copy)" : "\(stem) \(copy).\(ext)")
        }
        try fm.moveItem(at: temp, to: target)
        return "Saved to \(target.path)."
    }

    private func publish(_ input: [String: Any]) async throws -> String {
        guard let confirm else { return "Publishing a port needs the user at their Mac. It was not done." }
        guard let port = (input["port"] as? NSNumber)?.intValue else { return "Error: port is required." }
        guard try await confirm(L("cloud.confirm.publish", String(port))) else {
            return "The user did not approve publishing this port. It was not done. Do not retry it."
        }
        let url = try await InstaBoxMachine.shared.publish(port: port)
        return "Port \(port) is public at \(url). Anyone with the link can open it."
    }
}
