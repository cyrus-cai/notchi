import Foundation

/// `notchi_source`: Notchi's own source code, from the public repository
/// (github.com/cyrus-cai/notchi) at the tag of the running version, so the
/// model answers questions about the app from the code instead of guessing.
/// The archive is downloaded once per version and kept in Caches.
struct NotchiSourceTool: NotchTool {
    static let toolName = "notchi_source"
    static let repo = UpdaterService.repo
    let name = toolName
    let description = """
    Notchi's own source code (this app), from its public repository \
    github.com/cyrus-cai/notchi at the version the user is running. Call it \
    before answering any question about how Notchi works, what a setting, \
    shortcut, tool or feature does, where something is, or why it behaves a \
    certain way. Do not answer such questions from memory. Actions: \
    "files" lists paths (optional prefix); "grep" searches with a regular \
    expression (optional path prefix); "read" returns a file's lines. \
    Sources are in NotchGlass/Sources; UI text is in Localization.swift; \
    release notes are in WhatsNewService.swift.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["files", "grep", "read"]],
            "pattern": ["type": "string", "description": "grep: regular expression, case-insensitive."],
            "path": ["type": "string", "description": "read: file path from the repository root. files/grep: optional path prefix to limit the search."],
            "start": ["type": "integer", "minimum": 1, "description": "read: first line, default 1."],
            "end": ["type": "integer", "minimum": 1, "description": "read: last line. At most 400 lines are returned per call."],
        ],
        "required": ["action"],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        let action = input["action"] as? String ?? ""
        let path = (input["path"] as? String)?
            .trimmingCharacters(in: CharacterSet(charactersIn: " /\n")) ?? ""
        let (root, ref) = try await Self.checkout()
        let files = Self.listFiles(root)

        switch action {
        case "files":
            let hits = files.filter { path.isEmpty || $0.hasPrefix(path) }
            guard !hits.isEmpty else { return "No files under \"\(path)\" at \(ref)." }
            let shown = hits.prefix(400)
            var out = "\(ref), \(hits.count) files:\n" + shown.joined(separator: "\n")
            if hits.count > shown.count { out += "\n… \(hits.count - shown.count) more; pass a narrower path." }
            return out

        case "grep":
            let pattern = (input["pattern"] as? String) ?? ""
            guard !pattern.isEmpty else { return "Error: grep needs pattern." }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return "Error: \"\(pattern)\" is not a valid regular expression."
            }
            let limit = 80
            var hits: [String] = []
            var total = 0
            for file in files where path.isEmpty || file.hasPrefix(path) {
                guard Self.isText(file),
                      let text = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
                else { continue }
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    let range = NSRange(line.startIndex..., in: line)
                    guard regex.firstMatch(in: line, range: range) != nil else { continue }
                    total += 1
                    if hits.count < limit {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        let shown = trimmed.count > 200 ? String(trimmed.prefix(200)) + "…" : trimmed
                        hits.append("\(file):\(index + 1): \(shown)")
                    }
                }
            }
            guard total > 0 else { return "No match for \"\(pattern)\" at \(ref)." }
            var out = "\(ref), \(total) matches:\n" + hits.joined(separator: "\n")
            if total > hits.count { out += "\n… \(total - hits.count) more; narrow the pattern or path." }
            return out

        case "read":
            guard !path.isEmpty else { return "Error: read needs path." }
            guard files.contains(path) else {
                let name = (path as NSString).lastPathComponent.lowercased()
                let near = files.filter { $0.lowercased().hasSuffix(name) }.prefix(5)
                return "No file \"\(path)\" at \(ref)."
                    + (near.isEmpty ? "" : " Did you mean: " + near.joined(separator: ", "))
            }
            guard Self.isText(path),
                  let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            else { return "\(path) is not a text file." }
            let lines = text.components(separatedBy: "\n")
            let start = max((input["start"] as? NSNumber)?.intValue ?? 1, 1)
            let requestedEnd = (input["end"] as? NSNumber)?.intValue ?? lines.count
            let end = min(requestedEnd, lines.count, start + 399)
            guard start <= lines.count else { return "\(path) has \(lines.count) lines." }
            let body = (start...end).map { "\($0)\t\(lines[$0 - 1])" }.joined(separator: "\n")
            var out = "\(path) at \(ref), lines \(start)-\(end) of \(lines.count):\n" + body
            if end < min(requestedEnd, lines.count) { out += "\n… continue with start=\(end + 1)." }
            return out

        default:
            return "Error: action must be files, grep or read."
        }
    }

    // MARK: - Archive

    private static let lock = CheckoutLock()

    /// The extracted source of the running version, downloading it the first
    /// time. Falls back to the default branch when the version has no tag
    /// (a local build ahead of the last release).
    static func checkout() async throws -> (URL, String) {
        try await lock.run {
            let version = await MainActor.run { UpdaterService.currentVersion }
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Notchi")
                .appendingPathComponent("notchi-source")
            for ref in ["v\(version)", "master"] {
                let dir = caches.appendingPathComponent(ref)
                let ready = dir.appendingPathComponent(".ready")
                // The branch moves; refresh it after a day. A tag never changes.
                if let attrs = try? FileManager.default.attributesOfItem(atPath: ready.path),
                   ref != "master" || ((attrs[.modificationDate] as? Date).map { Date().timeIntervalSince($0) < 86_400 } ?? false) {
                    return (dir, ref)
                }
                let url = URL(string: "https://codeload.github.com/\(repo)/tar.gz/\(ref == "master" ? "refs/heads/master" : "refs/tags/\(ref)")")!
                var request = URLRequest(url: url)
                request.timeoutInterval = 60
                let (file, response) = try await ProxyConfig.urlSession.download(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                try? FileManager.default.removeItem(at: dir)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let tar = Process()
                tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                tar.arguments = ["-xzf", file.path, "-C", dir.path, "--strip-components", "1"]
                try tar.run()
                tar.waitUntilExit()
                try? FileManager.default.removeItem(at: file)
                guard tar.terminationStatus == 0 else {
                    try? FileManager.default.removeItem(at: dir)
                    throw NSError(domain: "notchi_source", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Could not unpack the source archive."])
                }
                FileManager.default.createFile(atPath: ready.path, contents: nil)
                return (dir, ref)
            }
            throw NSError(domain: "notchi_source", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not download the source from github.com/\(repo)."])
        }
    }

    /// Repository-relative paths of every file, sorted.
    static func listFiles(_ root: URL) -> [String] {
        let base = root.standardizedFileURL.path + "/"
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [String] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base) else { continue }
            let rel = String(full.dropFirst(base.count))
            if rel != ".ready" { out.append(rel) }
        }
        return out.sorted()
    }

    static func isText(_ path: String) -> Bool {
        let binary: Set<String> = ["png", "jpg", "jpeg", "gif", "icns", "ico", "pdf", "zip", "mp4", "mov", "mp3", "wav", "ttf", "otf", "car", "webp"]
        return !binary.contains((path as NSString).pathExtension.lowercased())
    }
}

/// Runs one download at a time, so two calls in one turn don't fetch the
/// archive twice.
private actor CheckoutLock {
    private var running: Task<(URL, String), Error>?

    func run(_ body: @escaping @Sendable () async throws -> (URL, String)) async throws -> (URL, String) {
        if let running { return try await running.value }
        let task = Task { try await body() }
        running = task
        defer { running = nil }
        return try await task.value
    }
}
