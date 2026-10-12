import Foundation
import Carbon.OpenScripting   // kASAppleScriptSuite / kASSubroutineEvent / keyASSubroutineName

/// Why an error happened writing to Notes, so the record view can show the right
/// recovery hint (grant Automation access vs. a generic retry) instead of a raw
/// AppleScript code.
enum NotesError: LocalizedError {
    /// TCC denied Automation access to Notes (or the user clicked "Don't Allow").
    case permissionDenied
    /// Notes.app couldn't be reached / launched.
    case notesUnavailable
    /// Anything else, carrying the raw AppleScript message for debugging.
    case scriptError(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return L("notes.error.permission")
        case .notesUnavailable:
            return L("notes.error.unavailable")
        case .scriptError(let msg):
            return msg
        }
    }
}

/// Writes typed lines straight into Apple's native Notes app.
///
/// One note per submit: the user's text becomes a new note in the default
/// account's "Notes" folder, with the first line as the title (Notes' own
/// behaviour when only `body` is set).
///
/// The user's text is **never** interpolated into the AppleScript source — it's
/// passed to a named handler as an Apple Event parameter (the injection-safe,
/// "parameterised query" pattern), so quotes / newlines / `¬` in what the user
/// types can't break or hijack the script.
///
/// **Threading — why this runs OFF the main thread.** `executeAppleEvent` blocks
/// the calling thread until the script returns. On the *first* write, macOS shows
/// the TCC "wants access to control Notes" prompt — a modal that needs the **main
/// runloop** to handle the user's click. If we block the main thread inside
/// `executeAppleEvent`, the prompt can paint but never receives the click: the
/// main thread waits on the script, the script waits on the user, the user's
/// click waits on the main thread → the whole app deadlocks (the freeze seen when
/// the permission dialog appeared). So the script runs on a dedicated **serial**
/// background queue, leaving the main runloop free to drive the prompt. The
/// `NSAppleScript` "not thread-safe" caveat is satisfied because the instance is
/// created on, and only ever touched from, that one serial queue — never shared
/// across threads, never run concurrently.
enum NotesService {
    /// A dedicated serial queue that owns the script. Serial = at most one write
    /// at a time, so the single `NSAppleScript` instance is never used concurrently.
    private static let queue = DispatchQueue(label: "com.notchglass.notes-applescript")

    /// The compiled script, created and used **only** on `queue`. Lazily built on
    /// the first write so we don't pay the compile cost at launch. `nil` if it
    /// failed to compile.
    private static var _script: NSAppleScript?
    private static var compiled = false

    /// Compile (once) and return the script. MUST be called on `queue`.
    private static func scriptOnQueue() -> NSAppleScript? {
        if compiled { return _script }
        compiled = true
        // Two handlers: one creates a note and **returns its id** so the record
        // row can jump back to it later; one shows an existing note by that id.
        //
        // `make new note` returns the new note object, whose `id` is a stable
        // `x-coredata://…/ICNote/p<rowid>` string. We hand that id straight back —
        // it's all `show` needs to reveal the exact note. (We deliberately do NOT
        // go the `applenotes:note/<UUID>` URL route: that UUID lives only in
        // NoteStore.sqlite, which is unreadable without Full Disk Access — a
        // disproportionate permission for a notch utility. `show` needs neither
        // FDA nor sqlite, just the Automation grant the app already has.)
        //
        // Notes' `body` is HTML, so the Swift side escapes the text and turns
        // newlines into <br> before this ever sees it. Setting only `body`
        // (no `name`) makes Notes use the first line as the title automatically.
        // Note target, in order of preference:
        //   1. The default account's *first* folder — robust against the top-level
        //      folder being localized ("备忘录" on a zh system) or not literally
        //      named "Notes". Hard-coding `folder "Notes"` was the main source of
        //      the intermittent "AppleEvent handler failed" (-10000): on iCloud
        //      accounts that reference often doesn't resolve, and it momentarily
        //      vanishes mid-sync.
        //   2. If that fails (no account/folder ready, e.g. mid-launch or mid-sync),
        //      create the note **unanchored** — `make new note with properties …`
        //      lets Notes file it in its own default location. This is the path that
        //      survives the transient states that used to throw.
        let source = """
        on notchCreateNote(noteBody)
            tell application "Notes"
                try
                    set targetFolder to folder 1 of default account
                    set newNote to make new note at targetFolder with properties {body:noteBody}
                on error
                    set newNote to make new note with properties {body:noteBody}
                end try
                return id of newNote
            end tell
        end notchCreateNote

        on notchShowNote(noteID)
            tell application "Notes"
                activate
                show (note id noteID)
            end tell
        end notchShowNote

        on notchNoteIndex(query)
            tell application "Notes"
                if query is "" then
                    return {id of every note, name of every note, modification date of every note}
                end if
                set found to (every note whose name contains query or plaintext contains query)
                set theIDs to {}
                set theNames to {}
                set theDates to {}
                repeat with n in found
                    set end of theIDs to id of n
                    set end of theNames to name of n
                    set end of theDates to modification date of n
                end repeat
                return {theIDs, theNames, theDates}
            end tell
        end notchNoteIndex

        on notchNoteText(noteID)
            tell application "Notes"
                return plaintext of note id noteID
            end tell
        end notchNoteText

        on notchAppendToNote(noteID, html)
            tell application "Notes"
                set body of note id noteID to (body of note id noteID) & html
            end tell
        end notchAppendToNote

        on notchDeleteNote(noteID)
            tell application "Notes"
                delete note id noteID
            end tell
        end notchDeleteNote
        """
        let s = NSAppleScript(source: source)
        s?.compileAndReturnError(nil)
        _script = s
        return s
    }

    /// Create a new note from `text`, off the main thread, then call `completion`
    /// back **on the main thread** with the outcome. Safe to call from the main
    /// thread (it won't block it — that's the whole point: see the type comment).
    ///
    /// On success the value is the new note's stable `id` (an `x-coredata://…`
    /// string), so the caller can store it on the history row and later jump back
    /// to that exact note via `showNote`. Empty input is a no-op success with no
    /// id (nothing was created).
    static func writeNote(_ text: String, completion: @escaping @MainActor (Result<String?, NotesError>) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Nothing to write — treat an empty submit as a (no-op) success.
            Task { @MainActor in completion(.success(nil)) }
            return
        }
        let body = htmlBody(from: trimmed)

        queue.async {
            let result = runWrite(body: body)
            // Hop back to the main actor to touch any UI/model state.
            Task { @MainActor in completion(result) }
        }
    }

    /// Bring Notes forward and reveal the note with `id` (the value `writeNote`
    /// handed back), then call `completion` on the main thread with whether the
    /// jump landed. `false` means the `show` failed — a stale id (note deleted in
    /// Notes, or a Core Data id from another device after iCloud sync), Automation
    /// access revoked, etc. — so the caller can fall back to opening Notes' main
    /// window instead of leaving the user staring at an unchanged screen. Runs off
    /// the main thread for the same deadlock-avoidance reason as `writeNote`.
    static func showNote(id: String, completion: @escaping @MainActor (Bool) -> Void) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Task { @MainActor in completion(false) }
            return
        }
        queue.async {
            guard let script = scriptOnQueue() else {
                Task { @MainActor in completion(false) }
                return
            }
            let event = subroutineEvent(named: "notchshownote", arg: trimmed)
            var error: NSDictionary?
            script.executeAppleEvent(event, error: &error)
            // `show` throws inside Notes for a missing note (≈ -1728) — surface that
            // as a failed jump so the caller can open the app instead.
            let ok = (error == nil)
            Task { @MainActor in completion(ok) }
        }
    }

    /// One note as `read_notes` returns it.
    struct NoteText: Sendable {
        let title: String
        let modified: Date?
        let text: String
    }

    /// The most recently edited notes, or those whose title or text contains
    /// `query`, newest first, with their plain text. Runs on `queue` like the
    /// writes; the first call may raise the Automation prompt for Notes.
    static func readNotes(query: String, limit: Int) async -> Result<[NoteText], NotesError> {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: readOnQueue(query: query, limit: limit)) }
        }
    }

    private static func readOnQueue(query: String, limit: Int) -> Result<[NoteText], NotesError> {
        guard let script = scriptOnQueue() else {
            return .failure(.scriptError("Couldn't prepare the Notes script."))
        }
        var error: NSDictionary?
        let index = script.executeAppleEvent(subroutineEvent(named: "notchnoteindex", arg: query),
                                             error: &error)
        if let error { return .failure(mapError(error)) }
        guard index.numberOfItems == 3,
              let ids = index.atIndex(1), let names = index.atIndex(2),
              let dates = index.atIndex(3) else { return .success([]) }
        var rows: [(id: String, title: String, modified: Date?)] = []
        let count = ids.numberOfItems
        if count > 0 {
            for i in 1...count {
                guard let id = ids.atIndex(i)?.stringValue else { continue }
                rows.append((id, names.atIndex(i)?.stringValue ?? "", dates.atIndex(i)?.dateValue))
            }
        }
        rows.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        var out: [NoteText] = []
        for row in rows.prefix(limit) {
            var textError: NSDictionary?
            let text = script.executeAppleEvent(subroutineEvent(named: "notchnotetext", arg: row.id),
                                                error: &textError).stringValue ?? ""
            out.append(NoteText(title: row.title, modified: row.modified, text: text))
        }
        return .success(out)
    }

    /// Notes whose title or text contains `query`, newest first, with ids,
    /// for `edit_note` to pick one.
    static func findNotes(query: String) async -> Result<[(id: String, title: String)], NotesError> {
        await withCheckedContinuation { cont in
            queue.async {
                guard let script = scriptOnQueue() else {
                    return cont.resume(returning: .failure(.scriptError("Couldn't prepare the Notes script.")))
                }
                var error: NSDictionary?
                let index = script.executeAppleEvent(subroutineEvent(named: "notchnoteindex", arg: query),
                                                     error: &error)
                if let error { return cont.resume(returning: .failure(mapError(error))) }
                guard index.numberOfItems == 3, let ids = index.atIndex(1), let names = index.atIndex(2),
                      let dates = index.atIndex(3), ids.numberOfItems > 0 else {
                    return cont.resume(returning: .success([]))
                }
                var rows: [(id: String, title: String, date: Date)] = []
                for i in 1...ids.numberOfItems {
                    guard let id = ids.atIndex(i)?.stringValue else { continue }
                    rows.append((id, names.atIndex(i)?.stringValue ?? "",
                                 dates.atIndex(i)?.dateValue ?? .distantPast))
                }
                rows.sort { $0.date > $1.date }
                cont.resume(returning: .success(rows.map { ($0.id, $0.title) }))
            }
        }
    }

    /// Append a line (e.g. `#工作`) to a note, or delete the note.
    static func edit(noteID: String, appendLine line: String?) async -> Result<Void, NotesError> {
        await withCheckedContinuation { cont in
            queue.async {
                guard let script = scriptOnQueue() else {
                    return cont.resume(returning: .failure(.scriptError("Couldn't prepare the Notes script.")))
                }
                let event = line.map {
                    subroutineEvent(named: "notchappendtonote",
                                    args: [noteID, "<div>\(htmlBody(from: $0))</div>"])
                } ?? subroutineEvent(named: "notchdeletenote", arg: noteID)
                var error: NSDictionary?
                script.executeAppleEvent(event, error: &error)
                cont.resume(returning: error.map { .failure(mapError($0)) } ?? .success(()))
            }
        }
    }

    /// The actual Apple Event send for note creation. Runs on `queue`. Returns the
    /// new note's id on success (or `nil` if Notes returned no usable id string —
    /// treated as a soft success: the note exists, we just can't deep-link it).
    private static func runWrite(body: String) -> Result<String?, NotesError> {
        guard let script = scriptOnQueue() else {
            return .failure(.scriptError("Couldn't prepare the Notes script."))
        }

        // Build the Apple Event that calls `notchCreateNote(body)` on the script
        // itself, passing the body as a string parameter — user text travels as
        // structured Apple Event data, not as script source.
        let event = subroutineEvent(named: "notchcreatenote", arg: body)

        var error: NSDictionary?
        var result = script.executeAppleEvent(event, error: &error)

        // A generic "AppleEvent handler failed" (-10000) is usually transient —
        // Notes was mid-launch or mid-iCloud-sync when the event landed. Pause
        // briefly and try exactly once more before giving up; a stuck permission
        // (-1743/-1744) or a missing target won't be retried by mapError's
        // classification, only this generic case is.
        if let firstError = error, (firstError[NSAppleScript.errorNumber] as? Int) == -10000 {
            Thread.sleep(forTimeInterval: 0.6)
            error = nil
            result = script.executeAppleEvent(event, error: &error)
        }

        if let error { return .failure(mapError(error)) }
        // The handler returns `id of newNote`; pull it out as the deep-link token.
        // An empty/absent string is fine — the note was still created.
        let noteID = result.stringValue
        return .success((noteID?.isEmpty == false) ? noteID : nil)
    }

    /// Build the subroutine-call Apple Event for `handler(arg)`. Handler names
    /// must be lowercase for the subroutine-call convention; user/data text rides
    /// as a structured string parameter, never interpolated into script source.
    private static func subroutineEvent(named handler: String, arg: String) -> NSAppleEventDescriptor {
        subroutineEvent(named: handler, args: [arg])
    }

    private static func subroutineEvent(named handler: String, args values: [String]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,                          // the script itself
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: handler),
                       forKeyword: AEKeyword(keyASSubroutineName))
        let args = NSAppleEventDescriptor.list()
        for (i, value) in values.enumerated() {
            args.insert(NSAppleEventDescriptor(string: value), at: i + 1)
        }
        event.setParam(args, forKeyword: keyDirectObject)
        return event
    }

    // MARK: - Helpers

    /// Map an AppleScript error dictionary onto a typed `NotesError`, so the UI can
    /// tell "you need to grant permission" apart from a transient failure.
    private static func mapError(_ dict: NSDictionary) -> NotesError {
        let number = dict[NSAppleScript.errorNumber] as? Int ?? 0
        let message = dict[NSAppleScript.errorMessage] as? String ?? "Couldn't save to Notes."
        switch number {
        case -1743, -1744:           // errAEEventNotPermitted / not authorised → TCC denied
            return .permissionDenied
        case -600, -609, -1708:      // procNotFound / connectionInvalid / event not handled
            return .notesUnavailable
        default:
            return .scriptError(message)
        }
    }

    /// Turn plain text into the HTML body Notes expects: escape the markup-significant
    /// characters so the literal text shows through, and convert newlines to `<br>`
    /// (a bare `\n` is swallowed by the HTML body). Order matters — `&` first, so we
    /// don't double-escape the entities we introduce.
    private static func htmlBody(from text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "&", with: "&amp;")
        s = s.replacingOccurrences(of: "<", with: "&lt;")
        s = s.replacingOccurrences(of: ">", with: "&gt;")
        s = s.replacingOccurrences(of: "\r\n", with: "<br>")
        s = s.replacingOccurrences(of: "\r", with: "<br>")
        s = s.replacingOccurrences(of: "\n", with: "<br>")
        return s
    }
}
