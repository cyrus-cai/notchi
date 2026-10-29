import Foundation
import UniformTypeIdentifiers

// File tools. `list_files` searches the user's Downloads, Desktop and
// Documents folders, content included: "看看下载里最新的 PDF", "桌面上那份合同
// 写了什么". `read_file`, `write_file`, `edit_file`, `find_files` and
// `grep_files` work anywhere on this Mac except credential stores. macOS asks
// once per protected folder the first time.

enum UserFolders {
    static let all: [(key: String, url: URL)] = [
        ("downloads", FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]),
        ("desktop", FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]),
        ("documents", FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]),
    ]

    static func url(for key: String) -> URL? {
        all.first { $0.key == key.lowercased() }?.url
    }

    /// The file at `path` when it lies inside one of the folders, after
    /// resolving `~`, `..` and symlinks; nil otherwise.
    static func contained(_ path: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        let roots = all.map { $0.url.standardizedFileURL.resolvingSymlinksInPath().path + "/" }
        return roots.contains { url.path.hasPrefix($0) } ? url : nil
    }
}

/// `list_files`: what is in Downloads, Desktop or Documents, newest first.
struct ListFilesTool: NotchTool {
    static let toolName = "list_files"
    let name = toolName
    let description = """
    Lists files in the user's Downloads, Desktop or Documents folder on this \
    Mac, most recently changed first, with size and date. Call to find a file \
    they mention ("the latest PDF in Downloads", "that contract on my Desktop"), \
    then read it with read_file. Searches subfolders when `query` or `content` \
    is given. Use `content` when they describe what is IN the file rather than \
    its name — "the screenshot with the 快充 times", "the PDF that mentions \
    the deposit": it searches the text inside documents and the text macOS \
    recognized in screenshots and photos. The search matches exact words, so \
    the file may not use the user's wording: put the other ways it could say \
    it in `content_any` — synonyms and the same term in Chinese and English, \
    e.g. 押金 → ["押金", "保证金", "deposit"]. A file matches if it contains \
    any one of them. Use folder=all when unsure where it is.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "folder": ["type": "string", "enum": ["downloads", "desktop", "documents", "all"],
                       "description": "Which folder; all searches the three."],
            "query": ["type": "string", "description": "Only files whose name contains this."],
            "content": ["type": "string",
                        "description": "Words that appear inside the file, including text in a screenshot. Several words must all appear."],
            "content_any": ["type": "array", "items": ["type": "string"], "maxItems": 10,
                            "description": "Alternative wordings of what is inside the file; a file matches if it contains any one. Each entry may hold several words, which must all appear. Combined with `content` as one more alternative."],
            "kind": ["type": "string", "enum": ["pdf", "image", "text", "any"],
                     "description": "Only this kind of file. Default any."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 50,
                      "description": "How many, 1 to 50. Default 15."],
        ],
        "required": ["folder"],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        let key = (input["folder"] as? String)?.lowercased() ?? ""
        let roots = key == "all" ? UserFolders.all.map(\.url) : UserFolders.url(for: key).map { [$0] } ?? []
        guard let root = roots.first else {
            return "Error: folder must be downloads, desktop, documents or all."
        }
        let query = (input["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var wordings: [String] = []
        for raw in [input["content"] as? String] + ((input["content_any"] as? [Any]) ?? []).map({ $0 as? String }) {
            guard let words = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty,
                  !wordings.contains(words) else { continue }
            wordings.append(words)
        }
        wordings = Array(wordings.prefix(10))
        let content = wordings.map { "\"\($0)\"" }.joined(separator: " or ")
        let kind = (input["kind"] as? String) ?? "any"
        let limit = min(max((input["limit"] as? NSNumber)?.intValue ?? 15, 1), 50)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let fm = FileManager.default
        let label = roots.count > 1 ? "Downloads, Desktop and Documents" : root.lastPathComponent

        var urls: [URL] = []
        // Which wording found each file, so the model knows what to look for in it.
        var matched: [URL: String] = [:]
        if !content.isEmpty {
            for words in wordings {
                for url in roots.flatMap({ Self.spotlight(words, in: $0) }) where matched[url] == nil {
                    matched[url] = words
                    urls.append(url)
                }
            }
            if !query.isEmpty { urls = urls.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(query) } }
        } else if roots.count > 1 {
            return "Error: folder=all needs content. Pick one folder to list it."
        } else if query.isEmpty {
            guard let top = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles]) else {
                return "Error: could not open \(root.lastPathComponent). macOS may be waiting for the user to allow access."
            }
            urls = top
        } else if let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            // Bounded: a Documents folder can hold a whole drive's worth.
            var seen = 0
            for case let url as URL in walker {
                seen += 1
                if seen > 20_000 { break }
                if url.lastPathComponent.localizedCaseInsensitiveContains(query) { urls.append(url) }
            }
        }

        let files: [(url: URL, date: Date, size: Int)] = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, Self.matches(url, kind: kind) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        .sorted { $0.date > $1.date }

        guard !files.isEmpty else {
            return content.isEmpty ? "No matching files in \(label)."
                : "No file in \(label) contains \(content) (as far as Spotlight has indexed)."
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        let bytes = ByteCountFormatter()
        var lines = [content.isEmpty ? "\(label), newest first (path · size · changed):"
            : "Files in \(label) containing \(content), newest first (path · size · changed). Read one with files action=read to confirm:"]
        for file in files.prefix(limit) {
            let path = (file.url.path as NSString).abbreviatingWithTildeInPath
            let hit = wordings.count > 1 ? matched[file.url].map { " · has \"\($0)\"" } ?? "" : ""
            lines.append("- \(path) · \(bytes.string(fromByteCount: Int64(file.size))) · \(fmt.string(from: file.date))\(hit)")
        }
        if files.count > limit { lines.append("…and \(files.count - limit) more.") }
        return lines.joined(separator: "\n")
    }

    /// Files under `root` whose indexed text holds every word of `words`:
    /// Spotlight's own index, which includes text recognized in images.
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
        return String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(500)
            .map { URL(fileURLWithPath: String($0)) }
    }

    private static func matches(_ url: URL, kind: String) -> Bool {
        guard kind != "any" else { return true }
        let type = UTType(filenameExtension: url.pathExtension)
        switch kind {
        case "pdf":   return type?.conforms(to: .pdf) == true
        case "image": return type?.conforms(to: .image) == true
        case "text":  return type.map { [.text, .sourceCode, .json, .xml].contains(where: $0.conforms) } ?? false
        default:      return true
        }
    }
}

/// Paths the file tools resolve: `~`, `..` and symlinks resolved; nil for a
/// credential store (`ShellRisk.credentialPaths`).
enum FilePaths {
    static func resolve(_ raw: String) -> URL? {
        let expanded = (raw as NSString).expandingTildeInPath
        let base = expanded.hasPrefix("/") ? expanded : NSHomeDirectory() + "/" + expanded
        let url = URL(fileURLWithPath: base).standardizedFileURL.resolvingSymlinksInPath()
        let lowered = url.path.lowercased()
        if ShellRisk.credentialPaths.contains(where: { lowered.contains($0) }) { return nil }
        return url
    }

    /// A copy of the file as it was, before a write or edit changes it, so
    /// the change can be undone. Returns the copy's path.
    static func backup(_ url: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let folder = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchi/file-backups", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(url.lastPathComponent)")
        return (try? fm.copyItem(at: url, to: copy)) != nil ? copy.path : nil
    }
}

/// `read_file`: the text of one file on this Mac.
struct ReadFileTool: NotchTool {
    static let toolName = "read_file"
    let name = toolName
    let description = """
    Reads one file on this Mac: the text of a PDF or text file, or the text in \
    an image. Pass the path list_files or find gave, or a path the user names, \
    e.g. ~/Documents/grants/budget.pdf or ~/.zshrc. Lines are numbered; for a \
    long file pass offset (first line, 1-based) and lines to read part of it.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "The file's path, e.g. ~/Downloads/report.pdf."],
            "offset": ["type": "integer", "minimum": 1, "description": "First line to read, 1-based. Default 1."],
            "lines": ["type": "integer", "minimum": 1, "description": "How many lines. Default all, up to the size limit."],
        ],
        "required": ["path"],
    ]

    private static let textLimit = 200_000

    func execute(_ input: [String: Any]) async throws -> String {
        guard let raw = (input["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return "Error: give the file's path." }
        guard let url = FilePaths.resolve(raw) else {
            return "Error: that path holds credentials and cannot be read."
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return "Error: there is no file at \(raw). Find it with files action=list or action=find."
        }
        if isDir.boolValue {
            return "Error: \(raw) is a folder. List it with files action=find."
        }
        let type = UTType(filenameExtension: url.pathExtension)
        let text: String?
        if type?.conforms(to: .image) == true {
            text = NotchModel.recognizedText(at: url)
            guard text != nil else { return "No text found in that image." }
        } else {
            text = NotchModel.droppedFileText(url, type: type)
        }
        guard let body = text else {
            return "Error: \(url.lastPathComponent) is not a PDF, text file or image, or it has no text."
        }
        let all = body.components(separatedBy: "\n")
        let offset = max((input["offset"] as? NSNumber)?.intValue ?? 1, 1)
        guard offset <= all.count else {
            return "Error: \(url.lastPathComponent) has \(all.count) lines; offset \(offset) is past the end."
        }
        let count = (input["lines"] as? NSNumber)?.intValue ?? all.count
        let slice = all[(offset - 1)..<min(all.count, offset - 1 + max(count, 1))]
        var out: [String] = []
        var size = 0
        var last = offset - 1
        for (i, line) in slice.enumerated() {
            size += line.count + 8
            if size > Self.textLimit { break }
            out.append("\(offset + i)\t\(line)")
            last = offset + i
        }
        var header = "\(url.path) (\(all.count) lines)"
        if offset > 1 || last < all.count { header += ", lines \(offset)–\(last)" }
        var result = header + ":\n" + out.joined(separator: "\n")
        if last < all.count { result += "\n[… more from line \(last + 1); call again with offset=\(last + 1)]" }
        return result
    }
}

/// `write_file`: create or replace a text file.
struct WriteFileTool: NotchTool {
    static let toolName = "write_file"
    let name = toolName
    let description = """
    Creates a text file, or replaces one, with `content`. Missing folders are \
    created. A file it replaces is copied aside first, and the result says where.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "The file's path, e.g. ~/Desktop/notes.md."],
            "content": ["type": "string", "description": "The file's full new text."],
        ],
        "required": ["path", "content"],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        guard let raw = (input["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return "Error: give the file's path." }
        guard let content = input["content"] as? String else { return "Error: give the content." }
        guard let url = FilePaths.resolve(raw) else {
            return "Error: that path holds credentials and cannot be written."
        }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = FilePaths.backup(url)
        try content.write(to: url, atomically: true, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").count
        var out = "Wrote \(url.path) (\(lines) lines)."
        if let backup { out += " The previous version is at \(backup)." }
        return out
    }
}

/// `edit_file`: replace exact text inside a file.
struct EditFileTool: NotchTool {
    static let toolName = "edit_file"
    let name = toolName
    let description = """
    Changes a text file by replacing `old_text` with `new_text`. `old_text` \
    must match the file exactly, spaces and line breaks included, and occur \
    once unless replace_all is true. Read the file first. The file as it was is \
    copied aside, and the result says where.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "The file's path."],
            "old_text": ["type": "string", "description": "The exact text to replace."],
            "new_text": ["type": "string", "description": "What replaces it."],
            "replace_all": ["type": "boolean", "description": "Replace every occurrence. Default false."],
        ],
        "required": ["path", "old_text", "new_text"],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        guard let raw = (input["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return "Error: give the file's path." }
        guard let old = input["old_text"] as? String, !old.isEmpty,
              let new = input["new_text"] as? String else {
            return "Error: give old_text and new_text."
        }
        guard let url = FilePaths.resolve(raw) else {
            return "Error: that path holds credentials and cannot be changed."
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Error: \(raw) does not exist or is not a UTF-8 text file."
        }
        let count = text.components(separatedBy: old).count - 1
        guard count > 0 else {
            return "Error: old_text was not found in \(url.lastPathComponent). Read the file and copy the text exactly."
        }
        let all = (input["replace_all"] as? Bool) == true
        guard count == 1 || all else {
            return "Error: old_text occurs \(count) times. Give more surrounding text so it matches once, or set replace_all=true."
        }
        let updated: String
        if all {
            updated = text.replacingOccurrences(of: old, with: new)
        } else {
            let range = text.range(of: old)!
            updated = text.replacingCharacters(in: range, with: new)
        }
        let backup = FilePaths.backup(url)
        try updated.write(to: url, atomically: true, encoding: .utf8)
        var out = "Replaced \(all ? count : 1) occurrence\(all && count > 1 ? "s" : "") in \(url.path)."
        if let backup { out += " The previous version is at \(backup)." }
        return out
    }
}

/// `find_files`: files and folders whose path matches a glob.
struct FindFilesTool: NotchTool {
    static let toolName = "find_files"
    let name = toolName
    let description = """
    Lists files under a folder whose path matches a glob: `*.pdf` matches by \
    name at any depth, `src/**/*.swift` or `*/2026-*` match the path below the \
    folder. Hidden folders, node_modules and ~/Library are skipped unless the \
    folder itself is inside them. Newest first.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "folder": ["type": "string", "description": "Where to look, e.g. ~/Projects. Default the home folder."],
            "pattern": ["type": "string", "description": "The glob, e.g. *.md or **/invoice*.pdf."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 500, "description": "How many. Default 100."],
        ],
        "required": ["pattern"],
    ]

    private static let skipped: Set<String> = ["node_modules", ".git", "DerivedData", "Pods", ".build"]

    func execute(_ input: [String: Any]) async throws -> String {
        guard let pattern = (input["pattern"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pattern.isEmpty else { return "Error: give a pattern." }
        let folderRaw = (input["folder"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "~"
        guard let root = FilePaths.resolve(folderRaw) else { return "Error: that folder holds credentials." }
        let limit = min(max((input["limit"] as? NSNumber)?.intValue ?? 100, 1), 500)
        let home = NSHomeDirectory()
        let skipLibrary = !root.path.hasPrefix(home + "/Library")
        let byPath = pattern.contains("/")
        let glob = pattern.hasPrefix("**/") ? String(pattern.dropFirst(3)) : pattern
        let matchByName = !byPath || pattern.hasPrefix("**/") && !glob.contains("/")
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsPackageDescendants]) else {
            return "Error: cannot read \(folderRaw)."
        }
        var hits: [(path: String, date: Date)] = []
        var seen = 0
        let started = Date()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        while let item = walker.nextObject() as? URL {
            seen += 1
            if seen > 400_000 || Date().timeIntervalSince(started) > 20 { break }
            let name = item.lastPathComponent
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            if values?.isDirectory == true {
                if name.hasPrefix(".") || Self.skipped.contains(name)
                    || skipLibrary && item.path == home + "/Library" {
                    walker.skipDescendants()
                    continue
                }
            }
            let rel = item.path.hasPrefix(rootPrefix) ? String(item.path.dropFirst(rootPrefix.count)) : name
            let subject = matchByName ? name : rel
            let pat = matchByName ? glob : pattern.replacingOccurrences(of: "**/", with: "*")
            if fnmatch(pat, subject, 0) == 0 {
                hits.append((item.path, values?.contentModificationDate ?? .distantPast))
            }
        }
        guard !hits.isEmpty else { return "No files under \(root.path) match \(pattern)." }
        hits.sort { $0.date > $1.date }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let lines = hits.prefix(limit).map { "\($0.path)  \(formatter.string(from: $0.date))" }
        var out = "\(hits.count) match\(hits.count == 1 ? "" : "es") under \(root.path):\n" + lines.joined(separator: "\n")
        if hits.count > limit { out += "\n[\(hits.count - limit) more; narrow the pattern or raise limit]" }
        return out
    }
}

/// `grep_files`: lines in text files that match a pattern, via `/usr/bin/grep`.
struct GrepFilesTool: NotchTool {
    static let toolName = "grep_files"
    let name = toolName
    let description = """
    Searches the text of files under a folder (or one file) for a regular \
    expression, extended syntax, and returns matching lines with file and line \
    number. `include` keeps files whose name matches a glob, e.g. *.swift. \
    Binary files, .git and node_modules are skipped.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "pattern": ["type": "string", "description": "The regular expression (grep -E)."],
            "path": ["type": "string", "description": "A folder or a file. Default the home folder; give a narrower one when you can."],
            "include": ["type": "string", "description": "Only files whose name matches this glob."],
            "ignore_case": ["type": "boolean", "description": "Match regardless of case. Default false."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 1000, "description": "Most lines to return. Default 200."],
        ],
        "required": ["pattern"],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        guard let pattern = input["pattern"] as? String, !pattern.isEmpty else { return "Error: give a pattern." }
        let pathRaw = (input["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "~"
        guard let url = FilePaths.resolve(pathRaw) else { return "Error: that path holds credentials." }
        let limit = min(max((input["limit"] as? NSNumber)?.intValue ?? 200, 1), 1000)
        var args = ["-rnIE", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=Library",
                    "--exclude-dir=.Trash", "-m", "50"]
        if (input["ignore_case"] as? Bool) == true { args.append("-i") }
        if let include = input["include"] as? String, !include.isEmpty { args.append("--include=\(include)") }
        args += ["--", pattern, url.path]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timer)
        var lines: [String] = []
        var total = 0
        var pending = ""
        let reader = pipe.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            pending += String(decoding: chunk, as: UTF8.self)
            while let nl = pending.firstIndex(of: "\n") {
                total += 1
                if lines.count < limit { lines.append(String(pending[..<nl]).prefix(400).description) }
                pending = String(pending[pending.index(after: nl)...])
            }
            if total > limit * 20 { process.terminate(); break }
        }
        timer.cancel()
        process.waitUntilExit()
        guard !lines.isEmpty else { return "No matches for \(pattern) under \(url.path)." }
        var out = lines.joined(separator: "\n")
        if total > lines.count { out += "\n[\(total - lines.count) more matching lines; narrow path, include or pattern]" }
        return out
    }
}
