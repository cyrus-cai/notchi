import Foundation

/// Where each provider's API key lives. Stored in `UserDefaults` — a plain plist
/// in the app's preferences. Every `Provider` gets its own entry, so switching
/// backends doesn't clobber the other one's key.
///
/// Lookup order per provider (see `AppDelegate`):
///   1. The provider's env var (e.g. `MIMO_API_KEY`, `DEEPSEEK_API_KEY`) — handy
///      for local dev / debugging.
///   2. The `UserDefaults` entry the user typed into Settings.
///   3. A built-in default, if any (none ship by default — every provider's key
///      is supplied by the user).
/// The env var wins so you can run with a throwaway key without touching the
/// stored one.
///
/// Why not the Keychain? These are client-side keys anyway — anyone who can run
/// the app can recover them, so the Keychain's encryption buys little here. In
/// exchange it triggers the system "wants to use your confidential information"
/// authorization prompt (especially across rebuilds with changing ad-hoc
/// signatures), which is more annoying than it's worth for a personal local app.
/// `UserDefaults` keeps the key in a plist under the user's own account — low
/// real-world risk for this use case, and no prompts.
///
/// ⚠️ The trade-off: the key is stored in plaintext, so any process that can read
/// your user defaults can read it. Fine for personal use; before distributing the
/// app to others, move the key behind a small backend so it never ships or sits
/// on disk in the clear.
enum APIKeyStore {
    private static let keyPrefix = "api_key."
    private static let modelKeyPrefix = "model."
    private static let selectedProviderKey = "selected_provider"

    /// Built-in development keys, used only when no env var and no stored entry
    /// are present for that provider. None ship by default — every provider's key
    /// comes from the env var or the Settings entry.
    ///
    /// ⚠️ Anything returned here would ship inside the app bundle — anyone with
    /// the `.app` could extract it. Keep these empty for distribution; if you ever
    /// add one for local convenience, remove it before shipping and rotate it if
    /// it leaks.
    private static func bundledKey(for _: Provider) -> String {
        ""   // no bundled keys — every provider's key is user-supplied
    }

    // MARK: - Selected provider

    /// Which backend is active. Persisted in `UserDefaults`. When the user has
    /// never explicitly picked one, prefer a provider they already configured a
    /// key for (installs that predate this default never wrote the selection),
    /// and otherwise default to OpenRouter — the only backend that works without
    /// pasting a key (one-click connect, free models).
    static var selectedProvider: Provider {
        get {
            let raw = UserDefaults.standard.string(forKey: selectedProviderKey) ?? ""
            if let chosen = Provider(rawValue: raw) { return chosen }
            if let configured = Provider.allCases.first(where: { read($0) != nil }) {
                return configured
            }
            return .openrouter
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: selectedProviderKey)
        }
    }

    // MARK: - Effective / stored key

    /// The effective key to use right now for `provider`:
    /// env var → stored entry → bundled default. `nil` when none is available.
    static func current(for provider: Provider) -> String? {
        if let env = ProcessInfo.processInfo.environment[provider.envVarName],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env
        }
        if let stored = read(provider) { return stored }
        let bundled = bundledKey(for: provider)
        return bundled.isEmpty ? nil : bundled
    }

    /// The key the user saved in Settings for `provider` (ignores the env
    /// override), so the Settings field shows what's actually stored.
    static func stored(for provider: Provider) -> String { read(provider) ?? "" }

    /// True when the provider's env var is forcing a key — then the Settings field
    /// is informational only, since the env override wins.
    static func hasEnvOverride(for provider: Provider) -> Bool {
        let env = ProcessInfo.processInfo.environment[provider.envVarName]
        return env?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Save (or clear, when empty) the user's key for `provider` in `UserDefaults`.
    static func save(_ key: String, for provider: Provider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { delete(provider); return }
        UserDefaults.standard.set(trimmed, forKey: defaultsKey(for: provider))
    }

    // MARK: - Auxiliary (non-provider) service keys

    // Exa is a *search backend*, not an LLM provider, so its key lives outside the
    // per-`Provider` namespace above. When present it replaces every provider's
    // native web search with Exa (see `ToolRegistry.standard(for:)` and the
    // server-search gate in `streamTurn`) — one good searcher for all backends.
    private static let exaDefaultsKey = "aux_key.exa"
    private static let exaEnvVar = "EXA_API_KEY"

    /// The effective Exa key right now: `EXA_API_KEY` env var → stored entry.
    /// `nil` when neither is set (then no provider uses Exa).
    static func currentExaKey() -> String? {
        if let env = ProcessInfo.processInfo.environment[exaEnvVar],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env
        }
        let stored = storedExaKey()
        return stored.isEmpty ? nil : stored
    }

    /// The Exa key the user saved in Settings (ignores the env override), so the
    /// field shows what's actually stored.
    static func storedExaKey() -> String {
        UserDefaults.standard.string(forKey: exaDefaultsKey) ?? ""
    }

    /// True when `EXA_API_KEY` is forcing a key — then the Settings field is
    /// informational only, since the env override wins.
    static func hasExaEnvOverride() -> Bool {
        let env = ProcessInfo.processInfo.environment[exaEnvVar]
        return env?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Whether Exa search is active (a key is available from env or Settings).
    /// Gates the per-provider native search off in favor of Exa for everyone.
    static var exaActive: Bool { currentExaKey() != nil }

    /// Save (or clear, when empty) the user's Exa key in `UserDefaults`.
    static func saveExaKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: exaDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: exaDefaultsKey)
        }
    }

    // Keenable is an optional standalone search backend (`KeenableSearchProvider`).
    // Its HTTP API REQUIRES a key (a keyless `/v1/search` call 401s — the "no key"
    // claim applies only to Keenable's CLI/MCP, not the raw API), so like Exa it's
    // only the active searcher when a key is configured.
    private static let keenableDefaultsKey = "aux_key.keenable"
    private static let keenableEnvVar = "KEENABLE_API_KEY"

    /// The effective Keenable key right now: `KEENABLE_API_KEY` env var → stored
    /// entry. `nil` when neither is set — then Keenable runs on its key-free tier.
    static func currentKeenableKey() -> String? {
        if let env = ProcessInfo.processInfo.environment[keenableEnvVar],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env
        }
        let stored = storedKeenableKey()
        return stored.isEmpty ? nil : stored
    }

    /// The Keenable key the user saved in Settings (ignores the env override), so
    /// the field shows what's actually stored.
    static func storedKeenableKey() -> String {
        UserDefaults.standard.string(forKey: keenableDefaultsKey) ?? ""
    }

    /// True when `KEENABLE_API_KEY` is forcing a key — then the Settings field is
    /// informational only, since the env override wins.
    static func hasKeenableEnvOverride() -> Bool {
        let env = ProcessInfo.processInfo.environment[keenableEnvVar]
        return env?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Save (or clear, when empty) the user's Keenable key in `UserDefaults`.
    static func saveKeenableKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: keenableDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: keenableDefaultsKey)
        }
    }

    /// Whether Keenable search is active (a key is available from env or Settings).
    static var keenableActive: Bool { currentKeenableKey() != nil }

    // AnySearch is a standalone search backend whose REST API also supports an
    // anonymous free tier. A key is therefore optional: when present it raises
    // the quota/concurrency limits, and when absent requests simply omit the
    // Authorization header.
    private static let anySearchDefaultsKey = "aux_key.anysearch"
    private static let anySearchEnvVar = "ANYSEARCH_API_KEY"

    /// The effective AnySearch key right now: `ANYSEARCH_API_KEY` env var →
    /// stored entry. `nil` means the selected backend uses anonymous access.
    static func currentAnySearchKey() -> String? {
        if let env = ProcessInfo.processInfo.environment[anySearchEnvVar],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env
        }
        let stored = storedAnySearchKey()
        return stored.isEmpty ? nil : stored
    }

    static func storedAnySearchKey() -> String {
        UserDefaults.standard.string(forKey: anySearchDefaultsKey) ?? ""
    }

    static func hasAnySearchEnvOverride() -> Bool {
        let env = ProcessInfo.processInfo.environment[anySearchEnvVar]
        return env?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func saveAnySearchKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: anySearchDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: anySearchDefaultsKey)
        }
    }

    /// Which web-search backend the user picks. Like the model picker, you choose
    /// one and that's the one that runs (no cross-backend fallback or automatic
    /// tiebreaker). `nil` means "use the provider's own native search".
    enum SearchBackend: String, CaseIterable, Identifiable {
        case keenable
        case exa
        case anysearch
        var id: String { rawValue }
    }

    private static let searchBackendKey = "searchBackend"

    /// The user's chosen search backend, or `nil` for the provider's native search
    /// (the default — nothing stored, or a stale value that no longer parses).
    static var preferredSearchBackend: SearchBackend? {
        get {
            UserDefaults.standard.string(forKey: searchBackendKey)
                .flatMap(SearchBackend.init)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: searchBackendKey)
            } else {
                UserDefaults.standard.removeObject(forKey: searchBackendKey)
            }
        }
    }

    /// The backend that actually runs. Exa and Keenable require a configured key;
    /// AnySearch is usable anonymously and therefore resolves without one. A
    /// keyless keyed-backend pick hands back to the provider's native search.
    static func resolvedSearchBackend() -> SearchBackend? {
        switch preferredSearchBackend {
        case .exa:      return exaActive ? .exa : nil
        case .keenable: return keenableActive ? .keenable : nil
        // AnySearch explicitly supports anonymous REST requests, so selecting it
        // is enough to make it the unified backend; a key only upgrades limits.
        case .anysearch: return .anysearch
        case nil:       return nil
        }
    }

    /// Whether a unified client-side searcher is standing in for
    /// every provider's native search. Gates the server-search suppression in
    /// `streamTurn`: when false, the provider's own native search stays in play.
    static var unifiedSearchActive: Bool { resolvedSearchBackend() != nil }

    // MARK: - Optional per-provider model override

    /// The model id the user typed in Settings for `provider` (empty when none),
    /// so the Settings field shows what's actually stored. An empty value means
    /// "use the provider's `defaultModel`".
    static func storedModel(for provider: Provider) -> String {
        UserDefaults.standard.string(forKey: modelDefaultsKey(for: provider)) ?? ""
    }

    /// Save (or clear, when empty) the user's model override for `provider`.
    static func saveModel(_ model: String, for provider: Provider) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = modelDefaultsKey(for: provider)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(trimmed, forKey: key)
        }
    }

    /// The model to actually use for `provider`: the user's override if set,
    /// otherwise `nil` so the client falls back to `provider.defaultModel`.
    static func effectiveModel(for provider: Provider) -> String? {
        let stored = storedModel(for: provider)
        // Codex: an empty override — or the legacy "codex" sentinel a pre-real-model
        // selection stored — both mean "use the configured model", so resolve them to
        // the real model read from ~/.codex/config.toml (keeps display and the `-m`
        // actually run in sync).
        if provider == .codex, stored.isEmpty || stored == "codex" {
            return provider.defaultModel
        }
        // Grok: same shape — an empty override or the "grok" sentinel both mean
        // "use the account's default model" (read from the CLI's model cache).
        if provider == .grokCode, stored.isEmpty || stored == "grok" {
            return provider.defaultModel
        }
        // Command Code: same shape once more — an empty override or the
        // "commandcode" sentinel both mean "use the CLI's own default model"
        // (read from the catalog `cmd --list-models` prints).
        if provider == .commandCode,
           stored.isEmpty || stored == CommandCodeCLIService.defaultSentinel {
            return provider.defaultModel
        }
        // pi: same shape again — an empty override or the "pi" sentinel both mean
        // "whatever pi itself is configured to run" (its own settings.json pair,
        // resolved against the catalog).
        if provider == .piCode, stored.isEmpty || stored == PiCLIService.defaultSentinel {
            return provider.defaultModel
        }
        // Claude Code: same shape again. "claude" is the retired account-default
        // sentinel a pre-0.3.1 selection may still hold; it no longer appears in
        // the picker, so resolve it (and an empty override) to the provider's own
        // default alias — the run then names the model the UI names.
        if provider == .claudeCode, stored.isEmpty || stored == "claude" {
            return provider.defaultModel
        }
        return stored.isEmpty ? nil : stored
    }

    // MARK: - Custom endpoint

    /// Whether `provider` needs a key at all before it can answer. Every hosted
    /// vendor does; the user's own endpoint may not (a local Ollama / LM Studio /
    /// vLLM server authenticates nobody), so its key field is optional.
    static func requiresKey(_ provider: Provider) -> Bool { provider != .custom }

    /// The key to send for `provider`, empty when there is none. Only meaningful
    /// for providers that can run keyless (`.custom`); everywhere else the caller
    /// still gates on `current(for:)` being non-nil first.
    static func keyOrEmpty(for provider: Provider) -> String {
        current(for: provider) ?? ""
    }

    // MARK: - UserDefaults plumbing

    private static func defaultsKey(for provider: Provider) -> String {
        keyPrefix + provider.rawValue
    }

    private static func modelDefaultsKey(for provider: Provider) -> String {
        modelKeyPrefix + provider.rawValue
    }

    private static func read(_ provider: Provider) -> String? {
        guard let key = UserDefaults.standard.string(forKey: defaultsKey(for: provider)),
              !key.isEmpty
        else { return nil }
        return key
    }

    private static func delete(_ provider: Provider) {
        UserDefaults.standard.removeObject(forKey: defaultsKey(for: provider))
    }
}

/// The user's **own** OpenAI-compatible backend, behind `Provider.custom`: a local
/// server (Ollama, LM Studio, vLLM, llama.cpp), a self-hosted gateway (one-api,
/// LiteLLM, New API), or any vendor Notch doesn't bundle. Everything the bundled
/// providers get from a hardcoded `ProviderSpec` — name, endpoint, model — this
/// one reads out of `UserDefaults` instead, so `Provider.custom.spec` is built at
/// read time from whatever the user typed in Settings.
///
/// One slot, not a list: the app answers with a single selected provider, and a
/// second custom endpoint would only ever be a second thing to switch between —
/// which is what the provider menu already is.
///
/// The **key is optional** here (unlike every hosted vendor): a local server
/// authenticates nobody, and some reject a blank `Authorization` header outright,
/// so an empty key means the header is left off entirely (see `URLRequest.setBearer`).
enum CustomProvider {
    private static let nameKey = "custom_provider.name"
    private static let urlKey  = "custom_provider.url"

    /// The label shown in the provider menu. Empty ⇒ the generic fallback name.
    static var name: String {
        get { UserDefaults.standard.string(forKey: nameKey) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { UserDefaults.standard.removeObject(forKey: nameKey) }
            else { UserDefaults.standard.set(trimmed, forKey: nameKey) }
        }
    }

    /// The base URL exactly as the user typed it — that's what the Settings field
    /// shows back to them. `chatEndpoint` does the normalizing.
    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { UserDefaults.standard.removeObject(forKey: urlKey) }
            else { UserDefaults.standard.set(trimmed, forKey: urlKey) }
        }
    }

    /// The model id to call. Stored in the same per-provider slot every other
    /// provider's override uses, so nothing downstream needs a special case.
    static var model: String {
        get { APIKeyStore.storedModel(for: .custom) }
        set { APIKeyStore.saveModel(newValue, for: .custom) }
    }

    /// Name for the provider menu: the user's label, else a generic one.
    static var displayName: String {
        let n = name
        return n.isEmpty ? L("model.custom.defaultName") : n
    }

    /// The full chat URL to POST to, derived from `baseURL`. Users paste any of the
    /// three shapes these servers document, so all three are accepted:
    ///   `http://localhost:11434`              → `…:11434/v1/chat/completions`
    ///   `http://localhost:1234/v1`            → `…/v1/chat/completions`
    ///   `https://host/v1/chat/completions`    → unchanged
    /// A scheme-less host gets `https://`. `nil` when nothing usable is stored —
    /// the provider then reads as unconfigured everywhere.
    static var chatEndpoint: URL? { normalized(baseURL) }

    static func normalized(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        if s.hasSuffix("/chat/completions") { return url }
        // A trailing API-version segment (`/v1`, `/v1beta`, `/v4`) means the user
        // gave the OpenAI-compatible base — only the method path is missing.
        let last = url.lastPathComponent
        if last.hasPrefix("v"), last.dropFirst().first?.isNumber == true {
            return URL(string: s + "/chat/completions")
        }
        return URL(string: s + "/v1/chat/completions")
    }

    /// A never-nil endpoint for `ProviderSpec`, which needs a concrete URL even
    /// before anything is configured. The placeholder host doesn't resolve, so a
    /// request that somehow escapes the readiness gates fails as "offline" rather
    /// than reaching anyone.
    static var endpointString: String {
        chatEndpoint?.absoluteString ?? "https://custom.invalid/v1/chat/completions"
    }

    /// Whether this endpoint can actually serve a request: a usable URL **and** a
    /// model id. There's no catalog to fall back on for someone else's server, so
    /// without a model id there is nothing to ask for.
    static var isConfigured: Bool { chatEndpoint != nil && !model.isEmpty }

    /// The model list `Provider.custom` offers before any live `/v1/models` fetch
    /// lands: just the id the user typed. The sentinel stands in while that field
    /// is still empty — `isConfigured` is false then, so it never reaches the wire.
    static var bundledModels: [String] { model.isEmpty ? ["custom"] : [model] }
}
