import Foundation
import UniformTypeIdentifiers

/// Persists the local mounted folder chosen for a folder-backed connector
/// (such as Google Drive for Desktop in `~/Library/CloudStorage`).
enum LocalDriveStore {
    private static let prefix = "mcp_local_folder."

    static func path(for id: String) -> String? {
        guard let raw = UserDefaults.standard.string(forKey: prefix + id), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    static func url(for id: String) -> URL? {
        guard let raw = path(for: id) else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    static func save(_ url: URL, for id: String) {
        let normalized = url.standardizedFileURL.path
        UserDefaults.standard.set(normalized, forKey: prefix + id)
    }

    static func delete(_ id: String) {
        UserDefaults.standard.removeObject(forKey: prefix + id)
    }

    /// Finds mounted Google Drive for Desktop folders on this Mac:
    /// modern FileProvider mounts under `~/Library/CloudStorage/GoogleDrive-*`
    /// and legacy mounts at `/Volumes/GoogleDrive` or `~/Google Drive`.
    static func discoverGoogleDrive() -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        let cloudStorage = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
        if let entries = try? fm.contentsOfDirectory(
            at: cloudStorage,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            let drives = entries
                .filter { url in
                    url.lastPathComponent.hasPrefix("GoogleDrive-")
                        && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            found.append(contentsOf: drives)
        }
        for legacy in [
            URL(fileURLWithPath: "/Volumes/GoogleDrive", isDirectory: true),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Google Drive", isDirectory: true),
        ] {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: legacy.path, isDirectory: &isDir), isDir.boolValue,
               !found.contains(where: { $0.standardizedFileURL == legacy.standardizedFileURL }) {
                found.append(legacy)
            }
        }
        return found
    }
}

/// Google Drive over the locally mounted Google Drive for Desktop folder.
/// Zero OAuth / CASA required: lists, searches, reads local & streamed files,
/// extracts links from `.gdoc`/`.gsheet`/`.gslides` shortcuts, and writes files
/// strictly inside the chosen Drive root.
struct GoogleDriveServer: MCPLocalServer {
    private static let connector = "googledrive"
    private static let maxWalkEntries = 20_000
    private static let textLimit = 20_000
    private static let cloudShortcuts: [String: String] = [
        "gdoc": "Google Doc",
        "gsheet": "Google Sheet",
        "gslides": "Google Slides",
        "gform": "Google Form",
        "gdraw": "Google Drawing",
        "gmap": "Google My Map",
        "gsite": "Google Site",
    ]

    var tools: [[String: Any]] {
        [
            [
                "name": "list_files",
                "description": "Lists files and folders in the connected local Google Drive folder (root or a relative subfolder), most recently modified first.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "folder": [
                            "type": "string",
                            "description": "Relative folder path inside Google Drive, e.g. \"My Drive\" or \"My Drive/Projects\". Omit for Drive root.",
                        ],
                        "limit": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 50,
                            "description": "Maximum entries to return. Default 20.",
                        ],
                    ],
                ],
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "search_files",
                "description": "Searches the connected local Google Drive by filename (`query`) and/or file contents (`content`, via macOS Spotlight index). Returns relative paths you can pass to `read_file`.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Case-insensitive substring to match against file or folder names.",
                        ],
                        "content": [
                            "type": "string",
                            "description": "Words that appear inside the file (PDFs, text, Office docs, screenshots indexed by Spotlight).",
                        ],
                        "kind": [
                            "type": "string",
                            "enum": ["any", "pdf", "image", "text", "gdoc"],
                            "description": "Filter by file kind. Default any.",
                        ],
                        "limit": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 50,
                            "description": "Maximum results to return. Default 15.",
                        ],
                    ],
                ],
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "read_file",
                "description": "Reads a file from the connected Google Drive by its relative path (from list_files or search_files). Supports PDFs, text/Markdown/CSV/JSON/code, and images (OCR). For Google Workspace cloud shortcuts (.gdoc/.gsheet/.gslides), returns the web link.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Relative path inside Google Drive, e.g. \"My Drive/Notes/plan.md\".",
                        ],
                        "offset": [
                            "type": "integer",
                            "minimum": 1,
                            "description": "First line to read, 1-based. Default 1.",
                        ],
                        "lines": [
                            "type": "integer",
                            "minimum": 1,
                            "description": "How many lines to return. Default all up to the size limit.",
                        ],
                    ],
                    "required": ["path"],
                ],
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "create_file",
                "description": "Creates or replaces a UTF-8 text or Markdown file inside the connected Google Drive folder. Missing subfolders are created; replaced files are backed up first.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Relative path inside Google Drive, e.g. \"My Drive/Notes/summary.md\".",
                        ],
                        "content": [
                            "type": "string",
                            "description": "Full text content to write.",
                        ],
                    ],
                    "required": ["path", "content"],
                ],
            ],
        ]
    }

    func call(_ name: String, _ arguments: [String: Any]) async throws -> String {
        let root = try Self.resolvedRoot()
        switch name {
        case "list_files":
            return try Self.listFiles(root: root, arguments: arguments)
        case "search_files":
            return try Self.searchFiles(root: root, arguments: arguments)
        case "read_file":
            return try Self.readFile(root: root, arguments: arguments)
        case "create_file":
            return try Self.createFile(root: root, arguments: arguments)
        default:
            throw MCPError("Unknown tool \(name).")
        }
    }

    // MARK: - Root & Path Containment

    private static func resolvedRoot() throws -> URL {
        guard let url = LocalDriveStore.url(for: connector) else {
            throw MCPError("Google Drive is not connected. Connect it in Settings.")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw MCPError("The Google Drive folder at \((url.path as NSString).abbreviatingWithTildeInPath) is unavailable. Make sure Google Drive for Desktop is running, or reconnect in Settings.")
        }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func resolveInside(root: URL, relative raw: String?) throws -> URL {
        let trimmed = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidate = trimmed.isEmpty ? root : root.appendingPathComponent(trimmed)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard resolved.path == rootPath || resolved.path.hasPrefix(prefix) else {
            throw MCPError("Path must stay inside the connected Google Drive folder.")
        }
        return resolved
    }

    private static func relativePath(of url: URL, from root: URL) -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if resolved.hasPrefix(prefix) {
            return String(resolved.dropFirst(prefix.count))
        }
        return url.lastPathComponent
    }

    // MARK: - Tools

    private static func listFiles(root: URL, arguments: [String: Any]) throws -> String {
        let folder = try resolveInside(root: root, relative: arguments["folder"] as? String)
        let limit = min(max((arguments["limit"] as? NSNumber)?.intValue ?? 20, 1), 50)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw MCPError("Folder not found in Google Drive.")
        }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw MCPError("Could not read folder. macOS may be waiting for permission, or Google Drive may still be syncing.")
        }
        let entries: [(url: URL, isDir: Bool, date: Date, size: Int)] = items.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return (url, v?.isDirectory == true, v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0)
        }
        .sorted { lhs, rhs in
            if lhs.isDir != rhs.isDir { return lhs.isDir }
            return lhs.date > rhs.date
        }
        guard !entries.isEmpty else { return "Folder is empty." }
        return formatEntries(entries, root: root, limit: limit, header: "Google Drive (\(relativePath(of: folder, from: root) == folder.lastPathComponent && folder == root ? "root" : relativePath(of: folder, from: root))):")
    }

    private static func searchFiles(root: URL, arguments: [String: Any]) throws -> String {
        let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let content = (arguments["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let kind = (arguments["kind"] as? String) ?? "any"
        let limit = min(max((arguments["limit"] as? NSNumber)?.intValue ?? 15, 1), 50)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey, .isRegularFileKey]
        let fm = FileManager.default

        var urls: [URL] = []
        if !content.isEmpty {
            urls = spotlight(content, in: root)
            if !query.isEmpty {
                urls = urls.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(query) }
            }
        } else if let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            var seen = 0
            for case let url as URL in walker {
                seen += 1
                if seen > maxWalkEntries { break }
                if query.isEmpty || url.lastPathComponent.localizedCaseInsensitiveContains(query) {
                    urls.append(url)
                }
            }
        }

        let entries: [(url: URL, isDir: Bool, date: Date, size: Int)] = urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let isDir = v.isDirectory == true
            if kind != "any" && isDir { return nil }
            guard isDir || matches(url, kind: kind) else { return nil }
            return (url, isDir, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0)
        }
        .sorted { $0.date > $1.date }

        guard !entries.isEmpty else {
            return content.isEmpty
                ? "No matching files found in Google Drive."
                : "No file in Google Drive matched content \"\(content)\" (Spotlight only indexes synced/local files, not .gdoc shortcuts)."
        }
        return formatEntries(entries, root: root, limit: limit, header: "Google Drive search results (newest first):")
    }

    private static func readFile(root: URL, arguments: [String: Any]) throws -> String {
        guard let rawPath = arguments["path"] as? String, !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError("path is required.")
        }
        let url = try resolveInside(root: root, relative: rawPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw MCPError("File not found in Google Drive: \(rawPath)")
        }
        guard !isDir.boolValue else {
            throw MCPError("\(rawPath) is a folder. Use list_files to inspect it.")
        }

        let ext = url.pathExtension.lowercased()
        if let label = cloudShortcuts[ext] {
            var msg = "\(url.lastPathComponent) is a \(label) cloud shortcut. Its contents are not stored locally by Google Drive for Desktop."
            if let link = cloudShortcutURL(url) {
                msg += "\nOpen in browser: \(link)"
            }
            return msg
        }

        let type = UTType(filenameExtension: ext)
        let text: String?
        if type?.conforms(to: .image) == true {
            text = NotchModel.recognizedText(at: url)
            guard text != nil else { return "No text found in that image." }
        } else {
            text = NotchModel.droppedFileText(url, type: type)
        }
        guard let body = text else {
            throw MCPError("\(url.lastPathComponent) is not a readable PDF, text file, or image.")
        }

        let all = body.components(separatedBy: "\n")
        let offset = max((arguments["offset"] as? NSNumber)?.intValue ?? 1, 1)
        guard offset <= all.count else {
            throw MCPError("\(url.lastPathComponent) has \(all.count) lines; offset \(offset) is past the end.")
        }
        let count = (arguments["lines"] as? NSNumber)?.intValue ?? all.count
        let slice = all[(offset - 1)..<min(all.count, offset - 1 + max(count, 1))]
        var out: [String] = []
        var size = 0
        var last = offset - 1
        for (i, line) in slice.enumerated() {
            size += line.count + 8
            if size > textLimit { break }
            out.append("\(offset + i)\t\(line)")
            last = offset + i
        }
        var header = "\(relativePath(of: url, from: root)) (\(all.count) lines)"
        if offset > 1 || last < all.count { header += ", lines \(offset)–\(last)" }
        var result = header + ":\n" + out.joined(separator: "\n")
        if last < all.count {
            result += "\n[… more from line \(last + 1); call read_file again with offset=\(last + 1)]"
        }
        return result
    }

    private static func createFile(root: URL, arguments: [String: Any]) throws -> String {
        guard let rawPath = arguments["path"] as? String, !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError("path is required.")
        }
        guard let content = arguments["content"] as? String else {
            throw MCPError("content is required.")
        }
        let url = try resolveInside(root: root, relative: rawPath)
        guard url != root else {
            throw MCPError("Give a file path inside Google Drive, not the root folder.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = FilePaths.backup(url)
        try content.write(to: url, atomically: true, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").count
        var out = "Saved \(relativePath(of: url, from: root)) (\(lines) lines)."
        if let backup { out += " Previous copy backed up at \(backup)." }
        return out
    }

    // MARK: - Helpers

    private static func cloudShortcutURL(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let link = json["url"] as? String, !link.isEmpty { return link }
        if let docID = json["doc_id"] as? String, !docID.isEmpty {
            return "https://drive.google.com/open?id=\(docID)"
        }
        return nil
    }

    private static func spotlight(_ words: String, in root: URL) -> [URL] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", root.path, words]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .prefix(500)
            .map { URL(fileURLWithPath: String($0)) }
    }

    private static func matches(_ url: URL, kind: String) -> Bool {
        let ext = url.pathExtension.lowercased()
        switch kind {
        case "any": return true
        case "gdoc": return cloudShortcuts[ext] != nil
        case "pdf": return UTType(filenameExtension: ext)?.conforms(to: .pdf) == true
        case "image": return UTType(filenameExtension: ext)?.conforms(to: .image) == true
        case "text":
            guard let type = UTType(filenameExtension: ext) else { return false }
            return [.text, .sourceCode, .json, .xml].contains(where: type.conforms)
        default: return true
        }
    }

    private static func formatEntries(
        _ entries: [(url: URL, isDir: Bool, date: Date, size: Int)],
        root: URL,
        limit: Int,
        header: String
    ) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        let bytes = ByteCountFormatter()
        var lines = [header]
        for entry in entries.prefix(limit) {
            let rel = relativePath(of: entry.url, from: root)
            if entry.isDir {
                lines.append("- \(rel)/ [folder] · \(fmt.string(from: entry.date))")
            } else if let shortcut = cloudShortcuts[entry.url.pathExtension.lowercased()] {
                lines.append("- \(rel) [\(shortcut) shortcut] · \(fmt.string(from: entry.date))")
            } else {
                lines.append("- \(rel) · \(bytes.string(fromByteCount: Int64(entry.size))) · \(fmt.string(from: entry.date))")
            }
        }
        if entries.count > limit {
            lines.append("…and \(entries.count - limit) more.")
        }
        return lines.joined(separator: "\n")
    }
}
