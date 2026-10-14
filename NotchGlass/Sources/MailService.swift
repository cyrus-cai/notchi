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
        on notchMailList(mode, query, limitText, daysText)
            set maxCount to limitText as integer
            tell application "Mail"
                if mode is "unread" then
                    set found to (messages of inbox whose read status is false)
                else
                    set found to (messages of inbox whose (sender contains query) or (subject contains query))
                end if
                set out to {}
                set seen to {}
                set n to 0
                repeat with m in found
                    set n to n + 1
                    if n > maxCount then exit repeat
                    set end of seen to (id of m)
                    set end of out to {(id of m) as string, (date received of m) as string, sender of m, subject of m, ""}
                end repeat
                if mode is "search" and n < maxCount then
                    set cutoff to (current date) - ((daysText as integer) * days)
                    set inBody to (messages of inbox whose date received > cutoff and content contains query)
                    repeat with m in inBody
                        if n ≥ maxCount then exit repeat
                        if (id of m) is not in seen then
                            set n to n + 1
                            set end of out to {(id of m) as string, (date received of m) as string, sender of m, subject of m, my snippet(content of m, query)}
                        end if
                    end repeat
                end if
                return out
            end tell
        end notchMailList

        on snippet(body, query)
            set o to offset of query in body
            if o is 0 then return ""
            set a to o - 80
            if a < 1 then set a to 1
            set b to o + (length of query) + 80
            if b > (length of body) then set b to length of body
            return text a thru b of body
        end snippet

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

    private static func call(_ handler: String, _ args: [String]) async -> Result<NSAppleEventDescriptor, MailError> {
        await withCheckedContinuation { cont in
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
