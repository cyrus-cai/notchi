import Foundation

/// A tool server that runs inside Notchi instead of over the network: the
/// connection speaks MCP to it the same way, so its tools are listed, deferred
/// and confirmed like any connector's.
protocol MCPLocalServer: Sendable {
    /// `tools/list` entries: name, description, inputSchema, annotations.
    var tools: [[String: Any]] { get }
    func call(_ name: String, _ arguments: [String: Any]) async throws -> String
}

final class MCPLocalTransport: MCPTransport, @unchecked Sendable {
    private let server: MCPLocalServer

    init(_ server: MCPLocalServer) {
        self.server = server
    }

    /// The local server for a connector that has one.
    static func server(for spec: MCPServerSpec) -> MCPLocalServer? {
        switch spec.oauthConnector {
        case "outlook": return OutlookServer()
        default: return nil
        }
    }

    func request(_ method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any] {
        switch method {
        case "initialize":
            return ["protocolVersion": MCPConnection.protocolVersion,
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "Notchi", "version": "1"]]
        case "tools/list":
            return ["tools": server.tools]
        case "tools/call":
            let name = params?["name"] as? String ?? ""
            let arguments = params?["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await server.call(name, arguments)
                return ["content": [["type": "text", "text": text]]]
            } catch {
                return ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
            }
        default:
            throw MCPError("Unknown method \(method).")
        }
    }

    func notify(_ method: String, params: [String: Any]?) async {}
    func setProtocolVersion(_ version: String) {}
    func close() {}
}

/// Outlook mail over Microsoft Graph, for personal and work accounts. Nothing
/// is sent: replies and new messages are saved as drafts for the user to send.
struct OutlookServer: MCPLocalServer {
    private static let connector = "outlook"
    private static let base = "https://graph.microsoft.com/v1.0"
    private static let listFields = "id,subject,from,receivedDateTime,bodyPreview,isRead,hasAttachments"
    private static let folders = ["inbox", "sentitems", "drafts", "archive", "deleteditems", "junkemail"]
    private static let bodyLimit = 8_000

    var tools: [[String: Any]] {
        [
            [
                "name": "list_messages",
                "description": "Lists the newest messages in an Outlook folder, newest first. unread_only lists only unread ones.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "folder": ["type": "string", "enum": Self.folders, "description": "Default inbox."],
                        "unread_only": ["type": "boolean"],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 30, "description": "Default 10."],
                    ],
                ],
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "search_messages",
                "description": "Searches every Outlook folder for messages whose sender, recipients, subject or text contain the words in `query`, such as an order number, a name or a topic.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 30, "description": "Default 10."],
                    ],
                    "required": ["query"],
                ],
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "read_message",
                "description": "Returns one Outlook message's sender, recipients, date and text, by the id from a list or search.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["id": ["type": "string"]],
                    "required": ["id"],
                ],
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "create_draft",
                "description": "Saves a new message in Outlook's Drafts. It is not sent; the user reviews and sends it.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "to": ["type": "array", "items": ["type": "string"], "description": "Email addresses."],
                        "cc": ["type": "array", "items": ["type": "string"]],
                        "subject": ["type": "string"],
                        "body": ["type": "string", "description": "Plain text, in the language and tone the user asked for."],
                    ],
                    "required": ["subject", "body"],
                ],
            ],
            [
                "name": "create_reply_draft",
                "description": "Saves a reply to an Outlook message in Drafts, with the original quoted below. It is not sent; the user reviews and sends it.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "The message replied to."],
                        "body": ["type": "string", "description": "Plain text, in the language and tone the user asked for."],
                        "reply_all": ["type": "boolean"],
                    ],
                    "required": ["id", "body"],
                ],
            ],
        ]
    }

    func call(_ name: String, _ arguments: [String: Any]) async throws -> String {
        let limit = min(max((arguments["limit"] as? Int) ?? 10, 1), 30)
        switch name {
        case "list_messages":
            let folder = (arguments["folder"] as? String).flatMap { Self.folders.contains($0) ? $0 : nil } ?? "inbox"
            var query = [
                URLQueryItem(name: "$top", value: String(limit)),
                URLQueryItem(name: "$select", value: Self.listFields),
                URLQueryItem(name: "$orderby", value: "receivedDateTime desc"),
            ]
            if arguments["unread_only"] as? Bool == true {
                // Graph wants the $orderby property to lead the $filter.
                query.append(URLQueryItem(name: "$filter",
                                          value: "receivedDateTime ge 1900-01-01T00:00:00Z and isRead eq false"))
            }
            let result = try await Self.graph("GET", "/me/mailFolders/\(folder)/messages", query: query)
            return Self.list(result, empty: "No messages.")
        case "search_messages":
            let text = ((arguments["query"] as? String) ?? "")
                .replacingOccurrences(of: "\"", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw MCPError("query is empty.") }
            let result = try await Self.graph("GET", "/me/messages", query: [
                URLQueryItem(name: "$search", value: "\"\(text)\""),
                URLQueryItem(name: "$top", value: String(limit)),
                URLQueryItem(name: "$select", value: Self.listFields),
            ])
            return Self.list(result, empty: "No messages match.")
        case "read_message":
            let id = try Self.id(arguments["id"])
            let message = try await Self.graph("GET", "/me/messages/\(id)", query: [
                URLQueryItem(name: "$select",
                             value: "subject,from,toRecipients,ccRecipients,receivedDateTime,body,hasAttachments,webLink"),
            ], headers: ["Prefer": "outlook.body-content-type=\"text\""])
            return Self.full(message)
        case "create_draft":
            let to = (arguments["to"] as? [String]) ?? []
            let cc = (arguments["cc"] as? [String]) ?? []
            let draft = try await Self.graph("POST", "/me/messages", body: [
                "subject": (arguments["subject"] as? String) ?? "",
                "body": ["contentType": "Text", "content": (arguments["body"] as? String) ?? ""],
                "toRecipients": to.map { ["emailAddress": ["address": $0]] },
                "ccRecipients": cc.map { ["emailAddress": ["address": $0]] },
            ])
            return Self.saved(draft)
        case "create_reply_draft":
            let id = try Self.id(arguments["id"])
            let action = arguments["reply_all"] as? Bool == true ? "createReplyAll" : "createReply"
            let draft = try await Self.graph("POST", "/me/messages/\(id)/\(action)", body: [
                "comment": (arguments["body"] as? String) ?? "",
            ])
            return Self.saved(draft)
        default:
            throw MCPError("Unknown tool \(name).")
        }
    }

    // MARK: - Graph

    private static func graph(_ method: String, _ path: String, query: [URLQueryItem] = [],
                              body: [String: Any]? = nil, headers: [String: String] = [:]) async throws -> [String: Any] {
        do {
            return try await send(method, path, query: query, body: body, headers: headers, refresh: false)
        } catch is Unauthorized {
            do {
                return try await send(method, path, query: query, body: body, headers: headers, refresh: true)
            } catch is Unauthorized {
                throw MCPError("Outlook refused the sign-in. Connect it again in Settings.")
            }
        }
    }

    private struct Unauthorized: Error {}

    private static func send(_ method: String, _ path: String, query: [URLQueryItem], body: [String: Any]?,
                             headers: [String: String], refresh: Bool) async throws -> [String: Any] {
        let token = try await MCPTokens.shared.accessToken(connector, forceRefresh: refresh)
        guard var comps = URLComponents(string: base + path) else { throw MCPError("Bad address.") }
        if !query.isEmpty { comps.queryItems = query }
        // `+` in $search must reach Graph encoded.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = comps.url else { throw MCPError("Bad address.") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await ProxyConfig.urlSession.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw Unauthorized() }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            throw MCPError("Outlook: \(message)")
        }
        return json
    }

    private static func id(_ value: Any?) throws -> String {
        guard let raw = value as? String, !raw.isEmpty else { throw MCPError("id is missing.") }
        return raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? raw
    }

    // MARK: - Text for the model

    private static func list(_ result: [String: Any], empty: String) -> String {
        let messages = (result["value"] as? [[String: Any]]) ?? []
        guard !messages.isEmpty else { return empty }
        return messages.map { m in
            var head = "- id: \(m["id"] as? String ?? "")\n  \(m["receivedDateTime"] as? String ?? "") | \(sender(m)) | \(m["subject"] as? String ?? "(no subject)")"
            if m["isRead"] as? Bool == false { head += " | unread" }
            if m["hasAttachments"] as? Bool == true { head += " | attachments" }
            let preview = (m["bodyPreview"] as? String ?? "")
                .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return preview.isEmpty ? head : head + "\n  " + String(preview.prefix(200))
        }.joined(separator: "\n")
    }

    private static func full(_ m: [String: Any]) -> String {
        var lines = [
            "From: \(sender(m))",
            "To: \(addresses(m["toRecipients"]))",
        ]
        let cc = addresses(m["ccRecipients"])
        if !cc.isEmpty { lines.append("Cc: \(cc)") }
        lines.append("Date: \(m["receivedDateTime"] as? String ?? "")")
        lines.append("Subject: \(m["subject"] as? String ?? "(no subject)")")
        if m["hasAttachments"] as? Bool == true { lines.append("Has attachments.") }
        if let link = m["webLink"] as? String { lines.append("Open in Outlook: \(link)") }
        var text = ((m["body"] as? [String: Any])?["content"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > bodyLimit {
            text = text.prefix(bodyLimit) + "\n[… \(text.count - bodyLimit) characters omitted …]"
        }
        return lines.joined(separator: "\n") + "\n\n" + text
    }

    private static func saved(_ draft: [String: Any]) -> String {
        var text = "Saved in Drafts. It has not been sent."
        if let link = draft["webLink"] as? String { text += "\nOpen it: \(link)" }
        return text
    }

    private static func sender(_ m: [String: Any]) -> String {
        let address = (m["from"] as? [String: Any])?["emailAddress"] as? [String: Any]
        let name = address?["name"] as? String ?? ""
        let email = address?["address"] as? String ?? ""
        return name.isEmpty || name == email ? email : "\(name) <\(email)>"
    }

    private static func addresses(_ value: Any?) -> String {
        ((value as? [[String: Any]]) ?? []).compactMap {
            ($0["emailAddress"] as? [String: Any])?["address"] as? String
        }.joined(separator: ", ")
    }
}
