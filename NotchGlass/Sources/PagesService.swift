import AppKit
import Foundation
import SwiftUI

// MARK: - Pages Service

/// Client for Notchi pages (`https://<slug>.notch.website`), backed by
/// `api.notch.website/v1/pages` and the install's anonymous bearer token
/// (`NoNoAccount`). Users with their own API key or CLI provider get an
/// anonymous token automatically on first use.
@MainActor
final class PagesService: ObservableObject {
    static let shared = PagesService()

    nonisolated static let domain = "notch.website"
    private nonisolated static let reserved: Set<String> = [
        "api", "www", "app", "mail", "email", "smtp", "imap", "license", "docs",
        "blog", "status", "admin", "staging", "dev", "cdn", "static", "assets",
        "auth", "login", "account", "billing", "pay", "help", "support", "pages",
        "page", "notchi", "notch", "nono", "telegram",
    ]

    struct PageSummary: Codable, Identifiable, Equatable, Sendable {
        let slug: String
        let url: String
        let title: String
        let visibility: String
        let createdAt: Double
        let updatedAt: Double

        var id: String { slug }
        var isPublic: Bool { visibility == "public" }
        var pageURL: URL? { URL(string: url) }
    }

    struct PageEntry: Codable, Equatable, Sendable {
        let at: Double
        let text: String
    }

    struct PageDetail: Codable, Equatable, Sendable {
        let slug: String
        let url: String
        let title: String
        let body: String
        let visibility: String
        let version: Int
        let createdAt: Double
        let updatedAt: Double
        let entries: [PageEntry]
        let entryCount: Int
    }

    struct PageWriteResult: Codable, Equatable, Sendable {
        let slug: String
        let url: String
        let title: String?
        let visibility: String?
        let version: Int
        let updatedAt: Double
    }

    private struct ListResponse: Decodable { let pages: [PageSummary] }
    private struct TicketResponse: Decodable { let url: String }
    private struct VisibilityResponse: Decodable { let slug: String; let visibility: String }
    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable { let message: String?; let code: String? }
        let error: Body
    }

    enum PageError: LocalizedError {
        case unavailable(String)
        case api(status: Int, code: String?, message: String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let message): return message
            case .api(_, _, let message): return message
            }
        }
    }

    @Published private(set) var pages: [PageSummary] = []
    @Published private(set) var loading = false
    @Published private(set) var lastError: String?

    private var accessURLs: [String: URL] = [:]
    private var syncedTelegram: (botID: String, userID: Int64)?

    /// Thread-safe title cache so `LinkCardStore` can title private pages
    /// without hitting the network (a private page answers 403 to LPMetadataProvider).
    private nonisolated static let titleLock = NSLock()
    private nonisolated(unsafe) static var titles: [String: String] = [:]

    private init() {}

    nonisolated static func cachedTitle(forSlug slug: String) -> String? {
        titleLock.lock()
        defer { titleLock.unlock() }
        return titles[slug]
    }

    private nonisolated static func rememberTitle(_ title: String?, forSlug slug: String) {
        guard let title, !title.isEmpty else { return }
        titleLock.lock()
        titles[slug] = title
        titleLock.unlock()
    }

    /// Returns the page slug if `url` points at `<slug>.notch.website`.
    nonisolated static func slug(from url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return nil }
        let suffix = "." + domain
        guard host.hasSuffix(suffix) else { return nil }
        let label = String(host.dropLast(suffix.count))
        guard !label.isEmpty, label.count <= 48, !label.contains("."), !reserved.contains(label) else {
            return nil
        }
        guard label.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }),
              label.first != "-", label.last != "-" else { return nil }
        return label
    }

    /// Extracts distinct Notchi page URLs referenced in `text`, in order of appearance.
    nonisolated static func pageURLs(in text: String) -> [(slug: String, url: URL)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"https://([a-z0-9](?:[a-z0-9-]{0,46}[a-z0-9])?)\.notch\.website(?:/[^\s)\]"'<>]*)?"#,
            options: [.caseInsensitive]
        ) else { return [] }
        let ns = text as NSString
        var seen: Set<String> = []
        var out: [(String, URL)] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: match.range)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]'\"，。；：！？）"))
            guard let url = URL(string: raw), let slug = slug(from: url),
                  seen.insert(slug).inserted else { continue }
            out.append((slug, URL(string: "https://\(slug).\(domain)") ?? url))
        }
        return out
    }

    // MARK: - API

    private var base: String {
        let endpoint = Provider.nonoEndpoint
        guard let range = endpoint.range(of: "/chat/completions", options: .backwards) else {
            return "https://api.notch.website/v1"
        }
        return String(endpoint[endpoint.startIndex..<range.lowerBound])
    }

    private func ensureToken() async throws -> String {
        if !NoNoAccount.shared.hasToken {
            await NoNoAccount.shared.register()
        }
        let token = NoNoAccount.shared.token
        guard !token.isEmpty else {
            throw PageError.unavailable("Could not reach api.notch.website to register this Mac.")
        }
        return token
    }

    private func request(_ path: String, method: String, body: [String: Any]? = nil) async throws -> Data {
        let token = try await ensureToken()
        guard let url = URL(string: base + path) else {
            throw PageError.unavailable("Invalid page endpoint.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (field, value) in NoNoRequestContext.headers where field == "X-Notchi-Version" || field == "X-Notchi-Device" {
            req.setValue(value, forHTTPHeaderField: field)
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await ProxyConfig.urlSession.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
               let msg = envelope.error.message {
                throw PageError.api(status: status, code: envelope.error.code, message: msg)
            }
            throw PageError.api(status: status, code: nil, message: "Server returned HTTP \(status).")
        }
        return data
    }

    private func upsertSummary(slug: String, url: String, title: String?, visibility: String?, createdAt: Double? = nil, updatedAt: Double) {
        if let i = pages.firstIndex(where: { $0.slug == slug }) {
            let old = pages[i]
            pages[i] = PageSummary(
                slug: slug,
                url: url,
                title: title ?? old.title,
                visibility: visibility ?? old.visibility,
                createdAt: createdAt ?? old.createdAt,
                updatedAt: updatedAt
            )
        } else if let title {
            pages.insert(
                PageSummary(
                    slug: slug,
                    url: url,
                    title: title,
                    visibility: visibility ?? "private",
                    createdAt: createdAt ?? updatedAt,
                    updatedAt: updatedAt
                ),
                at: 0
            )
        }
    }

    func create(title: String, body: String, slugHint: String? = nil) async throws -> PageWriteResult {
        var payload: [String: Any] = [
            "title": title,
            "body": body,
            "time_zone": TimeZone.current.identifier,
        ]
        if let slugHint, !slugHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["slug_hint"] = slugHint
        }
        let data = try await request("/pages", method: "POST", body: payload)
        let result = try JSONDecoder().decode(PageWriteResult.self, from: data)
        Self.rememberTitle(result.title ?? title, forSlug: result.slug)
        upsertSummary(slug: result.slug, url: result.url, title: result.title ?? title,
                      visibility: result.visibility ?? "private", updatedAt: result.updatedAt)
        return result
    }

    func get(slug: String, entries: Int = 10) async throws -> PageDetail {
        let data = try await request("/pages/\(slug)?entries=\(entries)", method: "GET")
        let detail = try JSONDecoder().decode(PageDetail.self, from: data)
        Self.rememberTitle(detail.title, forSlug: detail.slug)
        upsertSummary(slug: detail.slug, url: detail.url, title: detail.title,
                      visibility: detail.visibility, createdAt: detail.createdAt, updatedAt: detail.updatedAt)
        return detail
    }

    func update(slug: String, title: String?, body: String?, baseVersion: Int?) async throws -> PageWriteResult {
        var payload: [String: Any] = ["time_zone": TimeZone.current.identifier]
        if let title { payload["title"] = title }
        if let body { payload["body"] = body }
        if let baseVersion { payload["base_version"] = baseVersion }
        let data = try await request("/pages/\(slug)", method: "PUT", body: payload)
        let result = try JSONDecoder().decode(PageWriteResult.self, from: data)
        if let title { Self.rememberTitle(title, forSlug: slug) }
        upsertSummary(slug: result.slug, url: result.url, title: title, visibility: nil, updatedAt: result.updatedAt)
        return result
    }

    func append(slug: String, text: String) async throws -> PageWriteResult {
        let payload: [String: Any] = [
            "text": text,
            "time_zone": TimeZone.current.identifier,
        ]
        let data = try await request("/pages/\(slug)/entries", method: "POST", body: payload)
        let result = try JSONDecoder().decode(PageWriteResult.self, from: data)
        upsertSummary(slug: result.slug, url: result.url, title: nil, visibility: nil, updatedAt: result.updatedAt)
        return result
    }

    @discardableResult
    func list() async throws -> [PageSummary] {
        let data = try await request("/pages", method: "GET")
        let response = try JSONDecoder().decode(ListResponse.self, from: data)
        pages = response.pages
        for page in response.pages {
            Self.rememberTitle(page.title, forSlug: page.slug)
        }
        return response.pages
    }

    func refreshList() async {
        guard !loading else { return }
        loading = true
        lastError = nil
        defer { loading = false }
        do {
            _ = try await list()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setVisibility(slug: String, isPublic: Bool) async throws {
        let visibility = isPublic ? "public" : "private"
        let data = try await request("/pages/\(slug)/visibility", method: "POST",
                                     body: ["visibility": visibility])
        let updated = try JSONDecoder().decode(VisibilityResponse.self, from: data)
        if let i = pages.firstIndex(where: { $0.slug == slug }) {
            let old = pages[i]
            pages[i] = PageSummary(slug: old.slug, url: old.url, title: old.title,
                                   visibility: updated.visibility,
                                   createdAt: old.createdAt, updatedAt: old.updatedAt)
        }
    }

    func delete(slug: String) async throws {
        _ = try await request("/pages/\(slug)", method: "DELETE")
        pages.removeAll { $0.slug == slug }
        accessURLs.removeValue(forKey: slug)
    }

    func mintTicket(slug: String) async throws -> URL {
        let data = try await request("/pages/\(slug)/ticket", method: "POST", body: [:])
        let response = try JSONDecoder().decode(TicketResponse.self, from: data)
        guard let url = URL(string: response.url) else {
            throw PageError.unavailable("Invalid ticket URL.")
        }
        return url
    }

    /// Returns the page's permanent read-only capability URL (`/#k=<secret>`)
    /// for mobile chats (Signal, Telegram). Cached in memory per slug.
    func accessURL(slug: String, rotate: Bool = false) async throws -> URL {
        if !rotate, let cached = accessURLs[slug] {
            return cached
        }
        let body: [String: Any] = rotate ? ["rotate": true] : [:]
        let data = try await request("/pages/\(slug)/key", method: "POST", body: body)
        let response = try JSONDecoder().decode(TicketResponse.self, from: data)
        guard let url = URL(string: response.url) else {
            throw PageError.unavailable("Invalid access URL.")
        }
        accessURLs[slug] = url
        return url
    }

    /// Rewrites bare `https://<slug>.notch.website` URLs owned by this Mac in
    /// `text` to include their permanent `#k=<secret>` fragment so private pages
    /// open directly from Signal or Telegram.
    func rewriteWithAccessKeys(in text: String) async -> String {
        let found = Self.pageURLs(in: text)
        guard !found.isEmpty else { return text }
        var replacements: [String: String] = [:]
        for item in found {
            if let url = try? await accessURL(slug: item.slug) {
                replacements[item.slug] = url.absoluteString
            }
        }
        guard !replacements.isEmpty,
              let regex = try? NSRegularExpression(
                pattern: #"https://([a-z0-9](?:[a-z0-9-]{0,46}[a-z0-9])?)\.notch\.website(?:/[^\s)\]"'<>]*)?"#,
                options: [.caseInsensitive]
              ) else {
            return text
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = text
        for match in matches.reversed() {
            let full = ns.substring(with: match.range)
            let trimmed = full.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]'\"，。；：！？）"))
            let trailing = String(full.dropFirst(trimmed.count))
            guard let url = URL(string: trimmed),
                  let slug = Self.slug(from: url),
                  let replacement = replacements[slug],
                  url.fragment == nil,
                  url.query == nil,
                  url.path.isEmpty || url.path == "/" else { continue }
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement + trailing)
        }
        return result
    }

    /// Opens a `<slug>.notch.website` URL in the browser. Mints a one-time owner
    /// ticket first so private pages open directly; falls back to the bare URL
    /// if this Mac does not own the page (for example, someone else's public page).
    func open(_ url: URL) {
        guard let slug = Self.slug(from: url) else {
            NSWorkspace.shared.open(url)
            return
        }
        Task {
            if let ticketed = try? await mintTicket(slug: slug) {
                NSWorkspace.shared.open(ticketed)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Registers the paired Telegram bot + owner user id so the owner can open
    /// private pages inside Telegram via Mini App `initData` verification.
    func syncTelegram(botID: String, userID: Int64) async {
        guard !botID.isEmpty, userID > 0 else { return }
        if (try? await request("/pages/telegram", method: "PUT", body: [
            "bot_id": botID,
            "user_id": String(userID),
        ])) != nil {
            syncedTelegram = (botID, userID)
        }
    }

    func ensureTelegramSynced(botID: String, userID: Int64) async {
        if let synced = syncedTelegram, synced.botID == botID, synced.userID == userID { return }
        await syncTelegram(botID: botID, userID: userID)
    }

    func clearTelegram() async {
        syncedTelegram = nil
        guard NoNoAccount.shared.hasToken else { return }
        _ = try? await request("/pages/telegram", method: "DELETE")
    }
}

// MARK: - PageTool

/// Gives the model a `page` tool to create and continuously update minimalist
/// web pages at `https://<slug>.notch.website`. Pages are private by default;
/// only the user can make a page public (from the page itself or Settings).
struct PageTool: NotchTool {
    static let toolName = "page"
    let name = toolName

    let description = """
    Create and update minimalist web pages at https://<slug>.notch.website. \
    Pages are private to the user by default (you cannot make a page public; \
    the user shares it themselves if they want). \
    Use this when a task is ongoing or recurring (such as a /loop tracking prices, \
    news, metrics, or status over time), when a report is long or structured enough \
    to read better as a standalone page than a chat bubble, or when the user asks \
    for a page. After creating or updating a page, put its URL on its own line in \
    your reply and keep the chat text brief. \
    Content is Markdown and supports ```viz blocks (barh, line, donut, stat, card); \
    do not write raw HTML. \
    Actions: \
    action=create makes a new page (`title`, optional `body`, optional `slug_hint` in ASCII). \
    action=append prepends a timestamped update (`page_id`, `text`) — preferred for loop rounds and ongoing logs. \
    action=update replaces `title` and/or `body` (`page_id`, optional `base_version` from get). \
    action=get reads a page's current content, version, and recent updates (`page_id`). \
    action=list lists the user's pages — check it before creating a new page for a topic that may already exist.
    """

    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["create", "update", "append", "get", "list"],
                "description": "create a new page, append a timestamped update, update the main body/title, get current content, or list existing pages.",
            ],
            "page_id": [
                "type": "string",
                "description": "update/append/get: the page slug returned by create or list (e.g. \"btc-watch-7f3k\").",
            ],
            "title": [
                "type": "string",
                "description": "create (required) or update (optional): concise page title in the user's language.",
            ],
            "body": [
                "type": "string",
                "description": "create (optional) or update (optional): Markdown content (supports ```viz blocks, no raw HTML).",
            ],
            "slug_hint": [
                "type": "string",
                "description": "create only: short ASCII kebab-case hint for the subdomain prefix (e.g. \"btc-watch\", \"daily-brief\").",
            ],
            "text": [
                "type": "string",
                "description": "append only: Markdown for this timestamped update entry.",
            ],
            "base_version": [
                "type": "integer",
                "description": "update only: version number from a prior get, to avoid overwriting concurrent edits.",
            ],
        ],
        "required": ["action"],
    ]

    /// Notifies the active loop (for auto-binding).
    let onTouch: @Sendable (_ slug: String, _ title: String?, _ url: URL, _ created: Bool) async -> Void
    /// True when executing inside a scheduled loop round.
    let isLoopRound: Bool
    /// The page slug already bound to the running loop, if any.
    let boundLoopSlug: String?
    /// Asks the user before writing to a public page in a normal conversation.
    let confirmPublicWrite: @Sendable (_ slug: String, _ title: String, _ preview: String) async throws -> Bool

    init(isLoopRound: Bool = false,
         boundLoopSlug: String? = nil,
         confirmPublicWrite: @escaping @Sendable (_ slug: String, _ title: String, _ preview: String) async throws -> Bool = { _, _, _ in false },
         onTouch: @escaping @Sendable (_ slug: String, _ title: String?, _ url: URL, _ created: Bool) async -> Void = { _, _, _, _ in }) {
        self.isLoopRound = isLoopRound
        self.boundLoopSlug = boundLoopSlug
        self.confirmPublicWrite = confirmPublicWrite
        self.onTouch = onTouch
    }

    /// Blocks prompt injection from silently exfiltrating private data into a
    /// page the user previously made public:
    /// - Loop rounds may only write to their own bound page (`boundLoopSlug`).
    /// - Regular chat turns must get explicit user confirmation before writing
    ///   to any public page.
    private func authorizeWrite(slug: String, preview: String, service: PagesService) async throws -> String? {
        let detail = try await service.get(slug: slug, entries: 0)
        guard detail.visibility == "public" else { return nil }
        if isLoopRound {
            if boundLoopSlug == slug { return nil }
            return "Error: A loop round can only update its own bound page, not another public page."
        }
        let approved = try await confirmPublicWrite(slug, detail.title, preview)
        return approved ? nil : "Not written: the user declined updating this public page."
    }

    func execute(_ input: [String: Any]) async throws -> String {
        guard let action = input["action"] as? String else {
            return "Error: action must be one of create, update, append, get, list."
        }
        let service = await MainActor.run { PagesService.shared }

        switch action {
        case "create":
            guard let title = (input["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                return "Error: action=create requires a non-empty title."
            }
            let body = (input["body"] as? String) ?? ""
            let hint = input["slug_hint"] as? String
            let result = try await service.create(title: title, body: body, slugHint: hint)
            if let url = URL(string: result.url) {
                await onTouch(result.slug, result.title ?? title, url, true)
            }
            return "Created page.\npage_id: \(result.slug)\nurl: \(result.url)\nvisibility: private\nversion: \(result.version)"

        case "append":
            guard let slug = Self.cleanSlug(input["page_id"] as? String) else {
                return "Error: action=append requires page_id."
            }
            guard let text = (input["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return "Error: action=append requires non-empty text."
            }
            if let blocked = try await authorizeWrite(slug: slug, preview: String(text.prefix(160)), service: service) {
                return blocked
            }
            let result = try await service.append(slug: slug, text: text)
            if let url = URL(string: result.url) {
                await onTouch(result.slug, nil, url, false)
            }
            return "Appended update.\npage_id: \(result.slug)\nurl: \(result.url)\nversion: \(result.version)"

        case "update":
            guard let slug = Self.cleanSlug(input["page_id"] as? String) else {
                return "Error: action=update requires page_id."
            }
            let title = (input["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = input["body"] as? String
            guard title != nil || body != nil else {
                return "Error: action=update requires title and/or body."
            }
            let preview = String((body ?? title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
            if let blocked = try await authorizeWrite(slug: slug, preview: preview, service: service) {
                return blocked
            }
            let baseVersion = input["base_version"] as? Int
            let result = try await service.update(slug: slug, title: title, body: body, baseVersion: baseVersion)
            if let url = URL(string: result.url) {
                await onTouch(result.slug, title, url, false)
            }
            return "Updated page.\npage_id: \(result.slug)\nurl: \(result.url)\nversion: \(result.version)"

        case "get":
            guard let slug = Self.cleanSlug(input["page_id"] as? String) else {
                return "Error: action=get requires page_id."
            }
            let detail = try await service.get(slug: slug, entries: 10)
            var out = [
                "page_id: \(detail.slug)",
                "url: \(detail.url)",
                "title: \(detail.title)",
                "visibility: \(detail.visibility)",
                "version: \(detail.version)",
            ]
            if !detail.body.isEmpty {
                out.append("\n--- body ---\n\(detail.body)")
            }
            if !detail.entries.isEmpty {
                let df = ISO8601DateFormatter()
                let lines = detail.entries.map { entry in
                    "[\(df.string(from: Date(timeIntervalSince1970: entry.at / 1000)))]\n\(entry.text)"
                }.joined(separator: "\n\n")
                out.append("\n--- recent updates (\(detail.entries.count) of \(detail.entryCount)) ---\n\(lines)")
            }
            return out.joined(separator: "\n")

        case "list":
            let pages = try await service.list()
            if pages.isEmpty { return "No pages yet." }
            let df = ISO8601DateFormatter()
            // Visibility is omitted on purpose so untrusted prompt injections
            // cannot scan for public pages to exfiltrate data into.
            return pages.prefix(50).map { p in
                let updated = df.string(from: Date(timeIntervalSince1970: p.updatedAt / 1000))
                return "- \(p.slug) | \(p.title) | updated \(updated) | \(p.url)"
            }.joined(separator: "\n")

        default:
            return "Error: action must be one of create, update, append, get, list."
        }
    }

    private static func cleanSlug(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: trimmed), let fromURL = PagesService.slug(from: url) {
            return fromURL
        }
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Settings Pane

/// Lists pages created by this Mac so the user can open them, flip Public/Private,
/// copy the link, or delete them.
struct NotchiPagesPane: View {
    @ObservedObject private var service = PagesService.shared
    @State private var busySlug: String?
    @State private var copiedSlug: String?
    @State private var confirmPublicSlug: String?
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pages published at *.notch.website are private to this Mac until you share them.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") {
                    Task { await service.refreshList() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .disabled(service.loading)
            }

            if let error = actionError ?? service.lastError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            if service.loading && service.pages.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, 16)
            } else if service.pages.isEmpty {
                Text("No pages yet. Ask Notchi to create a page or let a recurring loop publish its updates.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(service.pages) { page in
                        row(for: page)
                        if page.id != service.pages.last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            }
        }
        .task { await service.refreshList() }
        .alert("Share this page publicly?", isPresented: Binding(
            get: { confirmPublicSlug != nil },
            set: { if !$0 { confirmPublicSlug = nil } }
        )) {
            Button("Cancel", role: .cancel) { confirmPublicSlug = nil }
            Button("Share Publicly") {
                if let slug = confirmPublicSlug {
                    confirmPublicSlug = nil
                    toggleVisibility(slug: slug, makePublic: true)
                }
            }
        } message: {
            Text("Anyone with the link will be able to read this page. Make sure it does not contain private notes, mail, or calendar details you do not want to share.")
        }
    }

    @ViewBuilder
    private func row(for page: PagesService.PageSummary) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(page.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(page.isPublic ? "Public" : "Private")
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(page.isPublic ? Color.green.opacity(0.16) : Color.primary.opacity(0.07),
                                    in: Capsule())
                        .foregroundStyle(page.isPublic ? Color.green : Color.secondary)
                }
                Text("\(page.slug).\(PagesService.domain) · \(relativeTime(page.updatedAt))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Open") {
                if let url = page.pageURL { service.open(url) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))

            Button(copiedSlug == page.slug ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(page.url, forType: .string)
                copiedSlug = page.slug
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if copiedSlug == page.slug { copiedSlug = nil }
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))

            Button(page.isPublic ? "Make Private" : "Share") {
                if page.isPublic {
                    toggleVisibility(slug: page.slug, makePublic: false)
                } else {
                    confirmPublicSlug = page.slug
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .disabled(busySlug == page.slug)

            Button(role: .destructive) {
                delete(slug: page.slug)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.borderless)
            .disabled(busySlug == page.slug)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func toggleVisibility(slug: String, makePublic: Bool) {
        busySlug = slug
        actionError = nil
        Task {
            defer { busySlug = nil }
            do {
                try await service.setVisibility(slug: slug, isPublic: makePublic)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func delete(slug: String) {
        busySlug = slug
        actionError = nil
        Task {
            defer { busySlug = nil }
            do {
                try await service.delete(slug: slug)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func relativeTime(_ ms: Double) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: Date(timeIntervalSince1970: ms / 1000), relativeTo: Date())
    }
}
