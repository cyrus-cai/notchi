import AppKit
import Foundation

/// Where a note-classified line lands: Apple Notes (the original AppleScript
/// pipeline in `NotesService`) or a folder of plain Markdown files the user
/// owns. Persisted in `UserDefaults`, edited in Settings → General; consulted
/// at each write, so flipping it never touches notes already filed — old
/// Recent rows keep their original deep links and still open where they went.
enum NoteDestination: String, CaseIterable, Identifiable {
    /// The classic behavior: notes go into Apple Notes via AppleScript. The
    /// default — zero-setup, synced by iCloud, familiar to existing users.
    case appleNotes
    /// Notes append to per-day Markdown files in a user-chosen folder — plain
    /// text the user can grep, sync (point it at iCloud Drive / an Obsidian
    /// vault), and feed to anything, with no Automation prompt at all.
    case markdownFolder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleNotes:     return L("noteDest.appleNotes")
        case .markdownFolder: return L("noteDest.folder")
        }
    }

    private static let key = "noteDestination"
    static var current: NoteDestination {
        get {
            UserDefaults.standard.string(forKey: key)
                .flatMap(NoteDestination.init) ?? .appleNotes
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}

/// Why a Markdown note write failed — a folder problem points the user at the
/// Settings picker; anything else carries the filesystem's own message.
enum FileNotesError: LocalizedError {
    /// The notes folder couldn't be created/reached (deleted volume, permission).
    case folderUnavailable
    /// The append itself failed, carrying the underlying message for display.
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .folderUnavailable:    return L("notes.file.error.folder")
        case .writeFailed(let msg): return msg
        }
    }
}

/// Writes typed lines into per-day Markdown files — the local-folder sibling of
/// `NotesService`, wearing the same async API shape so `NotchModel`'s two write
/// paths (submit + closed-notch sense) branch on `NoteDestination` and nothing
/// else changes.
///
/// **Layout: one file per day, entries appended.** A jot-per-file would just
/// move "scattered" from Notes into Finder; a day file keeps the stream of
/// quick captures readable as a page (the Obsidian daily-note convention) and
/// trivially feedable to a summarizer:
///
/// ```
/// 2026-07-11.md
///   # 2026-07-11
///
///   ## 14:32
///   buy milk
///
///   ## 15:07
///   that idea about …
/// ```
///
/// Unlike the AppleScript path there's no TCC prompt, no deadlock choreography,
/// no HTML escaping — the text lands verbatim as Markdown (which also means an
/// AI answer saved here keeps its real formatting instead of literal `**`
/// rendered by Notes). Writes still run on a serial background queue: file I/O
/// off the main thread, and serial so two rapid jots can't interleave appends.
enum FileNotesService {
    /// Serial = appends never race each other; the file grows one entry at a time.
    private static let queue = DispatchQueue(label: "com.notchglass.notes-file")

    private static let folderKey = "markdownNotesFolder"

    /// The folder that receives the day files. Defaults to ~/Documents/Notch Notes
    /// until the user picks their own (Settings → General); created on demand at
    /// each write, so deleting it never breaks the pipeline — it just comes back.
    static var folderPath: String {
        get {
            if let stored = UserDefaults.standard.string(forKey: folderKey),
               !stored.isEmpty {
                return stored
            }
            return (NSHomeDirectory() as NSString)
                .appendingPathComponent("Documents/Notch Notes")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: folderKey)
        }
    }

    /// The folder as shown in Settings — home-relative, so the row stays short.
    static var folderDisplayPath: String {
        (folderPath as NSString).abbreviatingWithTildeInPath
    }

    /// Append `text` to today's Markdown file, off the main thread, then call
    /// `completion` back **on the main thread** — the same contract as
    /// `NotesService.writeNote`, so call sites swap in without reshaping.
    ///
    /// On success the value is the day file's absolute path — stored on the
    /// history row as its deep link, so "open in app" can reveal the exact file
    /// (distinguished from Apple Notes links by not starting with `x-coredata://`).
    /// Empty input is a no-op success with no path (nothing was written).
    static func writeNote(_ text: String, completion: @escaping @MainActor (Result<String?, FileNotesError>) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Task { @MainActor in completion(.success(nil)) }
            return
        }
        // Read the folder on the caller's thread — UserDefaults is cheap and this
        // pins the write to the folder chosen at submit time, not at I/O time.
        let folder = folderPath
        queue.async {
            let result = appendOnQueue(trimmed, folder: folder)
            Task { @MainActor in completion(result) }
        }
    }

    /// Reveal the notes folder in Finder — the no-deep-link fallback for file-mode
    /// captures (mirrors `openApp("com.apple.Notes")` on the Apple Notes side).
    /// Creates the folder first so the jump can't dead-end on a missing target.
    static func revealFolder() {
        let folder = folderPath
        try? FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: folder, isDirectory: true))
    }

    /// The actual append. Runs on `queue`. Returns the day file's path on success.
    private static func appendOnQueue(_ text: String, folder: String) -> Result<String?, FileNotesError> {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        } catch {
            return .failure(.folderUnavailable)
        }

        let now = Date()
        let path = (folder as NSString).appendingPathComponent("\(dayStamp(now)).md")
        // A blank line before each `##` keeps the Markdown valid however the
        // previous entry ended; the trailing newline keeps the file append-clean.
        let entry = "\n## \(timeStamp(now))\n\n\(text)\n"

        if !fm.fileExists(atPath: path) {
            // First jot of the day: lead with the date heading so the file reads
            // as a page on its own (and in any Markdown editor's outline).
            let initial = "# \(dayStamp(now))\n" + entry
            do {
                try initial.write(toFile: path, atomically: true, encoding: .utf8)
            } catch {
                return .failure(.writeFailed(error.localizedDescription))
            }
            return .success(path)
        }

        guard let handle = FileHandle(forWritingAtPath: path) else {
            return .failure(.writeFailed("Couldn't open \(path)."))
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(entry.utf8))
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
        return .success(path)
    }

    // MARK: - Stamps

    /// `2026-07-11` — the filename and the `#` heading. POSIX locale so a device
    /// set to a non-Gregorian calendar can't bend the filenames; **local** time
    /// zone on purpose: "today's file" should match the user's wall clock.
    private static func dayStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// `14:32` — the per-entry `##` heading.
    private static func timeStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
