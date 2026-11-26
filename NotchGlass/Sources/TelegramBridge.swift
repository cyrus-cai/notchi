import AppKit
import SwiftUI
import AVFoundation
import Foundation
import IOKit.pwr_mgt
import Speech
import UniformTypeIdentifiers

/// Notchi as the user's own Telegram bot: messages to the bot are answered
/// here, on the Mac, with the same model and tools as the panel, and land in
/// Recent.
///
/// Each user makes their own bot with @BotFather and pastes its token here.
/// The app long-polls the Bot API directly (`getUpdates`), so nothing passes
/// through Notchi's servers and one user's bot never shares a rate limit or a
/// ban with another's.
///
/// A locked screen or a sleeping display does not stop the bot. While it
/// polls, the Mac does not go to sleep on its own when on power, and the app
/// is kept out of App Nap; while it answers, it does not sleep on battery
/// either. A closed lid puts the Mac to sleep unless an external display is
/// attached, or "Answer with the lid closed" is on (`LidSleep`). While the Mac
/// sleeps nobody polls; Telegram keeps the messages for 24 hours and they are
/// answered on wake.
///
/// The bot answers one chat: the first private chat that taps Start within
/// `pairingWindow` of the token being entered. Everyone else is ignored.
///
/// A chat continues one thread. Replying to one of the bot's
/// messages continues the thread that message belongs to.
///
/// Anything a message carries goes to the model: photos, stills from videos,
/// voice and audio transcribed on this Mac, the text of documents, and a line
/// saying what a location, contact or poll is. An album is answered once.
@MainActor
final class TelegramBridge: ObservableObject {
    static let shared = TelegramBridge()

    enum State: Equatable {
        case off
        /// Checking a token with `getMe`.
        case checking
        case invalidToken
        /// Token works; waiting for the owner to tap Start in Telegram.
        case pairing(bot: String)
        case connected(bot: String, owner: String)
        /// Disconnected by the user. Token and owner are kept, so Reconnect is
        /// one click; nothing is polled meanwhile.
        case paused(bot: String, owner: String)
    }

    @Published private(set) var state: State = .off
    /// True while Settings shows the setup steps. The panel then does not fold
    /// when the pointer leaves it (`NotchModel`'s leave watch); Esc still closes.
    var holdsPanel = false

    weak var model: NotchModel?

    private var pollTask: Task<Void, Never>? {
        didSet {
            pollAwake = pollTask == nil ? nil : Awake(.polling)
            applyLidSleep()
        }
    }
    /// Held while polling, released when polling stops.
    private var pollAwake: Awake?
    private var pairingUntil: Date?
    /// Messages run one after another per lane: a chat's own lane, plus one
    /// lane per older thread the user replies to, so a reply to another thread
    /// does not wait for this one (`lane(for:chatID:)`).
    private var chains: [String: Task<Void, Never>] = [:]
    /// Text messages handed to a running round (`NotchModel.steer`), by thread
    /// and message id, kept until the round ends to answer the ones it did
    /// not read.
    private var steered: [UUID: [Int: [[String: Any]]]] = [:]
    /// Option buttons sent for a pending question, by the question's id.
    private var questionOptions: [UUID: [String]] = [:]
    /// The model rows each /model message offers, by the id in its buttons.
    private var modelOptions: [UUID: [AskModelMRU.Entry]] = [:]
    /// A bare `/note`, `/remind`, `/code`, `/loop`, `/issue`, or a text action
    /// picked with nothing to run on: the chat's next message goes there, as a
    /// mode picked in the `/` menu holds the next line in the notch.
    private var pendingModes: [Int64: Mode] = [:]
    /// What the buttons under a command's reply or an answer do, by the id in
    /// their callback data.
    private var choices: [UUID: Choice] = [:]
    /// Agent tasks started from the chat, by "chat:message" of the messages
    /// reporting them. A reply to one continues that task.
    private var agentReports: [String: UUID] = [:]
    /// Messages collect here per chat until no new one has come for a short
    /// wait, then go out as one round: people split one request over several
    /// messages. An album arrives as one message per item, sharing a
    /// `media_group_id`, and Telegram splits more than 10 items into several
    /// albums, so a batch holding album items waits `albumWait` instead.
    private var albums: [Int64: [[String: Any]]] = [:]
    private var albumFlush: [Int64: Task<Void, Never>] = [:]
    private static let albumWait: UInt64 = 3_000_000_000
    private static let burstWait: UInt64 = 1_500_000_000

    private static let tokenKey = "aux_key.telegram"
    private static let botKey = "TelegramBotUsername"
    private static let ownerKey = "TelegramOwnerChatID"
    private static let ownerNameKey = "TelegramOwnerName"
    private static let offsetKey = "TelegramUpdateOffset"
    private static let pausedKey = "TelegramPaused"
    private static let threadsKey = "TelegramThreadByChat"
    private static let messagesKey = "TelegramThreadByMessage"
    private static let messagesCap = 500
    private static let pairingWindow: TimeInterval = 10 * 60
    /// Telegram's limit is 4096; the rest leaves room for HTML tags.
    private static let messageLimit = 3800

    /// "Answer with the lid closed": while polling, the Mac does not sleep
    /// when the lid closes (`pmset disablesleep`). On unless it was set before.
    /// A bot paired before this default keeps the off it was showing, so no
    /// password dialog comes up for it.
    @Published private(set) var answersWithLidClosed =
        UserDefaults.standard.object(forKey: TelegramBridge.lidKey) as? Bool
            ?? (UserDefaults.standard.object(forKey: TelegramBridge.ownerKey) == nil)
    @Published private(set) var lidBusy = false
    private static let lidKey = "TelegramAnswerWithLidClosed"

    private var token: String { UserDefaults.standard.string(forKey: Self.tokenKey) ?? "" }
    /// The bot's chat in Telegram, nil before a bot is set up.
    var botChatURL: URL? {
        UserDefaults.standard.string(forKey: Self.botKey).flatMap { URL(string: "https://t.me/\($0)") }
    }
    private var owner: Int64? {
        let id = UserDefaults.standard.object(forKey: Self.ownerKey) as? NSNumber
        return id?.int64Value
    }

    /// The shape of a BotFather token: the bot's numeric id, a colon, 35 characters.
    static func looksLikeToken(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^\d{6,12}:[A-Za-z0-9_-]{30,}$"#, options: .regularExpression) != nil
    }

    // MARK: - Lifecycle

    /// At launch: resume polling when a bot is set up.
    func start() {
        // A crash or a forced quit can leave lid sleep off with nobody polling.
        applyLidSleep()
        guard !token.isEmpty else { return }
        let bot = UserDefaults.standard.string(forKey: Self.botKey) ?? ""
        let ownerName = UserDefaults.standard.string(forKey: Self.ownerNameKey) ?? ""
        if owner != nil, UserDefaults.standard.bool(forKey: Self.pausedKey) {
            state = .paused(bot: bot, owner: ownerName)
            return
        }
        if let owner {
            state = .connected(bot: bot, owner: ownerName)
            syncPagesIdentity(owner: owner)
        } else {
            state = .pairing(bot: bot)
        }
        poll()
    }

    /// Saves the token, checks it, sets the bot's commands, and opens the bot
    /// in Telegram so the user only has to tap Start.
    func connect(token raw: String) async {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeToken(token) else { state = .invalidToken; return }
        stopPolling()
        state = .checking
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        let me = await call("getMe", [:])
        guard me["ok"] as? Bool == true,
              let bot = (me["result"] as? [String: Any])?["username"] as? String else {
            UserDefaults.standard.removeObject(forKey: Self.tokenKey)
            state = .invalidToken
            return
        }
        UserDefaults.standard.set(bot, forKey: Self.botKey)
        UserDefaults.standard.removeObject(forKey: Self.ownerKey)
        UserDefaults.standard.removeObject(forKey: Self.offsetKey)
        UserDefaults.standard.removeObject(forKey: Self.pausedKey)
        // getUpdates and a webhook cannot both be on.
        await call("deleteWebhook", [:])
        await registerCommands()
        await call("setMyShortDescription", ["short_description": L("telegram.description")])
        openPairing()
        poll()
    }

    /// Opens the bot in Telegram and accepts the next Start as the owner.
    func openPairing() {
        guard owner == nil, let bot = UserDefaults.standard.string(forKey: Self.botKey), !bot.isEmpty else { return }
        state = .pairing(bot: bot)
        pairingUntil = Date().addingTimeInterval(Self.pairingWindow)
        if let url = URL(string: "https://t.me/\(bot)?start=notchi") { NSWorkspace.shared.open(url) }
    }

    /// Stops answering, keeping the bot and its owner for `reconnect`.
    func disconnect() {
        stopPolling()
        pairingUntil = nil
        guard owner != nil else { forget(); return }
        UserDefaults.standard.set(true, forKey: Self.pausedKey)
        state = .paused(bot: UserDefaults.standard.string(forKey: Self.botKey) ?? "",
                        owner: UserDefaults.standard.string(forKey: Self.ownerNameKey) ?? "")
    }

    /// Resumes a paused bot. Messages sent while it was paused are dropped,
    /// not answered all at once.
    func reconnect() async {
        guard case .paused(let bot, let ownerName) = state else { return }
        UserDefaults.standard.removeObject(forKey: Self.pausedKey)
        state = .connected(bot: bot, owner: ownerName)
        if let owner { syncPagesIdentity(owner: owner) }
        await call("deleteWebhook", ["drop_pending_updates": true])
        UserDefaults.standard.removeObject(forKey: Self.offsetKey)
        poll()
    }

    /// Forgets the bot entirely; setup starts again from step one.
    func forget() {
        stopPolling()
        for key in [Self.tokenKey, Self.botKey, Self.ownerKey, Self.ownerNameKey, Self.offsetKey,
                    Self.pausedKey, Self.threadsKey, Self.messagesKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        pairingUntil = nil
        state = .off
        Task { await PagesService.shared.clearTelegram() }
    }

    private var botID: String? {
        let parts = token.split(separator: ":", maxSplits: 1)
        guard let first = parts.first, !first.isEmpty, first.allSatisfy(\.isNumber) else { return nil }
        return String(first)
    }

    private func syncPagesIdentity(owner: Int64) {
        guard let botID else { return }
        Task { await PagesService.shared.syncTelegram(botID: botID, userID: owner) }
    }

    private func pageWebAppButtons(in text: String) async -> [[[String: Any]]] {
        let items = Array(PagesService.pageURLs(in: text).prefix(3))
        guard !items.isEmpty else { return [] }
        if let botID, let owner {
            await PagesService.shared.ensureTelegramSynced(botID: botID, userID: owner)
        }
        var rows: [[[String: Any]]] = []
        for item in items {
            let title = PagesService.cachedTitle(forSlug: item.slug) ?? item.slug
            let url = (try? await PagesService.shared.accessURL(slug: item.slug)) ?? item.url
            rows.append([[
                "text": "↗ \(title)",
                "web_app": ["url": url.absoluteString],
            ]])
        }
        return rows
    }

    // MARK: - Lid

    private var anyChannelActive: Bool { pollTask != nil || SignalBridge.shared.isListening }

    /// With a paired channel (Telegram or Signal), turning it on installs the
    /// sudo rule `LidSleep` runs under and turns lid sleep off; turning it off
    /// does the reverse. Each asks for an administrator password once. With
    /// nothing to change on the system yet, only the choice is saved, and
    /// pairing installs the rule.
    func setAnswersWithLidClosed(_ on: Bool) async {
        guard !lidBusy, on != answersWithLidClosed else { return }
        if !LidSleep.ruleInstalled, !on || (owner == nil && !SignalBridge.shared.isPaired) {
            answersWithLidClosed = on
            UserDefaults.standard.set(on, forKey: Self.lidKey)
            return
        }
        lidBusy = true
        defer { lidBusy = false }
        let done = on ? await LidSleep.install(disableNow: anyChannelActive)
                      : await LidSleep.uninstall()
        guard done else { return }
        answersWithLidClosed = on
        UserDefaults.standard.set(on, forKey: Self.lidKey)
        LidSleep.applied = on && anyChannelActive
    }

    /// First pairing with the setting on. Declining the password dialog turns
    /// the setting off.
    func installLidRuleAfterPairing() async {
        guard answersWithLidClosed, !LidSleep.ruleInstalled, !lidBusy else { return }
        lidBusy = true
        defer { lidBusy = false }
        let done = await LidSleep.install(disableNow: anyChannelActive)
        answersWithLidClosed = done
        UserDefaults.standard.set(done, forKey: Self.lidKey)
        LidSleep.applied = done && anyChannelActive
    }

    /// Lid sleep is off exactly while the setting is on, its sudo rule is in
    /// place and any channel (Telegram or Signal) is actively listening.
    func applyLidSleep() {
        let want = answersWithLidClosed && anyChannelActive && LidSleep.ruleInstalled
        guard want != LidSleep.applied else { return }
        LidSleep.applied = want
        Task.detached { LidSleep.set(disabled: want) }
    }

    /// At quit: lid sleep goes back on, so a closed Mac in a bag still sleeps.
    func restoreLidSleep() {
        guard LidSleep.applied else { return }
        LidSleep.applied = false
        LidSleep.set(disabled: false)
    }

    // MARK: - Polling

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// The command menu next to the message field. Sent on every start so a
    /// bot paired by an older version also gets new commands.
    private func registerCommands() async {
        let commands = ["note", "remind", "code", "loop", "actions", "model", "stop", "issue"]
        await call("setMyCommands", ["commands": commands.map {
            ["command": $0, "description": L("telegram.command." + $0)]
        }])
    }

    private func poll() {
        guard pollTask == nil, !token.isEmpty else { return }
        pollTask = Task { [weak self] in
            await self?.registerCommands()
            var backoff: UInt64 = 1
            while !Task.isCancelled {
                guard let self else { return }
                let offset = UserDefaults.standard.integer(forKey: Self.offsetKey)
                let result = await self.call("getUpdates", ["offset": offset, "timeout": 50,
                                                            "allowed_updates": ["message", "callback_query"]],
                                             timeout: 65)
                if Task.isCancelled { return }
                if result["error_code"] as? Int == 401 {
                    self.state = .invalidToken
                    self.pollTask = nil
                    return
                }
                if result["error_code"] as? Int == 409 { await self.call("deleteWebhook", [:]) }
                guard result["ok"] as? Bool == true, let updates = result["result"] as? [[String: Any]] else {
                    try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                    backoff = min(backoff * 2, 60)
                    continue
                }
                backoff = 1
                for update in updates {
                    if let id = update["update_id"] as? Int {
                        UserDefaults.standard.set(id + 1, forKey: Self.offsetKey)
                    }
                    self.route(update)
                }
            }
        }
    }

    /// One Bot API call. Returns Telegram's response body; a 429 waits the
    /// `retry_after` Telegram names and tries once more.
    @discardableResult
    private func call(_ method: String, _ params: [String: Any], timeout: TimeInterval = 20) async -> [String: Any] {
        for attempt in 0..<2 {
            guard !token.isEmpty,
                  let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)"),
                  let body = try? JSONSerialization.data(withJSONObject: params) else { return ["ok": false] }
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            guard let (data, _) = try? await ProxyConfig.urlSession.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["ok": false] }
            if json["error_code"] as? Int == 429, attempt == 0,
               let wait = (json["parameters"] as? [String: Any])?["retry_after"] as? Int {
                try? await Task.sleep(nanoseconds: UInt64(min(wait, 30)) * 1_000_000_000)
                continue
            }
            return json
        }
        return ["ok": false]
    }

    /// Uploads one image file as a photo (multipart: `sendPhoto` takes a file
    /// only as form data).
    private func sendPhoto(_ file: URL, chatID: Int64, replyTo: Int? = nil,
                           silent: Bool = false) async -> [String: Any] {
        guard !token.isEmpty,
              let url = URL(string: "https://api.telegram.org/bot\(token)/sendPhoto"),
              let data = try? Data(contentsOf: file) else { return ["ok": false] }
        let boundary = "notchi-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("chat_id", String(chatID))
        if let replyTo { field("reply_to_message_id", String(replyTo)) }
        if silent { field("disable_notification", "true") }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (reply, _) = try? await ProxyConfig.urlSession.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return ["ok": false] }
        return json
    }

    /// `pmset -a disablesleep`, the only switch that keeps a Mac awake with
    /// the lid closed and no external display. It needs root, so turning the
    /// setting on installs one sudoers rule allowing exactly the two pmset
    /// commands without a password; after that it runs silently.
    private enum LidSleep {
        static let rulePath = "/etc/sudoers.d/notchi-lid"
        private static let appliedKey = "TelegramLidSleepDisabled"

        static var ruleInstalled: Bool { FileManager.default.fileExists(atPath: rulePath) }

        /// Whether this app turned lid sleep off and has not turned it back on.
        static var applied: Bool {
            get { UserDefaults.standard.bool(forKey: appliedKey) }
            set { UserDefaults.standard.set(newValue, forKey: appliedKey) }
        }

        @discardableResult
        static func set(disabled: Bool) -> Bool {
            run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]) == 0
        }

        static func install(disableNow: Bool) async -> Bool {
            let user = NSUserName()
            guard user.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return false }
            let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
            let tmp = "/tmp/notchi-lid.sudoers"
            var steps = [
                "/bin/echo '\(rule)' > \(tmp)",
                "/usr/sbin/visudo -cf \(tmp)",
                "/usr/sbin/chown root:wheel \(tmp)",
                "/bin/chmod 0440 \(tmp)",
                "/bin/mv -f \(tmp) \(rulePath)",
            ]
            if disableNow { steps.append("/usr/bin/pmset -a disablesleep 1") }
            return await admin(steps.joined(separator: " && "))
        }

        static func uninstall() async -> Bool {
            await admin("/usr/bin/pmset -a disablesleep 0 && /bin/rm -f \(rulePath)")
        }

        /// The system's administrator password dialog.
        private static func admin(_ command: String) async -> Bool {
            let script = "do shell script \"\(command)\" with administrator privileges"
            return await Task.detached { run("/usr/bin/osascript", ["-e", script]) == 0 }.value
        }

        private static func run(_ path: String, _ arguments: [String]) -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return -1 }
            process.waitUntilExit()
            return process.terminationStatus
        }
    }

    /// Keeps the Mac awake for as long as the value lives.
    private final class Awake {
        enum Purpose {
            /// No idle sleep on power (the system ignores this assertion on
            /// battery), and no App Nap, so the long poll keeps running.
            case polling
            /// No idle sleep on power or battery while a reply is being made.
            case answering
        }

        private var assertion = IOPMAssertionID(0)
        private let activity: NSObjectProtocol

        init(_ purpose: Purpose) {
            let type = purpose == .polling ? kIOPMAssertionTypePreventSystemSleep
                                           : kIOPMAssertionTypePreventUserIdleSystemSleep
            let reason = purpose == .polling ? "Notchi is waiting for Telegram messages"
                                             : "Notchi is answering a Telegram message"
            IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        reason as CFString, &assertion)
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: reason)
        }

        deinit {
            if assertion != 0 { IOPMAssertionRelease(assertion) }
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    // MARK: - Updates

    private func route(_ update: [String: Any]) {
        if let callback = update["callback_query"] as? [String: Any] {
            let from = ((callback["from"] as? [String: Any])?["id"] as? NSNumber)?.int64Value
            guard let owner, from == owner else { return }
            Task { await answerCallback(callback) }
            return
        }
        guard let message = update["message"] as? [String: Any],
              let chat = message["chat"] as? [String: Any],
              chat["type"] as? String == "private",
              let chatID = (chat["id"] as? NSNumber)?.int64Value else { return }
        if owner == nil {
            // Pairing: the first Start inside the window becomes the owner.
            guard let until = pairingUntil, until > Date(),
                  (message["text"] as? String)?.hasPrefix("/start") == true else { return }
            let name = (chat["username"] as? String).map { "@" + $0 } ?? chat["first_name"] as? String ?? ""
            UserDefaults.standard.set(NSNumber(value: chatID), forKey: Self.ownerKey)
            UserDefaults.standard.set(name, forKey: Self.ownerNameKey)
            pairingUntil = nil
            state = .connected(bot: UserDefaults.standard.string(forKey: Self.botKey) ?? "", owner: name)
            syncPagesIdentity(owner: chatID)
            Task { await installLidRuleAfterPairing() }
        }
        guard chatID == owner else { return }
        let text = message["text"] as? String
        // Not queued: the lane it would wait in is the round it stops.
        if let text, text == "/stop" || text.hasPrefix("/stop@") {
            Task { await stop(chatID: chatID) }
            flushAlbum(chatID: chatID)
            return
        }
        // Not queued either: a switch made during an answer applies to the next one.
        if let text, text == "/model" || text.hasPrefix("/model@") || text.hasPrefix("/model ") {
            Task { await offerModels(chatID: chatID) }
            flushAlbum(chatID: chatID)
            return
        }
        // The `/` menu's modes, text actions and `@issue`.
        if let text, let (command, argument) = Self.command(in: text), Mode(command: command) != nil {
            flushAlbum(chatID: chatID)
            let messageID = (message["message_id"] as? NSNumber)?.intValue ?? 0
            let quote = Self.quotedText(of: message)
            Task { await runCommand(command, argument: argument, quote: quote,
                                    chatID: chatID, messageID: messageID) }
            return
        }
        let isCommand = text?.hasPrefix("/") == true
        // Trial ended: no round can run, so say so now instead of waiting out
        // the burst window and a round that fails.
        if LicenseLock.isLocked, !isCommand {
            let messageID = (message["message_id"] as? NSNumber)?.intValue ?? 0
            Task { [weak self] in
                await self?.call("sendMessage", ["chat_id": chatID,
                                                 "text": L("service.error.licenseRequired"),
                                                 "reply_to_message_id": messageID])
            }
            return
        }
        if isCommand { flushAlbum(chatID: chatID) }
        if !isCommand {
            albums[chatID, default: []].append(message)
            let wait = albums[chatID]?.contains { $0["media_group_id"] != nil } == true
                ? Self.albumWait : Self.burstWait
            albumFlush[chatID]?.cancel()
            albumFlush[chatID] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: wait)
                guard !Task.isCancelled else { return }
                self?.flushAlbum(chatID: chatID)
            }
            return
        }
        enqueue([message], chatID: chatID)
    }

    private func flushAlbum(chatID: Int64) {
        albumFlush.removeValue(forKey: chatID)?.cancel()
        guard let items = albums.removeValue(forKey: chatID) else { return }
        enqueue(items, chatID: chatID)
    }

    private func enqueue(_ messages: [[String: Any]], chatID: Int64) {
        let firstText = messages.first?["text"] as? String
        if firstText?.hasPrefix("/") == true {
            pendingModes.removeValue(forKey: chatID)
        } else if let mode = pendingModes.removeValue(forKey: chatID) {
            let lane = "\(chatID)"
            let previous = chains[lane]
            chains[lane] = Task { [weak self] in
                await previous?.value
                await self?.runMode(mode, messages: messages, chatID: chatID)
            }
            return
        }
        // A reply to an agent report continues that task.
        if let replied = (messages.first?["reply_to_message"] as? [String: Any])?["message_id"] as? NSNumber,
           let taskID = agentReports["\(chatID):\(replied.intValue)"],
           AgentTaskManager.shared.tasks.contains(where: { $0.id == taskID }) {
            let text = messages
                .compactMap { (($0["text"] ?? $0["caption"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if !text.isEmpty {
                let messageID = (messages.first?["message_id"] as? NSNumber)?.intValue ?? 0
                Task { await continueAgent(taskID: taskID, prompt: text, chatID: chatID, replyTo: messageID) }
                return
            }
        }
        if steer(messages, chatID: chatID) { return }
        let lane = lane(for: messages, chatID: chatID)
        let previous = chains[lane]
        chains[lane] = Task { [weak self] in
            await previous?.value
            await self?.answer(messages, chatID: chatID)
        }
    }

    /// A reply to a message of another thread runs in that thread's lane;
    /// everything else waits in the chat's own lane.
    private func lane(for messages: [[String: Any]], chatID: Int64) -> String {
        if let replied = (messages.first?["reply_to_message"] as? [String: Any])?["message_id"] as? NSNumber,
           let mapped = threadForMessage(chatID: chatID, messageID: replied.intValue),
           mapped != thread(for: chatID) {
            return "\(chatID):\(mapped.uuidString)"
        }
        return "\(chatID)"
    }

    /// Text sent while its thread is answering goes to that round, which reads
    /// it after its next tool call. Messages with files, a quote, or a reply to
    /// anything but one of the bot's messages wait for the next round instead.
    private func steer(_ messages: [[String: Any]], chatID: Int64) -> Bool {
        guard let model, let first = messages.first,
              messages.allSatisfy({ ($0["text"] as? String).map { !$0.hasPrefix("/") } ?? false }),
              first["quote"] == nil, first["external_reply"] == nil else { return false }
        var target = thread(for: chatID)
        if let replied = first["reply_to_message"] as? [String: Any] {
            guard let id = (replied["message_id"] as? NSNumber)?.intValue,
                  let mapped = threadForMessage(chatID: chatID, messageID: id) else { return false }
            target = mapped
        }
        let text = messages
            .compactMap { ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard let target, !text.isEmpty,
              let tag = (messages.last?["message_id"] as? NSNumber)?.intValue,
              model.steer(threadID: target, text: text, tag: tag) else { return false }
        steered[target, default: [:]][tag] = messages
        SignalBridge.shared.mirrorTelegramMessage(threadID: target, text: text, images: [])
        for message in messages {
            guard let id = (message["message_id"] as? NSNumber)?.intValue else { continue }
            Task { [weak self] in
                await self?.call("setMessageReaction", [
                    "chat_id": chatID, "message_id": id,
                    "reaction": [["type": "emoji", "emoji": "👀"]],
                ])
            }
        }
        return true
    }

    /// Threads stopped with /stop, so an empty answer does not also report
    /// a failure.
    private var stoppedThreads: Set<UUID> = []

    private func stop(chatID: Int64) async {
        let id = thread(for: chatID)
        var stopped = id.map { model?.stopTelegramRound(threadID: $0) ?? false } ?? false
        if stopped, let id { stoppedThreads.insert(id) }
        // Else the newest agent task started from this chat.
        if !stopped {
            let started = Set(agentReports.filter { $0.key.hasPrefix("\(chatID):") }.values)
            if let task = AgentTaskManager.shared.tasks.last(where: { started.contains($0.id) && $0.isRunning }) {
                stopped = AgentTaskManager.shared.cancel(taskID: task.id)
            }
        }
        await call("sendMessage", ["chat_id": chatID,
                                   "text": L(stopped ? "telegram.stopped" : "telegram.nothingToStop")])
    }

    /// `messages` is one message, or the items of one album in order. With a
    /// text action, what they carry is the text the action runs on, in a
    /// thread of its own, as in the notch.
    private func answer(_ messages: [[String: Any]], chatID: Int64,
                        action: PromptShortcut? = nil) async {
        guard let model, let message = messages.first else { return }
        let awake = Awake(.answering)
        defer { withExtendedLifetime(awake) {} }
        // Each split album, and a text sent after them, can carry its own words.
        let text = messages
            .compactMap { (($0["text"] ?? $0["caption"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let messageID = (message["message_id"] as? NSNumber)?.intValue ?? 0

        if text.hasPrefix("/start") {
            await call("sendMessage", ["chat_id": chatID, "text": L("telegram.paired")])
            return
        }

        var found = Attachments()
        var skipped = 0
        for item in messages {
            let room = NotchModel.composeImageLimit - found.images.count
            let more = await attachments(of: item, chatID: chatID, room: room)
            found.images += more.images
            found.files += more.files
            skipped += more.skippedImages
        }
        let limit = NotchModel.composeImageLimit
        skipped += max(0, found.images.count - limit)
        let images = Array(found.images.prefix(limit))
        if skipped > 0 {
            found.files.append(NotchModel.DroppedFile(
                name: "Images",
                text: "\(images.count + skipped) images were sent. Only the first \(limit) are attached; "
                    + "the other \(skipped) were left out. Tell the user and ask them to send those separately."))
        }
        guard !text.isEmpty || !images.isEmpty || !found.files.isEmpty else {
            await call("sendMessage", ["chat_id": chatID, "text": L("telegram.unsupported"),
                                       "reply_to_message_id": messageID])
            return
        }
        // All files of one message share the panel's text budget for drops.
        var left = NotchModel.droppedFileTextLimit
        let files = found.files.map { file -> NotchModel.DroppedFile in
            defer { left = max(0, left - file.text.count) }
            guard file.text.count > left else { return file }
            return .init(name: file.name, text: String(file.text.prefix(left)) + "\n[… the rest of this file was cut]")
        }
        var question = files.isEmpty ? text : NotchModel.fileEnvelope(line: text, files: files)
        // A reply or a quote carries the quoted text, as a reply does in the notch.
        if let quoted = Self.quotedText(of: message) {
            question = NotchModel.replyEnvelope(line: question, quote: quoted)
        }
        if let action {
            question = Self.actionQuestion(action, input: question)
        }

        // A reply to one of the bot's messages continues that message's thread.
        var threadID = thread(for: chatID)
        if let replied = (message["reply_to_message"] as? [String: Any])?["message_id"] as? NSNumber,
           let mapped = threadForMessage(chatID: chatID, messageID: replied.intValue) {
            threadID = mapped
        }
        // A thread deleted from Recent starts over.
        if let id = threadID, !model.history.contains(where: { $0.id == id }) { threadID = nil }
        if action != nil { threadID = nil }
        // Another lane can still be answering this thread.
        while let id = threadID, model.liveThread(id) != nil {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let seedIDs = Set(threadID.flatMap { id in model.history.first { $0.id == id }?.conversation.map(\.id) } ?? [])

        await call("sendChatAction", ["chat_id": chatID, "action": "typing"])
        guard let landed = model.runTelegramRound(threadID: threadID, question: question, images: images,
                                                  pin: action?.pin) else {
            await call("sendMessage", ["chat_id": chatID, "text": L(LicenseLock.isLocked ? "service.error.licenseRequired" : "telegram.failed"),
                                       "reply_to_message_id": messageID])
            return
        }
        SignalBridge.shared.mirrorTelegramMessage(threadID: landed, text: text, images: images)
        setThread(landed, chat: chatID)
        model.openSteering(threadID: landed)
        let previous = threadID.flatMap { id in model.history.first { $0.id == id }?.conversation }?
            .last(where: { $0.role == "assistant" && !$0.isError })?.text ?? ""
        react(to: text, previous: previous, thread: landed, chatID: chatID, messageID: messageID)
        await stream(thread: landed, seedIDs: seedIDs, chatID: chatID, replyTo: messageID)
        // Messages sent after the round's last tool call: answer them next.
        let waiting = steered.removeValue(forKey: landed) ?? [:]
        let unread = model.closeSteering(threadID: landed).compactMap { waiting[$0] }.flatMap { $0 }
        if !unread.isEmpty { await answer(unread, chatID: chatID) }
    }

    /// The text a message replies to: the part the user highlighted
    /// (`quote`), else the whole replied message, capped like a notch reply.
    private static func quotedText(of message: [String: Any]) -> String? {
        let replied = message["reply_to_message"] as? [String: Any]
            ?? message["external_reply"] as? [String: Any]
        let picked = (message["quote"] as? [String: Any])?["text"] as? String
            ?? (replied?["text"] ?? replied?["caption"]) as? String
        guard let body = picked?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty
        else { return nil }
        let limit = NotchModel.replyQuoteLimit
        return body.count > limit ? String(body.prefix(limit)) + "…" : body
    }

    // MARK: - Reactions

    /// Same bar as the notch's `NotchModel.reactionMinProbability`.
    private static let reactionMinProbability = 0.5

    /// The notch's emoji reaction, put on the Telegram message: Jev is asked in
    /// parallel with the answer under the same switch and privacy rules, and
    /// the emoji is dropped once the answer has finished, as in the notch.
    private func react(to text: String, previous: String, thread: UUID, chatID: Int64, messageID: Int) {
        let account = NoNoAccount.shared
        guard ChatSwitch.emojiReactions, account.canDecide, messageID != 0 else { return }
        let message = String(text.prefix(1500))
        guard !message.isEmpty, !ClipPrivacy.containsSecret(message) else { return }
        let prior = ClipPrivacy.containsSecret(previous) ? "" : String(previous.suffix(1500))
        Task { [weak self] in
            guard let verdict = await account.react(to: message, previous: prior),
                  verdict.probability >= Self.reactionMinProbability,
                  let emoji = verdict.emoji,
                  let self, self.model?.liveThread(thread) != nil else { return }
            await self.call("setMessageReaction", [
                "chat_id": chatID, "message_id": messageID,
                "reaction": [["type": "emoji", "emoji": Self.telegramReaction(for: emoji)]],
            ])
        }
    }

    /// Bots can only react with Telegram's fixed list of emoji, written
    /// without variation selectors.
    private static let allowedReactions: Set<String> = [
        "👍", "👎", "❤", "🔥", "🥰", "👏", "😁", "🤔", "🤯", "😱", "🤬", "😢", "🎉", "🤩",
        "🤮", "💩", "🙏", "👌", "🕊", "🤡", "🥱", "🥴", "😍", "🐳", "❤‍🔥", "🌚", "🌭", "💯",
        "🤣", "⚡", "🍌", "🏆", "💔", "🤨", "😐", "🍓", "🍾", "💋", "🖕", "😈", "😴", "😭",
        "🤓", "👻", "👨‍💻", "👀", "🎃", "🙈", "😇", "😨", "🤝", "✍", "🤗", "🫡", "🎅", "🎄",
        "☃", "💅", "🤪", "🗿", "🆒", "💘", "🙉", "🦄", "😘", "💊", "🙊", "😎", "👾",
        "🤷‍♂", "🤷", "🤷‍♀", "😡",
    ]

    /// The closest allowed reaction for emoji outside the list.
    private static let nearestReaction: [String: String] = [
        "😂": "🤣", "😆": "😁", "😄": "😁", "😃": "😁", "😀": "😁", "😅": "😁", "😹": "🤣",
        "🙂": "🥰", "😊": "🥰", "☺": "🥰", "🥹": "🥰", "😻": "😍", "🤤": "😍",
        "🧡": "❤", "💛": "❤", "💚": "❤", "💙": "❤", "💜": "❤", "🖤": "❤", "🤍": "❤", "🤎": "❤",
        "💕": "❤", "💖": "❤", "💗": "❤", "💓": "❤", "💞": "❤", "💝": "❤", "🫶": "❤", "♥": "❤",
        "‼": "🤯", "❗": "🤯", "❕": "🤯", "⁉": "🤯", "😮": "🤯", "😲": "🤯", "😯": "🤯",
        "❓": "🤔", "❔": "🤔", "🧐": "🤔",
        "😞": "😢", "😔": "😢", "😟": "😢", "🥺": "😢", "😿": "😢", "😕": "😢", "🙁": "😢", "☹": "😢",
        "😩": "😭", "😫": "😭", "😖": "😭", "😣": "😭",
        "😠": "😡", "😤": "😡", "👿": "😈",
        "😳": "😨", "😰": "😨", "😧": "😨", "😦": "😨", "🫣": "🙈",
        "🙌": "👏", "💪": "🔥", "🚀": "🔥", "✨": "🤩", "🌟": "🤩", "⭐": "🤩", "💫": "🤩",
        "🥳": "🎉", "🎊": "🎉", "🎈": "🎉", "🎁": "🎉", "🎂": "🎉", "🍰": "🎉", "🧁": "🎉",
        "🍺": "🍾", "🍻": "🍾", "🥂": "🍾", "🍷": "🍾", "🍸": "🍾", "🥃": "🍾",
        "🥇": "🏆", "🏅": "🏆", "👑": "🏆",
        "😪": "😴", "💤": "😴", "🛌": "😴",
        "🤒": "💊", "🤕": "💊", "😷": "💊", "🤧": "💊",
        "🤞": "🙏", "🫂": "🤗", "👋": "🤝", "✅": "👌", "✔": "👌", "☑": "👌",
        "💡": "⚡", "🌩": "⚡", "😬": "😐", "😑": "😐", "😶": "😐", "🙄": "🥱", "🤭": "🙊",
        "💻": "👨‍💻", "🖥": "👨‍💻", "⌨": "👨‍💻", "🤑": "🤩", "😜": "🤪", "😝": "🤪", "😛": "🤪",
        "😉": "😘", "😗": "😘", "😙": "😘", "😚": "😘", "🤢": "🤮", "💀": "👻", "☠": "👻",
    ]

    /// Maps the notch's emoji to one a bot may set. Variation selectors and
    /// skin tones are dropped first; an emoji with no close match gets 👀.
    static func telegramReaction(for emoji: String) -> String {
        let bare = String(String.UnicodeScalarView(emoji.unicodeScalars.filter {
            $0.value != 0xFE0F && !(0x1F3FB...0x1F3FF).contains($0.value)
        }))
        if allowedReactions.contains(bare) { return bare }
        return nearestReaction[bare] ?? "👀"
    }

    /// Follows the round once a second and waits for it to finish; nothing of a
    /// half-written answer is shown. The finished text goes out with
    /// formatting. Pending questions go out as inline buttons.
    private func stream(thread: UUID, seedIDs: Set<UUID>, chatID: Int64, replyTo firstReplyTo: Int) async {
        guard let model else { return }
        var replyTo = firstReplyTo
        var sentID: Int?
        var sawLive = false
        var askedQuestions: Set<UUID> = []
        var ticks = 0
        // A follow-up the round read mid-answer: the text before it stays in
        // the message above it, the text after it goes into a new message
        // replying to it. `base` is where the current message's text starts
        // in the answer.
        var base = 0
        var handledTags: Set<Int> = []
        var firstSegment = true
        while true {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            ticks += 1
            guard let live = model.liveThread(thread) else {
                // Not started yet: a round registers on its task's first tick.
                // A round that already ended (one that failed at once, such as
                // a locked license) has its answer in history: stop waiting.
                let landed = model.history.first(where: { $0.id == thread })?.conversation
                    .contains(where: { $0.role == "assistant" && !seedIDs.contains($0.id) }) ?? false
                if !sawLive && !landed && ticks < 15 { continue }
                break
            }
            sawLive = true
            guard let answer = live.last(where: { $0.role == "assistant" && !seedIDs.contains($0.id) }) else { continue }
            if let question = answer.pendingQuestion, !askedQuestions.contains(question.id) {
                askedQuestions.insert(question.id)
                await ask(question, chatID: chatID)
            }
            let unread = model.unreadSteerTags(threadID: thread)
            let read = Set(steered[thread]?.keys.map { $0 } ?? []).subtracting(unread).subtracting(handledTags)
            if let newest = read.max() {
                handledTags.formUnion(read)
                let raw = answer.text
                let segment = String(raw.dropFirst(min(base, raw.count)))
                if Self.plain(segment).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Only a status line so far: drop it, the answer starts below the follow-up.
                    if let sentID { await call("deleteMessage", ["chat_id": chatID, "message_id": sentID]) }
                } else {
                    let head = firstSegment ? Self.head(of: answer) : ("", "")
                    let segmentBody = await PagesService.shared.rewriteWithAccessKeys(
                        in: Self.withoutVisualBlocks(segment).trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    _ = await deliver(body: segmentBody,
                                      head: head, tail: "", sentID: sentID,
                                      replyTo: replyTo, chatID: chatID, thread: thread)
                    firstSegment = false
                }
                base = raw.count
                sentID = nil
                replyTo = newest
                continue
            }
            // No streaming preview and no tool-activity line: the chat shows the
            // finished answer only (the user asked for no intermediate
            // "thinking" state, 2026-11-20). Typing keeps the wait readable.
            if ticks % 4 == 0 { await call("sendChatAction", ["chat_id": chatID, "action": "typing"]) }
        }

        let turn = model.history.first(where: { $0.id == thread })?.conversation
            .last(where: { $0.role == "assistant" && !seedIDs.contains($0.id) })
        let whole = turn?.text ?? ""
        let final = String(whole.dropFirst(min(base, whole.count)))
        let (withoutVisuals, charts) = Self.renderVisuals(final)
        let (shownText, photos) = Self.localImages(withoutVisuals)
        let pictures = photos + charts
        let rawBody = shownText.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = rawBody.isEmpty ? "" : await PagesService.shared.rewriteWithAccessKeys(in: rawBody)
        defer {
            // After the text, so the picture lands under the line asking about it.
            if !pictures.isEmpty {
                Task { [weak self, replyTo] in
                    for picture in pictures {
                        let result = await self?.sendPhoto(picture, chatID: chatID,
                                                           replyTo: body.isEmpty ? replyTo : nil)
                        if let self, let result, let id = Self.messageID(result) {
                            self.remember(messageID: id, chatID: chatID, thread: thread)
                        }
                    }
                    for chart in charts { try? FileManager.default.removeItem(at: chart) }
                }
            }
        }
        let wasStopped = stoppedThreads.remove(thread) != nil
        guard !body.isEmpty || !pictures.isEmpty else {
            if wasStopped { return }
            // The answer before a follow-up already went out; nothing came after it.
            if !firstSegment {
                if let sentID { await call("deleteMessage", ["chat_id": chatID, "message_id": sentID]) }
                return
            }
            if let sentID {
                await call("editMessageText", ["chat_id": chatID, "message_id": sentID, "text": L(LicenseLock.isLocked ? "service.error.licenseRequired" : "telegram.failed")])
            } else {
                await call("sendMessage", ["chat_id": chatID, "text": L(LicenseLock.isLocked ? "service.error.licenseRequired" : "telegram.failed"), "reply_to_message_id": replyTo])
            }
            return
        }
        let head = firstSegment && turn != nil ? Self.head(of: turn!) : ("", "")
        let tail = Self.sourcesHTML(turn?.sources ?? [])
        let lastID = await deliver(body: body, head: head, tail: tail, sentID: sentID,
                                   replyTo: replyTo, chatID: chatID, thread: thread)
        if let turn, let lastID, !wasStopped {
            offerButtons(after: turn, thread: thread, chatID: chatID, messageID: lastID)
        }
    }

    /// The lines the notch shows above an answer: what it filed (HTML, plain).
    private static func head(of turn: NotchModel.Turn) -> (String, String) {
        let filed = uniqued(turn.captures.map(captureLabel))
        return (filed.map { "<i>" + TelegramFormat.escape($0) + "</i>" }.joined(separator: "\n"),
                filed.joined(separator: "\n"))
    }

    /// Sends `body` formatted, editing `sentID` into its first part when there
    /// is one. `tail` (the pages read) goes under the last part. Returns the
    /// last message's id.
    private func deliver(body: String, head: (String, String), tail: String, sentID: Int?,
                         replyTo: Int, chatID: Int64, thread: UUID) async -> Int? {
        let parts = body.isEmpty ? [] : Self.split(body)
        var lastID = sentID
        var tailSent = tail.isEmpty
        for (index, part) in parts.enumerated() {
            var html = TelegramFormat.html(part)
            var plainPart = part
            if index == 0, !head.0.isEmpty {
                html = head.0 + "\n\n" + html
                plainPart = head.1 + "\n\n" + plainPart
            }
            if index == parts.count - 1, !tail.isEmpty, html.count + tail.count + 2 <= 4096 {
                html += "\n\n" + tail
                tailSent = true
            }
            if index == 0, let sentID {
                let result = await call("editMessageText", ["chat_id": chatID, "message_id": sentID,
                                                            "text": html, "parse_mode": "HTML",
                                                            "disable_web_page_preview": true])
                if result["ok"] as? Bool != true {
                    await call("editMessageText", ["chat_id": chatID, "message_id": sentID, "text": plainPart])
                }
                continue
            }
            var params: [String: Any] = ["chat_id": chatID, "text": html, "parse_mode": "HTML",
                                         "disable_web_page_preview": true]
            if index == 0 { params["reply_to_message_id"] = replyTo }
            var result = await call("sendMessage", params)
            if result["ok"] as? Bool != true {
                result = await call("sendMessage", ["chat_id": chatID, "text": plainPart])
            }
            if let id = Self.messageID(result) {
                remember(messageID: id, chatID: chatID, thread: thread)
                lastID = id
            }
        }
        // Sources that did not fit under the last part go out on their own.
        if !tailSent {
            let result = await call("sendMessage", ["chat_id": chatID, "text": tail, "parse_mode": "HTML",
                                                    "disable_web_page_preview": true,
                                                    "disable_notification": true])
            if let id = Self.messageID(result) { remember(messageID: id, chatID: chatID, thread: thread) }
        }
        return lastID
    }

    /// A round asked in Notchi itself (the panel, a window, a loop), sent to
    /// the owner's chat as the question quoted above the answer. The chat then
    /// continues that thread, and replying to the message does too.
    func mirror(threadID: UUID, question: String, answer: String) {
        guard case .connected = state, let owner else { return }
        let (withoutVisuals, charts) = Self.renderVisuals(answer)
        let (shownText, photos) = Self.localImages(withoutVisuals)
        let pictures = photos + charts
        let body = shownText.trimmingCharacters(in: .whitespacesAndNewlines)
        let asked = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !body.isEmpty || !pictures.isEmpty else { return }
        setThread(threadID, chat: owner)
        let previous = chains["\(owner)"]
        chains["\(owner)"] = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let rewritten = body.isEmpty ? "" : await PagesService.shared.rewriteWithAccessKeys(in: body)
            let pageButtons = await self.pageWebAppButtons(in: answer)
            let parts = rewritten.isEmpty ? [] : Self.split(rewritten)
            for (index, part) in parts.enumerated() {
                let quote = index == 0 && !asked.isEmpty
                let isLast = index == parts.count - 1
                var params: [String: Any] = [
                    "chat_id": owner,
                    "text": (quote ? "<blockquote>" + TelegramFormat.escape(asked) + "</blockquote>\n" : "")
                        + TelegramFormat.html(part),
                    "parse_mode": "HTML", "disable_web_page_preview": true,
                    "disable_notification": true,
                ]
                if isLast && !pageButtons.isEmpty {
                    params["reply_markup"] = ["inline_keyboard": pageButtons]
                }
                var result = await self.call("sendMessage", params)
                if result["ok"] as? Bool != true {
                    var fallback: [String: Any] = [
                        "chat_id": owner,
                        "text": (quote ? "› " + asked + "\n\n" : "") + part,
                        "disable_notification": true,
                    ]
                    if isLast && !pageButtons.isEmpty {
                        fallback["reply_markup"] = ["inline_keyboard": pageButtons]
                    }
                    result = await self.call("sendMessage", fallback)
                }
                if let id = Self.messageID(result) { self.remember(messageID: id, chatID: owner, thread: threadID) }
            }
            for picture in pictures {
                let result = await self.sendPhoto(picture, chatID: owner, silent: true)
                if let id = Self.messageID(result) { self.remember(messageID: id, chatID: owner, thread: threadID) }
            }
            for chart in charts { try? FileManager.default.removeItem(at: chart) }
        }
    }

    /// A message the user sent Notchi in Signal, shown in the owner's chat as
    /// it arrives, quoted, so the chat holds both sides of the conversation.
    /// The answer follows later through `mirror` without quoting it again.
    func mirrorSignalMessage(threadID: UUID, text: String, images: [NSImage]) {
        guard case .connected = state, let owner else { return }
        let shown = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(3500))
        guard !shown.isEmpty || !images.isEmpty else { return }
        setThread(threadID, chat: owner)
        let files: [URL] = images.compactMap { image in
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            else { return nil }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("notchi-signal-\(UUID().uuidString).jpg")
            return (try? jpeg.write(to: url)) != nil ? url : nil
        }
        let previous = chains["\(owner)"]
        chains["\(owner)"] = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { for file in files { try? FileManager.default.removeItem(at: file) } }
            if !shown.isEmpty {
                var result = await self.call("sendMessage", [
                    "chat_id": owner,
                    "text": "<blockquote>" + TelegramFormat.escape(shown) + "</blockquote>\n<i>"
                        + TelegramFormat.escape(L("signal.forwarded")) + "</i>",
                    "parse_mode": "HTML", "disable_web_page_preview": true,
                    "disable_notification": true,
                ])
                if result["ok"] as? Bool != true {
                    result = await self.call("sendMessage", ["chat_id": owner, "text": "› " + shown + "\n" + L("signal.forwarded"),
                                                             "disable_notification": true])
                }
                if let id = Self.messageID(result) { self.remember(messageID: id, chatID: owner, thread: threadID) }
            }
            for file in files {
                let result = await self.sendPhoto(file, chatID: owner, silent: true)
                if let id = Self.messageID(result) { self.remember(messageID: id, chatID: owner, thread: threadID) }
            }
        }
    }

    private func ask(_ question: NotchModel.PendingUserQuestion, chatID: Int64) async {
        questionOptions[question.id] = question.options
        let buttons = question.options.enumerated().map { index, option in
            [["text": option, "callback_data": "\(question.id.uuidString)|\(index)"]]
        }
        await call("sendMessage", ["chat_id": chatID, "text": question.question,
                                   "reply_markup": ["inline_keyboard": buttons]])
    }

    /// The models the menu bar's Model menu lists: the serving one, then the
    /// recently used ones that are still set up.
    private static func modelRows() -> [AskModelMRU.Entry] {
        let current = APIKeyStore.selectedProvider
        let currentModel = APIKeyStore.effectiveModel(for: current) ?? current.defaultModel
        var rows: [AskModelMRU.Entry] = []
        if ModelCatalogStore.ready(current), !currentModel.isEmpty {
            rows.append(.init(provider: current, model: currentModel))
        }
        for entry in AskModelMRU.entries where ModelCatalogStore.ready(entry.provider) {
            if !rows.contains(entry) { rows.append(entry) }
        }
        return Array(rows.prefix(AskModelMRU.capacity))
    }

    private static func modelName(_ entry: AskModelMRU.Entry) -> String {
        "\(ModelRatings.prettyName(for: entry.model, provider: entry.provider)) (\(entry.provider.displayName))"
    }

    private func offerModels(chatID: Int64) async {
        let rows = Self.modelRows()
        guard let first = rows.first else {
            await call("sendMessage", ["chat_id": chatID, "text": L("menuBar.noModel")])
            return
        }
        let current = APIKeyStore.selectedProvider
        let currentModel = APIKeyStore.effectiveModel(for: current) ?? current.defaultModel
        let serving = first.provider == current && first.model == currentModel
        let id = UUID()
        modelOptions[id] = rows
        let buttons = rows.enumerated().map { index, row in
            [["text": (index == 0 && serving ? "✓ " : "") + Self.modelName(row),
              "callback_data": "model|\(id.uuidString)|\(index)"]]
        }
        let text = serving ? String(format: L("telegram.model.current"), Self.modelName(first))
                           : L("telegram.command.model")
        await call("sendMessage", ["chat_id": chatID, "text": text,
                                   "reply_markup": ["inline_keyboard": buttons]])
    }

    private func chooseModel(_ parts: [Substring], message: [String: Any]?) async {
        guard parts.count == 3, let id = UUID(uuidString: String(parts[1])),
              let index = Int(parts[2]),
              let rows = modelOptions.removeValue(forKey: id),
              rows.indices.contains(index) else { return }
        let row = rows[index]
        ModelCatalogStore.select(provider: row.provider, model: row.model)
        if let message,
           let chatID = ((message["chat"] as? [String: Any])?["id"] as? NSNumber)?.int64Value,
           let messageID = (message["message_id"] as? NSNumber)?.intValue {
            await call("editMessageText", ["chat_id": chatID, "message_id": messageID,
                                           "text": String(format: L("telegram.model.current"), Self.modelName(row))])
        }
    }

    private func answerCallback(_ callback: [String: Any]) async {
        guard let id = callback["id"] as? String else { return }
        await call("answerCallbackQuery", ["callback_query_id": id])
        guard let data = callback["data"] as? String else { return }
        if data.hasPrefix("model|") {
            await chooseModel(data.split(separator: "|"), message: callback["message"] as? [String: Any])
            return
        }
        if data.hasPrefix("pick|") {
            await choose(data.split(separator: "|"), message: callback["message"] as? [String: Any])
            return
        }
        let parts = data.split(separator: "|")
        guard parts.count == 2, let questionID = UUID(uuidString: String(parts[0])),
              let index = Int(parts[1]),
              let options = questionOptions.removeValue(forKey: questionID),
              options.indices.contains(index) else { return }
        model?.chooseUserOption(options[index], questionID: questionID)
        if let owner, let thread = thread(for: owner) {
            SignalBridge.shared.mirrorTelegramMessage(threadID: thread, text: options[index], images: [])
        }
        if let message = callback["message"] as? [String: Any],
           let chatID = ((message["chat"] as? [String: Any])?["id"] as? NSNumber)?.int64Value,
           let messageID = (message["message_id"] as? NSNumber)?.intValue {
            let text = (message["text"] as? String ?? "") + "\n→ " + options[index]
            await call("editMessageText", ["chat_id": chatID, "message_id": messageID, "text": text])
        }
    }

    private func downloadImage(_ fileID: String) async -> NSImage? {
        let info = await call("getFile", ["file_id": fileID])
        guard let path = (info["result"] as? [String: Any])?["file_path"] as? String,
              let url = URL(string: "https://api.telegram.org/file/bot\(token)/\(path)"),
              let (data, response) = try? await ProxyConfig.urlSession.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return NSImage(data: data)
    }

    // MARK: - Attachments

    private struct Attachments {
        var images: [NSImage] = []
        /// Everything else, as text the model reads inside the question
        /// (`NotchModel.fileEnvelope`).
        var files: [NotchModel.DroppedFile] = []
        /// Photos not downloaded because the round already has its limit.
        var skippedImages = 0
    }

    /// Bots can download files up to 20 MB.
    private static let downloadLimit = 20 * 1024 * 1024
    /// Stills taken from one video.
    private static let videoFrames = 4

    /// Downloaded files, kept so a model with commands can open them.
    private static var filesFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Notchi")
            .appendingPathComponent("Telegram")
    }

    /// `room` is how many more images the round can take; a photo past it is
    /// counted, not downloaded.
    private func attachments(of message: [String: Any], chatID: Int64, room: Int) async -> Attachments {
        var found = Attachments()
        func note(_ name: String, _ text: String) {
            found.files.append(NotchModel.DroppedFile(name: name, text: text))
        }

        if let photos = message["photo"] as? [[String: Any]],
           let largest = photos.last?["file_id"] as? String {
            if room <= 0 {
                found.skippedImages += 1
            } else if let image = await downloadImage(largest) {
                found.images.append(image)
            } else {
                note("Photo", "The photo could not be downloaded.")
            }
        }

        if let sticker = message["sticker"] as? [String: Any] {
            let still = sticker["is_animated"] as? Bool != true && sticker["is_video"] as? Bool != true
            let id = still ? sticker["file_id"] as? String
                : (sticker["thumbnail"] as? [String: Any])?["file_id"] as? String
            if let id, let image = await downloadImage(id) { found.images.append(image) }
            let emoji = sticker["emoji"] as? String ?? ""
            note("Sticker", emoji.isEmpty ? "A sticker." : "A sticker for \(emoji).")
        }

        // An animation also comes with a `document` describing the same file.
        let video = (message["video"] ?? message["video_note"] ?? message["animation"]) as? [String: Any]
        if let video {
            let kind = message["video_note"] != nil ? "Video message"
                : message["animation"] != nil ? "GIF" : "Video"
            found = merge(found, await videoAttachment(video, kind: kind, chatID: chatID))
        }

        if let audio = (message["voice"] ?? message["audio"]) as? [String: Any] {
            let kind = message["voice"] != nil ? "Voice message" : "Audio"
            found.files.append(await audioAttachment(audio, kind: kind, chatID: chatID))
        }

        if video == nil, let document = message["document"] as? [String: Any] {
            found = merge(found, await documentAttachment(document, chatID: chatID))
        }

        if let venue = message["venue"] as? [String: Any] {
            let location = venue["location"] as? [String: Any] ?? [:]
            note("Location", [venue["title"] as? String, venue["address"] as? String,
                              Self.coordinates(location)].compactMap { $0 }.joined(separator: "\n"))
        } else if let location = message["location"] as? [String: Any] {
            let live = location["live_period"] != nil ? " (live location)" : ""
            note("Location", (Self.coordinates(location) ?? "") + live)
        }

        if let contact = message["contact"] as? [String: Any] {
            let name = [contact["first_name"] as? String, contact["last_name"] as? String]
                .compactMap { $0 }.joined(separator: " ")
            note("Contact", [name, contact["phone_number"] as? String].compactMap { $0 }
                .filter { !$0.isEmpty }.joined(separator: "\n"))
        }

        if let poll = message["poll"] as? [String: Any] {
            let options = (poll["options"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            note("Poll", ([poll["question"] as? String ?? ""] + options.map { "- " + $0 })
                .joined(separator: "\n"))
        }

        if let dice = message["dice"] as? [String: Any] {
            let emoji = dice["emoji"] as? String ?? "🎲"
            let value = (dice["value"] as? NSNumber)?.intValue ?? 0
            note("Dice", "\(emoji) landed on \(value).")
        }

        if found.images.isEmpty, found.files.isEmpty, message["text"] == nil {
            for key in ["story", "game", "invoice", "paid_media", "giveaway"] where message[key] != nil {
                note("Attachment", "A Telegram \(key.replacingOccurrences(of: "_", with: " ")) that bots cannot open.")
                break
            }
        }
        return found
    }

    private func merge(_ a: Attachments, _ b: Attachments) -> Attachments {
        Attachments(images: a.images + b.images, files: a.files + b.files)
    }

    private func videoAttachment(_ video: [String: Any], kind: String, chatID: Int64) async -> Attachments {
        var found = Attachments()
        let length = (video["duration"] as? NSNumber).map { " (" + Self.clock($0.intValue) + ")" } ?? ""
        guard let url = await download(video, name: kind, chatID: chatID) else {
            if let thumb = (video["thumbnail"] as? [String: Any])?["file_id"] as? String,
               let image = await downloadImage(thumb) {
                found.images.append(image)
            }
            found.files.append(.init(name: kind, text: "A \(kind.lowercased())\(length). "
                + Self.unreadable(video) + (found.images.isEmpty ? "" : " Its cover is attached.")))
            return found
        }
        found.images = await Self.frames(of: url, count: Self.videoFrames)
        let transcript = await Self.transcript(of: url)
        var text = "A \(kind.lowercased())\(length), shown as \(found.images.count) stills in order."
        if let transcript { text += "\nWhat is said in it:\n" + transcript }
        text += "\nSaved on this Mac at " + url.path
        found.files.append(.init(name: kind, text: text))
        return found
    }

    private func audioAttachment(_ audio: [String: Any], kind: String, chatID: Int64) async -> NotchModel.DroppedFile {
        let name = audio["file_name"] as? String ?? kind
        var about = [audio["performer"] as? String, audio["title"] as? String]
            .compactMap { $0 }.joined(separator: " – ")
        if let seconds = (audio["duration"] as? NSNumber)?.intValue {
            about += (about.isEmpty ? "" : ", ") + Self.clock(seconds)
        }
        let head = "A \(kind.lowercased())" + (about.isEmpty ? "." : " (\(about)).")
        guard let url = await download(audio, name: kind, chatID: chatID) else {
            return .init(name: name, text: head + " " + Self.unreadable(audio))
        }
        guard let transcript = await Self.transcript(of: url) else {
            return .init(name: name, text: head + " It could not be transcribed on this Mac.\nSaved on this Mac at " + url.path)
        }
        return .init(name: name, text: head + "\nTranscript:\n" + transcript)
    }

    private func documentAttachment(_ document: [String: Any], chatID: Int64) async -> Attachments {
        var found = Attachments()
        let name = document["file_name"] as? String ?? "File"
        guard let url = await download(document, name: "File", chatID: chatID) else {
            found.files.append(.init(name: name, text: Self.unreadable(document)))
            return found
        }
        let mime = document["mime_type"] as? String ?? ""
        let type = UTType(filenameExtension: url.pathExtension) ?? UTType(mimeType: mime)
        if type?.conforms(to: .image) == true, let image = NSImage(contentsOf: url), image.isValid {
            found.images.append(image)
            return found
        }
        if type?.conforms(to: .movie) == true || mime.hasPrefix("video/") {
            return await videoAttachment(document, kind: "Video", chatID: chatID)
        }
        if type?.conforms(to: .audio) == true || mime.hasPrefix("audio/") {
            found.files.append(await audioAttachment(document, kind: "Audio", chatID: chatID))
            return found
        }
        let text = await Task.detached { NotchModel.droppedFileText(url, type: type) }.value
        if let text {
            found.files.append(.init(name: name, text: text))
        } else {
            let size = ByteCountFormatter.string(fromByteCount: Int64((document["file_size"] as? NSNumber)?.intValue ?? 0),
                                                 countStyle: .file)
            found.files.append(.init(name: name, text: "A file Notchi cannot read (\(mime.isEmpty ? url.pathExtension : mime), \(size)).\nSaved on this Mac at " + url.path))
        }
        return found
    }

    /// Downloads a file into `filesFolder`, under its own name. nil when it is
    /// over `downloadLimit` or the download fails. Downloading takes a while,
    /// so the chat shows the bot typing.
    private func download(_ media: [String: Any], name fallback: String, chatID: Int64) async -> URL? {
        guard let id = media["file_id"] as? String else { return nil }
        if let size = (media["file_size"] as? NSNumber)?.intValue, size > Self.downloadLimit { return nil }
        await call("sendChatAction", ["chat_id": chatID, "action": "typing"])
        let info = await call("getFile", ["file_id": id])
        guard let path = (info["result"] as? [String: Any])?["file_path"] as? String,
              let remote = URL(string: "https://api.telegram.org/file/bot\(token)/\(path)"),
              let (temp, response) = try? await ProxyConfig.urlSession.download(from: remote),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        var name = media["file_name"] as? String ?? ""
        if name.isEmpty {
            let ext = (path as NSString).pathExtension
            name = ext.isEmpty ? fallback : fallback + "." + ext
        }
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let folder = Self.filesFolder.appendingPathComponent(media["file_unique_id"] as? String ?? UUID().uuidString)
        let url = folder.appendingPathComponent(name)
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        try? files.removeItem(at: url)
        guard (try? files.moveItem(at: temp, to: url)) != nil else { return nil }
        return url
    }

    /// Why a file was not read: too large for a bot, or the download failed.
    private static func unreadable(_ media: [String: Any]) -> String {
        if let size = (media["file_size"] as? NSNumber)?.intValue, size > downloadLimit {
            return "It is larger than the 20 MB a bot can download, so its content is not available."
        }
        return "It could not be downloaded."
    }

    private static func coordinates(_ location: [String: Any]) -> String? {
        guard let lat = (location["latitude"] as? NSNumber)?.doubleValue,
              let lon = (location["longitude"] as? NSNumber)?.doubleValue else { return nil }
        return String(format: "%.6f, %.6f", lat, lon)
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Stills spread evenly through a video.
    nonisolated static func frames(of url: URL, count: Int) async -> [NSImage] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1568, height: 1568)
        var images: [NSImage] = []
        for index in 0..<count {
            let time = CMTime(seconds: duration.seconds * (Double(index) + 0.5) / Double(count),
                              preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: time) {
                images.append(NSImage(cgImage: image, size: .zero))
            }
        }
        return images
    }

    /// The speech in an audio or video file, recognised on this Mac only. nil
    /// when speech recognition is not allowed, on-device recognition is not
    /// available for the system language, the file has no readable audio, or
    /// nothing was said.
    nonisolated static func transcript(of url: URL) async -> String? {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized,
              let recognizer = SFSpeechRecognizer(), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition,
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384),
                  (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 else { break }
            request.append(buffer)
        }
        request.endAudio()
        let text: String? = await withCheckedContinuation { continuation in
            let once = Once()
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    once.run { continuation.resume(returning: result.bestTranscription.formattedString) }
                } else if error != nil {
                    once.run { continuation.resume(returning: nil) }
                }
            }
            once.keep(task)
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Threads

    private func thread(for chatID: Int64) -> UUID? {
        let map = UserDefaults.standard.dictionary(forKey: Self.threadsKey) as? [String: String] ?? [:]
        return map[String(chatID)].flatMap(UUID.init(uuidString:))
    }

    private func setThread(_ thread: UUID?, chat chatID: Int64) {
        var map = UserDefaults.standard.dictionary(forKey: Self.threadsKey) as? [String: String] ?? [:]
        map[String(chatID)] = thread?.uuidString
        UserDefaults.standard.set(map, forKey: Self.threadsKey)
    }

    private func threadForMessage(chatID: Int64, messageID: Int) -> UUID? {
        let list = UserDefaults.standard.array(forKey: Self.messagesKey) as? [[String]] ?? []
        let key = "\(chatID):\(messageID)"
        return list.last(where: { $0.first == key }).flatMap { $0.count == 2 ? UUID(uuidString: $0[1]) : nil }
    }

    private func remember(messageID: Int, chatID: Int64, thread: UUID) {
        var list = UserDefaults.standard.array(forKey: Self.messagesKey) as? [[String]] ?? []
        list.append(["\(chatID):\(messageID)", thread.uuidString])
        UserDefaults.standard.set(Array(list.suffix(Self.messagesCap)), forKey: Self.messagesKey)
    }

    // MARK: - Text

    private static func messageID(_ result: [String: Any]) -> Int? {
        ((result["result"] as? [String: Any])?["message_id"] as? NSNumber)?.intValue
    }

    /// What the streaming preview shows: the answer without visual blocks.
    /// Plain text, because half-written Markdown is not valid HTML.
    private static func plain(_ text: String) -> String {
        localImages(withoutVisualBlocks(text)).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Images an answer shows from this Mac — `![…](file://…)` or an absolute
    /// path, such as a picture from the cloud desktop. Telegram cannot fetch
    /// them, so they leave the text and go out as photos. Only files that
    /// exist and are images are taken; any other line stays as written.
    static func localImages(_ text: String) -> (text: String, files: [URL]) {
        let pattern = #"!\[[^\]]*\]\(\s*(file://[^)\s]+|/[^)\s]+)\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (text, []) }
        var files: [URL] = []
        var out = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: text),
                  let target = Range(match.range(at: 1), in: text) else { continue }
            let raw = String(text[target])
            let url = raw.hasPrefix("file://") ? URL(string: raw) : URL(fileURLWithPath: raw)
            guard let url, url.isFileURL, FileManager.default.fileExists(atPath: url.path),
                  UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { continue }
            files.insert(url, at: 0)
            out.replaceSubrange(whole, with: "")
        }
        return (out, files)
    }

    /// Charts and cards (`VisualBlocks`) are drawn by the app; in Telegram
    /// each becomes one line saying where to see it. An unclosed fence (still
    /// streaming) is dropped to the end.
    static func withoutVisualBlocks(_ text: String) -> String {
        var out: [String] = []
        var inBlock = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inBlock, trimmed.hasPrefix("```"),
               VisualSpecParser.languages.contains(String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()) {
                inBlock = true
                continue
            }
            if inBlock {
                if trimmed == "```" {
                    inBlock = false
                    out.append(L("telegram.visual"))
                }
                continue
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// Splits at paragraph, then line breaks, so no part is over the limit.
    static func split(_ text: String) -> [String] {
        var parts: [String] = []
        var rest = Substring(text)
        while rest.count > messageLimit {
            let window = rest.prefix(messageLimit)
            let cut = window.range(of: "\n\n", options: .backwards)?.lowerBound
                ?? window.range(of: "\n", options: .backwards)?.lowerBound
                ?? window.endIndex
            parts.append(String(rest[rest.startIndex..<cut]))
            rest = rest[cut...].drop(while: { $0 == "\n" })
        }
        if !rest.isEmpty { parts.append(String(rest)) }
        return parts
    }
}

/// Markdown as the models write it, to the HTML subset Telegram accepts:
/// fenced and inline code, bold, italic, links, and headings as bold lines.
enum TelegramFormat {
    static func html(_ markdown: String) -> String {
        var out: [String] = []
        var inCode = false
        var code: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    out.append("<pre>" + escape(code.joined(separator: "\n")) + "</pre>")
                    code = []
                }
                inCode.toggle()
                continue
            }
            if inCode { code.append(line); continue }
            if let heading = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                out.append("<b>" + inline(String(line[heading.upperBound...])) + "</b>")
                continue
            }
            out.append(inline(line))
        }
        if inCode { out.append("<pre>" + escape(code.joined(separator: "\n")) + "</pre>") }
        return out.joined(separator: "\n")
    }

    private static func inline(_ line: String) -> String {
        // Code spans first, so nothing inside them is read as formatting.
        var result = ""
        let pieces = line.components(separatedBy: "`")
        for (index, piece) in pieces.enumerated() {
            if index % 2 == 1, index < pieces.count - 1 {
                result += "<code>" + escape(piece) + "</code>"
            } else {
                result += emphasis(escape(index % 2 == 1 ? "`" + piece : piece))
            }
        }
        return result
    }

    private static func emphasis(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#,
                                   with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<b>$1</b>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#,
                                   with: "<i>$1</i>", options: .regularExpression)
        return s
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Runs a closure once, from whichever recognition callback comes first, and
/// holds the recognition task until then.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var task: SFSpeechRecognitionTask?

    func keep(_ task: SFSpeechRecognitionTask) {
        lock.lock(); defer { lock.unlock() }
        if !done { self.task = task }
    }

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        task = nil
        lock.unlock()
        if first { body() }
    }
}

// MARK: - Commands

/// The notch's `/` menu in the chat: `/note`, `/remind`, `/code` and `/loop`
/// are its modes, `/actions` its text actions, `/issue` its `@issue`. Each
/// takes the text after it, or the replied-to message; bare, it holds the
/// chat's next message, as a picked mode holds the next line in the notch.
extension TelegramBridge {
    fileprivate enum Mode: Equatable {
        case note, remind, code, loop, issue, actions
        /// A text action picked with nothing to run on yet.
        case action(UUID)

        init?(command: String) {
            switch command {
            case "note", "notes", "capture": self = .note
            case "remind", "reminder", "todo": self = .remind
            case "code", "agent", "task": self = .code
            case "loop", "repeat", "every": self = .loop
            case "issue", "feedback", "bug": self = .issue
            case "actions", "action", "shortcuts", "shortcut": self = .actions
            default: return nil
            }
        }

        /// The prompt's placeholder for the same mode in the notch.
        var placeholderKey: String {
            switch self {
            case .note: return "note.placeholder"
            case .remind: return "remind.placeholder"
            case .code: return "agent.placeholder"
            case .loop: return "loop.placeholder"
            case .issue: return "issue.placeholder"
            case .actions, .action: return "telegram.command.actions"
            }
        }
    }

    /// What one row of buttons does.
    fileprivate enum Choice {
        case folders(task: String, folders: [URL], replyTo: Int)
        case intervals(prompt: String)
        case actions(ids: [UUID], input: String?, replyTo: Int)
        case followUp(question: String)
        case resume(thread: UUID, turn: UUID)
        case retry(thread: UUID)
        case undo(NotchModel.Turn.Capture)
    }

    /// `/word@bot rest` → ("word", "rest").
    fileprivate static func command(in text: String) -> (String, String)? {
        guard text.hasPrefix("/") else { return nil }
        let end = text.firstIndex(where: { $0.isWhitespace || $0.isNewline }) ?? text.endIndex
        var word = String(text[text.index(after: text.startIndex)..<end])
        if let at = word.firstIndex(of: "@") { word = String(word[..<at]) }
        let rest = String(text[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (word.lowercased(), rest)
    }

    fileprivate func runCommand(_ command: String, argument: String, quote: String?,
                                chatID: Int64, messageID: Int) async {
        guard let mode = Mode(command: command) else { return }
        let input = argument.isEmpty ? (quote ?? "") : argument
        if mode == .actions {
            await offerActions(input: input.isEmpty ? nil : input, chatID: chatID, replyTo: messageID)
            return
        }
        guard !input.isEmpty else {
            pendingModes[chatID] = mode
            await call("sendMessage", ["chat_id": chatID, "text": L(mode.placeholderKey),
                                       "reply_to_message_id": messageID])
            return
        }
        await perform(mode, text: input, chatID: chatID, replyTo: messageID)
    }

    /// The message that followed a bare command.
    fileprivate func runMode(_ mode: Mode, messages: [[String: Any]], chatID: Int64) async {
        if case .action(let id) = mode {
            if let action = PromptShortcutStore.current.first(where: { $0.id == id }) {
                await answer(messages, chatID: chatID, action: action)
            } else {
                await answer(messages, chatID: chatID)
            }
            return
        }
        let text = messages
            .compactMap { (($0["text"] ?? $0["caption"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let messageID = (messages.first?["message_id"] as? NSNumber)?.intValue ?? 0
        guard !text.isEmpty else {
            await call("sendMessage", ["chat_id": chatID, "text": L("telegram.unsupported"),
                                       "reply_to_message_id": messageID])
            return
        }
        await perform(mode, text: text, chatID: chatID, replyTo: messageID)
    }

    private func perform(_ mode: Mode, text: String, chatID: Int64, replyTo: Int) async {
        guard let model else { return }
        switch mode {
        case .note, .remind:
            await call("sendChatAction", ["chat_id": chatID, "action": "typing"])
            let reply = await model.captureFromTelegram(text, reminder: mode == .remind)
            await call("sendMessage", ["chat_id": chatID, "text": reply, "reply_to_message_id": replyTo])
        case .issue:
            await call("sendChatAction", ["chat_id": chatID, "action": "typing"])
            let reply = await model.submitIssueFromTelegram(text)
            await call("sendMessage", ["chat_id": chatID, "text": reply, "reply_to_message_id": replyTo])
        case .code:
            await startAgentFlow(task: text, chatID: chatID, replyTo: replyTo)
        case .loop:
            await offerIntervals(prompt: text, chatID: chatID, replyTo: replyTo)
        case .actions:
            await offerActions(input: text, chatID: chatID, replyTo: replyTo)
        case .action:
            break
        }
    }

    // MARK: Buttons

    private func keyboard(_ id: UUID, _ titles: [String]) -> [String: Any] {
        ["inline_keyboard": titles.enumerated().map { index, title in
            [["text": title, "callback_data": "pick|\(id.uuidString)|\(index)"]]
        }]
    }

    private func clearButtons(chatID: Int64, messageID: Int) async {
        await call("editMessageReplyMarkup", ["chat_id": chatID, "message_id": messageID,
                                              "reply_markup": ["inline_keyboard": []]])
    }

    fileprivate func choose(_ parts: [Substring], message: [String: Any]?) async {
        guard parts.count == 3, let id = UUID(uuidString: String(parts[1])),
              let index = Int(parts[2]), let choice = choices[id],
              let message,
              let chatID = ((message["chat"] as? [String: Any])?["id"] as? NSNumber)?.int64Value,
              let messageID = (message["message_id"] as? NSNumber)?.intValue else { return }
        switch choice {
        case .folders(let task, let folders, let replyTo):
            guard folders.indices.contains(index) else { return }
            choices[id] = nil
            await startAgent(task: task, folder: folders[index], chatID: chatID,
                             replyTo: replyTo, statusID: messageID)
        case .intervals(let prompt):
            guard LoopInterval.presets.indices.contains(index) else { return }
            choices[id] = nil
            let minutes = LoopInterval.presets[index]
            await call("editMessageText", ["chat_id": chatID, "message_id": messageID,
                                           "text": L("loop.every", LoopInterval.short(minutes))])
            model?.startTelegramLoop(prompt: prompt, minutes: minutes)
        case .actions(let ids, let input, let replyTo):
            guard ids.indices.contains(index),
                  let action = PromptShortcutStore.current.first(where: { $0.id == ids[index] }) else { return }
            choices[id] = nil
            guard let input else {
                pendingModes[chatID] = .action(action.id)
                await call("editMessageText", ["chat_id": chatID, "message_id": messageID,
                                               "text": L("telegram.action.armed", action.displayName)])
                return
            }
            await call("editMessageText", ["chat_id": chatID, "message_id": messageID,
                                           "text": action.displayName])
            let lane = "\(chatID)"
            let previous = chains[lane]
            chains[lane] = Task { [weak self] in
                await previous?.value
                await self?.answer([["text": input, "message_id": replyTo]], chatID: chatID, action: action)
            }
        case .followUp(let question):
            choices[id] = nil
            await clearButtons(chatID: chatID, messageID: messageID)
            // As if the user had replied to this answer with the question.
            enqueue([["text": question, "message_id": messageID,
                      "reply_to_message": ["message_id": messageID]]], chatID: chatID)
        case .resume(let thread, let turn):
            choices[id] = nil
            await clearButtons(chatID: chatID, messageID: messageID)
            let lane = "\(chatID)"
            let previous = chains[lane]
            chains[lane] = Task { [weak self] in
                await previous?.value
                guard let self, let model = self.model else { return }
                let seed = Set(model.history.first { $0.id == thread }?.conversation.map(\.id) ?? [])
                guard model.continueTelegramAnswer(threadID: thread, turnID: turn) != nil else { return }
                let awake = Awake(.answering)
                defer { withExtendedLifetime(awake) {} }
                await self.stream(thread: thread, seedIDs: seed, chatID: chatID, replyTo: messageID)
            }
        case .retry(let thread):
            choices[id] = nil
            await clearButtons(chatID: chatID, messageID: messageID)
            let lane = "\(chatID)"
            let previous = chains[lane]
            chains[lane] = Task { [weak self] in
                await previous?.value
                guard let self, let model = self.model,
                      let (landed, seed) = model.retryTelegramRound(threadID: thread) else { return }
                self.setThread(landed, chat: chatID)
                let awake = Awake(.answering)
                defer { withExtendedLifetime(awake) {} }
                await self.call("sendChatAction", ["chat_id": chatID, "action": "typing"])
                await self.stream(thread: landed, seedIDs: seed, chatID: chatID, replyTo: messageID)
            }
        case .undo(let capture):
            choices[id] = nil
            model?.undoTurnCapture(capture)
            await clearButtons(chatID: chatID, messageID: messageID)
        }
    }

    /// Under a settled answer: Continue on a cut-off one and Undo on a memory
    /// change, as the notch shows them; then the suggested next question once
    /// it is ready (`NotchModel.nextQuestions`), which the notch puts in the
    /// follow-up field.
    fileprivate func offerButtons(after turn: NotchModel.Turn, thread: UUID, chatID: Int64, messageID: Int) {
        var rows: [(UUID, String)] = []
        if turn.isError {
            let id = UUID()
            choices[id] = .retry(thread: thread)
            rows.append((id, L("error.retry")))
        }
        if turn.interrupted {
            let id = UUID()
            choices[id] = .resume(thread: thread, turn: turn.id)
            rows.append((id, L("result.continue")))
        }
        for capture in turn.captures where capture.kind == .memory {
            let id = UUID()
            choices[id] = .undo(capture)
            rows.append((id, L("agent.process.undo")))
        }
        let turnText = turn.text
        Task { [weak self] in
            guard let self else { return }
            let pageButtons = await self.pageWebAppButtons(in: turnText)
            @MainActor func markup(_ rows: [(UUID, String)]) -> [String: Any] {
                let callbackRows: [[[String: Any]]] = rows.filter { self.choices[$0.0] != nil }.map { row in
                    [["text": row.1, "callback_data": "pick|\(row.0.uuidString)|0"]]
                }
                return ["inline_keyboard": pageButtons + callbackRows]
            }
            if !rows.isEmpty || !pageButtons.isEmpty {
                await self.call("editMessageReplyMarkup", ["chat_id": chatID, "message_id": messageID,
                                                           "reply_markup": markup(rows)])
            }
            guard let model = self.model, model.suggestFollowUpEnabled,
                  !turn.interrupted, !turn.isError else { return }
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                // A newer round on the thread makes the suggestion stale.
                if model.liveThread(thread) != nil { return }
                guard let question = model.nextQuestions[turn.id] else { continue }
                let id = UUID()
                self.choices[id] = .followUp(question: question)
                await self.call("editMessageReplyMarkup", ["chat_id": chatID, "message_id": messageID,
                                                           "reply_markup": markup(rows + [(id, question)])])
                return
            }
        }
    }

    private func offerIntervals(prompt: String, chatID: Int64, replyTo: Int) async {
        let id = UUID()
        choices[id] = .intervals(prompt: prompt)
        await call("sendMessage", ["chat_id": chatID, "text": L("loop.chip.help"),
                                   "reply_to_message_id": replyTo,
                                   "reply_markup": keyboard(id, LoopInterval.presets.map {
                                       L("loop.every", LoopInterval.short($0))
                                   })])
    }

    private func offerActions(input: String?, chatID: Int64, replyTo: Int) async {
        let actions = PromptShortcutStore.current.filter(\.isReady)
        guard !actions.isEmpty else {
            await call("sendMessage", ["chat_id": chatID, "text": L("telegram.actions.empty"),
                                       "reply_to_message_id": replyTo])
            return
        }
        let id = UUID()
        choices[id] = .actions(ids: actions.map(\.id), input: input, replyTo: replyTo)
        await call("sendMessage", ["chat_id": chatID, "text": L("shortcuts.promptAction"),
                                   "reply_to_message_id": replyTo,
                                   "reply_markup": keyboard(id, actions.map(\.displayName))])
    }

    /// A text action's request, built as the notch builds it for a line
    /// typed under a `/`-picked action.
    fileprivate static func actionQuestion(_ action: PromptShortcut, input: String) -> String {
        """
        \(action.prompt.trimmingCharacters(in: .whitespacesAndNewlines))

        <selected_text>
        \(input)
        </selected_text>
        """
    }

    // MARK: Agent

    /// `/code`: the task runs on the agent the Agent pill has armed, in its
    /// folder; with no folder set yet, the recent ones are offered.
    private func startAgentFlow(task: String, chatID: Int64, replyTo: Int) async {
        guard let model else { return }
        guard model.telegramAgentArming != nil else {
            await call("sendMessage", ["chat_id": chatID, "text": L("telegram.agent.none"),
                                       "reply_to_message_id": replyTo])
            return
        }
        if let folder = model.telegramArmedAgentFolder {
            await startAgent(task: task, folder: folder, chatID: chatID, replyTo: replyTo, statusID: nil)
            return
        }
        let folders = model.telegramAgentFolders
        guard !folders.isEmpty else {
            await call("sendMessage", ["chat_id": chatID, "text": L("telegram.agent.noFolder"),
                                       "reply_to_message_id": replyTo])
            return
        }
        let id = UUID()
        choices[id] = .folders(task: task, folders: folders, replyTo: replyTo)
        await call("sendMessage", ["chat_id": chatID, "text": L("agent.folder.choose"),
                                   "reply_to_message_id": replyTo,
                                   "reply_markup": keyboard(id, folders.map(\.lastPathComponent))])
    }

    private func startAgent(task: String, folder: URL, chatID: Int64, replyTo: Int, statusID: Int?) async {
        guard let arming = model?.telegramAgentArming else { return }
        AgentModelMRU.record(engine: arming.engine, model: arming.model)
        AgentFolderMRU.record(folder)
        guard let taskID = AgentTaskManager.shared.start(folder: folder, prompt: task, engine: arming.engine,
                                                         model: arming.model, effort: arming.effort) else {
            await call("sendMessage", ["chat_id": chatID, "text": L("telegram.failed"),
                                       "reply_to_message_id": replyTo])
            return
        }
        let header = L("telegram.agent.working", arming.engine.displayName, folder.lastPathComponent)
        await followAgent(taskID: taskID, header: header, chatID: chatID, replyTo: replyTo, statusID: statusID)
    }

    /// A reply to an agent report: the next round of the same session.
    fileprivate func continueAgent(taskID: UUID, prompt: String, chatID: Int64, replyTo: Int) async {
        guard let task = AgentTaskManager.shared.tasks.first(where: { $0.id == taskID }) else { return }
        AgentTaskManager.shared.followUp(taskID: taskID, prompt: prompt)
        let header = L("telegram.agent.working", task.engine.displayName, task.folder.lastPathComponent)
        await followAgent(taskID: taskID, header: header, chatID: chatID, replyTo: replyTo, statusID: nil)
    }

    /// One status message showing the run's latest activity line, as the
    /// task card does, then the report as the answer.
    private func followAgent(taskID: UUID, header: String, chatID: Int64, replyTo: Int, statusID: Int?) async {
        let awake = Awake(.answering)
        defer { withExtendedLifetime(awake) {} }
        var status = statusID
        if let status {
            await call("editMessageText", ["chat_id": chatID, "message_id": status, "text": header])
        } else {
            status = Self.messageID(await call("sendMessage", ["chat_id": chatID, "text": header,
                                                               "reply_to_message_id": replyTo]))
        }
        if let status { agentReports["\(chatID):\(status)"] = taskID }
        var shown = ""
        var ticks = 0
        while true {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            ticks += 1
            guard let task = AgentTaskManager.shared.tasks.first(where: { $0.id == taskID }),
                  task.isRunning else { break }
            let line = (task.activity ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if ticks % 3 == 0, line != shown, let status {
                shown = line
                await call("editMessageText", ["chat_id": chatID, "message_id": status,
                                               "text": line.isEmpty ? header : header + "\n" + line])
            }
            if ticks % 4 == 0 { await call("sendChatAction", ["chat_id": chatID, "action": "typing"]) }
        }
        if let status, !shown.isEmpty {
            await call("editMessageText", ["chat_id": chatID, "message_id": status, "text": header])
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
            // Dismissed already: the record it left in Recent.
            report = model?.history.first(where: { $0.id == taskID })?.conversation
                .last(where: { $0.role == "assistant" })?.text ?? ""
        }
        let (withoutVisuals, charts) = Self.renderVisuals(report)
        let (text, photos) = Self.localImages(withoutVisuals)
        let rawBody = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = rawBody.isEmpty ? "" : await PagesService.shared.rewriteWithAccessKeys(in: rawBody)
        guard !body.isEmpty || !(photos + charts).isEmpty else {
            await call("sendMessage", ["chat_id": chatID, "text": L("telegram.failed"),
                                       "reply_to_message_id": status ?? replyTo])
            return
        }
        let pageButtons = await pageWebAppButtons(in: report)
        let parts = body.isEmpty ? [] : Self.split(body)
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            var params: [String: Any] = ["chat_id": chatID, "text": TelegramFormat.html(part),
                                         "parse_mode": "HTML", "disable_web_page_preview": true,
                                         "reply_to_message_id": status ?? replyTo]
            if isLast && !pageButtons.isEmpty {
                params["reply_markup"] = ["inline_keyboard": pageButtons]
            }
            var result = await call("sendMessage", params)
            if result["ok"] as? Bool != true {
                var fallback: [String: Any] = ["chat_id": chatID, "text": part]
                if isLast && !pageButtons.isEmpty {
                    fallback["reply_markup"] = ["inline_keyboard": pageButtons]
                }
                result = await call("sendMessage", fallback)
            }
            if let id = Self.messageID(result) { agentReports["\(chatID):\(id)"] = taskID }
        }
        for picture in photos + charts {
            let result = await sendPhoto(picture, chatID: chatID)
            if let id = Self.messageID(result) { agentReports["\(chatID):\(id)"] = taskID }
        }
        for chart in charts { try? FileManager.default.removeItem(at: chart) }
    }

    // MARK: Answer extras

    static func captureLabel(_ capture: NotchModel.Turn.Capture) -> String {
        CaptureLineLink.label(for: capture.kind)
    }

    fileprivate static func uniqued(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }

    /// The pages an answer read, one per site as the notch's reading list
    /// shows them, folded under a heading.
    fileprivate static func sourcesHTML(_ sources: [WebSource]) -> String {
        var seen = Set<String>()
        let rows = sources.filter { seen.insert($0.host).inserted }.prefix(10).map { source -> String in
            let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return "<a href=\"\(TelegramFormat.escape(source.url))\">"
                + TelegramFormat.escape(title.isEmpty ? source.host : title) + "</a>"
        }
        guard !rows.isEmpty else { return "" }
        return "<blockquote expandable><b>" + TelegramFormat.escape(L("telegram.sources")) + "</b>\n"
            + rows.joined(separator: "\n") + "</blockquote>"
    }

    /// Charts and cards (`VisualBlocks`) drawn as the notch draws them, as PNG
    /// files to send as photos. A block that does not parse keeps the line
    /// saying where to see it.
    static func renderVisuals(_ text: String) -> (text: String, files: [URL]) {
        var out: [String] = []
        var files: [URL] = []
        var language: String?
        var body: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if language == nil, trimmed.hasPrefix("```") {
                let tag = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                if VisualSpecParser.languages.contains(tag) {
                    language = tag
                    body = []
                    continue
                }
            }
            if let tag = language {
                if trimmed == "```" {
                    language = nil
                    if let spec = VisualSpecParser.parse(body.joined(separator: "\n"), language: tag),
                       let file = png(of: spec) {
                        files.append(file)
                    } else {
                        out.append(L("telegram.visual"))
                    }
                } else {
                    body.append(line)
                }
                continue
            }
            out.append(line)
        }
        return (out.joined(separator: "\n"), files)
    }

    private static func png(of spec: VisualSpec) -> URL? {
        let view = VisualBlockView(spec: spec)
            .frame(width: 340, alignment: .leading)
            .padding(16)
            .background(Color(nsColor: NSColor(white: 0.1, alpha: 1)))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        guard let cg = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchi-chart-\(UUID().uuidString).png")
        guard (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}
