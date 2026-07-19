import AppKit
import CryptoKit
import Foundation
import Network

/// One-click "Connect OpenRouter": the OAuth PKCE flow that gets a user their
/// own API key without ever pasting one. The point is onboarding simplicity —
/// OpenRouter's free models make the app usable at $0, but only if getting a key
/// doesn't require a trip through a developer console.
///
/// The flow (https://openrouter.ai/docs — OAuth PKCE):
///   1. Generate a random `code_verifier`; derive its S256 challenge.
///   2. Listen on a random loopback port (OpenRouter allows `localhost` callbacks
///      on any port — designed for native apps exactly like this one).
///   3. Open the default browser at `openrouter.ai/auth`. The user signs in (or
///      signs up, free) and approves; the browser redirects to our port with a
///      one-time `code`.
///   4. POST the code + verifier to `/api/v1/auth/keys`; the response is an API
///      key scoped to *the user's own account* — their quota, not a shared one.
///   5. Save it in `APIKeyStore` under `.openrouter` and rebuild the AI service.
///
/// Because the key belongs to the user's account, nothing secret ships in the
/// app and no quota is shared between users — the two failure modes a bundled
/// developer key would have.
@MainActor
final class OpenRouterAuth: ObservableObject {
    static let shared = OpenRouterAuth()
    private init() {}

    enum Phase: Equatable {
        case idle
        /// Browser is open; the loopback listener is waiting for the redirect.
        case waiting
        /// Code received; exchanging it for the key.
        case exchanging
        /// Key saved — a one-shot signal the settings view reacts to.
        case connected
        case failed(String)
    }
    @Published private(set) var phase: Phase = .idle

    private var listener: NWListener?
    private var verifier = ""
    private var timeoutTask: Task<Void, Never>?

    /// How long the browser leg may dangle before the listener is torn down. The
    /// user may need to sign up, find a 2FA code, etc. — generous, but bounded so
    /// an abandoned attempt doesn't hold a port forever.
    private static let timeout: TimeInterval = 300

    // MARK: - Flow

    /// Kick off (or restart) the connect flow. Safe to call repeatedly — any
    /// earlier attempt is torn down first, so the Connect button can't stack
    /// listeners.
    func connect() {
        teardown()
        verifier = Self.randomVerifier()
        let challenge = Self.s256Challenge(of: verifier)

        // Loopback only: the callback must come from this machine's browser, so
        // never expose the port beyond 127.0.0.1.
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: params) else {
            phase = .failed(L("or.error.noPort"))
            return
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            Task { @MainActor in
                self?.read(conn, accumulated: Data())
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.listener === listener else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        self.fail(L("or.error.noPort"))
                        return
                    }
                    self.openBrowser(port: port, challenge: challenge)
                case .failed:
                    self.fail(L("or.error.noPort"))
                default:
                    break
                }
            }
        }
        listener.start(queue: .main)
        phase = .waiting

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
            guard let self, self.phase == .waiting else { return }
            // Quietly reset — an abandoned browser tab isn't an error worth a
            // red pill, the user just gets the Connect button back.
            self.teardown()
            self.phase = .idle
        }
    }

    /// Abort a pending flow (the settings Cancel button).
    func cancel() {
        teardown()
        phase = .idle
    }

    /// Clear a one-shot `.connected` / `.failed` so the row returns to rest.
    func acknowledge() {
        if phase == .connected || isFailed { phase = .idle }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func fail(_ message: String) {
        teardown()
        phase = .failed(message)
    }

    private func teardown() {
        listener?.cancel()
        listener = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func openBrowser(port: UInt16, challenge: String) {
        var comps = URLComponents(string: "https://openrouter.ai/auth")!
        comps.queryItems = [
            URLQueryItem(name: "callback_url", value: "http://localhost:\(port)/callback"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        NSWorkspace.shared.open(comps.url!)
    }

    // MARK: - Loopback HTTP

    /// Accumulate one HTTP request head off the connection. GETs carry no body,
    /// so the blank line after the headers is the whole message; the size cap
    /// shields against a hostile local process spraying the port.
    private func read(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { conn.cancel(); return }
                var buf = accumulated
                if let data { buf.append(data) }
                if let head = String(data: buf, encoding: .utf8),
                   head.contains("\r\n\r\n") {
                    self.route(conn, requestHead: head)
                } else if error != nil || complete || buf.count > 16384 {
                    conn.cancel()
                } else {
                    self.read(conn, accumulated: buf)
                }
            }
        }
    }

    /// Act on one request. Only `/callback` ends the flow — browsers also fetch
    /// `/favicon.ico` and the like, which must not consume the listener.
    private func route(_ conn: NWConnection, requestHead: String) {
        let parts = requestHead.components(separatedBy: " ")
        guard parts.count >= 2, let target = URLComponents(string: parts[1]),
              target.path == "/callback" else {
            respond(conn, status: "404 Not Found", body: "")
            return
        }
        let query = { (name: String) in
            target.queryItems?.first(where: { $0.name == name })?.value
        }
        if let code = query("code"), !code.isEmpty {
            respond(conn, status: "200 OK", body: Self.successPage)
            listener?.cancel()   // one code is all we need; stop accepting
            listener = nil
            timeoutTask?.cancel()
            exchange(code: code)
        } else {
            respond(conn, status: "200 OK", body: Self.deniedPage)
            fail(L("or.error.cancelled"))
        }
    }

    private func respond(_ conn: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(payload.count)\r\n"
            + "Connection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + payload,
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Code → key exchange

    private struct ExchangeRequest: Encodable {
        let code: String
        let codeVerifier: String
        let codeChallengeMethod: String
        enum CodingKeys: String, CodingKey {
            case code
            case codeVerifier = "code_verifier"
            case codeChallengeMethod = "code_challenge_method"
        }
    }
    private struct ExchangeResponse: Decodable { let key: String }

    private func exchange(code: String) {
        phase = .exchanging
        let verifier = self.verifier
        Task {
            do {
                var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
                req.httpMethod = "POST"
                req.timeoutInterval = 30
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONEncoder().encode(ExchangeRequest(
                    code: code, codeVerifier: verifier, codeChallengeMethod: "S256"))
                let (data, response) = try await ProxyConfig.urlSession.data(for: req)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      case let key = try JSONDecoder().decode(ExchangeResponse.self, from: data).key,
                      !key.isEmpty else {
                    fail(L("or.error.noKey"))
                    return
                }
                APIKeyStore.save(key, for: .openrouter)
                NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
                phase = .connected
            } catch {
                fail(L("or.error.unreachable"))
            }
        }
    }

    // MARK: - PKCE primitives

    /// 32 random bytes, base64url — 43 chars of the RFC 7636 unreserved set.
    private static func randomVerifier() -> String {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return base64url(bytes)
    }

    /// S256: base64url(sha256(ascii(verifier))).
    private static func s256Challenge(of verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Browser-facing pages

    /// What the redirect tab shows. Styled to read as the app speaking — dark,
    /// quiet, one line — since this page IS the end of the user-visible flow.
    /// Computed (not stored) so the copy tracks the live App Language rather than
    /// freezing at first access.
    private static var successPage: String {
        page(title: L("or.page.connected.title"),
             line: L("or.page.connected.line"))
    }

    private static var deniedPage: String {
        page(title: L("or.page.cancelled.title"),
             line: L("or.page.cancelled.line"))
    }

    private static func page(title: String, line: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>Notchi — \(title)</title></head>
        <body style="margin:0;display:flex;align-items:center;justify-content:center;height:100vh;\
        background:#101014;color:rgba(255,255,255,.85);\
        font:15px/1.5 -apple-system,BlinkMacSystemFont,sans-serif">
        <div style="text-align:center;max-width:32em;padding:0 2em">\(line)</div>
        </body></html>
        """
    }
}
