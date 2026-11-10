import Carbon.OpenScripting   // kASAppleScriptSuite / kASSubroutineEvent / keyASSubroutineName
import Foundation

/// Reads the user's Mail inbox and saves reply drafts, through AppleScript —
/// for `read_mail` and `draft_mail`. Nothing is ever sent: a draft is saved
/// to Drafts for the user to review and send. Same queue discipline as
/// `NotesService`: one compiled script, used only on its own serial queue, so
/// the Automation prompt the first call raises can be answered.
enum MailService {
    private static let queue = DispatchQueue(label: "com.notchglass.mail-applescript")
    private static var _script: NSAppleScript?
    private static var compiled = false

    struct Header: Sendable {
        let id: String
        let date: String
        let sender: String
        let subject: String
        /// For a message found by its body: the text around the match.
        var snippet: String = ""
    }

    struct Message: Sendable {
        let sender: String
        let subject: String
        let date: String
        let content: String
    }

    enum MailError: LocalizedError {
        case permissionDenied
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Notchi is not allowed to use Mail. The user can allow it in System Settings → Privacy & Security → Automation."
            case .failed(let message): return message
            }
        }
    }

    private static func scriptOnQueue() -> NSAppleScript? {
        if compiled { return _script }
        compiled = true
        let source = """
        -- Every handler first narrows the inbox to a date window with one
        -- `whose date received >` query, then reads the few messages in it one
        -- by one. Mail answers one Apple event at a time and keeps working on a
        -- query after its caller gives up, so a condition Mail has to test on
        -- every message (`read status is false`, `content contains`) across an
        -- 11,000-message inbox held it for minutes, and every Mail call after it
        -- timed out too (2026-11-09). Measured on that inbox: a one-day window is
        -- 35 messages and about 5 s, the first call after launch up to 30 s.
        on notchMailList(mode, query, limitText, daysText)
            set maxCount to limitText as integer
            if mode is "unread" then
                set cutoff to (current date) - (7 * days)
            else
                set cutoff to (current date) - ((daysText as integer) * days)
            end if
            tell application "Mail"
                set recent to (messages of inbox whose date received > cutoff)
                set out to {}
                set seen to {}
                set n to 0
                set scanned to 0
                repeat with m in recent
                    if n ≥ maxCount or scanned ≥ 800 then exit repeat
                    set scanned to scanned + 1
                    if mode is "unread" then
                        set keep to (read status of m is false)
                    else
                        set keep to ((sender of m) contains query or (subject of m) contains query)
                    end if
                    if keep then
                        set n to n + 1
                        set end of seen to (id of m)
                        set end of out to {(id of m) as string, (date received of m) as string, sender of m, subject of m, ""}
                    end if
                end repeat
                -- The text of at most 200 messages from the last 14 days.
                if mode is "search" and n < maxCount then
                    set bodyCutoff to (current date) - (14 * days)
                    set scanned to 0
                    repeat with m in recent
                        if n ≥ maxCount or scanned ≥ 200 then exit repeat
                        if (date received of m) < bodyCutoff then exit repeat
                        set scanned to scanned + 1
                        if (id of m) is not in seen then
                            set body to content of m
                            if body contains query then
                                set n to n + 1
                                set end of out to {(id of m) as string, (date received of m) as string, sender of m, subject of m, my snippet(body, query)}
                            end if
                        end if
                    end repeat
                end if
                return out
            end tell
        end notchMailList

        -- Messages from the last `minutesText` minutes with their text, for a
        -- code a site just sent.
        on notchMailRecent(minutesText, limitText)
            set maxCount to limitText as integer
            set cutoff to (current date) - ((minutesText as integer) * minutes)
            tell application "Mail"
                set recent to (messages of inbox whose date received > cutoff)
                set out to {}
                repeat with m in recent
                    if (count of out) ≥ maxCount then exit repeat
                    set body to content of m
                    if (length of body) > 4000 then set body to text 1 thru 4000 of body
                    set end of out to {(id of m) as string, (date received of m) as string, sender of m, subject of m, body}
                end repeat
                return out
            end tell
        end notchMailRecent

        on snippet(body, query)
            set o to offset of query in body
            if o is 0 then return ""
            set a to o - 80
            if a < 1 then set a to 1
            set b to o + (length of query) + 80
            if b > (length of body) then set b to length of body
            return text a thru b of body
        end snippet

        -- A lookup by id is one query Mail answers from its index: about 9 s on
        -- that inbox, faster than walking even three days of messages (36 s).
        on notchMailRead(messageID)
            tell application "Mail"
                set m to first message of inbox whose id is (messageID as integer)
                return {sender of m, subject of m, (date received of m) as string, content of m}
            end tell
        end notchMailRead

        on notchMailDraft(toAddress, subjectText, bodyText, replyID)
            tell application "Mail"
                if replyID is not "" then
                    set original to first message of inbox whose id is (replyID as integer)
                    set draft to reply original opening window false
                    set content of draft to bodyText & return & return & (content of draft)
                else
                    set draft to make new outgoing message with properties {subject:subjectText, content:bodyText, visible:false}
                    if toAddress is not "" then
                        tell draft to make new to recipient at end of to recipients with properties {address:toAddress}
                    end if
                end if
                save draft
                return "saved"
            end tell
        end notchMailDraft
        """
        let script = NSAppleScript(source: source)
        script?.compileAndReturnError(nil)
        _script = script
        return script
    }

    /// When the call now running in Mail started. A second call while one runs
    /// would only queue behind it in Mail and time out, so it returns at once.
    private static let busyLock = NSLock()
    private static var busySince: Date?

    private static func call(_ handler: String, _ args: [String]) async -> Result<NSAppleEventDescriptor, MailError> {
        busyLock.lock()
        if let since = busySince {
            busyLock.unlock()
            let seconds = Int(Date().timeIntervalSince(since))
            return .failure(.failed("Mail is still answering an earlier request (\(seconds) s so far). Wait for it instead of calling again; a new call would only queue behind it."))
        }
        busySince = Date()
        busyLock.unlock()
        defer {
            busyLock.lock()
            busySince = nil
            busyLock.unlock()
        }
        return await withCheckedContinuation { cont in
            queue.async {
                guard let script = scriptOnQueue() else {
                    return cont.resume(returning: .failure(.failed("Couldn't prepare the Mail script.")))
                }
                let event = NSAppleEventDescriptor.appleEvent(
                    withEventClass: AEEventClass(kASAppleScriptSuite),
                    eventID: AEEventID(kASSubroutineEvent),
                    targetDescriptor: nil,
                    returnID: AEReturnID(kAutoGenerateReturnID),
                    transactionID: AETransactionID(kAnyTransactionID))
                event.setParam(NSAppleEventDescriptor(string: handler.lowercased()),
                               forKeyword: AEKeyword(keyASSubroutineName))
                let list = NSAppleEventDescriptor.list()
                for (i, arg) in args.enumerated() { list.insert(NSAppleEventDescriptor(string: arg), at: i + 1) }
                event.setParam(list, forKeyword: keyDirectObject)
                var error: NSDictionary?
                // May raise the Automation prompt for Mail: hold the panel.
                let result = PermissionPromptGate.automating("com.apple.mail") {
                    script.executeAppleEvent(event, error: &error)
                }
                if let error {
                    let number = error[NSAppleScript.errorNumber] as? Int ?? 0
                    if number == -1743 || number == -1744 { return cont.resume(returning: .failure(.permissionDenied)) }
                    return cont.resume(returning: .failure(.failed(error[NSAppleScript.errorMessage] as? String ?? "Mail did not answer.")))
                }
                cont.resume(returning: .success(result))
            }
        }
    }

    /// Unread inbox messages, or those whose sender or subject contains
    /// `query`, then messages from the last `days` days whose body does.
    static func list(unread: Bool, query: String, limit: Int, days: Int = 30) async -> Result<[Header], MailError> {
        switch await call("notchMailList", [unread ? "unread" : "search", query, String(limit), String(days)]) {
        case .failure(let error): return .failure(error)
        case .success(let list):
            guard list.numberOfItems > 0 else { return .success([]) }
            return .success((1...list.numberOfItems).compactMap { i in
                guard let row = list.atIndex(i), row.numberOfItems >= 4 else { return nil }
                return Header(id: row.atIndex(1)?.stringValue ?? "", date: row.atIndex(2)?.stringValue ?? "",
                              sender: row.atIndex(3)?.stringValue ?? "", subject: row.atIndex(4)?.stringValue ?? "",
                              snippet: row.numberOfItems >= 5 ? row.atIndex(5)?.stringValue ?? "" : "")
            })
        }
    }

    struct Recent: Sendable {
        let header: Header
        let body: String
    }

    /// Messages received in the last `minutes` minutes, newest first, with up
    /// to 4,000 characters of each one's text.
    static func recent(minutes: Int, limit: Int) async -> Result<[Recent], MailError> {
        switch await call("notchMailRecent", [String(minutes), String(limit)]) {
        case .failure(let error): return .failure(error)
        case .success(let list):
            guard list.numberOfItems > 0 else { return .success([]) }
            return .success((1...list.numberOfItems).compactMap { i in
                guard let row = list.atIndex(i), row.numberOfItems >= 5 else { return nil }
                let header = Header(id: row.atIndex(1)?.stringValue ?? "", date: row.atIndex(2)?.stringValue ?? "",
                                    sender: row.atIndex(3)?.stringValue ?? "", subject: row.atIndex(4)?.stringValue ?? "")
                return Recent(header: header, body: row.atIndex(5)?.stringValue ?? "")
            })
        }
    }

    /// Likely one-time codes in a message: 4 to 8 digits, or 6 to 8 letters and
    /// digits with at least two digits, standing alone. Candidates on a line
    /// with a code word come first; years and long digit runs are left out.
    static func codes(in text: String) -> [String] {
        let words = ["code", "otp", "verif", "pin", "passcode", "验证码", "校验码", "動態", "認証", "인증", "코드"]
        guard let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])([0-9]{4,8}|[A-Z0-9]{6,8})(?![A-Za-z0-9])"#) else { return [] }
        var near: [String] = []
        var other: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let lowered = line.lowercased()
            let hasWord = words.contains { lowered.contains($0) }
            for m in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let r = Range(m.range(at: 1), in: line) else { continue }
                let token = String(line[r])
                if token.filter(\.isNumber).count < 2 { continue }
                if token.count == 4, let year = Int(token), (1990...2100).contains(year) { continue }
                if hasWord { if !near.contains(token) { near.append(token) } }
                else if !other.contains(token) { other.append(token) }
            }
        }
        return near.isEmpty ? Array(other.prefix(3)) : Array(near.prefix(3))
    }

    static func read(id: String) async -> Result<Message, MailError> {
        switch await call("notchMailRead", [id]) {
        case .failure(let error): return .failure(error)
        case .success(let row):
            guard row.numberOfItems == 4 else { return .failure(.failed("No message has id \(id).")) }
            return .success(Message(sender: row.atIndex(1)?.stringValue ?? "", subject: row.atIndex(2)?.stringValue ?? "",
                                    date: row.atIndex(3)?.stringValue ?? "", content: row.atIndex(4)?.stringValue ?? ""))
        }
    }

    /// Save a draft: a reply to inbox message `replyID`, or a new message.
    static func draft(to: String, subject: String, body: String, replyID: String) async -> Result<Void, MailError> {
        switch await call("notchMailDraft", [to, subject, body, replyID]) {
        case .failure(let error): return .failure(error)
        case .success: return .success(())
        }
    }
}
