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
    then read it with read_file. Searches subfolders when `query` is given.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "folder": ["type": "string", "enum": ["downloads", "desktop", "documents"],
                       "description": "Which folder."],
            "query": ["type": "string", "description": "Only files whose name contains this."],
            "kind": ["type": "string", "enum": ["pdf", "image", "text", "any"],
                     "description": "Only this kind of file. Default any."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 50,
                      "description": "How many, 1 to 50. Default 15."],
        ],
        "required": ["folder"],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        guard let key = input["folder"] as? String, let root = UserFolders.url(for: key) else {
            return "Error: folder must be downloads, desktop or documents."
        }
        let query = (input["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let kind = (input["kind"] as? String) ?? "any"
        let limit = min(max((input["limit"] as? NSNumber)?.intValue ?? 15, 1), 50)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let fm = FileManager.default

        var urls: [URL] = []
        if query.isEmpty {
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
            return "No matching files in \(root.lastPathComponent)."
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        let bytes = ByteCountFormatter()
        var lines = ["\(root.lastPathComponent), newest first (path · size · changed):"]
        for file in files.prefix(limit) {
            let path = (file.url.path as NSString).abbreviatingWithTildeInPath
            lines.append("- \(path) · \(bytes.string(fromByteCount: Int64(file.size))) · \(fmt.string(from: file.date))")
        }
        if files.count > limit { lines.append("…and \(files.count - limit) more.") }
        return lines.joined(separator: "\n")
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
    gave. Other folders and other file types cannot be read.
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
            return "Error: there is no file at \(raw). Call list_files to find it."
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
