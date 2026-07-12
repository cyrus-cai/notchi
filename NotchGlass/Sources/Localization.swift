import Foundation
import Combine
import SwiftUI

/// The app's interface language, chosen in Settings → General → App Language and
/// persisted in `UserDefaults`. Independent of the macOS system language: a user
/// can run a Chinese interface on an English Mac (or the reverse). `.system`
/// follows whatever the OS reports, which is the default.
///
/// Switching is *live* — no relaunch. The single `Localization` store publishes
/// the change, every view reads its strings through `L(_:)`, and SwiftUI
/// re-renders the tree. See `Localization`.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case chineseSimplified
    case chineseTraditional

    var id: String { rawValue }

    /// The picker label — each language named in itself (the convention OS
    /// language pickers use), so the row reads the same whatever the current UI
    /// language is. `.system` is the one exception: it's named in the active
    /// language because it describes a behavior, not a language.
    var label: String {
        switch self {
        case .system:             return L("appLang.system")
        case .english:            return "English"
        case .chineseSimplified:  return "简体中文"
        case .chineseTraditional: return "繁體中文"
        }
    }

    /// The concrete locale this choice resolves to — `.system` reads the OS
    /// preference and folds it onto the three we ship, defaulting to English for
    /// anything we don't translate.
    var resolved: Localization.Locale {
        switch self {
        case .english:            return .en
        case .chineseSimplified:  return .zhHans
        case .chineseTraditional: return .zhHant
        case .system:             return AppLanguage.systemLocale
        }
    }

    /// Map the OS's preferred localization onto one of our three. `zh-Hant` /
    /// `zh-TW` / `zh-HK` / `zh-MO` → Traditional; any other `zh*` → Simplified;
    /// everything else → English — mirrors the landing page's `normLang`.
    private static var systemLocale: Localization.Locale {
        let pref = (Locale.preferredLanguages.first ?? "en").lowercased()
        if pref.hasPrefix("zh-hant") || pref.hasPrefix("zh-tw")
            || pref.hasPrefix("zh-hk") || pref.hasPrefix("zh-mo") { return .zhHant }
        if pref.hasPrefix("zh") { return .zhHans }
        return .en
    }

    private static let key = "appLanguage"
    static var current: AppLanguage {
        get {
            UserDefaults.standard.string(forKey: key)
                .flatMap(AppLanguage.init) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}

/// The live string store. One shared instance drives the whole app: views inject
/// it as an `@EnvironmentObject` (or read the shared singleton), call `L("key")`
/// to look up the active-language string, and re-render whenever `language`
/// changes — which is what makes the App Language switch instant, no relaunch.
final class Localization: ObservableObject {
    static let shared = Localization()

    /// The three concrete catalogs we ship. `.system` resolves to one of these.
    enum Locale { case en, zhHans, zhHant }

    /// The user's choice. Setting it persists and republishes, so every view
    /// reading `L(_:)` re-evaluates with the new language on the next render.
    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            AppLanguage.current = language
        }
    }

    private init() {
        language = AppLanguage.current
    }

    /// Look up `key` in the active language, falling back to English, then to the
    /// key itself (so a missing entry is visible in development rather than blank).
    func string(_ key: String) -> String {
        let table: [String: String]
        switch language.resolved {
        case .en:     table = Strings.en
        case .zhHans: table = Strings.zhHans
        case .zhHant: table = Strings.zhHant
        }
        return table[key] ?? Strings.en[key] ?? key
    }
}

/// Global accessor — terse on purpose, since it appears inline in nearly every
/// view (`Text(L("settings.title"))`). Reads the shared store, so it tracks the
/// live language. For interpolation, pass positional args and use `%@` / `%lld`
/// in the catalog value (`L("update.to", v)`).
@inline(__always)
func L(_ key: String) -> String {
    Localization.shared.string(key)
}

/// Interpolating variant: substitutes the args into the catalog value with
/// `String(format:)`. Catalog strings use `%@` for text and `%lld` for integers,
/// the same order in every language (CJK keeps the same `%@` slots).
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: Localization.shared.string(key), arguments: args)
}

/// The string catalog. EN is the source of truth; the two Chinese variants follow
/// the landing page's voice — natural spoken Chinese with a little spark, never
/// stiff machine translation. `zhHant` is the Traditional counterpart of `zhHans`
/// (same tone, Taiwan/HK vocabulary: 檔案/金鑰/游標/終端機…).
///
/// Keys are dot-namespaced by area. Self-named proper nouns (provider brands,
/// "macOS", language names shown in their own script) are intentionally absent —
/// they read the same in every language and stay hardcoded at the call site.
enum Strings {
    // MARK: English (source of truth)
    static let en: [String: String] = [
        // App Language picker
        "appLang.system": "System",

        // Settings shell
        "settings.title": "SETTINGS",
        "settings.back": "Back to prompt",
        "sidebar.model": "Model",
        "sidebar.search": "Search",
        "sidebar.notes": "Notes",
        "sidebar.tools": "Tools",
        "sidebar.general": "General",
        "sidebar.about": "About",

        // Model section
        "model.provider": "Provider",
        "model.provider.noSearchGroup": "No built-in web search",
        "model.provider.noSearchReason": "No native web search. Add a search key in Settings → Search to enable it.",
        "model.apiKey": "API key",
        "model.pasteKey": "Paste your API key",
        "search.backend": "Search backend",
        "search.backend.native": "Default",
        "search.backend.keenable": "Keenable",
        "search.backend.exa": "Exa",
        "model.keenableApiKey": "Keenable key",
        "model.keenablePasteKey": "Paste your Keenable API key",
        "model.keenableHint": "A search backend for every model. Pick which backend to use above. Get a key at ",
        "model.keenableHint.host": "keenable.ai",
        "model.exaApiKey": "Exa key",
        "model.exaPasteKey": "Paste your Exa API key",
        "model.exaHint": "A search backend with full-text grounding. Pick which backend to use above. Get a key at ",
        "model.exaHint.host": "exa.ai",
        "model.test": "Test",
        "model.cancel": "Cancel",
        "model.change": "Change",
        "model.save": "Save",
        "model.saved": "Saved",
        "model.account": "Account",
        "model.disconnect": "Disconnect",
        "model.connecting": "Connecting…",

        // Codex (ChatGPT) — keyless backend that reuses `codex login`.
        "codex.status.connected": "Signed in via ChatGPT",
        "codex.status.getCodex": "Get Codex",
        "codex.action.reauthorize": "Re-authorize",
        "codex.action.signIn": "Sign in",
        "codex.status.hint.ready": "Notch runs your local Codex CLI — answers are billed to your ChatGPT plan.",
        "codex.status.hint.login": "Codex is installed. Run `codex login` in Terminal to sign in, then reopen this.",
        "codex.status.hint.install": "Install the Codex CLI and run `codex login`, then reopen Settings.",
        "codex.error.notInstalled": "Codex CLI not found. Install it and run `codex login`.",
        "codex.error.notSignedIn": "Not signed in to Codex. Run `codex login` in Terminal.",
        "codex.error.noOutput": "Codex returned no answer. Please try again.",
        "codex.error.spawnFailed": "Couldn't start the Codex CLI.",
        "codex.error.runFailed": "Codex failed:",
        "model.finishSignIn": "Finish signing in in your browser…",
        "model.pasteInstead": "Paste a key instead",
        "model.connectOpenRouter": "Connect OpenRouter",
        "model.label": "Model",
        "model.default": "Default (%@)",
        "model.freeFeatured": "Best free models",
        "model.freeMore": "More free models",
        "model.picker.search": "Search…",
        "model.picker.allProviders": "All providers",
        "model.picker.providers": "Providers",
        "model.picker.someProviders": "%lld providers",
        "model.picker.configured": "Configured",
        "model.picker.unconfigured": "No key yet",
        "model.picker.default": "Default",
        "model.picker.empty": "No matching models",
        "model.picker.addKey": "Add key",
        "model.picker.showAll": "Show all %lld models",
        "model.picker.showLess": "Show fewer",
        "model.picker.speed": "Speed",
        "model.picker.intelligence": "Intelligence",
        "model.picker.context": "Context",
        "model.picker.vision": "Vision",
        "model.picker.tools": "Tool Use",
        "model.picker.reasoning": "Reasoning",
        "model.picker.webSearch": "Web search",
        "model.picker.noWebSearch": "No web search",
        "model.keys.section": "Provider & API key",
        "model.setup.needed": "Set up %@ to start asking.",
        "model.pending.hint": "Add a key for %@ to use %@.",
        "model.footer.openrouter.pre": "Free to use — Connect signs you in to ",
        "model.footer.openrouter.host": "openrouter.ai",
        "model.footer.openrouter.post": " and stores a key on this Mac. Free models have a daily cap; add credits there to raise it.",
        "model.footer.byok.pre": "Stored on this Mac. Get a key at ",
        "model.footer.byok.post": ".",
        "model.footer.env": "A key from the %@ environment variable is in use; it overrides these fields.",

        // Connectivity verdicts
        "conn.ok": "Key verified",
        "conn.missingKey": "Enter a key",
        "conn.unauthorized": "Invalid key",
        "conn.serverError": "Server error (%lld)",
        "conn.offline": "No connection",
        "conn.timedOut": "Timed out",
        "conn.unavailable": "Test unavailable for this provider",
        "conn.unexpected": "Unexpected response",

        // Tools section (translation prefs)
        "translation.pref1": "Primary language",
        "translation.pref2": "Secondary language",
        "translation.hint": "Translates to the primary language, or the secondary when already primary.",

        // General section
        "general.showOn": "Show on",
        "general.placement.footer": "External monitors get a menu-bar-height island.",
        "general.dockIcon": "Dock icon",
        "general.dockIcon.footer": "Hidden keeps it a pure overlay — summon with ⌘, or by hovering the notch.",
        "general.launchAtLogin": "Launch at login",
        "general.fullscreenAutoHide": "Hide in full screen",
        "general.fullscreenAutoHide.hint": "Tuck the island away while a full-screen app covers its screen. Only affects the virtual notch on external displays.",
        "general.noteDestination": "Save notes to",
        "general.noteDestination.hint": "Apple Notes, or plain Markdown files (one per day) in a folder you choose.",
        "general.noteFolder.choose": "Choose…",
        "noteDest.appleNotes": "Apple Notes",
        "noteDest.folder": "Markdown folder",
        "general.customInstructions": "Custom instructions",
        "general.customInstructions.placeholder": "e.g. Always answer in English",
        "general.customInstructions.hint": "A short preference added to every Ask — like \"prefer code\" or \"use metric\".",
        "general.quickTools": "Quick tools",
        "general.quickTools.count": "%lld enabled",
        "general.copySense": "Copy sensing",
        "general.copySense.hint": "Copy a note or reminder, press ⌘C again to file it.",
        "sense.note": "To Save",
        "sense.reminder": "To Save",
        "sense.saved": "Saved",
        "sense.failed": "Couldn't save",
        "general.appLanguage": "Language",
        "general.shortcut": "Shortcut",
        "general.shortcut.recording": "Type a shortcut…",
        "general.shortcut.off": "Off",
        "general.shortcut.reset": "Reset to double-tap ⌥",
        "general.shortcut.disable": "Turn off",
        "general.shortcut.needModifier": "Add ⌘, ⌥ or ⌃ — a bare key fires too easily.",
        "general.shortcut.reserved": "⌘, already opens Settings. Pick another.",
        "placement.all": "All displays",
        "placement.builtIn": "Built-in display",
        "dock.hidden": "Hidden",
        "dock.shown": "Shown",

        // About section
        "about.update.to": "Update to %@",
        "about.updating": "Updating…",
        "about.updateFailed": "Update failed — get it from the releases page",
        "about.github": "GitHub",
        "about.releases": "Releases",
        "about.privacy": "Privacy",
        "about.whatsNew": "What's New",
        "about.group.updates": "Updates",
        "about.group.more": "More",
        "about.checkForUpdates": "Check for updates",
        "about.checking": "Checking…",
        "about.upToDate": "You're up to date",

        // What's New
        "whatsnew.title": "WHAT'S NEW",
        "whatsnew.back": "Back to prompt",
        "whatsnew.currentBadge": "CURRENT VERSION",
        "whatsnew.cue": "what's new",
        "whatsnew.section.features": "FEATURES",
        "whatsnew.section.improvements": "IMPROVEMENTS",
        "whatsnew.section.fixes": "FIXES",
        "whatsnew.empty": "Release notes aren't available right now.",
        "whatsnew.viewReleases": "View on Releases",

        // Idle / input
        "input.placeholder": "Type anything...",
        "input.saving": "Saving…",
        "input.copiedPrefix": "Copied: %@",
        "hint.ask": "Ask",
        "hint.note": "Note",
        "hint.remind": "Remind",

        // First-run onboarding (see OnboardingService / OnboardingView).
        // The gesture hint teaches the summon affordance at the resting notch; the
        // guide is the 3-step in-panel flow that opens on the first launch.
        "onboarding.gestureHint": "hover — or ⌘,",
        "onboarding.gestureHint.noNotch": "⌘, to open",
        "onboarding.back": "Back",
        "onboarding.next": "Next",
        "onboarding.skip": "Skip",
        // Step 1 — welcome
        "onboarding.welcome.headline": "You type. It sorts.",
        "onboarding.welcome.sub": "Type a half-formed thought — Notchi routes it three ways:",
        "onboarding.welcome.ask": "A question goes to AI.",
        "onboarding.welcome.note": "Anything to keep goes to Apple Notes.",
        "onboarding.welcome.remind": "Anything with a time goes to Apple Reminders.",
        // Step 2 — connect a model
        "onboarding.connect.title": "Connect a model",
        "onboarding.connect.lead": "Ask needs an AI model. Note and Remind already work without one.",
        "onboarding.connect.or.button": "Connect OpenRouter — free",
        "onboarding.connect.or.short": "OpenRouter — free",
        "onboarding.connect.or.subtitle": "Free, sign in once",
        "onboarding.connect.byok": "Have your own key? Paste it",
        "onboarding.connect.byok.short": "Paste a key",
        "onboarding.connect.byok.subtitle": "OpenAI, Anthropic & more",
        "onboarding.connect.connected": "Connected",
        "onboarding.connect.connecting": "Connecting…",
        "onboarding.connect.privacy": "",
        // Step 2b — paste a key (in-guide, not Settings)
        "onboarding.paste.title": "Paste a key",
        "onboarding.paste.lead": "Pick your provider and paste its API key. You can change this later in Settings.",
        "onboarding.paste.provider": "Provider",
        "onboarding.paste.field": "Paste your %@ key",
        "onboarding.paste.get": "Get a key",
        "onboarding.paste.save": "Save & continue",
        "onboarding.paste.invalid": "That doesn't look like a valid key.",
        // Step 3 — try it
        "onboarding.try.title": "You're set",
        "onboarding.try.lead": "Hover the notch any time to summon Notchi. Here's your first question:",
        "onboarding.try.example": "How long does caffeine take to kick in?",
        "onboarding.try.ask": "Ask it",
        "recur.daily": " · Daily",
        "recur.weekly": " · Weekly",
        "recur.weeklyOn": " · Weekly · %@",
        "recur.monthly": " · Monthly",

        // Clipboard preset chips
        "preset.summarize": "Summarize",
        "preset.keyPoints": "Key Points",
        "preset.proofread": "Proofread",
        "preset.rewrite": "Rewrite",
        "preset.friendly": "Friendly",
        "preset.professional": "Professional",
        "preset.concise": "Concise",
        "preset.translate": "Translate",

        // Capture chips
        "capture.note": "Note",
        "capture.remind": "Remind",

        // Recent list
        "recent.manage": "More",
        "recent.collapse": "Back",
        "recent.settings": "Settings (⌘,)",
        "recent.menu.settings": "Settings",
        "recent.menu.seeAll": "See all history",
        "history.window.title": "History",
        "history.window.search": "Search history",
        "history.window.filter.all": "All",
        "history.window.filter.ask": "Ask",
        "history.window.filter.notes": "Notes",
        "history.window.filter.reminders": "Reminders",
        "history.window.count": "%lld items",
        "history.window.empty": "No history yet",
        "history.window.empty.filtered": "Nothing matches",
        "history.window.detail.empty": "Select a conversation",
        "history.detail.you": "You",
        "history.detail.assistant": "Assistant",
        "recent.clear": "Clear",
        "recent.filter": "Filter…",
        "recent.filter.note": "Note",
        "recent.filter.remind": "Remind",
        "recent.filter.ask": "Ask",
        "recent.filter.clear": "Clear filter",
        "recent.badge.notes": "Notes",
        "recent.badge.reminders": "Reminders",
        "recent.hint.note": "Opens this note in Notes",
        "recent.hint.reminder": "Opens this reminder in Reminders",
        "recent.hint.ask": "Reopens this conversation",
        "recent.answering": "Answering…",
        "recent.delete": "Delete",
        "recent.recent": "Recent",

        // Clear-history confirm
        "clear.title": "Clear recent history?",
        "clear.body": "This permanently removes all recent questions. This can't be undone.",
        "clear.cancel": "Cancel",
        "clear.confirm": "Clear History",

        // Result / thread
        "result.setUpModel": "Set up your model",
        "result.basedOnCopied": "Based on what you copied",
        "result.you": "You",
        "result.newConversation": "New conversation (←)",
        "result.pin": "Pin (⌘P)",
        "result.unpin": "Unpin (⌘P)",
        "result.copiedToClipboard": "Copied to clipboard",
        "result.copyAnswer": "Copy answer (⌘C)",
        "result.copyMarkdown": "Copy as Markdown (⌘C)",
        "result.copyPlainText": "Copy as plain text",
        "result.regenerate": "Regenerate (⌘R)",
        "result.regenerate.menu": "Regenerate (⌘R)",
        "result.regenerate.with": "Regenerate with…",
        "result.regenerate.current": "%@ (current)",
        "result.copyToContinue": "Copy chat to continue in ChatGPT or Claude",
        "result.model": "Model",
        "result.modelUsed": "Answered by %@",
        "result.followUp": "Ask a follow-up…",
        "clip.imageCopied": "Copied image",
        "bubble.showMore": "Show more",
        "bubble.showLess": "Show less",
        "ask.visionHint": "The selected model may not support images — try a vision-capable model.",

        // Feedback / errors
        "feedback.addedNotesClip": "Added to Notes · with clipboard",
        "feedback.addedNotes": "Added to Notes",
        "feedback.notesFailed": "Couldn't save to Notes. Try again.",
        "feedback.addedFile": "Added to notes folder",
        "feedback.addedFileClip": "Added to notes folder · with clipboard",
        "feedback.fileFailed": "Couldn't write the note file. Try again.",
        "feedback.addedReminders": "Added to Reminders%@",
        "feedback.remindersFailed": "Couldn't save to Reminders. Try again.",
        "feedback.savePreservedLine": "%1$@\n%2$@",
        "error.generic": "Something went wrong. Try again.",
        "error.retry": "Try again",
        "error.openSettings": "Open Settings",
        "error.interrupted": "\n\n— connection lost; answer may be incomplete.",
        "error.truncated": "\n\n— answer cut off (hit the length limit).",
        "notify.answerReady.title": "Answer ready",

        // Relative time
        "time.justNow": "just now",
        "time.minutesAgo": "%lldm ago",
        "time.hoursAgo": "%lldh ago",
        "time.daysAgo": "%lldd ago",

        // Service errors
        "notes.error.permission": "Allow access to Notes in System Settings → Privacy & Security → Automation.",
        "notes.error.unavailable": "Couldn't reach Notes. Try again.",
        "notes.file.error.folder": "Couldn't create the notes folder. Check its location in Settings.",
        "notes.error.fallback": "Couldn't save to Notes.",
        "reminders.error.permission": "Allow access in System Settings → Privacy & Security → Reminders.",
        "reminders.error.noList": "No Reminders list found. Open the Reminders app once, then try again.",

        // AI service errors / stub
        "service.error.http": "%@ request failed (HTTP %lld).",
        "service.error.malformed": "%@ returned an unexpected response.",
        "stub.noModel": "No model connected yet — this is the offline stub. Open Settings (⌘,) and connect a free OpenRouter account (or paste an API key) to get live answers.",

        // OpenRouter OAuth
        "or.error.noPort": "Couldn't open a local port for the sign-in redirect",
        "or.error.cancelled": "Sign-in was cancelled in the browser",
        "or.error.noKey": "OpenRouter didn't issue a key — try connecting again",
        "or.error.unreachable": "Couldn't reach OpenRouter — check your connection and try again",

        // OpenRouter browser-redirect pages (shown in the user's browser)
        "or.page.connected.title": "Connected",
        "or.page.connected.line": "Notchi is connected — you can close this tab.",
        "or.page.cancelled.title": "Cancelled",
        "or.page.cancelled.line": "Sign-in was cancelled. You can close this tab and try again from Notchi.",

        // Agent tool activity (shown on the streaming turn while a tool runs)
        "agent.activity.search": "Searching the web…",
        "agent.activity.refining": "Digging deeper…",
        "agent.activity.composing": "Reading the results…",
        // While reading results, the line names the page (its host) being read.
        "agent.activity.readingPage": "Reading %@",
        "agent.activity.clipboard": "Reading the clipboard…",
        "agent.activity.time": "Checking the time…",
        "agent.activity.calc": "Calculating…",
        "agent.activity.askUser": "Waiting for your choice…",
        "agent.activity.working": "Working…",
        "agent.activity.runningTool": "Running %@…",
        "agent.activity.thinking": "Thinking…",

        // Source badge (under a search-grounded answer)
        "source.badge.help": "Sources",
        "source.badge.fallback": "Sources",
    ]

    // MARK: 简体中文
    static let zhHans: [String: String] = [
        "appLang.system": "跟随系统",

        "settings.title": "设置",
        "settings.back": "返回输入",
        "sidebar.model": "模型",
        "sidebar.search": "搜索",
        "sidebar.notes": "笔记",
        "sidebar.tools": "工具",
        "sidebar.general": "通用",
        "sidebar.about": "关于",

        "model.provider": "服务商",
        "model.provider.noSearchGroup": "无内置联网搜索",
        "model.provider.noSearchReason": "没有原生联网搜索。在 设置 → 搜索 里填搜索密钥即可启用。",
        "model.apiKey": "API 密钥",
        "model.pasteKey": "粘贴你的 API 密钥",
        "search.backend": "搜索后端",
        "search.backend.native": "默认",
        "search.backend.keenable": "Keenable",
        "search.backend.exa": "Exa",
        "model.keenableApiKey": "Keenable 密钥",
        "model.keenablePasteKey": "粘贴你的 Keenable API 密钥",
        "model.keenableHint": "一个面向所有模型的搜索后端。在上方选择使用哪个后端。获取密钥 ",
        "model.keenableHint.host": "keenable.ai",
        "model.exaApiKey": "Exa 密钥",
        "model.exaPasteKey": "粘贴你的 Exa API 密钥",
        "model.exaHint": "带全文支撑的搜索后端。在上方选择使用哪个后端。获取密钥 ",
        "model.exaHint.host": "exa.ai",
        "model.test": "测试",
        "model.cancel": "取消",
        "model.change": "更改",
        "model.save": "保存",
        "model.saved": "已保存",
        "model.account": "账号",
        "model.disconnect": "断开",

        // Codex（ChatGPT）—— 无需密钥，复用 `codex login` 登录。
        "codex.status.connected": "已通过 ChatGPT 登录",
        "codex.status.getCodex": "获取 Codex",
        "codex.action.reauthorize": "重新授权",
        "codex.action.signIn": "登录",
        "codex.status.hint.ready": "Notch 会调用本机的 Codex CLI，用量计入你的 ChatGPT 套餐。",
        "codex.status.hint.login": "已安装 Codex。在终端运行 `codex login` 登录后，重新打开此处。",
        "codex.status.hint.install": "安装 Codex CLI 并运行 `codex login`，然后重新打开设置。",
        "codex.error.notInstalled": "未找到 Codex CLI。请先安装并运行 `codex login`。",
        "codex.error.notSignedIn": "尚未登录 Codex。请在终端运行 `codex login`。",
        "codex.error.noOutput": "Codex 未返回内容，请重试。",
        "codex.error.spawnFailed": "无法启动 Codex CLI。",
        "codex.error.runFailed": "Codex 执行失败：",
        "model.connecting": "连接中…",
        "model.finishSignIn": "去浏览器里完成登录…",
        "model.pasteInstead": "改用密钥粘贴",
        "model.connectOpenRouter": "连接 OpenRouter",
        "model.label": "模型",
        "model.default": "默认（%@）",
        "model.freeFeatured": "高质量免费模型",
        "model.freeMore": "更多免费模型",
        "model.picker.search": "搜索…",
        "model.picker.allProviders": "全部供应商",
        "model.picker.providers": "供应商",
        "model.picker.someProviders": "%lld 家供应商",
        "model.picker.configured": "已配置",
        "model.picker.unconfigured": "未配置 key",
        "model.picker.default": "默认",
        "model.picker.empty": "没有匹配的模型",
        "model.picker.addKey": "去填 key",
        "model.picker.showAll": "展开全部 %lld 个模型",
        "model.picker.showLess": "收起",
        "model.picker.speed": "速度",
        "model.picker.intelligence": "智能程度",
        "model.picker.context": "上下文",
        "model.picker.vision": "视觉",
        "model.picker.tools": "工具调用",
        "model.picker.reasoning": "推理",
        "model.picker.webSearch": "联网搜索",
        "model.picker.noWebSearch": "无联网搜索",
        "model.keys.section": "服务商与密钥",
        "model.setup.needed": "配置 %@ 后即可开始提问。",
        "model.pending.hint": "填入 %@ 密钥后即可使用 %@。",
        "model.footer.openrouter.pre": "免费使用——点「连接」会带你登录 ",
        "model.footer.openrouter.host": "openrouter.ai",
        "model.footer.openrouter.post": "，密钥存在这台 Mac 上。免费模型每天有上限，充点额度就能提高。",
        "model.footer.byok.pre": "只存在这台 Mac 上。去这里拿密钥：",
        "model.footer.byok.post": "。",
        "model.footer.env": "正在使用来自 %@ 环境变量的密钥，它会覆盖这里的设置。",

        "conn.ok": "密钥已验证",
        "conn.missingKey": "请输入密钥",
        "conn.unauthorized": "密钥无效",
        "conn.serverError": "服务器错误（%lld）",
        "conn.offline": "无网络连接",
        "conn.timedOut": "请求超时",
        "conn.unavailable": "该服务商不支持测试",
        "conn.unexpected": "响应异常",

        "translation.pref1": "首选语言一",
        "translation.pref2": "首选语言二",
        "translation.hint": "译成语言一；原文已是语言一时译成语言二。",

        "general.showOn": "显示于",
        "general.placement.footer": "外接显示器会得到一个菜单栏高度的小岛。",
        "general.dockIcon": "程序坞图标",
        "general.dockIcon.footer": "隐藏后它就是个纯浮层——用 ⌘, 或把鼠标移到刘海上来唤出。",
        "general.launchAtLogin": "开机时启动",
        "general.fullscreenAutoHide": "全屏时隐藏",
        "general.fullscreenAutoHide.hint": "当某个应用全屏占据它所在的屏幕时，把小岛收起来。仅影响外接显示器上的虚拟刘海。",
        "general.noteDestination": "笔记保存到",
        "general.noteDestination.hint": "存入 Apple 备忘录，或存成你指定文件夹里的 Markdown 纯文本（每天一个文件）。",
        "general.noteFolder.choose": "选择…",
        "noteDest.appleNotes": "Apple 备忘录",
        "noteDest.folder": "Markdown 文件夹",
        "general.customInstructions": "自定义指令",
        "general.customInstructions.placeholder": "例如：始终用简体中文回答",
        "general.customInstructions.hint": "拼进每次提问的一句偏好，比如「优先给代码」「用公制单位」。",
        "general.quickTools": "快捷工具",
        "general.quickTools.count": "已选 %lld 个",
        "general.copySense": "复制感知",
        "general.copySense.hint": "复制笔记或提醒后，再按一次 ⌘C 直接存好。",
        "sense.note": "To Save",
        "sense.reminder": "To Save",
        "sense.saved": "已存入",
        "sense.failed": "没存上",
        "general.appLanguage": "语言",
        "general.shortcut": "快捷键",
        "general.shortcut.recording": "按下快捷键…",
        "general.shortcut.off": "关闭",
        "general.shortcut.reset": "恢复为双击 ⌥",
        "general.shortcut.disable": "关闭",
        "general.shortcut.needModifier": "需含 ⌘、⌥ 或 ⌃——单个键太容易误触。",
        "general.shortcut.reserved": "⌘, 已用于打开设置，请换一个。",
        "placement.all": "所有显示器",
        "placement.builtIn": "内建显示器",
        "dock.hidden": "隐藏",
        "dock.shown": "显示",

        "about.update.to": "更新到 %@",
        "about.updating": "更新中…",
        "about.updateFailed": "更新失败——请到发布页手动下载",
        "about.github": "GitHub",
        "about.releases": "发布页",
        "about.privacy": "隐私政策",
        "about.whatsNew": "新功能",
        "about.group.updates": "更新",
        "about.group.more": "更多",
        "about.checkForUpdates": "检查更新",
        "about.checking": "检查中…",
        "about.upToDate": "已是最新版本",

        "whatsnew.title": "新功能",
        "whatsnew.back": "返回输入",
        "whatsnew.currentBadge": "当前版本",
        "whatsnew.cue": "新功能",
        "whatsnew.section.features": "新功能",
        "whatsnew.section.improvements": "改进",
        "whatsnew.section.fixes": "问题修复",
        "whatsnew.empty": "暂时无法获取更新说明。",
        "whatsnew.viewReleases": "查看发布页",

        "input.placeholder": "随便打点什么…",
        "input.saving": "保存中…",
        "input.copiedPrefix": "已复制：%@",
        "hint.ask": "问问",
        "hint.note": "记下",
        "hint.remind": "提醒",

        // First-run onboarding (see OnboardingService / OnboardingView).
        "onboarding.gestureHint": "悬停 — 或 ⌘,",
        "onboarding.gestureHint.noNotch": "⌘, 打开",
        "onboarding.back": "上一步",
        "onboarding.next": "下一步",
        "onboarding.skip": "跳过",
        // Step 1 — welcome
        "onboarding.welcome.headline": "你只管打字，它来分拣。",
        "onboarding.welcome.sub": "随手打出脑子里的想法，Notchi 替你分到三处：",
        "onboarding.welcome.ask": "问题交给 AI。",
        "onboarding.welcome.note": "想记下的，进备忘录。",
        "onboarding.welcome.remind": "带时间的，进提醒事项。",
        // Step 2 — connect a model
        "onboarding.connect.title": "连接一个模型",
        "onboarding.connect.lead": "“问问”需要一个 AI 模型。记笔记和提醒不用它也能用。",
        "onboarding.connect.or.button": "连接 OpenRouter — 免费",
        "onboarding.connect.or.short": "OpenRouter — 免费",
        "onboarding.connect.or.subtitle": "免费，登录一次即可",
        "onboarding.connect.byok": "有自己的密钥？点这里粘贴",
        "onboarding.connect.byok.short": "粘贴密钥",
        "onboarding.connect.byok.subtitle": "OpenAI、Anthropic 等",
        "onboarding.connect.connected": "已连接",
        "onboarding.connect.connecting": "连接中…",
        "onboarding.connect.privacy": "",
        // Step 2b — paste a key (in-guide, not Settings)
        "onboarding.paste.title": "粘贴密钥",
        "onboarding.paste.lead": "选择你的服务商，粘贴它的 API 密钥。之后可以在设置里修改。",
        "onboarding.paste.provider": "服务商",
        "onboarding.paste.field": "粘贴你的 %@ 密钥",
        "onboarding.paste.get": "获取密钥",
        "onboarding.paste.save": "保存并继续",
        "onboarding.paste.invalid": "这看起来不是一个有效的密钥。",
        // Step 3 — try it
        "onboarding.try.title": "搞定",
        "onboarding.try.lead": "随时悬停刘海就能唤出 Notchi。这是你的第一个问题：",
        "onboarding.try.example": "咖啡因要多久才起效？",
        "onboarding.try.ask": "问它",
        "recur.daily": " · 每天",
        "recur.weekly": " · 每周",
        "recur.weeklyOn": " · 每周 · %@",
        "recur.monthly": " · 每月",

        "preset.summarize": "总结",
        "preset.keyPoints": "提炼要点",
        "preset.proofread": "校对",
        "preset.rewrite": "改写",
        "preset.friendly": "更亲切",
        "preset.professional": "更专业",
        "preset.concise": "更简洁",
        "preset.translate": "翻译",

        "capture.note": "记下",
        "capture.remind": "提醒",

        "recent.manage": "更多",
        "recent.collapse": "返回",
        "recent.settings": "设置（⌘,）",
        "recent.menu.settings": "设置",
        "recent.menu.seeAll": "查看全部历史",
        "history.window.title": "历史记录",
        "history.window.search": "搜索历史",
        "history.window.filter.all": "全部",
        "history.window.filter.ask": "问答",
        "history.window.filter.notes": "备忘录",
        "history.window.filter.reminders": "提醒事项",
        "history.window.count": "%lld 条",
        "history.window.empty": "还没有历史记录",
        "history.window.empty.filtered": "没有匹配项",
        "history.window.detail.empty": "选择一条对话",
        "history.detail.you": "你",
        "history.detail.assistant": "回答",
        "recent.clear": "清空",
        "recent.filter": "筛选…",
        "recent.filter.note": "记下",
        "recent.filter.remind": "提醒",
        "recent.filter.ask": "问问",
        "recent.filter.clear": "清除筛选",
        "recent.badge.notes": "备忘录",
        "recent.badge.reminders": "提醒事项",
        "recent.hint.note": "在「备忘录」中打开这条笔记",
        "recent.hint.reminder": "在「提醒事项」中打开这条提醒",
        "recent.hint.ask": "重新打开这段对话",
        "recent.answering": "回答中…",
        "recent.delete": "删除",
        "recent.recent": "最近",

        "clear.title": "清空最近记录？",
        "clear.body": "这会永久删除所有最近的提问，无法撤销。",
        "clear.cancel": "取消",
        "clear.confirm": "清空记录",

        "result.setUpModel": "先配置你的模型",
        "result.basedOnCopied": "结合了你复制的内容",
        "result.you": "你",
        "result.newConversation": "新对话（←）",
        "result.pin": "固定（⌘P）",
        "result.unpin": "取消固定（⌘P）",
        "result.copiedToClipboard": "已复制到剪贴板",
        "result.copyAnswer": "复制回答（⌘C）",
        "result.copyMarkdown": "复制为 Markdown（⌘C）",
        "result.copyPlainText": "复制为纯文本",
        "result.regenerate": "重新回答（⌘R）",
        "result.regenerate.menu": "重新回答（⌘R）",
        "result.regenerate.with": "换模型重答…",
        "result.regenerate.current": "%@（当前）",
        "result.copyToContinue": "复制对话，去 ChatGPT 或 Claude 接着聊",
        "result.model": "模型",
        "result.modelUsed": "由 %@ 回答",
        "result.followUp": "继续追问…",
        "clip.imageCopied": "已复制图片",
        "bubble.showMore": "展开",
        "bubble.showLess": "收起",
        "ask.visionHint": "当前模型可能不支持图片输入——请换用支持视觉的模型。",

        "feedback.addedNotesClip": "已存入备忘录 · 含剪贴板内容",
        "feedback.addedNotes": "已存入备忘录",
        "feedback.notesFailed": "存入备忘录失败，请重试。",
        "feedback.addedFile": "已存入笔记文件夹",
        "feedback.addedFileClip": "已存入笔记文件夹 · 含剪贴板内容",
        "feedback.fileFailed": "笔记文件没写上，再试一次。",
        "feedback.addedReminders": "已加入提醒事项%@",
        "feedback.remindersFailed": "加入提醒事项失败，请重试。",
        "feedback.savePreservedLine": "%1$@\n%2$@",
        "error.generic": "出了点问题，请重试。",
        "error.retry": "重试",
        "error.openSettings": "打开设置",
        "error.interrupted": "\n\n——连接中断，回答可能不完整。",
        "error.truncated": "\n\n——回答被长度限制截断了。",
        "notify.answerReady.title": "回答好了",

        "time.justNow": "刚刚",
        "time.minutesAgo": "%lld 分钟前",
        "time.hoursAgo": "%lld 小时前",
        "time.daysAgo": "%lld 天前",

        "notes.error.permission": "请在「系统设置 → 隐私与安全性 → 自动化」中允许访问「备忘录」。",
        "notes.error.unavailable": "无法连接「备忘录」，请重试。",
        "notes.file.error.folder": "笔记文件夹创建失败，去设置里检查一下位置。",
        "notes.error.fallback": "存入备忘录失败。",
        "reminders.error.permission": "请在「系统设置 → 隐私与安全性 → 提醒事项」中允许访问。",
        "reminders.error.noList": "找不到提醒事项列表。请先打开一次「提醒事项」App，然后重试。",

        "service.error.http": "%@ 请求失败（HTTP %lld）。",
        "service.error.malformed": "%@ 返回了异常响应。",
        "stub.noModel": "还没连接模型——现在是离线占位回复。打开设置（⌘,），连接一个免费的 OpenRouter 账号（或粘贴 API 密钥）就能拿到实时回答。",

        "or.error.noPort": "无法为登录回调打开本地端口",
        "or.error.cancelled": "已在浏览器中取消登录",
        "or.error.noKey": "OpenRouter 没有签发密钥——请再连一次",
        "or.error.unreachable": "无法连接 OpenRouter——请检查网络后重试",

        "or.page.connected.title": "已连接",
        "or.page.connected.line": "Notchi 已连接——可以关掉这个标签页了。",
        "or.page.cancelled.title": "已取消",
        "or.page.cancelled.line": "登录已取消。关掉这个标签页，回 Notchi 再试一次就好。",

        // 智能体工具活动（工具运行时显示在流式回答上方）
        "agent.activity.search": "正在联网搜索…",
        "agent.activity.refining": "正在进一步查证…",
        "agent.activity.composing": "正在整理搜索结果…",
        "agent.activity.readingPage": "正在阅读 %@…",
        "agent.activity.clipboard": "正在读取剪贴板…",
        "agent.activity.time": "正在查看时间…",
        "agent.activity.calc": "正在计算…",
        "agent.activity.askUser": "等你选一下…",
        "agent.activity.working": "处理中…",
        "agent.activity.runningTool": "正在运行 %@…",
        "agent.activity.thinking": "思考中…",

        "source.badge.help": "来源",
        "source.badge.fallback": "来源",
    ]

    // MARK: 繁體中文
    static let zhHant: [String: String] = [
        "appLang.system": "跟隨系統",

        "settings.title": "設定",
        "settings.back": "返回輸入",
        "sidebar.model": "模型",
        "sidebar.search": "搜尋",
        "sidebar.notes": "筆記",
        "sidebar.tools": "工具",
        "sidebar.general": "一般",
        "sidebar.about": "關於",

        "model.provider": "服務商",
        "model.provider.noSearchGroup": "無內建聯網搜尋",
        "model.provider.noSearchReason": "沒有原生聯網搜尋。在 設定 → 搜尋 裡填搜尋密鑰即可啟用。",
        "model.apiKey": "API 金鑰",
        "model.pasteKey": "貼上你的 API 金鑰",
        "search.backend": "搜尋後端",
        "search.backend.native": "預設",
        "search.backend.keenable": "Keenable",
        "search.backend.exa": "Exa",
        "model.keenableApiKey": "Keenable 金鑰",
        "model.keenablePasteKey": "貼上你的 Keenable API 金鑰",
        "model.keenableHint": "一個面向所有模型的搜尋後端。在上方選擇使用哪個後端。取得金鑰 ",
        "model.keenableHint.host": "keenable.ai",
        "model.exaApiKey": "Exa 金鑰",
        "model.exaPasteKey": "貼上你的 Exa API 金鑰",
        "model.exaHint": "帶全文支撐的搜尋後端。在上方選擇使用哪個後端。取得金鑰 ",
        "model.exaHint.host": "exa.ai",
        "model.test": "測試",
        "model.cancel": "取消",
        "model.change": "更改",
        "model.save": "儲存",
        "model.saved": "已儲存",
        "model.account": "帳號",
        "model.disconnect": "中斷連接",
        "model.connecting": "連接中…",

        // Codex（ChatGPT）—— 免金鑰，沿用 `codex login` 登入。
        "codex.status.connected": "已透過 ChatGPT 登入",
        "codex.status.getCodex": "取得 Codex",
        "codex.action.reauthorize": "重新授權",
        "codex.action.signIn": "登入",
        "codex.status.hint.ready": "Notch 會呼叫本機的 Codex CLI，用量計入你的 ChatGPT 方案。",
        "codex.status.hint.login": "已安裝 Codex。請在終端機執行 `codex login` 登入後，重新開啟此處。",
        "codex.status.hint.install": "安裝 Codex CLI 並執行 `codex login`，然後重新開啟設定。",
        "codex.error.notInstalled": "找不到 Codex CLI。請先安裝並執行 `codex login`。",
        "codex.error.notSignedIn": "尚未登入 Codex。請在終端機執行 `codex login`。",
        "codex.error.noOutput": "Codex 未回傳內容，請重試。",
        "codex.error.spawnFailed": "無法啟動 Codex CLI。",
        "codex.error.runFailed": "Codex 執行失敗：",
        "model.finishSignIn": "去瀏覽器裡完成登入…",
        "model.pasteInstead": "改用金鑰貼上",
        "model.connectOpenRouter": "連接 OpenRouter",
        "model.label": "模型",
        "model.default": "預設（%@）",
        "model.freeFeatured": "高質量免費模型",
        "model.freeMore": "更多免費模型",
        "model.picker.search": "搜尋…",
        "model.picker.allProviders": "全部供應商",
        "model.picker.providers": "供應商",
        "model.picker.someProviders": "%lld 家供應商",
        "model.picker.configured": "已設定",
        "model.picker.unconfigured": "未設定金鑰",
        "model.picker.default": "預設",
        "model.picker.empty": "沒有符合的模型",
        "model.picker.addKey": "去填金鑰",
        "model.picker.showAll": "展開全部 %lld 個模型",
        "model.picker.showLess": "收合",
        "model.picker.speed": "速度",
        "model.picker.intelligence": "智慧程度",
        "model.picker.context": "上下文",
        "model.picker.vision": "視覺",
        "model.picker.tools": "工具呼叫",
        "model.picker.reasoning": "推理",
        "model.picker.webSearch": "聯網搜尋",
        "model.picker.noWebSearch": "無聯網搜尋",
        "model.keys.section": "服務商與金鑰",
        "model.setup.needed": "設定 %@ 後即可開始提問。",
        "model.pending.hint": "填入 %@ 金鑰後即可使用 %@。",
        "model.footer.openrouter.pre": "免費使用——點「連接」會帶你登入 ",
        "model.footer.openrouter.host": "openrouter.ai",
        "model.footer.openrouter.post": "，金鑰存在這台 Mac 上。免費模型每天有上限，儲值一點額度就能提高。",
        "model.footer.byok.pre": "只存在這台 Mac 上。去這裡拿金鑰：",
        "model.footer.byok.post": "。",
        "model.footer.env": "正在使用來自 %@ 環境變數的金鑰，它會覆蓋這裡的設定。",

        "conn.ok": "金鑰已驗證",
        "conn.missingKey": "請輸入金鑰",
        "conn.unauthorized": "金鑰無效",
        "conn.serverError": "伺服器錯誤（%lld）",
        "conn.offline": "無網路連線",
        "conn.timedOut": "請求逾時",
        "conn.unavailable": "此服務商不支援測試",
        "conn.unexpected": "回應異常",

        "translation.pref1": "首選語言一",
        "translation.pref2": "首選語言二",
        "translation.hint": "譯成語言一；原文已是語言一時譯成語言二。",

        "general.showOn": "顯示於",
        "general.placement.footer": "外接螢幕會得到一個選單列高度的小島。",
        "general.dockIcon": "Dock 圖示",
        "general.dockIcon.footer": "隱藏後它就是個純浮層——用 ⌘, 或把游標移到瀏海上來喚出。",
        "general.launchAtLogin": "開機時啟動",
        "general.fullscreenAutoHide": "全螢幕時隱藏",
        "general.fullscreenAutoHide.hint": "當某個應用全螢幕佔據它所在的螢幕時，把小島收起來。僅影響外接螢幕上的虛擬瀏海。",
        "general.noteDestination": "筆記保存到",
        "general.noteDestination.hint": "存入 Apple 備忘錄，或存成你指定資料夾裡的 Markdown 純文字（每天一個檔案）。",
        "general.noteFolder.choose": "選擇…",
        "noteDest.appleNotes": "Apple 備忘錄",
        "noteDest.folder": "Markdown 資料夾",
        "general.customInstructions": "自訂指令",
        "general.customInstructions.placeholder": "例如：始終用繁體中文回答",
        "general.customInstructions.hint": "拼進每次提問的一句偏好，比如「優先給程式碼」「用公制單位」。",
        "general.quickTools": "快捷工具",
        "general.quickTools.count": "已選 %lld 個",
        "general.copySense": "複製感知",
        "general.copySense.hint": "複製筆記或提醒後，再按一次 ⌘C 直接存好。",
        "sense.note": "To Save",
        "sense.reminder": "To Save",
        "sense.saved": "已存入",
        "sense.failed": "沒存上",
        "general.appLanguage": "語言",
        "general.shortcut": "快捷鍵",
        "general.shortcut.recording": "按下快捷鍵…",
        "general.shortcut.off": "關閉",
        "general.shortcut.reset": "還原為雙擊 ⌥",
        "general.shortcut.disable": "關閉",
        "general.shortcut.needModifier": "需含 ⌘、⌥ 或 ⌃——單個鍵太容易誤觸。",
        "general.shortcut.reserved": "⌘, 已用於開啟設定，請換一個。",
        "placement.all": "所有螢幕",
        "placement.builtIn": "內建螢幕",
        "dock.hidden": "隱藏",
        "dock.shown": "顯示",

        "about.update.to": "更新到 %@",
        "about.updating": "更新中…",
        "about.updateFailed": "更新失敗——請到發佈頁手動下載",
        "about.github": "GitHub",
        "about.releases": "發佈頁",
        "about.privacy": "隱私政策",
        "about.whatsNew": "新功能",
        "about.group.updates": "更新",
        "about.group.more": "更多",
        "about.checkForUpdates": "檢查更新",
        "about.checking": "檢查中…",
        "about.upToDate": "已是最新版本",

        "whatsnew.title": "新功能",
        "whatsnew.back": "返回輸入",
        "whatsnew.currentBadge": "目前版本",
        "whatsnew.cue": "新功能",
        "whatsnew.section.features": "新功能",
        "whatsnew.section.improvements": "改進",
        "whatsnew.section.fixes": "問題修復",
        "whatsnew.empty": "暫時無法取得更新說明。",
        "whatsnew.viewReleases": "查看發佈頁",

        "input.placeholder": "隨便打點什麼…",
        "input.saving": "儲存中…",
        "input.copiedPrefix": "已複製：%@",
        "hint.ask": "問問",
        "hint.note": "記下",
        "hint.remind": "提醒",

        // First-run onboarding (see OnboardingService / OnboardingView).
        "onboarding.gestureHint": "懸停 — 或 ⌘,",
        "onboarding.gestureHint.noNotch": "⌘, 開啟",
        "onboarding.back": "上一步",
        "onboarding.next": "下一步",
        "onboarding.skip": "跳過",
        // Step 1 — welcome
        "onboarding.welcome.headline": "你只管打字，它來分揀。",
        "onboarding.welcome.sub": "隨手打出腦中的想法，Notchi 替你分到三處：",
        "onboarding.welcome.ask": "問題交給 AI。",
        "onboarding.welcome.note": "想記下的，進備忘錄。",
        "onboarding.welcome.remind": "帶時間的，進提醒事項。",
        // Step 2 — connect a model
        "onboarding.connect.title": "連接一個模型",
        "onboarding.connect.lead": "「問問」需要一個 AI 模型。記筆記和提醒不用它也能用。",
        "onboarding.connect.or.button": "連接 OpenRouter — 免費",
        "onboarding.connect.or.short": "OpenRouter — 免費",
        "onboarding.connect.or.subtitle": "免費，登入一次即可",
        "onboarding.connect.byok": "有自己的密鑰？點這裡貼上",
        "onboarding.connect.byok.short": "貼上密鑰",
        "onboarding.connect.byok.subtitle": "OpenAI、Anthropic 等",
        "onboarding.connect.connected": "已連接",
        "onboarding.connect.connecting": "連接中…",
        "onboarding.connect.privacy": "",
        // Step 2b — paste a key (in-guide, not Settings)
        "onboarding.paste.title": "貼上密鑰",
        "onboarding.paste.lead": "選擇你的服務商，貼上它的 API 密鑰。之後可以在設定裡修改。",
        "onboarding.paste.provider": "服務商",
        "onboarding.paste.field": "貼上你的 %@ 密鑰",
        "onboarding.paste.get": "取得密鑰",
        "onboarding.paste.save": "儲存並繼續",
        "onboarding.paste.invalid": "這看起來不是一個有效的密鑰。",
        // Step 3 — try it
        "onboarding.try.title": "搞定",
        "onboarding.try.lead": "隨時懸停瀏海就能喚出 Notchi。這是你的第一個問題：",
        "onboarding.try.example": "咖啡因要多久才起效？",
        "onboarding.try.ask": "問它",
        "recur.daily": " · 每天",
        "recur.weekly": " · 每週",
        "recur.weeklyOn": " · 每週 · %@",
        "recur.monthly": " · 每月",

        "preset.summarize": "總結",
        "preset.keyPoints": "提煉要點",
        "preset.proofread": "校對",
        "preset.rewrite": "改寫",
        "preset.friendly": "更親切",
        "preset.professional": "更專業",
        "preset.concise": "更簡潔",
        "preset.translate": "翻譯",

        "capture.note": "記下",
        "capture.remind": "提醒",

        "recent.manage": "更多",
        "recent.collapse": "返回",
        "recent.settings": "設定（⌘,）",
        "recent.menu.settings": "設定",
        "recent.menu.seeAll": "查看全部歷史",
        "history.window.title": "歷史紀錄",
        "history.window.search": "搜尋歷史",
        "history.window.filter.all": "全部",
        "history.window.filter.ask": "問答",
        "history.window.filter.notes": "備忘錄",
        "history.window.filter.reminders": "提醒事項",
        "history.window.count": "%lld 筆",
        "history.window.empty": "還沒有歷史紀錄",
        "history.window.empty.filtered": "沒有符合項目",
        "history.window.detail.empty": "選擇一則對話",
        "history.detail.you": "你",
        "history.detail.assistant": "回答",
        "recent.clear": "清空",
        "recent.filter": "篩選…",
        "recent.filter.note": "記下",
        "recent.filter.remind": "提醒",
        "recent.filter.ask": "問問",
        "recent.filter.clear": "清除篩選",
        "recent.badge.notes": "備忘錄",
        "recent.badge.reminders": "提醒事項",
        "recent.hint.note": "在「備忘錄」中開啟這則筆記",
        "recent.hint.reminder": "在「提醒事項」中開啟這則提醒",
        "recent.hint.ask": "重新開啟這段對話",
        "recent.answering": "回答中…",
        "recent.delete": "刪除",
        "recent.recent": "最近",

        "clear.title": "清空最近記錄？",
        "clear.body": "這會永久刪除所有最近的提問，無法復原。",
        "clear.cancel": "取消",
        "clear.confirm": "清空記錄",

        "result.setUpModel": "先設定你的模型",
        "result.basedOnCopied": "結合了你複製的內容",
        "result.you": "你",
        "result.newConversation": "新對話（←）",
        "result.pin": "固定（⌘P）",
        "result.unpin": "取消固定（⌘P）",
        "result.copiedToClipboard": "已複製到剪貼簿",
        "result.copyAnswer": "複製回答（⌘C）",
        "result.copyMarkdown": "複製為 Markdown（⌘C）",
        "result.copyPlainText": "複製為純文字",
        "result.regenerate": "重新回答（⌘R）",
        "result.regenerate.menu": "重新回答（⌘R）",
        "result.regenerate.with": "換模型重答…",
        "result.regenerate.current": "%@（目前）",
        "result.copyToContinue": "複製對話，去 ChatGPT 或 Claude 接著聊",
        "result.model": "模型",
        "result.modelUsed": "由 %@ 回答",
        "result.followUp": "繼續追問…",
        "clip.imageCopied": "已複製圖片",
        "bubble.showMore": "展開",
        "bubble.showLess": "收起",
        "ask.visionHint": "目前模型可能不支援圖片輸入——請換用支援視覺的模型。",

        "feedback.addedNotesClip": "已存入備忘錄 · 含剪貼簿內容",
        "feedback.addedNotes": "已存入備忘錄",
        "feedback.notesFailed": "存入備忘錄失敗，請重試。",
        "feedback.addedFile": "已存入筆記資料夾",
        "feedback.addedFileClip": "已存入筆記資料夾 · 含剪貼簿內容",
        "feedback.fileFailed": "筆記檔案沒寫上，再試一次。",
        "feedback.addedReminders": "已加入提醒事項%@",
        "feedback.remindersFailed": "加入提醒事項失敗，請重試。",
        "feedback.savePreservedLine": "%1$@\n%2$@",
        "error.generic": "出了點問題，請重試。",
        "error.retry": "重試",
        "error.openSettings": "打開設定",
        "error.interrupted": "\n\n——連線中斷，回答可能不完整。",
        "error.truncated": "\n\n——回答被長度限制截斷了。",
        "notify.answerReady.title": "回答好了",

        "time.justNow": "剛剛",
        "time.minutesAgo": "%lld 分鐘前",
        "time.hoursAgo": "%lld 小時前",
        "time.daysAgo": "%lld 天前",

        "notes.error.permission": "請在「系統設定 → 隱私權與安全性 → 自動化」中允許存取「備忘錄」。",
        "notes.error.unavailable": "無法連接「備忘錄」，請重試。",
        "notes.file.error.folder": "筆記資料夾建立失敗，去設定裡檢查一下位置。",
        "notes.error.fallback": "存入備忘錄失敗。",
        "reminders.error.permission": "請在「系統設定 → 隱私權與安全性 → 提醒事項」中允許存取。",
        "reminders.error.noList": "找不到提醒事項列表。請先開啟一次「提醒事項」App，然後重試。",

        "service.error.http": "%@ 請求失敗（HTTP %lld）。",
        "service.error.malformed": "%@ 回傳了異常回應。",
        "stub.noModel": "還沒連接模型——現在是離線佔位回覆。打開設定（⌘,），連接一個免費的 OpenRouter 帳號（或貼上 API 金鑰）就能拿到即時回答。",

        "or.error.noPort": "無法為登入回呼開啟本地連接埠",
        "or.error.cancelled": "已在瀏覽器中取消登入",
        "or.error.noKey": "OpenRouter 沒有簽發金鑰——請再連一次",
        "or.error.unreachable": "無法連接 OpenRouter——請檢查網路後重試",

        "or.page.connected.title": "已連接",
        "or.page.connected.line": "Notchi 已連接——可以關掉這個分頁了。",
        "or.page.cancelled.title": "已取消",
        "or.page.cancelled.line": "登入已取消。關掉這個分頁，回 Notchi 再試一次就好。",

        // 智慧代理工具活動（工具執行時顯示在串流回答上方）
        "agent.activity.search": "正在聯網搜尋…",
        "agent.activity.refining": "正在進一步查證…",
        "agent.activity.composing": "正在整理搜尋結果…",
        "agent.activity.readingPage": "正在閱讀 %@…",
        "agent.activity.clipboard": "正在讀取剪貼簿…",
        "agent.activity.time": "正在查看時間…",
        "agent.activity.calc": "正在計算…",
        "agent.activity.askUser": "等你選一下…",
        "agent.activity.working": "處理中…",
        "agent.activity.runningTool": "正在執行 %@…",
        "agent.activity.thinking": "思考中…",

        "source.badge.help": "來源",
        "source.badge.fallback": "來源",
    ]
}
