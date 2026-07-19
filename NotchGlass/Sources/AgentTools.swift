import Foundation
import AppKit

// MARK: - Built-in agent tools
//
// The deliberately small tool surface: read what the user already copied, tell
// the time, do exact arithmetic, ask the user a clarifying question, run a web
// search, and read a web page's text. All read-only — no file-system writes, no
// shell, no computer-use; those high-blast-radius surfaces are intentionally out
// of scope. The harness advertises exactly this set; growing it is a matter of
// adding a `NotchTool` and registering it (see `ToolRegistry.standard(for:)`).

/// Current local date and time. The notch assistant has no clock of its own
/// (the model's knowledge has a cutoff), so any "what day is it / how long until
/// …" question needs this. Argument-less.
struct DateTimeTool: NotchTool {
    let name = "current_datetime"
    let description = """
    Returns the user's current local date, time, and timezone. Call this whenever \
    the answer depends on the current moment — "what day is it", "what time is \
    it", scheduling, "how long until X", or any relative-date reasoning. Do not \
    guess the date from training data; call this instead.
    """
    let schema: [String: Any] = ["type": "object", "properties": [:]]

    func execute(_ input: [String: Any]) async throws -> String {
        let now = Date()
        let fmt = DateFormatter()
        fmt.dateStyle = .full
        fmt.timeStyle = .long
        // Render in the user's chosen interface language so the model reads a date
        // string in the same language it's answering in.
        switch Localization.shared.language.resolved {
        case .en:     fmt.locale = Foundation.Locale(identifier: "en_US")
        case .zhHans: fmt.locale = Foundation.Locale(identifier: "zh_Hans")
        case .zhHant: fmt.locale = Foundation.Locale(identifier: "zh_Hant")
        }
        let tz = TimeZone.current
        return "\(fmt.string(from: now)) (timezone \(tz.identifier), UTC offset \(tz.secondsFromGMT() / 3600))"
    }
}

/// Read the system clipboard. This is how the *model* gets at what the user
/// copied ("summarize this", "what I copied") — explicit, on-demand access on
/// any turn, with no client-side injection heuristic. Returns text or
/// a short "nothing usable" note; never the raw pasteboard object.
struct ReadClipboardTool: NotchTool {
    let name = "read_clipboard"
    let description = """
    Returns the current text contents of the user's clipboard. Call this when the \
    user refers to "this", "what I copied", "the text above", or otherwise points \
    at content they've put on the clipboard that isn't already in the conversation.
    """
    let schema: [String: Any] = ["type": "object", "properties": [:]]

    /// Cap the returned text so a giant clipboard can't blow up the next turn's
    /// context. Mirrors the 1500-char gate the heuristic path uses, with headroom.
    private static let maxChars = 4000

    func execute(_ input: [String: Any]) async throws -> String {
        // NSPasteboard must be read on the main thread.
        let text: String? = await MainActor.run {
            NSPasteboard.general.string(forType: .string)
        }
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return "The clipboard is empty or holds no readable text."
        }
        return raw.count > Self.maxChars
            ? String(raw.prefix(Self.maxChars)) + "\n…(clipboard truncated)"
            : raw
    }
}

/// Exact arithmetic. LLMs reliably mangle multi-step or large-number math
/// (carry errors, dropped digits), so any numeric computation the user asks for
/// should run through a deterministic evaluator rather than the model's "head".
/// The evaluator is a small hand-written recursive-descent parser (see
/// `ArithmeticParser`) — deliberately NOT `NSExpression`, whose `format:`
/// initializer throws *ObjC* exceptions on malformed input (uncatchable by Swift
/// `try`, so a crash) and exposes a far wider surface (keypaths, `FUNCTION()`,
/// casts) than a calculator needs. The parser only understands `+ - * / ^`,
/// parentheses, unary minus, `%` (as ÷100), and a fixed whitelist of functions;
/// anything else is a thrown Swift error, never a crash.
struct CalculateTool: NotchTool {
    let name = "calculate"
    let description = """
    Evaluates an arithmetic expression exactly and returns the numeric result. \
    Call this for ANY calculation — arithmetic, percentages, tips, unit math, \
    multi-step sums — instead of computing in your head; models make silent \
    mistakes on large or chained numbers. Supports + - * / ^ (power), parentheses, \
    unary minus, a trailing or inline % (e.g. "18% of 240" → "0.18 * 240"), and \
    the functions sqrt, abs, ln, log, exp, sin, cos, tan, round, floor, ceil. \
    Pass the expression as a plain math string in `expression`.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "expression": [
                "type": "string",
                "description": "The arithmetic expression to evaluate, e.g. \"1234 * 5.6 + sqrt(81)\" or \"18% * 240\".",
            ],
        ],
        "required": ["expression"],
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        guard let expr = (input["expression"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expr.isEmpty else {
            return "Error: no expression given."
        }
        do {
            var parser = ArithmeticParser(expr)
            let value = try parser.evaluate()
            return Self.format(value)
        } catch let e as ArithmeticParser.ParseError {
            // A readable message the model can relay or recover from, not a crash.
            return "Error: \(e.message)"
        }
    }

    /// Render a `Double` without a trailing `.0` for whole numbers, and without
    /// floating-point noise (`0.1 + 0.2` → `0.3`, not `0.30000000000000004`).
    static func format(_ v: Double) -> String {
        guard v.isFinite else { return v.isNaN ? "not a number" : (v < 0 ? "-∞" : "∞") }
        if v == v.rounded() && abs(v) < 1e15 {
            return String(Int64(v))
        }
        // Up to 10 significant decimals, then strip trailing zeros.
        var s = String(format: "%.10g", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}

/// A minimal recursive-descent arithmetic evaluator. Grammar (lowest→highest
/// precedence): `expr = term (('+'|'-') term)*`, `term = factor (('*'|'/') factor)*`,
/// `factor = power ('^' factor)?` (right-assoc), `power = ('-')? primary`,
/// `primary = number | '(' expr ')' | func '(' expr ')'`. A trailing/inline `%`
/// on a number means ÷100. Every failure is a thrown `ParseError` — nothing here
/// can throw an ObjC exception, so it cannot crash the app on bad input.
struct ArithmeticParser {
    struct ParseError: Error { let message: String }

    private let chars: [Character]
    private var pos = 0

    init(_ input: String) {
        // Normalize a few common unicode operators the model (or a paste) might emit.
        let normalized = input
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-") // U+2212 minus
            .replacingOccurrences(of: ",", with: "")  // thousands separators
        self.chars = Array(normalized)
    }

    mutating func evaluate() throws -> Double {
        let v = try parseExpr()
        skipSpaces()
        guard pos == chars.count else {
            throw ParseError(message: "unexpected '\(chars[pos])' in expression.")
        }
        return v
    }

    // MARK: grammar

    private mutating func parseExpr() throws -> Double {
        var value = try parseTerm()
        while true {
            skipSpaces()
            guard let op = peek(), op == "+" || op == "-" else { break }
            advance()
            let rhs = try parseTerm()
            value = (op == "+") ? value + rhs : value - rhs
        }
        return value
    }

    private mutating func parseTerm() throws -> Double {
        var value = try parseFactor()
        while true {
            skipSpaces()
            guard let op = peek(), op == "*" || op == "/" else { break }
            advance()
            let rhs = try parseFactor()
            if op == "/" {
                guard rhs != 0 else { throw ParseError(message: "division by zero.") }
                value /= rhs
            } else {
                value *= rhs
            }
        }
        return value
    }

    private mutating func parseFactor() throws -> Double {
        let base = try parseUnary()
        skipSpaces()
        if peek() == "^" {
            advance()
            let exp = try parseFactor() // right-associative
            return pow(base, exp)
        }
        return base
    }

    private mutating func parseUnary() throws -> Double {
        skipSpaces()
        if peek() == "-" { advance(); return -(try parseUnary()) }
        if peek() == "+" { advance(); return try parseUnary() }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> Double {
        skipSpaces()
        guard let c = peek() else { throw ParseError(message: "expression ended unexpectedly.") }

        if c == "(" {
            advance()
            let v = try parseExpr()
            skipSpaces()
            guard peek() == ")" else { throw ParseError(message: "missing closing parenthesis.") }
            advance()
            return try applyPercent(to: v)
        }

        if c.isLetter {
            let fn = readIdentifier()
            skipSpaces()
            guard peek() == "(" else { throw ParseError(message: "unknown name '\(fn)'.") }
            advance()
            let arg = try parseExpr()
            skipSpaces()
            guard peek() == ")" else { throw ParseError(message: "missing ')' after \(fn)().") }
            advance()
            return try applyPercent(to: try apply(function: fn, to: arg))
        }

        if c.isNumber || c == "." {
            let n = try readNumber()
            return try applyPercent(to: n)
        }

        throw ParseError(message: "unexpected '\(c)'.")
    }

    /// A trailing `%` after a value means "÷100" (so `18%` → 0.18, `50% * 200` → 100).
    private mutating func applyPercent(to v: Double) throws -> Double {
        skipSpaces()
        if peek() == "%" { advance(); return v / 100 }
        return v
    }

    private func apply(function fn: String, to x: Double) throws -> Double {
        switch fn {
        case "sqrt":
            guard x >= 0 else { throw ParseError(message: "sqrt of a negative number.") }
            return x.squareRoot()
        case "abs":   return abs(x)
        case "ln":    return Foundation.log(x)
        case "log":   return Foundation.log10(x)
        case "exp":   return Foundation.exp(x)
        case "sin":   return Foundation.sin(x)
        case "cos":   return Foundation.cos(x)
        case "tan":   return Foundation.tan(x)
        case "round": return x.rounded()
        case "floor": return x.rounded(.down)
        case "ceil":  return x.rounded(.up)
        default:      throw ParseError(message: "unknown function '\(fn)'.")
        }
    }

    // MARK: lexing

    private mutating func readNumber() throws -> Double {
        let start = pos
        var seenDot = false
        while let c = peek(), c.isNumber || (c == "." && !seenDot) {
            if c == "." { seenDot = true }
            advance()
        }
        // Optional exponent: 1e3, 2.5E-4
        if let c = peek(), c == "e" || c == "E" {
            advance()
            if let s = peek(), s == "+" || s == "-" { advance() }
            while let d = peek(), d.isNumber { advance() }
        }
        let text = String(chars[start..<pos])
        guard let value = Double(text) else { throw ParseError(message: "bad number '\(text)'.") }
        return value
    }

    private mutating func readIdentifier() -> String {
        let start = pos
        while let c = peek(), c.isLetter { advance() }
        return String(chars[start..<pos]).lowercased()
    }

    private func peek() -> Character? { pos < chars.count ? chars[pos] : nil }
    private mutating func advance() { pos += 1 }
    private mutating func skipSpaces() { while let c = peek(), c == " " || c == "\t" { advance() } }
}

/// Ask the *user* a clarifying multiple-choice question mid-answer. The one tool
/// whose "execution" is a conversation: `execute` publishes the question to the
/// panel (a card with tappable options under the streaming answer) and suspends
/// until the user picks one — the picked option text is the tool result the model
/// reads back. The suspension is bounded: the user tapping an option, the round
/// being cancelled, or a timeout (the user walked away) each resume it exactly
/// once — see `NotchModel.awaitUserChoice`, which owns that state. The tool itself
/// stays UI-agnostic: the bridge closure is injected at registry construction.
struct AskUserTool: NotchTool {
    let name = "ask_user"
    let description = """
    Shows the user one multiple-choice question in the UI and returns the option \
    they pick. Call this ONLY when you are blocked on a decision that is genuinely \
    the user's to make and that materially changes the answer — an ambiguous \
    request with several plausible readings, or a choice between real alternatives \
    you cannot infer from context. Never use it for anything you can figure out \
    yourself or with your other tools, and ask at most one question per answer. \
    Give 2-4 short, distinct options covering the likely answers. The user may not \
    respond; in that case proceed with your best judgment and say what you assumed.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "question": [
                "type": "string",
                "description": "The single question to ask the user — short and specific.",
            ],
            "options": [
                "type": "array",
                "items": ["type": "string"],
                "minItems": 2,
                "maxItems": 4,
                "description": "2-4 short, mutually exclusive answer choices for the user to pick from.",
            ],
        ],
        "required": ["question", "options"],
    ]

    /// The UI bridge: present the question and suspend until an option is picked
    /// (or the wait ends another way). Injected by `NotchModel` when the registry
    /// is built for a round, capturing that round's answer turn.
    let present: @Sendable (_ question: String, _ options: [String]) async throws -> String

    func execute(_ input: [String: Any]) async throws -> String {
        guard let question = (input["question"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty else {
            return "Error: no question given."
        }
        // Normalize the options: trimmed, non-empty, de-duplicated (the option
        // strings are ForEach ids in the card), capped at 4.
        var seen = Set<String>()
        let options = ((input["options"] as? [Any]) ?? [])
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard options.count >= 2 else {
            return "Error: give at least 2 distinct options for the user to choose from."
        }
        return try await present(question, Array(options.prefix(4)))
    }
}

/// The description every client-side web-search tool advertises. One shared
/// string so the three backends (GLM / Exa / Keenable) never drift apart: the
/// model's search behavior should not change with the backend. Beyond the
/// when-to-search trigger it teaches the two habits that cut rounds and break
/// the re-search loop: batch independent queries into ONE turn (the harness
/// runs them concurrently — each extra round costs a full model round-trip),
/// and when snippets are close-but-not-quite, `read_page` the best result
/// instead of rewording the same query again.
let webSearchToolDescription = """
Searches the web for current, real-time information and returns the top \
results with sources and dates. Call this whenever the answer depends on \
information that may have changed or is past your knowledge cutoff — news, \
current events, today's prices or rates, the latest version of something, or \
anything time-sensitive. Prefer a focused query. When you need several \
independent facts, issue multiple search calls with different queries in the \
SAME turn — they run in parallel and save a round-trip. If the results look \
relevant but the snippets don't contain the specific fact you need, call \
read_page on the most promising result instead of searching again with a \
reworded query. If the results don't contain the answer, say so rather than \
guessing.
"""

/// Kimi's `$web_search` is a *builtin* server tool with an unusual contract
/// (XII-118): the model emits a tool call, and the client must echo the call's
/// arguments back **unchanged** for Moonshot to actually run the search
/// server-side. There is no local search to perform — this "tool" exists only so
/// the harness's ordinary tool loop has something to dispatch to instead of
/// failing on an unknown name, and its `execute` returns its own input re-encoded
/// as JSON, which is exactly the echo Kimi expects. Registered only for the Kimi
/// provider (see `ToolRegistry.standard(for:)`); never advertised — Kimi declares
/// the tool itself via the request's `builtin_function` entry, so this carries no
/// description/schema the model would ever read.
struct KimiWebSearchPassthrough: NotchTool {
    let name = "$web_search"
    let description = ""
    let schema: [String: Any] = ["type": "object", "properties": [:]]

    func execute(_ input: [String: Any]) async throws -> String {
        // Echo the model's arguments back verbatim as a JSON string — Moonshot
        // runs the real search on receiving this. Anything else (an error, a
        // summary, empty) means the search silently never happens.
        guard let data = try? JSONSerialization.data(withJSONObject: input),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

/// Real web search for GLM, via Zhipu's **standalone** Web Search API
/// (`/paas/v4/web_search`). XII-118 originally wired GLM as a "mode A" in-chat
/// `tools:[{web_search}]` entry, but live testing showed that path silently does
/// NOT search on the current account/models (glm-4.5-air / glm-4.6 / glm-4-air all
/// returned training-cutoff hallucinations with no `web_search` array) — exactly
/// the dishonest behavior XII-116 fought. The standalone API, by contrast, returns
/// genuine real-time results. So GLM search is a real *client-side* tool: the
/// model calls it, the harness hits the standalone endpoint with the user's GLM
/// key, and feeds the results back. This DOES drive the "🔍 searching" activity
/// line (it goes through the harness tool loop), unlike a true server-side search.
struct GLMWebSearchTool: SourcedTool {
    // NOT "web_search": that name collides with GLM's own built-in server-side
    // web_search tool, so glm-4.x mistakes this client tool for the builtin —
    // it ignores the results we feed back and re-calls the tool in a loop until
    // the iteration cap, then answers from training data (the stale/hallucinated
    // answers Cyrus saw). A distinct name makes the model treat it as an ordinary
    // function: it reads the fed-back results and answers from them. Verified live.
    let name = "lookup_web"
    let description = webSearchToolDescription
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "The search query."]
        ],
        "required": ["query"],
    ]

    private static let endpoint = URL(string: "https://open.bigmodel.cn/api/paas/v4/web_search")!
    private static let timeout: TimeInterval = 15
    private static let maxResults = 6

    // Conforms to the plain protocol via the sourced path: the model gets the
    // text, the UI gets the sources, both from one search.
    func execute(_ input: [String: Any]) async throws -> String {
        try await runSourced(input).text
    }

    func runSourced(_ input: [String: Any]) async throws -> (text: String, sources: [WebSource]) {
        guard let query = (input["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return ("Error: empty search query.", [])
        }
        // The tool reads the GLM key itself (same source as the service), so the
        // NotchTool protocol stays key-agnostic.
        guard let key = APIKeyStore.current(for: .glm) else {
            return ("Error: no GLM API key configured, can't search.", [])
        }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = Self.timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "search_engine": "search_pro",
            "search_query": query,
        ])

        do {
            let (data, response) = try await ProxyConfig.urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return ("Search failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).", [])
            }
            return Self.parse(data, query: query)
        } catch {
            return ("Search failed: \(error.localizedDescription)", [])
        }
    }

    /// Parse the standalone API's `{ search_result: [{title, content, link,
    /// publish_date, …}] }` once into BOTH the model-facing text (a compact, dated,
    /// sourced block it grounds on — with an explicit "no results" so it never
    /// invents an answer) and the structured `[WebSource]` for the UI badge. Only
    /// results carrying a usable http(s) link become badge sources; the text still
    /// includes link-less results so the model can use them.
    private static func parse(_ data: Data, query: String) -> (text: String, sources: [WebSource]) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["search_result"] as? [[String: Any]], !results.isEmpty else {
            let miss = "The search returned no results for \"\(query)\". Do not fabricate "
                     + "an answer — tell the user the search found nothing on this."
            return (miss, [])
        }
        let top = results.prefix(maxResults)
        let blocks = top.enumerated().map { (i, r) -> String in
            let title = (r["title"] as? String) ?? "(untitled)"
            let date = (r["publish_date"] as? String).map { " (\($0))" } ?? ""
            let link = (r["link"] as? String).flatMap { $0.isEmpty ? nil : "\n   \($0)" } ?? ""
            var snippet = (r["content"] as? String) ?? ""
            if snippet.count > 500 { snippet = String(snippet.prefix(500)) + "…" }
            return "[\(i + 1)] \(title)\(date)\n   \(snippet)\(link)"
        }
        let text = "Web search results for \"\(query)\":\n\n" + blocks.joined(separator: "\n\n")

        var seen = Set<String>()
        let sources: [WebSource] = top.compactMap { r in
            guard let link = r["link"] as? String,
                  let scheme = URL(string: link)?.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  !seen.contains(link) else { return nil }
            seen.insert(link)
            let title = (r["title"] as? String) ?? link
            let date = (r["publish_date"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return WebSource(title: title, url: link, date: date)
        }
        return (text, sources)
    }
}

/// Provider-agnostic web search via **Exa** (`https://api.exa.ai/search`). Unlike
/// `GLMWebSearchTool` (which reuses the GLM provider's key and only exists because
/// GLM's in-chat search silently no-ops), Exa is a standalone search backend with
/// its own key (`APIKeyStore.currentExaKey()` / `EXA_API_KEY`). When that key is
/// present this tool is registered for *every* provider and the providers' own
/// native server-side search is suppressed — Exa becomes the single searcher for
/// all backends (the point: a better, fresher, cheaper replacement than each
/// vendor's built-in search). Like the GLM tool it is a `SourcedTool`: one call
/// yields both the model-facing grounded text and the `[WebSource]` badge data.
///
/// Request shape follows Exa's coding-agent guide: `type:"auto"` (balanced
/// relevance/speed), `numResults`, and `contents:{highlights:true}` for
/// token-efficient, query-relevant excerpts. Response: `results[]` each carrying
/// `title`, `url`, `publishedDate`, and a `highlights` string array (with `text`
/// as a fallback when a result has no highlights).
struct ExaWebSearchTool: SourcedTool {
    let name = "exa_search"
    let description = webSearchToolDescription
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "The search query."]
        ],
        "required": ["query"],
    ]

    private static let endpoint = URL(string: "https://api.exa.ai/search")!
    private static let timeout: TimeInterval = 15
    private static let maxResults = 6

    func execute(_ input: [String: Any]) async throws -> String {
        try await runSourced(input).text
    }

    func runSourced(_ input: [String: Any]) async throws -> (text: String, sources: [WebSource]) {
        guard let query = (input["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return ("Error: empty search query.", [])
        }
        guard let key = APIKeyStore.currentExaKey() else {
            return ("Error: no Exa API key configured, can't search.", [])
        }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = Self.timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Exa authenticates with an `x-api-key` header, not a Bearer token.
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "query": query,
            "type": "auto",
            "numResults": Self.maxResults,
            "contents": ["highlights": true],
        ])

        do {
            let (data, response) = try await ProxyConfig.urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return ("Search failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).", [])
            }
            return Self.parse(data, query: query)
        } catch {
            return ("Search failed: \(error.localizedDescription)", [])
        }
    }

    /// Parse Exa's `{ results: [{title, url, publishedDate, highlights:[...],
    /// text}] }` once into BOTH the model-facing text (a compact, dated, sourced
    /// block it grounds on — with an explicit "no results" so it never invents an
    /// answer) and the structured `[WebSource]` for the UI badge. The snippet is
    /// the joined `highlights`, falling back to `text` when a result has none.
    private static func parse(_ data: Data, query: String) -> (text: String, sources: [WebSource]) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]], !results.isEmpty else {
            let miss = "The search returned no results for \"\(query)\". Do not fabricate "
                     + "an answer — tell the user the search found nothing on this."
            return (miss, [])
        }
        let top = results.prefix(maxResults)
        let blocks = top.enumerated().map { (i, r) -> String in
            let title = (r["title"] as? String) ?? "(untitled)"
            let date = (r["publishedDate"] as? String).flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
            let link = (r["url"] as? String).flatMap { $0.isEmpty ? nil : "\n   \($0)" } ?? ""
            var snippet = snippetText(from: r)
            if snippet.count > 500 { snippet = String(snippet.prefix(500)) + "…" }
            return "[\(i + 1)] \(title)\(date)\n   \(snippet)\(link)"
        }
        let text = "Web search results for \"\(query)\":\n\n" + blocks.joined(separator: "\n\n")

        var seen = Set<String>()
        let sources: [WebSource] = top.compactMap { r in
            guard let link = r["url"] as? String,
                  let scheme = URL(string: link)?.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  !seen.contains(link) else { return nil }
            seen.insert(link)
            let title = (r["title"] as? String) ?? link
            let date = (r["publishedDate"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return WebSource(title: title, url: link, date: date)
        }
        return (text, sources)
    }

    /// The result's query-relevant excerpt: the joined `highlights` array, or the
    /// full `text` when highlights are absent (e.g. a result Exa couldn't excerpt).
    private static func snippetText(from r: [String: Any]) -> String {
        if let highlights = r["highlights"] as? [String] {
            let joined = highlights
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " … ")
            if !joined.isEmpty { return joined }
        }
        return (r["text"] as? String) ?? ""
    }
}

/// Web search via **Keenable** (`https://api.keenable.ai/v1/search`). A standalone
/// search backend keyed by `APIKeyStore.currentKeenableKey()` / `KEENABLE_API_KEY`.
/// NOTE: despite Keenable's "no API key required" marketing (which applies only to
/// its CLI/MCP, not the raw HTTP API), the `/v1/search` endpoint *always* requires
/// an `X-API-Key` header — a keyless call returns 401. So this tool is only
/// registered when a Keenable key is configured.
///
/// Precedence: Exa wins when its key is set; else Keenable when *its* key is set
/// (`ToolRegistry.standard(for:)`). Like the other client search tools it is a
/// `SourcedTool`: one call yields both the model-facing grounded text and the
/// `[WebSource]` badge data.
///
/// Request: `POST /v1/search` with `{ "query": ... }`. Response: `results[]` each
/// carrying `title`, `url`, `snippet` (query-relevant highlights, falling back to
/// `description`), and `published_at` (ISO 8601).
struct KeenableWebSearchTool: SourcedTool {
    let name = "keenable_search"
    let description = webSearchToolDescription
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "The search query."]
        ],
        "required": ["query"],
    ]

    private static let endpoint = URL(string: "https://api.keenable.ai/v1/search")!
    private static let timeout: TimeInterval = 15
    // Keenable always returns ~10 results and ignores any count param (sending one
    // makes it return 0). Empirically its relevance ranking is solid for the first
    // few and then pads the tail with off-topic filler, so we keep only the top
    // (post-filtering) handful rather than feeding the model the noisy tail.
    private static let maxResults = 4

    func execute(_ input: [String: Any]) async throws -> String {
        try await runSourced(input).text
    }

    func runSourced(_ input: [String: Any]) async throws -> (text: String, sources: [WebSource]) {
        guard let query = (input["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return ("Error: empty search query.", [])
        }
        guard let key = APIKeyStore.currentKeenableKey() else {
            return ("Error: no Keenable API key configured, can't search.", [])
        }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = Self.timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The HTTP API mandates `X-API-Key` (a keyless call 401s, despite the
        // "no key" CLI/MCP marketing).
        req.setValue(key, forHTTPHeaderField: "X-API-Key")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])

        do {
            let (data, response) = try await ProxyConfig.urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return ("Search failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).", [])
            }
            return Self.parse(data, query: query)
        } catch {
            return ("Search failed: \(error.localizedDescription)", [])
        }
    }

    /// Parse Keenable's `{ results: [{title, url, snippet, description,
    /// published_at}] }` once into BOTH the model-facing text (a compact, dated,
    /// sourced block it grounds on — with an explicit "no results" so it never
    /// invents an answer) and the structured `[WebSource]` for the UI badge. The
    /// snippet is `snippet`, falling back to `description` when a result has none.
    private static func parse(_ data: Data, query: String) -> (text: String, sources: [WebSource]) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else {
            let miss = "The search returned no results for \"\(query)\". Do not fabricate "
                     + "an answer — tell the user the search found nothing on this."
            return (miss, [])
        }
        // Drop empty-shell results (no usable excerpt — Keenable's tail padding is
        // often a bare title with no snippet/description, e.g. "- YouTube"), THEN
        // take the top few. Filtering before the cap keeps the kept count honest.
        let usable = results.filter { !snippetText(from: $0).isEmpty }
        guard !usable.isEmpty else {
            let miss = "The search returned no results for \"\(query)\". Do not fabricate "
                     + "an answer — tell the user the search found nothing on this."
            return (miss, [])
        }
        let top = usable.prefix(maxResults)
        let blocks = top.enumerated().map { (i, r) -> String in
            let title = (r["title"] as? String) ?? "(untitled)"
            let date = (r["published_at"] as? String).flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
            let link = (r["url"] as? String).flatMap { $0.isEmpty ? nil : "\n   \($0)" } ?? ""
            var snippet = snippetText(from: r, title: title)
            if snippet.count > 280 { snippet = String(snippet.prefix(280)) + "…" }
            return "[\(i + 1)] \(title)\(date)\n   \(snippet)\(link)"
        }
        let text = "Web search results for \"\(query)\":\n\n" + blocks.joined(separator: "\n\n")

        var seen = Set<String>()
        let sources: [WebSource] = top.compactMap { r in
            guard let link = r["url"] as? String,
                  let scheme = URL(string: link)?.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  !seen.contains(link) else { return nil }
            seen.insert(link)
            let title = (r["title"] as? String) ?? link
            let date = (r["published_at"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return WebSource(title: title, url: link, date: date)
        }
        return (text, sources)
    }

    /// The result's query-relevant excerpt: `snippet`, falling back to the meta
    /// `description` when a result carries no snippet. Keenable often prefixes the
    /// snippet with the page title (and sometimes a date) — redundant once we print
    /// the title on its own line — so when a `title` is given we strip that leading
    /// echo. Called with no title from the empty-shell filter (pure presence check).
    private static func snippetText(from r: [String: Any], title: String? = nil) -> String {
        var text = (r["snippet"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
            text = ((r["description"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let title, !title.isEmpty, text.hasPrefix(title) else { return text }
        // Strip the echoed title and any immediately-following date (e.g.
        // "Title 2025-09-13 actual summary…") plus leading separators.
        var rest = Substring(text.dropFirst(title.count))
        rest = rest.drop { " \t\n-–—:|·•".contains($0) }
        if let m = rest.range(of: #"^\d{4}-\d{2}-\d{2}\s*"#, options: .regularExpression) {
            rest = rest[m.upperBound...]
        }
        let cleaned = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only use the stripped version if something substantive remains.
        return cleaned.isEmpty ? text : cleaned
    }
}

/// Fetches one web page and returns its readable text. The companion to web
/// search: search surfaces *which* page has the answer (title + short snippet),
/// but the snippet often doesn't contain the specific fact the user asked for.
/// Rather than re-search with a reworded query (the runaway loop `searchStopNudge`
/// fights), the model calls `read_page` on the most promising result and reads the
/// actual page. Input is a single `url` string — normally one the model just saw
/// in a search result. HTML is stripped to plain text and truncated to a few KB so
/// a long article doesn't blow the reply budget.
///
/// Read-only and same-shape as the rest of the surface: no cookies, no JS, a hard
/// timeout, and it only follows `http(s)` — a bad/blocked/oversized page comes back
/// as a short error string the model can adapt to, never a thrown turn-killer.
struct ReadPageTool: NotchTool {
    let name = "read_page"
    let description = """
    Fetches a web page and returns its readable text. Use this after a web search \
    when a result looks like it has the answer but its snippet is too short to be \
    sure — call read_page on that result's URL to read the actual page instead of \
    searching again with a different query. Input is the page URL (typically one \
    from a search result). Returns the page's main text, trimmed; if the page \
    can't be fetched, say so rather than guessing.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "url": ["type": "string", "description": "The full http(s) URL of the page to read."]
        ],
        "required": ["url"],
    ]

    private static let timeout: TimeInterval = 15
    /// Cap the extracted text so one long article can't swallow the reply budget.
    /// ~8k characters is a few pages of prose — enough to hold the answer, small
    /// enough to leave the model room to actually respond.
    private static let maxChars = 8000
    /// Refuse to download an enormous body (a media file, a huge page) — we only
    /// want text, and streaming megabytes just to throw them away wastes time.
    private static let maxBytes = 2_000_000

    func execute(_ input: [String: Any]) async throws -> String {
        guard let raw = (input["url"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "Error: no url provided."
        }
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return "Error: \"\(raw)\" is not a valid http(s) URL."
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = Self.timeout
        // A real UA — some sites 403 the default URLSession agent.
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await ProxyConfig.urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return "Error: no response from \(url.host ?? raw)."
            }
            guard (200..<300).contains(http.statusCode) else {
                return "Error: \(url.host ?? raw) returned HTTP \(http.statusCode)."
            }
            if data.count > Self.maxBytes {
                return "Error: \(url.host ?? raw) is too large to read (\(data.count / 1000) KB)."
            }
            // Decode as UTF-8, falling back to Latin-1 so a mis-declared page still
            // yields *something* readable rather than an empty string.
            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            let text = Self.extractText(from: html)
            guard !text.isEmpty else {
                return "The page at \(url.host ?? raw) had no readable text (it may be a "
                     + "media file or rendered entirely by JavaScript). Do not fabricate its "
                     + "contents."
            }
            let clipped = text.count > Self.maxChars
                ? String(text.prefix(Self.maxChars)) + "\n\n[…page truncated…]"
                : text
            return "Content of \(raw):\n\n\(clipped)"
        } catch {
            return "Error fetching \(url.host ?? raw): \(error.localizedDescription)"
        }
    }

    /// Strip HTML to readable plain text. Not a full parser — a pragmatic cleaner:
    /// drop `<script>`/`<style>`/`<head>` wholesale (their contents are never
    /// prose), turn block-level tags into newlines so paragraphs survive, remove the
    /// remaining tags, decode the handful of entities that actually show up, then
    /// collapse the runaway whitespace that stripping leaves behind.
    static func extractText(from html: String) -> String {
        var s = html
        // Remove whole non-content elements, contents and all. `(?s)` (dotall) is
        // load-bearing: these blocks span newlines in every real page, and without
        // it `.` stops at line breaks and the script/style innards leak into the
        // extracted text (verified against NSRegularExpression's default).
        for tag in ["script", "style", "head", "noscript", "svg", "template"] {
            s = s.replacingOccurrences(
                of: "(?s)<\(tag)\\b[^>]*>.*?</\(tag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive])
        }
        // Block-level tags → newline, so paragraph/heading/list structure survives
        // as line breaks instead of words running together.
        s = s.replacingOccurrences(
            of: "<(br|/p|/div|/li|/h[1-6]|/tr|/table|/section|/article|p|div|li|h[1-6]|tr)\\b[^>]*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive])
        // Strip every remaining tag.
        s = s.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode the entities that actually appear in prose. Ordered array, not a
        // dictionary: `&amp;` must decode LAST or a literal `&amp;lt;` (a page
        // displaying the text "&lt;") double-decodes into `<` — and a dictionary's
        // iteration order would make that a coin flip per run.
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&mdash;", "—"),
            ("&ndash;", "–"), ("&hellip;", "…"), ("&rsquo;", "'"), ("&lsquo;", "'"),
            ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"),
            ("&amp;", "&"),
        ]
        for (ent, ch) in entities { s = s.replacingOccurrences(of: ent, with: ch) }
        // Numeric entities (&#123; / &#x1F600;) → their scalar.
        s = decodeNumericEntities(s)
        // Collapse whitespace: many spaces/tabs → one space; 3+ newlines → two
        // (keep a paragraph break, drop the rest). Trim each line's edges.
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        s = lines.joined(separator: "\n")
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replace `&#NNN;` / `&#xHHH;` numeric character references with their scalar.
    private static func decodeNumericEntities(_ s: String) -> String {
        guard s.contains("&#") else { return s }
        var out = ""
        var rest = Substring(s)
        while let amp = rest.range(of: "&#") {
            out += rest[..<amp.lowerBound]
            let after = rest[amp.upperBound...]
            guard let semi = after.firstIndex(of: ";") else {
                out += rest[amp.lowerBound...]; return out
            }
            let body = after[..<semi]
            let scalarValue: UInt32?
            if let f = body.first, f == "x" || f == "X" {
                scalarValue = UInt32(body.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(body, radix: 10)
            }
            if let v = scalarValue, let scalar = Unicode.Scalar(v) {
                out.append(Character(scalar))
            } else {
                out += "&#\(body);"  // not a valid ref — leave it be
            }
            rest = after[after.index(after: semi)...]
        }
        out += rest
        return out
    }
}

// MARK: - Default registry

extension ToolRegistry {
    /// The standard tool set handed to the agent for a given provider. Built once
    /// per submit; an unconfigured/offline session can be given `ToolRegistry([])`
    /// instead to force the plain non-agent path.
    ///
    /// For most providers, real web search is NOT a tool here — it's the
    /// provider's own server-side search, injected into the request by `streamTurn`
    /// off `Provider.serverSearch` (XII-118). Two providers are client-side
    /// exceptions, both added here per provider:
    ///  • **GLM** — its in-chat `tools:[{web_search}]` path silently doesn't search
    ///    on the current account/models (verified live), so GLM uses a real
    ///    client-side `GLMWebSearchTool` that hits Zhipu's standalone search API.
    ///  • **Kimi** — its builtin search needs a client-side echo, so the
    ///    `$web_search` passthrough is added so the harness can echo the call back.
    /// (The defunct DuckDuckGo `WebSearchTool` was removed — see XII-116/XII-118.)
    ///
    /// **Unified searcher (optional, keyed, user-chosen).** A single client-side
    /// search tool can replace every provider's native search — the server-search
    /// gate in `streamTurn` and the GLM/Kimi client tools below all defer to it.
    /// Which one is the user's choice, not a hard-coded vendor preference:
    /// `APIKeyStore.resolvedSearchBackend()` maps their picked search backend
    /// (Keenable / Exa) plus whether it's keyed to the tool that runs. When it
    /// returns `nil` (nothing picked, or the pick has no key), the provider's own
    /// native search (GLM client tool / Kimi echo / server-side search) stays in play.
    static func standard(for provider: Provider) -> ToolRegistry {
        var tools: [NotchTool] = [
            DateTimeTool(),
            ReadClipboardTool(),
            CalculateTool(),
            ReadPageTool(),
        ]
        switch APIKeyStore.resolvedSearchBackend() {
        case .exa:
            tools.append(ExaWebSearchTool())
        case .keenable:
            tools.append(KeenableWebSearchTool())
        // No client searcher picked (or the pick has no key) — the provider's own
        // native search stays in play.
        case nil:
            if provider == .glm {
                tools.append(GLMWebSearchTool())
            }
            if provider.builtinSearchName == "$web_search" {
                tools.append(KimiWebSearchPassthrough())
            }
        }
        return ToolRegistry(tools)
    }

    /// Provider-agnostic default, kept for call sites that don't yet thread a
    /// provider through (it omits any provider-specific builtin like Kimi's echo).
    static var standard: ToolRegistry { ToolRegistry([
        DateTimeTool(), ReadClipboardTool(), CalculateTool(), ReadPageTool(),
    ]) }
}
