import Foundation
import AppKit
import SwiftUI

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

    /// Why a round goes without `cloud_machine` while the feature is built in:
    /// the system prompt says it, so the model tells the user instead of
    /// looking for the tool on this Mac. `nil` when the tool is offered or the
    /// feature is off.
    nonisolated static var unavailableReason: String? {
        guard DebugFeatureFlags.cloudMachine, !isAvailable else { return nil }
        if !UserDefaults.standard.bool(forKey: enabledKey) {
            return "it is turned off in Settings → Chat → Cloud machine"
        }
        return "it is not connected to an InstaBox account; turning it on in Settings → Chat → Cloud machine connects it"
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
            // The switch keeps the value the user set. Writing false here once
            // left a connected key unused: `isAvailable` went false, the tool
            // dropped out of every round with no word to the model, and it
            // spent a round hunting for it (2026-11-03).
            DiagnosticsLog.shared.record(provider: "InstaBox", kind: "claim-failed")
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
            // Debian marks the system Python as externally managed, so a plain
            // `pip install` exits 1. On 2026-11-12 a model lost three calls to
            // that before adding --break-system-packages by hand.
            body["envs"] = Self.baseEnv.merging(env) { _, given in given }
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

    /// Set on every command: `pip install` works without extra flags.
    private static let baseEnv = ["PIP_BREAK_SYSTEM_PACKAGES": "1"]

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
/// internet, waits on a card.
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
    action=show_image takes an image file on the machine (a screenshot you made, a \
    chart) and returns a Markdown image line for your answer; use it to show the user \
    a picture, not publish_port. pip install works without extra flags. \
    It also has a desktop with Chromium that you drive: action=browse opens a URL \
    and returns the page as numbered elements (fields, check boxes, buttons, links, \
    text). action=click presses element `index` (buttons, links, check boxes, radio \
    buttons; for a check box the result says whether it is now checked), action=fill types `text` into field `index` (replacing what is there), \
    action=select chooses option `text` in drop-down `index`, action=type and \
    action=key send text or a key (Return, Tab, ctrl+a) to what has focus, \
    action=scroll moves the page, action=back goes back, and action=page_state reads \
    the page again. action=show_element takes a picture of element `index` (a \
    captcha image) and returns a Markdown image line for your answer, so the user \
    sees it. Every one of them returns the page as it is afterwards, with \
    fresh numbers: use only numbers from the latest result. On a long page, pass \
    `find` (action=page_state find=Password) to get just the matching elements \
    instead of reading the saved output in parts. The browser keeps its \
    cookies between calls. The first call can take a minute while the machine starts.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["shell", "read", "write", "upload", "download", "publish_port", "show_image",
                                                  "browse", "page_state", "click", "fill", "select",
                                                  "type", "key", "scroll", "back", "show_element"]],
            "url": ["type": "string", "description": "action=browse: the page to open."],
            "index": ["type": "integer",
                      "description": "click, fill, select, scroll, show_element: the element's number in the latest page state."],
            "text": ["type": "string",
                     "description": "fill: the field's new text. select: the option to choose. type: the text to type."],
            "key": ["type": "string", "description": "action=key: xdotool key syntax, e.g. Return, Tab, ctrl+a."],
            "direction": ["type": "string", "enum": ["up", "down"], "description": "action=scroll. Default down."],
            "app": ["type": "string",
                    "description": "Browser actions: another app on the cloud machine's desktop. Default Chromium."],
            "find": ["type": "string",
                     "description": "Browser actions: return only the elements whose line contains this text (a field label, a button's words) instead of the whole page."],
            "command": ["type": "string", "description": "action=shell: the bash command."],
            "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 600,
                                "description": "action=shell: seconds before it is stopped. Default 60."],
            "background": ["type": "boolean",
                           "description": "action=shell: start it and return at once with its log file."],
            "cwd": ["type": "string", "description": "action=shell: working directory. Default /data/home."],
            "path": ["type": "string",
                     "description": "read, write, download, show_image: the path on the machine. upload: where to put it there."],
            "content": ["type": "string", "description": "action=write: the file's full text."],
            "local_path": ["type": "string", "description": "action=upload: the file or folder on this Mac."],
            "port": ["type": "integer", "description": "action=publish_port: the port the server listens on."],
        ],
        "required": ["action"],
    ]

    /// Shows a question on the round's card; true when the user allowed it.
    let confirm: @Sendable (String) async throws -> Bool

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
        case "show_image": return try await showImage(input)
        case let action? where Self.browserActions.contains(action):
            return try await browser(input)
        default:
            return "Error: action must be shell, read, write, upload, download, publish_port, show_image, "
                + "browse, page_state, click, fill, select, type, key, scroll, back or show_element."
        }
    }

    static let browserActions: Set<String> = ["browse", "page_state", "click", "fill", "select",
                                              "type", "key", "scroll", "back", "show_element"]

    /// One step on the machine's desktop, through `CloudDesktopBridge`. The
    /// tool's action names map to the bridge's operations.
    private func browser(_ input: [String: Any]) async throws -> String {
        let action = input["action"] as? String ?? ""
        let op = ["browse": "open", "page_state": "state", "show_element": "snap"][action] ?? action
        var job: [String: Any] = ["op": op]
        if let app = Self.text(input, "app") { job["app"] = app }
        let index = (input["index"] as? NSNumber)?.intValue ?? (input["index"] as? String).flatMap { Int($0) }
        if let find = Self.text(input, "find") { job["find"] = find }
        switch action {
        case "browse":
            guard var url = Self.text(input, "url") else { return "Error: url is required." }
            if !url.contains("://") && !url.hasPrefix("data:") { url = "https://" + url }
            job["url"] = url
        case "click", "fill", "select", "show_element":
            guard let index else { return "Error: index is required." }
            job["index"] = index
            if action == "fill" || action == "select" {
                guard let text = input["text"] as? String else { return "Error: text is required." }
                job["text"] = text
            }
        case "type":
            guard let text = input["text"] as? String, !text.isEmpty else { return "Error: text is required." }
            job["text"] = text
        case "key":
            guard let key = Self.text(input, "key") else { return "Error: key is required." }
            job["key"] = key
        case "scroll":
            if let index { job["index"] = index }
            job["direction"] = Self.text(input, "direction") ?? "down"
        default:
            break
        }
        let output = try await CloudDesktopBridge.run(job)
        return action == "show_element" ? try await Self.bringPicture(output) : output
    }

    /// The bridge leaves the picture in the machine's /tmp. It comes to this
    /// Mac, where the answer can show it: the notch draws a `file://` image,
    /// and the Telegram bridge sends it as a photo.
    private static func bringPicture(_ output: String) async throws -> String {
        guard let match = output.range(of: #"Saved a picture of element \d+ to (/tmp/notchi-snap-\d+\.png)\."#,
                                       options: .regularExpression) else { return output }
        let line = String(output[match])
        guard let pathRange = line.range(of: #"/tmp/notchi-snap-\d+\.png"#, options: .regularExpression) else {
            return output
        }
        let temp = try await InstaBoxMachine.shared.download(String(line[pathRange]))
        let folder = try capturesFolder()
        let target = folder.appendingPathComponent("element-\(UUID().uuidString.prefix(8)).png")
        try FileManager.default.moveItem(at: temp, to: target)
        let note = """
        The picture is saved on this Mac. To show it, put this line in your answer as it is: \
        ![captcha](\(target.absoluteString)) \
        You have not seen the picture: do not say what kind of captcha it is or what it shows.
        """
        return output.replacingCharacters(in: match, with: note)
    }

    /// Pictures from the cloud desktop, kept for a day: long enough for the
    /// thread that shows one, without piling up.
    private static func capturesFolder() throws -> URL {
        let fm = FileManager.default
        let folder = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchi", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-86_400)
        for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let changed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let changed, changed < cutoff { try? fm.removeItem(at: file) }
        }
        return folder
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

    /// A command whose only job is reading public web pages: curl or wget a URL
    /// and grep, cut or parse what comes back, or strip tags from a saved page.
    /// On 2026-11-12 and 2026-11-14 a model sent 7, 28 and 32 such calls in
    /// three rounds (2 to 34 seconds each, read_page answers in about 1), even
    /// after the system prompt told it to use read_page. Commands that also
    /// build, install, run containers or send data are left alone.
    static func pageScraping(_ command: String) -> String? {
        let lowered = command.lowercased()
        let work = ["docker", "apt ", "apt-get", "pip install", "npm ", "npx ", "yarn ", "git clone",
                    "make ", "cargo ", "go build", "go run", "tar ", "unzip", "chmod +x"]
        if work.contains(where: lowered.contains) { return nil }
        // curl that sends data (a form, an upload, POST) is not a page read.
        let sends = #"\bcurl\b[^|\n]*\s(-d|--data\S*|-F|--form|-T|--upload-file|-X\s*(POST|PUT|PATCH|DELETE))\b"#
        if command.range(of: sends, options: .regularExpression) != nil { return nil }
        let stripsTags = [#"<[^>]+>"#, #"<[^>]*>"#, "<script", "html.unescape", "beautifulsoup",
                          "bs4", "html2text", "lynx -dump", "w3m -dump"].contains(where: lowered.contains)
        let fetches = lowered.range(of: #"\b(curl|wget)\b"#, options: .regularExpression) != nil
            && lowered.contains("http")
        let processes = lowered.range(of: #"\|\s*(grep|sed|awk|head|tail|cut|jq|python3?|tr|sort)\b"#,
                                      options: .regularExpression) != nil
            || lowered.range(of: #"-o\s+\S+\.(html?|json|xml|md|txt)\b"#, options: .regularExpression) != nil
        guard stripsTags || (fetches && processes) else { return nil }
        return """
        Not run: this command only reads web pages, and the cloud machine is the slow \
        way to do that. Use read_page with the URL for a page's text (it reads JSON \
        too). To filter a large JSON reply or loop over many URLs, run the same \
        command with run_shell on this Mac. A file saved on the cloud machine in an \
        earlier round is not a current copy: fetch the page again. If neither \
        read_page nor run_shell can reach the site, open it with action=browse.
        """
    }

    /// A refusal for a shell command that drives the desktop by hand: xdotool
    /// clicks, moves, key presses or typing. On 2026-11-16 a model installed
    /// xdotool and clicked at guessed screen coordinates 4 times on two
    /// displays after action=click left a check box unchanged; none landed.
    /// The browser actions read element frames and click with the mouse
    /// themselves. Reading window geometry or searching windows is left alone.
    static func desktopScripting(_ command: String) -> String? {
        let pattern = #"\bxdotool\b[^|;&\n]*\b(click|mousemove|mousedown|mouseup|key|keydown|keyup|type)\b"#
        guard command.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return """
        Not run: clicking or typing on the desktop through xdotool is done by the browser \
        actions. action=click on a check box or radio button reads its state afterwards and \
        clicks it with the mouse when the first click left it unchanged; the result says \
        whether it is checked. Use action=click, fill, type or key with an element number \
        from the latest page state.
        """
    }

    /// Files the command names by absolute path, or by bare name after a `cd`,
    /// that look like saved data. Their age is reported after the command runs.
    static func dataFiles(in command: String, cwd: String?) -> [String] {
        let ext = #"\.(html?|json|xml|md|txt|csv|tsv|log)\b"#
        var paths = Set<String>()
        let absolute = try? NSRegularExpression(pattern: #"(?<![\w:/.])(/(?:tmp|data/home)/[\w./-]+"# + ext + ")")
        let ns = command as NSString
        for match in absolute?.matches(in: command, range: NSRange(location: 0, length: ns.length)) ?? [] {
            paths.insert(ns.substring(with: match.range(at: 1)))
        }
        var dir = cwd ?? "/data/home"
        if let cd = command.range(of: #"\bcd\s+(/[\w./-]+)"#, options: .regularExpression) {
            dir = String(command[cd].dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        let bare = try? NSRegularExpression(pattern: #"(?<![\w:/.-])([\w-]+"# + ext + ")")
        for match in bare?.matches(in: command, range: NSRange(location: 0, length: ns.length)) ?? [] {
            paths.insert(dir + "/" + ns.substring(with: match.range(at: 1)))
        }
        return paths.sorted().filter { !$0.contains("'") }
    }

    private static let mtimeMark = "__NOTCHI_MTIME__"
    /// A file older than this was left by an earlier round, not by this task.
    private static let staleAge: TimeInterval = 3600

    /// Adds a line after the command that prints the age of each data file it
    /// names, and keeps the command's exit code.
    private static func withAgeCheck(_ command: String, files: [String]) -> String {
        guard !files.isEmpty else { return command }
        let quoted = files.map { "'\($0)'" }.joined(separator: " ")
        return command + """

        __notchi_rc=$?; __notchi_now=$(date +%s); for f in \(quoted); do [ -f "$f" ] && \
        echo "\(mtimeMark) $(( __notchi_now - $(stat -c %Y "$f") )) $f"; done; exit $__notchi_rc
        """
    }

    /// Removes the age lines and, for files older than `staleAge`, adds a note.
    /// On 2026-11-14 a round reported a model as free from /tmp/sf.html, which
    /// an earlier round had downloaded 8 hours before.
    private static func ageNotes(_ output: String) -> (output: String, note: String?) {
        var kept: [Substring] = []
        var stale: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix(mtimeMark) else { kept.append(line); continue }
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count == 3, let age = TimeInterval(parts[1]) else { continue }
            if age > staleAge {
                let hours = age >= 7200 ? "\(Int(age / 3600)) hours" : "\(Int(age / 60)) minutes"
                stale.append("\(parts[2]) (last changed \(hours) ago)")
            }
        }
        let note = stale.isEmpty ? nil : """
        [Note: \(stale.joined(separator: ", ")) came from an earlier task, not this one. \
        Do not report what it says as current; fetch the source again.]
        """
        return (kept.joined(separator: "\n"), note)
    }

    private func shell(_ input: [String: Any]) async throws -> String {
        guard let command = Self.text(input, "command") else { return "Error: command is required." }
        let cwd = Self.text(input, "cwd")
        if let refusal = Self.pageScraping(command) ?? Self.desktopScripting(command) { return refusal }
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
        let files = Self.dataFiles(in: command, cwd: cwd)
        let result = try await InstaBoxMachine.shared.exec(Self.withAgeCheck(command, files: files),
                                                           cwd: cwd, timeout: timeout)
        let head = result.timedOut ? "[stopped after \(Int(timeout)) seconds]" : "[exit code: \(result.exitCode)]"
        let (output, note) = Self.ageNotes(result.output)
        var reply = output.isEmpty ? head : head + "\n" + output
        if let note { reply += "\n" + note }
        return reply
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

    private static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    private static let imageLimit = 20_000_000

    /// Brings an image from the machine into the captures folder and returns the
    /// line that shows it. On 2026-11-12 a model published port 8080 to show six
    /// screenshots: the links were open to anyone and stop working once the
    /// machine pauses. Copying into this app's own folder asks nothing.
    private func showImage(_ input: [String: Any]) async throws -> String {
        guard let raw = Self.text(input, "path") else { return "Error: path is required." }
        let path = Self.remotePath(raw)
        let ext = (path as NSString).pathExtension.lowercased()
        guard Self.imageTypes.contains(ext) else {
            return "Error: show_image takes a png, jpg, gif or webp file. Convert it on the machine first."
        }
        let temp = try await InstaBoxMachine.shared.download(path)
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.imageLimit else {
            try? fm.removeItem(at: temp)
            return "Error: \(path) is \(size / 1_000_000) MB. Scale it down on the machine (under 20 MB) and try again."
        }
        let target = try Self.capturesFolder().appendingPathComponent("image-\(UUID().uuidString.prefix(8)).\(ext)")
        try fm.moveItem(at: temp, to: target)
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return """
        The picture is saved on this Mac. To show it, put this line in your answer as it is: \
        ![\(name)](\(target.absoluteString))
        """
    }

    private func publish(_ input: [String: Any]) async throws -> String {
        guard let port = (input["port"] as? NSNumber)?.intValue else { return "Error: port is required." }
        guard try await confirm(L("cloud.confirm.publish", String(port))) else {
            return "The user did not approve publishing this port. It was not done. Do not retry it."
        }
        let url = try await InstaBoxMachine.shared.publish(port: port)
        return "Port \(port) is public at \(url). Anyone with the link can open it."
    }
}

// MARK: - Desktop

/// Drives the machine's desktop through open-computer-use, the computer-use
/// MCP server InstaBox installs on `agent-browser` machines
/// (`/usr/local/bin/instabox-computer-use`). Its element numbers only hold
/// inside the server process that read them, and each call from here is its
/// own exec, so a script on the machine keeps one server running behind a unix
/// socket. The script is written to the machine on the first call after launch.
enum CloudDesktopBridge {
    static let path = "/data/home/.notchi/cu-bridge.mjs"
    /// A first call may start the desktop, the server and Chromium.
    private static let timeout: TimeInterval = 180

    private actor Written {
        private(set) var done = false
        func set(_ value: Bool) { done = value }
    }
    private static let written = Written()

    static func run(_ job: [String: Any]) async throws -> String {
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: job), as: UTF8.self)
        for attempt in 0..<2 {
            if !(await written.done) {
                try await InstaBoxMachine.shared.write(Data(script.utf8), to: path)
                await written.set(true)
            }
            let sent = Date()
            let result = try await InstaBoxMachine.shared.exec(
                "node \(path) run", env: ["NOTCHI_CU": payload], cwd: nil, timeout: timeout)
            // A machine made again since the script was written.
            if attempt == 0, result.output.contains("Cannot find module") {
                await written.set(false)
                continue
            }
            let output = Self.logTiming(result.output, roundTrip: Date().timeIntervalSince(sent))
            if result.timedOut { return "[stopped after \(Int(timeout)) seconds] " + output }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "Error: the desktop script could not be written to the cloud machine."
    }

    /// Where each browser call's step times go: one line per call, with the
    /// script's own times and the whole exec as seen from this Mac.
    static var timingLog: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchi/cloud-browser-timing.log")
    }

    /// Takes the script's `NOTCHI-TIMING` line off `output` and appends it to
    /// `timingLog`. The model does not see it.
    private static func logTiming(_ output: String, roundTrip: TimeInterval) -> String {
        let marker = "NOTCHI-TIMING "
        var kept: [Substring] = []
        var timing = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(marker) { timing = String(line.dropFirst(marker.count)) } else { kept.append(line) }
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp) exec=\(Int(roundTrip * 1000)) \(timing.isEmpty ? "{}" : timing)\n"
        let url = timingLog
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: url)
        }
        return kept.joined(separator: "\n")
    }

    private static let script = #"""
    // Notchi's bridge to the machine's computer-use MCP server (open-computer-use,
    // started through /usr/local/bin/instabox-computer-use). Element numbers from
    // get_app_state only hold inside the process that produced them, and every
    // Notchi call is a separate exec, so one server process stays up behind a unix
    // socket and each exec talks to it.
    //
    //   node cu-bridge.mjs run      reads a job from $NOTCHI_CU, prints the result
    //   node cu-bridge.mjs serve    the long-lived server (started by `run`)
    //
    // A job: {"op", "app"?, "url"?, "index"?, "text"?, "key"?, "direction"?, "pages"?}
    // op: open, state, click, fill, select, type, key, back, scroll, snap, apps
    import net from 'node:net';
    import fs from 'node:fs';
    import os from 'node:os';
    import { spawn } from 'node:child_process';

    const SOCK = '/tmp/notchi-cu.sock';
    const TIMING = 'NOTCHI-TIMING ';
    const LOG = '/tmp/notchi-cu.log';
    const PROFILE = '/data/home/.notchi/chromium';
    const IDLE_MS = 20 * 60 * 1000;
    const uid = process.getuid();
    const desktopEnv = {
      ...process.env,
      DISPLAY: ':1',
      XDG_RUNTIME_DIR: `/run/user/${uid}`,
      DBUS_SESSION_BUS_ADDRESS: `unix:path=/run/user/${uid}/bus`,
      GDK_BACKEND: 'x11',
    };
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    const log = (s) => { try { fs.appendFileSync(LOG, `${new Date().toISOString()} ${s}\n`); } catch {} };

    async function serve() {
      const child = spawn('/usr/local/bin/instabox-computer-use', ['mcp'], {
        stdio: ['pipe', 'pipe', 'pipe'], env: process.env,
      });
      const pending = new Map();
      let nextId = 1;
      let buf = '';
      child.stdout.on('data', (d) => {
        buf += d;
        let i;
        while ((i = buf.indexOf('\n')) >= 0) {
          const line = buf.slice(0, i).trim();
          buf = buf.slice(i + 1);
          if (!line) continue;
          let msg;
          try { msg = JSON.parse(line); } catch { continue; }
          const p = pending.get(msg.id);
          if (p) { pending.delete(msg.id); p(msg); }
        }
      });
      child.stderr.on('data', (d) => log(`mcp: ${String(d).trim()}`));
      child.on('exit', (code) => {
        log(`mcp exited ${code}`);
        try { fs.unlinkSync(SOCK); } catch {}
        process.exit(1);
      });
      const rpc = (method, params) => new Promise((resolve) => {
        const id = nextId++;
        pending.set(id, resolve);
        child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
      });
      await rpc('initialize', {
        protocolVersion: '2025-06-18', capabilities: {},
        clientInfo: { name: 'notchi', version: '1' },
      });
      child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');

      let idle = setTimeout(() => process.exit(0), IDLE_MS);
      let queue = Promise.resolve();
      try { fs.unlinkSync(SOCK); } catch {}
      const server = net.createServer((conn) => {
        let input = '';
        conn.on('data', (d) => {
          input += d;
          if (!input.includes('\n')) return;
          clearTimeout(idle);
          idle = setTimeout(() => process.exit(0), IDLE_MS);
          let call;
          try { call = JSON.parse(input); } catch { conn.end('{"error":"bad request"}\n'); return; }
          queue = queue.then(async () => {
            const reply = await rpc('tools/call', { name: call.tool, arguments: call.args || {} });
            conn.end(JSON.stringify(reply) + '\n');
          });
        });
      });
      server.listen(SOCK);
    }

    function ask(call) {
      return new Promise((resolve, reject) => {
        const conn = net.createConnection(SOCK);
        let out = '';
        conn.on('connect', () => conn.write(JSON.stringify(call) + '\n'));
        conn.on('data', (d) => { out += d; });
        conn.on('end', () => {
          try { resolve(JSON.parse(out)); } catch { reject(new Error(out || 'no reply')); }
        });
        conn.on('error', reject);
      });
    }

    async function connected() {
      try { return await ask({ tool: 'list_apps', args: {} }); } catch {}
      spawn(process.execPath, [process.argv[1], 'serve'], {
        detached: true, stdio: 'ignore', env: process.env,
      }).unref();
      // The first start may bring the desktop up.
      for (let i = 0; i < 90; i++) {
        await sleep(1000);
        try { return await ask({ tool: 'list_apps', args: {} }); } catch {}
      }
      throw new Error('The computer-use server did not start. See /tmp/notchi-cu.log and /tmp/instabox-*.log.');
    }

    function textOf(reply) {
      if (reply.error) return { text: `Error: ${reply.error.message || JSON.stringify(reply.error)}`, failed: true };
      const r = reply.result || {};
      const text = (r.content || []).filter((c) => c.type === 'text').map((c) => c.text).join('\n');
      return { text, failed: !!r.isError };
    }

    // The tree as get_app_state prints it, without what a model cannot use:
    // unnamed layout nodes, the actions every node has, placeholder characters.
    function compact(tree) {
      const out = [];
      for (const raw of tree.split('\n')) {
        let line = raw.replace(/￼/g, '').replace(/\s+$/, '');
        const m = line.match(/^(\s*)(\d+) (.*)$/);
        if (!m) { if (line.trim()) out.push(line.trim()); continue; }
        const [, indent, index] = m;
        let rest = m[3];
        let frame = '';
        rest = rest.replace(/ Frame: \{x: (-?[\d.]+), y: (-?[\d.]+), width: ([\d.]+), height: ([\d.]+)\}/, (_, x, y, w, h) => {
          frame = ` @${Math.round(x)},${Math.round(y)} ${Math.round(w)}x${Math.round(h)}`;
          return '';
        });
        rest = rest.replace(/ Secondary Actions: (.*)$/, (_, list) => {
          const kept = list.split(', ').filter((a) => !['doDefault', 'showContextMenu'].includes(a)
            && !a.startsWith('scroll'));
          return kept.length ? ` [${kept.join(', ')}]` : '';
        });
        rest = rest.replace(/ Value:\s*(?=\[|$)/, '');
        rest = rest.trim();
        const role = rest.match(/^(panel|notification|section|filler|static|grouping|form|landmark|redundant object|unknown|image|separator|paragraph)$/);
        if (role) continue;
        const depth = Math.min(indent.length, 12);
        out.push(`${' '.repeat(depth)}${index} ${rest}${frame}`);
      }
      return out.join('\n');
    }

    // Chromium's window around the page (toolbar buttons, tab strip, side
    // panels) runs to a hundred nodes. Kept: the window line, the address bar and
    // the page itself.
    function pageOnly(tree) {
      const lines = tree.split('\n');
      const start = lines.findIndex((l) => /^\s*\d+ document web\b/.test(l));
      if (start < 0) return tree;
      const depth = lines[start].match(/^\s*/)[0].length;
      let end = start + 1;
      while (end < lines.length && (lines[end].match(/^\s*/)[0].length > depth || !/^\s*\d+ /.test(lines[end]))) end++;
      const head = lines.slice(0, start).filter((l) => !/^\s*\d+ /.test(l) || /Address and search bar|^\s*0 /.test(l));
      const tail = lines.slice(end).filter((l) => !/^\s*\d+ /.test(l));
      return [...head, ...lines.slice(start, end), ...tail].join('\n');
    }

    const isChromium = (app) => app.toLowerCase() === 'chromium';
    const stateFile = (app) => `/tmp/notchi-cu-state-${app.toLowerCase().replace(/[^a-z0-9]+/g, '-')}.txt`;

    function xdo(args) { return command('xdotool', args); }

    function command(bin, args) {
      return new Promise((resolve) => {
        const p = spawn(bin, args, { env: desktopEnv, stdio: ['ignore', 'pipe', 'pipe'] });
        let out = '';
        let err = '';
        p.stdout.on('data', (d) => { out += d; });
        p.stderr.on('data', (d) => { err += d; });
        p.on('close', (code) => resolve({ code, out: out.trim(), err: err.trim() }));
        p.on('error', () => resolve({ code: -1, out: '' }));
      });
    }

    // The app's window that keyboard input should reach. xdotool types into the
    // window with X focus, which an accessibility click does not always move.
    // With several windows open, the one picked is the window the last state
    // was read from (its title is in the state's `Window: "…"` line). On
    // 2026-11-20 the last Chromium window in xdotool's list was an older
    // sign-up page: show_element took its picture instead of the captcha, and
    // mouse clicks and wheel scrolls would have gone to it too.
    async function focusWindow(app) {
      const found = isChromium(app)
        ? await xdo(['search', '--onlyvisible', '--name', ' - Chromium$'])
        : await xdo(['search', '--onlyvisible', '--class', app]);
      const ids = found.out.split('\n').filter(Boolean);
      let title = null;
      try { title = fs.readFileSync(stateFile(app), 'utf8').match(/Window: "(.*?)", App:/)?.[1] || null; } catch {}
      let id = null;
      if (title && ids.length > 1) {
        for (const candidate of ids) {
          const name = await xdo(['getwindowname', candidate]);
          if (name.out === title) { id = candidate; break; }
        }
      }
      if (!id) id = ids.pop();
      if (id) await xdo(['windowactivate', '--sync', id]);
      return id;
    }

    // The window xdotool reports as active, to check that a screenshot or a
    // mouse action lands on the window that was raised.
    async function activeWindow() {
      return (await xdo(['getactivewindow'])).out || null;
    }

    // The container a captcha widget sits in: element `index` itself or its
    // nearest ancestor that is a dialog or a frame. Returns the container's
    // line and the lines under it, or null when there is no such container
    // below the page (a captcha image in the page's own form).
    function enclosing(app, index) {
      let lines = [];
      try { lines = fs.readFileSync(stateFile(app), 'utf8').split('\n'); } catch { return null; }
      const at = lines.findIndex((l) => new RegExp(`^\\s*${index} `).test(l));
      if (at < 0) return null;
      const depthOf = (l) => l.match(/^\s*/)[0].length;
      const container = (l) => /^\s*\d+ (dialog|internal frame|alert)\b/.test(l);
      let top = container(lines[at]) ? at : -1;
      for (let i = at - 1, d = depthOf(lines[at]); top < 0 && i >= 0; i--) {
        if (!/^\s*\d+ /.test(lines[i]) || depthOf(lines[i]) >= d) continue;
        d = depthOf(lines[i]);
        if (container(lines[i])) top = i;
        else if (/^\s*\d+ document web\b/.test(lines[i])) {
          // A frame's own document sits under the frame; the page's top
          // document ends the search.
          const parent = lines.slice(0, i).reverse().find((l) => /^\s*\d+ /.test(l) && depthOf(l) < d);
          if (!parent || !container(parent)) return null;
        }
      }
      if (top < 0) return null;
      const depth = depthOf(lines[top]);
      let end = top + 1;
      while (end < lines.length && (depthOf(lines[end]) > depth || !/^\s*\d+ /.test(lines[end]))) end++;
      return { head: lines[top], body: lines.slice(top, end) };
    }

    // A captcha the user can answer in a reply has a field for the characters.
    // A captcha widget with no text field (slider, "click the pictures in
    // order", puzzle) is answered on the picture itself. On 2026-11-20 the
    // model showed such a widget as a "typed captcha" and asked the user for
    // characters that had no field to go in.
    const CAPTCHA = /captcha|验证码|人机验证|verification|verify you are human/i;
    function untypedCaptcha(app, index) {
      const box = enclosing(app, index);
      if (!box || !box.body.some((l) => CAPTCHA.test(l))) return null;
      if (box.body.some((l) => /^\s*\d+ (entry|password text|text|spin button)\b/.test(l))) return null;
      return box.head.match(/^\s*(\d+) /)?.[1] || String(index);
    }

    // AT-SPI role names, longest first so `page tab list` wins over `page tab`.
    const ROLES = ['page tab list', 'check menu item', 'radio menu item', 'check box', 'radio button',
      'push button', 'toggle button', 'combo box', 'page tab', 'menu item', 'list item', 'spin button',
      'date editor', 'document web', 'password text', 'tool bar', 'table cell', 'entry', 'text', 'link',
      'button', 'label', 'heading', 'list', 'menu', 'table', 'slider'];

    // The element's line in the last state read, for its role and actions.
    function elementLine(app, index) {
      let tree = '';
      try { tree = fs.readFileSync(stateFile(app), 'utf8'); } catch { return null; }
      const line = tree.split('\n').find((l) => new RegExp(`^\\s*${index} `).test(l));
      if (!line) return null;
      const actions = (line.match(/ Secondary Actions: (.*?)(?: Frame: |$)/)?.[1] || '').split(', ').filter(Boolean);
      const body = line.trim().replace(/^\d+ /, '');
      const role = ROLES.find((r) => body === r || body.startsWith(r + ' ')) || '';
      return { line, actions, role };
    }

    // An element's frame as get_app_state gives it: relative to its window.
    function frameOf(line) {
      const m = line && line.match(/Frame: \{x: (-?[\d.]+), y: (-?[\d.]+), width: ([\d.]+), height: ([\d.]+)\}/);
      return m ? { x: +m[1], y: +m[2], w: +m[3], h: +m[4] } : null;
    }

    // The line without its number and frame, to find the same element again
    // after a scroll.
    const identity = (line) => line.trim().replace(/^\d+ /, '').replace(/ Frame: \{.*\}$/, '');

    async function windowOrigin(app) {
      const id = await focusWindow(app);
      if (!id) return null;
      const geo = await xdo(['getwindowgeometry', '--shell', id]);
      const x = +(geo.out.match(/^X=(-?\d+)/m)?.[1] ?? NaN);
      const y = +(geo.out.match(/^Y=(-?\d+)/m)?.[1] ?? NaN);
      return Number.isFinite(x) && Number.isFinite(y) ? { x, y } : null;
    }

    // The element's line once it is inside the visible part of the window. The
    // page's frames run past the window; only what is on screen can be
    // captured or clicked with the mouse.
    async function scrollIntoView(app, index, el) {
      let line = el.line;
      for (let i = 0; i < 12; i++) {
        const tree = fs.readFileSync(stateFile(app), 'utf8').split('\n');
        const docLine = tree.find((l) => /^\s*\d+ document web\b/.test(l));
        const frame = frameOf(line);
        if (!frame) throw new Error(`Element ${index} has no position on screen.`);
        // The document's frame is the whole page, so what shows is the window
        // below the browser's toolbar.
        const win = frameOf(tree.find((l) => /^\s*0 /.test(l)));
        const bar = frameOf(tree.find((l) => /Address and search bar/.test(l)));
        if (!docLine || !win) break;
        const top = bar ? bar.y + bar.h + 12 : frameOf(docLine).y;
        const bottom = win.y + win.h - 4;
        if (frame.y >= top && frame.y + frame.h <= bottom) break;
        // Chromium ignores an accessibility scroll on the document; the wheel
        // over the page moves it.
        const origin = await windowOrigin(app);
        if (!origin) break;
        await xdo(['mousemove', String(Math.round(origin.x + win.w / 2)), String(Math.round(origin.y + (top + bottom) / 2))]);
        await xdo(['click', '--repeat', '3', '--delay', '40', frame.y < top ? '4' : '5']);
        await sleep(500);
        await readState(app);
        const fresh = fs.readFileSync(stateFile(app), 'utf8').split('\n');
        line = fresh.find((l) => identity(l) === identity(el.line)) || fresh.find((l) => new RegExp(`^\\s*${index} `).test(l));
      }
      return line;
    }

    // A picture of one element, scrolled into view first.
    async function snap(app, index, el) {
      const widget = untypedCaptcha(app, index);
      if (widget) {
        throw new Error(`Element ${index} is in a captcha (${widget}) that has no text field: it is answered by `
          + 'clicking or dragging on the picture, and a reply from the user cannot do that. Do not show it '
          + 'or ask for characters; say this step needs the user at the page and give the page\'s link.');
      }
      const line = await scrollIntoView(app, index, el);
      const frame = frameOf(line);
      const origin = await windowOrigin(app);
      if (!frame || !origin) throw new Error(`Could not find element ${index} on screen.`);
      const raised = await focusWindow(app);
      await sleep(300);
      const active = await activeWindow();
      if (raised && active && String(+active) !== String(+raised)) {
        throw new Error(`Another window is in front of ${app}, so a picture would show that window. `
          + 'Read the page again (action=page_state) and retry once.');
      }
      const pad = 8;
      const x = Math.max(0, Math.round(origin.x + frame.x - pad));
      const y = Math.max(0, Math.round(origin.y + frame.y - pad));
      const w = Math.round(frame.w + pad * 2);
      const h = Math.round(frame.h + pad * 2);
      const path = `/tmp/notchi-snap-${Date.now()}.png`;
      const shot = await command('scrot', ['-o', '-a', `${x},${y},${w},${h}`, path]);
      if (shot.code !== 0 || !fs.existsSync(path)) throw new Error(`The screenshot failed (scrot ${x},${y},${w},${h}: ${shot.code} ${shot.err || ''}).`);
      return `Saved a picture of element ${index} to ${path}.`;
    }

    // Roles whose click flips a checked state.
    const TOGGLES = ['check box', 'radio button', 'toggle button', 'check menu item', 'radio menu item'];

    // Chromium names a check box's action after what it would do: `check` while
    // the box is unchecked, `uncheck` while it is checked. null when the line
    // has neither.
    function checkedOf(line) {
      if (!line) return null;
      const acts = (line.match(/ Secondary Actions: (.*?)(?: Frame: |$)/)?.[1] || '').split(', ');
      if (acts.includes('uncheck')) return true;
      if (acts.includes('check')) return false;
      return null;
    }

    // The line without its number, actions and frame: the same for a check box
    // before and after it changes.
    const toggleId = (line) => identity(line).replace(/ Secondary Actions: .*$/, '');

    // The same element in the state file just read: by its number when that
    // still fits, else the nearest line with the same role and name.
    function sameElement(app, index, el) {
      let lines = [];
      try { lines = fs.readFileSync(stateFile(app), 'utf8').split('\n'); } catch { return null; }
      const want = toggleId(el.line);
      const at = lines.find((l) => new RegExp(`^\\s*${index} `).test(l));
      if (at && toggleId(at) === want) return at;
      const same = lines.filter((l) => /^\s*\d+ /.test(l) && toggleId(l) === want);
      const f = frameOf(el.line);
      if (same.length <= 1 || !f) return same[0] || null;
      const dist = (l) => { const g = frameOf(l); return g ? Math.abs(g.x - f.x) + Math.abs(g.y - f.y) : 1e9; };
      return same.sort((a, b) => dist(a) - dist(b))[0];
    }

    // A left click with the mouse at the middle of the element's frame.
    async function mouseClick(app, line) {
      const frame = frameOf(line);
      const origin = await windowOrigin(app);
      if (!frame || !origin) return false;
      await xdo(['mousemove', String(Math.round(origin.x + frame.x + frame.w / 2)),
        String(Math.round(origin.y + frame.y + frame.h / 2))]);
      await xdo(['click', '1']);
      return true;
    }

    // After a click on a check box or radio button: reads its state again and,
    // when the accessibility action left it unchanged, clicks it once with the
    // mouse. On 2026-11-16 an accessibility click left a sign-up's terms box
    // unchecked; the result said only "Clicked", and the model went on to click
    // the box, its label and a second box, which flips the box back each time.
    async function verifyToggle(app, index, el, was) {
      await sleep(600);
      await readState(app);
      let now = checkedOf(sameElement(app, index, el));
      let how = '';
      if (now === was) {
        const fresh = sameElement(app, index, el) || el.line;
        const target = await scrollIntoView(app, index, { line: fresh });
        if (await mouseClick(app, target)) {
          await sleep(800);
          await readState(app);
          now = checkedOf(sameElement(app, index, el));
          how = ' The accessibility click left it unchanged, so it was clicked again with the mouse.';
        }
      }
      const word = (v) => (v ? 'checked' : 'not checked');
      if (now === null) {
        return `Clicked ${index} (${el.role}).${how} Its checked state cannot be read; look for it in the page below before clicking it again.`;
      }
      if (now !== was) {
        return `Clicked ${index} (${el.role}).${how} It is now ${word(now)}. `
          + 'Clicking it or its label again would undo that.';
      }
      return `Clicked ${index} (${el.role}) with the accessibility action and then with the mouse; it is still ${word(now)}. `
        + 'Its label and any drawn box next to it toggle the same input: click one of them once, then read the state '
        + 'in the result before any other click on this box. If it stays unchanged, say which box will not change.';
    }

    // CPU ticks (utime + stime) of a process, from /proc/<pid>/stat.
    function ticks(pid) {
      try {
        const s = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
        const f = s.slice(s.lastIndexOf(')') + 2).split(' ');
        return +f[11] + +f[12];
      } catch { return null; }
    }

    // Processes using at least `floor` percent of one core over one second.
    async function busyProcesses(floor) {
      const first = new Map();
      for (const p of fs.readdirSync('/proc')) {
        if (!/^\d+$/.test(p)) continue;
        const t = ticks(p);
        if (t !== null) first.set(p, t);
      }
      await sleep(1000);
      const out = [];
      for (const [p, t0] of first) {
        const t1 = ticks(p);
        if (t1 === null) continue;
        // At 100 ticks a second, ticks in one second are percent of a core.
        const pct = t1 - t0;
        if (pct < floor) continue;
        let name = '';
        try { name = fs.readFileSync(`/proc/${p}/comm`, 'utf8').trim(); } catch {}
        out.push({ pid: +p, pct, name });
      }
      return out.sort((a, b) => b.pct - a.pct);
    }

    // Desktop processes that each held a full core on 2026-11-09 and made every
    // accessibility call time out after 30 s. Chromium does not need them.
    const SPINNERS = ['xfce4-panel', 'xfdesktop', 'xfsettingsd', 'xfce4-notifyd', 'xfwm4'];

    // Stops any of SPINNERS that is using most of a core, when the machine is
    // loaded. Returns a line for the result, or ''.
    async function healDesktop() {
      if (os.loadavg()[0] < os.cpus().length * 0.75) return '';
      const killed = [];
      for (const b of await busyProcesses(60)) {
        if (!SPINNERS.includes(b.name)) continue;
        try { process.kill(b.pid, 'SIGKILL'); killed.push(`${b.name} (${b.pct}%)`); } catch {}
      }
      if (!killed.length) return '';
      log(`stopped spinning ${killed.join(', ')}`);
      return `Stopped desktop processes that were each using a full core: ${killed.join(', ')}.`;
    }

    // Load and busy processes, appended to a timeout so the cause is in the
    // result instead of found later.
    async function diagnose() {
      const [l1, l5] = os.loadavg();
      const busy = (await busyProcesses(30)).slice(0, 5)
        .map((b) => `${b.name} pid ${b.pid} ${b.pct}%`).join(', ') || 'none above 30%';
      return `Machine load ${l1.toFixed(1)} (1 min), ${l5.toFixed(1)} (5 min) on ${os.cpus().length} cores. `
        + `Busy processes: ${busy}. Waiting does not fix a busy process: stop it with action=shell `
        + '(kill PID), or restart the browser with pkill chromium and action=browse.';
    }

    // The page as the model saw it, without element numbers, to tell whether a
    // click changed anything.
    const plainState = (s) => s.replace(/^(\s*)\d+ /gm, '$1');

    async function tool(name, args) {
      const { text, failed } = textOf(await ask({ tool: name, args }));
      if (failed) throw new Error(`${name}: ${text}`);
      return text;
    }

    // An element's own name: its line without number, role, value, actions and frame.
    function nameOf(el) {
      return el.line.trim().replace(/^\d+ /, '').slice(el.role.length)
        .replace(/ (Value:|Secondary Actions:|Frame:).*$/, '').trim();
    }

    // A consent banner's "accept all" button, when the same page also has a
    // button that declines optional cookies: the decline button's line, so the
    // click goes there instead.
    const ACCEPT_ALL = /^(accept|allow) (all|cookies)\b|^(接受|同意)(全部|所有)|^全部(接受|同意)/i;
    const DECLINE = /reject|decline|deny|necessary only|only necessary|essential only|only essential|拒绝|仅必要|仅限必要/i;
    function cookieRejectInstead(app, el) {
      if (!['button', 'push button', 'link'].includes(el.role) || !ACCEPT_ALL.test(nameOf(el))) return null;
      let tree = '';
      try { tree = fs.readFileSync(stateFile(app), 'utf8'); } catch { return null; }
      for (const line of tree.split('\n')) {
        const m = line.match(/^\s*(\d+) (push button|button|link) (.*?)(?: (?:Value:|Secondary Actions:|Frame:).*)?$/);
        if (m && DECLINE.test(m[3])) return `${m[1]} (${m[3].trim()})`;
      }
      return null;
    }

    // Elements more than one screen above or below the visible part of the
    // page are left out: a long page's footer alone runs to hundreds of lines.
    // `find` still searches the whole page.
    function nearViewport(state) {
      const lines = state.split('\n');
      const doc = lines.find((l) => /^\s*\d+ document web\b/.test(l));
      const view = doc && doc.match(/ @-?\d+,(-?\d+) \d+x(\d+)$/);
      if (!view) return state;
      const top = +view[1], h = +view[2];
      let above = 0, below = 0;
      const kept = lines.filter((l) => {
        const f = l.match(/ @-?\d+,(-?\d+) \d+x(\d+)$/);
        if (!f || l === doc) return true;
        const y = +f[1], fh = +f[2];
        if (y + fh < top - h) { above++; return false; }
        if (y > top + 2 * h) { below++; return false; }
        return true;
      });
      if (!above && !below) return state;
      const parts = [];
      if (above) parts.push(`${above} above`);
      if (below) parts.push(`${below} below`);
      kept.push(`[${parts.join(', ')} the visible part of the page are left out. `
        + 'Pass find=<words> to get them by text, or action=scroll.]');
      return kept.join('\n');
    }

    // One operation from Notchi. Each picks the method that works on Chromium's
    // accessibility tree: check boxes, radio buttons and links answer to their
    // own actions; text goes in through the keyboard, since Chromium's fields are
    // not settable over accessibility.
    async function perform(job, app) {
      const index = job.index === undefined ? undefined : String(job.index);
      const el = index === undefined ? null : elementLine(app, index);
      if (index !== undefined && !el) {
        throw new Error(`No element ${index} in the last state of ${app}. Read the state again (action=page_state) and use a number from it.`);
      }
      switch (job.op) {
        case 'open': {
          spawn('chromium', [
            '--no-first-run', '--no-default-browser-check', '--force-renderer-accessibility',
            '--disable-features=Translate', '--password-store=basic', `--user-data-dir=${PROFILE}`, job.url,
          ], { detached: true, stdio: 'ignore', env: desktopEnv }).unref();
          await sleep(4000);
          return `Opened ${job.url}.`;
        }
        case 'state':
          return '';
        case 'click': {
          if (!el) throw new Error('index is required.');
          const reject = cookieRejectInstead(app, el);
          if (reject) {
            throw new Error(`${index} accepts all optional cookies. Click ${reject} instead; `
              + 'accept all only when the user asked for it.');
          }
          const own =['check', 'uncheck', 'press', 'jump', 'click', 'open', 'activate', 'expand or contract']
            .find((a) => el.actions.includes(a));
          const was = TOGGLES.includes(el.role) ? checkedOf(el.line) : null;
          if (el.role === 'radio button' && was === true) {
            job.verified = true;
            return `${index} (radio button) is already selected; nothing was clicked.`;
          }
          if (own && el.role !== 'entry' && el.role !== 'combo box') {
            await tool('perform_secondary_action', { app, element_index: index, action: own });
          } else {
            await tool('click', { app, element_index: index });
          }
          if (was !== null) {
            job.verified = true;
            return await verifyToggle(app, index, el, was);
          }
          const box = frameOf(el.line);
          if (box && (box.w <= 2 || box.h <= 2)) {
            return `Clicked ${index} (${el.role}). It is ${Math.round(box.w)}x${Math.round(box.h)} pixels, `
              + 'so it is likely a hidden input under a drawn box: if the page below shows no change, '
              + 'click its label or the visible box next to it.';
          }
          return `Clicked ${index} (${el.role}).`;
        }
        case 'fill': {
          if (!el) throw new Error('index is required.');
          await tool('click', { app, element_index: index });
          await focusWindow(app);
          await xdo(['key', '--clearmodifiers', 'ctrl+a']);
          if (job.text === '') {
            await xdo(['key', 'BackSpace']);
          } else {
            await xdo(['type', '--clearmodifiers', '--delay', '12', '--', job.text]);
          }
          // On 2026-11-16 an answer gave a password that had only been typed into
          // a sign-up form that was never submitted, and asked the user to check
          // the field.
          if (el.role === 'password text') {
            return `Filled ${index} (password). The account does not exist yet: keep this password out of your `
              + 'answer until the site confirms the account was created or the password changed.';
          }
          return `Filled ${index}.`;
        }
        case 'select': {
          // A <select>: focused, typing an option's text moves to it, and Return
          // closes the list on it.
          if (!el) throw new Error('index is required.');
          await tool('click', { app, element_index: index });
          await sleep(400);
          await focusWindow(app);
          await xdo(['type', '--clearmodifiers', '--delay', '40', '--', job.text]);
          await xdo(['key', 'Return']);
          return `Chose "${job.text}" in ${index}.`;
        }
        case 'type':
          await focusWindow(app);
          await xdo(['type', '--clearmodifiers', '--delay', '12', '--', job.text]);
          return 'Typed.';
        case 'key':
          await focusWindow(app);
          await xdo(['key', '--clearmodifiers', job.key]);
          return `Pressed ${job.key}.`;
        case 'back':
          await focusWindow(app);
          await xdo(['key', '--clearmodifiers', 'alt+Left']);
          return 'Went back.';
        case 'scroll': {
          let target = index;
          if (target === undefined) {
            let tree = '';
            try { tree = fs.readFileSync(stateFile(app), 'utf8'); } catch {}
            target = tree.match(/^\s*(\d+) document web\b/m)?.[1];
          }
          if (target === undefined) {
            await focusWindow(app);
            await xdo(['key', job.direction === 'up' ? 'Page_Up' : 'Page_Down']);
          } else {
            await tool('scroll', { app, element_index: target, direction: job.direction || 'down', pages: job.pages || 1 });
          }
          return `Scrolled ${job.direction || 'down'}.`;
        }
        case 'snap':
          if (!el) throw new Error('index is required.');
          return await snap(app, index, el);
        case 'apps':
          return await tool('list_apps', {});
        default:
          throw new Error(`Unknown operation ${job.op}.`);
      }
    }

    // get_app_state calls and their milliseconds in the last readState.
    let lastReads = [];
    async function readState(app) {
      let state = '';
      lastReads = [];
      // Chromium builds the page's accessibility tree on the first request, so
      // the first read can show only the window around it.
      for (let i = 0; i < 5; i++) {
        const t0 = Date.now();
        state = await tool('get_app_state', { app, max_tree_nodes: 3000, text_limit: 2000 });
        lastReads.push(Date.now() - t0);
        if (!isChromium(app) || /\n\s*\d+ document web .*\n\s+\d+ /.test(state)) break;
        await sleep(1500);
      }
      fs.writeFileSync(stateFile(app), state);
      return compact(isChromium(app) ? pageOnly(state) : state);
    }

    async function run() {
      const job = JSON.parse(process.env.NOTCHI_CU || '{}');
      const app = job.app || 'Chromium';
      const lines = [];
      // Milliseconds per step. Browser calls took 38 to 49 s each on 2026-11-21,
      // a page_state with no page load among them, and nothing showed which
      // step used the time. Notchi takes this line off the result and logs it.
      const started = Date.now();
      const timing = { op: job.op };
      const mark = (name, from) => { timing[name] = Date.now() - from; return Date.now(); };
      let t = Date.now();
      const healed = await healDesktop();
      if (healed) lines.push(healed);
      t = mark('heal', t);
      await connected();
      t = mark('connect', t);
      let before = '';
      if (job.op === 'click') {
        try {
          const raw = fs.readFileSync(stateFile(app), 'utf8');
          before = plainState(compact(isChromium(app) ? pageOnly(raw) : raw));
        } catch {}
      }
      let said = '';
      try {
        said = await perform(job, app);
      } catch (e) {
        const extra = /timed out/i.test(e.message) ? '\n' + await diagnose() : '';
        process.stdout.write([...lines, `Error: ${e.message}${extra}`].join('\n') + '\n');
        process.exit(1);
      }
      if (said) lines.push(said);
      t = mark('perform', t);
      if (job.op !== 'apps') {
        if (job.op !== 'state' && job.op !== 'open') await sleep(1200);
        try {
          let state = await readState(app);
          t = mark('readState', t);
          timing.reads = lastReads;
          if (before && !job.verified && plainState(state) === before) {
            lines.push('The page is the same as before this click: the click did not take effect. '
              + 'Do not assume it worked; check the element is on screen (action=scroll), then try its label, '
              + 'a neighbouring element, or action=key.');
          }
          if (job.find) {
            const want = String(job.find).toLowerCase();
            const hits = state.split('\n').filter((l) => l.toLowerCase().includes(want));
            state = hits.length
              ? `Elements matching "${job.find}" (${hits.length}):\n` + hits.map((l) => l.trim()).join('\n')
              : `No element matches "${job.find}".`;
          } else if (isChromium(app)) {
            state = nearViewport(state);
          }
          lines.push(state);
        } catch (e) {
          const extra = /timed out/i.test(e.message) ? '\n' + await diagnose() : '';
          lines.push(`Reading ${app} failed: ${e.message}${extra}`);
        }
      }
      let out = lines.join('\n');
      if (out.length > 40000) out = out.slice(0, 40000) + '\n[Cut at 40000 characters.]';
      timing.total = Date.now() - started;
      timing.load = os.loadavg()[0].toFixed(1);
      log(`timing ${JSON.stringify(timing)}`);
      process.stdout.write(out + '\n' + TIMING + JSON.stringify(timing) + '\n');
    }

    const mode = process.argv[2];
    if (mode === 'serve') serve().catch((e) => { log(String(e)); process.exit(1); });
    else run().catch((e) => { process.stdout.write(`Error: ${e.message}\n`); process.exit(1); });
    """#
}

// MARK: - Status chip

/// The cloud machine's connection, one glyph left of the result header's pin
/// while the cloud machine is on: a cloud when connected, a dimmed cloud while
/// the browser approval is pending, a struck-through cloud when connecting
/// failed. Hidden when it is off. A click opens Settings → Chat, where it is
/// turned on and off.
struct CloudMachineStatusChip: View {
    /// `GlassSegmentCluster(glass:)`: off draws the glyph bare.
    var glass: Bool = true
    /// `GlassSegmentCluster(bareChip:)`.
    var bareChip: Bool = true
    var openSettings: () -> Void
    @ObservedObject private var account = InstaBoxAccount.shared

    private enum Look: Equatable { case connected, connecting, failed }

    private var look: Look? {
        guard DebugFeatureFlags.cloudMachine else { return nil }
        switch account.state {
        case .off: return nil
        case .claiming: return .connecting
        case .connected: return .connected
        case .failed: return .failed
        }
    }

    var body: some View {
        Group {
            if let look {
                GlassSegmentCluster(segments: [
                    .init(id: "cloud", tooltip: tooltip(look), action: openSettings) {
                        Image(systemName: look == .failed ? "icloud.slash" : "icloud")
                            .sfFont(12, weight: .light)
                            .opacity(look == .connecting ? 0.45 : 1)
                            .id(look)
                            .transition(.opacity)
                    }
                ], glass: glass, bareChip: bareChip)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: look)
    }

    private func tooltip(_ look: Look) -> String {
        switch look {
        case .connected: return L("cloud.status.connected")
        case .connecting: return L("cloud.status.connecting")
        case .failed: return L("cloud.status.failed")
        }
    }
}

/// The cloud machine as a row in the ⋯ menus, under a divider: "Cloud
/// machine" over its status, with a switch that turns it on or off
/// (`InstaBoxAccount.setOn`). Shown once the machine is on or has a key.
struct CloudMachineStatusMenuRow: View {
    /// The model menu's type size; off for the `/` menu's, in a menu whose
    /// other rows use it.
    var compact: Bool = true
    @ObservedObject private var account = InstaBoxAccount.shared
    @Environment(\.menuCardLight) private var menuCardLight

    static var isShown: Bool {
        guard DebugFeatureFlags.cloudMachine else { return false }
        if case .off = InstaBoxAccount.shared.state {
            return APIKeyStore.currentInstaBoxKey() != nil
        }
        return true
    }

    private var on: Bool {
        if case .off = account.state { return false }
        return true
    }

    private var status: String {
        switch account.state {
        case .claiming: return L("cloud.menu.connecting")
        case .failed: return L("cloud.menu.failed")
        default: return "InstaBox"
        }
    }

    var body: some View {
        if Self.isShown {
            let fontSize = compact ? MenuCard.pickerFontSize : MenuCard.fontSize
            let pad = compact ? MenuCard.pickerRowPad : MenuCard.rowPad
            VStack(alignment: .leading, spacing: 4) {
                Rectangle()
                    .fill(Tokens.hairline)
                    .frame(height: 0.5)
                    .padding(.horizontal, pad)
                    .padding(.vertical, 2)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("cloud.title"))
                            .sfFont(fontSize, weight: .regular)
                            .foregroundStyle(menuCardLight ? Tokens.text2 : Tokens.text3)
                        Text(status)
                            .sfFont(MenuCard.accessoryFontSize, weight: .regular)
                            .foregroundStyle(Tokens.text4)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Toggle("", isOn: Binding(
                        get: { on },
                        set: { Haptics.levelChange(); account.setOn($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Tokens.switchTint)
                }
                .padding(.horizontal, pad)
                .padding(.vertical, 6)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
