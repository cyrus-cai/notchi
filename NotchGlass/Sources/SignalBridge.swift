import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import IOKit.pwr_mgt
import SwiftUI
import SystemConfiguration
import UniformTypeIdentifiers

/// Notchi over Signal, backed by a local `signal-cli` JSON-RPC daemon.
///
/// Signal has no official Bot API: every client speaks the end-to-end encrypted
/// Signal protocol directly. `SignalBridge` links this Mac as a secondary
/// device (`signal-cli link -n "Notchi"`) with a QR code right in Settings,
/// then keeps `signal-cli -a <account> jsonRpc` running over stdio.
///
/// Messages sent to **Note to Self** on the linked account are answered here on
/// the Mac with the same model and tools as the notch, and land in Recent.
/// Messages to or from other people are ignored so Notchi never replies to a
/// friend's chat. Every timestamp Notchi sends is recorded to prevent
/// Note-to-Self echo loops.
@MainActor
final class SignalBridge: ObservableObject {
    static let shared = SignalBridge()

    enum State: Equatable {
        case off
        /// `signal-cli` is not installed on this Mac yet.
        case missingCLI
        /// Running `brew install signal-cli`.
        case installingCLI
        /// Probing `signal-cli` accounts or starting device linking.
        case checking
        /// Waiting for the user to scan the QR code in Signal on their phone.
        case linking(uri: String)
        /// Daemon running and listening on `account`.
        case connected(account: String)
        /// Paused by the user; account is kept so turning it back on is one click.
        case paused(account: String)
        /// Setup or launch failed.
        case failed(String)
    }

    @Published private(set) var state: State = .off
    /// True while creating/syncing the Notchi chat right after linking.
    @Published private(set) var settingUpChat = false
    /// True while Settings shows setup / QR linking so the panel stays open.
    var holdsPanel = false

    weak var model: NotchModel?

    // MARK: - Persistence Keys

    private static let accountKey = "SignalAccountNumber"
    private static let uuidKey = "SignalAccountUUID"
    private static let groupIDKey = "SignalNotchiGroupID"
    private static let avatarVersionKey = "SignalNotchiAvatarVersion"
    private static let currentAvatarVersion = 4
    private static let pausedKey = "SignalPaused"
    private static let threadKey = "SignalCurrentThread"
    private static let messagesKey = "SignalThreadByTimestamp"
    private static let sentTimestampsKey = "SignalSentTimestamps"
    private static let messagesCap = 500
    private static let sentTimestampsCap = 300
    private static let burstWait: UInt64 = 350_000_000
    private static let reactionMinProbability = 0.5

    // MARK: - Runtime State

    private var account: String? {
        get { UserDefaults.standard.string(forKey: Self.accountKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: Self.accountKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.accountKey)
            }
        }
    }

    private var accountUUID: String? {
        get { UserDefaults.standard.string(forKey: Self.uuidKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: Self.uuidKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.uuidKey)
            }
        }
    }

    /// Dedicated solo Signal group named "Notchi" with Notchi's two-eyes avatar.
    private var notchiGroupID: String? {
        get { UserDefaults.standard.string(forKey: Self.groupIDKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: Self.groupIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.groupIDKey)
            }
        }
    }

    var isPaired: Bool {
        if let account, !account.isEmpty { return true }
        return false
    }

    var isListening: Bool {
        daemonTask != nil && isPaired
    }

    private var daemonTask: Task<Void, Never>? {
        didSet {
            daemonAwake = daemonTask == nil ? nil : Awake()
            TelegramBridge.shared.applyLidSleep()
        }
    }
    private var daemonAwake: Awake?
    private var daemonProcess: Process?
    private var daemonStdin: FileHandle?
    private var activeProxyURL: String?
    private var proxyStore: SCDynamicStore?
    private var linkTask: Task<Void, Never>?
    private var installProcess: Process?

    private var nextRpcID = 1
    private var pendingRPC: [Int: CheckedContinuation<[String: Any], Never>] = [:]
    private var supportsNoteToSelf = true
    /// Set after a fresh pairing so the Notchi chat surfaces at the top of the
    /// user's Signal chat list (even if they previously deleted the thread).
    private var announceReadyOnConnect = false

    /// Timestamps of messages Notchi sent itself, so Note-to-Self sync echoes
    /// never trigger a loop.
    private var sentTimestamps: Set<Int64> = {
        let saved = UserDefaults.standard.array(forKey: SignalBridge.sentTimestampsKey) as? [NSNumber] ?? []
        return Set(saved.map(\.int64Value))
    }()

    /// Messages queued for burst merging before starting a round.
    private var burstQueue: [IncomingMessage] = []
    private var burstFlush: Task<Void, Never>?
    /// Serial execution chains per lane ("main" or a replied-to thread UUID).
    private var chains: [String: Task<Void, Never>] = [:]
    /// Threads stopped via `/stop`.
    private var stoppedThreads: Set<UUID> = []
    /// Steered follow-ups by thread and timestamp.
    private var steered: [UUID: [Int: [IncomingMessage]]] = [:]
    /// Active `pendingQuestion` waiting for the user's reply in Signal.
    private var activeQuestion: (id: UUID, options: [String])?
    /// Bare command waiting for the next message (or folder/action pick).
    private var pendingMode: Mode?
    /// Agent tasks started from Signal, by report message timestamp (reply to continue).
    private var agentReports: [Int64: UUID] = [:]
    /// Latest resumable / retryable / undoable state for quick text commands.
    private var lastInterrupted: (thread: UUID, turn: UUID)?
    private var lastFailedThread: UUID?
    private var lastUndoCapture: NotchModel.Turn.Capture?

    private enum Mode: Equatable {
        case note, remind, code, loop, issue, actions
        case action(UUID)
        case pickAction(ids: [UUID], input: String?)
        case pickFolder(task: String, folders: [URL])
    }

    // MARK: - CLI Discovery

    static func findCLI() -> String? {
        let fm = FileManager.default
        let fixed = [
            "/opt/homebrew/bin/signal-cli",
            "/usr/local/bin/signal-cli",
            "\(NSHomeDirectory())/.local/bin/signal-cli",
        ]
        for path in fixed where fm.isExecutableFile(atPath: path) {
            return path
        }
        return ShellEnvironment.which(["signal-cli"])
    }

    static func findBrew() -> String? {
        let fm = FileManager.default
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] where fm.isExecutableFile(atPath: path) {
            return path
        }
        return ShellEnvironment.which(["brew"])
    }

    /// True when Homebrew is available on this Mac for one-click install.
    static var hasBrew: Bool { findBrew() != nil }

    /// Renders a `sgnl://linkdevice?...` URI into a crisp QR code image.
    static func qrImage(for uri: String) -> NSImage? {
        guard let data = uri.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    // MARK: - Lifecycle

    /// At app launch: resume daemon if an account was paired and not paused.
    func start() {
        guard let account, !account.isEmpty else { return }
        if UserDefaults.standard.bool(forKey: Self.pausedKey) {
            state = .paused(account: account)
            return
        }
        guard Self.findCLI() != nil else {
            state = .missingCLI
            return
        }
        state = .connected(account: account)
        startDaemon(ensureGroup: true)
    }

    /// At app quit: terminate any running child processes cleanly.
    func stop() {
        stopWatchingSystemProxy()
        cancelLink()
        stopDaemon()
        if let p = installProcess, p.isRunning { p.terminate() }
        installProcess = nil
    }

    /// Restarts the running `signal-cli` daemon when the resolved proxy changes
    /// (Settings → General proxy field or macOS system proxy toggle).
    func reloadForProxyChange() {
        guard daemonTask != nil else { return }
        let next = ProxyConfig.resolved()?.url
        guard next != activeProxyURL else { return }
        startDaemon(ensureGroup: isPaired)
    }

    /// Begins setup: ensures the single multi-account `signal-cli jsonRpc`
    /// daemon is warm, then runs `startLink` / `finishLink` over JSON-RPC.
    func beginSetup() async {
        cancelLink()
        guard Self.findCLI() != nil else {
            state = .missingCLI
            return
        }
        state = .checking
        startLinkingViaRPC()
    }

    /// Starts a fresh QR code link on the existing warm `signal-cli jsonRpc` daemon.
    func startNewLink() {
        cancelLink()
        guard Self.findCLI() != nil else {
            state = .missingCLI
            return
        }
        state = .checking
        startLinkingViaRPC()
    }

    /// Runs `brew install signal-cli` in the background, then proceeds to setup.
    func installCLI() async {
        guard let brew = Self.findBrew() else {
            state = .missingCLI
            return
        }
        if case .installingCLI = state { return }
        state = .installingCLI
        let exitCode: Int32 = await withCheckedContinuation { continuation in
            let p = ShellEnvironment.makeProcess(brew, ["install", "signal-cli"])
            let errPipe = Pipe()
            p.standardOutput = FileHandle.nullDevice
            p.standardError = errPipe
            p.standardInput = FileHandle.nullDevice
            self.installProcess = p
            p.terminationHandler = { proc in
                DispatchQueue.main.async {
                    if self.installProcess === proc { self.installProcess = nil }
                    continuation.resume(returning: proc.terminationStatus)
                }
            }
            do {
                try p.run()
            } catch {
                self.installProcess = nil
                continuation.resume(returning: -1)
            }
        }
        guard exitCode == 0, Self.findCLI() != nil else {
            state = .failed(L("signal.installFailed"))
            return
        }
        await beginSetup()
    }

    /// Pauses the daemon while keeping the linked account for one-click resume.
    func disconnect() {
        cancelLink()
        stopDaemon()
        guard let account, !account.isEmpty else {
            state = .off
            return
        }
        UserDefaults.standard.set(true, forKey: Self.pausedKey)
        state = .paused(account: account)
    }

    /// Resumes a paused Signal connection.
    func reconnect() {
        guard let account, !account.isEmpty else {
            Task { await beginSetup() }
            return
        }
        guard Self.findCLI() != nil else {
            state = .missingCLI
            return
        }
        announceReadyOnConnect = true
        UserDefaults.standard.removeObject(forKey: Self.pausedKey)
        state = .connected(account: account)
        startDaemon(ensureGroup: true)
    }

    /// Forgets the saved account and clears its local `signal-cli` data.
    /// When `relink` is true, keeps the warm `signal-cli jsonRpc` daemon alive
    /// so `deleteLocalAccountData` and `startLink` run back-to-back with zero
    /// extra JVM cold starts.
    func forget(relink: Bool = false) {
        let oldAccount = account
        cancelLink()
        for key in [Self.accountKey, Self.uuidKey, Self.groupIDKey, Self.avatarVersionKey,
                    Self.pausedKey, Self.threadKey, Self.messagesKey, Self.sentTimestampsKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        sentTimestamps.removeAll()
        settingUpChat = false
        state = relink ? .checking : .off

        if let oldAccount, !oldAccount.isEmpty, daemonProcess?.isRunning == true {
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.rpc("deleteLocalAccountData", [
                    "account": oldAccount,
                    "ignoreRegistered": true,
                ], timeoutSeconds: 15)
                if relink {
                    self.startLinkingViaRPC()
                } else {
                    self.stopDaemon()
                }
            }
        } else if relink {
            if let oldAccount, !oldAccount.isEmpty, let cli = Self.findCLI() {
                Task { @MainActor [weak self] in
                    await Self.deleteLocalAccountData(cli: cli, account: oldAccount)
                    self?.startLinkingViaRPC()
                }
            } else {
                startLinkingViaRPC()
            }
        } else {
            stopDaemon()
            if let oldAccount, !oldAccount.isEmpty, let cli = Self.findCLI() {
                Task { await Self.deleteLocalAccountData(cli: cli, account: oldAccount) }
            }
        }
    }

    nonisolated private static func deleteLocalAccountData(cli: String, account: String) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = ShellEnvironment.makeProcess(cli, ["-a", account, "deleteLocalAccountData", "--ignore-registered"])
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                try? p.run()
                p.waitUntilExit()
                done.resume()
            }
        }
    }

    // MARK: - Linking & Account Discovery

    private struct AccountInfo {
        let number: String
        let uuid: String?
    }

    private func listAccounts(cli: String) async -> [AccountInfo] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = ShellEnvironment.makeProcess(cli, ["-o", "json", "listAccounts"])
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    continuation.resume(returning: [])
                    return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard let text = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: Self.parseAccounts(text))
            }
        }
    }

    nonisolated private static func parseAccounts(_ output: String) -> [AccountInfo] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // JSON array: [{"number": "+...", "uuid": "..."}]
        if let data = trimmed.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array.compactMap { item in
                guard let number = (item["number"] as? String) ?? (item["username"] as? String),
                      !number.isEmpty else { return nil }
                return AccountInfo(number: number, uuid: item["uuid"] as? String)
            }
        }
        // NDJSON lines or plain text fallback ("Number: +1234567890")
        var results: [AccountInfo] = []
        for line in trimmed.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("{"), let d = l.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let number = (obj["number"] as? String) ?? (obj["username"] as? String),
               !number.isEmpty {
                results.append(AccountInfo(number: number, uuid: obj["uuid"] as? String))
            } else if l.hasPrefix("Number:") {
                let number = l.dropFirst("Number:".count).trimmingCharacters(in: .whitespaces)
                if !number.isEmpty { results.append(AccountInfo(number: number, uuid: nil)) }
            }
        }
        return results
    }

    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func appendLines(_ chunk: Data) -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            data.append(chunk)
            var lines: [Data] = []
            while let nl = data.firstIndex(of: 0x0A) {
                lines.append(data.prefix(upTo: nl))
                data.removeSubrange(...nl)
            }
            return lines
        }
    }

    /// Runs `startLink` + `finishLink` inside the already-running multi-account
    /// `signal-cli jsonRpc` daemon — zero extra JVM cold starts between Remove,
    /// QR linking, group setup, and sending `Connected.`.
    private func startLinkingViaRPC() {
        cancelLink()
        if daemonTask == nil {
            startDaemon(ensureGroup: false)
        }
        linkTask = Task { [weak self] in
            guard let self else { return }
            // Wait briefly for the daemon process to spawn if it just started.
            for _ in 0..<40 where self.daemonProcess?.isRunning != true {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if Task.isCancelled { return }
            let started = await self.rpc("startLink", [:], timeoutSeconds: 30)
            if Task.isCancelled { return }
            guard let result = started["result"] as? [String: Any],
                  let uri = result["deviceLinkUri"] as? String, !uri.isEmpty else {
                let msg = ((started["error"] as? [String: Any])?["message"] as? String) ?? ""
                self.state = .failed(Self.friendlyLinkError(msg))
                return
            }
            self.state = .linking(uri: uri)

            let finished = await self.rpc("finishLink", [
                "deviceLinkUri": uri,
                "deviceName": "Notchi",
            ], timeoutSeconds: 120)
            if Task.isCancelled { return }

            if let error = finished["error"] as? [String: Any] {
                let msg = (error["message"] as? String) ?? ""
                if msg.lowercased().contains("timed out"), self.holdsPanel {
                    self.startLinkingViaRPC()
                } else {
                    self.state = .failed(Self.friendlyLinkError(msg))
                }
                return
            }

            let number: String?
            if let str = finished["result"] as? String, !str.isEmpty {
                number = str
            } else if let obj = finished["result"] as? [String: Any] {
                number = (obj["number"] as? String) ?? (obj["username"] as? String)
            } else {
                number = nil
            }
            guard let number, !number.isEmpty else {
                self.state = .failed(L("signal.linkFailed"))
                return
            }
            self.finishPairing(account: number, uuid: nil)
        }
    }

    /// Turns raw `signal-cli` error text (which may include Java `INFO`/`WARN`
    /// lines) into a concise user-facing message.
    private static func friendlyLinkError(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("411") || lower.contains("device limit") || lower.contains("too many") {
            return L("signal.linkDeviceLimit")
        }
        if lower.contains("already") && lower.contains("exist") {
            return L("signal.linkAlreadyExists")
        }
        let meaningful = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("INFO ") && !$0.hasPrefix("DEBUG ") && !$0.hasPrefix("WARN ") }
        if let last = meaningful.last, !last.isEmpty {
            return String(last.prefix(140))
        }
        return L("signal.linkFailed")
    }

    private func cancelLink() {
        linkTask?.cancel()
        linkTask = nil
    }

    private func finishPairing(account number: String, uuid: String?) {
        account = number
        accountUUID = uuid
        announceReadyOnConnect = true
        settingUpChat = true
        UserDefaults.standard.removeObject(forKey: Self.pausedKey)
        state = .connected(account: number)
        Task { await TelegramBridge.shared.installLidRuleAfterPairing() }
        // Daemon is already warm in the same JVM — set up the Notchi chat immediately.
        if daemonProcess?.isRunning == true {
            Task { @MainActor [weak self] in
                await self?.ensureNotchiGroup()
            }
        } else {
            startDaemon(ensureGroup: true)
        }
    }

    // MARK: - JSON-RPC Daemon (Single Multi-Account JVM)

    private func startDaemon(ensureGroup: Bool) {
        stopDaemon()
        startWatchingSystemProxy()
        daemonTask = Task { [weak self] in
            var backoff: UInt64 = 2
            var shouldEnsure = ensureGroup
            while !Task.isCancelled {
                guard let self else { return }
                guard let cli = Self.findCLI() else {
                    self.state = .missingCLI
                    return
                }
                let startedAt = Date()
                await self.runDaemonSession(cli: cli, ensureGroup: shouldEnsure)
                shouldEnsure = true
                if Task.isCancelled { return }
                // Reset backoff if the daemon stayed healthy for > 30s.
                if Date().timeIntervalSince(startedAt) > 30 { backoff = 2 }
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 60)
            }
        }
    }

    private func stopDaemon() {
        daemonTask?.cancel()
        daemonTask = nil
        activeProxyURL = nil
        terminateDaemonProcess()
    }

    private func terminateDaemonProcess() {
        daemonStdin = nil
        if let p = daemonProcess {
            if p.isRunning { p.terminate() }
            daemonProcess = nil
        }
        let inflight = pendingRPC
        pendingRPC.removeAll()
        for (_, cont) in inflight {
            cont.resume(returning: ["error": ["message": "stopped"]])
        }
    }

    private func runDaemonSession(cli: String, ensureGroup: Bool) async {
        // Multi-account JSON-RPC mode: one process handles linking, cleanup, groups, and messaging.
        let proxy = ProxyConfig.resolved()
        activeProxyURL = proxy?.url
        let p = Self.makeSignalProcess(cli, ["jsonRpc"], proxy: proxy)
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice

        daemonProcess = p
        daemonStdin = inPipe.fileHandleForWriting

        let buffer = LineBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            for lineData in buffer.appendLines(chunk) where !lineData.isEmpty {
                Task { @MainActor [weak self] in
                    self?.handleRPCLine(lineData)
                }
            }
        }

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            p.terminationHandler = { [weak self] proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor [weak self] in
                    if self?.daemonProcess === proc {
                        self?.terminateDaemonProcess()
                    }
                    done.resume()
                }
            }
            do {
                try p.run()
                if ensureGroup, let acc = self.account, !acc.isEmpty {
                    Task { @MainActor [weak self] in
                        guard let self, self.daemonProcess === p else { return }
                        await self.ensureNotchiGroup()
                    }
                }
            } catch {
                self.terminateDaemonProcess()
                done.resume()
            }
        }
    }

    // MARK: - Proxy Support

    /// Builds a `signal-cli` process configured with Java/GraalVM proxy system
    /// properties. `signal-cli`'s underlying `libsignal` ignores `HTTP(S)_PROXY`
    /// and macOS system proxy settings, so HTTP/SOCKS proxies must be passed as
    /// `-D...` properties (leading CLI args for Homebrew's GraalVM native binary,
    /// or `JAVA_OPTS` for JVM wrapper script installs).
    private static func makeSignalProcess(_ cli: String, _ arguments: [String],
                                          proxy: ProxyConfig.Resolved?) -> Process {
        let props = proxyProperties(for: proxy)
        guard !props.isEmpty else {
            return ShellEnvironment.makeProcess(cli, arguments)
        }
        if isShellScript(cli) {
            let p = ShellEnvironment.makeProcess(cli, arguments)
            var env = p.environment ?? [:]
            let existing = env["JAVA_OPTS"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let joined = props.joined(separator: " ")
            env["JAVA_OPTS"] = existing.isEmpty ? joined : "\(existing) \(joined)"
            p.environment = env
            return p
        }
        return ShellEnvironment.makeProcess(cli, props + arguments)
    }

    private static func proxyProperties(for proxy: ProxyConfig.Resolved?) -> [String] {
        guard let proxy,
              let url = URL(string: proxy.url),
              let host = url.host, !host.isEmpty
        else { return [] }
        let port = url.port ?? (proxy.isSOCKS ? 1080 : 80)
        var props: [String] = []
        if proxy.isSOCKS {
            props.append("-DsocksProxyHost=\(host)")
            props.append("-DsocksProxyPort=\(port)")
            if let user = url.user, !user.isEmpty {
                props.append("-Djava.net.socks.username=\(user)")
            }
            if let pass = url.password, !pass.isEmpty {
                props.append("-Djava.net.socks.password=\(pass)")
            }
        } else {
            props.append("-Dhttp.proxyHost=\(host)")
            props.append("-Dhttp.proxyPort=\(port)")
            props.append("-Dhttps.proxyHost=\(host)")
            props.append("-Dhttps.proxyPort=\(port)")
            if let user = url.user, !user.isEmpty {
                props.append("-Dhttp.proxyUser=\(user)")
                props.append("-Dhttps.proxyUser=\(user)")
            }
            if let pass = url.password, !pass.isEmpty {
                props.append("-Dhttp.proxyPassword=\(pass)")
                props.append("-Dhttps.proxyPassword=\(pass)")
            }
        }
        return props
    }

    private static func isShellScript(_ path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 2), head.count == 2 else { return false }
        return head[0] == 0x23 && head[1] == 0x21 // "#!"
    }

    private func startWatchingSystemProxy() {
        guard proxyStore == nil else { return }
        var context = SCDynamicStoreContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "com.notchglass.signal.proxy" as CFString, { _, _, _ in
            Task { @MainActor in
                SignalBridge.shared.reloadForProxyChange()
            }
        }, &context) else { return }
        SCDynamicStoreSetNotificationKeys(store, ["State:/Network/Global/Proxies" as CFString] as CFArray, nil)
        SCDynamicStoreSetDispatchQueue(store, DispatchQueue.main)
        proxyStore = store
    }

    private func stopWatchingSystemProxy() {
        if let store = proxyStore {
            SCDynamicStoreSetDispatchQueue(store, nil)
            proxyStore = nil
        }
    }

    // MARK: - Dedicated "Notchi" Chat (Solo Group + Two-Eyes Avatar)

    /// Ensures a dedicated solo Signal group named "Notchi" with Notchi's
    /// two-eyes avatar exists on the linked account, so the user chats with
    /// "Notchi" instead of "Note to Self".
    /// When `forceCreate` is true (e.g. after the user disbanded/left the old
    /// group), skips reusing cached group entries and creates a fresh one.
    private func ensureNotchiGroup(forceCreate: Bool = false) async {
        guard let account, !account.isEmpty else { return }
        let shouldAnnounce = announceReadyOnConnect
        announceReadyOnConnect = false
        if shouldAnnounce || notchiGroupID == nil { settingUpChat = true }
        defer { settingUpChat = false }

        if !forceCreate {
            let listed = await rpc("listGroups", ["account": account], timeoutSeconds: 30)
            let groups = listed["result"] as? [[String: Any]] ?? []

            func isActiveSoloNotchi(_ g: [String: Any]) -> Bool {
                let isMember = g["isMember"] as? Bool ?? false
                let isBlocked = g["isBlocked"] as? Bool ?? false
                guard isMember, !isBlocked else { return false }
                let members = g["members"] as? [[String: Any]] ?? []
                return members.count <= 1
            }

            // 1. Keep the saved group if it still exists and we are an active member.
            if let saved = notchiGroupID,
               groups.contains(where: { ($0["id"] as? String) == saved && isActiveSoloNotchi($0) }) {
                if UserDefaults.standard.integer(forKey: Self.avatarVersionKey) < Self.currentAvatarVersion {
                    await refreshGroupAvatar(groupID: saved)
                }
                if shouldAnnounce {
                    _ = await sendNoteToSelf(L("telegram.paired"))
                }
                return
            }

            // 2. Reuse the most recent active solo group named "Notchi" (e.g. after reinstall).
            if let existing = groups.last(where: { g in
                (g["name"] as? String) == "Notchi" && isActiveSoloNotchi(g)
            }), let id = existing["id"] as? String, !id.isEmpty {
                notchiGroupID = id
                if UserDefaults.standard.integer(forKey: Self.avatarVersionKey) < Self.currentAvatarVersion {
                    await refreshGroupAvatar(groupID: id)
                }
                if shouldAnnounce {
                    _ = await sendNoteToSelf(L("telegram.paired"))
                }
                return
            }
        }

        // 3. Create a fresh solo group named "Notchi" with Notchi's two-eyes avatar.
        var params: [String: Any] = [
            "account": account,
            "name": "Notchi",
            "description": L("telegram.description"),
        ]
        let avatarURL = renderNotchiAvatarFile()
        if let avatarURL { params["avatar"] = avatarURL.path }
        let created = await rpc("updateGroup", params, timeoutSeconds: 30)
        if let avatarURL { try? FileManager.default.removeItem(at: avatarURL) }
        if let result = created["result"] as? [String: Any],
           let groupID = result["groupId"] as? String, !groupID.isEmpty {
            notchiGroupID = groupID
            UserDefaults.standard.set(Self.currentAvatarVersion, forKey: Self.avatarVersionKey)
            if !forceCreate {
                // Send a short connected message so the new chat immediately appears
                // in Signal's conversation list on the phone.
                _ = await sendNoteToSelf(L("telegram.paired"))
            }
        }
    }

    private func refreshGroupAvatar(groupID: String) async {
        guard let account, !account.isEmpty, let avatarURL = renderNotchiAvatarFile() else { return }
        defer { try? FileManager.default.removeItem(at: avatarURL) }
        let resp = await rpc("updateGroup", [
            "account": account,
            "groupId": groupID,
            "avatar": avatarURL.path,
        ], timeoutSeconds: 30)
        if resp["error"] == nil {
            UserDefaults.standard.set(Self.currentAvatarVersion, forKey: Self.avatarVersionKey)
        }
    }

    /// Renders Notchi's two-eyes mark (`NotchiMarkEyes`) on a black background
    /// as a 320×320 JPEG for the Signal avatar. Forces dark appearance so
    /// `NotchiMarkPose.ink` is always crisp white regardless of macOS Light Mode.
    private func renderNotchiAvatarFile() -> URL? {
        let side: CGFloat = 320
        let renderer = ImageRenderer(content:
            ZStack {
                Color.black
                NotchiMarkEyes(pose: NotchiMarkPose(), eyeHeight: 105)
            }
            .frame(width: side, height: side)
            .environment(\.colorScheme, .dark))
        renderer.scale = 1
        guard let cg = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cg)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchi-signal-avatar-\(UUID().uuidString).jpg")
        guard (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    private func handleRPCLine(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // Response to an outgoing RPC request
        if let id = (json["id"] as? NSNumber)?.intValue, let cont = pendingRPC.removeValue(forKey: id) {
            cont.resume(returning: json)
            return
        }
        // Incoming notification
        if json["method"] as? String == "receive", let params = json["params"] as? [String: Any] {
            handleReceive(params)
        }
    }

    @discardableResult
    private func rpc(_ method: String, _ params: [String: Any], timeoutSeconds: UInt64 = 20) async -> [String: Any] {
        guard let stdin = daemonStdin, daemonProcess?.isRunning == true else {
            return ["error": ["message": "daemon not running"]]
        }
        let id = nextRpcID
        nextRpcID += 1
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else {
            return ["error": ["message": "encode failed"]]
        }
        data.append(0x0A)

        return await withCheckedContinuation { cont in
            pendingRPC[id] = cont
            do {
                try stdin.write(contentsOf: data)
            } catch {
                if let c = pendingRPC.removeValue(forKey: id) {
                    c.resume(returning: ["error": ["message": error.localizedDescription]])
                }
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                if let c = self?.pendingRPC.removeValue(forKey: id) {
                    c.resume(returning: ["error": ["message": "timeout"]])
                }
            }
        }
    }

    // MARK: - Sending Messages

    @discardableResult
    private func sendNoteToSelf(_ text: String, attachments: [String] = [],
                                quoteTimestamp: Int64? = nil,
                                allowGroupRecreate: Bool = true) async -> Int64? {
        guard let account else { return nil }
        var params: [String: Any] = ["account": account, "message": text]
        if let groupID = notchiGroupID, !groupID.isEmpty {
            params["groupId"] = groupID
            params["notifySelf"] = true
        } else if supportsNoteToSelf {
            params["noteToSelf"] = true
        } else {
            params["recipient"] = [account]
        }
        if !attachments.isEmpty { params["attachments"] = attachments }
        if let quoteTimestamp, quoteTimestamp > 0 {
            params["quoteTimestamp"] = quoteTimestamp
            params["quoteAuthor"] = account
        }

        var response = await rpc("send", params)
        // If sending to the Notchi group failed because the group itself is gone
        // or invalid (not a transient network/timeout error), recreate a fresh
        // Notchi group and retry once.
        if let error = response["error"] as? [String: Any],
           notchiGroupID != nil, allowGroupRecreate,
           Self.isGroupInvalidError(error) {
            await ensureNotchiGroup(forceCreate: true)
            if let freshGroup = notchiGroupID, !freshGroup.isEmpty {
                params["groupId"] = freshGroup
                params.removeValue(forKey: "quoteTimestamp")
                params.removeValue(forKey: "quoteAuthor")
                response = await rpc("send", params)
            }
        }
        if response["error"] != nil, notchiGroupID == nil, supportsNoteToSelf {
            // Older signal-cli versions expect `recipient: [self]` instead of `noteToSelf: true`.
            supportsNoteToSelf = false
            params.removeValue(forKey: "noteToSelf")
            params["recipient"] = [account]
            response = await rpc("send", params)
        }
        if let result = response["result"] as? [String: Any],
           let ts = (result["timestamp"] as? NSNumber)?.int64Value {
            recordSentTimestamp(ts)
            return ts
        }
        return nil
    }

    private static func isGroupInvalidError(_ error: [String: Any]) -> Bool {
        let msg = ((error["message"] as? String) ?? "").lowercased()
        let hints = ["group not found", "unknown group", "not a member", "invalid group", "blocked", "permission"]
        return hints.contains(where: { msg.contains($0) })
    }

    private func sendTyping() async {
        guard let account else { return }
        if let groupID = notchiGroupID, !groupID.isEmpty {
            _ = await rpc("sendTyping", ["account": account, "groupId": groupID])
        } else {
            _ = await rpc("sendTyping", ["account": account, "recipient": [account]])
        }
    }

    private func sendReaction(emoji: String, targetTimestamp: Int64) async {
        guard let account, targetTimestamp > 0 else { return }
        var params: [String: Any] = [
            "account": account,
            "emoji": emoji,
            "targetAuthor": account,
            "targetTimestamp": targetTimestamp,
        ]
        if let groupID = notchiGroupID, !groupID.isEmpty {
            params["groupId"] = groupID
            params["notifySelf"] = true
        } else {
            params["recipient"] = [account]
        }
        _ = await rpc("sendReaction", params)
    }

    private func recordSentTimestamp(_ ts: Int64) {
        sentTimestamps.insert(ts)
        var saved = UserDefaults.standard.array(forKey: Self.sentTimestampsKey) as? [NSNumber] ?? []
        saved.append(NSNumber(value: ts))
        if saved.count > Self.sentTimestampsCap {
            saved = Array(saved.suffix(Self.sentTimestampsCap))
            sentTimestamps = Set(saved.map(\.int64Value))
        }
        UserDefaults.standard.set(saved, forKey: Self.sentTimestampsKey)
    }

    // MARK: - Receiving & Routing

    private struct IncomingAttachment {
        let id: String
        let contentType: String
        let filename: String?
    }

    private struct IncomingMessage {
        let timestamp: Int64
        let text: String
        let attachments: [IncomingAttachment]
        let quoteTimestamp: Int64?
        let quoteText: String?
    }

    private func handleReceive(_ params: [String: Any]) {
        guard let account, let envelope = params["envelope"] as? [String: Any] else { return }
        if let receiveAccount = params["account"] as? String, receiveAccount != account { return }

        // 1. Linked device sync: messages sent from the user's phone arrive as
        //    syncMessage.sentMessage.
        if let sync = envelope["syncMessage"] as? [String: Any],
           let sent = sync["sentMessage"] as? [String: Any] {
            if let group = sent["groupInfo"] as? [String: Any],
               let gid = group["groupId"] as? String {
                guard let notchiGroupID, gid == notchiGroupID else { return }
                if (group["type"] as? String)?.uppercased() == "QUIT" {
                    self.notchiGroupID = nil
                    return
                }
                if let msg = parseMessageBody(sent) { enqueue(msg) }
                return
            }
            // Fallback to Note-to-Self only when no dedicated Notchi group is set up.
            guard notchiGroupID == nil else { return }
            let destNum = (sent["destinationNumber"] as? String) ?? (sent["destination"] as? String)
            let destUUID = sent["destinationUuid"] as? String
            let isSelf = (destNum == account) || (accountUUID != nil && destUUID == accountUUID)
            guard isSelf else { return }
            if let msg = parseMessageBody(sent) { enqueue(msg) }
            return
        }

        // 2. Direct dataMessage from self (group or Note-to-Self depending on signal-cli version).
        if let data = envelope["dataMessage"] as? [String: Any] {
            let srcNum = (envelope["sourceNumber"] as? String) ?? (envelope["source"] as? String)
            let srcUUID = envelope["sourceUuid"] as? String
            let isSelf = (srcNum == account) || (accountUUID != nil && srcUUID == accountUUID)
            guard isSelf else { return }
            if let group = data["groupInfo"] as? [String: Any],
               let gid = group["groupId"] as? String {
                guard let notchiGroupID, gid == notchiGroupID else { return }
            } else {
                guard notchiGroupID == nil else { return }
            }
            if let msg = parseMessageBody(data, fallbackTimestamp: (envelope["timestamp"] as? NSNumber)?.int64Value) {
                enqueue(msg)
            }
        }
    }

    private func parseMessageBody(_ body: [String: Any], fallbackTimestamp: Int64? = nil) -> IncomingMessage? {
        guard let ts = (body["timestamp"] as? NSNumber)?.int64Value ?? fallbackTimestamp else { return nil }
        // Loop guard: skip anything Notchi itself sent.
        if sentTimestamps.contains(ts) { return nil }

        let text = (body["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawAttachments = body["attachments"] as? [[String: Any]] ?? []
        let attachments: [IncomingAttachment] = rawAttachments.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let ct = (item["contentType"] as? String) ?? "application/octet-stream"
            return IncomingAttachment(id: id, contentType: ct, filename: item["filename"] as? String)
        }
        guard !text.isEmpty || !attachments.isEmpty else { return nil }

        let quote = body["quote"] as? [String: Any]
        let quoteTS = (quote?["id"] as? NSNumber)?.int64Value
        let quoteText = quote?["text"] as? String

        return IncomingMessage(timestamp: ts, text: text, attachments: attachments,
                               quoteTimestamp: quoteTS, quoteText: quoteText)
    }

    private func enqueue(_ message: IncomingMessage) {
        // 1. If a tool/model question is awaiting an answer, route this reply directly to it.
        if let q = activeQuestion, message.attachments.isEmpty, !message.text.isEmpty {
            activeQuestion = nil
            let chosen: String
            if let idx = Int(message.text), q.options.indices.contains(idx - 1) {
                chosen = q.options[idx - 1]
            } else {
                chosen = message.text
            }
            model?.chooseUserOption(chosen, questionID: q.id)
            return
        }

        // 2. Commands run immediately without waiting for burst merge.
        if message.attachments.isEmpty, let (cmd, rest) = Self.command(in: message.text) {
            if handleCommand(cmd, rest: rest, message: message) { return }
        }

        // 3. Armed bare command / folder pick / action pick takes the next message.
        if let mode = pendingMode, message.attachments.isEmpty, !message.text.isEmpty {
            pendingMode = nil
            Task { await runPendingMode(mode, text: message.text, replyTo: message.timestamp) }
            return
        }

        // 4. Reply to an Agent report continues that Agent session.
        if let qts = message.quoteTimestamp, let taskID = agentReports[qts],
           message.attachments.isEmpty, !message.text.isEmpty {
            Task { await continueAgent(taskID: taskID, prompt: message.text, replyTo: message.timestamp) }
            return
        }

        // 5. If a round is currently running on the target thread, steer it instead of queuing.
        let targetThread = message.quoteTimestamp.flatMap { threadForTimestamp($0) } ?? defaultThread()
        if let targetThread, let model, model.liveThread(targetThread) != nil,
           message.attachments.isEmpty, !message.text.isEmpty {
            let tag = Int(message.timestamp % Int64(Int.max))
            if model.steer(threadID: targetThread, text: message.text, tag: tag) {
                steered[targetThread, default: [:]][tag, default: []].append(message)
                return
            }
        }

        burstQueue.append(message)
        burstFlush?.cancel()
        burstFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.burstWait)
            guard !Task.isCancelled, let self else { return }
            let batch = self.burstQueue
            self.burstQueue.removeAll()
            self.burstFlush = nil
            guard !batch.isEmpty else { return }
            self.dispatch(batch)
        }
    }

    private func dispatch(_ batch: [IncomingMessage], action: PromptShortcut? = nil) {
        let repliedThread = batch.compactMap { $0.quoteTimestamp.flatMap { threadForTimestamp($0) } }.first
        let laneKey = repliedThread?.uuidString ?? "main"
        let previous = chains[laneKey]
        chains[laneKey] = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.answer(batch, repliedThread: repliedThread, action: action)
        }
    }

    // MARK: - Answering via NotchModel

    private func answer(_ batch: [IncomingMessage], repliedThread: UUID?,
                        action: PromptShortcut? = nil) async {
        guard let model, let last = batch.last else { return }

        var textParts: [String] = []
        var images: [NSImage] = []

        if let quote = batch.first?.quoteText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !quote.isEmpty, repliedThread == nil {
            let limit = NotchModel.replyQuoteLimit
            let clipped = quote.count > limit ? String(quote.prefix(limit)) + "…" : quote
            textParts.append("[Replying to: \(clipped)]")
        }

        for msg in batch {
            if !msg.text.isEmpty { textParts.append(msg.text) }
            for att in msg.attachments {
                guard let url = Self.attachmentURL(id: att.id) else { continue }
                let ct = att.contentType.lowercased()
                if ct.hasPrefix("image/"), let img = NSImage(contentsOf: url) {
                    images.append(img)
                } else if ct.hasPrefix("video/") {
                    let stills = await TelegramBridge.frames(of: url, count: 4)
                    images.append(contentsOf: stills)
                    if let transcript = await TelegramBridge.transcript(of: url) {
                        textParts.append(transcript)
                    } else if stills.isEmpty {
                        textParts.append("[Video]")
                    }
                } else if ct.hasPrefix("audio/") {
                    if let transcript = await TelegramBridge.transcript(of: url) {
                        textParts.append(transcript)
                    } else {
                        textParts.append("[Voice message]")
                    }
                } else if let docText = Self.readTextAttachment(url, filename: att.filename) {
                    textParts.append(docText)
                }
            }
        }

        var question = textParts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty || !images.isEmpty else {
            _ = await sendNoteToSelf(L("signal.unsupported"), quoteTimestamp: last.timestamp)
            return
        }
        if let action {
            question = """
            \(action.prompt.trimmingCharacters(in: .whitespacesAndNewlines))

            <selected_text>
            \(question)
            </selected_text>
            """
        }

        let existingThread = action != nil ? nil : (repliedThread ?? defaultThread())
        let seedIDs = Set(existingThread.flatMap { id in
            model.history.first(where: { $0.id == id })?.conversation.map(\.id)
        } ?? [])
        let previousAnswer = existingThread.flatMap { id in
            model.history.first(where: { $0.id == id })?.conversation.last(where: { $0.role == "assistant" })?.text
        } ?? ""

        guard let threadID = model.runChannelRound(
            threadID: existingThread,
            question: question,
            images: images,
            origin: .signal,
            pin: action?.pin
        ) else {
            _ = await sendNoteToSelf(L("signal.failed"), quoteTimestamp: last.timestamp)
            return
        }

        if repliedThread == nil && action == nil { currentThread = threadID }
        model.openSteering(threadID: threadID)
        for msg in batch { remember(timestamp: msg.timestamp, thread: threadID) }

        react(to: question, previous: previousAnswer, thread: threadID, targetTimestamp: last.timestamp)
        Task { [weak self] in await self?.sendTyping() }
        await stream(thread: threadID, seedIDs: seedIDs, replyTo: last.timestamp)

        // Answer any steered messages that arrived too late to be read by the round.
        let unreadTags = Set(model.unreadSteerTags(threadID: threadID))
        let leftovers = (steered.removeValue(forKey: threadID) ?? [:])
            .filter { unreadTags.contains($0.key) }
            .sorted { $0.key < $1.key }
            .flatMap(\.value)
        if !leftovers.isEmpty {
            await answer(leftovers, repliedThread: repliedThread)
        }
    }

    private func stream(thread: UUID, seedIDs: Set<UUID>, replyTo: Int64) async {
        guard let model else { return }
        var sawLive = false
        var askedQuestions: Set<UUID> = []
        var ticks = 0
        while true {
            try? await Task.sleep(nanoseconds: 200_000_000)
            ticks += 1
            guard let live = model.liveThread(thread) else {
                let landed = model.history.first(where: { $0.id == thread })?.conversation
                    .contains(where: { $0.role == "assistant" && !seedIDs.contains($0.id) }) ?? false
                if !sawLive && !landed && ticks < 75 { continue }
                break
            }
            sawLive = true
            if let answer = live.last(where: { $0.role == "assistant" && !seedIDs.contains($0.id) }),
               let question = answer.pendingQuestion, !askedQuestions.contains(question.id) {
                askedQuestions.insert(question.id)
                await askPendingQuestion(question)
            }
            if ticks % 20 == 0 {
                Task { [weak self] in await self?.sendTyping() }
            }
        }
        activeQuestion = nil

        let turn = model.history.first(where: { $0.id == thread })?.conversation
            .last(where: { $0.role == "assistant" && !seedIDs.contains($0.id) })
        let whole = turn?.text ?? ""
        let (withoutVisuals, charts) = TelegramBridge.renderVisuals(whole)
        let (shownText, photos) = TelegramBridge.localImages(withoutVisuals)
        let pictures = photos + charts
        let rawBody = shownText.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = rawBody.isEmpty ? "" : await PagesService.shared.rewriteWithAccessKeys(in: rawBody)

        defer {
            for chart in charts { try? FileManager.default.removeItem(at: chart) }
        }

        let wasStopped = stoppedThreads.remove(thread) != nil
        guard !body.isEmpty || !pictures.isEmpty else {
            if wasStopped { return }
            lastFailedThread = thread
            _ = await sendNoteToSelf(
                L(LicenseLock.isLocked ? "service.error.licenseRequired" : "signal.failed"),
                quoteTimestamp: replyTo
            )
            return
        }

        let head = turn.map(Self.captureHeader(of:)) ?? ""
        var tail = Self.sourcesText(turn?.sources ?? [])
        var hints: [String] = []
        if let turn {
            if turn.isError {
                lastFailedThread = thread
                hints.append("/retry")
            }
            if turn.interrupted {
                lastInterrupted = (thread: thread, turn: turn.id)
                hints.append("/continue")
            }
            if let mem = turn.captures.last(where: { $0.kind == .memory }) {
                lastUndoCapture = mem
                hints.append("/undo")
            }
        }
        if !hints.isEmpty {
            let line = hints.joined(separator: "  ·  ")
            tail = tail.isEmpty ? line : (tail + "\n\n" + line)
        }

        let parts = body.isEmpty ? [] : TelegramBridge.split(body)
        if parts.isEmpty {
            if let ts = await sendNoteToSelf(head, attachments: pictures.map(\.path), quoteTimestamp: replyTo) {
                remember(timestamp: ts, thread: thread)
            }
            return
        }

        for (index, part) in parts.enumerated() {
            var text = part
            if index == 0, !head.isEmpty { text = head + "\n\n" + text }
            if index == parts.count - 1, !tail.isEmpty { text += "\n\n" + tail }
            let atts = (index == parts.count - 1) ? pictures.map(\.path) : []
            if let ts = await sendNoteToSelf(text, attachments: atts,
                                             quoteTimestamp: index == 0 ? replyTo : nil) {
                remember(timestamp: ts, thread: thread)
            }
        }
    }

    private func askPendingQuestion(_ question: NotchModel.PendingUserQuestion) async {
        activeQuestion = (id: question.id, options: question.options)
        let lines = question.options.enumerated().map { "\($0.offset + 1). \($0.element)" }
        let msg = lines.isEmpty
            ? question.question
            : "\(question.question)\n\n" + lines.joined(separator: "\n")
        _ = await sendNoteToSelf(msg)
    }

    /// Mirrors a loop round or Mac-side continuation on a Signal thread back to Signal.
    func mirror(threadID: UUID, question: String, answer: String) {
        guard case .connected = state else { return }
        let (withoutVisuals, charts) = TelegramBridge.renderVisuals(answer)
        let (shownText, photos) = TelegramBridge.localImages(withoutVisuals)
        let pictures = photos + charts
        let body = shownText.trimmingCharacters(in: .whitespacesAndNewlines)
        let asked = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !body.isEmpty || !pictures.isEmpty else { return }
        currentThread = threadID

        let previous = chains["main"]
        chains["main"] = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { for chart in charts { try? FileManager.default.removeItem(at: chart) } }
            let rewritten = body.isEmpty ? "" : await PagesService.shared.rewriteWithAccessKeys(in: body)
            let parts = rewritten.isEmpty ? [] : TelegramBridge.split(rewritten)
            if parts.isEmpty {
                let prefix = asked.isEmpty ? "" : "› \(asked)"
                if let ts = await self.sendNoteToSelf(prefix, attachments: pictures.map(\.path)) {
                    self.remember(timestamp: ts, thread: threadID)
                }
                return
            }
            for (index, part) in parts.enumerated() {
                let text = (index == 0 && !asked.isEmpty) ? "› \(asked)\n\n\(part)" : part
                let atts = (index == parts.count - 1) ? pictures.map(\.path) : []
                if let ts = await self.sendNoteToSelf(text, attachments: atts) {
                    self.remember(timestamp: ts, thread: threadID)
                }
            }
        }
    }

    // MARK: - Reactions

    private func react(to text: String, previous: String, thread: UUID, targetTimestamp: Int64) {
        let account = NoNoAccount.shared
        guard ChatSwitch.emojiReactions, account.canDecide, targetTimestamp > 0 else { return }
        let message = String(text.prefix(1500))
        guard !message.isEmpty, !ClipPrivacy.containsSecret(message) else { return }
        let prior = ClipPrivacy.containsSecret(previous) ? "" : String(previous.suffix(1500))
        Task { [weak self] in
            guard let verdict = await account.react(to: message, previous: prior),
                  verdict.probability >= Self.reactionMinProbability,
                  let emoji = verdict.emoji,
                  let self, self.model?.liveThread(thread) != nil else { return }
            await self.sendReaction(emoji: emoji, targetTimestamp: targetTimestamp)
        }
    }

    // MARK: - Commands

    private static func command(in text: String) -> (String, String)? {
        guard text.hasPrefix("/") else { return nil }
        let end = text.firstIndex(where: { $0.isWhitespace || $0.isNewline }) ?? text.endIndex
        let cmd = String(text[text.index(after: text.startIndex)..<end]).lowercased()
        guard !cmd.isEmpty, cmd.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        let rest = String(text[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (cmd, rest)
    }

    private func handleCommand(_ cmd: String, rest: String, message: IncomingMessage) -> Bool {
        let input = rest.isEmpty ? (message.quoteText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : rest
        switch cmd {
        case "new", "reset", "clear":
            pendingMode = nil
            currentThread = nil
            Task { _ = await sendNoteToSelf(L("telegram.newThread"), quoteTimestamp: message.timestamp) }
            return true
        case "stop", "cancel":
            pendingMode = nil
            let thread = message.quoteTimestamp.flatMap { threadForTimestamp($0) } ?? defaultThread()
            if let thread, let model, model.stopTelegramRound(threadID: thread) {
                stoppedThreads.insert(thread)
                Task { _ = await sendNoteToSelf(L("telegram.stopped"), quoteTimestamp: message.timestamp) }
            } else {
                Task { _ = await sendNoteToSelf(L("telegram.nothingToStop"), quoteTimestamp: message.timestamp) }
            }
            return true
        case "model":
            Task { await handleModelCommand(rest, replyTo: message.timestamp) }
            return true
        case "note", "notes", "capture":
            if input.isEmpty {
                pendingMode = .note
                Task { _ = await sendNoteToSelf(L("note.placeholder"), quoteTimestamp: message.timestamp) }
            } else {
                Task { await runPendingMode(.note, text: input, replyTo: message.timestamp) }
            }
            return true
        case "remind", "reminder", "todo":
            if input.isEmpty {
                pendingMode = .remind
                Task { _ = await sendNoteToSelf(L("remind.placeholder"), quoteTimestamp: message.timestamp) }
            } else {
                Task { await runPendingMode(.remind, text: input, replyTo: message.timestamp) }
            }
            return true
        case "code", "agent", "task":
            if input.isEmpty {
                pendingMode = .code
                Task { _ = await sendNoteToSelf(L("agent.placeholder"), quoteTimestamp: message.timestamp) }
            } else {
                Task { await runPendingMode(.code, text: input, replyTo: message.timestamp) }
            }
            return true
        case "loop", "repeat", "every":
            if input.isEmpty {
                pendingMode = .loop
                Task { _ = await sendNoteToSelf(L("loop.placeholder"), quoteTimestamp: message.timestamp) }
            } else {
                Task { await runPendingMode(.loop, text: input, replyTo: message.timestamp) }
            }
            return true
        case "issue", "feedback", "bug":
            if input.isEmpty {
                pendingMode = .issue
                Task { _ = await sendNoteToSelf(L("issue.placeholder"), quoteTimestamp: message.timestamp) }
            } else {
                Task { await runPendingMode(.issue, text: input, replyTo: message.timestamp) }
            }
            return true
        case "actions", "action", "shortcuts", "shortcut":
            Task { await offerActions(input: input.isEmpty ? nil : input, replyTo: message.timestamp) }
            return true
        case "continue", "resume":
            guard let target = lastInterrupted, let model else { return true }
            lastInterrupted = nil
            Task {
                let seed = Set(model.history.first { $0.id == target.thread }?.conversation.map(\.id) ?? [])
                guard model.continueTelegramAnswer(threadID: target.thread, turnID: target.turn) != nil else { return }
                await sendTyping()
                await stream(thread: target.thread, seedIDs: seed, replyTo: message.timestamp)
            }
            return true
        case "retry":
            let thread = lastFailedThread ?? defaultThread()
            lastFailedThread = nil
            guard let thread, let model else { return true }
            Task {
                guard let (landed, seed) = model.retryTelegramRound(threadID: thread) else { return }
                currentThread = landed
                await sendTyping()
                await stream(thread: landed, seedIDs: seed, replyTo: message.timestamp)
            }
            return true
        case "undo":
            guard let capture = lastUndoCapture else { return true }
            lastUndoCapture = nil
            model?.undoTurnCapture(capture)
            Task { _ = await sendNoteToSelf(L("agent.process.undo"), quoteTimestamp: message.timestamp) }
            return true
        case "help":
            let help = """
            /new — \(L("telegram.command.new"))
            /stop — \(L("telegram.command.stop"))
            /model — \(L("telegram.command.model"))
            /note — \(L("telegram.command.note"))
            /remind — \(L("telegram.command.remind"))
            /code — \(L("telegram.command.code"))
            /loop — \(L("telegram.command.loop"))
            /actions — \(L("telegram.command.actions"))
            /issue — \(L("telegram.command.issue"))
            """
            Task { _ = await sendNoteToSelf(help, quoteTimestamp: message.timestamp) }
            return true
        default:
            return false
        }
    }

    private func runPendingMode(_ mode: Mode, text: String, replyTo: Int64) async {
        guard let model else { return }
        switch mode {
        case .note:
            Task { [weak self] in await self?.sendTyping() }
            let reply = await model.captureFromTelegram(text, reminder: false)
            if !reply.isEmpty { _ = await sendNoteToSelf(reply, quoteTimestamp: replyTo) }
        case .remind:
            Task { [weak self] in await self?.sendTyping() }
            let reply = await model.captureFromTelegram(text, reminder: true)
            if !reply.isEmpty { _ = await sendNoteToSelf(reply, quoteTimestamp: replyTo) }
        case .issue:
            Task { [weak self] in await self?.sendTyping() }
            let reply = await model.submitIssueFromTelegram(text)
            if !reply.isEmpty { _ = await sendNoteToSelf(reply, quoteTimestamp: replyTo) }
        case .loop:
            model.startTelegramLoop(prompt: text, minutes: 60)
            _ = await sendNoteToSelf(L("signal.loopStarted"), quoteTimestamp: replyTo)
        case .code:
            await startAgentFlow(task: text, replyTo: replyTo)
        case .actions:
            await offerActions(input: text, replyTo: replyTo)
        case .action(let id):
            guard let action = PromptShortcutStore.current.first(where: { $0.id == id }) else { return }
            let msg = IncomingMessage(timestamp: replyTo, text: text, attachments: [],
                                      quoteTimestamp: nil, quoteText: nil)
            dispatch([msg], action: action)
        case .pickAction(let ids, let savedInput):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let idx = Int(trimmed), ids.indices.contains(idx - 1),
                  let action = PromptShortcutStore.current.first(where: { $0.id == ids[idx - 1] }) else {
                _ = await sendNoteToSelf(L("telegram.actions.empty"), quoteTimestamp: replyTo)
                return
            }
            if let savedInput, !savedInput.isEmpty {
                let msg = IncomingMessage(timestamp: replyTo, text: savedInput, attachments: [],
                                          quoteTimestamp: nil, quoteText: nil)
                dispatch([msg], action: action)
            } else {
                pendingMode = .action(action.id)
                _ = await sendNoteToSelf(L("telegram.action.armed", action.displayName), quoteTimestamp: replyTo)
            }
        case .pickFolder(let task, let folders):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let idx = Int(trimmed), folders.indices.contains(idx - 1) else {
                _ = await sendNoteToSelf(L("telegram.agent.noFolder"), quoteTimestamp: replyTo)
                return
            }
            await startAgent(task: task, folder: folders[idx - 1], replyTo: replyTo)
        }
    }

    private func offerActions(input: String?, replyTo: Int64) async {
        let actions = PromptShortcutStore.current
        guard !actions.isEmpty else {
            _ = await sendNoteToSelf(L("telegram.actions.empty"), quoteTimestamp: replyTo)
            return
        }
        // Support `/actions 1 <text>` directly
        if let input, !input.isEmpty {
            let parts = input.split(maxSplits: 1, whereSeparator: { $0.isWhitespace || $0.isNewline })
            if let first = parts.first, let idx = Int(first), actions.indices.contains(idx - 1) {
                let action = actions[idx - 1]
                if parts.count == 2 {
                    let body = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let msg = IncomingMessage(timestamp: replyTo, text: body, attachments: [],
                                              quoteTimestamp: nil, quoteText: nil)
                    dispatch([msg], action: action)
                } else {
                    pendingMode = .action(action.id)
                    _ = await sendNoteToSelf(L("telegram.action.armed", action.displayName), quoteTimestamp: replyTo)
                }
                return
            }
        }
        pendingMode = .pickAction(ids: actions.map(\.id), input: input)
        let list = actions.enumerated().map { "\($0.offset + 1). \($0.element.displayName)" }.joined(separator: "\n")
        _ = await sendNoteToSelf("\(L("telegram.command.actions"))\n\n\(list)", quoteTimestamp: replyTo)
    }

    // MARK: - Agent (/code)

    private func startAgentFlow(task: String, replyTo: Int64) async {
        guard let model else { return }
        guard model.telegramAgentArming != nil else {
            _ = await sendNoteToSelf(L("telegram.agent.none"), quoteTimestamp: replyTo)
            return
        }
        if let folder = model.telegramArmedAgentFolder {
            await startAgent(task: task, folder: folder, replyTo: replyTo)
            return
        }
        let folders = model.telegramAgentFolders
        guard !folders.isEmpty else {
            _ = await sendNoteToSelf(L("telegram.agent.noFolder"), quoteTimestamp: replyTo)
            return
        }
        pendingMode = .pickFolder(task: task, folders: folders)
        let list = folders.enumerated().map { "\($0.offset + 1). \($0.element.lastPathComponent)" }.joined(separator: "\n")
        _ = await sendNoteToSelf("\(L("agent.folder.choose"))\n\n\(list)", quoteTimestamp: replyTo)
    }

    private func startAgent(task: String, folder: URL, replyTo: Int64) async {
        guard let arming = model?.telegramAgentArming else { return }
        AgentModelMRU.record(engine: arming.engine, model: arming.model)
        AgentFolderMRU.record(folder)
        guard let taskID = AgentTaskManager.shared.start(folder: folder, prompt: task, engine: arming.engine,
                                                         model: arming.model, effort: arming.effort) else {
            _ = await sendNoteToSelf(L("signal.failed"), quoteTimestamp: replyTo)
            return
        }
        let header = L("telegram.agent.working", arming.engine.displayName, folder.lastPathComponent)
        await followAgent(taskID: taskID, header: header, replyTo: replyTo)
    }

    private func continueAgent(taskID: UUID, prompt: String, replyTo: Int64) async {
        guard let task = AgentTaskManager.shared.tasks.first(where: { $0.id == taskID }) else { return }
        AgentTaskManager.shared.followUp(taskID: taskID, prompt: prompt)
        let header = L("telegram.agent.working", task.engine.displayName, task.folder.lastPathComponent)
        await followAgent(taskID: taskID, header: header, replyTo: replyTo)
    }

    private func followAgent(taskID: UUID, header: String, replyTo: Int64) async {
        if let ts = await sendNoteToSelf(header, quoteTimestamp: replyTo) {
            agentReports[ts] = taskID
        }
        var ticks = 0
        while true {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            ticks += 1
            guard let task = AgentTaskManager.shared.tasks.first(where: { $0.id == taskID }),
                  task.isRunning else { break }
            if ticks % 4 == 0 {
                Task { [weak self] in await self?.sendTyping() }
            }
        }
        let task = AgentTaskManager.shared.tasks.first(where: { $0.id == taskID })
        let report: String
        switch task?.outcome {
        case .cancelled?:
            return
        case .success?:
            report = task?.result ?? ""
        case .failure?:
            report = task?.failureReason ?? ""
        case nil:
            report = model?.history.first(where: { $0.id == taskID })?.conversation
                .last(where: { $0.role == "assistant" })?.text ?? ""
        }
        let (withoutVisuals, charts) = TelegramBridge.renderVisuals(report)
        let (text, photos) = TelegramBridge.localImages(withoutVisuals)
        let pictures = photos + charts
        defer { for chart in charts { try? FileManager.default.removeItem(at: chart) } }
        let rawBody = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = rawBody.isEmpty ? "" : await PagesService.shared.rewriteWithAccessKeys(in: rawBody)
        guard !body.isEmpty || !pictures.isEmpty else {
            _ = await sendNoteToSelf(L("signal.failed"), quoteTimestamp: replyTo)
            return
        }
        let parts = body.isEmpty ? [] : TelegramBridge.split(body)
        if parts.isEmpty {
            if let ts = await sendNoteToSelf("", attachments: pictures.map(\.path), quoteTimestamp: replyTo) {
                agentReports[ts] = taskID
            }
            return
        }
        for (index, part) in parts.enumerated() {
            let atts = (index == parts.count - 1) ? pictures.map(\.path) : []
            if let ts = await sendNoteToSelf(part, attachments: atts, quoteTimestamp: index == 0 ? replyTo : nil) {
                agentReports[ts] = taskID
            }
        }
    }

    private func handleModelCommand(_ query: String, replyTo: Int64) async {
        let currentProvider = APIKeyStore.selectedProvider
        let currentModel = APIKeyStore.effectiveModel(for: currentProvider) ?? currentProvider.defaultModel
        var rows: [AskModelMRU.Entry] = []
        if ModelCatalogStore.ready(currentProvider), !currentModel.isEmpty {
            rows.append(.init(provider: currentProvider, model: currentModel))
        }
        for entry in AskModelMRU.entries where ModelCatalogStore.ready(entry.provider) {
            if !rows.contains(entry) { rows.append(entry) }
        }
        rows = Array(rows.prefix(AskModelMRU.capacity))
        guard let first = rows.first else {
            _ = await sendNoteToSelf(L("menuBar.noModel"), quoteTimestamp: replyTo)
            return
        }
        func label(_ entry: AskModelMRU.Entry) -> String {
            "\(ModelRatings.prettyName(for: entry.model, provider: entry.provider)) (\(entry.provider.displayName))"
        }
        if query.isEmpty {
            let list = rows.enumerated().map { idx, r in
                "\(idx + 1). \(label(r))"
            }.joined(separator: "\n")
            let header = String(format: L("telegram.model.current"), label(first))
            _ = await sendNoteToSelf("\(header)\n\(list)", quoteTimestamp: replyTo)
            return
        }
        let lower = query.lowercased()
        if let idx = Int(lower), rows.indices.contains(idx - 1) {
            let picked = rows[idx - 1]
            ModelCatalogStore.select(provider: picked.provider, model: picked.model)
            _ = await sendNoteToSelf(String(format: L("telegram.model.current"), label(picked)), quoteTimestamp: replyTo)
        } else if let match = rows.first(where: {
            label($0).lowercased().contains(lower) || $0.model.lowercased().contains(lower)
        }) {
            ModelCatalogStore.select(provider: match.provider, model: match.model)
            _ = await sendNoteToSelf(String(format: L("telegram.model.current"), label(match)), quoteTimestamp: replyTo)
        } else {
            let header = String(format: L("telegram.model.current"), label(first))
            _ = await sendNoteToSelf(header, quoteTimestamp: replyTo)
        }
    }

    // MARK: - Threads & Formatting

    /// The thread a Signal message lands in when not replying to a specific
    /// earlier message: follows Notchi's unified main thread when enabled,
    /// falling back to Signal's own current thread.
    private func defaultThread() -> UUID? {
        if let model, model.unifiedThreadsEnabled,
           let mainID = model.history.first(where: { $0.mainThread && $0.source == .ask })?.id {
            return mainID
        }
        return currentThread
    }

    private var currentThread: UUID? {
        get { UserDefaults.standard.string(forKey: Self.threadKey).flatMap(UUID.init(uuidString:)) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.uuidString, forKey: Self.threadKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.threadKey)
            }
        }
    }

    private func threadForTimestamp(_ ts: Int64) -> UUID? {
        let list = UserDefaults.standard.array(forKey: Self.messagesKey) as? [[String]] ?? []
        let key = String(ts)
        return list.last(where: { $0.first == key }).flatMap { $0.count == 2 ? UUID(uuidString: $0[1]) : nil }
    }

    private func remember(timestamp ts: Int64, thread: UUID) {
        var list = UserDefaults.standard.array(forKey: Self.messagesKey) as? [[String]] ?? []
        list.append([String(ts), thread.uuidString])
        UserDefaults.standard.set(Array(list.suffix(Self.messagesCap)), forKey: Self.messagesKey)
    }

    private static func captureHeader(of turn: NotchModel.Turn) -> String {
        var seen = Set<String>()
        let labels = turn.captures.map(TelegramBridge.captureLabel).filter { seen.insert($0).inserted }
        return labels.joined(separator: "\n")
    }

    private static func sourcesText(_ sources: [WebSource]) -> String {
        guard !sources.isEmpty else { return "" }
        let lines = sources.prefix(5).map { item -> String in
            let title = item.title.isEmpty ? item.url : item.title
            return "• \(title) — \(item.url)"
        }
        return L("telegram.sources") + "\n" + lines.joined(separator: "\n")
    }

    // MARK: - Attachments

    private static func attachmentURL(id: String) -> URL? {
        let fm = FileManager.default
        let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
            ?? "\(NSHomeDirectory())/.local/share"
        let candidates = [
            URL(fileURLWithPath: "\(xdg)/signal-cli/attachments/\(id)"),
            URL(fileURLWithPath: "\(NSHomeDirectory())/.local/share/signal-cli/attachments/\(id)"),
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    private static func readTextAttachment(_ url: URL, filename: String?) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 0, size <= 64 * 1024 else { return nil }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let name = filename ?? url.lastPathComponent
        return "[\(name)]\n\(text)"
    }

    // MARK: - Power Assertion

    private final class Awake {
        private var assertion: IOPMAssertionID = 0
        private let activity: NSObjectProtocol

        init() {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Notchi Signal channel listening" as CFString,
                &assertion
            )
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Notchi Signal channel listening"
            )
        }

        deinit {
            if assertion != 0 { IOPMAssertionRelease(assertion) }
            ProcessInfo.processInfo.endActivity(activity)
        }
    }
}
