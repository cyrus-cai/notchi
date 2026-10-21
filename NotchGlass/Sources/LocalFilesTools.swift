import Foundation
import UniformTypeIdentifiers

// Read-only tools over the user's Downloads, Desktop and Documents folders:
// "看看下载里最新的 PDF", "桌面上那份合同写了什么". Nothing outside those three
// folders is listed or read. macOS asks once per folder the first time.

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

/// `read_file`: the text of one file from those folders.
struct ReadFileTool: NotchTool {
    static let toolName = "read_file"
    let name = toolName
    let description = """
    Reads one file from the user's Downloads, Desktop or Documents folder: the \
    text of a PDF or text file, or the text in an image. Pass the path list_files \
    gave, or a path the user names inside those folders — subfolders included, \
    e.g. ~/Documents/grants/budget.pdf. Other folders and other file types \
    cannot be read.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "The file's path, e.g. ~/Downloads/report.pdf."],
        ],
        "required": ["path"],
    ]

    private static let textLimit = 20_000

    func execute(_ input: [String: Any]) async throws -> String {
        guard let raw = (input["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return "Error: give the file's path." }
        guard let url = UserFolders.contained(raw) else {
            return "Error: only files in Downloads, Desktop or Documents can be read."
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "Error: there is no file at \(raw). Find it with files action=list."
        }
        let type = UTType(filenameExtension: url.pathExtension)
        let text: String?
        if type?.conforms(to: .image) == true {
            text = NotchModel.recognizedText(at: url)
            guard text != nil else { return "No text found in that image." }
        } else {
            text = NotchModel.droppedFileText(url, type: type)
        }
        guard var body = text else {
            return "Error: \(url.lastPathComponent) is not a PDF, text file or image, or it has no text."
        }
        if body.count > Self.textLimit {
            body = String(body.prefix(Self.textLimit)) + "\n[… the rest of the file was cut]"
        }
        return "\(url.lastPathComponent):\n\(body)"
    }
}
