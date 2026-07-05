import Foundation

/// One turn in a conversation, in the shape every chat API expects: a `role`
/// (`"user"` or `"assistant"`) and its `content`. `NotchModel` builds the running
/// list and hands the whole thing to the service on each submit, so a follow-up
/// carries the full context instead of starting over.
struct ChatMessage: Sendable, Equatable {
    let role: String   // "user" | "assistant"
    let content: String
    /// A copied image riding this turn (XII-121), already downsampled and
    /// base64-encoded for the wire; `nil` for the ordinary text-only turn. Each
    /// client encodes it in its own vendor shape (Anthropic `source` block /
    /// OpenAI-style `image_url` data URI).
    var image: ChatImage? = nil
}

/// A wire-ready image attachment: the base64 payload plus its mime type. Built
/// once in `NotchModel.encodeForVision` (long side capped, JPEG) and carried
/// opaquely from there to whichever client sends it.
struct ChatImage: Sendable, Equatable {
    let base64: String
    let mediaType: String   // e.g. "image/jpeg"
}

/// The seam where the notch talks to an AI. In the web prototype this was
/// `window.claude.complete()`; here it's an async protocol so a real Claude API
/// client can be dropped in later without touching any UI code.
///
/// Per the current scope the app ships with `StubAIService` — no network, no API
/// key. To go live, implement this protocol against the Anthropic API (ideally
/// through a small backend so the key never ships in the app) and swap the
/// instance handed to `NotchModel`.
protocol AIService: Sendable {
    /// Continue a conversation, streaming the reply as it arrives. `system` is the
    /// persona/instruction; `messages` is the full alternating user/assistant
    /// history ending on the latest user turn — so the model answers *with the
    /// prior turns in context* (real follow-ups, not fresh single-shot queries).
    /// Each yielded value is an incremental chunk of text to append (not the full
    /// answer). The stream finishes when the model is done; it should respect
    /// cancellation (stop producing once the surrounding `Task` is cancelled).
    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error>
}

/// Reply-length budgets, in tokens. A normal turn is short (the 90-word persona
/// cap); a clipboard-enriched turn lets the model use up to 200 words for a
/// summary/translation of the copied text, which needs a bigger wire ceiling than
/// the default — at 1024 a long clip (≤1500 chars) + question + 200-word answer
/// was being truncated mid-thought (XII-91).
enum ReplyTokens {
    static let standard = 1024
    static let enriched = 2048

    /// The suffix appended to the system prompt on a clipboard-enriched turn (see
    /// `NotchModel.submit`). Single source of truth so the wire `max_tokens` can be
    /// raised for exactly the turns whose prompt was widened to 200 words.
    static let enrichedMarker = "\nFor this turn you may use up to 200 words."

    /// The `max_tokens` to send for a turn with this system prompt: the larger
    /// budget when the prompt carries the enriched-turn marker, otherwise standard.
    static func budget(forSystem system: String) -> Int {
        system.contains(enrichedMarker) ? enriched : standard
    }
}

/// Auto-retry for transient streaming failures. The very first Ask after
/// onboarding (and any cold request) can hit a one-off that has nothing to do
/// with the user's setup: a dropped connection, a slow-first-token timeout, a
/// free-model rate-limit (429), a backend 5xx, or a stream that opens and then
/// finishes without a single token. Surfacing those as a dead error — when a
/// second attempt would just work — is the bad experience we're killing. So the
/// transport retries the connect/first-token phase a couple of times with
/// backoff before giving up. It only ever retries *before any token has been
/// yielded* (the call sites enforce this), so a reply is never duplicated.
enum StreamRetry {
    /// Up to this many *extra* attempts after the first (so 3 tries total). Small
    /// on purpose: the goal is to ride out a blip, not to hammer a down backend.
    static let maxRetries = 2

    /// Backoff before the Nth retry (1-based): ~0.5s, then ~1.5s. Capped so a
    /// `Retry-After` we honor below can't push the wait absurdly long.
    static let maxBackoff: TimeInterval = 6

    static func backoff(forRetry n: Int) -> TimeInterval {
        min(maxBackoff, 0.5 * pow(3, Double(n - 1)))   // 0.5, 1.5, 4.5, …
    }

    /// Whether an error from the connect/first-token phase is worth retrying.
    /// Retry the transient class — network drops, timeouts, 429, and 5xx — but
    /// NOT a definitive client error (401/403/400/404): a bad/missing key or a
    /// malformed request won't fix itself, so we fail fast and let the UI offer
    /// "Open Settings" instead of stalling through pointless retries.
    static func isRetryable(_ error: Error) -> Bool {
        if let svc = error as? OpenAICompatAIService.ServiceError {
            switch svc {
            case .http(_, let status, _):
                return status == 429 || (500..<600).contains(status)
            case .malformedResponse:
                return true   // no/!HTTPURLResponse — treat as a transient blip
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .resourceUnavailable, .badServerResponse:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// The `Retry-After` header (seconds), clamped to `maxBackoff`, if present on
    /// a 429/503. Lets us wait roughly as long as the provider asks instead of
    /// guessing — without ever blocking for an unbounded time.
    static func retryAfter(_ response: URLResponse?) -> TimeInterval? {
        guard let http = response as? HTTPURLResponse,
              let raw = http.value(forHTTPHeaderField: "Retry-After"),
              let secs = TimeInterval(raw.trimmingCharacters(in: .whitespaces))
        else { return nil }
        return min(maxBackoff, max(0, secs))
    }

    /// Sleep for the chosen backoff before retry `n`, preferring the provider's
    /// `Retry-After` when it gave one. Throws `CancellationError` if the
    /// surrounding task was cancelled mid-wait (a newer round superseded us).
    static func waitBeforeRetry(_ n: Int, response: URLResponse? = nil) async throws {
        let secs = retryAfter(response) ?? backoff(forRetry: n)
        try await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
    }
}

extension AIService {
    /// Convenience for callers that just want the whole answer to a single
    /// question: wraps it as a one-message conversation, drains the stream, and
    /// concatenates it. Kept so non-streaming, single-shot use sites stay simple.
    func complete(prompt: String) async throws -> String {
        var out = ""
        let messages = [ChatMessage(role: "user", content: prompt)]
        for try await chunk in stream(system: notchSystemPromptDated(), messages: messages) { out += chunk }
        return out
    }
}

/// The system prompt the prototype used for its in-notch assistant. Kept here so
/// a real implementation can reuse the exact persona.
///
/// The web-search clause matters: the persona is otherwise "concise, under 90
/// words", which on its own nudges the model to answer in one shot from memory
/// and skip the extra round a tool call costs. That's exactly wrong for anything
/// time-sensitive — the model's training data is stale and today is later than
/// its cutoff. So the persona explicitly makes "search first" the default for
/// changeable facts, and licenses the extra round / a few more words to do it,
/// instead of leaving the decision to the tool description alone.
let notchSystemPrompt = """
You are a helpful assistant living in the notch of a Mac. Answer the user's \
question concisely and warmly in the user's language. Keep it under 90 words, \
no markdown headers.

When you mention a link, write it as a Markdown inline link — [visible text](url) \
— never a bare URL, so it renders as a clickable link rather than plain text.

You can search the web and read the current date. Be cautious with any \
information that can change over time — news, current events, prices or rates, \
rankings, "latest"/"newest", which version is current, who currently holds a \
role, whether something has shipped, anything dated this year. Do not answer \
such questions from memory: your training data is stale and today is later than \
your cutoff, so treat your recollection as likely out of date. Search first and \
answer from the results. When there's any doubt whether something may have \
changed, err toward searching rather than trusting memory. A search is worth \
the extra round and a few more words — don't skip it just to stay short. \
You don't need to spell out your source every time; cite it only when it \
matters — when the claim is contested, surprising, or the user would want to \
check it — and otherwise just answer. \
When you search, prefer English-language queries and lean on English-language \
sources, even when answering in another language — they tend to be more \
timely and reliable. Only fall back to a Chinese-language query when the topic \
is inherently local (a China-specific product, person, policy, or event) and \
English sources are thin. Then answer in the user's language as usual.
"""

/// The persona with the current local date inlined as the first line, so the
/// model knows up front that "now" is later than its training cutoff and treats
/// its memory as potentially stale — turning the bare `current_datetime` tool
/// (which the model has to *think* to call) into an unconditional fact it always
/// has. The single-shot `complete` path and the agent path both build the prompt
/// through here. Rendered in the user's interface language to match the answer,
/// mirroring `DateTimeTool`'s locale handling.
func notchSystemPromptDated(customInstructions: String? = nil) -> String {
    let fmt = DateFormatter()
    fmt.dateStyle = .full
    fmt.timeStyle = .none
    switch Localization.shared.language.resolved {
    case .en:     fmt.locale = Foundation.Locale(identifier: "en_US")
    case .zhHans: fmt.locale = Foundation.Locale(identifier: "zh_Hans")
    case .zhHant: fmt.locale = Foundation.Locale(identifier: "zh_Hant")
    }
    var prompt = "Today is \(fmt.string(from: Date())).\n\n" + notchSystemPrompt
    // The user's own preferences (XII-137), appended AFTER the built-in persona so
    // the core rules — concise, search-first, honest — are stated first and the
    // preference is a trailing refinement, not an override. Framed as "the user's
    // standing preferences" and explicitly subordinate to the rules above, so a
    // one-liner like "always answer in English" is honoured without letting it
    // dislodge search-first / honesty. Only appended on the Ask path with a
    // non-empty value; presets and title generation pass nil (they carry their own
    // precise instructions and must not be polluted).
    if let custom = customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
       !custom.isEmpty {
        prompt += "\n\nThe user has set these standing preferences. Honour them where "
            + "they don't conflict with the rules above (search-first, honesty, and "
            + "concision still apply):\n\(custom)"
    }
    return prompt
}

/// System prompt for summarizing a conversation into a short recent-list title.
/// The title is derived from the *actual* exchange (not the user's first message),
/// so generic prompts like "总结一下" don't end up as the displayed title.
let titleSystemPrompt = """
You write short, *distinctive* titles for a list of past conversations. The \
list shows many titles stacked together, so each one must be specific enough \
that the user can tell it apart from similar conversations at a glance.

Given a conversation, produce a title that:
- Captures the actual topic discussed (not the user's first message verbatim).
- Leads with the most distinguishing detail — the specific name, number, \
place, product, or action involved — rather than a broad category word. \
Prefer "小米 SU7 售价" over "小米"; prefer "Redis 连接池泄漏" over "Redis 问题".
- Fits in roughly 16 characters or 10 Chinese characters. Use the space to be \
specific; don't pad, but don't truncate away the distinguishing detail either.
- Is in the same language as the conversation.

Output only the title text — no quotes, numbering, or explanation.
"""

// MARK: - Providers

/// Everything the app needs to know about one AI backend, gathered in a single
/// place. Each `Provider` case maps to exactly one `ProviderSpec` (see
/// `Provider.spec`), so a provider's full definition — name, endpoint, models,
/// signup links, env var — lives in one contiguous block instead of being smeared
/// across a dozen parallel `switch`es. Adding a vendor means writing one `spec`
/// literal; editing one means touching one place.
struct ProviderSpec {
    /// Human-readable name shown in Settings.
    let displayName: String
    /// The request endpoint. OpenAI-compatible vendors share the
    /// `/v1/chat/completions` shape; Anthropic uses its native `/v1/messages`.
    let endpoint: URL
    /// Default model used when the user hasn't picked one explicitly. Always the
    /// first entry of `availableModels`.
    let defaultModel: String
    /// The models offered in the Settings model picker. These are the current,
    /// commonly-used model ids per vendor — a curated shortlist, not an exhaustive
    /// catalog; vendors add/retire models over time, so this bundled set is only
    /// the offline fallback: the remote manifest (`RemoteModelManifest`) overrides
    /// it without an app release, and the live `/models` fetch in `ModelCatalog`
    /// supersedes both in the picker when a key is present.
    let availableModels: [String]
    /// Short host shown in the Settings footer ("get a key at …").
    let signupHost: String
    /// Clickable URL to the provider's API-key console. The footer shows the short
    /// `signupHost`, but the link points at the exact key-creation page.
    let signupURL: URL
    /// Environment variable that force-overrides the stored key (handy for dev).
    let envVarName: String

    /// Convenience initializer: `models` carries the picker list and its first
    /// entry doubles as `defaultModel`, so the two can never drift apart.
    init(displayName: String, endpoint: String, models: [String],
         signupHost: String, signupURL: String, envVarName: String) {
        self.displayName = displayName
        self.endpoint = URL(string: endpoint)!
        self.defaultModel = models[0]
        self.availableModels = models
        self.signupHost = signupHost
        self.signupURL = URL(string: signupURL)!
        self.envVarName = envVarName
    }
}

/// The AI backends the app knows how to talk to. Most expose an
/// **OpenAI-compatible** `/v1/chat/completions` endpoint and share one client
/// (`OpenAICompatAIService`); Anthropic speaks its native `/v1/messages` and uses
/// a dedicated client. The per-provider data all lives in `spec`; the few
/// properties below `spec` are behavioral, grouped by *how the client behaves*
/// rather than by vendor, so they stay as small switches.
enum Provider: String, CaseIterable, Identifiable, Sendable {
    /// First in the menu deliberately: the only backend that works without
    /// pasting a key (one-click OAuth connect, free models) — the default for
    /// fresh installs.
    case openrouter
    // International majors first, then domestic providers by familiarity —
    // OpenRouter stays at the top as the keyless default for fresh installs.
    case openai
    case anthropic
    case gemini
    case deepseek
    case qwen
    case glm
    case kimi
    case minimax
    case mimo

    var id: String { rawValue }

    /// The single source of truth for this provider's configuration. Everything
    /// that's pure per-vendor data is defined here, one self-contained block per
    /// provider — read the block and you know the whole provider.
    var spec: ProviderSpec {
        switch self {
        case .openrouter:
            return ProviderSpec(
                displayName: "OpenRouter",
                endpoint: "https://openrouter.ai/api/v1/chat/completions",
                // The free auto-router: OpenRouter picks a currently-available
                // free model per request, so this keeps working as the free
                // lineup rotates. The live `/models` fetch fills in the current
                // `:free` lineup (see `ModelCatalog`), too fluid to bundle.
                models: ["openrouter/free"],
                signupHost: "openrouter.ai",
                signupURL: "https://openrouter.ai/settings/keys",
                envVarName: "OPENROUTER_API_KEY")
        case .mimo:
            return ProviderSpec(
                displayName: "MiMo",
                endpoint: "https://api.xiaomimimo.com/v1/chat/completions",
                models: ["mimo-v2.5-pro", "mimo-v2.5"],
                signupHost: "platform.xiaomimimo.com",
                signupURL: "https://platform.xiaomimimo.com/console/api-keys/api_key",
                envVarName: "MIMO_API_KEY")
        case .deepseek:
            return ProviderSpec(
                displayName: "DeepSeek",
                endpoint: "https://api.deepseek.com/v1/chat/completions",
                models: ["deepseek-v4-flash", "deepseek-v4-pro"],
                signupHost: "platform.deepseek.com",
                signupURL: "https://platform.deepseek.com/api_keys/api_key",
                envVarName: "DEEPSEEK_API_KEY")
        case .openai:
            return ProviderSpec(
                displayName: "OpenAI",
                endpoint: "https://api.openai.com/v1/chat/completions",
                models: ["gpt-5.5", "gpt-5.5-pro", "gpt-5.4", "gpt-5.2", "gpt-5", "gpt-5-mini"],
                signupHost: "platform.openai.com",
                signupURL: "https://platform.openai.com/api-keys/api_key",
                envVarName: "OPENAI_API_KEY")
        case .gemini:
            return ProviderSpec(
                displayName: "Google Gemini",
                endpoint: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
                models: ["gemini-3.5-flash", "gemini-3-flash", "gemini-3.1-pro", "gemini-3.1-flash-lite", "gemini-2.5-pro", "gemini-2.5-flash"],
                signupHost: "aistudio.google.com",
                signupURL: "https://aistudio.google.com/app/apikey/api_key",
                envVarName: "GEMINI_API_KEY")
        case .anthropic:
            return ProviderSpec(
                displayName: "Anthropic",
                endpoint: "https://api.anthropic.com/v1/messages",
                models: ["claude-sonnet-4-6", "claude-opus-4-8", "claude-haiku-4-5"],
                signupHost: "console.anthropic.com",
                signupURL: "https://console.anthropic.com/settings/keys/api_key",
                envVarName: "ANTHROPIC_API_KEY")
        case .minimax:
            return ProviderSpec(
                displayName: "MiniMax",
                endpoint: "https://api.minimaxi.com/v1/chat/completions",
                models: ["MiniMax-M3", "MiniMax-M3-highspeed", "MiniMax-M2.7", "MiniMax-M2.5"],
                signupHost: "platform.minimaxi.com",
                signupURL: "https://platform.minimaxi.com/api_key",
                envVarName: "MINIMAX_API_KEY")
        case .glm:
            return ProviderSpec(
                displayName: "GLM",
                endpoint: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
                models: ["glm-5", "glm-5.1", "glm-5-turbo", "glm-4.6"],
                signupHost: "open.bigmodel.cn",
                signupURL: "https://open.bigmodel.cn/usercenter/apikeys/api_key",
                envVarName: "GLM_API_KEY")
        case .qwen:
            return ProviderSpec(
                displayName: "Qwen",
                endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
                models: ["qwen3-max", "qwen3.5-plus", "qwen3.5-flash", "qwen-plus", "qwen-flash"],
                signupHost: "bailian.console.aliyun.com",
                signupURL: "https://bailian.console.aliyun.com/api_key",
                envVarName: "QWEN_API_KEY")
        case .kimi:
            return ProviderSpec(
                displayName: "Kimi",
                endpoint: "https://api.moonshot.cn/v1/chat/completions",
                models: ["kimi-k2.6", "kimi-k2.5", "moonshot-v1-128k", "moonshot-v1-32k"],
                signupHost: "platform.moonshot.cn",
                signupURL: "https://platform.moonshot.cn/console/api-keys/api_key",
                envVarName: "KIMI_API_KEY")
        }
    }

    // Per-vendor data — thin pass-throughs to `spec` so existing call sites
    // (`provider.displayName`, `provider.endpoint`, …) keep working unchanged.
    var displayName: String     { spec.displayName }
    var endpoint: URL           { spec.endpoint }
    // Models go through the remote curated manifest first (hot-updated from the
    // website, see `RemoteModelManifest`), so the shortlist and the default a
    // fresh install uses can move without an app release; the bundled spec is
    // the offline fallback.
    var defaultModel: String    { RemoteModelManifest.models(for: self)?.first ?? spec.defaultModel }
    var availableModels: [String] { RemoteModelManifest.models(for: self) ?? spec.availableModels }
    var signupHost: String      { spec.signupHost }
    var signupURL: URL          { spec.signupURL }
    var envVarName: String      { spec.envVarName }

    /// The provider's cheap/fast tier for mechanical tasks — translate/summarize
    /// chips and `generateTitle` (XII-132). Picked from the provider's OWN live
    /// model list (`availableModels`, which rides the hot-updated manifest) by
    /// name pattern, so it tracks the current lineup instead of hard-coding a
    /// model that may be renamed/retired. Returns `nil` when this provider exposes
    /// no distinct light tier (or its only model IS the light one) — the caller
    /// then just keeps the main model, so routing can never make a task fail.
    ///
    /// The match order per provider is most-preferred-light first; the first name
    /// in `availableModels` that contains a light marker wins. Never returns the
    /// user's currently-selected model (routing to "light" that equals the main is
    /// a no-op the caller detects, but we avoid it here for clarity).
    var lightModel: String? {
        let models = availableModels
        // Vendor-specific light markers, in the order we'd prefer them. Lowercased
        // substring match against each candidate id.
        let markers: [String]
        switch self {
        case .anthropic:  markers = ["haiku"]
        case .openai:     markers = ["mini", "nano"]
        case .gemini:     markers = ["flash-lite", "flash"]
        case .deepseek:   markers = ["flash"]
        case .qwen:       markers = ["flash"]
        case .glm:        markers = ["turbo", "flash"]
        case .kimi:       markers = ["32k", "8k"]           // smaller-context = cheaper tier
        case .minimax:    markers = ["highspeed"]
        case .mimo:       markers = []                       // single tier — no light split
        case .openrouter: markers = []                       // auto-router already picks cheap
        }
        for marker in markers {
            if let hit = models.first(where: { $0.lowercased().contains(marker) }) {
                return hit
            }
        }
        return nil
    }

    // MARK: Behavioral traits (grouped by client behavior, not by vendor)

    /// Whether this provider speaks the OpenAI-compatible `/v1/chat/completions`
    /// contract (true for everyone) or a vendor-native protocol (Anthropic's
    /// `/v1/messages`). `AppDelegate` uses this to pick the client implementation.
    var isOpenAICompatible: Bool {
        switch self {
        case .anthropic: return false
        default:         return true
        }
    }

    /// JSON key for the output-token cap. MiMo follows OpenAI's newer
    /// `max_completion_tokens`; everyone else uses the classic `max_tokens`.
    /// (Unused by the Anthropic client, which always sends `max_tokens`.)
    var maxTokensField: String {
        switch self {
        case .mimo:     return "max_completion_tokens"
        default:        return "max_tokens"
        }
    }

    /// Vendor-specific extras sent with every chat request. OpenRouter's two
    /// optional attribution headers identify the app (its docs ask nicely);
    /// everyone else needs nothing beyond auth.
    var extraHeaders: [String: String] {
        switch self {
        case .openrouter:
            return ["HTTP-Referer": "https://github.com/\(UpdaterService.repo)",
                    "X-Title": "Notch"]
        default:
            return [:]
        }
    }

    /// Whether this provider's models reliably support function/tool calling, so
    /// the agent harness can drive them. Every vendor here exposes a tool-calling
    /// API on its current models; OpenRouter is the one wildcard — its free
    /// auto-router rotates across whatever free model is available, some of which
    /// don't do tools, so an unsupported pick simply yields no tool calls and the
    /// harness reads that as a normal `end_turn`. The gate exists so a future
    /// known-toolless provider can be excluded cleanly without touching the harness.
    var supportsTools: Bool { true }

    /// Whether `model` accepts image input (XII-121) — the gate for the
    /// clipboard-image thumbnail: a text-only model never shows a preview it
    /// can't consume. Judged from the id string alone, because Settings lets the
    /// user type any id and OpenRouter serves `vendor/slug` ids, so there's no
    /// enum to switch on. Curated vision families plus the generic markers
    /// vendors put in vision-model names; an unrecognized id (including the
    /// `openrouter/free` auto-router, whose routed model is undisclosed until
    /// request time) reads as text-only — only a model known to read images
    /// earns the thumbnail.
    static func modelSupportsVision(_ model: String) -> Bool {
        let m = model.lowercased()
        // Families whose current lineup takes images end to end.
        let visionFamilies = ["claude", "gemini", "gpt-4o", "gpt-4.1", "gpt-4-turbo",
                              "gpt-5", "grok-4", "llama-4", "pixtral", "llava", "internvl"]
        if visionFamilies.contains(where: m.contains) { return true }
        // Vendor-agnostic markers vision variants carry in the id itself
        // (qwen3-vl, mimo-vl, minimax-vl-01, moonshot-v1-…-vision-preview, …).
        let markers = ["vision", "-vl", "vl-", "omni"]
        if markers.contains(where: m.contains) { return true }
        // GLM's vision line is the trailing v (glm-4v, glm-4.5v, glm-4.6v).
        if m.hasPrefix("glm"), m.hasSuffix("v") { return true }
        return false
    }

    // MARK: Server-side web search (XII-118)

    /// How this provider exposes a *real* web search the model can run during a
    /// turn — using the key the app already holds, with no separate search account
    /// (the keyless constraint). `nil` means the provider has no native search, so
    /// the request goes out unchanged and the assistant answers without searching
    /// (the honest no-search fallback from XII-116). The three shapes are genuinely
    /// different wire protocols, verified per-provider against current vendor docs:
    ///
    /// - `.tool`  (Anthropic, GLM, OpenRouter): inject one entry into the request
    ///   `tools` array; the search runs entirely server-side and the grounded text
    ///   streams straight back. The client never executes or echoes anything.
    /// - `.builtin` (Kimi): inject a `builtin_function` tool. The model emits a
    ///   tool call the client must echo back *unchanged* (its arguments JSON) for
    ///   the provider to actually run the search — handled by the matching
    ///   passthrough tool, not by any local execution.
    /// - `.chatModelSwap` (OpenAI): chat-completions has no search tool; the only
    ///   path is to swap the request `model` to a search-capable id and add a
    ///   parameter, which forces a search every turn.
    enum ServerSearch {
        /// A `tools`-array entry (provider-shaped) the search rides on. Fully
        /// server-side; nothing comes back through the harness's tool loop.
        case tool([String: Any])
        /// A `builtin_function` tool plus the body fields it requires (e.g.
        /// `thinking: disabled`). The client echoes the call back; see
        /// `KimiWebSearchPassthrough`.
        case builtin(tool: [String: Any], bodyExtras: [String: Any])
        /// Swap the request model to `model` and merge `bodyExtras` (e.g.
        /// `web_search_options`). Used where chat-completions can't carry a tool.
        case chatModelSwap(model: String, bodyExtras: [String: Any])
    }

    /// The native search shape for this provider, or `nil` for no native search.
    /// Tier-1 coverage (Anthropic / OpenAI / Kimi / GLM / OpenRouter); the rest
    /// fall through to `nil` and answer without searching.
    var serverSearch: ServerSearch? {
        switch self {
        case .anthropic:
            // Fully server-side; streams server_tool_use → web_search_tool_result
            // → cited text through the existing /v1/messages SSE parser. Requires
            // the user to enable web search in the Anthropic Console.
            return .tool(["type": "web_search_20260318", "name": "web_search"])
        // GLM is intentionally NOT here. Its in-chat `tools:[{web_search}]` path
        // was verified (live, with a real key) to silently NOT search on the
        // current account/models — it returned training-cutoff hallucinations with
        // no results, the exact dishonest behavior XII-116 fought. GLM's real
        // search runs through a *client-side* tool against Zhipu's standalone Web
        // Search API instead — see `GLMWebSearchTool` and `ToolRegistry.standard`.
        case .openrouter:
            // One tool for every proxied model; bills OpenRouter credits, no extra
            // key. The old `:online` model suffix is deprecated — don't use it.
            return .tool([
                "type": "openrouter:web_search",
                "parameters": ["engine": "auto", "max_results": 5,
                               "search_context_size": "medium"],
            ])
        case .kimi:
            // Builtin function the client must echo back unchanged for Moonshot to
            // run the search. `thinking: disabled` is required and rides at the
            // body root (the SDK's `extra_body` is just a pass-through wrapper).
            return .builtin(
                tool: ["type": "builtin_function", "function": ["name": "$web_search"]],
                bodyExtras: ["thinking": ["type": "disabled"]])
        case .openai:
            // Chat-completions has no search *tool*; the search-API model performs
            // a web search every turn. `web_search_options` is its enabling param.
            return .chatModelSwap(model: "gpt-5-search-api",
                                  bodyExtras: ["web_search_options": [String: Any]()])
        default:
            return nil
        }
    }

    /// The function name a provider uses for a *builtin* search the client must
    /// echo back (Kimi's `$web_search`). The harness matches an incoming tool call
    /// against this to route it to the passthrough instead of failing on an unknown
    /// tool. `nil` for providers whose search needs no echo.
    var builtinSearchName: String? {
        if case .builtin = serverSearch, case .kimi = self { return "$web_search" }
        return nil
    }

    /// Whether this provider can run a *real* web search during a turn — either a
    /// native server-side search (`serverSearch != nil`: Anthropic / OpenAI / Kimi
    /// / OpenRouter) or the client-side `GLMWebSearchTool` (GLM). The five vendors
    /// that have neither (DeepSeek / Gemini / Qwen / MiniMax / MiMo) return false:
    /// their requests go out unchanged and the model answers only from its training
    /// data, with no way to reach current information. The Settings provider menu
    /// uses this to demote the no-search vendors into a "not recommended" submenu.
    var supportsWebSearch: Bool {
        serverSearch != nil || self == .glm
    }
}

/// Offline stand-in. Returns a short, plausible-looking answer after a brief
/// "thinking" delay so the loading state is exercised exactly as it will be with
/// a real backend. Not meant to be smart — just to make the UI fully live.
struct StubAIService: AIService {
    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        // The stub deliberately ignores `system`: the placeholder answer is built
        // only from the user's question, never from the persona/instruction text.
        // Binding it to `_` makes that explicit so the system prompt can't leak
        // into the streamed output (and thence into saved history).
        _ = system
        let q = (messages.last(where: { $0.role == "user" })?.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Count prior user turns so a follow-up visibly knows it has context —
        // proof the whole thread reaches the service, not just the latest line.
        let priorTurns = messages.filter { $0.role == "user" }.count - 1
        let contextNote = priorTurns > 0
            ? "(Following up on \(priorTurns) earlier \(priorTurns == 1 ? "question" : "questions").) "
            : ""
        let text = """
        \(contextNote)Here's a placeholder answer to **\(q)**.

        \(L("stub.noModel"))
        """
        return AsyncThrowingStream { continuation in
            let task = Task {
                // Brief lead-in so the "thinking" wave shows, then dribble the
                // text out word by word to exercise the streaming path.
                try? await Task.sleep(nanoseconds: 700_000_000)
                for word in text.split(separator: " ", omittingEmptySubsequences: false) {
                    if Task.isCancelled { break }
                    continuation.yield(String(word) + " ")
                    try? await Task.sleep(nanoseconds: 35_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - OpenAI-compatible live backend

/// One client for every OpenAI-compatible vendor (MiMo, DeepSeek, …). They all
/// expose the same `/v1/chat/completions` contract, so this is a thin POST — no
/// SDK, no framework, just `URLSession`. The only thing that varies per vendor is
/// the `Provider` (endpoint + model + key), passed in at construction.
///
/// The persona arrives as `system` and the running conversation as `messages`
/// (alternating user/assistant turns), which map straight onto the chat schema —
/// the system prompt as the first message, then the history. Cancellation is
/// honored: if the panel collapses mid-flight the `URLSession` task is torn down
/// with the surrounding `Task`.
struct OpenAICompatAIService: AIService {
    let apiKey: String
    let provider: Provider
    /// Model id; defaults to the provider's default when not overridden.
    var model: String

    init(provider: Provider, apiKey: String, model: String? = nil) {
        self.provider = provider
        self.apiKey = apiKey
        self.model = model ?? provider.defaultModel
    }

    private var endpoint: URL { provider.endpoint }

    /// Cap on how much of an error response body we'll read before giving up. A
    /// hostile/broken endpoint could stream an unbounded error body; we only need
    /// a short snippet for the message, so stop well before it can grow the
    /// process's memory. Shared by both clients via `drainErrorBody`.
    static let maxErrorBodyChars = 4096

    /// How long a streaming request may sit idle before `URLSession` aborts it, so
    /// a backend that opens the connection and then hangs can't pin the task open
    /// forever. Generous enough for slow first-token latency on real providers.
    static let streamTimeout: TimeInterval = 60

    /// Drain an error response body up to `maxErrorBodyChars`, then stop reading —
    /// the rest of the (possibly unbounded) stream is dropped. Shared so both the
    /// OpenAI-compatible and Anthropic clients cap the same way.
    static func drainErrorBody<S: AsyncSequence>(_ lines: S) async -> String
        where S.Element == String {
        var bodyText = ""
        do {
            for try await line in lines {
                bodyText += line
                if bodyText.count >= maxErrorBodyChars {
                    return String(bodyText.prefix(maxErrorBodyChars))
                }
            }
        } catch {
            // Partial body is still useful for the error message.
        }
        return bodyText
    }

    enum ServiceError: LocalizedError {
        case http(provider: String, status: Int, body: String)
        case malformedResponse(provider: String)

        var errorDescription: String? {
            switch self {
            case .http(let provider, let status, _):
                return L("service.error.http", provider, status)
            case .malformedResponse(let provider):
                return L("service.error.malformed", provider)
            }
        }

        /// The HTTP status when this is an HTTP failure, else nil — for the
        /// metadata-only diagnostics breadcrumb (XII-85), never any body text.
        var httpStatus: Int? {
            if case .http(_, let status, _) = self { return status }
            return nil
        }
    }

    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // System prompt first, then the running conversation verbatim —
                // so a follow-up is answered with every prior turn in context.
                let chat = [Message(role: "system", content: system)]
                    + messages.map { Message(role: $0.role, content: $0.content, image: $0.image) }

                // Retry the connect/first-token phase on a transient blip (network
                // drop, timeout, 429, 5xx, or a stream that finishes with zero
                // tokens). We only ever re-attempt while `yieldedAny` is false, so
                // a partially-streamed reply is never replayed/duplicated.
                var yieldedAny = false
                var attempt = 0
                while true {
                    do {
                        var req = URLRequest(url: endpoint)
                        req.httpMethod = "POST"
                        req.timeoutInterval = Self.streamTimeout
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                        for (field, value) in provider.extraHeaders {
                            req.setValue(value, forHTTPHeaderField: field)
                        }

                        let body = RequestBody(
                            model: model,
                            messages: chat,
                            maxTokens: ReplyTokens.budget(forSystem: system),
                            tokenFieldName: provider.maxTokensField,
                            temperature: 0.7,
                            stream: true
                        )
                        req.httpBody = try JSONEncoder().encode(body)

                        let (bytes, response) = try await URLSession.shared.bytes(for: req)
                        guard let http = response as? HTTPURLResponse else {
                            throw ServiceError.malformedResponse(provider: provider.displayName)
                        }
                        guard (200..<300).contains(http.statusCode) else {
                            // Drain the error body (capped) for a useful message.
                            let bodyText = await Self.drainErrorBody(bytes.lines)
                            throw ServiceError.http(provider: provider.displayName,
                                                    status: http.statusCode, body: bodyText)
                        }

                        // Server-Sent Events: each event is a `data: {json}` line,
                        // terminated by `data: [DONE]`. We append only `delta.content`
                        // and deliberately skip `reasoning_content` (the model's
                        // think-aloud) so the notch shows the answer, not the
                        // scratchpad.
                        let decoder = JSONDecoder()
                        for try await line in bytes.lines {
                            if Task.isCancelled { break }
                            guard line.hasPrefix("data:") else { continue }
                            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if payload.isEmpty { continue }
                            if payload == "[DONE]" { break }
                            guard let data = payload.data(using: .utf8),
                                  let chunk = try? decoder.decode(StreamChunk.self, from: data),
                                  let piece = chunk.choices.first?.delta.content,
                                  !piece.isEmpty
                            else { continue }
                            yieldedAny = true
                            continuation.yield(piece)
                        }
                        if Task.isCancelled { continuation.finish(); return }
                        // A clean finish that produced no text is a transient empty
                        // response (free models do this): retry it like a failure
                        // while we still can, otherwise surface it as an error so the
                        // user isn't left staring at a silent blank.
                        if !yieldedAny && attempt < StreamRetry.maxRetries {
                            attempt += 1
                            try await StreamRetry.waitBeforeRetry(attempt)
                            continue
                        }
                        if !yieldedAny {
                            throw ServiceError.malformedResponse(provider: provider.displayName)
                        }
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        continuation.finish()
                        return
                    } catch {
                        // Only retry transient classes, and only before any token
                        // reached the UI. Anything else (bad key, exhausted retries)
                        // ends the stream with the real error for the UI to surface.
                        if !yieldedAny, attempt < StreamRetry.maxRetries,
                           StreamRetry.isRetryable(error) {
                            attempt += 1
                            do { try await StreamRetry.waitBeforeRetry(attempt) }
                            catch { continuation.finish(); return }
                            continue
                        }
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // OpenAI-compatible request / streaming-response shapes (only fields we use).
    //
    // The output-cap field name differs across vendors: MiMo follows OpenAI's
    // newer `max_completion_tokens`, while DeepSeek uses the classic `max_tokens`.
    // We encode the same value under whichever key the provider expects, so the
    // rest of the request stays identical.
    private struct RequestBody: Encodable {
        let model: String
        let messages: [Message]
        let maxTokens: Int
        let tokenFieldName: String
        let temperature: Double
        let stream: Bool

        private struct DynamicKey: CodingKey {
            let stringValue: String
            init(_ s: String) { stringValue = s }
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { return nil }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: DynamicKey.self)
            try c.encode(model, forKey: DynamicKey("model"))
            try c.encode(messages, forKey: DynamicKey("messages"))
            try c.encode(maxTokens, forKey: DynamicKey(tokenFieldName))
            try c.encode(temperature, forKey: DynamicKey("temperature"))
            try c.encode(stream, forKey: DynamicKey("stream"))
        }
    }
    private struct Message: Encodable {
        let role: String
        let content: String
        var image: ChatImage? = nil

        private enum CodingKeys: String, CodingKey { case role, content }
        private enum PartKeys: String, CodingKey {
            case type, text, url
            case imageUrl = "image_url"
        }

        /// A text-only turn keeps `content` as the plain string every backend
        /// accepts. A vision turn (XII-121) switches `content` to the OpenAI
        /// parts array — the text plus the image as an `image_url` data URI —
        /// which OpenAI/OpenRouter/compatible vendors all speak.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(role, forKey: .role)
            guard let image else {
                try c.encode(content, forKey: .content)
                return
            }
            var parts = c.nestedUnkeyedContainer(forKey: .content)
            var textPart = parts.nestedContainer(keyedBy: PartKeys.self)
            try textPart.encode("text", forKey: .type)
            try textPart.encode(content, forKey: .text)
            var imagePart = parts.nestedContainer(keyedBy: PartKeys.self)
            try imagePart.encode("image_url", forKey: .type)
            var url = imagePart.nestedContainer(keyedBy: PartKeys.self, forKey: .imageUrl)
            try url.encode("data:\(image.mediaType);base64,\(image.base64)", forKey: .url)
        }
    }
    /// One `chat.completion.chunk` event. `delta.content` is the incremental
    /// answer text; it's `null` on role-only and reasoning-only chunks, hence
    /// optional.
    private struct StreamChunk: Decodable {
        let choices: [Choice]
        struct Choice: Decodable { let delta: Delta }
        struct Delta: Decodable { let content: String? }
    }
}

// MARK: - Anthropic (Claude) native backend

/// Claude doesn't speak the OpenAI `/v1/chat/completions` contract, so it can't
/// ride `OpenAICompatAIService`. This is the same thin `URLSession` streaming
/// client shaped to Anthropic's native `/v1/messages` API instead:
///   · auth via the `x-api-key` header (not `Authorization: Bearer`)
///   · a required `anthropic-version` header
///   · the system prompt as a top-level `system` field, not a system message
///   · SSE events typed by `event.type`; the answer text arrives in
///     `content_block_delta` events as `delta.text`
///
/// It conforms to the same `AIService` protocol, so the UI and `NotchModel` are
/// none the wiser — `AppDelegate` just constructs this instead when the selected
/// provider is `.anthropic`.
struct AnthropicAIService: AIService {
    let apiKey: String
    let provider: Provider
    var model: String

    /// Pinned API version. Anthropic dates its breaking changes; `2023-06-01` is
    /// the long-stable baseline the Messages API ships against.
    private let anthropicVersion = "2023-06-01"

    init(provider: Provider = .anthropic, apiKey: String, model: String? = nil) {
        self.provider = provider
        self.apiKey = apiKey
        self.model = model ?? provider.defaultModel
    }

    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // See `OpenAICompatAIService.stream` for the retry rationale: ride
                // out a transient connect/first-token blip, but only ever before
                // any token reached the UI so a reply is never duplicated.
                var yieldedAny = false
                var attempt = 0
                while true {
                    do {
                        var req = URLRequest(url: provider.endpoint)
                        req.httpMethod = "POST"
                        req.timeoutInterval = OpenAICompatAIService.streamTimeout
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                        req.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")

                        // Anthropic takes the persona as a top-level `system` field and
                        // the conversation as `messages` (user/assistant only, no system
                        // role in the array) — both arrive ready to forward verbatim, so
                        // a follow-up carries the full prior context.
                        let body = RequestBody(
                            model: model,
                            system: system,
                            messages: messages.map { .init(role: $0.role, content: $0.content, image: $0.image) },
                            maxTokens: ReplyTokens.budget(forSystem: system),
                            stream: true
                        )
                        req.httpBody = try JSONEncoder().encode(body)

                        let (bytes, response) = try await URLSession.shared.bytes(for: req)
                        guard let http = response as? HTTPURLResponse else {
                            throw OpenAICompatAIService.ServiceError.malformedResponse(provider: provider.displayName)
                        }
                        guard (200..<300).contains(http.statusCode) else {
                            let bodyText = await OpenAICompatAIService.drainErrorBody(bytes.lines)
                            throw OpenAICompatAIService.ServiceError.http(provider: provider.displayName,
                                                                          status: http.statusCode, body: bodyText)
                        }

                        // SSE: lines come as `event: <type>` then `data: {json}`. We
                        // don't need the event line — the JSON carries its own `type`,
                        // and we only act on `content_block_delta` / `text_delta`,
                        // appending `delta.text`. Everything else (message_start,
                        // ping, content_block_stop, message_stop, …) is skipped.
                        let decoder = JSONDecoder()
                        for try await line in bytes.lines {
                            if Task.isCancelled { break }
                            guard line.hasPrefix("data:") else { continue }
                            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if payload.isEmpty { continue }
                            guard let data = payload.data(using: .utf8),
                                  let event = try? decoder.decode(StreamEvent.self, from: data),
                                  event.type == "content_block_delta",
                                  let piece = event.delta?.text,
                                  !piece.isEmpty
                            else { continue }
                            yieldedAny = true
                            continuation.yield(piece)
                        }
                        if Task.isCancelled { continuation.finish(); return }
                        if !yieldedAny && attempt < StreamRetry.maxRetries {
                            attempt += 1
                            try await StreamRetry.waitBeforeRetry(attempt)
                            continue
                        }
                        if !yieldedAny {
                            throw OpenAICompatAIService.ServiceError.malformedResponse(provider: provider.displayName)
                        }
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        continuation.finish()
                        return
                    } catch {
                        if !yieldedAny, attempt < StreamRetry.maxRetries,
                           StreamRetry.isRetryable(error) {
                            attempt += 1
                            do { try await StreamRetry.waitBeforeRetry(attempt) }
                            catch { continuation.finish(); return }
                            continue
                        }
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // Anthropic Messages request / streaming-response shapes (only fields we use).
    private struct RequestBody: Encodable {
        let model: String
        let system: String
        let messages: [Message]
        let maxTokens: Int
        let stream: Bool

        enum CodingKeys: String, CodingKey {
            case model, system, messages, stream
            case maxTokens = "max_tokens"
        }
    }
    private struct Message: Encodable {
        let role: String
        let content: String
        var image: ChatImage? = nil

        private enum CodingKeys: String, CodingKey { case role, content }
        private enum PartKeys: String, CodingKey { case type, text, source }
        private enum SourceKeys: String, CodingKey {
            case type, data
            case mediaType = "media_type"
        }

        /// A text-only turn keeps `content` as the plain string. A vision turn
        /// (XII-121) switches it to Anthropic's content-block array — the image
        /// as a base64 `source` block first (the recommended image-then-text
        /// order), then the text block.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(role, forKey: .role)
            guard let image else {
                try c.encode(content, forKey: .content)
                return
            }
            var parts = c.nestedUnkeyedContainer(forKey: .content)
            var imagePart = parts.nestedContainer(keyedBy: PartKeys.self)
            try imagePart.encode("image", forKey: .type)
            var source = imagePart.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            try source.encode("base64", forKey: .type)
            try source.encode(image.mediaType, forKey: .mediaType)
            try source.encode(image.base64, forKey: .data)
            var textPart = parts.nestedContainer(keyedBy: PartKeys.self)
            try textPart.encode("text", forKey: .type)
            try textPart.encode(content, forKey: .text)
        }
    }
    /// One SSE event. We only read `content_block_delta`, whose `delta.text` holds
    /// the incremental answer; on other event types `delta`/`text` are absent.
    private struct StreamEvent: Decodable {
        let type: String
        let delta: Delta?
        struct Delta: Decodable { let text: String? }
    }
}

// MARK: - Remote curated manifest (hot-updated shortlists + defaults, no app release needed)

/// The curated per-provider model shortlist and default, maintained as a static
/// JSON on the website (`https://notch.website/models.json`, deployed with the
/// landing page) instead of baked into the binary. This is what lets the
/// *recommended* lineup — and crucially the default model a fresh install uses —
/// move without shipping an app release: edit the JSON, `vercel deploy --prod`,
/// and every installed copy picks it up on its next refresh.
///
/// Layering: this manifest overrides the bundled `ProviderSpec` lists;
/// `ModelCatalog`'s live `/v1/models` fetch (the vendor's own, exhaustive
/// catalog) still supersedes both in the Settings picker when a key is present.
/// On any failure — never fetched, offline, malformed JSON — callers fall back
/// to the bundled lists, so this can only improve on the shipped defaults,
/// never break them.
///
/// Manifest shape (provider keys are `Provider.rawValue`; the first id in each
/// array doubles as the default model, same convention as `ProviderSpec`):
///
///     { "version": 1, "providers": { "openai": ["gpt-5.5", …], … } }
enum RemoteModelManifest {
    /// Baked into every shipped version — must never move. Schema evolution goes
    /// through the JSON's `version` field, not a new URL.
    private static let manifestURL = URL(string: "https://notch.website/models.json")!
    private static let dataKey = "remoteModelManifest.json"
    private static let fetchedAtKey = "remoteModelManifest.fetchedAt"
    /// Re-fetch at most this often. Launch and Settings-open both call
    /// `refreshIfDue`, so a shorter TTL just means more no-op wakeups.
    private static let ttl: TimeInterval = 6 * 60 * 60

    /// Parsed manifest (provider rawValue → model ids), seeded from the persisted
    /// copy so the very first read after launch already reflects the last fetch.
    /// Guarded by `lock`: read from any thread via `Provider.availableModels`,
    /// replaced on a background task after a successful fetch.
    private static let lock = NSLock()
    private static var cached: [String: [String]]? = loadPersisted()
    private static var fetching = false

    /// Synchronous critical section — NSLock's lock/unlock can't be called
    /// directly from async code (Swift 6 rule), so the async `refreshIfDue`
    /// funnels its state touches through here.
    private static func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// The curated list for `provider`, or `nil` when the manifest has never been
    /// fetched (or doesn't cover this provider) — callers fall back to the
    /// bundled `ProviderSpec` list. First entry doubles as the default model.
    static func models(for provider: Provider) -> [String]? {
        withLock { cached?[provider.rawValue] }
    }

    /// Fetch the manifest when the cached copy is older than `ttl` (or absent).
    /// Cheap no-op otherwise, so callers can invoke it opportunistically. Any
    /// failure leaves the previous cache in place.
    static func refreshIfDue() async {
        let due: Bool = withLock {
            guard !fetching, cached == nil || isStale else { return false }
            fetching = true
            return true
        }
        guard due else { return }
        defer { withLock { fetching = false } }

        var req = URLRequest(url: manifestURL)
        req.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let lists = decode(data) else { return }
        withLock { cached = lists }
        UserDefaults.standard.set(data, forKey: dataKey)
        UserDefaults.standard.set(Date(), forKey: fetchedAtKey)
    }

    private static var isStale: Bool {
        guard let last = UserDefaults.standard.object(forKey: fetchedAtKey) as? Date
        else { return true }
        return Date().timeIntervalSince(last) >= ttl
    }

    private static func loadPersisted() -> [String: [String]]? {
        guard let data = UserDefaults.standard.data(forKey: dataKey) else { return nil }
        return decode(data)
    }

    /// Decode + sanitize: drop empty ids and empty lists, and reject a manifest
    /// with no usable providers at all, so a bad deploy can't blank the pickers —
    /// `models(for:)` returning `nil` keeps the bundled fallback in charge.
    private static func decode(_ data: Data) -> [String: [String]]? {
        struct Manifest: Decodable { let providers: [String: [String]] }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return nil }
        let cleaned = manifest.providers
            .mapValues { $0.filter { !$0.isEmpty } }
            .filter { !$0.value.isEmpty }
        return cleaned.isEmpty ? nil : cleaned
    }
}

// MARK: - Live model catalog (hot-updated, no app release needed)

/// Fetches the *live* list of models a provider currently serves, so the Settings
/// picker stays current when a vendor adds or renames a model — no new app build
/// required. This is the answer to "I can't ship a release every time a model name
/// changes": the names come from the vendor's own API at runtime.
///
/// Every OpenAI-compatible vendor exposes `GET /v1/models` (same auth as chat).
/// Anthropic exposes the same path with its `x-api-key` + `anthropic-version`
/// headers. We derive the models URL from the chat endpoint, fetch, and return the
/// ids. On any failure (no key, offline, vendor without the endpoint) the caller
/// falls back to `Provider.availableModels` — the built-in shortlist — so the
/// picker is never empty.
enum ModelCatalog {
    /// Fetch the provider's current model ids. Returns `nil` on any error so the
    /// caller can fall back to the bundled `availableModels` list.
    static func fetch(for provider: Provider, apiKey: String) async -> [String]? {
        guard let url = modelsURL(for: provider) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if provider.isOpenAICompatible {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        } else {
            // Anthropic: same key header + pinned version as the messages API.
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        req.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            let list = try JSONDecoder().decode(ModelList.self, from: data)
            let ids = list.data.map(\.id).filter { !$0.isEmpty }
            // OpenRouter's catalog is its FULL marketplace — hundreds of ids, most
            // of them paid, which a freshly-connected $0 account can't call. Offer
            // only what actually works free: the auto-router plus the current
            // `:free` variants.
            if provider == .openrouter {
                let free = ids.filter { $0.hasSuffix(":free") }.sorted()
                return ["openrouter/free"] + free
            }
            return ids.isEmpty ? nil : ids
        } catch {
            return nil
        }
    }

    /// Turn a chat endpoint into its `/models` sibling:
    ///   `.../v1/chat/completions`        → `.../v1/models`
    ///   `.../v1/messages` (Anthropic)    → `.../v1/models`
    ///   `.../compatible-mode/v1/chat/...`→ `.../compatible-mode/v1/models`
    /// Done by string surgery on the path so it works for every vendor's prefix.
    private static func modelsURL(for provider: Provider) -> URL? {
        let s = provider.endpoint.absoluteString
        for suffix in ["/chat/completions", "/messages"] where s.hasSuffix(suffix) {
            return URL(string: String(s.dropLast(suffix.count)) + "/models")
        }
        return nil
    }

    /// OpenAI-style `{ "data": [ { "id": "..." }, ... ] }`. Anthropic's
    /// `/v1/models` returns the same `data: [{ id }]` shape, so one decoder fits
    /// both.
    private struct ModelList: Decodable {
        let data: [Entry]
        struct Entry: Decodable { let id: String }
    }
}

// MARK: - Connectivity test

/// A one-shot "does this key actually work?" check for the Settings panel. It hits
/// the provider's `GET /v1/models` with the user's key — the same lightweight,
/// token-free request `ModelCatalog` uses — and turns the outcome into a verdict
/// the UI can show plainly. We probe `/v1/models` (not a chat completion) so the
/// test costs nothing and doesn't depend on a specific model id being valid.
enum ConnectivityTest {
    enum Result: Equatable {
        case ok                    // reachable + authenticated
        case missingKey            // nothing to test
        case unauthorized(Int)     // 401/403 — bad or revoked key
        case http(Int)             // other non-2xx from the server
        case offline               // no network / DNS / connection failure
        case timedOut
        case failed(String)        // anything else, with a short reason

        /// Short user-facing line for the Settings footer.
        var message: String {
            switch self {
            case .ok:                 return L("conn.ok")
            case .missingKey:         return L("conn.missingKey")
            case .unauthorized:       return L("conn.unauthorized")
            case .http(let code):     return L("conn.serverError", code)
            case .offline:            return L("conn.offline")
            case .timedOut:           return L("conn.timedOut")
            case .failed(let why):    return why
            }
        }

        var isOK: Bool { self == .ok }
    }

    /// Probe `provider` with `apiKey`. Network call; safe to await off the main
    /// actor. Returns a verdict — never throws.
    static func run(provider: Provider, apiKey: String) async -> Result {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .missingKey }
        guard let url = probeURL(for: provider) else {
            // No /models sibling we can derive — fall back to "we can't test this".
            return .failed(L("conn.unavailable"))
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if provider.isOpenAICompatible {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        req.timeoutInterval = 12

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failed(L("conn.unexpected"))
            }
            switch http.statusCode {
            case 200..<300:   return .ok
            case 401, 403:    return .unauthorized(http.statusCode)
            default:          return .http(http.statusCode)
            }
        } catch let error as URLError {
            switch error.code {
            case .timedOut:                   return .timedOut
            case .notConnectedToInternet,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .networkConnectionLost,
                 .dnsLookupFailed:            return .offline
            default:                          return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Same path derivation as `ModelCatalog.modelsURL`, duplicated here so the test
    /// doesn't depend on that enum's private helper. OpenRouter is the exception:
    /// its `/models` is public (answers 200 to any key, so it can't judge one) —
    /// `/api/v1/key` requires auth and describes the key, making it the honest probe.
    private static func probeURL(for provider: Provider) -> URL? {
        if provider == .openrouter {
            return URL(string: "https://openrouter.ai/api/v1/key")
        }
        let s = provider.endpoint.absoluteString
        for suffix in ["/chat/completions", "/messages"] where s.hasSuffix(suffix) {
            return URL(string: String(s.dropLast(suffix.count)) + "/models")
        }
        return nil
    }
}

// MARK: - Agent (tool-calling) turn streaming
//
// `streamTurn` is the richer counterpart to `stream`: it yields a `TurnEvent`
// stream — text, tool-call requests, and a final stop reason — for one model
// turn, which is what the `AgentHarness` loop runs on. The two clients lower the
// provider-neutral `AgentMessage`/`ToolSpec` into their respective wire formats
// (OpenAI `tool_calls` vs Anthropic `tool_use`), which differ in three ways: how
// the tool list is shaped, how a tool call streams in, and how a tool result is
// sent back.
//
// JSON note: tool inputs are arbitrary objects, so these clients build request
// bodies with `JSONSerialization` against `[String: Any]` rather than `Encodable`
// structs — Swift's `Codable` can't round-trip a heterogeneous `[String: Any]`,
// and the harness already speaks that shape.

/// Shared helpers for encoding a JSON request body and reading SSE `data:` lines,
/// used by both agent clients.
private enum AgentWire {
    /// Serialize a JSON object to request-body data.
    static func body(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
    /// Parse one decoded JSON-string argument blob into `[String: Any]`. Tool args
    /// always decode to an object; a malformed/empty blob yields an empty dict so a
    /// no-argument call still runs.
    static func decodeArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }
}

extension OpenAICompatAIService: AgentCapableService {
    func streamTurn(system: String,
                    messages: [AgentMessage],
                    tools: [ToolSpec]) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // Retry the connect/first-event phase on a transient blip, only
                // while nothing meaningful has reached the harness yet. For a tool
                // turn "meaningful" is text OR a tool call — a turn that legitimately
                // emits only a tool call (search-then-answer) must NOT be retried as
                // if empty. See `OpenAICompatAIService.stream` for the rationale.
                var emittedAny = false
                var attempt = 0
                while true {
                    do {
                        var req = URLRequest(url: provider.endpoint)
                        req.httpMethod = "POST"
                        req.timeoutInterval = Self.streamTimeout
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                        for (field, value) in provider.extraHeaders {
                            req.setValue(value, forHTTPHeaderField: field)
                        }

                        // Server-side web search (XII-118): for OpenAI-compatible
                        // vendors the native search rides in three different shapes.
                        // `.tool` (GLM) adds a tools-array entry; `.builtin` (Kimi)
                        // adds a builtin tool plus required body fields and is echoed
                        // back by the harness; `.chatModelSwap` (OpenAI) swaps the model
                        // and adds a parameter. Resolve the effective model + any extra
                        // search tool/body up front, then build the request once.
                        // A unified client-side searcher (Keenable by default, Exa
                        // when keyed) replaces every provider's native search — it
                        // rides in `tools` instead (see `ToolRegistry.standard(for:)`),
                        // so the vendor's own server search stands down.
                        var effectiveModel = model
                        var searchTool: [String: Any]? = nil
                        var bodyExtras: [String: Any] = [:]
                        switch (APIKeyStore.unifiedSearchActive ? nil : provider.serverSearch) {
                        case .tool(let t):
                            searchTool = t
                        case .builtin(let t, let extras):
                            searchTool = t
                            bodyExtras = extras
                        case .chatModelSwap(let m, let extras):
                            effectiveModel = m
                            bodyExtras = extras
                        case nil:
                            break
                        }

                        // The model's own client-side tools plus, when present, the
                        // provider's server-search entry. Kept in one array so a turn
                        // can both call a local tool and search.
                        var wireTools = Self.wireTools(tools)
                        if let searchTool { wireTools.append(searchTool) }

                        var body: [String: Any] = [
                            "model": effectiveModel,
                            "messages": Self.wireMessages(system: system, messages: messages),
                            provider.maxTokensField: ReplyTokens.budget(forSystem: system),
                            "temperature": 0.7,
                            "stream": true,
                        ]
                        if !wireTools.isEmpty { body["tools"] = wireTools }
                        for (k, v) in bodyExtras { body[k] = v }
                        req.httpBody = try AgentWire.body(body)

                        let (bytes, response) = try await URLSession.shared.bytes(for: req)
                        guard let http = response as? HTTPURLResponse else {
                            throw ServiceError.malformedResponse(provider: provider.displayName)
                        }
                        guard (200..<300).contains(http.statusCode) else {
                            let bodyText = await Self.drainErrorBody(bytes.lines)
                            throw ServiceError.http(provider: provider.displayName,
                                                    status: http.statusCode, body: bodyText)
                        }

                        // Tool calls arrive in fragments across many SSE chunks: the
                        // first delta for a call carries its `index`, `id`, and
                        // `function.name`; subsequent deltas for the same `index`
                        // append to `function.arguments`. We accumulate per index and
                        // emit one `toolCall` per call once the stream completes.
                        var callsByIndex: [Int: (id: String, name: String, args: String)] = [:]
                        var finishReason: String? = nil
                        var yieldedText = false

                        for try await line in bytes.lines {
                            if Task.isCancelled { break }
                            guard line.hasPrefix("data:") else { continue }
                            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if payload.isEmpty { continue }
                            if payload == "[DONE]" { break }
                            guard let data = payload.data(using: .utf8),
                                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  let choices = obj["choices"] as? [[String: Any]],
                                  let choice = choices.first
                            else { continue }

                            if let fr = choice["finish_reason"] as? String { finishReason = fr }
                            guard let delta = choice["delta"] as? [String: Any] else { continue }

                            if let content = delta["content"] as? String, !content.isEmpty {
                                yieldedText = true
                                emittedAny = true
                                continuation.yield(.text(content))
                            }
                            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                                for tc in toolCalls {
                                    let idx = tc["index"] as? Int ?? 0
                                    var entry = callsByIndex[idx] ?? (id: "", name: "", args: "")
                                    if let id = tc["id"] as? String, !id.isEmpty { entry.id = id }
                                    if let fn = tc["function"] as? [String: Any] {
                                        if let n = fn["name"] as? String, !n.isEmpty { entry.name = n }
                                        if let a = fn["arguments"] as? String { entry.args += a }
                                    }
                                    callsByIndex[idx] = entry
                                }
                            }
                        }
                        if Task.isCancelled { continuation.finish(); return }

                        let namedCalls = callsByIndex.keys.sorted().compactMap { idx -> (id: String, name: String, args: String)? in
                            let c = callsByIndex[idx]!
                            guard !c.name.isEmpty else { return nil }
                            // Some vendors omit an id; synthesize a stable one so the
                            // result can be matched back.
                            return (id: c.id.isEmpty ? "call_\(idx)" : c.id, name: c.name, args: c.args)
                        }

                        // A turn that produced neither text nor a tool call is an
                        // empty response — retry it like a transient failure while we
                        // still can, otherwise surface it as an error.
                        if !yieldedText && namedCalls.isEmpty && !emittedAny {
                            if attempt < StreamRetry.maxRetries {
                                attempt += 1
                                try await StreamRetry.waitBeforeRetry(attempt)
                                continue
                            }
                            throw ServiceError.malformedResponse(provider: provider.displayName)
                        }

                        // Emit the assembled tool calls in index order.
                        for c in namedCalls {
                            continuation.yield(.toolCall(id: c.id, name: c.name,
                                                         input: AgentWire.decodeArgs(c.args)))
                        }
                        continuation.yield(.finished(stopReason: finishReason))
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        continuation.finish()
                        return
                    } catch {
                        if !emittedAny, attempt < StreamRetry.maxRetries,
                           StreamRetry.isRetryable(error) {
                            attempt += 1
                            do { try await StreamRetry.waitBeforeRetry(attempt) }
                            catch { continuation.finish(); return }
                            continue
                        }
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// OpenAI tool list: `[{type:"function", function:{name, description,
    /// parameters}}]`. `parameters` is the tool's JSON Schema. A `$`-prefixed name
    /// is a provider *builtin* (Kimi's `$web_search`, XII-118) and takes the
    /// `builtin_function` shape with only a name — no description/parameters, which
    /// the vendor rejects on a builtin.
    private static func wireTools(_ tools: [ToolSpec]) -> [[String: Any]] {
        tools.map { t in
            if t.name.hasPrefix("$") {
                return ["type": "builtin_function",
                        "function": ["name": t.name]]
            }
            return ["type": "function",
                    "function": ["name": t.name,
                                 "description": t.description,
                                 "parameters": t.schema]]
        }
    }

    /// Lower the neutral conversation to OpenAI chat messages. The system prompt
    /// leads; a plain turn is `{role, content}`; an assistant tool-call turn is
    /// `{role:"assistant", content, tool_calls:[…]}`; a tool-results turn becomes
    /// one `{role:"tool", tool_call_id, content}` message per result.
    private static func wireMessages(system: String,
                                     messages: [AgentMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = [["role": "system", "content": system]]
        for m in messages {
            switch m.kind {
            case .text(let role, let text):
                out.append(["role": role, "content": text])
            case .assistantToolCalls(let text, let calls):
                let toolCalls: [[String: Any]] = calls.map { c in
                    let argsJSON = (try? String(data: JSONSerialization.data(withJSONObject: c.input),
                                                encoding: .utf8)) ?? "{}"
                    return ["id": c.id,
                            "type": "function",
                            "function": ["name": c.name, "arguments": argsJSON ?? "{}"]]
                }
                out.append(["role": "assistant",
                            "content": text,
                            "tool_calls": toolCalls])
            case .toolResults(let results):
                for r in results {
                    // `name` is required for Kimi's builtin-search echo to match
                    // (XII-118); OpenAI and the other vendors ignore the extra
                    // field, so it's safe to always include when known.
                    var msg: [String: Any] = ["role": "tool",
                                              "tool_call_id": r.id,
                                              "content": r.result]
                    if !r.name.isEmpty { msg["name"] = r.name }
                    out.append(msg)
                }
            }
        }
        return out
    }
}

extension AnthropicAIService: AgentCapableService {
    func streamTurn(system: String,
                    messages: [AgentMessage],
                    tools: [ToolSpec]) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // Retry the connect/first-event phase on a transient blip, only
                // while nothing meaningful (text OR a tool call) has reached the
                // harness — so a search-then-answer turn isn't mistaken for empty
                // and a partial reply is never duplicated. See
                // `OpenAICompatAIService.stream` for the rationale.
                var emittedAny = false
                var attempt = 0
                while true {
                    do {
                        var req = URLRequest(url: provider.endpoint)
                        req.httpMethod = "POST"
                        req.timeoutInterval = OpenAICompatAIService.streamTimeout
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                        // Client-side tools plus, when present, Anthropic's native
                        // server-side web search (XII-118). It rides in the same
                        // `tools` array; the search runs server-side and streams back
                        // through this same SSE loop as `server_tool_use` /
                        // `web_search_tool_result` blocks (skipped below as unknown
                        // block types — the cited answer text streams as normal
                        // `text_delta`). Requires the user to have enabled web search
                        // in the Anthropic Console; if not, the API returns a
                        // `web_search_tool_result_error` block and the model answers
                        // without it.
                        // The unified client-side searcher (Keenable by default, Exa
                        // when keyed) replaces native search for every provider (it
                        // rides as a client-side tool instead), so Anthropic's
                        // server-side web_search stands down too.
                        var wireTools = Self.wireTools(tools)
                        if !APIKeyStore.unifiedSearchActive,
                           case .tool(let searchTool)? = provider.serverSearch {
                            wireTools.append(searchTool)
                        }
                        var body: [String: Any] = [
                            "model": model,
                            "system": system,
                            "messages": Self.wireMessages(messages),
                            "max_tokens": ReplyTokens.budget(forSystem: system),
                            "stream": true,
                        ]
                        if !wireTools.isEmpty { body["tools"] = wireTools }
                        req.httpBody = try AgentWire.body(body)

                        let (bytes, response) = try await URLSession.shared.bytes(for: req)
                        guard let http = response as? HTTPURLResponse else {
                            throw OpenAICompatAIService.ServiceError.malformedResponse(provider: provider.displayName)
                        }
                        guard (200..<300).contains(http.statusCode) else {
                            let bodyText = await OpenAICompatAIService.drainErrorBody(bytes.lines)
                            throw OpenAICompatAIService.ServiceError.http(provider: provider.displayName,
                                                                          status: http.statusCode, body: bodyText)
                        }

                        // Anthropic streams each content block separately. A `tool_use`
                        // block opens with `content_block_start` (carrying the block's
                        // `id` and tool `name`), streams its arguments as
                        // `input_json_delta` partial-JSON fragments, and closes with
                        // `content_block_stop`. We track the open block by index and
                        // accumulate its partial JSON; text blocks stream as
                        // `text_delta`. The final `message_delta` carries `stop_reason`.
                        var blocks: [Int: (id: String, name: String, partialJSON: String)] = [:]
                        var stopReason: String? = nil

                        for try await line in bytes.lines {
                            if Task.isCancelled { break }
                            guard line.hasPrefix("data:") else { continue }
                            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if payload.isEmpty { continue }
                            guard let data = payload.data(using: .utf8),
                                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  let type = obj["type"] as? String
                            else { continue }

                            switch type {
                            case "content_block_start":
                                let idx = obj["index"] as? Int ?? 0
                                if let block = obj["content_block"] as? [String: Any],
                                   block["type"] as? String == "tool_use" {
                                    let id = block["id"] as? String ?? "toolu_\(idx)"
                                    let name = block["name"] as? String ?? ""
                                    blocks[idx] = (id: id, name: name, partialJSON: "")
                                }
                            case "content_block_delta":
                                let idx = obj["index"] as? Int ?? 0
                                guard let delta = obj["delta"] as? [String: Any] else { break }
                                switch delta["type"] as? String {
                                case "text_delta":
                                    if let t = delta["text"] as? String, !t.isEmpty {
                                        emittedAny = true
                                        continuation.yield(.text(t))
                                    }
                                case "input_json_delta":
                                    if let partial = delta["partial_json"] as? String,
                                       var entry = blocks[idx] {
                                        entry.partialJSON += partial
                                        blocks[idx] = entry
                                    }
                                default:
                                    break
                                }
                            case "content_block_stop":
                                let idx = obj["index"] as? Int ?? 0
                                if let b = blocks[idx], !b.name.isEmpty {
                                    emittedAny = true
                                    continuation.yield(.toolCall(id: b.id, name: b.name,
                                                                 input: AgentWire.decodeArgs(b.partialJSON)))
                                    blocks[idx] = nil
                                }
                            case "message_delta":
                                if let delta = obj["delta"] as? [String: Any],
                                   let sr = delta["stop_reason"] as? String {
                                    stopReason = sr
                                }
                            case "message_stop":
                                break
                            default:
                                break
                            }
                        }
                        if Task.isCancelled { continuation.finish(); return }

                        // A turn that produced neither text nor a tool call is an
                        // empty response — retry like a transient failure while we
                        // still can, otherwise surface it as an error.
                        if !emittedAny {
                            if attempt < StreamRetry.maxRetries {
                                attempt += 1
                                try await StreamRetry.waitBeforeRetry(attempt)
                                continue
                            }
                            throw OpenAICompatAIService.ServiceError.malformedResponse(provider: provider.displayName)
                        }
                        continuation.yield(.finished(stopReason: stopReason))
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        continuation.finish()
                        return
                    } catch {
                        if !emittedAny, attempt < StreamRetry.maxRetries,
                           StreamRetry.isRetryable(error) {
                            attempt += 1
                            do { try await StreamRetry.waitBeforeRetry(attempt) }
                            catch { continuation.finish(); return }
                            continue
                        }
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Anthropic tool list: `[{name, description, input_schema}]`.
    private static func wireTools(_ tools: [ToolSpec]) -> [[String: Any]] {
        tools.map { t in
            ["name": t.name, "description": t.description, "input_schema": t.schema]
        }
    }

    /// Lower the neutral conversation to Anthropic messages. The system prompt is
    /// a top-level field (added in `streamTurn`), not a message. A plain turn is
    /// `{role, content:"…"}`. An assistant tool-call turn is `{role:"assistant",
    /// content:[ {type:text,…}?, {type:tool_use, id, name, input}… ]}`. A
    /// tool-results turn is `{role:"user", content:[{type:tool_result,
    /// tool_use_id, content, is_error?}…]}`.
    private static func wireMessages(_ messages: [AgentMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in messages {
            switch m.kind {
            case .text(let role, let text):
                out.append(["role": role, "content": text])
            case .assistantToolCalls(let text, let calls):
                var content: [[String: Any]] = []
                if !text.isEmpty { content.append(["type": "text", "text": text]) }
                for c in calls {
                    content.append(["type": "tool_use",
                                    "id": c.id,
                                    "name": c.name,
                                    "input": c.input])
                }
                out.append(["role": "assistant", "content": content])
            case .toolResults(let results):
                let content: [[String: Any]] = results.map { r in
                    var block: [String: Any] = ["type": "tool_result",
                                                "tool_use_id": r.id,
                                                "content": r.result]
                    if r.isError { block["is_error"] = true }
                    return block
                }
                out.append(["role": "user", "content": content])
            }
        }
        return out
    }
}
