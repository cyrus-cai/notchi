import AppKit
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
/// A chat continues one thread until `/new`. Replying to one of the bot's
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
    /// Each chat's updates run one after another: a second message waits for
    /// the first answer instead of racing it on the same thread.
    private var chains: [Int64: Task<Void, Never>] = [:]
    /// Option buttons sent for a pending question, by the question's id.
    private var questionOptions: [UUID: [String]] = [:]
    /// An album arrives as one message per item, sharing a `media_group_id`.
    /// The items wait here until no new one has come for `albumWait`.
    private var albums: [String: [[String: Any]]] = [:]
    private var albumFlush: [String: Task<Void, Never>] = [:]
    private static let albumWait: UInt64 = 1_500_000_000

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
    /// when the lid closes (`pmset disablesleep`).
    @Published private(set) var answersWithLidClosed = UserDefaults.standard.bool(forKey: TelegramBridge.lidKey)
    @Published private(set) var lidBusy = false
    private static let lidKey = "TelegramAnswerWithLidClosed"

    private var token: String { UserDefaults.standard.string(forKey: Self.tokenKey) ?? "" }
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
        if let _ = owner {
            state = .connected(bot: bot, owner: ownerName)
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
        await call("setMyCommands", ["commands": [["command": "new", "description": L("telegram.command.new")]]])
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
    }

    // MARK: - Lid

    /// Turning it on installs the sudo rule `LidSleep` runs under and turns lid
    /// sleep off; turning it off does the reverse. Each asks for an
    /// administrator password once.
    func setAnswersWithLidClosed(_ on: Bool) async {
        guard !lidBusy, on != answersWithLidClosed else { return }
        lidBusy = true
        defer { lidBusy = false }
        let done = on ? await LidSleep.install(disableNow: pollTask != nil)
                      : await LidSleep.uninstall()
        guard done else { return }
        answersWithLidClosed = on
        UserDefaults.standard.set(on, forKey: Self.lidKey)
        LidSleep.applied = on && pollTask != nil
    }

    /// Lid sleep is off exactly while the setting is on and the bot polls.
    private func applyLidSleep() {
        let want = answersWithLidClosed && pollTask != nil
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

    private func poll() {
        guard pollTask == nil, !token.isEmpty else { return }
        pollTask = Task { [weak self] in
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

    /// `pmset -a disablesleep`, the only switch that keeps a Mac awake with
    /// the lid closed and no external display. It needs root, so turning the
    /// setting on installs one sudoers rule allowing exactly the two pmset
    /// commands without a password; after that it runs silently.
    private enum LidSleep {
        static let rulePath = "/etc/sudoers.d/notchi-lid"
        private static let appliedKey = "TelegramLidSleepDisabled"

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
        }
        guard chatID == owner else { return }
        if let group = message["media_group_id"] as? String {
            albums[group, default: []].append(message)
            albumFlush[group]?.cancel()
            albumFlush[group] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.albumWait)
                guard !Task.isCancelled, let self,
                      let items = self.albums.removeValue(forKey: group) else { return }
                self.albumFlush[group] = nil
                self.enqueue(items, chatID: chatID)
            }
            return
        }
        enqueue([message], chatID: chatID)
    }

    private func enqueue(_ messages: [[String: Any]], chatID: Int64) {
        let previous = chains[chatID]
        chains[chatID] = Task { [weak self] in
            await previous?.value
            await self?.answer(messages, chatID: chatID)
        }
    }

    /// `messages` is one message, or the items of one album in order.
    private func answer(_ messages: [[String: Any]], chatID: Int64) async {
        guard let model, let message = messages.first else { return }
        let awake = Awake(.answering)
        defer { withExtendedLifetime(awake) {} }
        let text = messages.lazy
            .compactMap { (($0["text"] ?? $0["caption"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let messageID = (message["message_id"] as? NSNumber)?.intValue ?? 0

        if text == "/new" || text.hasPrefix("/new@") {
            setThread(nil, chat: chatID)
            await call("sendMessage", ["chat_id": chatID, "text": L("telegram.newThread")])
            return
        }
        if text.hasPrefix("/start") {
            await call("sendMessage", ["chat_id": chatID, "text": L("telegram.paired")])
            return
        }

        var found = Attachments()
        for item in messages {
            let more = await attachments(of: item, chatID: chatID)
            found.images += more.images
            found.files += more.files
        }
        let images = Array(found.images.prefix(NotchModel.composeImageLimit))
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
        let question = files.isEmpty ? text : NotchModel.fileEnvelope(line: text, files: files)

        // A reply to one of the bot's messages continues that message's thread.
        var threadID = thread(for: chatID)
        if let replied = (message["reply_to_message"] as? [String: Any])?["message_id"] as? NSNumber,
           let mapped = threadForMessage(chatID: chatID, messageID: replied.intValue) {
            threadID = mapped
        }
        // A thread deleted from Recent starts over.
        if let id = threadID, !model.history.contains(where: { $0.id == id }) { threadID = nil }
        let seedIDs = Set(threadID.flatMap { id in model.history.first { $0.id == id }?.conversation.map(\.id) } ?? [])

        await call("sendChatAction", ["chat_id": chatID, "action": "typing"])
        guard let landed = model.runTelegramRound(threadID: threadID, question: question, images: images) else {
            await call("sendMessage", ["chat_id": chatID, "text": L("telegram.failed"),
                                       "reply_to_message_id": messageID])
            return
        }
        setThread(landed, chat: chatID)
        await stream(thread: landed, seedIDs: seedIDs, chatID: chatID, replyTo: messageID)
    }

    /// Follows the round once a second (Telegram's edit rate for one chat) and
    /// mirrors the answer into one message, then writes the final text with
    /// formatting. Pending questions go out as inline buttons.
    private func stream(thread: UUID, seedIDs: Set<UUID>, chatID: Int64, replyTo: Int) async {
        guard let model else { return }
        var sentID: Int?
        var lastShown = ""
        var sawLive = false
        var askedQuestions: Set<UUID> = []
        var ticks = 0
        while true {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            ticks += 1
            guard let live = model.liveThread(thread) else {
                // Not started yet: a round registers on its task's first tick.
                if !sawLive && ticks < 15 { continue }
                break
            }
            sawLive = true
            guard let answer = live.last(where: { $0.role == "assistant" && !seedIDs.contains($0.id) }) else { continue }
            if let question = answer.pendingQuestion, !askedQuestions.contains(question.id) {
                askedQuestions.insert(question.id)
                await ask(question, chatID: chatID)
            }
            let shown = Self.plain(answer.text)
            if shown.isEmpty {
                if ticks % 4 == 0 { await call("sendChatAction", ["chat_id": chatID, "action": "typing"]) }
                continue
            }
            guard shown != lastShown else { continue }
            let preview = String(shown.prefix(Self.messageLimit))
            if let sentID {
                await call("editMessageText", ["chat_id": chatID, "message_id": sentID, "text": preview])
            } else {
                let result = await call("sendMessage", ["chat_id": chatID, "text": preview,
                                                        "reply_to_message_id": replyTo])
                sentID = Self.messageID(result)
                if let sentID { remember(messageID: sentID, chatID: chatID, thread: thread) }
            }
            lastShown = shown
        }

        let final = model.history.first(where: { $0.id == thread })?.conversation
            .last(where: { $0.role == "assistant" && !seedIDs.contains($0.id) })?.text ?? ""
        let body = Self.withoutVisualBlocks(final).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            if let sentID {
                await call("editMessageText", ["chat_id": chatID, "message_id": sentID, "text": L("telegram.failed")])
            } else {
                await call("sendMessage", ["chat_id": chatID, "text": L("telegram.failed"), "reply_to_message_id": replyTo])
            }
            return
        }
        let parts = Self.split(body)
        for (index, part) in parts.enumerated() {
            let html = TelegramFormat.html(part)
            if index == 0, let sentID {
                let result = await call("editMessageText", ["chat_id": chatID, "message_id": sentID,
                                                            "text": html, "parse_mode": "HTML",
                                                            "disable_web_page_preview": true])
                if result["ok"] as? Bool != true {
                    await call("editMessageText", ["chat_id": chatID, "message_id": sentID, "text": part])
                }
                continue
            }
            var params: [String: Any] = ["chat_id": chatID, "text": html, "parse_mode": "HTML",
                                         "disable_web_page_preview": true]
            if index == 0 { params["reply_to_message_id"] = replyTo }
            var result = await call("sendMessage", params)
            if result["ok"] as? Bool != true {
                result = await call("sendMessage", ["chat_id": chatID, "text": part])
            }
            if let id = Self.messageID(result) { remember(messageID: id, chatID: chatID, thread: thread) }
        }
    }

    /// A round asked in Notchi itself (the panel, a window, a loop), sent to
    /// the owner's chat as the question quoted above the answer. The chat then
    /// continues that thread, and replying to the message does too.
    func mirror(threadID: UUID, question: String, answer: String) {
        guard case .connected = state, let owner else { return }
        let body = Self.withoutVisualBlocks(answer).trimmingCharacters(in: .whitespacesAndNewlines)
        let asked = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !body.isEmpty else { return }
        setThread(threadID, chat: owner)
        let previous = chains[owner]
        chains[owner] = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            for (index, part) in Self.split(body).enumerated() {
                let quote = index == 0 && !asked.isEmpty
                var result = await self.call("sendMessage", [
                    "chat_id": owner,
                    "text": (quote ? "<blockquote>" + TelegramFormat.escape(asked) + "</blockquote>\n" : "")
                        + TelegramFormat.html(part),
                    "parse_mode": "HTML", "disable_web_page_preview": true,
                    "disable_notification": true])
                if result["ok"] as? Bool != true {
                    result = await self.call("sendMessage", ["chat_id": owner,
                                                             "text": (quote ? "› " + asked + "\n\n" : "") + part,
                                                             "disable_notification": true])
                }
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

    private func answerCallback(_ callback: [String: Any]) async {
        guard let id = callback["id"] as? String else { return }
        await call("answerCallbackQuery", ["callback_query_id": id])
        guard let data = callback["data"] as? String else { return }
        let parts = data.split(separator: "|")
        guard parts.count == 2, let questionID = UUID(uuidString: String(parts[0])),
              let index = Int(parts[1]),
              let options = questionOptions.removeValue(forKey: questionID),
              options.indices.contains(index) else { return }
        model?.chooseUserOption(options[index], questionID: questionID)
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

    private func attachments(of message: [String: Any], chatID: Int64) async -> Attachments {
        var found = Attachments()
        func note(_ name: String, _ text: String) {
            found.files.append(NotchModel.DroppedFile(name: name, text: text))
        }

        if let photos = message["photo"] as? [[String: Any]],
           let largest = photos.last?["file_id"] as? String {
            if let image = await downloadImage(largest) {
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
    nonisolated private static func frames(of url: URL, count: Int) async -> [NSImage] {
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
    nonisolated private static func transcript(of url: URL) async -> String? {
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
        withoutVisualBlocks(text).trimmingCharacters(in: .whitespacesAndNewlines)
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
