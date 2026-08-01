import Foundation

extension URLRequest {
    /// Set `Authorization: Bearer …`, or leave the header off entirely when there
    /// is no key. Every hosted vendor always has one; a user's own endpoint
    /// (`Provider.custom` pointed at Ollama / LM Studio / vLLM) authenticates
    /// nobody, and a blank `Bearer ` is worse than no header at all — some servers
    /// reject the empty credential outright.
    mutating func setBearer(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
    }
}

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

/// The one place a wire output cap is still spoken about.
///
/// Notch does **not** cap output length on the wire. Reply length is a matter of
/// style, and it is already set where style belongs: the persona says "keep it
/// under 90 words" (`notchSystemPrompt`). `max_tokens` cannot express that — it
/// isn't a request for brevity, it's a guillotine, and it falls mid-sentence.
///
/// The cap we used to send (a flat 1024) never once shortened an answer: a
/// 90-word reply is ~150 tokens, five to eight times under it. The only thing it
/// ever did was cut off models that *think*, because on a reasoning model
/// `max_tokens` is not the answer's budget — reasoning and answer come out of one
/// pot. Measured on the wire, one question, cap vs no cap:
///
///   · `deepseek-v4-flash`         1024 → 1542 chars of reasoning, answer strangled
///                                        at 79 chars, `finish_reason: length`
///                                 none → answers fully, `finish_reason: stop`
///   · `thinkingmachines/inkling`  1024 → **zero** content, `finish_reason: length`
///                                        (which the stream layer can only report
///                                        as "unexpected response")
///                                 none → answers fully, `finish_reason: stop`
///
/// And no provider we hold a key for (DeepSeek, GLM, OpenRouter, Vercel) applies a
/// stingy default when the field is absent — every one finished cleanly. So the
/// field is simply not sent.
enum ReplyTokens {
    /// Anthropic is the exception, and only because its Messages API *requires*
    /// `max_tokens` — omitting it is a 400. So this is a ceiling in the "nothing
    /// should ever legitimately reach it" sense, not a length knob: high enough
    /// that thinking plus a 90-word answer never comes close, low enough to stay
    /// within what every Claude model accepts as a max output.
    ///
    /// Untested here — this machine has no Anthropic key, so unlike the numbers
    /// above this one rests on the documented output ceiling rather than on a
    /// measurement of our own.
    static let anthropicRequiredCeiling = 8192
}

/// The one place sampling knobs are still spoken about.
///
/// Notch does **not** send `temperature`. Same reasoning as `ReplyTokens`: reply
/// character is a matter of style, and style is already set where it belongs —
/// `notchSystemPrompt`. A flat 0.7 was never solving anything; it just rode along
/// on every request as a leftover default.
///
/// It was also actively breaking models. OpenAI locks the reasoning line to the
/// default (1) from `gpt-5.5` onward, so any explicit value is a hard 400 — not a
/// warning, not a clamp. Measured on the wire with the same key, one question,
/// with vs. without the field:
///
///   · `gpt-5.6-terra` / `gpt-5.6-luna`  0.7 → 400 "Unsupported value:
///                                             'temperature' ... Only the default
///                                             (1) value is supported"
///                                      none → streams normally
///   · `gpt-5.5`                          0.7 → same 400 (and it's the first entry
///                                             in the bundled shortlist)
///   · `gpt-5.4` / `gpt-5.4-mini`         0.7 → still accepted
///
/// So the breakage moves with the model roster, and a per-model allow/deny list
/// would have to be re-litigated on every OpenAI release for a knob we don't want
/// in the first place. The field is simply not sent — every provider's default is
/// fine for a 90-word answer.
///
/// No members: unlike `ReplyTokens` there is no value left to hold, so this is a
/// greppable anchor for the request builders that cite it.
enum SamplingKnobs {}

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
/// The tool-use stance is a measured balance between two opposite failure
/// modes. Answering time-sensitive questions from memory fabricates stale facts
/// (training data predates "today") — but the previous blanket "err toward
/// searching" wording made models burn whole extra round-trips on stable
/// knowledge. Benchmarked live (2026-07, DeepSeek/GLM/OpenRouter, 10 queries ×
/// 3 prompt variants): the search-leaning wording sent "how do I force-restart
/// an iPhone" through a 12–32s web search and let one FX-rate query spiral for
/// 9 search rounds / 50s, while this wording answered every stable question in
/// one round and still searched 6/6 of the genuinely time-sensitive ones with
/// equally correct answers. So the persona names the split explicitly: direct
/// answer is the default for stable knowledge, and search remains mandatory —
/// never memory — for changeable facts.
let notchSystemPrompt = """
You are a helpful assistant living in the notch of a Mac. Answer the user's \
question concisely and warmly in the user's language. Keep it under 90 words, \
no markdown headers.

When you mention a link, write it as a Markdown inline link — [visible text](url) \
— never a bare URL, so it renders as a clickable link rather than plain text.

Speed is part of this product: you are a quick-launch assistant and every tool \
call costs the user an extra round-trip. Default to answering directly, with NO \
tool call, whenever the answer is stable knowledge: translations, rewriting or \
drafting text, explanations and definitions, code and technical questions, \
how-tos, and general facts that do not change over time.

Call a tool only when the answer genuinely depends on it:
- Facts that change over time — news, current events, prices or rates, \
rankings, "latest"/"newest" versions, who currently holds a role, anything \
dated this year — must be searched, never answered from memory; your training \
data is stale and today is later than your cutoff. For these, search first and \
answer from the results.
- What the user copied ("this", "what I copied") → read_clipboard.
- Exact arithmetic → calculate.
- The current clock time → current_datetime (today's date is already stated above).
- The user's own past activity in this app — "what did I work on today", "what \
have I recorded", "what did I ask you yesterday", "summarize my week", "did I \
ever note anything about X" → search_history. It reads their own questions, \
notes, reminders and agent tasks, with timestamps. The current conversation is \
already in front of you, so only reach for it to see beyond this thread.

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
    case .ja:     fmt.locale = Foundation.Locale(identifier: "ja_JP")
    case .ko:     fmt.locale = Foundation.Locale(identifier: "ko_KR")
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
    // Vercel AI Gateway is the other aggregator — one key fronts hundreds of
    // models across OpenAI/Anthropic/Google/xAI/… with automatic provider
    // fallback. Sits right after OpenRouter, its keyless sibling in kind.
    case vercel
    // International majors first, then domestic providers by familiarity —
    // OpenRouter stays at the top as the keyless default for fresh installs.
    case openai
    // OpenAI's Codex CLI, driven as a keyless backend: it reuses the user's
    // `codex login` (ChatGPT sign-in) instead of an API key, so it sits right
    // after OpenAI as its subscription-billed sibling. Not an HTTP endpoint — it
    // shells out to the local `codex` binary (see `CodexCLIService`).
    case codex
    // Anthropic's Claude Code CLI, the same keyless pattern as Codex: Notch
    // spawns the user's own official `claude` binary (their own `claude` sign-in,
    // billed to their Claude plan). The compliance posture is deliberate — see
    // `ClaudeCLIService`: only the genuine binary is run, credentials are never
    // read, and Notch offers no in-app Claude sign-in.
    case claudeCode
    // xAI's Grok CLI, the same keyless pattern as Codex/Claude Code: Notch spawns
    // the user's own official `grok` binary (their `grok login` browser sign-in, or
    // `XAI_API_KEY`), billed to their xAI / SuperGrok plan. Not an HTTP endpoint —
    // it shells out to the local `grok` binary (see `GrokCLIService`).
    case grokCode
    case anthropic
    case gemini
    case deepseek
    case qwen
    case glm
    case kimi
    case minimax
    case mimo
    // The user's own OpenAI-compatible endpoint — a local server, a self-hosted
    // gateway, or a vendor we don't bundle. Last in the menu: it's the escape
    // hatch for everything the list above doesn't cover. Its whole spec is read
    // from Settings at call time (see `CustomProvider`), not hardcoded here.
    case custom

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
        case .vercel:
            return ProviderSpec(
                displayName: "Vercel AI Gateway",
                // OpenAI-compatible chat/completions; one key fronts every
                // provider. Models are `creator/model` slugs. The live
                // `/v1/models` fetch (no auth needed) fills the full catalog;
                // this shortlist is only the offline fallback.
                endpoint: "https://ai-gateway.vercel.sh/v1/chat/completions",
                models: ["anthropic/claude-sonnet-4.6", "openai/gpt-5.5",
                         "google/gemini-3.1-pro", "anthropic/claude-opus-4.8",
                         "openai/gpt-5-mini", "xai/grok-4.3"],
                signupHost: "vercel.com",
                signupURL: "https://vercel.com/d?to=%2F%5Bteam%5D%2F~%2Fai%2Fapi-keys",
                envVarName: "VERCEL_AI_GATEWAY_API_KEY")
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
        case .codex:
            // Not a real HTTP backend — `CodexCLIService` shells out to the local
            // `codex` binary. `endpoint` is a placeholder (never used for a request);
            // the single "codex" model id is a sentinel meaning "codex's own default
            // model" (see `CodexCLIService.init`). `signupURL` points at install docs
            // since there's no key to create — the user runs `codex login` instead.
            return ProviderSpec(
                displayName: "Codex (ChatGPT)",
                endpoint: "https://chatgpt.com/backend-api/codex",
                models: ["codex"],
                signupHost: "developers.openai.com",
                signupURL: "https://developers.openai.com/codex/cli",
                envVarName: "CODEX_CLI_UNUSED")
        case .claudeCode:
            // Not an HTTP backend — `ClaudeCLIService` shells out to the local
            // `claude` binary; `endpoint` is a never-used placeholder. The ids are
            // the CLI's documented `--model` shorthands. The old "claude" sentinel
            // ("the account's default model", no `--model` flag) is deliberately
            // NOT offered any more: a row reading "Default" names nothing you can
            // point at, and it was a twin of whichever alias it resolved to. The
            // `signupURL` points at the install docs — there's no key to create,
            // and sign-in happens in the user's own terminal (`claude`), never in
            // Notch.
            return ProviderSpec(
                displayName: "Claude Code",
                endpoint: "https://code.claude.com/unused",
                models: ["opus", "sonnet", "haiku"],
                signupHost: "code.claude.com",
                signupURL: "https://code.claude.com/docs/en/quickstart",
                envVarName: "CLAUDE_CODE_UNUSED")
        case .grokCode:
            // Not an HTTP backend — `GrokCLIService` shells out to the local `grok`
            // binary; `endpoint` is a never-used placeholder. "grok" is a sentinel
            // meaning "the account's default model" (no `-m` flag). The `signupURL`
            // points at the install docs — there's no key to create; sign-in is
            // `grok login` (browser OAuth) or the `XAI_API_KEY` env var.
            return ProviderSpec(
                displayName: "Grok CLI",
                endpoint: "https://cli-chat-proxy.grok.com/unused",
                models: ["grok"],
                signupHost: "docs.x.ai",
                signupURL: "https://docs.x.ai/docs/cli",
                envVarName: "GROK_CLI_UNUSED")
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
        case .custom:
            // Everything here is the user's, read fresh from `UserDefaults` on
            // every access so editing the endpoint in Settings takes effect on the
            // next request — no relaunch, no cached spec. `signupURL` points at the
            // endpoint itself (there's no key console to send anyone to); the
            // Settings footer replaces the "get a key at …" line for this provider,
            // so that link is only a fallback.
            return ProviderSpec(
                displayName: CustomProvider.displayName,
                endpoint: CustomProvider.endpointString,
                models: CustomProvider.bundledModels,
                signupHost: CustomProvider.chatEndpoint?.host ?? "",
                signupURL: CustomProvider.endpointString,
                envVarName: "CUSTOM_API_KEY")
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
    /// Backends that are driven by the user's own signed-in CLI rather than a key
    /// we hold: nothing to paste, and "configured" means the binary is installed
    /// and logged in (see each service's `isAvailable`).
    var isCLI: Bool {
        switch self {
        case .codex, .claudeCode, .grokCode: return true
        default: return false
        }
    }

    var defaultModel: String {
        // Codex's model isn't a curated shortlist — it's whatever the user's own
        // `codex` is configured to run (read from ~/.codex/config.toml), so the
        // picker and answer footer show the real model name, not a generic "codex".
        if self == .codex { return CodexCLIService.defaultModel }
        // Grok's model likewise isn't a curated shortlist — it's the account's own,
        // read from the CLI's model cache (see `GrokCLIService`).
        if self == .grokCode { return GrokCLIService.defaultModel }
        // The custom endpoint's model is the user's own typed id — a remote
        // manifest has no business overriding someone's private server.
        if self == .custom { return spec.defaultModel }
        // Claude Code's default is a concrete alias, never the retired "claude"
        // account-default sentinel — `availableModels` filters it out of the
        // remote manifest too, so take the head from there.
        if self == .claudeCode { return availableModels.first ?? spec.defaultModel }
        return RemoteModelManifest.models(for: self)?.first ?? spec.defaultModel
    }
    var availableModels: [String] {
        // Codex's list is the account's real models from the app-server `model/list`
        // (see `CodexCLIService`), falling back to the single configured model until
        // that fetch lands — never a curated/remote shortlist.
        if self == .codex { return CodexCLIService.availableModelIDs }
        // Grok's list is the account's real models from `~/.grok/models_cache.json`
        // (see `GrokCLIService`), falling back to the single "grok" sentinel.
        if self == .grokCode { return GrokCLIService.availableModelIDs }
        if self == .custom { return spec.availableModels }
        // Claude Code no longer offers the "claude" account-default sentinel (see
        // the spec above); a remote manifest written before that still lists it,
        // so drop it here rather than let a "Default" row back into the picker.
        if self == .claudeCode {
            let list = RemoteModelManifest.models(for: self) ?? spec.availableModels
            let named = list.filter { $0 != "claude" }
            return named.isEmpty ? spec.availableModels : named
        }
        return RemoteModelManifest.models(for: self) ?? spec.availableModels
    }
    var signupHost: String      { spec.signupHost }
    var signupURL: URL          { spec.signupURL }
    var envVarName: String      { spec.envVarName }

    /// The brand behind this provider's **own** models — the vendor label
    /// `VendorLogos` looks a mark up by when an id doesn't name its vendor itself.
    ///
    /// First-party catalogs are full of ids that carry no vendor at all (OpenAI's
    /// `dall-e-3` / `chatgpt-4o-latest`, GLM's `cogview-4`, Qwen's `qwq-32b`) or that
    /// name something that isn't one (Gemini's OpenAI-compat `/models` prefixes every
    /// id: `models/gemini-3.1-pro`). Those models still belong to the vendor whose
    /// endpoint served them, so the picker draws that vendor's mark instead of falling
    /// back to a monogram tile.
    ///
    /// `nil` for the two gateways: their ids are `vendor/slug`, so they already answer
    /// the question themselves, and a fallback would stamp the wrong logo on the
    /// hundreds of third-party models they front.
    var vendorName: String? {
        switch self {
        // The gateways front other people's models, and a custom endpoint could be
        // serving anything at all — in both cases the id has to speak for itself.
        case .openrouter, .vercel, .custom: return nil
        case .openai, .codex:         return "OpenAI"
        case .anthropic, .claudeCode: return "Anthropic"
        case .grokCode:               return "xAI"
        case .gemini:                 return "Google"
        case .deepseek:               return "DeepSeek"
        case .qwen:                   return "Qwen"
        case .glm:                    return "Zhipu"
        case .kimi:                   return "Moonshot"
        case .minimax:                return "MiniMax"
        case .mimo:                   return "MiMo"
        }
    }

    // MARK: Behavioral traits (grouped by client behavior, not by vendor)

    /// Whether this provider speaks the OpenAI-compatible `/v1/chat/completions`
    /// contract (true for everyone) or a vendor-native protocol (Anthropic's
    /// `/v1/messages`). `AppDelegate` uses this to pick the client implementation.
    var isOpenAICompatible: Bool {
        switch self {
        // Anthropic speaks its native protocol; Codex and Claude Code aren't HTTP
        // at all (subprocesses). All are routed to their own client, never the
        // shared one.
        case .anthropic, .codex, .claudeCode, .grokCode: return false
        default:                                         return true
        }
    }

    /// Vendor-specific extras sent with every chat request. OpenRouter's two
    /// optional attribution headers identify the app (its docs ask nicely);
    /// everyone else needs nothing beyond auth.
    var extraHeaders: [String: String] {
        switch self {
        case .openrouter:
            return ["HTTP-Referer": "https://github.com/\(UpdaterService.repo)",
                    "X-Title": "Notchi"]
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
    var supportsTools: Bool {
        // Codex and Claude Code run their OWN agent loops inside the CLI (search,
        // reasoning, file access), so Notch's tool harness must stay out of their
        // way — the turn dispatcher takes the plain `stream` path for them. Every
        // other provider exposes a function-calling API the harness can drive.
        switch self {
        case .codex, .claudeCode, .grokCode: return false
        default:                             return true
        }
    }

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
        // Codex, Claude Code and Grok search the web themselves as part of their
        // agent loops, so they earn the "Web search" chip even though Notch injects
        // nothing (`serverSearch == nil`).
        serverSearch != nil || self == .glm || self == .codex || self == .claudeCode
            || self == .grokCode
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
                        req.setBearer(apiKey)
                        for (field, value) in provider.extraHeaders {
                            req.setValue(value, forHTTPHeaderField: field)
                        }

                        let body = RequestBody(
                            model: model,
                            messages: chat,
                            stream: true,
                            fallbackModels: provider == .openrouter
                                ? OpenRouterFreeModels.serverFallbacks(primary: model) : nil
                        )
                        req.httpBody = try JSONEncoder().encode(body)

                        let (bytes, response) = try await ProxyConfig.urlSession.bytes(for: req)
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
    // No output cap is sent. It used to be, under whichever key the vendor wanted
    // (`max_completion_tokens` for MiMo, `max_tokens` for everyone else), which is
    // why the encoder below is key-driven — that machinery now carries only the
    // fields we still send. See `ReplyTokens` for why the cap went away, and
    // `SamplingKnobs` for why `temperature` went with it.
    private struct RequestBody: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        /// OpenRouter's server-side failover chain (`models`), primary first —
        /// see `OpenRouterFreeModels.serverFallbacks`. `nil` for every other
        /// provider (and for OpenRouter paid models), keeping the wire body
        /// byte-identical to before.
        var fallbackModels: [String]? = nil

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
            try c.encode(stream, forKey: DynamicKey("stream"))
            if let fallbackModels {
                try c.encode(fallbackModels, forKey: DynamicKey("models"))
            }
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
                            maxTokens: ReplyTokens.anthropicRequiredCeiling,
                            stream: true
                        )
                        req.httpBody = try JSONEncoder().encode(body)

                        let (bytes, response) = try await ProxyConfig.urlSession.bytes(for: req)
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
        guard let (data, response) = try? await ProxyConfig.urlSession.data(for: req),
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

// MARK: - Catalog hygiene (modality + snapshot collapse)

/// Which `/v1/models` entries are **not** reachable through `chat/completions`,
/// decided from the id alone. This is the fallback tier of `Entry.isChatModel` —
/// the one that carries every vendor shipping no modality field at all, which is
/// all of them except Vercel and OpenRouter.
///
/// Deliberately a table of **modality words**, never of model names. "embedding"
/// and "whisper" still mean the same thing years from now, while `gpt-5.5` is
/// stale within a quarter — so model names stay in the places that update
/// themselves (the remote manifest and the live catalog) and only this
/// vocabulary is compiled in.
///
/// Erring toward keeping: a wrongly-dropped chat model is invisible, while a
/// wrongly-kept image model is one dead row. So "vision" and "instruct" are
/// *absent* on purpose — `qwen-vl`, `llama-3-instruct` and friends are genuine
/// chat models.
enum ModalityFilter {
    private static let nonChatMarkers = [
        // Retrieval
        "embed", "rerank",
        // Speech in / out
        "tts", "whisper", "transcribe", "audio", "speech", "voice", "realtime",
        // Image generation
        "dall-e", "image", "cogview", "wanx",
        // Video / music generation
        "video", "sora", "music",
        // Classification
        "moderation",
        // Legacy completion-only engines that still sit in OpenAI's catalog
        "babbage", "davinci",
    ]

    static func isNonChat(_ id: String) -> Bool {
        let lower = id.lowercased()
        return nonChatMarkers.contains { lower.contains($0) }
    }
}

/// Collapses a vendor's dated snapshots down to one row per model.
///
/// Vendors publish the same model several times over — a rolling alias plus every
/// pinned build behind it (`gpt-4o`, `gpt-4o-2024-11-20`, `gpt-4o-2024-08-06`;
/// `claude-sonnet-4-5`, `claude-sonnet-4-5-20250929`). All of them answer, so none
/// can be filtered by capability, yet a picker showing four rows for one model is
/// just noise.
///
/// Purely structural — no model names anywhere, so it needs no upkeep as lineups
/// turn over. `-preview` / `-exp` are deliberately **not** collapsed: `o1-preview`
/// and `o1` are different models, and merging them would hide one.
enum ModelSnapshots {
    /// `id` with its dated / revision / `-latest` suffix removed — the rolling
    /// alias form. Returns `id` unchanged when it carries no such suffix.
    static func base(of id: String) -> String {
        var parts = id.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return id }
        func digits(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy(\.isNumber) }

        if parts.last?.lowercased() == "latest" {
            // `chatgpt-4o-latest` → `chatgpt-4o`
            parts.removeLast()
        } else if parts.count > 3, digits(parts[parts.count - 1]), parts[parts.count - 1].count == 2,
                  digits(parts[parts.count - 2]), parts[parts.count - 2].count == 2,
                  digits(parts[parts.count - 3]), parts[parts.count - 3].count == 4 {
            // `gpt-4o-2024-08-06` → `gpt-4o`
            parts.removeLast(3)
        } else if let last = parts.last, digits(last), [3, 4, 8].contains(last.count) {
            // `claude-3-5-sonnet-20240620`, `gpt-4-0613`, `gemini-1.5-pro-002`
            parts.removeLast()
        }
        return parts.joined(separator: "-")
    }

    /// One entry per model, in the catalog's own order (first sighting wins the
    /// slot, so the list doesn't reshuffle around the collapse).
    static func collapse(_ entries: [ModelCatalog.ModelList.Entry]) -> [ModelCatalog.ModelList.Entry] {
        var pick: [String: ModelCatalog.ModelList.Entry] = [:]
        var order: [String] = []
        for entry in entries {
            let key = base(of: entry.id)
            guard let held = pick[key] else {
                pick[key] = entry
                order.append(key)
                continue
            }
            pick[key] = preferred(held, entry, base: key)
        }
        return order.compactMap { pick[$0] }
    }

    /// Which of two siblings represents the model. The rolling alias always wins —
    /// it's the id that keeps pointing at the vendor's current build, so it can
    /// never go stale. Failing that, the newest one; failing timestamps, the id
    /// that sorts last (date suffixes sort chronologically).
    private static func preferred(_ a: ModelCatalog.ModelList.Entry,
                                  _ b: ModelCatalog.ModelList.Entry,
                                  base: String) -> ModelCatalog.ModelList.Entry {
        if a.id == base { return a }
        if b.id == base { return b }
        switch (a.createdDate, b.createdDate) {
        case let (x?, y?): return x >= y ? a : b
        case (_?, nil):    return a
        case (nil, _?):    return b
        case (nil, nil):   return a.id >= b.id ? a : b
        }
    }
}

extension ISO8601DateFormatter {
    /// Anthropic's `created_at` ("2025-02-19T00:00:00Z"), and the same with
    /// fractional seconds — formatters are expensive to build, so both are made
    /// once and shared.
    static let modelCatalog = ISO8601DateFormatter()
    static let modelCatalogFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
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
    /// A fetched model list plus, for OpenRouter, which of its free models are
    /// flagship-class (see `OpenRouterFreeModels`) — the Settings menu uses the
    /// membership to draw its grouped sections. Empty for other providers.
    struct Result {
        let models: [String]
        let openRouterFeatured: Set<String>
        /// Rich metadata for each id in `models` (same order), for the custom
        /// picker's detail panel. Empty for providers whose `/v1/models` gave no
        /// per-model fields — the picker then builds `ModelInfo` from the bare id.
        let infos: [ModelInfo]

        init(models: [String], openRouterFeatured: Set<String>, infos: [ModelInfo] = []) {
            self.models = models
            self.openRouterFeatured = openRouterFeatured
            self.infos = infos
        }
    }

    /// In-memory cache of the last successful live fetch per provider, so the
    /// network hit (plus, for OpenRouter, the extra `UsageRankings` call) isn't
    /// repeated every time Settings reopens. `InlineSettingsView` is "closed ==
    /// destroyed" (`NotchBody.swift`'s `if model.showSettings { InlineSettingsView(…) }`),
    /// which wipes its own `@State private var liveByProvider` — this cache lives
    /// on the type instead, so it survives that teardown across the app's whole
    /// process lifetime (until `ttl` lapses or the key changes).
    ///
    /// Keyed by provider, but an entry also carries the `apiKey` it was fetched
    /// with: a stale entry from a different key for the same provider is treated
    /// as a miss, so pasting a new key always shows that key's own catalog.
    /// Guarded by `cacheLock` for the same reason as `RemoteModelManifest.cached`
    /// — `loadAllProviderModels` fires one concurrent fetch per provider via a
    /// `TaskGroup`, and NSLock can't be touched directly from async code.
    private struct CacheEntry {
        let apiKey: String
        let result: Result
        let fetchedAt: Date
    }
    private static let cacheLock = NSLock()
    private static var cache: [Provider: CacheEntry] = [:]
    /// Shorter than `RemoteModelManifest`'s 6h: a vendor's live `/v1/models` is
    /// cheap to re-hit and more likely to have actually changed (new model
    /// shipped) within a single sitting than the curated manifest is.
    private static let ttl: TimeInterval = 60 * 60

    private static func withCacheLock<T>(_ body: () -> T) -> T {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return body()
    }

    /// Fetch the provider's current model ids. Returns `nil` on any error so the
    /// caller can fall back to the bundled `availableModels` list.
    ///
    /// Serves the cached result when one exists for this exact `(provider,
    /// apiKey)` pair and is younger than `ttl` — set `force: true` to bypass it
    /// (for a manual refresh/retry action, should one ever be wired up; nothing
    /// in the Settings UI does today). A failed fetch is never cached, so the
    /// next call — cache or no — always gets a real retry.
    static func fetch(for provider: Provider, apiKey: String, force: Bool = false) async -> Result? {
        // Codex / Grok have no `/v1/models` endpoint (they're local subprocesses, not
        // HTTP), so there's nothing to fetch — their model lists come from the CLIs.
        if provider == .codex || provider == .grokCode { return nil }
        if !force, let hit = withCacheLock({ cache[provider] }),
           hit.apiKey == apiKey, Date().timeIntervalSince(hit.fetchedAt) < ttl {
            return hit.result
        }
        guard let result = await fetchLive(for: provider, apiKey: apiKey) else { return nil }
        withCacheLock { cache[provider] = CacheEntry(apiKey: apiKey, result: result, fetchedAt: Date()) }
        return result
    }

    /// Drop the cached catalog for `provider`. The cache keys on (provider, key),
    /// which is enough while a provider's endpoint is fixed — but the custom
    /// endpoint's URL is itself editable, so pointing it at a different server
    /// with the same (often empty) key would otherwise serve the old server's
    /// model list. Settings calls this when those fields change.
    static func invalidate(_ provider: Provider) {
        withCacheLock { cache[provider] = nil }
    }

    /// The actual network round-trip behind `fetch` — split out so `fetch` can
    /// wrap it with the cache check/write above without indenting this whole body.
    private static func fetchLive(for provider: Provider, apiKey: String) async -> Result? {
        guard let url = modelsURL(for: provider) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if provider.isOpenAICompatible {
            req.setBearer(apiKey)
        } else {
            // Anthropic: same key header + pinned version as the messages API.
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        req.timeoutInterval = 10

        do {
            let (data, response) = try await ProxyConfig.urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            let list = try JSONDecoder().decode(ModelList.self, from: data)
            // Clean the catalog before anything else looks at it — the picker, the
            // featured split and the shortlist all inherit from this one place.
            // Two passes: drop what chat can't call (`Entry.isChatModel`), then
            // collapse each model's dated snapshots into one row (`ModelSnapshots`).
            let entries = ModelSnapshots.collapse(
                list.data.filter { !$0.id.isEmpty && $0.isChatModel })
            // id → rich metadata, so the reordered/​filtered id lists below can
            // carry their `ModelInfo` along without re-decoding.
            let byID = Dictionary(entries.map { ($0.id, ModelInfo(entry: $0, provider: provider)) },
                                  uniquingKeysWith: { a, _ in a })
            func infos(for ids: [String]) -> [ModelInfo] {
                ids.map { byID[$0]
                    ?? ModelInfo(id: $0, vendor: ModelRatings.vendor(for: $0, provider: provider)) }
            }
            // OpenRouter's catalog is its FULL marketplace — hundreds of ids, most
            // of them paid, which a freshly-connected $0 account can't call. Offer
            // only what actually works free: the auto-router, then the flagship-
            // class free models (biggest first), then the rest alphabetically.
            if provider == .openrouter {
                // Real usage ranks the free lineup; fetched with the same key,
                // in parallel with nothing (models is already in hand). A nil
                // result (offline / niche key / endpoint down) degrades to
                // size-only ordering — the empty map does exactly that.
                let usage = await UsageRankings.fetch(apiKey: apiKey) ?? [:]
                let (featured, rest) = OpenRouterFreeModels.split(
                    entries.filter { $0.id.hasSuffix(":free") }
                        .map { (id: $0.id, description: $0.description) },
                    usage: usage)
                let ids = ["openrouter/free"] + featured + rest
                return Result(models: ids, openRouterFeatured: Set(featured),
                              infos: infos(for: ids))
            }
            let ids = entries.map(\.id)
            return ids.isEmpty ? nil : Result(models: ids, openRouterFeatured: [],
                                              infos: infos(for: ids))
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
    /// both. `description` (OpenRouter-only) feeds the free-model size ranking.
    /// OpenRouter's `/v1/models` also carries the rich per-model metadata the
    /// custom picker's detail panel shows — human name, context window, input
    /// modalities (→ Vision), supported parameters (→ Tool Use / Reasoning), and
    /// pricing (→ tier badge). Every field is optional so a leaner vendor payload
    /// (or Anthropic's own `/v1/models`) still decodes; the picker simply shows
    /// less for those.
    struct ModelList: Decodable {
        let data: [Entry]
        struct Entry: Decodable {
            let id: String
            let name: String?
            let description: String?
            let contextLength: Int?
            let architecture: Architecture?
            let supportedParameters: [String]?
            let pricing: Pricing?
            let reasoning: Reasoning?
            /// The model's modality class, as Vercel AI Gateway reports it:
            /// `language` (chat), or one of `image` / `video` / `embedding` /
            /// `reranking` / `transcription` / `speech` / `realtime`. Absent for
            /// every other vendor's `/v1/models`, which lists chat models only.
            /// See `isChatModel`.
            let type: String?
            /// Release timestamp — the one *auto-updating* "how new is this model"
            /// signal vendors actually serve, and what lets the picker surface a
            /// brand-new flagship before anyone edits the curated manifest.
            /// OpenAI / OpenRouter give a unix `created`; Anthropic an ISO-8601
            /// `created_at`. Vendors that publish neither (Kimi, MiniMax, MiMo)
            /// leave both nil and fall back to catalog order — an honest degrade,
            /// and their catalogs are small enough that ordering barely matters.
            let created: Double?
            let createdAt: String?

            /// The two timestamp spellings resolved to one date, `nil` when the
            /// vendor ships neither.
            var createdDate: Date? {
                if let created, created > 0 { return Date(timeIntervalSince1970: created) }
                guard let createdAt, !createdAt.isEmpty else { return nil }
                return ISO8601DateFormatter.modelCatalog.date(from: createdAt)
                    ?? ISO8601DateFormatter.modelCatalogFractional.date(from: createdAt)
            }

            /// Whether this entry can actually be called through `chat/completions`,
            /// decided from the strongest signal the payload carries.
            ///
            /// A vendor's `/v1/models` is its **whole** catalog, not its chat
            /// catalog: embeddings, TTS, transcription, image generation, moderation
            /// and realtime models all ride along, and none of them can serve a chat
            /// request on any plan. They have no business in a model picker.
            ///
            /// Three tiers, best evidence first:
            ///  1. `type` — Vercel classifies every entry, so it's the last word.
            ///  2. `output_modalities` — OpenRouter declares what a model emits; one
            ///     that emits images or audio isn't a chat model.
            ///  3. the id itself — every first-party vendor (OpenAI, Gemini, Qwen,
            ///     GLM, …) ships *no* classification at all, so the modality has to
            ///     be read off the name (`ModalityFilter`). The old code treated a
            ///     missing `type` as "keep", which is why OpenAI's picker arrived
            ///     carrying its entire non-chat catalog.
            var isChatModel: Bool {
                if let type { return type == "language" }
                if let out = architecture?.outputModalities, !out.isEmpty {
                    return out.contains("text")
                }
                return !ModalityFilter.isNonChat(id)
            }

            struct Architecture: Decodable {
                let inputModalities: [String]?
                let outputModalities: [String]?
                enum CodingKeys: String, CodingKey {
                    case inputModalities = "input_modalities"
                    case outputModalities = "output_modalities"
                }
            }
            struct Pricing: Decodable {
                let prompt: String?
                let completion: String?
            }
            struct Reasoning: Decodable {
                let mandatory: Bool?
            }

            enum CodingKeys: String, CodingKey {
                case id, name, description, architecture, pricing, reasoning, type, created
                case contextLength = "context_length"
                case supportedParameters = "supported_parameters"
                case createdAt = "created_at"
            }
        }
    }
}

// MARK: - Model metadata (custom picker detail panel)

/// The per-model facts the custom picker's detail panel renders: a human name,
/// context window, capability flags, a tier badge, and the two 0–5 meters (Speed
/// / Intelligence). Built from a `ModelCatalog.ModelList.Entry` when the vendor
/// ships the rich payload (OpenRouter), or from the bare id alone (every other
/// provider) — in which case the metadata is inferred from the id and the meters
/// come from `ModelRatings`.
struct ModelInfo: Identifiable, Equatable, Sendable {
    /// The wire id passed to the API — the picker's selection value and dictionary key.
    let id: String
    /// Human-readable name for the row/header; the id when no `name` was given.
    let name: String
    /// The vendor label shown on the trailing edge of each row ("OpenAI", "Anthropic").
    let vendor: String
    /// Context window in tokens, or `nil` when unknown (hidden in the panel).
    let contextTokens: Int?
    let vision: Bool
    let toolUse: Bool
    let reasoning: Bool
    /// A short tier tag ("Adv. AI" / "Pro") or `nil` for the plain rows.
    let tier: Tier?
    /// When the vendor published this model, when it says. Not shown anywhere —
    /// it's the ranking signal that keeps the picker's shortlist current without
    /// a manifest edit (see `ModelCatalogStore.shortlistIDs`). `nil` for vendors
    /// that ship no timestamp, and for rows built from a bare id.
    let created: Date?
    /// 0–5 filled bars each, curated where known and heuristic otherwise.
    let speed: Int
    let intelligence: Int

    /// The two badge tiers the reference draws — the blue "Adv. AI" (advanced,
    /// flagship-class) and "Pro" (paid/premium tier). Plain rows carry no badge.
    enum Tier: Sendable { case advanced, pro
        var label: String { self == .advanced ? "Adv. AI" : "Pro" }
    }

    /// Human context, e.g. "200k". `nil` context → `nil`.
    var contextLabel: String? {
        guard let t = contextTokens, t > 0 else { return nil }
        if t >= 1_000_000 { return String(format: "%.1fM", Double(t) / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
        if t >= 1_000 { return "\(t / 1_000)k" }
        return "\(t)"
    }

    /// Build from a rich OpenRouter entry: capabilities and context come straight
    /// off the payload; the meters and tier are curated/heuristic via `ModelRatings`.
    /// `provider` is who served the entry — it names the vendor for the ids that don't
    /// name their own (see `ModelRatings.vendor(for:provider:)`).
    init(entry: ModelCatalog.ModelList.Entry, provider: Provider) {
        let params = entry.supportedParameters ?? []
        let modalities = entry.architecture?.inputModalities ?? []
        self.id = entry.id
        self.name = entry.name?.isEmpty == false ? entry.name! : ModelRatings.prettyName(for: entry.id)
        self.vendor = ModelRatings.vendor(for: entry.id, provider: provider)
        self.contextTokens = entry.contextLength
        self.vision = modalities.contains("image")
        self.toolUse = params.contains("tools") || params.contains("tool_choice")
        self.reasoning = entry.reasoning != nil || params.contains("reasoning") || params.contains("include_reasoning")
        let rating = ModelRatings.rating(id: entry.id, reasoning: self.reasoning,
                                         promptPrice: Double(entry.pricing?.prompt ?? ""))
        self.speed = rating.speed
        self.intelligence = rating.intelligence
        self.tier = rating.tier
        self.created = entry.createdDate
    }

    /// Build from a bare id (providers whose `/v1/models` gives no metadata, or the
    /// bundled shortlist). Capabilities are inferred from the id; the meters come
    /// wholly from `ModelRatings`.
    init(id: String, vendor: String) {
        let rating = ModelRatings.rating(id: id, reasoning: ModelRatings.looksReasoning(id),
                                         promptPrice: nil)
        self.id = id
        self.name = ModelRatings.prettyName(for: id)
        self.vendor = vendor
        self.contextTokens = nil
        self.vision = ModelRatings.looksVision(id)
        self.toolUse = true   // every provider we ship speaks tools; assume yes when unstated
        self.reasoning = ModelRatings.looksReasoning(id)
        self.speed = rating.speed
        self.intelligence = rating.intelligence
        self.tier = rating.tier
        self.created = nil
    }
}

/// The Speed / Intelligence meters and tier badge — the two things OpenRouter's
/// API does *not* carry. A hand-maintained table pins the well-known families
/// (kept short and honest); anything it misses falls back to a heuristic read of
/// the id (flagship vs. mini/nano/flash), whether it reasons, and its price. So a
/// brand-new model still gets a plausible read the day it ships, and the ones
/// users actually reach for get an accurate one.
enum ModelRatings {
    /// (speed, intelligence) on the reference's 0–5 scale, plus the tier badge.
    struct Rating { let speed: Int; let intelligence: Int; let tier: ModelInfo.Tier? }

    /// Fold a vendor's spelling variants onto one canonical id, so a single needle
    /// covers every route to the same model. Two folds, both load-bearing:
    ///
    ///  · **Claude versions.** Anthropic's own API dashes them (`claude-opus-4-8`,
    ///    plus a date tail); both gateways dot them (`anthropic/claude-opus-4.8`).
    ///    Dashes between two digits become dots — scoped to Claude ids, because for
    ///    everyone else a digit-dash-digit is a size or a date (`llama-3-8b`).
    ///  · **Qwen.** OpenRouter says `qwen3-14b`, Vercel says `qwen-3-14b`.
    ///
    /// It also guarantees a leading `/`, so a needle can anchor to the start of the
    /// model slug. OpenAI's o-series is why: the bare needle `o1` is a substring of
    /// `sao10k/l3-lunaris-8b`, and `/o1` is not.
    private static func canonical(_ id: String) -> String {
        var lower = id.lowercased()
        lower = lower.replacingOccurrences(of: "qwen-2.5", with: "qwen2.5")
        lower = lower.replacingOccurrences(of: "qwen-3", with: "qwen3")
        if !lower.contains("/") { lower = "/" + lower }
        guard lower.contains("claude") else { return lower }
        let ch = Array(lower)
        return String(ch.indices.map { i -> Character in
            (ch[i] == "-" && i > 0 && i + 1 < ch.count
             && ch[i - 1].isNumber && ch[i + 1].isNumber) ? "." : ch[i]
        })
    }

    /// Curated ratings, keyed by a substring of the canonical id. **First match wins**,
    /// so every block runs most-specific → most-generic: a family's variants before the
    /// family, the family before the vendor catch-all, vendor entries before the generic
    /// size markers at the bottom. (`gpt-5.1-codex-mini` must precede `gpt-5.1-codex`,
    /// which must precede `gpt-5.1`, which must precede `gpt-5` — every one of those is
    /// a substring of the one before it.)
    ///
    /// The scale, so the numbers mean the same thing in every block:
    ///  · intelligence 5 = the vendor's current flagship · 4 = strong mainline or a
    ///    superseded flagship · 3 = the fast mid tier · 2 = mini/nano · 1 = legacy.
    ///  · speed 1 = deliberately slow (`-pro`, deep-research) · 2 = big flagship ·
    ///    3 = mainline · 4 = light · 5 = mini/flash.
    ///
    /// Latency/deliberation suffixes (`-fast`, `-thinking`, …) are **not** listed here —
    /// they ride on the family's row via `variantAdjust`.
    ///
    /// Written against the catalogs as they stand today. It does not try to predict a
    /// model that doesn't exist yet: an unlisted id falls to `heuristic`, which is now
    /// only expected to be *plausible*, not right.
    private static let table: [(needle: String, speed: Int, intelligence: Int, tier: ModelInfo.Tier?)] = [
        // ── OpenAI ────────────────────────────────────────────────────────────────
        // `-pro` is the slow deliberating variant, not merely a pricier one.
        ("gpt-5.5-pro",        1, 5, .advanced),
        ("gpt-5.5",            2, 5, .advanced),
        ("gpt-5.4-pro",        1, 5, .advanced),
        ("gpt-5.4-nano",       5, 2, nil),
        ("gpt-5.4-mini",       5, 3, nil),
        ("gpt-5.4",            2, 5, .advanced),
        ("gpt-5.3",            3, 5, .advanced),   // -chat / -codex
        ("gpt-5.2-pro",        1, 5, .advanced),
        ("gpt-5.2",            3, 4, .advanced),   // -chat / -codex
        ("gpt-5.1-codex-mini", 5, 3, nil),
        ("gpt-5.1-codex",      3, 4, nil),         // …-codex-max too
        ("gpt-5.1",            3, 4, .advanced),   // -chat / -instant / -thinking
        ("gpt-5-pro",          1, 5, .advanced),
        ("gpt-5-nano",         5, 2, nil),
        ("gpt-5-mini",         5, 3, nil),
        ("gpt-5-codex",        3, 4, nil),
        ("gpt-5",              3, 4, .advanced),   // …-chat
        ("gpt-4.1-nano",       5, 2, nil),
        ("gpt-4.1-mini",       4, 3, nil),
        ("gpt-4.1",            3, 4, nil),
        ("gpt-4o-mini",        5, 3, nil),
        ("gpt-4o",             4, 3, nil),
        ("gpt-4-turbo",        3, 3, nil),         // was 5/2: "turbo" read as a mini
        ("gpt-4",              2, 3, nil),         // the 2023 original; slow and dear
        ("gpt-3.5-turbo",      5, 1, nil),
        ("gpt-oss-120b",       4, 3, nil),
        ("gpt-oss",            5, 2, nil),         // …-20b, …-safeguard-20b
        // The o-series needles carry the slug-boundary `/` (see `canonical`): bare
        // `o1` is a substring of `sao10k/l3-lunaris-8b`, which is not an OpenAI model.
        ("/o4-mini",           3, 4, nil),         // …-high, …-deep-research
        ("/o3-deep-research",  1, 5, .advanced),
        ("/o3-mini",           4, 4, nil),         // …-high — NOT o3's 1/5
        ("/o3-pro",            1, 5, .advanced),
        ("/o3",                1, 5, .advanced),
        ("/o1-pro",            1, 5, .advanced),
        ("/o1",                1, 4, nil),
        // ── Anthropic ─────────────────────────────────────────────────────────────
        // Keyed by version, not by tier name. The old `opus`/`sonnet`/`haiku` needles
        // gave claude-3-haiku and claude-haiku-4.5 the same numbers, and dropped
        // claude-fable-5 (a flagship — 1M ctx, priced above opus-4.8) on the floor.
        ("claude-fable-5",     2, 5, .advanced),
        ("claude-opus-4.8",    2, 5, .advanced),   // …-fast via variantAdjust
        ("claude-opus-4.7",    2, 5, .advanced),
        ("claude-opus-4.6",    2, 5, .advanced),
        ("claude-opus-4.5",    2, 5, .advanced),
        ("claude-opus-4.1",    1, 4, .advanced),   // 2025 flagship, since superseded
        ("claude-opus-4",      1, 4, .advanced),
        ("claude-sonnet-5",    3, 5, .advanced),
        ("claude-sonnet-4.6",  3, 4, .advanced),
        ("claude-sonnet-4.5",  3, 4, .advanced),
        ("claude-sonnet-4",    3, 4, nil),
        ("claude-haiku-4.5",   5, 3, nil),
        ("claude-3.5-haiku",   5, 2, nil),
        ("claude-3-haiku",     5, 1, nil),
        ("opus",               2, 5, .advanced),   // catch-alls for ids we don't list
        ("sonnet",             3, 4, nil),
        ("haiku",              5, 3, nil),
        // ── Google ────────────────────────────────────────────────────────────────
        ("gemini-3.5-flash",      5, 4, nil),
        ("gemini-3.1-flash-lite", 5, 2, nil),
        ("gemini-3.1-flash",      5, 3, nil),
        ("gemini-3.1-pro",        2, 5, .advanced),
        ("gemini-3-flash",        5, 3, nil),
        ("gemini-3-pro",          2, 5, .advanced),
        ("gemini-omni-flash",     5, 3, nil),
        ("gemini-2.5-pro",        3, 4, nil),
        ("gemini-2.5-flash",      5, 3, nil),
        ("gemini-2.0-flash",      5, 2, nil),
        ("gemma",                 4, 2, nil),
        // ── xAI ───────────────────────────────────────────────────────────────────
        ("grok-4.5",           2, 5, .advanced),
        ("grok-4.3",           2, 5, .advanced),
        ("grok-4.20",          3, 5, .advanced),   // -reasoning / -non-reasoning / -multi-agent
        ("grok-4.1-fast",      5, 3, nil),
        ("grok-build",         3, 3, nil),
        ("grok-4",             2, 4, nil),
        ("grok",               3, 3, nil),
        // ── DeepSeek ──────────────────────────────────────────────────────────────
        ("deepseek-v4-flash",  5, 3, nil),
        ("deepseek-v4-pro",    2, 5, .advanced),
        ("deepseek-v4",        3, 5, .advanced),
        ("deepseek-r1",        1, 4, nil),
        ("deepseek-v3.2",      3, 4, nil),
        ("deepseek-v3.1",      3, 4, nil),
        ("deepseek-v3",        3, 4, nil),
        ("deepseek",           3, 3, nil),
        // ── Zhipu GLM ─────────────────────────────────────────────────────────────
        ("glm-5v-turbo",       5, 3, nil),
        ("glm-5-turbo",        5, 3, nil),
        ("glm-5.2",            3, 5, .advanced),   // …-fast via variantAdjust
        ("glm-5.1",            3, 5, .advanced),
        ("glm-5",              2, 5, .advanced),
        ("glm-4.7-flash",      5, 2, nil),         // …-flashx
        ("glm-4.7",            3, 4, nil),
        ("glm-4.6",            3, 4, nil),
        ("glm-4.5-air",        5, 2, nil),
        ("glm-4.5",            3, 4, nil),
        ("glm",                3, 3, nil),
        // ── Qwen (canonicalized: `qwen-3-…` → `qwen3-…`) ──────────────────────────
        ("qwen3.7-max",        2, 5, .advanced),
        ("qwen3.7-plus",       3, 4, nil),
        ("qwen3.6-max",        2, 5, .advanced),
        ("qwen3.6-plus",       3, 4, nil),
        ("qwen3.6-27b",        4, 3, nil),
        ("qwen3.5-flash",      5, 3, nil),
        ("qwen3.5-plus",       3, 4, nil),
        ("qwen3.5-397b",       2, 5, .advanced),
        ("qwen3.5-122b",       3, 4, nil),
        ("qwen3.5",            3, 4, nil),
        ("qwen3-max",          2, 5, .advanced),
        ("qwen3-coder",        3, 4, nil),
        ("qwen3-235b",         3, 4, nil),
        ("qwen3-vl",           3, 4, nil),
        ("qwen3-32b",          4, 3, nil),
        ("qwen3-30b",          4, 3, nil),
        ("qwen3-14b",          5, 2, nil),
        ("qwen3-8b",           5, 2, nil),
        ("qwen-flash",         5, 2, nil),
        ("qwen-plus",          4, 3, nil),
        ("qwen2.5",            3, 3, nil),
        ("qwen",               3, 3, nil),         // was 3/4 for all 60 qwen ids
        // ── Moonshot Kimi ─────────────────────────────────────────────────────────
        ("kimi-k2.7-code",     3, 5, .advanced),   // …-highspeed via variantAdjust
        ("kimi-k2.7",          3, 5, .advanced),
        ("kimi-k2.6",          2, 5, .advanced),
        ("kimi-k2.5",          3, 4, nil),
        ("kimi-k2",            3, 4, nil),         // …-thinking via variantAdjust
        ("kimi",               3, 4, nil),
        ("moonshot-v1",        4, 2, nil),
        // ── MiniMax ───────────────────────────────────────────────────────────────
        ("minimax-m3",         2, 5, .advanced),
        ("minimax-m2.7",       3, 4, nil),
        ("minimax-m2.5",       3, 4, nil),
        ("minimax-m2.1",       3, 4, nil),         // …-lightning via variantAdjust
        ("minimax-m2",         3, 4, nil),
        ("minimax-m1",         2, 3, nil),
        ("minimax-01",         3, 2, nil),
        ("minimax",            3, 3, nil),
        // ── Xiaomi MiMo ───────────────────────────────────────────────────────────
        ("mimo-v2.5-pro",      2, 4, nil),
        ("mimo-v2.5",          3, 3, nil),
        ("mimo-v2-pro",        2, 4, nil),
        ("mimo-v2-flash",      5, 2, nil),
        ("mimo",               4, 3, nil),
        // ── Meta ──────────────────────────────────────────────────────────────────
        ("llama-4",            4, 4, nil),
        ("llama-3.3-70b",      3, 3, nil),
        ("llama-3.1-405b",     2, 4, nil),
        ("llama-3.1-70b",      3, 3, nil),
        ("llama-3.1-8b",       5, 2, nil),
        ("llama-3-8b",         5, 1, nil),
        ("llama",              4, 3, nil),
        // ── OpenRouter's free auto-router ─────────────────────────────────────────
        // Routes to whatever solid free model is up right now — quick, mid, honest.
        ("openrouter/free",    4, 3, nil),
        // ── Generic size markers — last resort before the heuristic ───────────────
        ("flash-lite",         5, 2, nil),
        ("flash",              5, 3, nil),
    ]

    static func rating(id: String, reasoning: Bool, promptPrice: Double?) -> Rating {
        let lower = canonical(id)
        if let hit = table.first(where: { lower.contains($0.needle) }) {
            return variantAdjust(Rating(speed: hit.speed, intelligence: hit.intelligence,
                                        tier: hit.tier), lower)
        }
        return heuristic(lower: lower, reasoning: reasoning, promptPrice: promptPrice)
    }

    /// Vendors ship one family tuned two ways: for latency (`-fast`, `-instant`,
    /// `-highspeed`, `-lightning`) or for deliberation (`-thinking`, `-reasoning`).
    /// The table keys the *family*; this nudges the family's numbers onto the variant,
    /// so `claude-opus-4.8-fast` no longer reads exactly as slow as `claude-opus-4.8`
    /// and `kimi-k2-thinking` no longer reads exactly as quick as `kimi-k2`.
    ///
    /// Only table hits pass through here — `heuristic` already folds `reasoning` in
    /// from the vendor's metadata, and running both would count it twice.
    ///
    /// `-non-reasoning` is the *negation* of the suffix, not an instance of it: xAI
    /// ships `grok-4.20-reasoning` and `grok-4.20-non-reasoning` side by side, and a
    /// bare `contains("-reasoning")` reads them identically.
    private static func variantAdjust(_ r: Rating, _ lower: String) -> Rating {
        var speed = r.speed, intelligence = r.intelligence
        if ["-fast", "-instant", "-highspeed", "-lightning"].contains(where: lower.contains) {
            speed += 1
        }
        if !lower.contains("non-reasoning"),
           ["-thinking", "-reasoning"].contains(where: lower.contains) {
            speed -= 1; intelligence += 1
        }
        return Rating(speed: min(5, max(1, speed)),
                      intelligence: min(5, max(1, intelligence)), tier: r.tier)
    }

    /// The fallback read for an id the table doesn't name. Size class sets the
    /// baseline (small = fast+dim, flagship = slow+bright); a reasoning model gains
    /// intelligence and loses speed; a non-trivial prompt price marks it "Pro".
    ///
    /// Matching is on **dash-delimited tokens, never raw substrings**. That is the
    /// whole point: `contains("1b")` fires inside `671b`, so a 671-billion-parameter
    /// flagship used to come out 5/2 — read as a nano, the exact inverse of the signal.
    /// `contains("pro")` likewise fired inside `inflection-3-productivity`.
    private static func heuristic(lower: String, reasoning: Bool, promptPrice: Double?) -> Rating {
        var speed = 3, intelligence = 3
        let tokens = Set(lower.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let small: Set<String> = ["nano", "mini", "flash", "lite", "small", "turbo",
                                  "highspeed", "air", "1b", "2b", "3b", "4b", "7b", "8b", "9b"]
        let big: Set<String> = ["opus", "large", "pro", "ultra", "max",
                                "70b", "72b", "120b", "235b", "405b", "480b", "671b"]
        if !tokens.isDisjoint(with: small) { speed += 2; intelligence -= 1 }
        if !tokens.isDisjoint(with: big)   { speed -= 1; intelligence += 1 }
        if reasoning { intelligence += 1; speed -= 1 }
        speed = min(5, max(1, speed)); intelligence = min(5, max(1, intelligence))
        var tier: ModelInfo.Tier? = nil
        if intelligence >= 5 { tier = .advanced }
        else if let p = promptPrice, p > 0.000002 { tier = .pro }
        return Rating(speed: speed, intelligence: intelligence, tier: tier)
    }

    // MARK: id-shape inference (used when the vendor gives no metadata)

    static func looksVision(_ id: String) -> Bool {
        let l = id.lowercased()
        return ["gpt-4o", "gpt-4.1", "gpt-5", "claude", "gemini", "vision", "-vl", "llava", "pixtral"]
            .contains(where: l.contains)
    }

    /// Two traps here, both the same shape as the ones in `table`:
    ///  · the o-series needs the slug-boundary `/` (bare `o1` lives inside `sao10k/…`,
    ///    which would then claim a reasoning badge and a 1/5 heuristic read);
    ///  · `-non-reasoning` contains `reasoning`, and xAI ships both variants.
    static func looksReasoning(_ id: String) -> Bool {
        let l = canonical(id)
        if l.contains("non-reasoning") { return false }
        return ["/o1", "/o3", "/o4", "-r1", "reasoning", "thinking", "-r-", "deepseek-r"]
            .contains(where: l.contains)
    }

    /// The vendor label — the key `VendorLogos` looks marks up by. Gateway ids are
    /// `vendor/slug`; bare ids are matched by family prefix. Every family we actually
    /// ship resolves to a real vendor, so the picker never renders a blank tile for a
    /// bundled model.
    ///
    /// The two gateways name the same vendor differently (`x-ai` on OpenRouter,
    /// `xai` on Vercel; `qwen` vs `alibaba`; `z-ai` vs `zai`), so both spellings map
    /// to one canonical label. An unlisted prefix — the community fine-tuners, mostly
    /// — capitalizes into a monogram, which is the honest render for a vendor with no
    /// brand mark.
    static let vendorNames: [String: String] = [
        // Notch's own providers.
        "openai": "OpenAI", "anthropic": "Anthropic", "google": "Google",
        "deepseek": "DeepSeek", "qwen": "Qwen", "alibaba": "Qwen",
        "z-ai": "Zhipu", "zai": "Zhipu", "zhipuai": "Zhipu", "thudm": "Zhipu",
        "moonshotai": "Moonshot", "moonshot": "Moonshot",
        "minimax": "MiniMax", "xiaomi": "MiMo", "openrouter": "OpenRouter",
        // Majors reachable through the gateways.
        "meta-llama": "Meta", "meta": "Meta",
        "mistralai": "Mistral", "mistral": "Mistral",
        "x-ai": "xAI", "xai": "xAI",
        "nvidia": "NVIDIA", "cohere": "Cohere", "perplexity": "Perplexity",
        "microsoft": "Microsoft", "amazon": "Amazon",
        "bytedance": "ByteDance", "bytedance-seed": "ByteDance",
        "tencent": "Tencent", "baidu": "Baidu", "stepfun": "StepFun",
        "liquid": "Liquid AI", "meituan": "Meituan", "inclusionai": "InclusionAI",
        "thinkingmachines": "Thinking Machines", "thinking-machines": "Thinking Machines",
        "kwaipilot": "Kwaipilot", "arcee-ai": "Arcee", "allenai": "Ai2",
        "ai21": "AI21", "ibm-granite": "IBM", "inflection": "Inflection",
        "inception": "Inception", "upstage": "Upstage", "deepcogito": "Deep Cogito",
        "morph": "Morph", "relace": "Relace", "poolside": "Poolside",
        "01-ai": "01.AI", "internlm": "InternLM", "baichuan-inc": "Baichuan",
        // No brand mark worth shrinking — named only so the monogram picks the right
        // initial (`nousresearch` would otherwise capitalize to "Nousresearch").
        "nousresearch": "Nous Research", "cognitivecomputations": "Dolphin",
        "aion-labs": "Aion Labs", "rekaai": "Reka", "sakana": "Sakana AI",
        "nex-agi": "Nex AGI", "anthracite-org": "Anthracite", "sao10k": "Sao10K",
    ]

    static func vendor(for id: String) -> String {
        if let slash = id.firstIndex(of: "/") {
            // OpenRouter prefixes a few ids with `~` (`~anthropic/…`); the tilde is
            // routing metadata, not part of the vendor name.
            let raw = String(id[..<slash]).lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "~"))
            return vendorNames[raw] ?? raw.capitalized
        }
        let l = id.lowercased()
        if l.hasPrefix("gpt") || l.hasPrefix("o1") || l.hasPrefix("o3") || l.hasPrefix("o4") { return "OpenAI" }
        if l.hasPrefix("claude") { return "Anthropic" }
        if l.hasPrefix("gemini") || l.hasPrefix("gemma") { return "Google" }
        if l.hasPrefix("deepseek") { return "DeepSeek" }
        if l.hasPrefix("qwen") || l.hasPrefix("qwq") || l.hasPrefix("qvq") { return "Qwen" }
        if l.hasPrefix("glm") || l.hasPrefix("chatglm") { return "Zhipu" }
        if l.hasPrefix("kimi") || l.hasPrefix("moonshot") { return "Moonshot" }
        if l.hasPrefix("minimax") || l.hasPrefix("abab") { return "MiniMax" }
        if l.hasPrefix("mimo") { return "MiMo" }
        if l.hasPrefix("grok") { return "xAI" }
        if l.hasPrefix("mistral") || l.hasPrefix("pixtral") || l.hasPrefix("codestral") { return "Mistral" }
        if l.hasPrefix("llama") { return "Meta" }
        // Third-party families a first-party endpoint may also host (DashScope resells
        // a few). Named here so `vendor(for:provider:)` recognizes them and leaves them
        // alone rather than stamping the host's logo on someone else's model.
        if l.hasPrefix("baichuan") { return "Baichuan" }
        if l.hasPrefix("yi-") { return "01.AI" }
        if l.hasPrefix("internlm") { return "InternLM" }
        if l.hasPrefix("hunyuan") { return "Tencent" }
        if l.hasPrefix("doubao") || l.hasPrefix("seed-") { return "ByteDance" }
        if l.hasPrefix("ernie") { return "Baidu" }
        if l.hasPrefix("step-") { return "StepFun" }
        return ""
    }

    /// Every label a *recognized* id resolves to — the gateway slugs plus the bare-id
    /// families above (each family's label is also a `vendorNames` value). Anything
    /// outside this set came back from `vendor(for:)` as a guess: an unknown slug,
    /// capitalized, or the empty string. That distinction is what `vendor(for:provider:)`
    /// keys off.
    static let knownVendors: Set<String> = Set(vendorNames.values)

    /// The vendor label for an id **served by a known provider** — what the picker
    /// actually needs, and strictly better than the id alone.
    ///
    /// A first-party endpoint's catalog is full of ids that name no vendor (OpenAI's
    /// `dall-e-3`, GLM's `cogview-4`, MiniMax's `speech-02`) or name a non-vendor
    /// (Gemini's OpenAI-compat layer prefixes every id with `models/`, which used to
    /// capitalize into a "Models" monogram). Those are the provider's own models, so
    /// the provider's brand is the honest answer.
    ///
    /// The fallback fires **only** when the id itself named no vendor we know: a model
    /// a provider resells (DashScope's `deepseek-r1`, `llama3.3-70b`, `baichuan2-13b`)
    /// keeps its real vendor and never wears the host's logo. Gateways opt out
    /// entirely (`vendorName == nil`) — their ids already carry the vendor.
    static func vendor(for id: String, provider: Provider) -> String {
        let v = vendor(for: id)
        guard let own = provider.vendorName, !knownVendors.contains(v) else { return v }
        return own
    }

    /// A tidy display name from an id: drop the `vendor/` prefix and the `:free`
    /// suffix, then capitalize the first letter (`opus` → "Opus", `gpt-5.5` →
    /// "Gpt-5.5") so every model name leads with a capital. The one non-id entry —
    /// OpenRouter's free auto-router — gets its product name instead of the bare
    /// slug remainder ("free").
    static func prettyName(for id: String) -> String {
        if id == "openrouter/free" { return "Auto Router (Free)" }
        var s = id
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// `prettyName`, but for an id read **as `provider` serves it**. The one
    /// provider that differs is Claude Code, whose ids are the CLI's rolling
    /// aliases: a chip reading "Opus" names a shelf, not a model, so the alias is
    /// shown as the concrete model it runs today — "Opus 5" — from the CLI probe's
    /// cache (`ClaudeCLIService.resolvedModels`). The vendor word is dropped
    /// because every one of these labels already sits beside the Anthropic mark.
    /// Until a probe has ever landed, the bare alias stands in.
    static func prettyName(for id: String, provider: Provider) -> String {
        guard provider == .claudeCode,
              let resolved = ClaudeCLIService.resolvedModels[id]
        else { return prettyName(for: id) }
        return ClaudeCLIService.shortDisplayName(forResolved: resolved)
    }
}

/// Ranks OpenRouter's rotating `:free` lineup so the genuinely good models
/// surface above the small/experimental ones instead of drowning in one
/// alphabetical list.
///
/// The primary signal is **real usage** — OpenRouter's own `rankings-daily`
/// dataset (total tokens per model over the last week), which is millions of
/// users voting with their feet. A model people actually run a lot is a far
/// truer "is this good" signal than any spec: hy3 leads the free lineup by 4×,
/// while nominally-huge models (llama-3.3-70b, hermes-405b) don't crack the
/// top-50 at all. Featured = has real usage, ordered most-used first.
///
/// Usage needs the user's key (and a fetch that can fail), so **parameter
/// count is the fallback**: a model with no usage row is ranked by total
/// params parsed from the catalog metadata (id, else description), and only
/// those ≥ `featuredThresholdB` are featured. So a brand-new free model that
/// hasn't accumulated usage yet still gets a fair shot on size, and if the
/// usage fetch fails entirely the menu degrades cleanly to size-only ordering.
enum OpenRouterFreeModels {
    // MARK: Server-side failover (`models` fallback chain)

    /// Free models are the unstable end of the OpenRouter marketplace: the
    /// `openrouter/free` auto-router can route to an id that is rate-limited,
    /// down, or answering empty *right now*, and a client-side retry of the
    /// identical request just hits the same wall again. OpenRouter's native fix
    /// is the request-body `models` array — a priority chain it walks entirely
    /// server-side (on rate-limits, downtime, moderation, context errors)
    /// within a single request; the response's `model` field reports whichever
    /// id actually answered.
    ///
    /// OpenRouter rejects a `models` array longer than this with a 400
    /// ("'models' array must have 3 items or fewer") — verified live 2026-07.
    /// So the chain is the primary plus at most two fallbacks.
    static let maxChainLength = 3

    /// The bundled fallback candidates: dependable, tool-capable free flagships
    /// from three different vendors (one vendor's outage shouldn't sink the
    /// whole chain), verified against the live catalog 2026-07. Only the first
    /// `maxChainLength - 1` distinct ones ride in any given chain; the remote
    /// manifest's `:free` ids (models.json, hot-updatable without an app
    /// release) take precedence over these when present.
    static let bundledFallbacks = [
        "openai/gpt-oss-120b:free",
        "qwen/qwen3-next-80b-a3b-instruct:free",
        "meta-llama/llama-3.3-70b-instruct:free",
    ]

    /// The failover chain for an OpenRouter request — primary first, then
    /// distinct free candidates up to `maxChainLength` total — or `nil` when
    /// failover doesn't apply. Applied only when the primary is itself free
    /// (the auto-router or a `:free` id): a *paid* model was a deliberate,
    /// billed choice, and silently answering with a different model would be a
    /// surprise, so paid requests go out unchanged.
    static func serverFallbacks(primary: String) -> [String]? {
        guard primary == "openrouter/free" || primary.hasSuffix(":free") else { return nil }
        let curated = (RemoteModelManifest.models(for: .openrouter) ?? [])
            .filter { $0.hasSuffix(":free") }
        var chain = [primary]
        for id in curated + bundledFallbacks
        where !chain.contains(id) && chain.count < maxChainLength {
            chain.append(id)
        }
        return chain.count > 1 ? chain : nil
    }

    // MARK: Featured / rest split for the Settings picker

    /// Total-parameter floor (in billions) for the *fallback* (size-only)
    /// featured test. 70B sits in the natural gap of the free lineup: flagships
    /// are 70B–550B+, the long tail of nano/mini/safety models is ≤33B.
    static let featuredThresholdB: Double = 70

    /// Any `<number>B` token: `550b`, `1.2b`, `295B-parameter`. The lookahead
    /// keeps it from matching inside a longer alphanumeric run (`a4b-it` still
    /// matches `4b` at its own end, `12bit` would not) — deliberately not `\b`,
    /// whose Unicode word-boundary semantics in Swift Regex fail on ids like
    /// `…-405b:free`. MoE ids like `550b-a55b` yield both numbers and `max`
    /// picks the total.
    private static let sizeToken = #/(\d+(?:\.\d+)?)\s*[bB](?![A-Za-z0-9])/#

    /// Best guess at total parameters, in billions; 0 when nothing is stated.
    /// The id wins over the description when both carry sizes — descriptions
    /// love comparisons ("beats Llama 405B"), which would inflate small models.
    static func paramBillions(id: String, description: String?) -> Double {
        let fromID = sizes(in: id)
        if let m = fromID.max() { return m }
        // Only the description's opening — later paragraphs drift into
        // benchmark comparisons against *other* (bigger) models.
        return sizes(in: String((description ?? "").prefix(400))).max() ?? 0
    }

    private static func sizes(in text: String) -> [Double] {
        text.matches(of: sizeToken).compactMap { Double($0.output.1) }
    }

    /// Total recent-usage tokens for a free `:free` id, or `nil` if that model
    /// has no ranking row. Both sides are reduced to a family stem
    /// (`UsageRankings.stem`) and matched by **prefix**, not equality: the
    /// ranking key may carry extra size chunks the id lacks
    /// (`qwen3-coder-480b-a35b` vs the id's `qwen3-coder`), so we credit a
    /// ranking key to this id when either stem is a prefix of the other. Sums
    /// across every matching key so a model split over multiple dated variants
    /// keeps its full total.
    private static func usageTokens(for id: String, in map: [String: Double]) -> Double? {
        let idStem = UsageRankings.stem(id)
        var total = 0.0
        var matched = false
        for (key, tokens) in map where stemsMatch(idStem, key) {
            total += tokens
            matched = true
        }
        return matched ? total : nil
    }

    /// Two stems refer to the same model family if one is a prefix of the other
    /// at a component (`/` or `-`) boundary — so `tencent/hy3` matches
    /// `tencent/hy3` and `qwen/qwen3-coder` matches `qwen/qwen3-coder-480b-a35b`,
    /// but `qwen/qwen3` would not spill into `qwen/qwen3-coder` (guarded by the
    /// boundary check).
    private static func stemsMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        func prefixAtBoundary(_ shorter: String, _ longer: String) -> Bool {
            guard longer.hasPrefix(shorter), longer.count > shorter.count else { return false }
            let next = longer[longer.index(longer.startIndex, offsetBy: shorter.count)]
            return next == "-" || next == "/"
        }
        return a.count < b.count ? prefixAtBoundary(a, b) : prefixAtBoundary(b, a)
    }

    /// Split free-model entries into (featured, rest).
    ///
    /// A model is **featured** if it has real last-week usage (`usage` non-nil),
    /// OR — when no usage is known for it — its parameter count clears the
    /// fallback threshold. Featured order: usage first (most-used → least),
    /// then the size-only models below them (biggest → smallest); the rest go
    /// alphabetical. Pass an empty `usage` map to get pure size-based ordering
    /// (the degraded path when the rankings fetch failed).
    static func split(
        _ entries: [(id: String, description: String?)],
        usage: [String: Double] = [:]
    ) -> (featured: [String], rest: [String]) {
        // (byUsage: token count if ranked else nil, size: params, id)
        var featured: [(byUsage: Double?, size: Double, id: String)] = []
        var rest: [String] = []
        for e in entries {
            let used = usageTokens(for: e.id, in: usage)
            let size = paramBillions(id: e.id, description: e.description)
            if used != nil || size >= featuredThresholdB {
                featured.append((byUsage: used, size: size, id: e.id))
            } else {
                rest.append(e.id)
            }
        }
        // Usage-ranked models sort above size-only ones; within each cohort,
        // by the cohort's own metric descending, ties broken by id.
        featured.sort { a, b in
            switch (a.byUsage, b.byUsage) {
            case let (ua?, ub?): return ua == ub ? a.id < b.id : ua > ub
            case (_?, nil):      return true      // any usage beats no usage
            case (nil, _?):      return false
            case (nil, nil):     return a.size == b.size ? a.id < b.id : a.size > b.size
            }
        }
        return (featured.map(\.id), rest.sorted())
    }

    /// How many models the "Best free models" section shows. The rest of the
    /// featured cohort spills into "More free models" — the header is meant to
    /// be a short, confident shortlist, not the whole flagship list.
    static let featuredLimit = 3

    /// Grouping for the Settings menu: ids that aren't `:free` variants (the
    /// auto-router, a hand-typed custom id) keep their original order up top,
    /// then the top `featuredLimit` featured models, then everything else.
    /// Buckets preserve the incoming order — the catalog fetch already ranked
    /// featured most-used-first, so "top N" is the N most-used. `featured`
    /// membership comes from that same fetch.
    static func group(
        _ ids: [String], featured featuredIDs: Set<String>, limit: Int = featuredLimit
    ) -> (head: [String], featured: [String], rest: [String]) {
        var head: [String] = [], featured: [String] = [], rest: [String] = []
        for id in ids {
            if !id.hasSuffix(":free") {
                head.append(id)
            } else if featuredIDs.contains(id), featured.count < limit {
                featured.append(id)
            } else {
                // Overflow featured models fall in with the rest; they keep
                // their fetch order (most-used first), so they lead the tail.
                rest.append(id)
            }
        }
        return (head, featured, rest)
    }
}

/// Fetches OpenRouter's `rankings-daily` dataset — real per-model token totals
/// over a recent window — and folds it into a base-name → total-tokens map that
/// `OpenRouterFreeModels.split` ranks by. This is the "millions of users voting"
/// signal; everything about matching it to our `:free` ids is handled here.
///
/// The dataset reports per *model version* (`model_permaslug`, dated, e.g.
/// `tencent/hy3-preview-20260421`) and mixes free+paid usage, so we key by the
/// undated base name and sum every permaslug that starts with it. A missing
/// row (model too niche for the top-50) simply yields no entry — the caller
/// treats "no usage" as a fallback-to-size case, not zero.
enum UsageRankings {
    /// A short recent window is what we want (fresh popularity, not a month-old
    /// average); the dataset defaults to 30 days, so we pass an explicit 3-day
    /// `start_date`. Auth is the same key used for `/models`.
    static func fetch(apiKey: String, days: Int = 3) async -> [String: Double]? {
        var comps = URLComponents(string: "https://openrouter.ai/api/v1/datasets/rankings-daily")
        // start_date only; end_date defaults to the most recent completed UTC day.
        if let start = Self.startDate(daysAgo: days) {
            comps?.queryItems = [URLQueryItem(name: "start_date", value: start)]
        }
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        do {
            let (data, response) = try await ProxyConfig.urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return byBaseName(payload.data)
        } catch {
            return nil
        }
    }

    /// Sum `total_tokens` per model **stem** — the family name with dated /
    /// `preview` version tails removed (`tencent/hy3-preview-20260421` and
    /// `tencent/hy3-20260706:free` both → `tencent/hy3`). Keying on the stem,
    /// then matching a free id's stem against it by *prefix* (see
    /// `OpenRouterFreeModels`), collapses every version of a model onto one
    /// total. This is deliberately looser than exact-key equality: an earlier
    /// version tried to reduce both sides to an identical string and silently
    /// dropped hy3's bulk, because a `-preview` tail on the ranking side has no
    /// counterpart on the `:free` id side and the two keys never met.
    static func byBaseName(_ rows: [Row]) -> [String: Double] {
        var totals: [String: Double] = [:]
        for r in rows {
            guard let tokens = Double(r.total_tokens) else { continue }
            totals[stem(r.model_permaslug), default: 0] += tokens
        }
        return totals
    }

    /// A model's family stem: drop `:free`, then peel a trailing dated /
    /// `-preview` version tail so all variants of one model share it.
    /// `tencent/hy3-preview-20260421` → `tencent/hy3`;
    /// `qwen/qwen3-coder-480b-a35b-07-25` → `qwen/qwen3-coder-480b-a35b`
    /// (size chunks are name parts, kept). Applied to *both* the ranking
    /// permaslug and the `:free` id so the two sides meet.
    static func stem(_ raw: String) -> String {
        var s = raw
        if s.hasSuffix(":free") { s = String(s.dropLast(":free".count)) }
        // Peel trailing "-<version-ish>" chunks: an 8-digit date, a `MM-DD`
        // fragment, a bare version number, a `v2`-style token, or the literal
        // `preview`. Everything else (including `-480b`, `-a35b`, `-instruct`)
        // is a name part and stays.
        func isVersionish(_ c: Substring) -> Bool {
            if c == "preview" { return true }
            if c.allSatisfy({ $0.isNumber }) { return true }          // 20260421, 2509, 25
            if c.first == "v", c.dropFirst().allSatisfy({ $0.isNumber || $0 == "." }) {
                return c.count > 1                                     // v2, v2.5
            }
            return false
        }
        while let dash = s.lastIndex(of: "-") {
            let chunk = s[s.index(after: dash)...]
            guard !chunk.isEmpty, isVersionish(chunk) else { break }
            s = String(s[..<dash])
        }
        return s
    }

    /// `YYYY-MM-DD` for `daysAgo` days before today (UTC). `nil` on the (never,
    /// in practice) chance the date math fails — the caller then omits the
    /// param and takes the dataset's 30-day default.
    private static func startDate(daysAgo: Int) -> String? {
        var cal = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else { return nil }
        cal.timeZone = utc
        guard let day = cal.date(byAdding: .day, value: -daysAgo, to: Date()) else { return nil }
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = utc
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: day)
    }

    struct Payload: Decodable { let data: [Row] }
    struct Row: Decodable {
        let model_permaslug: String
        let total_tokens: String
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
        // A custom endpoint may legitimately have no key (a local server), so the
        // probe still runs — "can I reach it?" is exactly what Test means there.
        guard !key.isEmpty || provider == .custom else { return .missingKey }
        guard let url = probeURL(for: provider) else {
            // No /models sibling we can derive — fall back to "we can't test this".
            return .failed(L("conn.unavailable"))
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if provider.isOpenAICompatible {
            req.setBearer(key)
        } else {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        req.timeoutInterval = 12

        do {
            let (_, response) = try await ProxyConfig.urlSession.data(for: req)
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

/// Models that refuse to run function tools *while reasoning* on the legacy
/// `/v1/chat/completions` endpoint.
///
/// OpenAI's `gpt-5.6-*` answers a tool request with a 400: "Function tools with
/// reasoning_effort are not supported for … in /v1/chat/completions. To use
/// function tools, use /v1/responses or set reasoning_effort to 'none'." No value
/// of the field helps except `none` — `low`/`medium` fail identically — so unlike
/// `temperature` (`SamplingKnobs`) this one can't be fixed by *not* sending a
/// field: the model needs to be told to stop reasoning. Measured on the wire, one
/// tool-bearing request per model:
///
///   · `gpt-5.6-luna` / `-terra`  no field / low / medium → 400
///                                `"none"`                → streams, tools work
///   · `gpt-5.5`, `gpt-5.4`, `-mini`  no field            → streams (they reason
///                                                          *and* call tools fine)
///
/// So it can't be sent unconditionally either — that would silently drop reasoning
/// on every model that doesn't need it. And a hardcoded model list is exactly the
/// thing that rots on the next OpenAI release. Instead this is **learned from the
/// 400 itself**: the vendor names the requirement, we honor it and replay the same
/// turn once, then remember the model id so the round-trip is paid once per launch.
/// A model id nobody has heard of yet needs no code change.
private enum ToolReasoningOptOut {
    private static let lock = NSLock()
    private static var models: Set<String> = []

    /// Whether an error body is the vendor asking for `reasoning_effort: "none"`
    /// because the request carried tools. Both terms are required so the unrelated
    /// "unsupported value for reasoning_effort" 400 doesn't match.
    static func isSignal(_ body: String) -> Bool {
        let b = body.lowercased()
        return b.contains("reasoning_effort") && b.contains("tools")
    }

    static func remember(_ model: String) {
        lock.lock(); defer { lock.unlock() }
        models.insert(model)
    }

    static func applies(to model: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return models.contains(model)
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
                // Flipped by the 400 below (or preset for a model we already
                // learned about) — see `ToolReasoningOptOut`.
                var noReasoning = false
                while true {
                    do {
                        var req = URLRequest(url: provider.endpoint)
                        req.httpMethod = "POST"
                        req.timeoutInterval = Self.streamTimeout
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.setBearer(apiKey)
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

                        // No `temperature` — see `SamplingKnobs`.
                        var body: [String: Any] = [
                            "model": effectiveModel,
                            "messages": Self.wireMessages(system: system, messages: messages),
                            "stream": true,
                        ]
                        if !wireTools.isEmpty {
                            body["tools"] = wireTools
                            // Only for a model that has told us it can't do both —
                            // never a blanket "stop reasoning". See `ToolReasoningOptOut`.
                            if noReasoning || ToolReasoningOptOut.applies(to: effectiveModel) {
                                body["reasoning_effort"] = "none"
                            }
                        }
                        for (k, v) in bodyExtras { body[k] = v }
                        // OpenRouter server-side failover for free models: `models`
                        // is the priority chain OpenRouter walks on its own when an
                        // id is rate-limited/down, within this single request. The
                        // `.model(ran)` event above already reports whichever id
                        // actually answered. See `OpenRouterFreeModels.serverFallbacks`.
                        if provider == .openrouter,
                           let chain = OpenRouterFreeModels.serverFallbacks(primary: effectiveModel) {
                            body["models"] = chain
                        }
                        req.httpBody = try AgentWire.body(body)

                        let (bytes, response) = try await ProxyConfig.urlSession.bytes(for: req)
                        guard let http = response as? HTTPURLResponse else {
                            throw ServiceError.malformedResponse(provider: provider.displayName)
                        }
                        guard (200..<300).contains(http.statusCode) else {
                            let bodyText = await Self.drainErrorBody(bytes.lines)
                            // The vendor telling us this model won't run tools while
                            // it reasons. Learn it and replay the same turn once with
                            // reasoning off, rather than surfacing a dead error.
                            if http.statusCode == 400, !wireTools.isEmpty, !noReasoning,
                               ToolReasoningOptOut.isSignal(bodyText) {
                                ToolReasoningOptOut.remember(effectiveModel)
                                noReasoning = true
                                continue
                            }
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
                        var reportedModel = false

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

                            // The provider echoes the concrete model it ran in every
                            // chunk's top-level `model`; report it once. For the
                            // `openrouter/free` auto-router this is the only place the
                            // real model (e.g. `openai/gpt-oss-20b:free`) is revealed.
                            if !reportedModel,
                               let ran = obj["model"] as? String, !ran.isEmpty {
                                reportedModel = true
                                continuation.yield(.model(ran))
                            }

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
                                        if let n = fn["name"] as? String, !n.isEmpty {
                                            // First sight of this call's name — the model
                                            // has committed to the tool while its arguments
                                            // are still streaming. Announce it now so the
                                            // activity line doesn't wait for the JSON tail.
                                            if entry.name.isEmpty {
                                                continuation.yield(.toolCallStarted(name: n))
                                            }
                                            entry.name = n
                                        }
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
                            "max_tokens": ReplyTokens.anthropicRequiredCeiling,
                            "stream": true,
                        ]
                        if !wireTools.isEmpty { body["tools"] = wireTools }
                        req.httpBody = try AgentWire.body(body)

                        let (bytes, response) = try await ProxyConfig.urlSession.bytes(for: req)
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
                                    // The block carries the tool name up front while
                                    // the arguments stream behind it — announce the
                                    // call now so the activity line doesn't wait.
                                    if !name.isEmpty {
                                        continuation.yield(.toolCallStarted(name: name))
                                    }
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
