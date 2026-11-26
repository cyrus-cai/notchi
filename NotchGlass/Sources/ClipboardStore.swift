import CryptoKit
import Foundation
import SQLite3

/// The SQLite file behind `ClipboardHistory`: one row per distinct text, with
/// a trigram full-text index so a few characters of Chinese or English find
/// it. Every call runs on one serial queue, so it is safe from any thread.
final class ClipboardStore: @unchecked Sendable {
    struct Clip: Identifiable, Equatable, Sendable {
        let id: Int64
        var text: String
        var app: String?
        var bundleID: String?
        var firstCopiedAt: Date
        var lastCopiedAt: Date
        var copyCount: Int
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.notchglass.clipboard-store")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) {
        queue.sync {
            guard sqlite3_open_v2(url.path, &db,
                                  SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                                  nil) == SQLITE_OK else {
                db = nil
                return
            }
            exec("PRAGMA journal_mode=WAL;")
            exec("""
            CREATE TABLE IF NOT EXISTS clips(
                id INTEGER PRIMARY KEY,
                text TEXT NOT NULL,
                hash TEXT NOT NULL UNIQUE,
                app TEXT,
                bundle_id TEXT,
                first_copied_at REAL NOT NULL,
                last_copied_at REAL NOT NULL,
                copy_count INTEGER NOT NULL DEFAULT 1);
            CREATE INDEX IF NOT EXISTS clips_last ON clips(last_copied_at);
            CREATE VIRTUAL TABLE IF NOT EXISTS clips_fts
                USING fts5(text, content='clips', content_rowid='id', tokenize='trigram');
            CREATE TRIGGER IF NOT EXISTS clips_ai AFTER INSERT ON clips BEGIN
                INSERT INTO clips_fts(rowid, text) VALUES (new.id, new.text);
            END;
            CREATE TRIGGER IF NOT EXISTS clips_ad AFTER DELETE ON clips BEGIN
                INSERT INTO clips_fts(clips_fts, rowid, text) VALUES ('delete', old.id, old.text);
            END;
            """)
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: Writes

    /// A text copied again keeps its row: the time moves, the count goes up.
    func upsert(text: String, app: String?, bundleID: String?, at date: Date) {
        queue.async { [self] in
            let sql = """
            INSERT INTO clips(text, hash, app, bundle_id, first_copied_at, last_copied_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(hash) DO UPDATE SET
                last_copied_at = excluded.last_copied_at,
                copy_count = copy_count + 1,
                app = excluded.app,
                bundle_id = excluded.bundle_id;
            """
            run(sql, [.text(text), .text(Self.hash(text)), .optionalText(app), .optionalText(bundleID),
                      .real(date.timeIntervalSince1970), .real(date.timeIntervalSince1970)])
        }
    }

    func delete(id: Int64) {
        queue.sync { run("DELETE FROM clips WHERE id = ?;", [.int(id)]) }
    }

    func deleteAll() {
        queue.sync {
            exec("DELETE FROM clips;")
            exec("INSERT INTO clips_fts(clips_fts) VALUES ('rebuild');")
        }
    }

    /// Deletes every copy last made before `date`.
    func prune(before date: Date) {
        queue.async { [self] in
            run("DELETE FROM clips WHERE last_copied_at < ?;", [.real(date.timeIntervalSince1970)])
        }
    }

    // MARK: Reads

    func count(before date: Date? = nil) -> Int {
        queue.sync {
            if let date {
                return scalarInt("SELECT COUNT(*) FROM clips WHERE last_copied_at < ?;",
                                 [.real(date.timeIntervalSince1970)])
            }
            return scalarInt("SELECT COUNT(*) FROM clips;", [])
        }
    }

    /// Newest first. Every word of `query` must appear in the text: words of
    /// three or more characters go through the full-text index, shorter ones
    /// (which a trigram index cannot match) through a plain substring test.
    func search(query: String? = nil, app: String? = nil, since: Date? = nil,
                until: Date? = nil, limit: Int, offset: Int = 0) -> [Clip] {
        var conditions: [String] = []
        var binds: [Bind] = []
        let words = (query ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        let long = words.filter { $0.count >= 3 }
        let short = words.filter { $0.count < 3 }
        if !long.isEmpty {
            let match = long.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                .joined(separator: " AND ")
            conditions.append("id IN (SELECT rowid FROM clips_fts WHERE clips_fts MATCH ?)")
            binds.append(.text(match))
        }
        for word in short {
            conditions.append("instr(lower(text), lower(?)) > 0")
            binds.append(.text(word))
        }
        if let app, !app.isEmpty {
            conditions.append("(instr(lower(app), lower(?)) > 0 OR lower(bundle_id) = lower(?))")
            binds.append(.text(app))
            binds.append(.text(app))
        }
        if let since {
            conditions.append("last_copied_at >= ?")
            binds.append(.real(since.timeIntervalSince1970))
        }
        if let until {
            conditions.append("last_copied_at < ?")
            binds.append(.real(until.timeIntervalSince1970))
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
        SELECT id, text, app, bundle_id, first_copied_at, last_copied_at, copy_count
        FROM clips \(whereClause) ORDER BY last_copied_at DESC LIMIT ? OFFSET ?;
        """
        binds.append(.int(Int64(limit)))
        binds.append(.int(Int64(offset)))
        return queue.sync {
            var rows: [Clip] = []
            withStatement(sql, binds) { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    rows.append(Clip(
                        id: sqlite3_column_int64(stmt, 0),
                        text: Self.columnText(stmt, 1) ?? "",
                        app: Self.columnText(stmt, 2),
                        bundleID: Self.columnText(stmt, 3),
                        firstCopiedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                        lastCopiedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                        copyCount: Int(sqlite3_column_int64(stmt, 6))))
                }
            }
            return rows
        }
    }

    /// Waits for the writes queued so far.
    func flush() { queue.sync {} }

    // MARK: SQLite plumbing (queue only)

    private enum Bind {
        case text(String)
        case optionalText(String?)
        case real(Double)
        case int(Int64)
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func run(_ sql: String, _ binds: [Bind]) {
        withStatement(sql, binds) { stmt in _ = sqlite3_step(stmt) }
    }

    private func scalarInt(_ sql: String, _ binds: [Bind]) -> Int {
        var value = 0
        withStatement(sql, binds) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW { value = Int(sqlite3_column_int64(stmt, 0)) }
        }
        return value
    }

    private func withStatement(_ sql: String, _ binds: [Bind], _ body: (OpaquePointer) -> Void) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, bind) in binds.enumerated() {
            let index = Int32(i + 1)
            switch bind {
            case .text(let s): sqlite3_bind_text(stmt, index, s, -1, Self.transient)
            case .optionalText(let s):
                if let s { sqlite3_bind_text(stmt, index, s, -1, Self.transient) } else { sqlite3_bind_null(stmt, index) }
            case .real(let d): sqlite3_bind_double(stmt, index, d)
            case .int(let n): sqlite3_bind_int64(stmt, index, n)
            }
        }
        body(stmt)
    }

    private static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
