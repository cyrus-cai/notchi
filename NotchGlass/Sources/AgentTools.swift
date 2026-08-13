import Foundation
import AppKit
import Carbon.HIToolbox

// MARK: - Built-in agent tools
//
// The deliberately small tool surface: read what the user already copied, tell
// the time, do exact arithmetic, search the user's own Notch archive, ask the
// user a clarifying question, run a web search, read a web page's text, and
// manage this app's own preferences. The settings tool is the single narrow
// write surface and has a mandatory in-app confirmation gate; there are still no
// file-system writes, shell, or computer-use tools. The harness advertises
// exactly this set; growing it is a matter of adding a `NotchTool` and
// registering it (see `ToolRegistry.standard(for:)`, or — for a tool that needs
// the live model, like `search_history` / `ask_user` / `manage_app_settings` —
// the per-round append in `NotchModel.submit`).

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
        case .ja:     fmt.locale = Foundation.Locale(identifier: "ja_JP")
        case .ko:     fmt.locale = Foundation.Locale(identifier: "ko_KR")
        case .fr:     fmt.locale = Foundation.Locale(identifier: "fr_FR")
        case .es:     fmt.locale = Foundation.Locale(identifier: "es_ES")
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

/// Open a URL in the user's default browser. A visible, side-effecting action —
/// a window jumps in front of whatever the user was doing — so it is gated on
/// *intent*, not on usefulness: the description below (reinforced by the persona
/// in `notchSystemPrompt`) forbids calling it for any research purpose. Looking
/// something up is what `read_page` and the search tools are for; this tool
/// exists only to carry out an explicit "open / visit / take me to that page".
/// The scheme is validated to http/https so the model can't open arbitrary
/// `file://`, `x-apple-…`, or app-scheme URLs.
struct OpenURLTool: NotchTool {
    let name = "open_url"
    let description = """
    Opens a web URL in the user's default browser, taking over their screen. Call \
    this ONLY when the user explicitly asked you to open, visit, launch, or go to \
    a page in this very message — the words have to be theirs. NEVER call it to \
    look something up, check a page, verify a fact, gather information, or show \
    the user a source you found: reading a page is read_page's job and searching \
    is the search tool's job, and neither ever justifies opening a browser. If you \
    merely think a link would be useful, write it in your answer as a Markdown \
    link and let the user decide. When in doubt, do not call this tool. Use the \
    full https URL the user meant.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "url": ["type": "string", "description": "The full http(s) URL to open. Only when the user explicitly asked for it to be opened."]
        ],
        "required": ["url"]
    ]

    func execute(_ input: [String: Any]) async throws -> String {
        guard let s = input["url"] as? String,
              let url = URL(string: s),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return "Error: not a valid http(s) URL."
        }
        let ok = await MainActor.run { NSWorkspace.shared.open(url) }
        return ok ? "Opened \(url.absoluteString)." : "Couldn't open \(url.absoluteString)."
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

// MARK: - App settings

/// Provider-neutral request passed from `manage_app_settings` into the live
/// `NotchModel`. Keeping the tool itself UI-agnostic mirrors `AskUserTool`: the
/// model owns both the confirmation card and the handful of published settings
/// that must update immediately rather than only on the next launch.
struct AppSettingsRequest: Sendable {
    enum Action: String, Sendable { case list, shortcuts, update, open }

    struct Change: Sendable {
        let setting: String
        let value: String
        let scope: String?
        /// Free instruction text, used only by `prompt_shortcut` — that setting
        /// binds a chord *and* the sentence it runs, which no scalar value can
        /// carry without inventing an escaping scheme.
        let prompt: String?

        init(setting: String, value: String, scope: String?, prompt: String? = nil) {
            self.setting = setting
            self.value = value
            self.scope = scope
            self.prompt = prompt
        }
    }

    let action: Action
    let changes: [Change]
    let section: String?
}

/// Read or change Notch's own preferences from the chat composer. Reads are
/// immediate; writes are deliberately routed through `NotchModel`, which shows
/// one in-answer Confirm/Cancel card and only commits after Confirm is tapped.
/// A batch is one request and therefore one confirmation — "hide both icons and
/// don't launch at login" should never make the user approve three times.
struct ManageAppSettingsTool: NotchTool {
    let name = "manage_app_settings"
    let description = """
    Reads, opens, or changes this Notch app's settings. Use this whenever the user asks in \
    natural language to view, enable, disable, or change a Notch preference. For \
    an explicit change, call action=update directly: the tool itself always shows \
    exactly one Confirm/Cancel card before writing, so NEVER ask for a separate \
    confirmation with ask_user and never claim success before reading the result. \
    Put multiple requested changes in one call so they share one confirmation.

    Supported setting ids and values:
    - app_language: system, english, chinese_simplified, chinese_traditional, japanese, korean, french, spanish
    - dock_icon / menu_bar_icon: shown or hidden
    - launch_at_login / hide_in_fullscreen / live_activity / copy_sense: true or false
    - display_placement: all or built_in
    - hover_sensitivity: low, balanced, or instant
    - note_destination: apple_notes or markdown_folder; notes_folder: absolute path
    - summon_shortcut: disabled, default, double_option, double_command, double_control, double_shift, or a chord such as command+shift+k
    - action_shortcut: a chord such as command+shift+c, or default to restore the shipped one. \
    scope is required: copy_answer, regenerate, pin, new_chat, filter, picker, or detach
    - prompt_shortcut: a global chord such as option+s that runs one saved instruction on \
    whatever text is selected in any app. Value is the chord, or remove to delete a binding, \
    or keep to edit only its text. `prompt` carries the instruction and is required when \
    creating one. `scope` picks an existing binding by its current chord (option+s) or by a \
    distinctive part of its prompt; omit scope to create a new binding.
    - custom_instructions: text (empty clears it); proxy: URL/host, or auto to clear the manual proxy
    - ai_provider: openrouter, vercel, openai, codex, claude_code, grok_code, command_code, anthropic, gemini, deepseek, qwen, glm, kimi, minimax, mimo, custom
    - ai_model: model id or default; optional scope is a provider (defaults to the active provider)
    - api_key: key text or empty to remove; scope is the provider (defaults to active). Never read keys back.
    - search_backend: native, keenable, exa, or anysearch
    - search_api_key: key text or empty to remove; scope must be keenable, exa, or anysearch. Never read keys back.
    - custom_provider_name / custom_provider_url / custom_provider_model: text (empty clears it)

    action=list returns every current value (keys only report configured/not configured). \
    action=shortcuts returns the complete localized keyboard-shortcut reference, including \
    the user's current summon shortcut, every editable action with its scope id, and the \
    user's prompt shortcuts. Use it whenever the user asks what shortcuts, hotkeys, or key \
    commands the app supports, and ALWAYS read it before changing action_shortcut or \
    prompt_shortcut so the scope you send points at a binding that really exists. \
    action=open opens the relevant in-app Settings page without changing anything; \
    section must be model, search, notes, general, appearance, shortcuts, or about. Use open \
    when the user asks for an unsupported value (for example an interface language \
    the app does not offer), so they land on the real available choices instead of \
    receiving only a textual refusal. Opening a page needs no confirmation. \
    For action=update, `changes` is required. Each change has setting, value, and \
    optional scope. Use canonical values above even when the user speaks another language.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["list", "shortcuts", "update", "open"],
                "description": "List current settings, return the shortcut reference, open a settings page, or request a confirmed update.",
            ],
            "section": [
                "type": "string",
                "enum": ["model", "search", "notes", "general", "appearance", "shortcuts", "about"],
                "description": "The page to open when action=open.",
            ],
            "changes": [
                "type": "array",
                "minItems": 1,
                "maxItems": 12,
                "items": [
                    "type": "object",
                    "properties": [
                        "setting": ["type": "string", "description": "A supported setting id."],
                        "value": [
                            "oneOf": [["type": "string"], ["type": "boolean"]],
                            "description": "The new string or boolean value.",
                        ],
                        "scope": [
                            "type": "string",
                            "description": "Provider/backend, the action id for action_shortcut, or the binding selector for prompt_shortcut.",
                        ],
                        "prompt": [
                            "type": "string",
                            "description": "The instruction a prompt_shortcut runs on the selection. Only used by prompt_shortcut.",
                        ],
                    ],
                    "required": ["setting", "value"],
                ],
            ],
        ],
        "required": ["action"],
    ]

    let handle: @Sendable (AppSettingsRequest) async throws -> String

    func execute(_ input: [String: Any]) async throws -> String {
        guard let rawAction = input["action"] as? String,
              let action = AppSettingsRequest.Action(rawValue: rawAction) else {
            return "Error: action must be list, shortcuts, open, or update."
        }
        if action == .list {
            return try await handle(AppSettingsRequest(action: .list, changes: [], section: nil))
        }
        if action == .shortcuts {
            return try await handle(AppSettingsRequest(action: .shortcuts, changes: [], section: nil))
        }
        if action == .open {
            guard let section = (input["section"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !section.isEmpty else {
                return "Error: action=open requires a section."
            }
            return try await handle(AppSettingsRequest(action: .open, changes: [],
                                                       section: section))
        }

        guard let rawChanges = input["changes"] as? [Any], !rawChanges.isEmpty else {
            return "Error: action=update requires at least one change."
        }
        guard rawChanges.count <= 12 else {
            return "Error: one confirmed update can contain at most 12 changes."
        }
        var changes: [AppSettingsRequest.Change] = []
        for raw in rawChanges {
            guard let item = raw as? [String: Any],
                  let setting = (item["setting"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !setting.isEmpty,
                  let value = Self.stringValue(item["value"]) else {
                return "Error: every change needs a setting and a string or boolean value."
            }
            let scope = (item["scope"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A prompt is user copy: trim nothing but the surrounding whitespace,
            // and let an explicitly empty string through as "no prompt given".
            let prompt = (item["prompt"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            changes.append(.init(setting: setting, value: value,
                                 scope: scope?.isEmpty == false ? scope : nil,
                                 prompt: prompt?.isEmpty == false ? prompt : nil))
        }
        return try await handle(AppSettingsRequest(action: .update, changes: changes,
                                                   section: nil))
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? Bool { return value ? "true" : "false" }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}

// MARK: - The user's own archive (search_history)

/// One decoded `search_history` request, in the terms the archive is actually
/// filtered by. Provider-neutral and `Sendable` so the tool (off the main actor)
/// can hand it to the main-actor lookup that owns `NotchModel.history`.
struct HistoryQuery: Sendable {
    /// Keyword to match against a row's title, question, answer, and turn text.
    /// `nil` means "no text filter" — a pure date/kind listing, which is the
    /// shape of "what did I do today".
    var text: String? = nil
    /// `HistoryItem.Source.rawValue` to restrict to, or `nil` for all four kinds.
    var kind: String? = nil
    /// Inclusive window. `since` is snapped to the start of its day and `until`
    /// to the END of its day by the lookup, so "2026-07-26 → 2026-07-26" means
    /// all of that one day rather than an empty instant.
    var since: Date? = nil
    var until: Date? = nil
    /// Row cap, already clamped by the tool.
    var limit: Int = 30
}

/// One archive row, flattened to exactly what the model is shown. Deliberately
/// NOT `HistoryItem`: the digest crosses from the main actor into the tool, and
/// keeping it a small `Sendable` value means transcripts, image filenames and
/// resume handles never leave the model layer at all.
struct HistoryDigestRow: Sendable {
    /// Per-field caps applied at the main-actor mapping, so a single pathological
    /// row (a pasted wall of text filed as a note) can't dominate the budget.
    static let headlineCap = 220
    static let bodyCap = 160

    let date: Date
    /// Display kind: `ask` / `note` / `reminder` / `agent`, the last carrying its
    /// outcome when the run reported one (`agent·failure`).
    let kind: String

    /// The one line that identifies the row — for an Ask that's its generated
    /// title (already an AI summary of the exchange), for a capture the captured
    /// text itself.
    let headline: String
    /// The literal question behind an Ask row, when the headline is a generated
    /// title and so doesn't already say it. `nil` for captures.
    let body: String?
}

/// The answer to one archive query: the rows that fit, plus how many actually
/// matched. `totalMatches` exists so a `limit`-truncated list can SAY it was
/// truncated — without it, "summarize my week" reads the newest 30 rows of a
/// 119-row week and presents them as the whole week, which is the one failure
/// mode of this tool that produces a confidently wrong answer rather than a
/// visibly thin one.
struct HistoryDigest: Sendable {
    let rows: [HistoryDigestRow]
    let totalMatches: Int

    static let empty = HistoryDigest(rows: [], totalMatches: 0)
}

/// Search the user's own Notch archive — the questions they asked, the notes and
/// reminders they captured, and the agent tasks they ran, all timestamped.
///
/// This is what closes the loop on the app's own record: the archive is already a
/// complete local log (`NotchModel.HistoryItem`), and this tool is the only thing
/// that was missing to let the assistant answer *from* it ("what did I work on
/// today", "what have I been recording", "what did I ask you last week").
///
/// Two deliberate properties:
///  • **On-demand, never injected.** The digest is only assembled when the model
///    asks for it, exactly like `read_clipboard` — no client-side heuristic
///    quietly ships the user's archive to the provider on every question.
///  • **Summaries, not transcripts.** Each Ask row already carries a generated
///    title (see `titleSystemPrompt`) and each capture is one short line, so a
///    day's worth of rows fits in a few hundred tokens without ever sending a
///    full conversation back over the wire.
struct SearchHistoryTool: NotchTool {
    let name = "search_history"
    let description = """
    Searches the user's own history inside this app — every question they asked \
    it, every note and reminder they captured through it, and every agent task \
    they ran — each with its timestamp. Call this whenever the user asks about \
    THEIR OWN past activity rather than about the world: "what did I work on \
    today", "what have I recorded", "what did I ask you yesterday", "summarize \
    my week", "did I ever note anything about X". Prefer a date window (`since` \
    / `until`, or `days`) for "today / yesterday / this week" questions and a \
    `query` keyword for "did I ever mention X". The CURRENT conversation is \
    already visible to you — only call this for things outside it. If it returns \
    nothing, say you found nothing recorded for that period; never invent \
    entries.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "Keyword to match against the text of past entries. Omit to list everything in the date window, which is what a \"what did I do today\" question wants.",
            ],
            "since": [
                "type": "string",
                "description": "Start of the window, inclusive: \"YYYY-MM-DD\", or \"today\" / \"yesterday\".",
            ],
            "until": [
                "type": "string",
                "description": "End of the window, inclusive (whole day): \"YYYY-MM-DD\", or \"today\" / \"yesterday\".",
            ],
            "days": [
                "type": "integer",
                "description": "Alternative to since/until: the last N days counting today (1 = today only, 7 = this past week). Use this when you'd rather not compute calendar dates.",
            ],
            "kind": [
                "type": "string",
                "enum": ["ask", "note", "reminder", "agent"],
                "description": "Restrict to one kind: ask = a question they asked this app, note / reminder = something they captured through it, agent = a coding task they ran. Omit for all four.",
            ],
            "limit": [
                "type": "integer",
                "description": "Maximum entries to return, newest first. Defaults to 30, capped at 60.",
            ],
        ],
    ]

    /// Bridge to the archive. Injected per round by `NotchModel` (which owns
    /// `history` on the main actor) — the same pattern `ask_user` uses, and the
    /// reason this tool isn't in `ToolRegistry.standard(for:)`.
    let lookup: @Sendable (HistoryQuery) async -> HistoryDigest

    /// "Now", for resolving the relative arguments (`today` / `yesterday` /
    /// `days`). Injectable so the regression harness can anchor the whole tool to
    /// a fixed moment (see `scripts/history_eval`) — production always leaves it
    /// as the real clock.
    var now: @Sendable () -> Date = { Date() }

    /// Total characters the digest may occupy. The archive is unbounded, so
    /// without this one call could hand a small model tens of thousands of
    /// characters of its own past.
    private static let outputCap = 6000

    /// Room held back from `outputCap` for the trailing "N more omitted" note. The
    /// note is appended after the row loop, so without reserving its space the cap
    /// was overshot by exactly its length — caught by `scripts/history_eval`'s
    /// budget case. Comfortably longer than the note ever gets.
    private static let footerReserve = 128

    /// Fixed-locale so the dates the model reads never shift with the user's
    /// interface language — unlike `DateTimeTool`, which deliberately localizes
    /// because its output IS prose. Here they're data the model does arithmetic
    /// on, so `YYYY-MM-DD (Sun) HH:mm` is the same everywhere.
    private static let rowFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Foundation.Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd (EEE) HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Foundation.Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Parse one date argument: an ISO day, or the two relative words a model
    /// reaches for even when told to send a date. Anything else is `nil`, which
    /// simply drops that bound rather than failing the call.
    private static func parseDay(_ raw: Any?, now: Date) -> Date? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !s.isEmpty else { return nil }
        let cal = Calendar.current
        switch s {
        case "today":     return cal.startOfDay(for: now)
        case "yesterday": return cal.date(byAdding: .day, value: -1,
                                          to: cal.startOfDay(for: now))
        default: break
        }
        // Tolerate a full ISO-8601 timestamp too — some models send one anyway.
        if let day = dayFormatter.date(from: String(s.prefix(10))) { return day }
        return nil
    }

    func execute(_ input: [String: Any]) async throws -> String {
        var query = HistoryQuery()
        let clock = now()

        if let text = (input["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            query.text = text
        }
        if let kind = (input["kind"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           ["ask", "note", "reminder", "agent"].contains(kind) {
            query.kind = kind
        }
        query.since = Self.parseDay(input["since"], now: clock)
        query.until = Self.parseDay(input["until"], now: clock)
        // `days` is the relative alternative: N days counting today. Only honoured
        // when the model didn't already name an explicit start, so the two ways of
        // saying it can't contradict each other.
        if query.since == nil, let days = intArgument(input["days"]), days > 0 {
            let cal = Calendar.current
            query.since = cal.date(byAdding: .day, value: -(min(days, 400) - 1),
                                   to: cal.startOfDay(for: clock))
        }
        // A window given backwards ("since tomorrow, until today") would silently
        // match nothing; read it as the window the model meant.
        if let since = query.since, let until = query.until, since > until {
            query.since = until
            query.until = since
        }
        query.limit = min(max(intArgument(input["limit"]) ?? 30, 1), 60)

        let digest = await lookup(query)
        return Self.render(digest, query: query)
    }

    /// Decode an integer argument that may arrive as a number OR as a string —
    /// both shapes show up across providers' function-calling JSON.
    private func intArgument(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let d = raw as? Double { return Int(d) }
        if let s = raw as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Render the digest the model reads. Newest first, one line per row, with a
    /// header that states the window and what the kinds mean — so the model can
    /// reason about coverage ("nothing on Tuesday") instead of guessing.
    private static func render(_ digest: HistoryDigest, query: HistoryQuery) -> String {
        let rows = digest.rows
        var scope: [String] = []
        if let since = query.since, let until = query.until {
            scope.append("\(dayFormatter.string(from: since)) → \(dayFormatter.string(from: until))")
        } else if let since = query.since {
            scope.append("since \(dayFormatter.string(from: since))")
        } else if let until = query.until {
            scope.append("up to \(dayFormatter.string(from: until))")
        }
        if let kind = query.kind { scope.append("kind \(kind)") }
        if let text = query.text { scope.append("matching “\(text)”") }
        let window = scope.isEmpty ? "the whole archive" : scope.joined(separator: ", ")

        guard !rows.isEmpty else {
            return """
            No entries found in the user's own archive (\(window)). Tell them you \
            have nothing recorded for that — do not invent entries, and do not \
            answer from your own memory as if it were their record.
            """
        }

        // The `limit` cut, stated up front: a model handed the newest 30 rows of a
        // 119-row week must know it is looking at a slice, or it will summarize the
        // slice as if it were the week.
        let capped = digest.totalMatches > rows.count
        let count = capped
            ? "The \(rows.count) most recent of \(digest.totalMatches) matching entries"
            : "\(rows.count) entr\(rows.count == 1 ? "y" : "ies")"
        var out = """
        \(count) from the user's own archive in this app (\(window)), newest first. \
        Kinds: ask = a question they asked this app, note / reminder = something \
        they captured through it, agent = a coding task they ran.
        """
        if capped {
            out += """
             Because this is only the newest slice, say so if you summarize it \
            ("of what I can see…"), or call again with a narrower date window or a \
            higher limit.
            """
        }
        out += "\n"
        var omitted = 0
        for (i, row) in rows.enumerated() {
            var line = "\(i + 1). [\(row.kind)] \(rowFormatter.string(from: row.date)) — \(row.headline)"
            if let body = row.body, !body.isEmpty { line += "\n   asked: \(body)" }
            // Budget check before appending, so the cap is never overshot and the
            // count of what didn't fit stays honest. The last row needs no footer,
            // so it may use the reserve — otherwise a digest that exactly fits
            // would drop its final row for a note it never prints.
            let allowance = outputCap - (i == rows.count - 1 ? 0 : footerReserve)
            guard out.count + line.count + 1 <= allowance else {
                omitted = rows.count - i
                break
            }
            out += line + "\n"
        }
        if omitted > 0 {
            out += "…(\(omitted) more entr\(omitted == 1 ? "y" : "ies") omitted to stay "
                + "within budget — narrow the date window or add a query keyword.)\n"
        }
        return out
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

/// Backend seam for web search. Providers own authentication, transport, and
/// response parsing; they never choose the tool name or schema exposed to a
/// model. Adding another search service only requires another implementation of
/// this protocol plus one case in `SearchBackend.searchProvider`.
protocol SearchProvider: Sendable {
    func search(_ input: [String: Any]) async throws -> (text: String, sources: [WebSource])
}

/// The one web-search capability exposed to models and consumed by the harness.
/// Its provider can change without changing the prompt-facing contract.
struct WebSearchTool: SourcedTool {
    static let toolName = "web_search"

    let name = toolName
    let description = webSearchToolDescription
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "The search query."]
        ],
        "required": ["query"],
    ]
    let provider: any SearchProvider

    func execute(_ input: [String: Any]) async throws -> String {
        try await runSourced(input).text
    }

    func runSourced(_ input: [String: Any]) async throws -> (text: String, sources: [WebSource]) {
        try await provider.search(input)
    }
}

/// Kimi's `$web_search` is a *builtin* server tool with an unusual contract
/// (XII-118): the model emits a tool call, and the client must echo the call's
/// arguments back **unchanged** for Moonshot to actually run the search
/// server-side. There is no local search to perform — this "tool" exists only so
/// the harness's ordinary tool loop has something to dispatch to instead of
/// failing on an unknown name, and its provider returns its input re-encoded
/// as JSON, which is exactly the echo Kimi expects. Registered only for the Kimi
/// provider (see `ToolRegistry.standard(for:)`). The service boundary advertises
/// it with Moonshot's wire-level builtin name while the registry keeps the stable
/// capability identity.
struct KimiSearchProvider: SearchProvider {
    func search(_ input: [String: Any]) async throws -> (text: String, sources: [WebSource]) {
        // Echo the model's arguments back verbatim as a JSON string — Moonshot
        // runs the real search on receiving this. Anything else (an error, a
        // summary, empty) means the search silently never happens.
        guard let data = try? JSONSerialization.data(withJSONObject: input),
              let json = String(data: data, encoding: .utf8) else {
            return ("{}", [])
        }
        return (json, [])
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
struct GLMSearchProvider: SearchProvider {
    // The service sends this capability under the `lookup_web` wire alias because
    // `web_search` collides with GLM's own built-in server-side tool: glm-4.x
    // ignores the results we feed back and re-calls the tool in a loop until
    // the iteration cap, then answers from training data (the stale/hallucinated
    // answers Cyrus saw). A distinct name makes the model treat it as an ordinary
    // function: it reads the fed-back results and answers from them. Verified live.
    private static let endpoint = URL(string: "https://open.bigmodel.cn/api/paas/v4/web_search")!
    private static let timeout: TimeInterval = 15
    private static let maxResults = 6

    func search(_ input: [String: Any]) async throws -> (text: String, sources: [WebSource]) {
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
/// `GLMSearchProvider` (which reuses the GLM provider's key and only exists because
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
struct ExaSearchProvider: SearchProvider {

    private static let endpoint = URL(string: "https://api.exa.ai/search")!
    private static let timeout: TimeInterval = 15
    private static let maxResults = 6

    func search(_ input: [String: Any]) async throws -> (text: String, sources: [WebSource]) {
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
struct KeenableSearchProvider: SearchProvider {

    private static let endpoint = URL(string: "https://api.keenable.ai/v1/search")!
    private static let timeout: TimeInterval = 15
    // Keenable always returns ~10 results and ignores any count param (sending one
    // makes it return 0). Empirically its relevance ranking is solid for the first
    // few and then pads the tail with off-topic filler, so we keep only the top
    // (post-filtering) handful rather than feeding the model the noisy tail.
    private static let maxResults = 4

    func search(_ input: [String: Any]) async throws -> (text: String, sources: [WebSource]) {
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

/// Provider-agnostic web search via **AnySearch**
/// (`https://api.anysearch.com/v1/search`). AnySearch supports anonymous REST
/// access, so this tool is active as soon as the backend is selected; an optional
/// `ANYSEARCH_API_KEY` / stored key is sent as a Bearer token for higher limits.
/// The unified endpoint routes an untagged query to the appropriate sources and
/// returns both compact snippets and cleaned page content.
struct AnySearchProvider: SearchProvider {

    private static let endpoint = URL(string: "https://api.anysearch.com/v1/search")!
    private static let timeout: TimeInterval = 15
    private static let maxResults = 6

    func search(_ input: [String: Any]) async throws -> (text: String, sources: [WebSource]) {
        guard let query = (input["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return ("Error: empty search query.", [])
        }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = Self.timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = APIKeyStore.currentAnySearchKey() {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "query": query,
            "max_results": Self.maxResults,
            "format": "json",
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

    /// Parse `{ code, message, data: { results: [{title,url,snippet,content}] } }`
    /// into the same model text + source badges used by the other searchers.
    private static func parse(_ data: Data, query: String) -> (text: String, sources: [WebSource]) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("Search failed: AnySearch returned an unreadable response.", [])
        }
        if let code = obj["code"] as? NSNumber, code.intValue != 0 {
            let message = (obj["message"] as? String) ?? "unknown API error"
            return ("Search failed: \(message)", [])
        }
        guard let payload = obj["data"] as? [String: Any],
              let results = payload["results"] as? [[String: Any]], !results.isEmpty else {
            let miss = "The search returned no results for \"\(query)\". Do not fabricate "
                     + "an answer — tell the user the search found nothing on this."
            return (miss, [])
        }

        let top = results.prefix(maxResults)
        let blocks = top.enumerated().map { (i, r) -> String in
            let title = (r["title"] as? String) ?? "(untitled)"
            let link = (r["url"] as? String).flatMap { $0.isEmpty ? nil : "\n   \($0)" } ?? ""
            var snippet = snippetText(from: r)
            if snippet.count > 500 { snippet = String(snippet.prefix(500)) + "…" }
            return "[\(i + 1)] \(title)\n   \(snippet)\(link)"
        }
        let text = "Web search results for \"\(query)\":\n\n" + blocks.joined(separator: "\n\n")

        var seen = Set<String>()
        let sources: [WebSource] = top.compactMap { r in
            guard let link = r["url"] as? String,
                  let scheme = URL(string: link)?.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  !seen.contains(link) else { return nil }
            seen.insert(link)
            return WebSource(title: (r["title"] as? String) ?? link, url: link, date: nil)
        }
        return (text, sources)
    }

    private static func snippetText(from result: [String: Any]) -> String {
        for key in ["snippet", "content"] {
            if let value = result[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }
}

extension APIKeyStore.SearchBackend {
    /// The only backend-to-implementation wiring point. Capability definition,
    /// prompts, registries, harness logic, and MCP exposure stay unchanged when
    /// another provider is added.
    var searchProvider: any SearchProvider {
        switch self {
        case .exa:       return ExaSearchProvider()
        case .keenable:  return KeenableSearchProvider()
        case .anysearch: return AnySearchProvider()
        }
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
    ///    client-side `GLMSearchProvider` that hits Zhipu's standalone search API.
    ///  • **Kimi** — its builtin search needs a client-side echo, so the
    ///    `$web_search` passthrough is added so the harness can echo the call back.
    /// (The defunct DuckDuckGo `WebSearchTool` was removed — see XII-116/XII-118.)
    ///
    /// **Unified searcher (optional, user-chosen).** A single client-side
    /// search tool can replace every provider's native search — the server-search
    /// gate in `streamTurn` and the GLM/Kimi client tools below all defer to it.
    /// Which one is the user's choice, not a hard-coded vendor preference:
    /// `APIKeyStore.resolvedSearchBackend()` maps their picked search backend
    /// (Keenable / Exa / AnySearch) to the tool that runs and enforces key
    /// requirements where applicable. When it returns `nil`, the provider's own
    /// native search (GLM client tool / Kimi echo / server-side search) stays in play.
    static func standard(for provider: Provider) -> ToolRegistry {
        var tools: [NotchTool] = [
            DateTimeTool(),
            ReadClipboardTool(),
            CalculateTool(),
            ReadPageTool(),
            OpenURLTool(),
        ]
        if let backend = APIKeyStore.resolvedSearchBackend() {
            tools.append(WebSearchTool(provider: backend.searchProvider))
        } else {
            // No client searcher picked (or the pick has no key) — the provider's
            // own native search stays in play.
            if provider == .glm {
                tools.append(WebSearchTool(provider: GLMSearchProvider()))
            }
            if provider == .kimi {
                tools.append(WebSearchTool(provider: KimiSearchProvider()))
            }
        }
        return ToolRegistry(tools)
    }

    /// Provider-agnostic default, kept for call sites that don't yet thread a
    /// provider through (it omits any provider-specific builtin like Kimi's echo).
    static var standard: ToolRegistry { ToolRegistry([
        DateTimeTool(), ReadClipboardTool(), CalculateTool(), ReadPageTool(),
        OpenURLTool(),
    ]) }
}
