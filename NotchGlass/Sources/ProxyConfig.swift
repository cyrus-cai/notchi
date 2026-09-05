import Foundation
import CFNetwork

/// The proxy Notch connects through — the app's own `URLSession` requests and
/// the agent CLIs (`claude`, `codex`) alike.
///
/// Why this exists: Notch is a GUI app, so it inherits **launchd's** environment,
/// not the one `~/.zshrc` builds. `HTTPS_PROXY` and friends simply aren't there,
/// and every CLI we spawn inherits that sparse environment — meaning a user behind
/// a plain `127.0.0.1:7890` HTTP proxy watches `claude`/`codex` fail to connect
/// while their terminal works fine. (`URLSession` follows the system proxy
/// natively, so auto detection is only about child processes — but an explicit
/// **manual** setting is forced onto the app's own requests too, via `urlSession`.)
/// `codex exec` additionally runs with `--ignore-user-config`, so its
/// `~/.codex/config.toml` proxy keys are dead too — environment variables are the
/// only lever left.
///
/// Resolution order, first hit wins:
///  1. **Manual** — what the user typed in Settings → General. An explicit setting
///     always beats detection.
///  2. **Inherited** — the spawning environment already carries a proxy (someone
///     ran `launchctl setenv`, or Notch was launched from a terminal). Leave it be.
///  3. **System** — macOS Network settings (`CFNetworkCopySystemProxySettings`).
///  4. **Login shell** — `$SHELL -lc` echo of the proxy vars, which covers the very
///     common "it's only exported in my .zshrc" case. Spawning a login shell costs
///     ~100-300ms, so the answer is cached (and `warmUp()` pays it off-thread).
enum ProxyConfig {

    // MARK: - The manual setting

    private static let manualKey = "agentProxyURL"

    /// The proxy typed in Settings → General. Empty means "auto" — fall through to
    /// the inherited / system / shell layers below.
    static var manual: String {
        get { UserDefaults.standard.string(forKey: manualKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: manualKey)
            invalidateCache()
        }
    }

    // MARK: - Resolution

    enum Source {
        case manual, inherited, system, shell
    }

    struct Resolved {
        /// The proxy URL, normalized to carry a scheme (`http://127.0.0.1:7890`).
        let url: String
        let source: Source
        /// SOCKS proxies ride `ALL_PROXY` alone — `HTTP(S)_PROXY` is an HTTP-proxy
        /// contract and most clients (node's undici, for one) won't speak SOCKS
        /// through it.
        var isSOCKS: Bool { url.hasPrefix("socks") }
    }

    /// The proxy that the next spawned CLI will use, or nil for a direct connection.
    /// Cached — call `invalidateCache()` when the setting changes.
    static func resolved(inheriting env: [String: String] = ProcessInfo.processInfo.environment) -> Resolved? {
        let m = manual.trimmingCharacters(in: .whitespacesAndNewlines)
        if !m.isEmpty, let url = normalize(m) {
            return Resolved(url: url, source: .manual)
        }
        // Someone already set one for us (launchctl setenv, or launched from a shell).
        for key in ["HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy", "HTTP_PROXY", "http_proxy"] {
            if let v = env[key], let url = normalize(v) {
                return Resolved(url: url, source: .inherited)
            }
        }
        if let url = systemProxy() { return Resolved(url: url, source: .system) }
        if let url = shellProxy() { return Resolved(url: url, source: .shell) }
        return nil
    }

    /// Inject the resolved proxy into a child process's environment. A no-op when
    /// nothing resolves, or when the environment already carries the proxy (source
    /// `.inherited` — re-writing what's already there buys nothing).
    static func apply(to env: inout [String: String]) {
        guard let proxy = resolved(inheriting: env), proxy.source != .inherited else { return }
        if proxy.isSOCKS {
            env["ALL_PROXY"] = proxy.url
            env["all_proxy"] = proxy.url
        } else {
            // Both cases: the CLIs are a node app and a rust binary, and the two
            // ecosystems disagree about which spelling they read.
            env["HTTP_PROXY"] = proxy.url
            env["http_proxy"] = proxy.url
            env["HTTPS_PROXY"] = proxy.url
            env["https_proxy"] = proxy.url
        }
        // Never route the loopback through the proxy — that's how a local MCP
        // server or an auth callback ends up going out and coming back nowhere.
        if env["NO_PROXY"] == nil && env["no_proxy"] == nil {
            env["NO_PROXY"] = "localhost,127.0.0.1,::1"
            env["no_proxy"] = "localhost,127.0.0.1,::1"
        }
    }

    /// Resolve off the main thread so the first Settings render (and the first
    /// agent spawn) hits a warm cache instead of paying for a login shell.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = resolved() }
    }

    // MARK: - The app's own requests

    /// The session the app's own HTTP goes through (AI streaming, search tools,
    /// updates). `URLSession` follows the system proxy natively, so auto needs no
    /// help here — only an explicit **manual** setting must be forced onto the
    /// connection. No manual proxy → this IS `URLSession.shared`. Cached; rebuilt
    /// by `invalidateCache()` when the setting changes.
    static var urlSession: URLSession {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = sessionCache { return cached }
        let session = makeSession()
        sessionCache = session
        return session
    }

    private nonisolated(unsafe) static var sessionCache: URLSession?

    /// A one-off session carrying the same manual-proxy settings as `urlSession`
    /// but owning `delegate`. Needed for the updater's download: `URLSession.shared`
    /// can't have a delegate, and a *per-task* delegate handed to the async
    /// `download(for:delegate:)` never receives the download-progress callbacks —
    /// the caller has to own the session for those to arrive. Invalidate it when
    /// the transfer is done (the session retains its delegate).
    static func session(delegate: URLSessionDelegate) -> URLSession {
        URLSession(configuration: proxiedConfiguration(),
                   delegate: delegate, delegateQueue: nil)
    }

    private static func makeSession() -> URLSession {
        guard normalize(manual).flatMap(URL.init(string:))?.host != nil else { return .shared }
        return URLSession(configuration: proxiedConfiguration())
    }

    /// `.default`, plus the manual proxy if one is set.
    private static func proxiedConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        guard let url = normalize(manual).flatMap(URL.init(string:)),
              let host = url.host
        else { return config }
        let scheme = url.scheme?.lowercased() ?? "http"
        let port = url.port ?? (scheme.hasPrefix("socks") ? 1080 : 80)
        var proxies: [AnyHashable: Any] = [:]
        if scheme.hasPrefix("socks") {
            proxies[kCFNetworkProxiesSOCKSEnable as String] = 1
            proxies[kCFNetworkProxiesSOCKSProxy as String] = host
            proxies[kCFNetworkProxiesSOCKSPort as String] = port
        } else {
            proxies[kCFNetworkProxiesHTTPEnable as String] = 1
            proxies[kCFNetworkProxiesHTTPProxy as String] = host
            proxies[kCFNetworkProxiesHTTPPort as String] = port
            proxies[kCFNetworkProxiesHTTPSEnable as String] = 1
            proxies[kCFNetworkProxiesHTTPSProxy as String] = host
            proxies[kCFNetworkProxiesHTTPSPort as String] = port
        }
        // The same loopback exemption `apply(to:)` writes for child processes.
        // Without it a manual proxy also swallows requests to a local endpoint —
        // a custom provider on `127.0.0.1`, the nono gateway override, an OAuth
        // callback — and the proxy answers for the host it could not reach, so a
        // local server that is simply down reports "HTTP 502" instead of a
        // connection error.
        proxies[kCFNetworkProxiesExceptionsList as String] = ["localhost", "127.0.0.1", "::1", "*.local"]
        config.connectionProxyDictionary = proxies
        return config
    }

    // MARK: - Normalizing what the user typed

    /// Accepts what people actually type — `127.0.0.1:7890`, `http://127.0.0.1:7890`,
    /// `socks5://…` — and returns a URL with a scheme, or nil if it's not usable.
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty,
              ["http", "https", "socks", "socks4", "socks5", "socks5h"].contains(scheme)
        else { return nil }
        return s
    }

    // MARK: - Detection

    /// macOS Network settings. PAC / auto-discovery is deliberately ignored: there's
    /// no environment variable that expresses "run this .pac script", so a PAC setup
    /// falls through to the shell layer rather than silently pinning a wrong host.
    private static func systemProxy() -> String? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue()
                as? [String: Any] else { return nil }

        func read(enable: CFString, host: CFString, port: CFString, scheme: String) -> String? {
            guard (settings[enable as String] as? Int) == 1,
                  let h = settings[host as String] as? String, !h.isEmpty
            else { return nil }
            let p = settings[port as String] as? Int
            return p.map { "\(scheme)://\(h):\($0)" } ?? "\(scheme)://\(h)"
        }

        // HTTPS first: it's what both CLIs actually need (every API call is TLS).
        return read(enable: kCFNetworkProxiesHTTPSEnable, host: kCFNetworkProxiesHTTPSProxy,
                    port: kCFNetworkProxiesHTTPSPort, scheme: "http")
            ?? read(enable: kCFNetworkProxiesHTTPEnable, host: kCFNetworkProxiesHTTPProxy,
                    port: kCFNetworkProxiesHTTPPort, scheme: "http")
            ?? read(enable: kCFNetworkProxiesSOCKSEnable, host: kCFNetworkProxiesSOCKSProxy,
                    port: kCFNetworkProxiesSOCKSPort, scheme: "socks5")
    }

    /// The proxy exported in the user's login shell — the case macOS's own settings
    /// never see (`export HTTPS_PROXY=…` in `.zshrc`). Cached behind `cacheLock`;
    /// a login shell is expensive enough that we must not pay for it per spawn.
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var shellCache: String??

    private static func shellProxy() -> String? {
        cacheLock.lock()
        if let cached = shellCache { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        let value = probeLoginShell()

        cacheLock.lock()
        shellCache = value
        cacheLock.unlock()
        return value
    }

    private static func probeLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        // One line per candidate, in preference order; the first non-empty wins.
        p.arguments = ["-lc",
                       #"printf '%s\n%s\n%s\n' "${HTTPS_PROXY:-$https_proxy}" "${ALL_PROXY:-$all_proxy}" "${HTTP_PROXY:-$http_proxy}""#]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            if let url = normalize(String(line)) { return url }
        }
        return nil
    }

    static func invalidateCache() {
        cacheLock.lock()
        shellCache = nil
        // In-flight streams keep the old session alive until they finish; new
        // requests pick up the new proxy. Never invalidate `.shared` itself.
        if let old = sessionCache, old !== URLSession.shared {
            old.finishTasksAndInvalidate()
        }
        sessionCache = nil
        cacheLock.unlock()
    }

    // MARK: - What Settings shows under the field

    /// One line describing what the next agent run will actually do — the point of
    /// the caption is that "auto" is never a mystery.
    static func statusLine() -> String {
        guard let proxy = resolved() else { return L("network.proxy.status.none") }
        switch proxy.source {
        case .manual:    return String(format: L("network.proxy.status.manual"), proxy.url)
        case .inherited: return String(format: L("network.proxy.status.inherited"), proxy.url)
        case .system:    return String(format: L("network.proxy.status.system"), proxy.url)
        case .shell:     return String(format: L("network.proxy.status.shell"), proxy.url)
        }
    }
}
