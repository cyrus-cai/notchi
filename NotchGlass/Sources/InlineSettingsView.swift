import AppKit
import Carbon.HIToolbox
import Carbon.OpenScripting
import Contacts
import CoreLocation
import EventKit
import Photos
import SwiftUI
import UserNotifications

/// The protected capabilities Notchi's tools use, as listed in General.
private enum SystemPermission: CaseIterable, Hashable {
    case accessibility, screenRecording, notifications, location, calendar, reminders, contacts, photos
    case notes, mail, music

    var labelKey: String {
        switch self {
        case .accessibility:   return "permissions.accessibility"
        case .screenRecording: return "permissions.screenRecording"
        case .notifications:   return "permissions.notifications"
        case .location:        return "permissions.location"
        case .calendar:        return "permissions.calendar"
        case .reminders:       return "permissions.reminders"
        case .contacts:        return "permissions.contacts"
        case .photos:          return "permissions.photos"
        case .notes:           return "permissions.notes"
        case .mail:            return "permissions.mail"
        case .music:           return "permissions.music"
        }
    }

    /// The app an Automation (Apple Events) permission is granted for.
    var automationTarget: String? {
        switch self {
        case .notes: return "com.apple.Notes"
        case .mail:  return "com.apple.mail"
        case .music: return "com.apple.Music"
        default:     return nil
        }
    }

    /// The Privacy & Security pane anchor. Notifications has its own pane.
    var privacyAnchor: String {
        switch self {
        case .accessibility:         return "Privacy_Accessibility"
        case .screenRecording:       return "Privacy_ScreenCapture"
        case .notifications:         return ""
        case .location:              return "Privacy_LocationServices"
        case .calendar:              return "Privacy_Calendars"
        case .reminders:             return "Privacy_Reminders"
        case .contacts:              return "Privacy_Contacts"
        case .photos:                return "Privacy_Photos"
        case .notes, .mail, .music:  return "Privacy_Automation"
        }
    }
}

/// A common vocabulary for the TCC-backed capabilities shown in General. Some
/// frameworks use different native enums, but the settings UI only needs these
/// user-facing states.
private enum SettingsPermissionStatus: Equatable {
    case checking
    case notDetermined
    case denied
    /// Partly granted: Calendar write-only, Photos or Contacts limited to a
    /// selection.
    case limited
    case granted
    case unavailable

    var label: String {
        switch self {
        case .checking:      return L("permissions.status.checking")
        case .notDetermined: return L("permissions.status.notGranted")
        case .denied:        return L("permissions.status.denied")
        case .limited:       return L("permissions.status.limited")
        case .granted:       return L("permissions.status.granted")
        case .unavailable:   return L("permissions.status.unavailable")
        }
    }

    var pillLabel: String {
        switch self {
        case .notDetermined, .unavailable: return L("permissions.action.allow")
        case .denied:                      return L("permissions.action.settings")
        case .checking, .granted, .limited: return label
        }
    }
}

/// Permission status row trailing view: granted/checking renders as a
/// non-interactive secondary badge, while a missing permission renders as an
/// actionable outline button.
private struct PermissionStatusPill: View {
    let status: SettingsPermissionStatus
    let action: () -> Void

    var body: some View {
        if status == .granted || status == .checking {
            SettingsBadge(text: status.pillLabel, variant: .secondary)
        } else {
            SettingsButton(title: status.pillLabel, variant: .outline, size: .sm, action: action)
        }
    }
}

/// A step action inside setup flows: renders as a secondary `SettingsButton`
/// when actionable, or a quiet `SettingsBadge` while in a passive status.
private struct TelegramStepPill: View {
    let title: String
    let action: (() -> Void)?

    init(title: String, action: (() -> Void)?) {
        self.title = title
        self.action = action
    }

    var body: some View {
        if let action {
            SettingsButton(title: title, variant: .secondary, size: .sm, action: action)
        } else {
            SettingsBadge(text: title, variant: .secondary)
        }
    }
}

/// One row of the connectors table: logo tile, name, then the status column —
/// Connect, a check once signed in (Disconnect on hover), Cancel while the
/// browser sign-in is open. A failure's reason goes under the name.
private struct ConnectorTableRow: View {
    let connector: MCPConnector
    @ObservedObject var auth: MCPConnectorAuth
    @ObservedObject var hub: MCPHub
    var onConnect: () -> Void
    @Environment(\.settingsMetrics) private var metrics
    @State private var hovering = false

    var body: some View {
        let phase = auth.phase(connector.id)
        let connected = auth.connected.contains(connector.id)
        let server = hub.servers.first { $0.name == connector.id }
        HStack(alignment: .center, spacing: 10) {
            tile
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(connector.title)
                        .font(.sf(Tokens.TypeSize.form, weight: .regular))
                        .foregroundStyle(Tokens.text1)
                        .lineLimit(1)
                    if connector.composio {
                        SettingsBadge(text: "Third-party", variant: .secondary)
                    }
                }
                if case .code(let code) = phase {
                    note(L("connector.code", code), color: Tokens.text3)
                } else if phase == .waiting {
                    note(L("connector.waiting"), color: Tokens.text3)
                } else if case .failed(let message) = phase {
                    note(message, color: Tokens.danger)
                } else if connected, case .failed(let reason)? = server?.status {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        note(reason, color: Tokens.text3)
                        UnderlineLink(title: L("mcp.retry")) { hub.restart(connector.id) }
                            .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if connected {
                    if hovering {
                        SettingsButton(title: L("connector.disconnect"), variant: .ghost, size: .sm) {
                            auth.disconnect(connector)
                        }
                    } else {
                        Image(icon: "checkmark")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Tokens.text2)
                            .padding(.trailing, 10)
                    }
                } else if auth.isWaiting(connector.id) {
                    SettingsButton(title: L("connector.cancel"), variant: .outline, size: .sm) {
                        auth.cancel()
                    }
                } else {
                    SettingsButton(title: L("connector.connect"), variant: .secondary, size: .sm) {
                        onConnect()
                    }
                }
            }
            .frame(width: 104, alignment: .trailing)
        }
        .frame(minHeight: 40)
        .padding(.vertical, phase == .idle && !(connected && isFailed(server)) ? 0 : 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }

    private func isFailed(_ server: MCPHub.Server?) -> Bool {
        if case .failed? = server?.status { return true }
        return false
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.sf(Tokens.TypeSize.meta))
            .foregroundStyle(color)
            .lineLimit(metrics.noteLines(2))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tile: some View {
        // Each brand's own current icon, taken from its website or Google's
        // product branding, in Assets.xcassets as ConnectorLogo-<id>.
        Image("ConnectorLogo-\(connector.id)")
            .resizable()
            .interpolation(.high)
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
    }
}

/// Settings rendered *inside* the notch panel, in place of the recent list —
/// not a separate window — wearing the panel's Liquid Glass skin so it reads as
/// part of the island. The gear and ⌘, both swap the RECENT block for
/// this; the back chevron returns to the idle prompt.
struct InlineSettingsView: View {
    @ObservedObject var model: NotchModel
    /// Respected wherever this pane animates a size or a position rather than a
    /// colour — the balance block's stepper unfolding, chiefly.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// The pane height when Settings is hosted in its own window
    /// (`SettingsWindowController`); nil inside the panel.
    @Environment(\.settingsWindowPaneHeight) private var windowPaneHeight
    private var inWindow: Bool { windowPaneHeight != nil }
    /// Spacing, widths and line limits for the frame Settings is drawn in.
    private var metrics: SettingsMetrics { inWindow ? .window : .panel }
    /// Self-update state (shared app-wide — the gear badge reads the same object).
    /// Drives the Version row: a quiet number normally, an Update action when a
    /// newer release is known.
    @ObservedObject private var updater = UpdaterService.shared
    /// The one-click OpenRouter OAuth flow. Observed so the Account row tracks
    /// its phases (waiting on the browser, exchanging, failed) live.
    @ObservedObject private var orAuth = OpenRouterAuth.shared

    /// The backend this pane configures — one the user brought (see
    /// `APIKeyStore.broughtProvider`), never Notchi. Picking Notchi on the panel
    /// does not touch it: Notchi has no key and no model choice, so these rows
    /// keep naming the vendor they were set up for.
    @State private var provider: Provider = APIKeyStore.broughtProvider
    /// The provider whose key the key section is viewing/editing. Follows
    /// `provider` while the section is closed; retargeted by the picker's
    /// "Add key" flow and by the section's own provider menu. All key-editor
    /// state below (apiKey / editingKey / saved / testResult) is scoped to this,
    /// so managing a key never hijacks the active backend.
    @State private var keyScope: Provider = APIKeyStore.broughtProvider
    @State private var apiKey: String = APIKeyStore.stored(for: APIKeyStore.broughtProvider)
    /// Empty string = "use the provider's default".
    @State private var modelID: String = APIKeyStore.storedModel(for: APIKeyStore.broughtProvider)
    @State private var saved = false
    /// False once a key is saved: the row shows a masked, read-only summary of
    /// the stored key (so screenshots never carry the full secret) until the
    /// user explicitly hits Change. Starts true only when nothing is stored.
    @State private var editingKey: Bool =
        APIKeyStore.stored(for: APIKeyStore.broughtProvider).isEmpty
            && !APIKeyStore.hasEnvOverride(for: APIKeyStore.broughtProvider)
    /// Whether Notchi is what actually answers right now. The one thing on this
    /// pane that tracks the active backend rather than the configured one: it
    /// lights the balance card's rim, and it is why a vendor with no key here is
    /// not a broken setup (something else is answering).
    @State private var notchiActive: Bool = APIKeyStore.selectedProvider.isFirstParty

    @State private var loadingModels = false

    /// Pointer over the model row — the refresh arrow rides its hover, the way the
    /// shortcut rows' reset button does.
    @State private var modelRowHovering = false

    /// A manual refresh (the arrow beside the model chip) in flight — every catalog
    /// cache bypassed at once, so this one can take a beat where the automatic
    /// refreshes never do (CLI probes spawn processes).
    @State private var refreshingModels = false

    /// A model waiting on a key: set when the user taps a keyless model in the
    /// picker. The key section opens on that provider, and the moment a key
    /// lands (paste-save or OpenRouter connect) this exact model is selected and
    /// the pending state clears — the "configure only when the pick needs it"
    /// flow. Until the key exists, nothing about the active backend changes.
    private struct PendingModel { let provider: Provider; let id: String }
    @State private var pendingModel: PendingModel?
    /// Whether the "Provider & API key" section is expanded by hand. A required
    /// setup (keyless active provider, or a pending model) forces it open
    /// regardless — see `keySection`.
    @State private var keySectionOpen = false
    /// nono's wallet. Observed rather than read once: checkout
    /// finishes in a browser, so the answer arrives from outside this view.
    @ObservedObject private var nono = NoNoAccount.shared
    /// The Notchi license row in About. Hidden while the gateway's switch is off.
    @ObservedObject private var license = NotchiLicense.shared
    @State private var enteringLicenseKey = false
    @State private var licenseKeyDraft = ""
    @State private var licenseKeyCopied = false
    /// The license landed while this row was on screen: the row stays, as a
    /// confirmation, until it leaves the screen.
    @State private var licenseJustActivated = false
    /// The purchase popup, opened from the sidebar's Buy License entry.
    @State private var licenseOfferOpen = false
    /// The window this view is drawn in, for the popup's window to hang off.
    @State private var settingsHostWindow = HostWindowBox()
    @State private var copyKeyHovering = false
    @FocusState private var licenseKeyFocused: Bool
    @FocusState private var searchKeyFocused: Bool
    /// Whether the custom-instructions field is unfolded. Collapsed at rest like
    /// the key section above it — it opens by itself only when there is already an
    /// instruction stored, so an existing preference is never hidden.
    @State private var instructionsSectionOpen = false
    /// What Notchi remembers about the user (`UserMemory`), folded like the
    /// instructions above it.
    @ObservedObject private var memory = UserMemory.shared
    @ObservedObject private var proactive = ProactiveEngine.shared
    @ObservedObject private var mcp = MCPHub.shared
    @ObservedObject private var connectorAuth = MCPConnectorAuth.shared
    @ObservedObject private var telegram = TelegramBridge.shared
    @ObservedObject private var signal = SignalBridge.shared
    @ObservedObject private var instaBox = InstaBoxAccount.shared
    @State private var telegramToken = ""
    @State private var telegramOpenedBotFather = false
    @State private var telegramSetupOpen = false
    @State private var telegramConfirmForget = false
    @State private var telegramBoardCount = NSPasteboard.general.changeCount
    @State private var signalSetupOpen = false
    @State private var signalConfirmForget = false
    @State private var signalCopiedBrew = false
    /// The open group in the connectors table. One tab shows one category's
    /// rows, so the table keeps a single heading over a short list.
    @State private var connectorCategory: MCPConnector.Category = .recommended
    @ObservedObject private var clipboardHistory = ClipboardHistory.shared
    /// A Forget waiting on its confirmation (turning Memory off deletes every file).
    @State private var memoryForgetTarget: MemoryForgetTarget?
    /// A Copy history change that deletes saved copies, waiting on its confirmation.
    @State private var clipboardConfirm: ClipboardConfirm?
    private enum ClipboardConfirm: Equatable {
        case turnOff(count: Int)
        case shorten(ClipboardRetention, count: Int)
        case clearAll(count: Int)
    }
    private struct MemoryForgetTarget: Equatable {
        /// Turning Memory off, which deletes every file.
        var turnsOff = false
    }

    /// The model catalog behind the picker — live lists, the fold, and which providers
    /// are callable. Session-wide (the panel's ⌘⇧I picker reads the same store), so a
    /// list fetched for one surface is already warm for the other.
    @ObservedObject private var catalog = ModelCatalogStore.shared

    @State private var modelPickerOpen = false

    /// The Prompt Shortcut editor uses the same model menu, but owns a separate
    /// presentation bit so opening it cannot disturb Settings' main model row.
    @State private var promptModelPickerOpen = false

    /// Connectivity-test state. `testing` drives the spinner; `testResult` is the
    /// last verdict shown under the key field (nil = nothing tested yet).
    @State private var testing = false
    @State private var testResult: ConnectivityTest.Result?

    /// True while an env var forces a key for the key section's provider — then
    /// the field is informational only, since the env override wins over typing.
    private var envOverride: Bool { APIKeyStore.hasEnvOverride(for: keyScope) }

    /// Exa search key state — a separate, provider-agnostic key (Exa is a search
    /// backend, not an LLM provider). When set, it replaces every model's built-in
    /// web search. Mirrors the provider key's edit/mask/saved lifecycle, minus the
    /// Test button and live-model coupling (there's nothing to test a search key
    /// against here, and it doesn't gate a model list).
    @State private var exaKey: String = APIKeyStore.storedExaKey()
    @State private var editingExaKey: Bool =
        APIKeyStore.storedExaKey().isEmpty && !APIKeyStore.hasExaEnvOverride()
    @State private var exaSaved = false
    /// True while `EXA_API_KEY` forces the Exa key — field is then informational.
    private var exaEnvOverride: Bool { APIKeyStore.hasExaEnvOverride() }

    /// The user's chosen search backend. Pick one and that's what
    /// runs — like the model picker, one choice with no "Default" / native fallback.
    /// `nil` only until the user (or the Search tab's first appearance) settles it on
    /// a concrete backend; `selectedBackend` fills that gap for display.
    @State private var searchBackend: APIKeyStore.SearchBackend? = APIKeyStore.preferredSearchBackend

    /// Keenable search key state — a standalone search backend, keyed (its HTTP API
    /// requires a key). Same edit/mask/saved lifecycle as the Exa row.
    @State private var keenableKey: String = APIKeyStore.storedKeenableKey()
    @State private var editingKeenableKey: Bool =
        APIKeyStore.storedKeenableKey().isEmpty && !APIKeyStore.hasKeenableEnvOverride()
    @State private var keenableSaved = false
    /// True while `KEENABLE_API_KEY` forces the key — field is then informational.
    private var keenableEnvOverride: Bool { APIKeyStore.hasKeenableEnvOverride() }

    private var canSaveKeenable: Bool {
        guard !keenableEnvOverride else { return false }
        return editingKeenableKey
            && keenableKey != APIKeyStore.storedKeenableKey()
    }

    /// The stored Keenable key rendered safe for display (same masking as Exa).
    private var maskedKeenableKey: String {
        let key = APIKeyStore.currentKeenableKey() ?? APIKeyStore.storedKeenableKey()
        guard key.count > 12 else { return String(repeating: "•", count: max(key.count, 8)) }
        return "\(key.prefix(4))••••••••\(key.suffix(4))"
    }

    /// AnySearch can run anonymously; its optional key only raises quota and
    /// concurrency limits. Start in the summary state even when no key exists so
    /// the row clearly says that anonymous access is already active.
    @State private var anySearchKey: String = APIKeyStore.storedAnySearchKey()
    @State private var editingAnySearchKey = false
    @State private var anySearchSaved = false
    private var anySearchEnvOverride: Bool { APIKeyStore.hasAnySearchEnvOverride() }

    private var canSaveAnySearch: Bool {
        guard !anySearchEnvOverride else { return false }
        return editingAnySearchKey
            && anySearchKey != APIKeyStore.storedAnySearchKey()
    }

    /// DeepSeek search has no key of its own: the row edits the DeepSeek
    /// provider key, the same one the DeepSeek model uses.
    @State private var deepSeekSearchKey: String = APIKeyStore.stored(for: .deepseek)
    @State private var editingDeepSeekSearchKey = false
    @State private var deepSeekSearchSaved = false
    private var deepSeekSearchEnvOverride: Bool { APIKeyStore.hasEnvOverride(for: .deepseek) }

    private var canSaveDeepSeekSearch: Bool {
        guard !deepSeekSearchEnvOverride else { return false }
        return editingDeepSeekSearchKey
            && deepSeekSearchKey != APIKeyStore.stored(for: .deepseek)
    }

    private var maskedDeepSeekSearchKey: String {
        let key = APIKeyStore.current(for: .deepseek) ?? ""
        guard key.count > 12 else { return String(repeating: "•", count: max(key.count, 8)) }
        return "\(key.prefix(4))••••••••\(key.suffix(4))"
    }

    private var maskedAnySearchKey: String {
        guard let key = APIKeyStore.currentAnySearchKey(), !key.isEmpty else {
            return L("model.anysearchAnonymous")
        }
        guard key.count > 12 else { return String(repeating: "•", count: max(key.count, 8)) }
        return "\(key.prefix(4))••••••••\(key.suffix(4))"
    }

    private var canSaveExa: Bool {
        guard !exaEnvOverride else { return false }
        return editingExaKey
            && exaKey != APIKeyStore.storedExaKey()
    }

    /// The stored Exa key rendered safe for display (same head/tail masking as the
    /// provider key).
    private var maskedExaKey: String {
        let key = APIKeyStore.currentExaKey() ?? APIKeyStore.storedExaKey()
        guard key.count > 12 else { return String(repeating: "•", count: max(key.count, 8)) }
        return "\(key.prefix(4))••••••••\(key.suffix(4))"
    }

    /// OpenRouter normally connects via the one-click OAuth row; this flips to the
    /// standard paste field for users who'd rather supply a key by hand.
    @State private var manualKeyEntry = false

    /// Bumped on every `.cliAvailabilityResolved` post, so a CLI account row that
    /// reads its state from a service's statics (rather than from `@State`) redraws
    /// when that state moves off a background queue — the Cursor sign-in, which
    /// finishes minutes after the click, is the case that needs it.
    @State private var cliTick = 0

    /// The custom endpoint's three fields (see `CustomProvider`). They save
    /// themselves a short pause after the last keystroke (`scheduleCustomSave`).
    @State private var customName: String = CustomProvider.name
    @State private var customURL: String = CustomProvider.baseURL
    @State private var customModel: String = CustomProvider.model
    @State private var customSaveTask: Task<Void, Never>?
    @State private var customSimple: Bool = CustomProvider.simpleMode
    /// Focus for the key field, so tapping the masked key lands the caret in it.
    @FocusState private var keyFieldFocused: Bool

    /// Whether any of the three differs from what's stored — the only state where
    /// the custom Save button lights up.
    private var canSaveCustom: Bool {
        customName.trimmingCharacters(in: .whitespacesAndNewlines) != CustomProvider.name
            || customURL.trimmingCharacters(in: .whitespacesAndNewlines) != CustomProvider.baseURL
            || customModel.trimmingCharacters(in: .whitespacesAndNewlines) != CustomProvider.model
    }

    private var canSave: Bool {
        guard !envOverride else { return false }
        // Only the API key needs an explicit Save — a model switch auto-persists,
        // so it never lights up this button.
        return editingKey
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && apiKey != APIKeyStore.stored(for: keyScope)
    }

    /// The stored key rendered safe for display: enough of the head and tail to
    /// recognize which key it is, bullets for everything in between. Short keys
    /// mask entirely rather than leak most of their characters.
    private var maskedKey: String {
        let key = APIKeyStore.current(for: keyScope) ?? APIKeyStore.stored(for: keyScope)
        guard key.count > 12 else { return String(repeating: "•", count: max(key.count, 8)) }
        return "\(key.prefix(4))••••••••\(key.suffix(4))"
    }

    /// The left-hand category list — the point of the column is that the next
    /// setting gets a home without redesigning the panel.
    enum Section: String, CaseIterable, Identifiable {
        case model = "Model"     // who answers: provider, API key, model override — and the search backend behind it
        case chat = "Chat"       // how a conversation behaves: custom instructions, lid-closed answers, cloud machine, memory, copy sensing, message sounds
        case memories = "Memories" // memory switches and Finder link to the memory folder
        case connect = "Connect" // third-party connectors
        case channels = "Channels" // other places that reach Notchi: the user's own Telegram bot
        case appearance = "Appearance" // notch style, interaction, and display placement
        case shortcuts = "Shortcuts" // editable keyboard controls, its own top-level settings category
        case general = "General" // language, app presence, note destination, permissions, + Advanced (proxy)
        case stats = "Stats"     // what the archive adds up to, and the requests behind it — read-only
        case license = "License" // the Notchi License card; its entry is pinned under the sidebar
        case about = "About"     // version + self-update
        case licenses = "Licenses" // third-party attribution and licences
        case survey = "Survey"   // the About pane's survey
        case usage = "Usage"     // Blend1 request list — reached from the wallet's links
        case pricing = "Pricing" // Blend1 per-model rates — reached from the wallet's links
        case balances = "Balances" // Blend1 gifts and purchases — reached from the wallet's links
        case privacy = "Privacy" // what happens to a Blend1 request — reached from the wallet's links
        case pages = "Pages"     // Notchi pages (*.notch.website) — reached from Chat
        case whatsNew = "WhatsNew" // the release notes — reached from About
        var id: String { rawValue }

        /// Panes whose content is a table or a browser: in the window they take
        /// the pane's full width instead of `SettingsMetrics.contentMaxWidth`.
        var fillsWindowWidth: Bool {
            self == .stats || self == .usage || self == .pricing || self == .balances
                || self == .pages
        }

        /// A sub-page rather than a category: reached from a parent pane, drawn
        /// across the whole panel, and left through the header's back pill or Esc.
        var isDetail: Bool {
            self == .licenses || self == .survey || self == .usage || self == .pricing || self == .balances
                || self == .privacy || self == .pages || self == .whatsNew
        }

        /// The section a sub-page sits under — where back (and ⎋) returns to.
        /// `nil` for the top-level categories, whose back leaves settings.
        var parent: Section? {
            switch self {
            case .licenses, .survey, .whatsNew: return .about
            case .usage, .pricing, .balances, .privacy: return .model
            case .pages:  return .chat
            default:               return nil
            }
        }

        /// The sidebar's rows: every category, minus the sub-pages — in
        /// declaration order, which is the grouping. The column is one narrow width and
        /// carries no device to draw a group with: a rule through it is heavy, and
        /// an inserted gap reads as a layout slip rather than a boundary. So the
        /// bands live in the ORDER and nowhere else — what answers and what it
        /// takes in, then how the app presents and behaves, then the two pages
        /// that only report.
        static var sidebarCases: [Section] { sidebarGroups.flatMap(\.sections) }

        /// The sidebar's groups, in order. A nil title is a group of top-level
        /// rows with no heading.
        static let sidebarGroups: [(titleKey: String?, sections: [Section])] = [
            ("settings.group.agent", [.model, .chat, .memories]),
            ("settings.group.personal", [.general, .appearance, .shortcuts]),
            ("settings.group.features", [.connect, .channels]),
            (nil, [.stats, .about]),
        ]

        /// The sidebar row's glyph.
        var icon: PhosphorIcons.Mark {
            switch self {
            case .model:      return PhosphorIcons.codeXml
            case .chat:       return PhosphorIcons.messageCircle
            case .memories:   return PhosphorIcons.brain
            case .general:    return PhosphorIcons.settings
            case .appearance: return PhosphorIcons.palette
            case .shortcuts:  return PhosphorIcons.command
            case .connect:    return PhosphorIcons.plugs
            case .channels:   return PhosphorIcons.paperPlane
            case .stats:      return PhosphorIcons.chartNoAxesColumn
            case .about:      return PhosphorIcons.userSound
            case .license:    return PhosphorIcons.key
            default:          return PhosphorIcons.settings
            }
        }

        /// Localization keys of the rows and headings on this pane, for the
        /// sidebar search.
        var searchKeys: [String] {
            switch self {
            case .model:
                return ["nono.credit", "model.byok", "model.provider", "model.label", "model.keys.section",
                        "decision.title", "sidebar.search", "search.backend"]
            case .chat:
                return ["general.customInstructions", "chat.suggestFollowUp", "proactive.title",
                        "pages.title", "capture.sources", "general.copySense"]
            case .memories:
                return ["memory.toggle", "memory.manage", "clipboardHistory.toggle",
                        "clipboardHistory.retention", "clipboardHistory.title"]
            case .general:
                return ["general.appLanguage", "general.launchAtLogin", "general.appPresence",
                        "appearance.appIcon", "general.dockIcon.toggle", "general.noteDestination",
                        "permissions.title", "general.advanced", "network.proxy"]
            case .appearance:
                return ["general.hoverSensitivity", "general.forceClickPressure",
                        "appearance.showOn",
                        "general.menuBarIcon",
                        "menuBarCard.position", "general.jevAutoPin",
                        "messageSounds"]
            case .shortcuts:
                return ["shortcuts.summon", "shortcuts.card", "shortcuts.screenshotGlobal",
                        "shortcuts.send", "shortcuts.cycleIntent", "shortcuts.recall",
                        "screenshot.destination", "shortcuts.slash", "shortcuts.copyAnswer", "shortcuts.pin",
                        "shortcuts.newChat", "shortcuts.picker"]
            case .channels:
                return ["telegram.title", "signal.title", "telegram.lid"]
            case .about:
                return ["whatsnew.title", "about.licenses"]
            default:
                return []
            }
        }

        /// Synonyms and related terms across languages for this category.
        var searchAliases: [String] {
            switch self {
            case .model:
                return ["ai", "llm", "gpt", "claude", "gemini", "deepseek", "openrouter", "openai", "anthropic",
                        "byok", "token", "billing", "credit", "balance", "top up", "pay", "wallet", "pricing", "usage",
                        "web search",
                        "模型", "供应商", "密钥", "余额", "充值", "账单", "费用", "价格", "用量", "联网",
                        "供應商", "金鑰", "餘額", "帳單", "聯網",
                        "モデル", "プロバイダ", "残高", "課金", "料金",
                        "모델", "잔액", "결제", "요금",
                        "modèle", "crédit", "solde", "facturation",
                        "modelo", "crédito", "saldo", "facturación"]
            case .chat:
                return ["conversation", "prompt", "system prompt", "instructions", "persona", "tone", "style",
                        "follow up", "suggest", "proactive", "website", "publish", "capture", "context", "copy",
                        "对话", "聊天", "提示词", "指令", "风格", "追问", "主动", "网页", "上下文", "复制",
                        "對話", "提示詞", "風格", "網頁", "複製",
                        "チャット", "プロンプト", "指示", "フォローアップ",
                        "채팅", "대화", "프롬프트", "지시",
                        "discussion", "instructions", "invites",
                        "conversación", "instrucciones"]
            case .memories:
                return ["memory", "remember", "forget", "profile", "about me", "clipboard", "copy history",
                        "paste", "pasteboard", "retention", "expire", "auto delete",
                        "记忆", "记住", "遗忘", "剪贴板", "复制历史", "粘贴", "保留", "清理",
                        "記憶", "記住", "遺忘", "剪貼簿", "複製歷史", "貼上",
                        "メモリ", "記憶", "クリップボード", "コピー履歴",
                        "메모리", "기억", "클립보드", "복사 기록",
                        "mémoire", "presse-papiers", "historique",
                        "memoria", "portapapeles", "historial"]
            case .general:
                return ["language", "locale", "startup", "boot", "autostart", "login", "icon", "dock",
                        "notes", "obsidian", "markdown", "permission", "privacy", "accessibility", "tcc",
                        "proxy", "http", "socks", "vpn", "network", "advanced",
                        "通用", "语言", "开机", "自启", "图标", "程序坞", "笔记", "权限", "隐私", "代理", "网络", "高级",
                        "一般", "語言", "開機", "圖示", "筆記", "權限", "隱私", "網路", "進階",
                        "一般", "言語", "起動", "ログイン", "権限", "プロキシ", "ネットワーク",
                        "일반", "언어", "시작", "로그인", "권한", "프록시", "네트워크",
                        "général", "langue", "démarrage", "autorisations", "réseau",
                        "general", "idioma", "inicio", "permisos", "red"]
            case .appearance:
                return ["theme", "display", "screen", "monitor", "notch", "island", "hover", "mouse",
                        "trackpad", "force click", "pressure", "haptic", "menubar", "status bar",
                        "card", "position", "pin", "sound", "audio", "sfx", "mute", "chime",
                        "外观", "显示", "屏幕", "显示器", "刘海", "悬停", "灵敏度", "按压", "触控板", "菜单栏", "位置", "置顶", "声音", "音效", "静音",
                        "外觀", "顯示", "螢幕", "顯示器", "瀏海", "懸停", "靈敏度", "選單列", "聲音", "靜音",
                        "外観", "ディスプレイ", "画面", "ノッチ", "メニューバー", "サウンド", "音", "消音",
                        "외관", "화면", "디스플레이", "메뉴 막대", "소리", "사운드", "음소거",
                        "apparence", "écran", "barre des menus", "son", "muet",
                        "apariencia", "pantalla", "barra de menús", "sonido", "silencio"]
            case .shortcuts:
                return ["hotkey", "keybind", "keyboard", "key", "shortcut", "trigger", "summon",
                        "screenshot", "capture", "send", "enter", "return", "slash", "command",
                        "快捷键", "热键", "按键", "键盘", "唤起", "截图", "发送", "命令",
                        "快捷鍵", "捷徑", "熱鍵", "按鍵", "鍵盤", "截圖",
                        "ショートカット", "ホットキー", "キーボード", "スクリーンショット",
                        "단축키", "키보드", "스크린샷",
                        "raccourci", "raccourcis", "clavier", "capture",
                        "atajo", "atajos", "teclado", "captura"]
            case .connect:
                return ["connector", "mcp", "integration", "plugin", "tool", "google", "gmail",
                        "calendar", "drive", "slack", "notion", "linear", "github", "figma", "outlook", "oauth",
                        "连接器", "集成", "插件", "工具", "第三方", "授权",
                        "連接器", "外掛", "授權",
                        "コネクタ", "プラグイン", "連携", "ツール",
                        "커넥터", "플러그인", "연동", "도구",
                        "connecteur", "connecteurs", "extension", "outils",
                        "conector", "conectores", "complemento", "herramientas"]
            case .channels:
                return ["channel", "bot", "remote", "mobile", "phone", "telegram", "tg", "signal",
                        "awake", "caffeinate", "sleep", "lid", "clamshell",
                        "频道", "通道", "机器人", "远程", "手机", "防休眠", "合盖", "唤醒",
                        "頻道", "機器人", "遠端", "防休眠",
                        "チャンネル", "ボット", "スリープ",
                        "채널", "봇", "잠자기",
                        "canal", "canaux", "veille",
                        "canal", "canales", "reposo"]
            case .stats:
                return ["stats", "statistics", "audit", "log", "history", "token", "cost", "spend",
                        "chart", "heatmap", "activity", "request", "usage",
                        "统计", "审计", "日志", "花费", "开销", "记录", "请求", "用量",
                        "統計", "稽核", "日誌", "花費", "記錄",
                        "統計", "監査", "ログ", "履歴", "使用量",
                        "통계", "감사", "로그", "기록", "사용량",
                        "statistiques", "journal", "historique",
                        "estadísticas", "registro", "historial"]
            case .about:
                return ["about", "version", "update", "upgrade", "changelog", "release notes",
                        "whats new", "license", "open source", "feedback", "survey",
                        "关于", "版本", "更新", "升级", "更新日志", "开源", "协议", "反馈",
                        "關於", "升級", "更新日誌", "開源", "回饋",
                        "バージョン", "アップデート", "更新", "リリースノート", "ライセンス",
                        "정보", "버전", "업데이트", "라이선스",
                        "à propos", "version", "mise à jour", "licence",
                        "acerca de", "versión", "actualización", "licencia"]
            default:
                return []
            }
        }

        /// Localized strings for every settings search key across ALL shipped
        /// locales, built once so a query in any language finds the same item.
        static let allLocaleStrings: [String: [String]] = {
            var keys = Set<String>()
            for s in Section.sidebarCases {
                keys.insert(s.titleKey)
                keys.formUnion(s.searchKeys)
            }
            let locales: [Localization.Locale] = [.en, .zhHans, .zhHant, .ja, .ko, .fr, .es]
            var result: [String: [String]] = [:]
            for locale in locales {
                let table = Strings.table(for: locale)
                for key in keys {
                    guard let value = table[key], !value.isEmpty else { continue }
                    if result[key]?.contains(value) != true {
                        result[key, default: []].append(value)
                    }
                }
            }
            return result
        }()

        /// Synonyms and related terms for individual setting rows.
        static func searchAliases(for key: String) -> [String] {
            switch key {
            case "nono.credit":
                return ["pay as you go", "balance", "credit", "wallet", "top up", "billing", "pricing", "usage",
                        "余额", "充值", "按量付费", "账单", "费用"]
            case "model.byok":
                return ["byok", "api key", "own key", "custom key", "自带", "密钥"]
            case "model.provider":
                return ["vendor", "openai", "anthropic", "claude", "gemini", "deepseek", "openrouter", "ollama",
                        "供应商", "提供商", "厂商"]
            case "model.label":
                return ["llm", "ai", "gpt", "claude", "gemini", "deepseek", "模型"]
            case "model.keys.section":
                return ["key", "secret", "token", "credential", "api", "密钥", "令牌"]
            case "decision.title":
                return ["jev", "router", "fast model", "small model", "决策", "路由"]
            case "sidebar.search", "search.backend":
                return ["web", "internet", "online", "exa", "keenable", "anysearch", "google", "search engine",
                        "联网", "网页搜索", "搜索引擎"]
            case "general.customInstructions":
                return ["system prompt", "prompt", "persona", "tone", "style", "instructions", "custom",
                        "提示词", "自定义指令", "回答偏好", "风格"]
            case "chat.suggestFollowUp":
                return ["follow up", "next", "suggestions", "追问", "建议"]
            case "proactive.title":
                return ["proactive", "nudge", "auto message", "greeting", "notify", "主动消息", "主动提醒"]
            case "pages.title":
                return ["website", "publish", "web page", "share", "html", "网页", "发布", "页面"]
            case "capture.sources":
                return ["context", "screen", "window", "browser", "app", "来源", "上下文", "捕获"]
            case "general.copySense":
                return ["copy", "clipboard", "paste", "selection", "smart copy", "复制建议", "剪贴板"]
            case "memory.toggle":
                return ["remember", "memory", "profile", "about me", "learn", "记忆", "记住"]
            case "memory.manage":
                return ["edit memory", "delete memory", "forget", "folder", "files", "管理记忆", "遗忘", "删除记忆"]
            case "clipboardHistory.toggle":
                return ["clipboard", "copy history", "pasteboard", "剪贴板", "复制历史"]
            case "clipboardHistory.retention":
                return ["expire", "days", "auto delete", "clean", "keep", "retention", "保留", "自动删除", "过期"]
            case "clipboardHistory.title":
                return ["clipboard", "copies", "paste", "history", "剪贴板历史", "复制记录"]
            case "general.appLanguage":
                return ["language", "locale", "english", "chinese", "japanese", "korean", "translation",
                        "语言", "中文", "英文", "翻译"]
            case "general.launchAtLogin":
                return ["startup", "autostart", "boot", "login", "开机", "自启", "启动"]
            case "general.appPresence":
                return ["dock", "menubar", "icon", "hide", "visibility", "图标", "显示"]
            case "appearance.appIcon":
                return ["logo", "icon", "badge", "应用图标"]
            case "general.dockIcon.toggle":
                return ["dock", "hide dock", "程序坞", "底部栏"]
            case "general.noteDestination":
                return ["notes", "apple notes", "obsidian", "markdown", "folder", "save", "笔记", "保存位置"]
            case "permissions.title":
                return ["privacy", "accessibility", "screen recording", "calendar", "reminders",
                        "contacts", "mail", "photos", "location", "tcc", "权限", "隐私", "辅助功能", "录屏"]
            case "general.advanced":
                return ["network", "proxy", "debug", "高级"]
            case "network.proxy":
                return ["http", "https", "socks", "socks5", "vpn", "clash", "surge", "代理", "翻墙", "网络"]
            case "general.hoverSensitivity":
                return ["hover", "mouse", "cursor", "notch", "trigger", "delay", "悬停", "灵敏度", "鼠标"]
            case "general.forceClickPressure":
                return ["force touch", "trackpad", "pressure", "press", "hold", "haptic", "按压", "触控板", "力度"]
            case "appearance.showOn":
                return ["monitor", "display", "screen", "external", "multi monitor", "显示器", "屏幕", "多屏"]
            case "general.menuBarIcon":
                return ["menubar", "status bar", "top bar", "notch", "菜单栏", "状态栏"]
            case "menuBarCard.position":
                return ["card", "corner", "top right", "placement", "location", "卡片位置", "弹窗位置"]
            case "general.jevAutoPin":
                return ["pin", "sticky", "stay open", "keep open", "自动置顶", "固定"]
            case "messageSounds":
                return ["sound", "audio", "sfx", "chime", "mute", "volume", "notification", "声音", "音效", "提示音", "静音"]
            case "shortcuts.summon":
                return ["open", "toggle", "hotkey", "launch", "唤起", "打开", "快捷键"]
            case "shortcuts.card":
                return ["panel", "top right", "card", "面板", "卡片"]
            case "shortcuts.screenshotGlobal":
                return ["screenshot", "capture", "snip", "screen", "截图", "截屏"]
            case "shortcuts.send":
                return ["enter", "return", "submit", "发送", "回车"]
            case "shortcuts.cycleIntent":
                return ["ask", "note", "remind", "mode", "switch", "切换", "模式"]
            case "shortcuts.recall":
                return ["history", "previous", "up arrow", "past", "历史", "上一条"]
            case "screenshot.destination":
                return ["screenshot", "save", "clipboard", "target", "截图目标"]
            case "shortcuts.slash":
                return ["command", "menu", "slash", "命令菜单", "斜杠"]
            case "shortcuts.copyAnswer":
                return ["copy", "clipboard", "复制回答"]
            case "shortcuts.pin":
                return ["pin", "sticky", "keep open", "置顶", "固定"]
            case "shortcuts.newChat":
                return ["new", "clear", "reset", "fresh", "新对话", "新建"]
            case "shortcuts.picker":
                return ["model", "agent", "switch", "选择模型", "切换模型"]
            case "telegram.title":
                return ["tg", "bot", "telegram", "电报", "机器人"]
            case "signal.title":
                return ["signal", "chat", "messenger"]
            case "telegram.lid":
                return ["awake", "caffeinate", "sleep", "clamshell", "closed", "防休眠", "合盖", "保持唤醒"]
            case "whatsnew.title":
                return ["changelog", "release notes", "updates", "version", "更新日志", "新功能"]
            case "about.licenses":
                return ["open source", "attribution", "credits", "开源", "许可"]
            default:
                return []
            }
        }

        /// Localization key for `title`, used to look up English fallback text during search.
        var titleKey: String {
            switch self {
            case .model:      return "sidebar.model"
            case .chat:       return "sidebar.chat"
            case .connect:    return "connect.connectors"
            case .channels:   return "connect.channels"
            case .memories:   return "memory.title"
            case .general:    return "sidebar.general"
            case .shortcuts:  return "sidebar.shortcuts"
            case .appearance: return "sidebar.appearance"
            case .stats:      return "sidebar.audit"
            case .license:    return "license.label"
            case .about:      return "sidebar.about"
            case .licenses:   return "about.licenses"
            case .survey:     return "survey.title"
            case .usage:      return "model.usage"
            case .pricing:    return "model.pricing"
            case .balances:   return "nono.balances"
            case .privacy:    return "nono.privacy.title"
            case .pages:      return "pages.title"
            case .whatsNew:   return "whatsnew.title"
            }
        }

        /// The sidebar label, localized. The raw value stays English (a stable
        /// identity); this is what the user actually reads.
        var title: String { L(titleKey) }
    }
    /// The open category, backed by `model.settingsSection` (not plain `@State`)
    /// so an App Language switch — which rebuilds this whole subtree via the
    /// root's `.id(loc.language)` — keeps the user on the pane they were on (e.g.
    /// General, where the language picker lives) instead of snapping back to Model.
    private var section: Section {
        get {
            if model.settingsSection == "Gifts" { return .balances }
            // License has no pane; its sidebar entry opens the passport popup.
            if model.settingsSection == Section.license.rawValue { return .model }
            return Section(rawValue: model.settingsSection) ?? .model
        }
        nonmutating set { model.settingsSection = newValue.rawValue }
    }

    /// The interface language — mirrors the persisted value; writes go through
    /// `selectAppLanguage`, which republishes `Localization.shared` so the whole
    /// app re-renders in the new language at once.
    @State private var appLanguage: AppLanguage = .current

    /// Which screens carry an island — mirrors the persisted value; writes go
    /// through `selectPlacement` so `AppDelegate` rebuilds panels immediately.
    @State private var placement: DisplayPlacement = .current

    /// Whether the app shows a Dock icon — mirrors the persisted value; writes go
    /// through `selectDockIconVisibility` so `AppDelegate` flips the activation
    /// policy immediately.
    @State private var dockIconVisibility: DockIconVisibility = .current

    /// The artwork shown when Notchi has a Dock / app-switcher presence. The
    /// original icon remains the persisted fallback; changing cards applies the
    /// running app image immediately.
    @State private var appIconStyle: AppIconStyle = .current
    /// Forces the Dot preview to resolve its other asset when macOS switches
    /// between light and dark while Settings is open.
    @State private var appIconAppearanceRevision = 0

    /// Whether the app shows a menu bar icon — mirrors the persisted value; writes
    /// go through `selectMenuBarIconVisibility` so `AppDelegate` adds or removes
    /// the status item immediately.
    @State private var menuBarIconVisibility: MenuBarIconVisibility = .current
    @State private var menuBarCardPlacement: MenuBarCardPlacement = .current
    @State private var screenshotDestination: ScreenshotDestination = .current

    /// Whether the app launches itself at login — seeded from the live system
    /// login-item status (`SMAppService`), not `UserDefaults`. Writes go through
    /// `selectLaunchAtLogin`, which registers/unregisters the item and reverts
    /// this optimistic flag if the OS refuses.
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled

    /// How eagerly the resting notch opens under the pointer — mirrors the
    /// persisted value; writes go through `selectHoverSensitivity`. Read live by
    /// `NotchModel.hoverEntered`, so a change applies to the very next hover.
    @State private var hoverSensitivity: HoverSensitivity = .current


    /// Which classifier Copy Sense asks (on-device / Jev) — mirrors the
    /// persisted value; writes go through `selectCopySenseEngine`. Read per
    /// copy by `NoNoAccount.usesRemoteSense`, so a change applies to the next one.
    @State private var copySenseEngine: CopySenseEngine = .current

    /// Which model makes the decision calls (Jev / the user's endpoint), and
    /// that endpoint's fields. Written through to `DecisionModel` /
    /// `DecisionEndpoint` as they change; read per call.
    @State private var decisionModel: DecisionModel = .current
    @State private var decisionURL: String = DecisionEndpoint.baseURL
    @State private var decisionKey: String = DecisionEndpoint.apiKey
    @State private var decisionModelID: String = DecisionEndpoint.model
    @State private var typeSafeKey: String = TypeSafeKey.value
    /// The decision model's Test: spinner while it runs, then the verdict.
    @State private var decisionTesting = false
    @State private var decisionTestResult: ConnectivityTest.Result?

    /// Where note captures land (Apple Notes / Markdown folder) — mirrors the
    /// persisted value; writes go through `selectNoteDestination`. Consulted per
    /// write, so the switch applies to the very next jot.
    @State private var noteDestination: NoteDestination = .current
    /// The Markdown folder as shown under the destination row (home-relative);
    /// refreshed when the chooser commits a new pick.
    @State private var notesFolderDisplay: String = FileNotesService.folderDisplayPath

    /// All editable shortcuts live together in the Shortcuts category. The
    /// summon chord re-registers globally; product actions are read live by the
    /// panel key catcher.
    @State private var summonHotKey: SummonHotKey = .current
    @State private var cardHotKey: SummonHotKey = .card
    @State private var screenshotHotKey: SummonHotKey = .screenshot
    @State private var appShortcuts: [AppShortcutAction: ShortcutChord] = AppShortcutStore.current
    /// User-authored global bindings are intentionally only a shortcut and one
    /// prompt. Their UUID exists solely so SwiftUI and AppDelegate can track rows.
    @State private var promptShortcuts: [PromptShortcut] = PromptShortcutStore.current
    /// The add flow begins with the remotely maintained starter library. It is
    /// seeded synchronously from the last manifest (or its bundled fallback),
    /// then refreshed through the manifest's existing request while visible.
    @State private var promptTemplatePickerOpen = false
    /// The summon row's "Reset to" menu card.
    @State private var summonResetMenuOpen = false
    @State private var cardResetMenuOpen = false
    @State private var screenshotResetMenuOpen = false
    @State private var promptTemplates = RemoteModelManifest.promptTemplates
    @State private var selectedPromptTemplateCategory = ""
    @State private var hoveredPromptTemplateID: String?
    @State private var promptTemplateCoverflowHovering = false
    @State private var promptTemplateCoverflowOffset: CGFloat = 0
    @State private var promptTemplateCoverflowDragOrigin: CGFloat?
    @State private var promptTemplateCoverflowTapLocked = false
    /// Only the newest snap's unlock may fire — an earlier one landing mid-run
    /// would reopen the detail tap to the click that is still arriving.
    @State private var promptTemplateCoverflowTapUnlockToken = 0
    /// The template whose detail page the picker is standing on, if any. A card
    /// is read before it is added: tapping the focused card opens this, and the
    /// card's `+` remains the shortcut past it.
    @State private var promptTemplateDetailID: String?
    /// The shortcut whose independent editor popover is open. The list itself
    /// never expands or changes height; one id also guarantees only one editor is
    /// presented at a time.
    @State private var presentedPromptShortcutID: UUID?
    /// Prompt rows stay visually still; hover reveals only the explicit Edit
    /// action in the reserved trailing slot.
    @State private var hoveredPromptShortcutID: UUID?
    @State private var hoveredShortcutRow: EditableShortcut?
    /// At most one row records at a time. Hints belong to their row so a conflict
    /// stays visually attached to the shortcut that needs attention.
    @State private var recordingShortcut: EditableShortcut?
    @State private var shortcutHints: [EditableShortcut: String] = [:]

    /// The open pane's shared label column width (see `LabelColumnWidthKey`).
    /// Zero means "not measured yet" — rows fall back to their own width for the
    /// one frame before the measurement lands. Reset on every pane switch: each
    /// category has its own set of labels, and General's longest must not stretch
    /// Appearance's column.
    @State private var labelColumnWidth: CGFloat = 0
    /// Each pane's last measured column width. A pane switch starts from this
    /// instead of 0, so a pane seen before lays out aligned on its first frame
    /// rather than drawing every control against its label for one frame.
    /// Static so it outlives closing and reopening Settings.
    @MainActor private static var labelColumnWidths: [Section: CGFloat] = [:]
    /// Which way the last pane switch moved through the category order (+1
    /// down, -1 up). Read by the pane transition.
    @State private var paneDirection: CGFloat = 1
    /// Shared by the sidebar rows so the selection capsule slides between them.
    @Namespace private var sidebarSelection
    /// The sidebar's search text.
    @State private var settingsQuery = ""
    @State private var settingsSearchFocus = false
    /// Key of the setting row currently highlighted after picking a search hit.
    @State private var highlightedSearchKey: String? = nil
    /// Key waiting for `ScrollViewReader` to scroll into view.
    @State private var pendingScrollKey: String? = nil
    /// Cancels an earlier highlight fade-out when another search hit is picked.
    @State private var searchHighlightToken = UUID()

    /// Whether the General pane's folded Advanced block is open.
    @State private var advancedSectionOpen = false
    /// Permissions are diagnostic/recovery controls rather than everyday
    /// preferences, so they stay folded until the user needs them.
    @State private var permissionsSectionOpen = false

    /// Which disclosure chip owns the pointer. Permissions and Advanced can share
    /// one pane, so a single Bool would brighten both at once.
    private enum DisclosureHover { case keys, instructions, permissions, advanced }
    @State private var hoveredDisclosure: DisclosureHover?

    /// What the proxy field resolves to right now — filled in asynchronously by
    /// `refreshProxyStatus` because detection may spawn a login shell.
    @State private var proxyStatus: String = ""
    /// `WeatherCity`'s storage; the row edits it in place.
    @AppStorage("weather.city") private var weatherCity: String = ""
    @AppStorage(NotchModel.jevAutoPinKey) private var jevAutoPinEnabled = true

    /// Live macOS authorization state for each protected capability the app
    /// uses. Missing entries read as `.checking`. Re-read while the permissions
    /// list is open, so a change made in System Settings shows without a relaunch.
    @State private var permissionStatus: [SystemPermission: SettingsPermissionStatus] = [:]

    /// The day the Stats grid's pointer is on. Lives here, not in the pane,
    /// because the readout naming it is drawn in the panel header — the pane's
    /// own corners are all spoken for.
    @State private var statsHover: StatsHoverDay?

    /// What Settings → Stats draws. `nil` until the first fold over the archive
    /// lands (see `refreshStats`); recomputed whenever the archive grows.
    @State private var stats: StatsDigest?
    /// The token odometer's reading, refreshed alongside the digest.
    @State private var statsTokens = TokenMeter.Reading(total: 0)

    /// Whether the sidebar's Audit row has been clicked; its New tag goes then.
    @State private var auditSeen = SettingsNewMarks.auditSeen
    @State private var surveyGrantSeen = SettingsNewMarks.surveyGrantSeen

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if section.isDetail && !inWindow {
                // A pushed sub-page (the Shortcuts reference under About): the
                // category column steps aside and the page takes the whole panel,
                // so it reads as one level deeper rather than another tab. The
                // way back walks out of it: the panel's back pill, or the
                // window's own circle under the traffic lights (`windowBackRow`).
                // No `.fixedSize(vertical:)` needed here: alone in the column, the
                // pane's own exact height (content, capped at Recent's) is the
                // whole page height.
                if inWindow && section == .whatsNew {
                    StandaloneWindowTitle(text: section.title)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                }
                windowBackRow()
                paneContent
                    // Exact width in the panel, for the same reason as the
                    // category pane's below.
                    .frame(width: inWindow ? nil : SettingsMetrics.panelBodyWidth - 16,
                           alignment: .topLeading)
                    // The header's own 8pt side inset, so the page starts
                    // under the back pill's left edge and ends under the pin.
                    .padding(.horizontal, 8)
                    // The window's back row carries its own air below it.
                    .padding(.top, showsWindowBackRow ? 0 : 12)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    // The sidebar drops by the pane's runway too, so the first
                    // category stays level with the pane's first row — the runway
                    // moves BOTH columns down, it doesn't stagger them.
                    // A hidden copy holds the sidebar's width and minimum height;
                    // the visible one is an overlay so it spans the full column
                    // height.
                    sidebar(measuring: true)
                        .padding(.top, metrics.paneTopRunway)
                        .hidden()
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 0) {
                        // The window keeps its sidebar on a sub-page, so the
                        // title and back circle sit at the top of the pane.
                        windowBackRow(leading: 18)
                        paneContent
                    }
                        // The panel's pane gets an exact width. Left flexible, a
                        // pane whose content asked for a few points more than
                        // the slot (Model asked 425.5 of 420) widened the whole
                        // body past `openWidthSettings`, and the centred overflow
                        // moved both side margins. The window keeps its
                        // flexible column (it can be resized).
                        .frame(width: inWindow ? nil : SettingsMetrics.panelPaneWidth,
                               alignment: .topLeading)
                        .padding(.leading, 14)
                        .background {
                            // Settings window only: the right pane is a darker
                            // panel with a rounded leading corner, flush with
                            // the window's top edge.
                            if inWindow {
                                GeometryReader { g in
                                    let top = g.frame(in: .global).minY
                                    UnevenRoundedRectangle(topLeadingRadius: 20,
                                                           style: .continuous)
                                        .fill(Tokens.adaptive(dark: .black.withAlphaComponent(0.3), light: .white.withAlphaComponent(0.55)))
                                        .overlay {
                                            UnevenRoundedRectangle(topLeadingRadius: 20,
                                                                   style: .continuous)
                                                .strokeBorder(Tokens.ink.opacity(0.07), lineWidth: 1)
                                        }
                                        .padding(.top, -top)
                                        .padding(.trailing, -(NotchBody.panelPadding + 1))
                                        .padding(.bottom, -(NotchBody.panelPadding + 1))
                                        .padding(.leading, -4)
                                }
                                .allowsHitTesting(false)
                            }
                        }
                }
                .overlay(alignment: .topLeading) {
                    sidebar()
                        .padding(.top, metrics.paneTopRunway)
                }
                // Take the columns' own height, nothing more: the pane already
                // carries an exact height (content, capped at Recent's), so this
                // no longer unfolds the scroll — it only stops the scroll behind
                // it from stretching the island.
                .fixedSize(horizontal: false, vertical: true)
                // Columns sit on the panel's own gutter, so the selected
                // category capsule shares its left edge with the back pill.
                .padding(.top, inWindow ? 12 : 0)
                // Pushing a sub-page drops the columns at once instead of
                // fading them: while they faded, the panel re-laid out under
                // them and the category column visibly lurched right for a
                // frame. Coming back still fades them in.
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        // Only soften the Settings content behind the template picker. A small
        // radius breaks the legibility of the old cards without erasing their
        // shapes or colours, and the modal overlay mounted below stays crisp.
        // The whole body at the panel's exact width too, so nothing below
        // (a header item, a pushed page) can widen it and shift the gutters.
        .frame(width: inWindow ? nil : SettingsMetrics.panelBodyWidth, alignment: .topLeading)
        .environment(\.menuCardLight, inWindow && colorScheme == .light)
        .blur(radius: license.locked ? 14 : (promptTemplatePickerOpen ? 2.5 : 0))
        .allowsHitTesting(!license.locked)
        // Trial ended: Settings is one page over the blurred panes, with Buy
        // License and Export your memories. It has no way to close; the back
        // pill stays, over the blur where the header draws it.
        .overlay {
            if license.locked { lockedPage }
        }
        // Its own overlay, on the header's frame and insets (`header`), so it
        // covers the blurred pill exactly.
        .overlay(alignment: .topLeading) {
            if license.locked, !inWindow {
                PanelBackPill(title: L("settings.title"), help: L("settings.back")) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        model.closeSettings()
                    }
                }
                .frame(height: Tokens.Control.header)
                .padding(.top, 12)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: license.locked)
        .overlay {
            if promptTemplatePickerOpen {
                ConfirmationDialogOverlay(
                    onDismiss: { closePromptTemplatePicker() },
                    edgeGlow: true
                ) {
                    promptTemplatePicker
                        .frame(width: 420)
                }
                .padding(.horizontal, -NotchBody.panelPadding)
                .padding(.top, -NotchBody.panelPadding)
                .padding(.bottom, -NotchBody.panelPadding)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if let id = presentedPromptShortcutID,
               let shortcut = promptShortcuts.first(where: { $0.id == id }) {
                ConfirmationDialogOverlay(
                    onDismiss: { closePromptShortcutEditor(id) }
                ) {
                    promptShortcutCard(shortcut)
                        .frame(width: 372)
                }
                // Settings is inset inside `NotchBody`; without reclaiming that
                // inset, the scrim stops at the settings content and leaves the
                // glass body's side and bottom gutters uncovered.
                .padding(.horizontal, -NotchBody.panelPadding)
                .padding(.top, -NotchBody.panelPadding)
                .padding(.bottom, -NotchBody.panelPadding)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if licenseOfferOpen {
                // The card itself is in its own window (`LicenseOfferWindow`)
                // so it can run past the island; here only the dim behind it.
                Color.black.opacity(metrics.scrimOpacity)
                    .contentShape(Rectangle())
                    .onTapGesture { closeLicenseOffer() }
                .padding(.horizontal, -NotchBody.panelPadding)
                .padding(.top, -NotchBody.panelPadding)
                .padding(.bottom, -NotchBody.panelPadding)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if let target = memoryForgetTarget {
                // Forgetting cannot be undone, so it asks first.
                ConfirmationDialogOverlay(onDismiss: { memoryForgetTarget = nil }) {
                    SettingsAlertDialog(
                        title: L("memory.clearAll"),
                        description: target.turnsOff ? L("memory.off.confirm") : L("memory.forgetAll.confirm"),
                        confirmTitle: L("memory.clearAll"),
                        cancelTitle: L("clear.cancel"),
                        destructive: true,
                        onCancel: { memoryForgetTarget = nil },
                        onConfirm: {
                            memoryForgetTarget = nil
                            withAnimation(.easeOut(duration: Tokens.hoverFade)) {
                                if target.turnsOff {
                                    memory.enabled = false   // which forgets everything
                                } else {
                                    memory.deleteAll()
                                }
                            }
                        }
                    )
                }
                .padding(.horizontal, -NotchBody.panelPadding)
                .padding(.top, -NotchBody.panelPadding)
                .padding(.bottom, -NotchBody.panelPadding)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if let confirm = clipboardConfirm {
                ConfirmationDialogOverlay(onDismiss: { clipboardConfirm = nil }) {
                    SettingsAlertDialog(
                        title: clipboardConfirmTitle(confirm),
                        description: clipboardConfirmText(confirm),
                        confirmTitle: clipboardConfirmTitle(confirm),
                        cancelTitle: L("clear.cancel"),
                        destructive: true,
                        onCancel: { clipboardConfirm = nil },
                        onConfirm: {
                            clipboardConfirm = nil
                            withAnimation(.easeOut(duration: Tokens.hoverFade)) {
                                switch confirm {
                                case .turnOff: clipboardHistory.enabled = false   // which deletes every copy
                                case .shorten(let option, _): clipboardHistory.retention = option
                                case .clearAll: clipboardHistory.clear()
                                }
                            }
                        }
                    )
                }
                .padding(.horizontal, -NotchBody.panelPadding)
                .padding(.top, -NotchBody.panelPadding)
                .padding(.bottom, -NotchBody.panelPadding)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if signalConfirmForget, case .connected(let account) = signal.state {
                ConfirmationDialogOverlay(onDismiss: { signalConfirmForget = false }) {
                    SettingsAlertDialog(
                        title: L("telegram.forget"),
                        description: L("signal.forget.confirm", account),
                        confirmTitle: L("telegram.forget"),
                        cancelTitle: L("clear.cancel"),
                        destructive: true,
                        onCancel: { signalConfirmForget = false },
                        onConfirm: {
                            signalConfirmForget = false
                            withAnimation(.easeOut(duration: Tokens.hoverFade)) {
                                signalSetupOpen = true
                                signal.forget(relink: true)
                            }
                        }
                    )
                }
                .padding(.horizontal, -NotchBody.panelPadding)
                .padding(.top, -NotchBody.panelPadding)
                .padding(.bottom, -NotchBody.panelPadding)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if telegramConfirmForget, case .connected(let bot, _) = telegram.state {
                // Starting over unpairs the bot, and pairing again takes the
                // whole setup, so it asks first. Same card as Forget memories.
                ConfirmationDialogOverlay(onDismiss: { telegramConfirmForget = false }) {
                    SettingsAlertDialog(
                        title: L("telegram.forget"),
                        description: L("telegram.forget.confirm", "@" + bot),
                        confirmTitle: L("telegram.forget"),
                        cancelTitle: L("clear.cancel"),
                        destructive: true,
                        onCancel: { telegramConfirmForget = false },
                        onConfirm: {
                            telegramConfirmForget = false
                            withAnimation(.easeOut(duration: Tokens.hoverFade)) {
                                telegramOpenedBotFather = false
                                telegramSetupOpen = true
                                telegram.forget()
                            }
                        }
                    )
                }
                .padding(.horizontal, -NotchBody.panelPadding)
                .padding(.top, -NotchBody.panelPadding)
                .padding(.bottom, -NotchBody.panelPadding)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if model.confirmingDisconnect {
                // Disconnecting drops the stored sign-in, and getting it back
                // takes the browser flow again, so it asks first.
                AccountDisconnectConfirm(
                    account: Provider.openrouter.displayName,
                    onCancel: {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            model.confirmingDisconnect = false
                        }
                    },
                    onConfirm: {
                        model.confirmingDisconnect = false
                        disconnectOpenRouter()
                    }
                )
                .padding(.horizontal, -NotchBody.panelPadding)
                .padding(.top, -NotchBody.panelPadding)
                .padding(.bottom, -NotchBody.panelPadding)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if inWindow, let connector = connectorAuth.pendingThirdPartyConsent {
                ThirdPartyConnectorConsentOverlay(connector: connector, auth: connectorAuth)
                    .padding(.horizontal, -NotchBody.panelPadding)
                    .padding(.top, -NotchBody.panelPadding)
                    .padding(.bottom, -NotchBody.panelPadding)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: model.confirmingDisconnect)
        .animation(.easeOut(duration: 0.16), value: connectorAuth.pendingThirdPartyConsent?.id)
        .animation(.easeOut(duration: 0.16), value: memoryForgetTarget)
        .animation(.easeOut(duration: 0.16), value: clipboardConfirm)
        .animation(.easeOut(duration: 0.16), value: telegramConfirmForget)
        .animation(.easeOut(duration: 0.16), value: signalConfirmForget)
        .animation(.easeOut(duration: 0.16), value: promptTemplatePickerOpen)
        .animation(.easeOut(duration: 0.16), value: presentedPromptShortcutID)
        .animation(.easeOut(duration: 0.16), value: licenseOfferOpen)
        .background(HostWindowProbe(box: settingsHostWindow))
        .onDisappear { if licenseOfferOpen { closeLicenseOffer() } }
        // The prompt card's "Enter key" opens the popup with the field out.
        .onAppear { takeKeyEntryRequest() }
        .onChange(of: license.wantsKeyEntry) { takeKeyEntryRequest() }
        // Bought or activated: the popup turns to the result (key, Done).
        // The Force Click gate is NOT mounted here: its scrim has to cover the
        // whole glass panel, and the settings body stops short of the island's
        // edges (the body's own padding showed as uncovered strips down the sides
        // and along the bottom). It hangs off the island itself in `ContentView`,
        // next to the Clear confirmation, on `model.forceClickLookupConflict`.
        .task {
            // A keyless model picked in the ⌘⇧I picker sent us here: adopt the pick,
            // aim the key section at its provider, and unfold it — from here it's the
            // same pending flow the settings picker's own "Add key" runs (the model
            // commits the moment a key lands, and nothing changes before that).
            if let pending = model.pendingModelSetup {
                model.pendingModelSetup = nil
                section = .model
                pendingModel = PendingModel(provider: pending.provider, id: pending.id)
                setKeyScope(pending.provider)
                keySectionOpen = true
            }
            adoptPendingSettingsProvider()
            // The backend can have changed on the panel since this view was last
            // built — the balance card's rim reads the live answer, not the one
            // that was true when the state was initialised.
            notchiActive = APIKeyStore.selectedProvider.isFirstParty
            // Un-throttled freshness check while the user is actually looking at
            // the Version row (one tiny request; failures stay silent).
            updater.check()
            // The model chip may be naming a Claude Code alias — resolve it to the
            // concrete model ("opus" → "Opus 5") without waiting for the picker to
            // be opened. Self-gating and cache-backed; usually a no-op.
            catalog.resolveClaudeAliases()
            await refreshModels()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appIconAppearanceChanged)) { _ in
            appIconAppearanceRevision &+= 1
        }
        // The panel's own model menu can switch the backend while this pane is
        // open — to Notchi (the rim lights, the rows stay put) or back off it.
        // A switch to one of theirs is a switch of the thing these rows DO name,
        // so they follow it; the key section only re-aims when it isn't busy
        // (a pending "Add key", or one the user opened by hand, keeps its target).
        .onReceive(NotificationCenter.default.publisher(for: .aiBackendChanged)) { _ in
            notchiActive = APIKeyStore.selectedProvider.isFirstParty
            let brought = APIKeyStore.broughtProvider
            if brought != provider {
                provider = brought
                modelID = APIKeyStore.storedModel(for: brought)
                if pendingModel == nil, !keySectionOpen { setKeyScope(brought) }
            } else {
                modelID = APIKeyStore.storedModel(for: brought)
            }
        }
        .onChange(of: model.pendingSettingsProvider) { _, _ in
            adoptPendingSettingsProvider()
        }
        .onChange(of: orAuth.phase) {
            // The OAuth flow just wrote a key from outside this view — sync the
            // cached state, prove the key live (green pill), and load the free
            // model list it unlocks.
            guard orAuth.phase == .connected, keyScope == .openrouter else { return }
            apiKey = APIKeyStore.stored(for: .openrouter)
            editingKey = false
            manualKeyEntry = false
            orAuth.acknowledge()
            // A connect that was blocking a picked model commits that pick now.
            if let pending = pendingModel, pending.provider == .openrouter {
                selectAcrossProviders(provider: .openrouter, model: pending.id)
            } else if provider == .openrouter {
                modelID = APIKeyStore.storedModel(for: .openrouter)
                activateIfShown(.openrouter)
                NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
            }
            test()
            Task { await refreshModels() }
        }
    }

    /// The settings body's height — FIXED, one number for every pane. It's sized
    /// so the island is exactly as tall in Settings as it is on Recent: the
    /// immersive recent layout's prompt FLOATS over its scroll surface, so that
    /// whole view is its 320pt list, while Settings stacks a back-pill header
    /// (12 + 26 + 4) and a 12pt gap above its pane, and that chrome comes out of
    /// the same budget. Short panes leave air at the bottom; long ones scroll. Fixed
    /// rather than measured per pane, so the island doesn't resize on every
    /// category switch (or re-measure on every layout pass).
    private static let headerChrome: CGFloat = 12 + Tokens.Control.header + 4 + 12
    private var settingsPaneHeight: CGFloat {
        windowPaneHeight ?? (NotchBody.immersiveListHeight - Self.headerChrome)
    }

    /// The window's titlebar is a unified toolbar row; the header sits in it,
    /// right of the traffic lights.
    static let windowHeaderTop: CGFloat = 13
    static let windowHeaderLeading: CGFloat = 78
    /// Height of everything above the pane in the window: header row and the
    /// 12pt gap the panel uses.
    static let windowChrome: CGFloat = windowHeaderTop + Tokens.Control.header + 4 + 12

    /// The window's back circle — visibly bigger than the panel's 26pt pill so
    /// it reads as a button standing on its own line.
    static let windowBackCircle: CGFloat = 36
    static let windowBackRowTop: CGFloat = -18
    static let windowBackRowBottom: CGFloat = 8
    /// What the back row adds above the pane on a pushed page, over the 12pt gap
    /// `windowChrome` already counts, so the window shrinks the pane by exactly
    /// this much and nothing spills past the bottom.
    static let windowBackRowChrome: CGFloat =
        windowBackRowTop + windowBackCircle + windowBackRowBottom

    /// `windowChrome` for the section about to be drawn.
    static func windowChrome(sectionRaw: String) -> CGFloat {
        let page = Section(rawValue: sectionRaw == "Gifts"
                           ? Section.balances.rawValue : sectionRaw) ?? .model
        return windowChrome + (page.parent == nil ? 0 : windowBackRowChrome)
    }

    /// Carries the open pane's measured content height out of the scroll view.
    private struct PaneContentHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// The widest label in the open pane, so every control in it can start at the
    /// same x; sizing each label to its own text leaves a ragged control column.
    /// A fixed pixel column can't do this job: French and Spanish labels are
    /// visibly longer than the
    /// English ones, so the number would either clip or waste half the pane.
    fileprivate struct SettingsLabelColumnKey: EnvironmentKey {
        static let defaultValue: CGFloat = 0
    }

    private struct LabelColumnWidthKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// Scroll anchor for the key section — the one pane area whose unfold can
    /// push its own fields past the pane's height cap.
    private static let keySectionAnchor = "settings.keySection"

    /// The empty inset above the pane's first row, and the length of the top
    /// taper that dissolves into it. The taper is the longer of the two (a fade
    /// that stops at the runway's edge reads as a hard cut), so it starts well
    /// above the first row and reaches down past it — matched to the
    /// bottom's 32pt so both edges of the pane dissolve at the same rate. It only
    /// ever draws while the pane is scrolled (`paneScrolledOffTop`), so at rest
    /// the first row is still fully solid.
    // Values: `SettingsMetrics.paneTopRunway` and `.paneTopFade`.

    /// The room a group heading takes above itself, on top of the pane's 18pt
    /// row rhythm. A heading opens a group, so its gap above must be visibly
    /// wider than the gap between two rows; without it the next group reads as
    /// more rows of the one before and the whole pane runs together.
    // Value: `SettingsMetrics.groupHeadingGap`.

    /// Whether the open pane is scrolled off its top — all the top taper needs to
    /// know. A Bool, not the live offset: driving the gradient's LENGTH from the
    /// offset rebuilt the pane's mask on every scroll tick, which is what made
    /// scrolling crawl. This flips once.
    @State private var paneScrolledOffTop = false

    /// Whether the open pane's rows are taller than the room under the runway.
    /// Starts `true` so a pane that does overflow never shows an un-tapered first
    /// frame; the measurement corrects it on the same layout pass.
    @State private var paneOverflows = true

    /// The panel sidebar's list is scrolled off its top; gates its top taper.
    @State private var sidebarScrolledOffTop = false

    /// Whether the Prompt shortcuts rail is scrolled off its leading edge — the
    /// same gate `paneScrolledOffTop` is for the vertical pane, and for the same
    /// reason: at rest the first card sits flush at 0, so a permanent leading
    /// taper would thin a card nothing is scrolling past.
    @State private var promptShortcutRailScrolled = false

    /// The ready-made action in the rail the pointer is over, if any. Kept apart
    /// from `hoveredPromptTemplateID` (the picker's cover flow) so a ghost card
    /// and the picker card for the same template never light each other.
    @State private var hoveredPromptTemplateGhostID: String?

    /// The open section's pane. Lives apart from `body` because it is drawn in
    /// two different frames — in the right-hand column beside the sidebar for a
    /// category, or across the whole panel for a pushed sub-page — and the switch
    /// itself should not have to know which.
    ///
    /// Every category scrolls inside ONE shared frame (see
    /// `settingsPaneHeight`) instead of stretching the island taller, with the
    /// same ceiling and the same edge tapers.
    @ViewBuilder
    private var paneContent: some View {
        if section == .whatsNew {
            // The release notes scroll in two columns of their own (the version
            // rail and the notes), so this page replaces the pane's scroller
            // instead of nesting inside it.
            WhatsNewView(model: model, showsHeader: false, height: settingsPaneHeight)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
        } else if section == .connect {
            stickyConnectorsPane
        } else {
            scrollingPaneContent
        }
    }

    /// Connectors pane with category tabs pinned at the top while the connector
    /// rows scroll underneath with edge fade.
    private var stickyConnectorsPane: some View {
        GeometryReader { viewport in
            let innerWidth: CGFloat? = viewport.size.width > 0
                ? max(0, viewport.size.width - metrics.paneSideInset * 2)
                : nil
            let columnWidth: CGFloat? = {
                guard let innerWidth else { return metrics.contentMaxWidth }
                if let cap = metrics.contentMaxWidth { return min(innerWidth, cap) }
                return innerWidth
            }()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                    if inWindow {
                        StandaloneWindowTitle(text: section.title)
                    }
                    connectorCategoryTabs
                }
                .frame(width: columnWidth, alignment: .topLeading)
                .frame(width: innerWidth, alignment: inWindow ? .top : .topLeading)
                .padding(.top, metrics.paneTopRunway)
                .padding(.bottom, 8)
                .padding(.horizontal, metrics.paneSideInset)

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(MCPConnector.connectors(in: activeConnectorCategory)) { connector in
                            ConnectorTableRow(connector: connector, auth: connectorAuth, hub: mcp) {
                                connectorAuth.requestConnect(connector)
                            }
                        }
                    }
                    .animation(.easeOut(duration: 0.18), value: activeConnectorCategory)
                    .frame(width: columnWidth, alignment: .topLeading)
                    .frame(width: innerWidth, alignment: inWindow ? .top : .topLeading)
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: PaneContentHeightKey.self, value: g.size.height)
                        }
                    )
                    .padding(.top, 2)
                    .padding(.bottom, 20)
                    .padding(.horizontal, metrics.paneSideInset)
                    .onScrollOffsetChange { offset in
                        let off = offset > 0.5
                        if off != paneScrolledOffTop { paneScrolledOffTop = off }
                    }
                }
                .id(activeConnectorCategory)
                .scrollIndicators(.never)
                .onPreferenceChange(PaneContentHeightKey.self) { height in
                    let headerBudget: CGFloat = metrics.paneTopRunway + 38 + (inWindow ? 40 : 0)
                    let over = height > settingsPaneHeight - headerBudget + 0.5
                    if over != paneOverflows { paneOverflows = over }
                }
                .scrollEdgeFade(top: paneScrolledOffTop, bottom: paneOverflows,
                                topFade: 18, bottomFade: 32)
            }
        }
        .frame(height: settingsPaneHeight, alignment: .topLeading)
        .onChange(of: activeConnectorCategory) {
            paneScrolledOffTop = false
        }
        .onAppear {
            paneScrolledOffTop = false
        }
    }

    @ViewBuilder
    private var scrollingPaneContent: some View {
        // The pane captured for this body pass. A pane leaving on a switch keeps
        // the value it was built with, so its preference callbacks can tell they
        // no longer speak for the open pane.
        let pane = section
        GeometryReader { viewport in
            // Lock the scroll content's width to the viewport so no single wide
            // row (a long pasted key, a multi-button control row) can ever stretch
            // the VStack past the pane edge and push sibling rows off-screen.
            // In the panel, the GeometryReader itself bleeds 8pt left & right
            // (so `scrollEdgeFade`'s mask never clips search highlights), and
            // `sideInset` restores the exact column width inside the ScrollView.
            let sideInset = metrics.paneSideInset + (inWindow ? 0 : 8)
            let innerWidth: CGFloat? = viewport.size.width > 0
                ? max(0, viewport.size.width - sideInset * 2)
                : nil
            let columnWidth: CGFloat? = {
                guard let innerWidth else { return section.fillsWindowWidth ? nil : metrics.contentMaxWidth }
                if section.fillsWindowWidth { return innerWidth }
                if let cap = metrics.contentMaxWidth { return min(innerWidth, cap) }
                return innerWidth
            }()
            ScrollViewReader { proxy in
            // The outgoing and incoming panes overlap here for the length of the
            // switch. Without this stack they were laid out side by side in the
            // columns' HStack, which widened the columns and pushed both of them
            // left for a frame.
            ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                    // The window names the open category at the top of its
                    // pane; the panel's back pill already says where you are.
                    if inWindow && !section.isDetail {
                        StandaloneWindowTitle(text: section.title)
                    }
                    switch section {
            case .model:
                // The prepaid balance, outside the card as an ordinary row:
                // it pays for the billed models, which the purchase does not
                // cover. It is there whichever backend is selected.
                nonoAccountRow
                    .searchTarget("nono.credit", active: highlightedSearchKey)
                // Everything you bring yourself, outside the card and unadorned,
                // in the order you set it up: which backend answers, which of
                // its models (only once it can answer), and the key that lets
                // it. The API key stays folded in `keySection` unless the choice
                // needs one or the user opens it. The caption names this
                // group as the alternative to the wallet above.
                Text(L("model.byok"))
                    .settingsHeading()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .searchTarget("model.byok", active: highlightedSearchKey)
                    .padding(.top, metrics.groupHeadingGap)
                providerRow
                    .searchTarget("model.provider", active: highlightedSearchKey)
                // A model list for a provider that cannot answer yet is a choice
                // with nothing behind it; it appears once the key or sign-in lands.
                if providerReady(provider) {
                    modelRow
                        .searchTarget("model.label", active: highlightedSearchKey)
                }
                keySection
                    .searchTarget("model.keys.section", active: highlightedSearchKey)
                // The model behind the small yes/no calls, beside the other
                // "which model, whose key" choices.
                Text(L("decision.title"))
                    .settingsHeading()
                    .padding(.top, metrics.groupHeadingGap)
                decisionModelRow
                    .searchTarget("decision.title", active: highlightedSearchKey)
                switch decisionModel {
                case .jev:    EmptyView()
                case .jevKey: decisionField(label: L("decision.key"), placeholder: L("model.pasteKey"),
                                            text: $typeSafeKey, secure: true) { TypeSafeKey.value = $0 }
                              decisionTestRow
                case .custom: decisionEndpointRows
                              decisionTestRow
                }
                // Web search is the same question this pane already answers
                // (which backend, and its key), so it rides here as a labelled
                // group rather than its own category.
                Text(L("sidebar.search"))
                    .settingsHeading()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .searchTarget("sidebar.search", active: highlightedSearchKey)
                    .padding(.top, metrics.groupHeadingGap)
                searchBackendRow
                    .searchTarget("search.backend", active: highlightedSearchKey)
                    // No stored pick yet → commit the shown default so the
                    // UI and what actually runs never disagree.
                    .onAppear {
                        if searchBackend == nil { selectSearchBackend(selectedBackend) }
                    }
                // Only the picked backend's key row shows — like the model
                // choice above, one pick, one field to fill.
                switch selectedBackend {
                case .keenable: keenableKeyRow
                case .exa:      exaKeyRow
                case .anysearch: anySearchKeyRow
                case .deepseek:  deepSeekSearchKeyRow
                }
            case .license:
                licensePane
            case .chat:
                // Three clear groups: how Notchi answers and follows up,
                // tools it can publish or run with, and what triggers a chat
                // from copied text.
                Text(L("chat.group.answers"))
                    .settingsHeading()
                customInstructionsRow
                    .searchTarget("general.customInstructions", active: highlightedSearchKey)
                suggestFollowUpRow
                    .searchTarget("chat.suggestFollowUp", active: highlightedSearchKey)
                proactiveSection
                    .searchTarget("proactive.title", active: highlightedSearchKey)
                Text(L("chat.group.tools"))
                    .settingsHeading()
                    .padding(.top, metrics.groupHeadingGap)
                pagesRow
                    .searchTarget("pages.title", active: highlightedSearchKey)
                if DebugFeatureFlags.cloudMachine {
                    cloudMachineSection
                }
                // MCP is switched off for now.
                // Text(L("mcp.title"))
                //     .settingsCaption()
                //     .padding(.top, 2)
                // mcpSection
                Text(L("capture.sources"))
                    .settingsHeading()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .searchTarget("capture.sources", active: highlightedSearchKey)
                    .padding(.top, metrics.groupHeadingGap)
                copySenseRow
                    .searchTarget("general.copySense", active: highlightedSearchKey)
            case .memories:
                // One group: what Notchi writes about you, then the text you
                // copied, as it was.
                Text(L("memory.title"))
                    .settingsHeading()
                memoryEnableRow
                    .searchTarget("memory.toggle", active: highlightedSearchKey)
                if memory.enabled {
                    UnderlineLink(title: L("memory.manage"), external: true) {
                        try? FileManager.default.createDirectory(at: UserMemory.folder,
                                                                 withIntermediateDirectories: true)
                        NSWorkspace.shared.open(UserMemory.folder)
                    }
                    .searchTarget("memory.manage", active: highlightedSearchKey)
                }
                if ClipboardHistory.available {
                    clipboardHistoryRow
                        .searchTarget("clipboardHistory.toggle", active: highlightedSearchKey)
                    if clipboardHistory.enabled {
                        clipboardRetentionRow
                            .searchTarget("clipboardHistory.retention", active: highlightedSearchKey)
                        UnderlineLink(title: L("clipboardHistory.title"), external: true) {
                            let url = ClipboardHistory.fileURL
                            if FileManager.default.fileExists(atPath: url.path) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            } else {
                                NSWorkspace.shared.open(url.deletingLastPathComponent())
                            }
                        }
                        .searchTarget("clipboardHistory.title", active: highlightedSearchKey)
                    }
                }
            case .general:
                // App-level settings: how it talks to you, launch, the app's
                // icons (app icon, Dock, menu bar icon), where notes are saved,
                // what the system lets it touch, and the escape hatch.
                appLanguageRow
                    .searchTarget("general.appLanguage", active: highlightedSearchKey)
                launchAtLoginRow
                    .searchTarget("general.launchAtLogin", active: highlightedSearchKey)
                Text(L("general.appPresence"))
                    .settingsHeading()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .searchTarget("general.appPresence", active: highlightedSearchKey)
                    .padding(.top, metrics.groupHeadingGap)
                if AppIconStyleFeature.isEnabled {
                    appIconStyleRow
                        .searchTarget("appearance.appIcon", active: highlightedSearchKey)
                }
                dockIconRow
                    .searchTarget("general.dockIcon.toggle", active: highlightedSearchKey)
                Text(L("capture.destination"))
                    .settingsHeading()
                    .padding(.top, metrics.groupHeadingGap)
                noteDestinationRow
                    .searchTarget("general.noteDestination", active: highlightedSearchKey)
                permissionsSection
                    .searchTarget("permissions.title", active: highlightedSearchKey)
                advancedSection
                    .searchTarget("general.advanced", active: highlightedSearchKey)
            case .shortcuts:
                shortcutsSection
            case .appearance:
                // Two small, literal groups: how the notch reacts and which
                // displays carry it, plus the menu bar icon and where its card opens.
                Text(L("appearance.behavior"))
                    .settingsHeading()
                hoverSensitivityRow
                    .searchTarget("general.hoverSensitivity", active: highlightedSearchKey)
                if ForceClickFeature.isEnabled {
                    forceClickPressureRow
                        .searchTarget("general.forceClickPressure", active: highlightedSearchKey)
                    if model.isForceTouchDisabled {
                        forceClickPausedNotice
                    }
                }
                Text(L("appearance.displays"))
                    .settingsHeading()
                    .padding(.top, metrics.groupHeadingGap)
                placementRow
                    .searchTarget("appearance.showOn", active: highlightedSearchKey)
                Text(L("appearance.menuBar"))
                    .settingsHeading()
                    .padding(.top, metrics.groupHeadingGap)
                menuBarIconRow
                    .searchTarget("general.menuBarIcon", active: highlightedSearchKey)
                menuBarCardPlacementRow
                    .searchTarget("menuBarCard.position", active: highlightedSearchKey)
                jevAutoPinRow
                    .searchTarget("general.jevAutoPin", active: highlightedSearchKey)
                Text(L("chat.group.effects"))
                    .settingsHeading()
                    .padding(.top, metrics.groupHeadingGap)
                messageSoundsRow
                    .searchTarget("messageSounds", active: highlightedSearchKey)
            case .channels:
                VStack(alignment: .leading, spacing: 14) {
                    telegramSection
                        .searchTarget("telegram.title", active: highlightedSearchKey)
                    signalSection
                        .searchTarget("signal.title", active: highlightedSearchKey)
                }
                Text(L("channels.group.background"))
                    .settingsHeading()
                    .padding(.top, metrics.groupHeadingGap)
                lidClosedRow
                    .searchTarget("telegram.lid", active: highlightedSearchKey)
            case .connect:
                // Drawn with sticky category tabs in `stickyConnectorsPane` (see `paneContent`).
                EmptyView()
            case .stats:
                statsSection
            case .about:
                aboutSection
            case .licenses:
                licensesSection
            case .survey:
                surveySection
            case .usage:
                usageSection
            case .pricing:
                pricingSection
            case .balances:
                balancesSection
            case .privacy:
                NonoPrivacyNote()
            case .pages:
                NotchiPagesPane()
            case .whatsNew:
                // Drawn beside this scroller, not in it (see `paneContent`).
                EmptyView()
            }
            }
            // The window caps how wide rows grow (see `SettingsMetrics`); tables
            // and the memory browser keep the full width. Both frames use exact
            // widths derived from the scroll viewport so no child can widen the
            // column past the pane boundary.
            .frame(width: columnWidth, alignment: .topLeading)
            // A window dragged wider than `SettingsMetrics.windowWidth` keeps the
            // column centred instead of leaving the extra width on one side.
            .frame(width: innerWidth, alignment: inWindow ? .top : .topLeading)
            // The open pane follows the live measurement; a leaving pane keeps
            // the column it was last measured with (see `LabelColumnFloor`).
            .environment(\.settingsLabelColumn,
                         pane == section ? labelColumnWidth : (Self.labelColumnWidths[pane] ?? 0))
            // How tall this pane's rows actually are, measured before the runway
            // and the bottom inset are added — the number the bottom taper is
            // gated on (see `paneOverflows`).
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: PaneContentHeightKey.self,
                                           value: g.size.height)
                }
            )
            // A top RUNWAY — the whole right-hand pane rests a little lower than the
            // sidebar's first item, and this inset is what the top taper dissolves
            // into: a small scroll eats empty space before a row reaches the
            // steep part of the taper (see `paneTopFade`), so rows stay readable
            // on a stray trackpad nudge instead of the pane's top looking
            // covered. The bottom keeps its own runway — that edge tapers at all
            // times.
            .padding(.top, metrics.paneTopRunway)
            .padding(.bottom, 20)
            // The window has the room, so its pane keeps more air on both
            // sides than the panel's 14pt gutter can afford. In the panel, add
            // an 8pt inner bleed (matched by `-8` on the ScrollView) so search
            // highlights can extend past the row edges without clipping.
            .padding(.horizontal, metrics.paneSideInset + (inWindow ? 0 : 8))
            // Zero-size probe on the scroll CONTENT: it reads the real clip view's
            // offset. Only the crossing matters, so state changes at most once per
            // scroll gesture rather than on every tick.
            .onScrollOffsetChange { offset in
                let off = offset > 0.5
                if off != paneScrolledOffTop { paneScrolledOffTop = off }
            }
            }
            .onPreferenceChange(PaneContentHeightKey.self) { height in
                // The runway is empty by definition, so the rows only overflow
                // once they outgrow what is left under it.
                guard pane == section else { return }
                let over = height > settingsPaneHeight - metrics.paneTopRunway + 0.5
                if over != paneOverflows { paneOverflows = over }
            }
            .onPreferenceChange(LabelColumnWidthKey.self) { width in
                if width > 0 { Self.labelColumnWidths[pane] = width }
                guard pane == section else { return }
                if abs(width - labelColumnWidth) > 0.5 { labelColumnWidth = width }
            }
            .scrollIndicators(.never)
            // One fixed height for every pane (see `settingsPaneHeight`) — the
            // island never resizes between categories, and a greedy ScrollView
            // never gets to claim the whole panel.
            .frame(height: settingsPaneHeight)
            // Key the scroll container by the open section: each category gets
            // its OWN scroll state, so leaving Model scrolled halfway doesn't
            // carry that offset into General (and vice versa) — a fresh scroll
            // always starts at the top of its own content.
            .id(section)
            // The new pane rises from the side the selection moved toward and
            // the old one leaves the other way, so the motion follows the
            // sidebar: a category further down comes up from below. The old
            // pane fades faster than the new one arrives, so the two never
            // read as overlapping text.
            .transition(.asymmetric(
                insertion: .opacity
                    .combined(with: .offset(y: 14 * paneDirection))
                    .animation(.spring(response: 0.34, dampingFraction: 0.88)),
                removal: .opacity
                    .combined(with: .offset(y: -8 * paneDirection))
                    .animation(.easeOut(duration: 0.12))
            ))
            }
            // A required setup unfolds the key section past the pane's height
            // cap — snap the scroller to it so what just appeared is in view
            // (the anchor lives on `keySection`). The first frame of the unfold
            // lands silently: the animation here would otherwise double the
            // section's own `.easeOut` and stall the open.
            .onChange(of: setupRequired) { _, required in
                guard required, section == .model else { return }
                DispatchQueue.main.async { proxy.scrollTo(Self.keySectionAnchor, anchor: .top) }
            }
            .onChange(of: pendingScrollKey) { _, key in
                guard let key else { return }
                // Wait a beat so a freshly swapped pane or unfolded collapsible
                // finishes laying out before scrolling to the target row.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        proxy.scrollTo("search.\(key)", anchor: .center)
                    }
                    if pendingScrollKey == key { pendingScrollKey = nil }
                }
            }
            // The top taper exists only once the pane is actually scrolled: it is
            // there to dissolve rows leaving past the back pill, and nothing is
            // leaving while the pane sits at top. It starts above the first row
            // and runs long (see `paneTopFade`) so rows thin out gradually
            // instead of snapping off at the runway's edge.
            // The bottom taper is gated on the pane actually overflowing, as
            // `scrollEdgeFade` documents — otherwise it washes out the last 32pt
            // of panes that fit (About's colophon, Stats' bottom card).
            .scrollEdgeFade(top: paneScrolledOffTop, bottom: paneOverflows,
                            topFade: metrics.paneTopFade, bottomFade: 32)
            // A pane swap starts at the top again; the observer only reports on
            // the next bounds change, so clear the flag here.
            .onAppear {
                // Once per appearance: a tag marked read while this pane is up
                // stays up, and is gone the next time Settings opens.
                showsRefreshedTag = !SettingsNewMarks.copySenseSeen
            }
            .onChange(of: section) {
                paneScrolledOffTop = false
                statsHover = nil
                // The new pane measures its own longest label; keeping the old
                // pane's number would indent the first frame by a width no row
                // here asked for.
                labelColumnWidth = Self.labelColumnWidths[section] ?? 0
                if section == .model { markSurveyGrantSeen() }
            }
            }
        }
        .frame(height: settingsPaneHeight)
        .padding(.horizontal, inWindow ? 0 : -8)
    }

    // MARK: - Sidebar

    /// Width of the category column. The panel's 104pt is what fits beside its
    /// 266pt pane; the window has the room, so its column gets the extra width
    /// and the categories stop crowding the traffic lights side of the header.
    private var sidebarWidth: CGFloat { metrics.sidebarWidth }

    /// `measuring` is the hidden copy that only holds the column's size; it
    /// draws no selection capsule, so the sliding capsule has one source.
    private func sidebar(measuring: Bool = false) -> some View {
        // In the panel the pane is a fixed 266pt and the grouped list is taller,
        // so the list scrolls inside that height instead of running past the
        // panel's glass. The window is tall enough to show it whole. The
        // license entry stays under the list in both, outside the scroll.
        VStack(alignment: .leading, spacing: 0) {
            if inWindow {
                sidebarList(measuring: measuring)
            } else {
                settingsSearchField(measuring: measuring)
                    .padding(.bottom, 8)
                    .zIndex(1)
                ScrollView(.vertical) {
                    sidebarList(measuring: measuring)
                        // Room for the last category to scroll clear of the
                        // bottom taper.
                        .padding(.bottom, 20)
                        .onScrollOffsetChange { offset in
                            let off = offset > 0.5
                            if off != sidebarScrolledOffTop { sidebarScrolledOffTop = off }
                        }
                }
                .scrollIndicators(.never)
                // The pane's tapers: the top one only once the list is scrolled.
                .scrollEdgeFade(top: sidebarScrolledOffTop, bottom: true,
                                topFade: metrics.paneTopFade, bottomFade: 32)
            }
            if license.showsSettingsEntry {
                sidebarLicenseItem(measuring: measuring)
                    .padding(.top, 6)
            }
        }
        .frame(height: inWindow ? nil : settingsPaneHeight)
        .frame(width: sidebarWidth, alignment: .topLeading)
        .padding(.trailing, 12)
    }

    private func sidebarList(measuring: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // The window has no back pill on a category, so the sidebar names
            // the window.
            if inWindow {
                // Lifted to the same strip the other windows' names sit in: it
                // would otherwise open 24pt lower, on the sidebar's own runway.
                StandaloneWindowTitle(text: L("settings.title"))
                    .padding(.horizontal, 10)
                    .padding(.top, 8 - StandaloneWindowStyle.titleLift)
                    .padding(.bottom, 14)
                settingsSearchField(measuring: measuring)
                    .padding(.bottom, 10)
                    .zIndex(1)
            }
            ForEach(Array(Section.sidebarGroups.enumerated()), id: \.offset) { index, group in
                // Groups are separated by a rule, not named: a caption above
                // four rows is a second hierarchy the list does not need, and
                // the rule reads quieter against the glass.
                if index > 0 {
                    Rectangle()
                        .fill(Tokens.hairline.opacity(0.7))
                        .frame(height: 1)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                }
                ForEach(group.sections) { s in
                    sidebarItem(s, measuring: measuring)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: sidebarWidth, alignment: .topLeading)
    }

    /// One search hit: a category, or a row on it.
    private struct SettingsSearchHit: Identifiable {
        let section: Section
        /// The row's localization key; nil when the category's own name matched.
        let key: String?
        /// The row's localized label; nil when the category's own name matched.
        let label: String?
        let score: Int
        var id: String { section.rawValue + "|" + (key ?? "") }
    }

    /// Normalize text for case/diacritic-insensitive matching.
    private static func normalizeSearch(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Damerau-Levenshtein distance bounded by `maxDist`; returns `maxDist + 1` if exceeded.
    private static func boundedEditDistance(_ a: [Character], _ b: [Character], maxDist: Int) -> Int {
        let m = a.count, n = b.count
        if abs(m - n) > maxDist { return maxDist + 1 }
        if m == 0 { return n }
        if n == 0 { return m }
        var d = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { d[i][0] = i }
        for j in 0...n { d[0][j] = j }
        for i in 1...m {
            var rowMin = maxDist + 1
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var v = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                    v = min(v, d[i - 2][j - 2] + 1)
                }
                d[i][j] = v
                if v < rowMin { rowMin = v }
            }
            if rowMin > maxDist { return maxDist + 1 }
        }
        return d[m][n]
    }

    /// Score a single normalized query token against a candidate phrase.
    /// Higher is better; 0 means no match.
    private static func tokenScore(_ token: String, against rawCandidate: String, isPrimary: Bool) -> Int {
        let cand = normalizeSearch(rawCandidate)
        guard !cand.isEmpty else { return 0 }
        let base: Int
        if cand == token {
            base = 100
        } else if cand.hasPrefix(token) {
            base = 90
        } else {
            let words = cand.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            if words.contains(where: { $0.hasPrefix(token) }) {
                base = 82
            } else if cand.contains(token) {
                base = 72
            } else {
                // Fuzzy matching for Latin/ASCII tokens of length >= 2.
                let isASCII = token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
                guard isASCII, token.count >= 2 else { return 0 }
                let tChars = Array(token)
                var fuzzy = 0
                // 1) Ordered subsequence inside any word (e.g. "prxy" -> "proxy", "clpb" -> "clipboard").
                for w in words where w.count >= tChars.count {
                    let wChars = Array(w)
                    var ti = 0
                    var firstIdx = -1, lastIdx = -1
                    for (wi, ch) in wChars.enumerated() where ti < tChars.count && ch == tChars[ti] {
                        if firstIdx < 0 { firstIdx = wi }
                        lastIdx = wi
                        ti += 1
                    }
                    if ti == tChars.count {
                        let span = lastIdx - firstIdx + 1
                        // Require reasonable density so short tokens don't match unrelated long words.
                        if Double(tChars.count) / Double(span) >= 0.5 && (firstIdx == 0 || tChars.count >= 3) {
                            fuzzy = max(fuzzy, firstIdx == 0 ? 52 : 44)
                        }
                    }
                }
                // 2) Typo tolerance (transposition / 1-2 char edit) against words.
                if fuzzy == 0, tChars.count >= 4 {
                    let maxDist = tChars.count >= 7 ? 2 : 1
                    for w in words where w.count >= 3 {
                        let wChars = Array(w)
                        if boundedEditDistance(tChars, wChars, maxDist: maxDist) <= maxDist {
                            fuzzy = max(fuzzy, 40)
                            break
                        }
                        // Also allow typo against a prefix of a longer word (e.g. "shorcut" vs "shortcuts").
                        if wChars.count > tChars.count {
                            let prefix = Array(wChars.prefix(tChars.count + 1))
                            if boundedEditDistance(tChars, prefix, maxDist: maxDist) <= maxDist {
                                fuzzy = max(fuzzy, 38)
                                break
                            }
                        }
                    }
                }
                guard fuzzy > 0 else { return 0 }
                base = fuzzy
            }
        }
        return isPrimary ? base : max(1, base - 15)
    }

    /// Score all query tokens against primary text + secondary aliases (English / synonyms).
    /// Every token must match at least one candidate.
    private static func matchScore(tokens: [String], primary: String, aliases: [String]) -> Int {
        guard !tokens.isEmpty else { return 0 }
        var total = 0
        for token in tokens {
            var best = tokenScore(token, against: primary, isPrimary: true)
            for alias in aliases {
                let s = tokenScore(token, against: alias, isPrimary: false)
                if s > best { best = s }
            }
            guard best > 0 else { return 0 }
            total += best
        }
        return total / tokens.count
    }

    /// Hits for `settingsQuery`, ranked by relevance and grouped by category.
    private var settingsSearchHits: [(section: Section, hits: [SettingsSearchHit])] {
        let q = Self.normalizeSearch(settingsQuery)
        guard !q.isEmpty else { return [] }
        let tokens = q.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }

        var scoredGroups: [(order: Int, bestScore: Int, section: Section, hits: [SettingsSearchHit])] = []
        for (order, s) in Section.sidebarCases.enumerated() {
            var hits: [SettingsSearchHit] = []
            var seen = Set<String>()
            for key in s.searchKeys {
                let label = L(key)
                guard label != key, label != s.title, !seen.contains(label) else { continue }
                var aliases = Section.searchAliases(for: key)
                if let localizedAll = Section.allLocaleStrings[key] {
                    for text in localizedAll where text != label { aliases.append(text) }
                }
                let score = Self.matchScore(tokens: tokens, primary: label, aliases: aliases)
                guard score > 0 else { continue }
                seen.insert(label)
                hits.append(SettingsSearchHit(section: s, key: key, label: label, score: score))
            }
            hits.sort { $0.score > $1.score }

            // Match the section itself across all shipped languages + category synonyms.
            // Only emit a section-level row when its own title matched directly OR
            // when no specific row inside the section matched (avoids redundant header/row pairs).
            let allTitles = (Section.allLocaleStrings[s.titleKey] ?? []).filter { $0 != s.title }
            var sectionAliases = s.searchAliases
            sectionAliases.append(contentsOf: allTitles)
            let titleOnlyScore = Self.matchScore(tokens: tokens, primary: s.title, aliases: allTitles)
            let sectionScore = Self.matchScore(tokens: tokens, primary: s.title, aliases: sectionAliases)
            if titleOnlyScore > 0 {
                hits.insert(SettingsSearchHit(section: s, key: nil, label: nil, score: titleOnlyScore), at: 0)
            } else if hits.isEmpty, sectionScore > 0 {
                hits.append(SettingsSearchHit(section: s, key: nil, label: nil, score: sectionScore))
            }

            if let top = hits.map(\.score).max() {
                scoredGroups.append((order, top, s, hits))
            }
        }

        scoredGroups.sort { lhs, rhs in
            if lhs.bestScore != rhs.bestScore { return lhs.bestScore > rhs.bestScore }
            return lhs.order < rhs.order
        }
        let out = scoredGroups.map { (section: $0.section, hits: $0.hits) }

        // The panel is short: keep the card inside it.
        guard !inWindow else { return out }
        var budget = 7
        return out.compactMap { group in
            guard budget > 0 else { return nil }
            let kept = Array(group.hits.prefix(budget))
            budget -= kept.count
            return (group.section, kept)
        }
    }

    private func openSearchHit(_ hit: SettingsSearchHit) {
        settingsQuery = ""
        settingsSearchFocus = false
        // Expand any collapsible block that houses the target row.
        switch hit.key {
        case "network.proxy":
            advancedSectionOpen = true
        case "model.keys.section":
            keySectionOpen = true
        case "general.customInstructions":
            instructionsSectionOpen = true
        default:
            break
        }
        showSection(hit.section)
        guard let key = hit.key else {
            highlightedSearchKey = nil
            pendingScrollKey = nil
            return
        }
        let token = UUID()
        searchHighlightToken = token
        // Toggle nil first if re-selecting the same key so `onChange(of: pendingScrollKey)` fires.
        if pendingScrollKey == key { pendingScrollKey = nil }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.22)) {
                highlightedSearchKey = key
            }
            pendingScrollKey = key
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard searchHighlightToken == token else { return }
            withAnimation(.easeOut(duration: 0.45)) {
                highlightedSearchKey = nil
            }
        }
    }

    /// The sidebar's search box. Typing opens a card of matching
    /// categories and rows over the pane; picking one opens its category.
    @ViewBuilder
    private func settingsSearchField(measuring: Bool) -> some View {
        HStack(spacing: 6) {
            PhosphorIcon(mark: PhosphorIcons.magnifyingGlass, size: inWindow ? 15 : 13)
                .foregroundStyle(Tokens.text3)
                .padding(.trailing, 3)
            HistorySearchField(text: $settingsQuery,
                               placeholder: L("settings.search"),
                               fontSize: SettingsType.label + metrics.typeBump,
                               focusTrigger: settingsSearchFocus,
                               onSubmit: {
                                   if let first = settingsSearchHits.first?.hits.first {
                                       openSearchHit(first)
                                   }
                               })
            if !settingsQuery.isEmpty {
                Button {
                    settingsQuery = ""
                } label: {
                    Image(icon: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tokens.text3)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).exemptsDoubleClickPin()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .glassCapsule(in: Capsule(style: .continuous), brighter: !settingsQuery.isEmpty)
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { settingsSearchFocus = true }
        .onExitCommand { settingsQuery = "" }
        .overlay(alignment: .topLeading) {
            if !measuring && !settingsQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                settingsSearchCard
                    .offset(y: 34)
                    .transition(.opacity)
            }
        }
    }

    private var settingsSearchCard: some View {
        let groups = settingsSearchHits
        let rowFontSize = SettingsType.label + metrics.typeBump
        let headerFontSize = SettingsType.description + metrics.typeBump
        let headerIconSize = headerFontSize + 1
        let rowPad = MenuCard.pickerRowPad
        let rowHeight: CGFloat = 26

        // Fit card width to its visible labels, floored at `sidebarWidth` (aligned
        // with the search pill) and capped so it stays compact over the pane.
        let rowFont = NSFont.systemFont(ofSize: rowFontSize, weight: .regular)
        let headerFont = NSFont.systemFont(ofSize: headerFontSize, weight: .medium)
        var widest: CGFloat = 0
        if groups.isEmpty {
            widest = NSAttributedString(string: L("settings.search.empty"),
                                        attributes: [.font: rowFont]).size().width
        } else {
            for group in groups {
                let hw = headerIconSize + 5 + NSAttributedString(string: group.section.title,
                                                                 attributes: [.font: headerFont]).size().width
                widest = max(widest, hw)
                for hit in group.hits {
                    let rw = NSAttributedString(string: hit.label ?? hit.section.title,
                                                attributes: [.font: rowFont]).size().width
                    widest = max(widest, rw)
                }
            }
        }
        let maxCardWidth: CGFloat = inWindow ? 220 : 188
        let cardWidth = min(max(sidebarWidth, ceil(widest) + (rowPad + MenuCard.cardPad) * 2 + 4), maxCardWidth)

        let totalRows = groups.reduce(0) { $0 + 1 + $1.hits.count }
        let listContent = VStack(alignment: .leading, spacing: MenuCard.rowSpacing) {
            if groups.isEmpty {
                Text(L("settings.search.empty"))
                    .font(.sf(SettingsType.description + metrics.typeBump))
                    .foregroundStyle(Tokens.text4)
                    .padding(.horizontal, rowPad)
                    .frame(height: rowHeight)
            }
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                HStack(spacing: 5) {
                    if group.section == .about {
                        NotchiSidebarEyes(size: headerIconSize)
                    } else {
                        PhosphorIcon(mark: group.section.icon, size: headerIconSize)
                    }
                    Text(group.section.title)
                        .lineLimit(1)
                }
                .font(.sf(headerFontSize, weight: .medium))
                .foregroundStyle(Tokens.text4)
                .padding(.horizontal, rowPad)
                .padding(.top, index == 0 ? 3 : 7)
                .padding(.bottom, 2)
                ForEach(group.hits) { hit in
                    MenuCardRow(title: hit.label ?? hit.section.title,
                                fontSize: rowFontSize,
                                height: rowHeight,
                                horizontalPadding: rowPad,
                                selected: false,
                                action: { openSearchHit(hit) })
                }
            }
        }

        return Group {
            if inWindow && totalRows > 12 {
                ScrollView(.vertical) {
                    listContent
                }
                .scrollIndicators(.never)
                .frame(height: 340)
            } else {
                listContent
            }
        }
        .padding(MenuCard.cardPad)
        .frame(width: cardWidth, alignment: .leading)
        .menuCardBackground()
        .environment(\.menuCardLight, inWindow && colorScheme == .light)
    }

    private func sidebarItem(_ s: Section, measuring: Bool) -> some View {
        SidebarItem(
            title: s.title,
            icon: s == .about ? nil : s.icon,
            notchiEyes: s == .about,
            selected: section == s || section.parent == s,
            selection: measuring ? nil : sidebarSelection,
            // The gear's update dot continues here: it leads to settings,
            // then the About entry carries it the rest of the way to the
            // update action — a quiet neutral dot, never a coloured one.
            badged: s == .about && isUpdateAvailable,
            isNew: s == .stats && !auditSeen,
            claim: s == .about && !isUpdateAvailable ? surveyClaim : nil,
            claimAction: {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { section = .survey }
            }
        ) {
            if s == .stats, !auditSeen {
                auditSeen = true
                SettingsNewMarks.auditSeen = true
            }
            showSection(s)
        }
    }

    /// The pinned license entry: "Activated" once this account holds a license
    /// or is included, "License" otherwise.
    private func sidebarLicenseItem(measuring: Bool) -> some View {
        SidebarItem(
            title: license.showsHeldLicense ? L("license.state.activated") : L("license.label"),
            icon: Section.license.icon,
            selected: licenseOfferOpen,
            selection: measuring ? nil : sidebarSelection,
            badged: false,
            isNew: false,
            claim: nil,
            claimAction: {},
            buy: license.needsPurchase
        ) {
            openLicenseOffer()
        }
    }

    /// The About row's tag while the gateway runs a survey this account has not
    /// answered. The row has no room for it beside the update dot, which wins.
    private var surveyClaim: String? {
        guard let survey = nono.snapshot?.survey, survey.status == "none" else { return nil }
        return L("sidebar.survey.claim", surveyAmount(survey.amountUSD))
    }

    /// Approved after this install saw the answer wait for review, and the Model
    /// pane has not been opened since. An account approved before that has nothing
    /// new to be told.
    private var surveyJustGranted: Bool {
        nono.snapshot?.survey?.status == "approved" && SettingsNewMarks.surveyWaited && !surveyGrantSeen
    }

    private func markSurveyGrantSeen() {
        guard surveyJustGranted else { return }
        surveyGrantSeen = true
        SettingsNewMarks.surveyGrantSeen = true
    }

    /// The credit is on the Model pane's wallet.
    private func openGrantedCredit() {
        markSurveyGrantSeen()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { section = .model }
    }

    /// Switch panes. The label column is set in the same update: left to
    /// `onChange(of: section)`, the new pane's first layout still used the
    /// old pane's widest label, came out a few points wider than the panel,
    /// and both columns stepped right before sliding back.
    ///
    /// All three writes go in one `withAnimation`. Written outside it, the
    /// column was committed as a separate update while the old pane was still
    /// the open one, so Appearance laid out once under Chat's wider column and
    /// pushed both columns left.
    ///
    /// The pane swap is animated (see the transition in `paneContent`); the
    /// two panes overlap in a ZStack there. The selection capsule slides
    /// between rows.
    private func showSection(_ s: Section) {
        guard s != section else { return }
        let direction = Self.direction(from: section, to: s)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            labelColumnWidth = Self.labelColumnWidths[s] ?? 0
            paneDirection = direction
            section = s
        }
    }

    /// +1 when `to` sits below `from` in the category order, -1 above.
    private static func direction(from: Section, to: Section) -> CGFloat {
        let order = Section.allCases
        let a = order.firstIndex(of: from) ?? 0
        let b = order.firstIndex(of: to) ?? 0
        return b >= a ? 1 : -1
    }

    private var isUpdateAvailable: Bool {
        if case .available = updater.phase { return true }
        return false
    }

    /// Notchi's two eyes drawn as hollow outlines in the current foreground ink,
    /// matching the stroke weight of `PhosphorIcon(size:)` in the sidebar.
    private struct NotchiSidebarEyes: View {
        let size: CGFloat
        var body: some View {
            let h = size * 0.56
            let w = h * NotchiEyeShape.aspect
            let gap = h * NotchiEyeShape.gap
            let lineWidth = max(0.95, size * 0.075)
            HStack(spacing: gap) {
                NotchiEyeShape()
                    .stroke(.foreground, lineWidth: lineWidth)
                    .padding(lineWidth / 2)
                    .frame(width: w, height: h)
                NotchiEyeShape()
                    .stroke(.foreground, lineWidth: lineWidth)
                    .padding(lineWidth / 2)
                    .frame(width: w, height: h)
            }
            .frame(width: size, height: size)
        }
    }

    /// One category row: quiet text that brightens on hover, a faint fill when
    /// selected — same translucent-chip language as GlassMenu, minus the border.
    private struct SidebarItem: View {
        var title: String
        /// Leading glyph.
        var icon: PhosphorIcons.Mark? = nil
        /// Draws Notchi's two eyes in place of `icon` (used for About).
        var notchiEyes: Bool = false
        var selected: Bool
        /// The namespace the selection capsule moves in; nil draws none.
        var selection: Namespace.ID?
        var badged: Bool
        var isNew = false
        /// A tag at the row's trailing edge with its own destination.
        var claim: String? = nil
        var claimAction: () -> Void = {}
        /// The Buy License row, in `LicenseChipSurface`.
        var buy = false
        var action: () -> Void

        @State private var hovering = false
        @Environment(\.settingsWindowPaneHeight) private var windowPane

        private var ink: Color {
            selected ? Tokens.text1 : (hovering ? Tokens.text1.opacity(0.88) : Tokens.text3)
        }

        private var itemShape: Capsule { Capsule(style: .continuous) }

        var body: some View {
            Button(action: action) {
                content
                    .foregroundStyle(ink)
                    .background {
                        if buy {
                            Color.clear.licenseChipSurface(itemShape, hovered: hovering)
                        }
                        itemShape
                            .fill(Tokens.ink.opacity(!selected && hovering ? 0.05 : 0))
                        if selected, let selection {
                            itemShape
                                .fill(Tokens.ink.opacity(0.09))
                                .matchedGeometryEffect(id: "sidebarSelection", in: selection)
                        }
                    }
                    .contentShape(itemShape)
            }
            .buttonStyle(.plain).exemptsDoubleClickPin()
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
            .overlay(alignment: .trailing) {
                if let claim {
                    Button(action: claimAction) {
                        NewBadge(text: claim, tracking: 0)
                    }
                    .buttonStyle(.plain).exemptsDoubleClickPin()
                    .padding(.trailing, 3)
                }
            }
        }

        private var content: some View {
            HStack(spacing: 6) {
                let iconSize: CGFloat = windowPane != nil ? 15 : 13
                if notchiEyes {
                    NotchiSidebarEyes(size: iconSize)
                        .padding(.trailing, 3)
                } else if let icon {
                    PhosphorIcon(mark: icon, size: iconSize)
                        .padding(.trailing, 3)
                }
                Text(title)
                    .modifier(SettingsTypeFont(size: SettingsType.label))
                    .lineLimit(1)
                    .layoutPriority(1)
                if badged {
                    Circle()
                        .fill(Tokens.text2)
                        .frame(width: 5, height: 5)
                }
                if isNew {
                    NewBadge()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
        }
    }

    // MARK: - Header

    /// The back pill names wherever you are and walks out of it: on a category
    /// that's "Settings" → leave settings; on a pushed sub-page it takes the
    /// page's own name and steps back one level to the section that owns it,
    /// so the pill never skips a floor.
    ///
    /// The panel's alone. The window keeps its titlebar row for the traffic
    /// lights and draws its way out of a page under them — see
    /// `windowBackRow`.
    private var header: some View {
        HStack(spacing: 10) {
            if !inWindow {
                PanelBackPill(
                    title: section.isDetail ? section.title : L("settings.title"),
                    help: section.parent.map { L("navigation.backTo", $0.title) }
                        ?? L("settings.back")
                ) {
                    if let parent = section.parent {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                            section = parent
                        }
                    } else {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                            model.closeSettings()
                        }
                    }
                }
            }

            Spacer()

            // Stats' hover readout. The header is the one line in this panel with
            // standing empty space, so naming the square under the pointer costs
            // no layout anywhere — and at this height it is clear of the pane's
            // own tapers.
            statsReadout

            // Zero spacing here: the unpinned cluster draws nothing but still
            // takes a slot, and the header's 10pt spacing before it would pull
            // the trailing chrome in from the pane's right edge.
            HStack(spacing: 0) {
                // The pin, on the idle prompt's terms — the same `IdleTrailingCluster`
                // chip, in the same glass: no button at rest (⌘P is the way in), and
                // the tack appears only once the panel IS pinned, showing the hold and
                // offering the click that releases it. Recent isn't reachable from
                // Settings, so the cluster carries the pin alone. 26pt to sit at the
                // back pill's height — the header's row height feeds `headerChrome`.
                if !inWindow {
                IdleTrailingCluster(
                    pinned: model.isAnswerPinned,
                    recentOpen: false,
                    showsRecent: false,
                    chipSize: Tokens.Control.header,
                    togglePin: {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            model.toggleAnswerPin()
                        }
                    },
                    toggleRecent: {}
                )
                }
            }
        }
        .frame(height: Tokens.Control.header)
        .padding(.leading, inWindow ? Self.windowHeaderLeading - NotchBody.panelPadding : 0)
        .padding(.trailing, 8)
        .padding(.top, inWindow ? Self.windowHeaderTop : 12)
        .padding(.bottom, 4)
        .animation(.easeOut(duration: Tokens.rowFade), value: statsHover)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: model.isAnswerPinned)
    }

    /// Whether this page is a pushed sub-page in the window — the one case with
    /// somewhere to go back to.
    private var showsWindowBackRow: Bool { inWindow && section.parent != nil }

    /// The back button of a pushed page: a single left chevron in a capsule.
    private func windowNavPill(parent: Section) -> some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { section = parent }
            } label: {
                Image(icon: "chevron.left")
                    .sfFont(Tokens.TypeSize.form, weight: .semibold)
                    .foregroundStyle(Tokens.text1)
                    .frame(width: 36, height: Self.windowBackCircle)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L("navigation.backTo", parent.title)))
        }
        .glassCapsule(in: Capsule(style: .continuous), brighter: false)
    }

    /// The window's way out of a pushed page, on a line of its own: one plain
    /// circle under the traffic lights. The pill that used to sit beside them
    /// crowded the lights, and the titlebar row is the window's chrome, not the
    /// page's — so the button drops below it and carries the chevron alone.
    @ViewBuilder
    private func windowBackRow(leading: CGFloat = 18 + 8) -> some View {
        if inWindow, let parent = section.parent {
            HStack(spacing: 0) {
                windowNavPill(parent: parent)
                StandaloneWindowTitle(text: section.title)
                    .padding(.leading, 14)
                Spacer(minLength: 0)
            }
            // The pane's own gutter — 18 inside the window plus the page's 8 —
            // so the circle sits on the first row's leading edge rather than
            // the header's inset.
            .padding(.leading, leading)
            .padding(.top, Self.windowBackRowTop)
            .padding(.bottom, Self.windowBackRowBottom)
        }
    }

    /// "Aug 5 · 21 chats · 2 agent runs" — the date, and what actually went
    /// through the notch that day, bucket by bucket. Each figure carries the noun
    /// its column in the totals row carries, singular forms included ("1 chat",
    /// never "1 chats"). A day nothing happened on shows only its date — the empty
    /// square under the pointer has already said the rest.
    @ViewBuilder
    private var statsReadout: some View {
        if section == .stats || section == .about,
           let day = statsHover?.day, let stats {
            let buckets = StatsFormat.dayBreakdown(stats.breakdown[day] ?? .init())
            Text(buckets.map { L("stats.dayTip", StatsFormat.day(day), $0) }
                 ?? StatsFormat.day(day))
                // Meta weight, not label weight: this line is an annotation on
                // the square under the pointer, and at `.text3`/11 it competed
                // with the back pill across the header from it.
                .font(.sf(Tokens.TypeSize.caption).monospacedDigit())
                .foregroundStyle(Tokens.text4)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 6)
                .transition(.opacity)
        }
    }

    // MARK: - Rows

    // MARK: - Provider & API key (supporting cast)

    /// Whether the pane must surface key setup right now: a picked model is
    /// waiting on a key, or the provider these rows name has none and nothing
    /// else can answer. Only then does key UI appear unbidden.
    ///
    /// Notchi answering is exactly that "something else". A keyless vendor sitting
    /// in the rows while the balance is what runs is a setup nobody started, and
    /// unfolding a key field over it says the app is broken when it is working.
    private var setupRequired: Bool {
        pendingModel != nil || (!notchiActive && !providerReady(provider))
    }

    /// Whether `p` can answer right now: a stored/env key for a normal provider, or
    /// — for keyless Codex / Claude Code — the CLI being installed and signed in.
    /// They have no key, so the plain `current(for:) != nil` check would wrongly
    /// read them as unconfigured.
    private func providerReady(_ p: Provider) -> Bool { ModelCatalogStore.ready(p) }

    /// The collapsed-by-default key management block. At rest it's one quiet
    /// disclosure line; expanded it carries the key/account row for whichever
    /// provider it's aimed at (normally the one the Provider row names) and the
    /// where-to-get-a-key footer. A required setup (see `setupRequired`) forces it
    /// open with a one-line reason on top — which is what picking an unconfigured
    /// provider upstairs triggers.
    @ViewBuilder
    private var keySection: some View {
        // nono has no key to paste, so there is nothing here to fold away — and
        // folding it anyway, behind a chip labelled "API key", hid the Add credit
        // button that is the only thing making the provider usable. Its row
        // leads the pane instead, and carries the anchor, so the scroll-into-view
        // on a required setup still lands.
        //
        // The fold is for a key or sign-in that already works. A provider that
        // cannot answer yet shows its key or sign-in row directly.
        Group {
            if keyScope == .nono {
                EmptyView()
            } else if !providerReady(keyScope) {
                VStack(alignment: .leading, spacing: 12) {
                    keySectionBody
                }
                .id(Self.keySectionAnchor)
            } else {
                foldedKeySection
            }
        }
        // The same provider became ready while its key field was in use (a key
        // just saved): open the fold, so the field doesn't vanish under the
        // cursor. A CLI sign-in finishes elsewhere, so its row folds away.
        .onChange(of: KeyReadiness(scope: keyScope, ready: providerReady(keyScope))) { old, new in
            if old.scope == new.scope, !old.ready, new.ready, !new.scope.isCLI {
                keySectionOpen = true
            }
        }
    }

    private struct KeyReadiness: Equatable {
        let scope: Provider
        let ready: Bool
    }

    @ViewBuilder
    private var foldedKeySection: some View {
        let expanded = keySectionOpen || setupRequired
        let summary = providerReady(keyScope) ? keyScope.displayName : nil
        SettingsCollapsible(
            title: L("model.keys.section"),
            summary: summary,
            isOpen: Binding(
                get: { expanded },
                set: { wantOpen in
                    withAnimation(.easeOut(duration: 0.16)) {
                        if !wantOpen {
                            keySectionOpen = false
                            pendingModel = nil     // folding away dismisses the pending ask
                            setKeyScope(provider)  // …and the section re-tracks the backend
                        } else {
                            keySectionOpen = true
                        }
                    }
                }
            )
        ) {
            keySectionBody
        }
        // The scroller's anchor (see `paneContent`): a required setup unfolding
        // this block past the pane's height cap snaps it into view.
        .id(Self.keySectionAnchor)
    }

    /// The key section's contents: why it is asking (when it is), whose key, the
    /// custom endpoint fields, the provider's key or account row, and the
    /// where-to-get-a-key footer.
    @ViewBuilder
    private var keySectionBody: some View {
        // Why the section opened by itself, when it did.
        if let pending = pendingModel {
            Text(L("model.pending.hint", pending.provider.displayName,
                   ModelRatings.prettyName(for: pending.id,
                                           provider: pending.provider)))
                .settingsDescription(Tokens.text2)
        } else if !providerReady(provider) {
            Text(L("model.setup.needed", provider.displayName))
                .settingsDescription(Tokens.text2)
        }

        // Whose key this section is editing — shown only when that isn't the
        // provider above (the ⌘⇧I picker's "Add key" aims it elsewhere).
        // For the ordinary case the Provider row above already says it, and
        // repeating it here would read as a second, contradicting control.
        if keyScope != provider {
            settingRow(label: L("model.provider")) {
                Text(keyScope.displayName)
                    .font(.sf(Tokens.TypeSize.form))
                    .foregroundStyle(Tokens.text1)
                    .lineLimit(1)
                    .frame(height: 30)
            }
        }

        // A custom endpoint is more than a key: name, URL and model id come
        // first, because without them there's nothing for a key to unlock.
        if keyScope == .custom {
            customEndpointRows
        }

        // The CLI backends have no key to paste — each shows its sign-in status
        // row. nono and OpenRouter get their account rows (unless the user asked
        // to paste by hand, or an env var forces a key). Everyone else gets the
        // key field.
        if keyScope == .codex {
            codexAccountRow
        } else if keyScope == .claudeCode {
            claudeAccountRow
        } else if keyScope == .grokCode {
            grokAccountRow
        } else if keyScope == .commandCode {
            commandCodeAccountRow
        } else if keyScope == .cursorCode {
            cursorAccountRow
        } else if keyScope == .piCode {
            piAccountRow
        } else if keyScope == .dshCode {
            dshAccountRow
        } else if keyScope == .nono && !manualKeyEntry && !envOverride {
            nonoAccountRow
        } else if keyScope == .openrouter && !manualKeyEntry && !envOverride {
            openRouterAccountRow
        } else {
            keyRow
        }
        if keyScope == .custom {
            customSimpleRow
        }

        // The CLI backends have no key to fetch — their own rows carry the
        // sign-in copy, so the generic "get a key at …" footer is wrong for
        // them and suppressed. nono is the same case for a different
        // reason: its token is issued by the gateway and never seen, so
        // there is no key for the user to go and get.
        if !keyScope.isCLI && keyScope != .nono {
            footer
        }
    }

    /// The custom endpoint's own fields: what to call it, where to send requests,
    /// and which model id to ask for. All three are the user's — nothing about
    /// someone's private server can be guessed — so they're plain text fields, and
    /// a single Save commits them together (`saveCustom`).
    ///
    /// The resolved line under the URL is the honesty check: it shows the exact
    /// address requests will hit after normalization, so a base URL that quietly
    /// grew a `/v1/chat/completions` is visible rather than surprising.
    @ViewBuilder
    private var customEndpointRows: some View {
        customField(label: L("model.custom.name"),
                    placeholder: L("model.custom.defaultName"),
                    text: $customName)
        customField(label: L("model.custom.url"),
                    placeholder: L("model.custom.urlPlaceholder"),
                    text: $customURL,
                    suffix: customURLSuffix)
        customField(label: L("model.custom.model"),
                    placeholder: L("model.custom.modelPlaceholder"),
                    text: $customModel)
    }

    /// The custom endpoint's simple-mode switch, under its key row.
    private var customSimpleRow: some View {
        settingRow(label: L("model.custom.simple"), info: L("model.custom.simple.hint"),
                   aligned: true) {
            Toggle("", isOn: Binding(
                get: { customSimple },
                set: { on in
                    Haptics.levelChange()
                    customSimple = on
                    CustomProvider.simpleMode = on
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.switchTint)
        }
    }

    /// The path normalization appends to what the user typed (usually
    /// `/v1/chat/completions`), drawn dimmed right after the typed text so the
    /// field shows the full address requests go to. Empty when nothing is added.
    private var customURLSuffix: String {
        guard let resolved = CustomProvider.normalized(customURL)?.absoluteString else { return "" }
        var typed = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while typed.hasSuffix("/") { typed.removeLast() }
        let withScheme = typed.contains("://") ? typed : "https://" + typed
        guard resolved.hasPrefix(withScheme) else { return "" }
        return String(resolved.dropFirst(withScheme.count))
    }

    /// One labelled text field in the key section's column, matching the key row's
    /// field chrome so the block reads as one form.
    private func customField(label: String, placeholder: String,
                             text: Binding<String>, suffix: String = "") -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.sf(Tokens.TypeSize.form, weight: .regular))
                .foregroundStyle(Tokens.text2)
                .frame(width: SettingsMetrics.fieldLabelWidth, alignment: .leading)
            // One structure for every state, so the text field keeps its
            // identity and focus while the suffix appears and disappears.
            // A hidden copy of the typed text sizes the field when there is a
            // suffix; it gives up width first when the address is too long.
            HStack(spacing: 0) {
                Text(text.wrappedValue)
                    .font(.sf(Tokens.TypeSize.form))
                    .lineLimit(1)
                    .padding(.trailing, 4)
                    .hidden()
                    .frame(minWidth: 24,
                           maxWidth: suffix.isEmpty ? .infinity : nil,
                           alignment: .leading)
                    .overlay(alignment: .leading) {
                        ZStack(alignment: .leading) {
                            if text.wrappedValue.isEmpty {
                                Text(placeholder)
                                    .font(.sf(Tokens.TypeSize.form))
                                    .foregroundStyle(Tokens.placeholder)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .allowsHitTesting(false)
                            }
                            customTextField(text)
                        }
                    }
                Text(suffix)
                    .font(.sf(Tokens.TypeSize.meta))
                    .foregroundStyle(Tokens.text3)
                    .lineLimit(1)
                    .fixedSize()
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
            }
            .clipped()
            .settingsInputBox(focused: false)
        }
    }

    /// Save the custom fields 0.6 s after the last keystroke, so the model list
    /// is not refetched on every character.
    private func scheduleCustomSave() {
        customSaveTask?.cancel()
        guard canSaveCustom else { return }
        customSaveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            saveCustom()
        }
    }

    /// The plain text field used by `customField`.
    private func customTextField(_ text: Binding<String>) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .font(.sf(Tokens.TypeSize.form))
            .foregroundStyle(Tokens.text1)
            .onSubmit { saveCustom() }
            // Typing here counts as activity, so a pointer that drifted off
            // the island can't fold the panel mid-edit.
            .onChange(of: text.wrappedValue) {
                model.noteUserTyping()
                scheduleCustomSave()
            }
    }

    /// Commit the custom endpoint. The catalog is dropped first: the model list
    /// belongs to whichever server the old URL pointed at, and keeping it would
    /// offer models the new one may not serve.
    private func saveCustom() {
        customSaveTask?.cancel()
        guard canSaveCustom else { return }
        CustomProvider.name = customName
        CustomProvider.baseURL = customURL
        CustomProvider.model = customModel
        // Read back what was actually stored (trimmed / cleared), so the fields
        // show the truth rather than the draft.
        customName = CustomProvider.name
        customURL = CustomProvider.baseURL
        customModel = CustomProvider.model
        if provider == .custom { modelID = customModel }
        catalog.forget(.custom)
        testResult = nil    // the last verdict belonged to the previous endpoint
        activateIfShown(.custom)
        NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
        Task { await refreshModels() }
    }

    /// Retarget the key section onto `p`, reloading its stored key and edit
    /// state. Touches only key-editor state — never the active backend.
    private func setKeyScope(_ p: Provider) {
        guard p != keyScope else { return }
        keyScope = p
        // Re-read the custom endpoint's fields whenever the section aims at it, so
        // a switch away and back never shows a stale draft.
        customName = CustomProvider.name
        customURL = CustomProvider.baseURL
        customModel = CustomProvider.model
        apiKey = APIKeyStore.stored(for: p)
        saved = false
        testResult = nil   // last verdict belonged to the old provider/key
        manualKeyEntry = false   // back to the Connect row next time OpenRouter shows
        editingKey = apiKey.isEmpty && !APIKeyStore.hasEnvOverride(for: p)
    }

    /// The detail card's first-party pill asked to land on this provider's Model
    /// pane. Switch the displayed backend so its key section is the page in view;
    /// a no-op if it's already there.
    ///
    /// Notchi is the exception, and the reason the pill exists: it comes here for
    /// the balance card, which leads the pane whatever is selected, so there is
    /// nothing to switch.
    private func adoptPendingSettingsProvider() {
        guard let focus = model.pendingSettingsProvider else { return }
        model.pendingSettingsProvider = nil
        let addCredit = model.pendingAddCredit
        model.pendingAddCredit = false
        section = .model
        guard !focus.isFirstParty else {
            // An add-credit door in the pickers: land on Balances with the
            // amount out, so the next click is the purchase.
            if addCredit {
                showingAmount = true
                section = .balances
            }
            return
        }
        selectProvider(focus)
        setKeyScope(focus)
    }

    /// Point this pane at `newValue` and, when it can answer, make it the active
    /// backend. A provider with no key yet only opens its key field: the backend
    /// in effect stays the last one that works, and it switches once the key is
    /// saved (`activateIfShown`). The key section follows; the only state where it
    /// aims elsewhere is a pending model (picker "Add key"), which retargets it
    /// itself.
    private func selectProvider(_ newValue: Provider) {
        guard newValue != provider else { return }
        // The Provider menu is a SwiftUI `Toggle` inside `Menu`. Selecting a
        // row arrives already wrapped in the menu's implicit animation, which
        // then interpolates every identity change in this pane — the chip, the
        // key block, the first-party rim blur — and the glass behind them
        // redraws for the whole duration. That is the stutter. The swap has
        // no motion worth keeping, so the transaction is silenced here; the
        // key section's own disclosure (the chevron tap) is a different write
        // and is left alone.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            provider = newValue
            APIKeyStore.broughtProvider = newValue
            modelID = APIKeyStore.storedModel(for: newValue)
            if ModelCatalogStore.ready(newValue) {
                APIKeyStore.selectedProvider = newValue
                notchiActive = false
                NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
            } else {
                // Chosen to be set up: open its key field even while another
                // backend answers (`setupRequired` stays false then).
                keySectionOpen = true
            }
            setKeyScope(newValue)
        }
        Task { await refreshModels() }
    }

    /// The key row keeps the form's two-column grid: label in the left column,
    /// the field in the control column (sharing its left edge with the provider /
    /// model chips), and Test/Save trailing the field as quiet word-buttons —
    /// the action sits right next to the thing it acts on.
    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(L("model.apiKey"))
                    .font(.sf(Tokens.TypeSize.form, weight: .regular))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: SettingsMetrics.fieldLabelWidth, alignment: .leading)

                ZStack(alignment: .leading) {
                    if editingKey {
                        // Our own placeholder, shown only while empty — SwiftUI's built-in
                        // `prompt:` ignores the color we set and renders its own dim gray,
                        // so we overlay a Text we fully control to get a clean bright hint.
                        if apiKey.isEmpty {
                            Text(L("model.pasteKey"))
                                .font(.sf(Tokens.TypeSize.form))
                                .foregroundStyle(Tokens.placeholder)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $apiKey)
                            .textFieldStyle(.plain)
                            .font(.sf(Tokens.TypeSize.form))
                            .foregroundStyle(Tokens.text1)
                            .disabled(envOverride)
                            .focused($keyFieldFocused)
                            // Return commits the paste — same as the Save button
                            // (which also unlocks the live model list).
                            .onSubmit { save() }
                            // Editing the key invalidates the last connectivity verdict —
                            // and counts as typing, so a pointer that drifted off the
                            // island can't fold the panel mid-paste.
                            .onChange(of: apiKey) { testResult = nil; model.noteUserTyping() }
                    } else {
                        // Saved state: a masked, read-only summary — the full key
                        // never sits on screen where a screenshot would catch it.
                        Text(maskedKey)
                            .font(.sf(Tokens.TypeSize.form))
                            .foregroundStyle(Tokens.text2)
                            .lineLimit(1)
                    }
                }
                .settingsInputBox(focused: keyFieldFocused)
                .opacity(envOverride ? 0.5 : 1)
                // The saved key's field is the way back into editing.
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !editingKey, !envOverride else { return }
                    startEditingKey()
                }

                if editingKey {
                    // While editing, only Save (and Cancel) — Test is deliberately
                    // withheld until the key is saved, so a connectivity check always
                    // probes the *stored* key, never an unsaved draft.
                    // Back out of editing without touching the stored key — only
                    // offered when there is a stored key to fall back to.
                    if !APIKeyStore.stored(for: keyScope).isEmpty {
                        SettingActionButton(title: L("model.cancel")) { stopEditingKey() }
                    }
                } else if !envOverride {
                    // Saved state allows a liveness check of the stored key, plus
                    // the way back into editing.
                    if testing {
                        ProgressView().controlSize(.small)
                    } else {
                        SettingActionButton(title: L("model.test")) { test() }
                    }
                }
                // One control: the button itself flips to "Saved" for a beat after
                // a save, then settles back to "Save" — no separate badge, no green
                // checkmark, just the panel's own light text.
                if editingKey || canSave || saved {
                    SettingActionButton(title: saved ? L("model.saved") : L("model.save"),
                                        tone: canSave || saved ? Tokens.text2 : Tokens.text4) { save() }
                        .disabled(!canSave && !saved)
                        .animation(.easeOut(duration: 0.2), value: saved)
                }
            }

            if let result = testResult {
                testVerdict(result)
                    // Indent under the control column so the verdict hangs off the
                    // field it judges, not the label gutter.
                    .padding(.leading, SettingsMetrics.fieldIndent)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// The search-backend picker. Exactly like the model picker: you pick one and
    /// that's what runs — no "Default" row, no native fallback. The picker always
    /// resolves to a concrete backend, and only that backend's key row shows below.
    private var searchBackendRow: some View {
        settingRow(label: L("search.backend")) {
            GlassMenu(title: searchBackendLabel(selectedBackend),
                      items: APIKeyStore.SearchBackend.allCases.map { b in
                GlassMenuItem(title: searchBackendLabel(b), selected: b == selectedBackend) {
                    selectSearchBackend(b)
                }
            })
        }
    }

    /// The concrete backend the picker shows — the stored pick, or the first case
    /// when nothing has been chosen yet (there's no "none" state in the UI).
    private var selectedBackend: APIKeyStore.SearchBackend {
        searchBackend ?? APIKeyStore.SearchBackend.allCases[0]
    }

    private func searchBackendLabel(_ b: APIKeyStore.SearchBackend) -> String {
        switch b {
        case .keenable: return L("search.backend.keenable")
        case .exa:      return L("search.backend.exa")
        case .anysearch: return L("search.backend.anysearch")
        case .deepseek:  return "DeepSeek"
        }
    }

    private func selectSearchBackend(_ newValue: APIKeyStore.SearchBackend) {
        // Compare against the stored pick (not the display default) so the first
        // commit from a `nil` state still persists even when it equals the default.
        guard newValue != searchBackend else { return }
        searchBackend = newValue
        APIKeyStore.preferredSearchBackend = newValue
        NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
    }

    /// The Keenable search-key row — a standalone keyed search backend. Same
    /// grid/edit/mask lifecycle as the Exa row; the hint says where to get a key.
    private var keenableKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("model.keenableApiKey"))
                    .font(.sf(Tokens.TypeSize.form, weight: .regular))
                    .foregroundStyle(Tokens.text1)
                    .lineLimit(1)
                    .frame(width: SettingsMetrics.searchKeyLabelWidth, alignment: .leading)

                ZStack(alignment: .leading) {
                    if editingKeenableKey {
                        if keenableKey.isEmpty {
                            Text(L("model.keenablePasteKey"))
                                .font(.sf(Tokens.TypeSize.label))
                                .foregroundStyle(Tokens.placeholder)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $keenableKey)
                            .textFieldStyle(.plain)
                            .font(.sf(Tokens.TypeSize.label))
                            .foregroundStyle(Tokens.text1)
                            .disabled(keenableEnvOverride)
                            .focused($searchKeyFocused)
                            .onSubmit { saveKeenableKey() }
                            // Typing here must hold off the hover-leave fold too.
                            .onChange(of: keenableKey) { model.noteUserTyping() }
                    } else {
                        Text(maskedKeenableKey)
                            .font(.sf(Tokens.TypeSize.label))
                            .foregroundStyle(Tokens.text2)
                            .lineLimit(1)
                    }
                }
                .settingsInputBox(focused: searchKeyFocused, height: Tokens.Control.header)
                .opacity(keenableEnvOverride ? 0.5 : 1)

                if editingKeenableKey {
                    if !APIKeyStore.storedKeenableKey().isEmpty {
                        SettingActionButton(title: L("model.cancel")) { stopEditingKeenableKey() }
                    }
                } else if !keenableEnvOverride {
                    SettingActionButton(title: L("model.change")) { editingKeenableKey = true }
                }
                if editingKeenableKey || canSaveKeenable || keenableSaved {
                    SettingActionButton(title: keenableSaved ? L("model.saved") : L("model.save"),
                                        tone: canSaveKeenable || keenableSaved ? Tokens.text2 : Tokens.text4) { saveKeenableKey() }
                        .disabled(!canSaveKeenable && !keenableSaved)
                        .animation(.easeOut(duration: 0.2), value: keenableSaved)
                }
            }

            // Where to get the key, on the line under the row.
            if !keenableEnvOverride {
                SettingInfo(keenableHintText)
            }

            // Only the live env-override status stays inline (it explains why the
            // field is locked); the how-to note is the line above.
            if keenableEnvOverride {
                Text(L("model.footer.env", "KEENABLE_API_KEY"))
                    .font(.sf(Tokens.TypeSize.meta))
                    .foregroundStyle(Tokens.text4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, SettingsMetrics.searchKeyIndent)
            }
        }
    }

    /// The Keenable hint with `keenable.ai` as a clickable link.
    private var keenableHintText: AttributedString {
        var text = AttributedString(L("model.keenableHint"))
        var host = AttributedString(L("model.keenableHint.host"))
        host.link = URL(string: "https://keenable.ai")
        host.foregroundColor = Tokens.text2
        text.append(host)
        return text
    }

    /// The Exa search-key row — same grid and edit/mask lifecycle as `keyRow`, but
    /// for the provider-agnostic search backend. No Test button (nothing model-side
    /// to probe) and a one-line hint below explaining the override + where to get a
    /// key. Hidden field stays masked once saved, like the provider key.
    private var exaKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("model.exaApiKey"))
                    .font(.sf(Tokens.TypeSize.form, weight: .regular))
                    .foregroundStyle(Tokens.text1)
                    .lineLimit(1)
                    .frame(width: SettingsMetrics.searchKeyLabelWidth, alignment: .leading)

                ZStack(alignment: .leading) {
                    if editingExaKey {
                        if exaKey.isEmpty {
                            Text(L("model.exaPasteKey"))
                                .font(.sf(Tokens.TypeSize.label))
                                .foregroundStyle(Tokens.placeholder)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $exaKey)
                            .textFieldStyle(.plain)
                            .font(.sf(Tokens.TypeSize.label))
                            .foregroundStyle(Tokens.text1)
                            .disabled(exaEnvOverride)
                            .focused($searchKeyFocused)
                            .onSubmit { saveExaKey() }
                            // Typing here must hold off the hover-leave fold too.
                            .onChange(of: exaKey) { model.noteUserTyping() }
                    } else {
                        Text(maskedExaKey)
                            .font(.sf(Tokens.TypeSize.label))
                            .foregroundStyle(Tokens.text2)
                            .lineLimit(1)
                    }
                }
                .settingsInputBox(focused: searchKeyFocused, height: Tokens.Control.header)
                .opacity(exaEnvOverride ? 0.5 : 1)

                if editingExaKey {
                    // Cancel only when there's a stored key to fall back to.
                    if !APIKeyStore.storedExaKey().isEmpty {
                        SettingActionButton(title: L("model.cancel")) { stopEditingExaKey() }
                    }
                } else if !exaEnvOverride {
                    SettingActionButton(title: L("model.change")) { editingExaKey = true }
                }
                if editingExaKey || canSaveExa || exaSaved {
                    SettingActionButton(title: exaSaved ? L("model.saved") : L("model.save"),
                                        tone: canSaveExa || exaSaved ? Tokens.text2 : Tokens.text4) { saveExaKey() }
                        .disabled(!canSaveExa && !exaSaved)
                        .animation(.easeOut(duration: 0.2), value: exaSaved)
                }
            }

            // Where to get the key, on the line under the row.
            if !exaEnvOverride {
                SettingInfo(exaHintText)
            }

            // Only the live env-override status stays inline; the how-to note
            // is the line above.
            if exaEnvOverride {
                Text(L("model.footer.env", "EXA_API_KEY"))
                    .font(.sf(Tokens.TypeSize.meta))
                    .foregroundStyle(Tokens.text4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, SettingsMetrics.searchKeyIndent)
            }
        }
    }

    /// The Exa hint with `exa.ai` as a clickable link, built as one `AttributedString`
    /// so the sentence stays a single `Text` while only the host opens the signup page.
    private var exaHintText: AttributedString {
        var text = AttributedString(L("model.exaHint"))
        var host = AttributedString(L("model.exaHint.host"))
        host.link = URL(string: "https://exa.ai")
        host.foregroundColor = Tokens.text2
        text.append(host)
        return text
    }

    /// Optional AnySearch key. With no key the summary remains actionable and
    /// says "Anonymous tier"; authenticated requests use the same masked/edit
    /// lifecycle as the other standalone search backends.
    private var anySearchKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("model.anysearchApiKey"))
                    .font(.sf(Tokens.TypeSize.form, weight: .regular))
                    .foregroundStyle(Tokens.text1)
                    .lineLimit(1)
                    .frame(width: SettingsMetrics.searchKeyLabelWidth, alignment: .leading)

                ZStack(alignment: .leading) {
                    if editingAnySearchKey {
                        if anySearchKey.isEmpty {
                            Text(L("model.anysearchPasteKey"))
                                .font(.sf(Tokens.TypeSize.label))
                                .foregroundStyle(Tokens.placeholder)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $anySearchKey)
                            .textFieldStyle(.plain)
                            .font(.sf(Tokens.TypeSize.label))
                            .foregroundStyle(Tokens.text1)
                            .disabled(anySearchEnvOverride)
                            .focused($searchKeyFocused)
                            .onSubmit { saveAnySearchKey() }
                            .onChange(of: anySearchKey) { model.noteUserTyping() }
                    } else {
                        Text(maskedAnySearchKey)
                            .font(.sf(Tokens.TypeSize.label))
                            .foregroundStyle(Tokens.text2)
                            .lineLimit(1)
                    }
                }
                .settingsInputBox(focused: searchKeyFocused, height: Tokens.Control.header)
                .opacity(anySearchEnvOverride ? 0.5 : 1)

                if editingAnySearchKey {
                    SettingActionButton(title: L("model.cancel")) { stopEditingAnySearchKey() }
                } else if !anySearchEnvOverride {
                    SettingActionButton(
                        title: APIKeyStore.storedAnySearchKey().isEmpty
                            ? L("model.addKey") : L("model.change")
                    ) { editingAnySearchKey = true }
                }
                if editingAnySearchKey || canSaveAnySearch || anySearchSaved {
                    SettingActionButton(
                        title: anySearchSaved ? L("model.saved") : L("model.save"),
                        tone: canSaveAnySearch || anySearchSaved ? Tokens.text2 : Tokens.text4
                    ) { saveAnySearchKey() }
                        .disabled(!canSaveAnySearch && !anySearchSaved)
                        .animation(.easeOut(duration: 0.2), value: anySearchSaved)
                }
            }

            // Where to get the key, on the line under the row.
            if !anySearchEnvOverride {
                SettingInfo(anySearchHintText)
            }

            if anySearchEnvOverride {
                Text(L("model.footer.env", "ANYSEARCH_API_KEY"))
                    .font(.sf(Tokens.TypeSize.meta))
                    .foregroundStyle(Tokens.text4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, SettingsMetrics.searchKeyIndent)
            }
        }
    }

    /// The DeepSeek search-key row. Same lifecycle as the AnySearch row, but it
    /// reads and writes the DeepSeek provider key.
    private var deepSeekSearchKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("model.deepseekSearchApiKey"))
                    .font(.sf(Tokens.TypeSize.form, weight: .regular))
                    .foregroundStyle(Tokens.text1)
                    .lineLimit(1)
                    .frame(width: SettingsMetrics.searchKeyLabelWidth, alignment: .leading)

                ZStack(alignment: .leading) {
                    if editingDeepSeekSearchKey {
                        if deepSeekSearchKey.isEmpty {
                            Text(L("model.deepseekSearchPasteKey"))
                                .font(.sf(Tokens.TypeSize.label))
                                .foregroundStyle(Tokens.placeholder)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $deepSeekSearchKey)
                            .textFieldStyle(.plain)
                            .font(.sf(Tokens.TypeSize.label))
                            .foregroundStyle(Tokens.text1)
                            .disabled(deepSeekSearchEnvOverride)
                            .focused($searchKeyFocused)
                            .onSubmit { saveDeepSeekSearchKey() }
                            .onChange(of: deepSeekSearchKey) { model.noteUserTyping() }
                    } else {
                        Text(maskedDeepSeekSearchKey)
                            .font(.sf(Tokens.TypeSize.label))
                            .foregroundStyle(Tokens.text2)
                            .lineLimit(1)
                    }
                }
                .settingsInputBox(focused: searchKeyFocused, height: Tokens.Control.header)
                .opacity(deepSeekSearchEnvOverride ? 0.5 : 1)

                if editingDeepSeekSearchKey {
                    SettingActionButton(title: L("model.cancel")) { stopEditingDeepSeekSearchKey() }
                } else if !deepSeekSearchEnvOverride {
                    SettingActionButton(
                        title: APIKeyStore.stored(for: .deepseek).isEmpty
                            ? L("model.addKey") : L("model.change")
                    ) {
                        deepSeekSearchKey = APIKeyStore.stored(for: .deepseek)
                        editingDeepSeekSearchKey = true
                    }
                }
                if editingDeepSeekSearchKey || canSaveDeepSeekSearch || deepSeekSearchSaved {
                    SettingActionButton(
                        title: deepSeekSearchSaved ? L("model.saved") : L("model.save"),
                        tone: canSaveDeepSeekSearch || deepSeekSearchSaved ? Tokens.text2 : Tokens.text4
                    ) { saveDeepSeekSearchKey() }
                        .disabled(!canSaveDeepSeekSearch && !deepSeekSearchSaved)
                        .animation(.easeOut(duration: 0.2), value: deepSeekSearchSaved)
                }
            }

            // Where to get the key, on the line under the row.
            if !deepSeekSearchEnvOverride {
                SettingInfo(deepSeekSearchHintText)
            }

            if deepSeekSearchEnvOverride {
                Text(L("model.footer.env", Provider.deepseek.envVarName))
                    .font(.sf(Tokens.TypeSize.meta))
                    .foregroundStyle(Tokens.text4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, SettingsMetrics.searchKeyIndent)
            }
        }
    }

    private var deepSeekSearchHintText: AttributedString {
        var text = AttributedString(L("model.deepseekSearchHint"))
        var host = AttributedString(L("model.deepseekSearchHint.host"))
        host.link = URL(string: "https://platform.deepseek.com/api_keys")
        host.foregroundColor = Tokens.text2
        text.append(host)
        return text
    }

    private var anySearchHintText: AttributedString {
        var text = AttributedString(L("model.anysearchHint"))
        var host = AttributedString(L("model.anysearchHint.host"))
        host.link = URL(string: "https://www.anysearch.com/console/api-keys")
        host.foregroundColor = Tokens.text2
        text.append(host)
        return text
    }

    /// The connectivity-test result, as a status line (see `statusPill`).
    @ViewBuilder
    private func testVerdict(_ result: ConnectivityTest.Result) -> some View {
        statusPill(ok: result.isOK, message: result.message)
    }

    /// The status line under a key/account field. Success reads as a quiet aside
    /// in faint text, in the same register as the rest of the panel.
    @ViewBuilder
    private func statusPill(ok: Bool, message: String) -> some View {
        Text(message)
            .modifier(SettingsTypeFont(size: SettingsType.description))
            .foregroundStyle(ok ? Tokens.text2 : Tokens.danger)
            .padding(.top, 1)
    }

    // MARK: - Notchi Balance

    /// Notchi Balance is the only first-party backend, so instead of a key to
    /// paste it shows what the wallet holds and offers to add to it. The token
    /// is fetched on first appearance and kept like any other provider's key;
    /// the user never sees it, because it is not something they chose or can
    /// usefully copy.
    ///
    /// On the Model pane this is one row that opens Balances: label left, the
    /// figure and a chevron right. Adding credit, and the links, are on that
    /// page (`nonoBalanceDetail`), so the pane carries one purchase action,
    /// the card's.
    @ViewBuilder
    private var nonoAccountRow: some View {
        let snapshot = nono.snapshot
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    nonoCreditLabel(snapshot)
                    nonoCreditHint(snapshot)
                }
                Spacer(minLength: 10)
                if nonoRegistering {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("nono.preparing"))
                            .font(.sf(Tokens.TypeSize.meta))
                            .foregroundStyle(Tokens.text2)
                    }
                } else if let snapshot {
                    HStack(spacing: 8) {
                        nonoFigure(snapshot, prominent: false)
                        Image(icon: "chevron.right")
                            .font(.sf(Tokens.TypeSize.badge, weight: .regular))
                            .foregroundStyle(Tokens.text4)
                            .opacity(balanceEntryHovering ? 1 : 0.6)
                    }
                } else if case .failed(let why) = nono.phase {
                    statusPill(ok: false, message: why)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    // `/me` is still in flight — the first appearance after a
                    // launch. A spinner, not a guess: drawing $0.00 tells someone
                    // who has credit that they have none.
                    ProgressView().controlSize(.small)
                }
            }
            .frame(minHeight: 30)
            .contentShape(Rectangle())
            .onTapGesture {
                guard snapshot != nil, !nonoRegistering else { return }
                open(.balances)
            }
            .onHover { balanceEntryHovering = $0 }
            .animation(.easeOut(duration: Tokens.rowFade), value: balanceEntryHovering)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The card shows no rates, so it fetches no catalog to draw itself.
        // `pricingSection` asks for them when it opens.
        .task { await nono.load() }
    }

    /// The locked Settings page (`NotchiLicense.locked`): the main action is
    /// Buy License; the two export links open the memory and chat history folders in Finder.
    private var lockedPage: some View {
        ZStack {
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
            VStack(spacing: 18) {
                Text(L("license.locked.title"))
                    .font(.sf(Tokens.TypeSize.reading, weight: .medium))
                    .foregroundStyle(Tokens.text1)
                    .multilineTextAlignment(.center)
                VStack(spacing: 14) {
                    BuyButtonFace(title: L("license.sidebar.buy"), busy: false,
                                  fullWidth: true, gradient: true) {
                        openLicenseOffer()
                    }
                    HStack(spacing: 16) {
                        UnderlineLink(title: L("license.locked.export"), external: true) {
                            NSWorkspace.shared.open(UserMemory.folder)
                        }
                        .fixedSize()
                        // history.json and HistoryImages live in this folder.
                        UnderlineLink(title: L("license.locked.exportHistory"), external: true) {
                            let folder = FileManager.default.urls(for: .applicationSupportDirectory,
                                                                  in: .userDomainMask)[0]
                                .appendingPathComponent("Notch", isDirectory: true)
                            NSWorkspace.shared.open(folder)
                        }
                        .fixedSize()
                    }
                }
            }
            .frame(width: 260)
        }
        .padding(.horizontal, -NotchBody.panelPadding)
        .padding(.top, -NotchBody.panelPadding)
        .padding(.bottom, -NotchBody.panelPadding)
        .transition(.opacity)
    }

    private func openLicenseOffer(keyField: Bool = false) {
        guard let host = settingsHostWindow.window else { return }
        licenseOfferOpen = true
        LicenseOfferWindow.shared.show(over: host, startWithKeyField: keyField) {
            closeLicenseOffer()
        }
    }

    private func closeLicenseOffer() {
        licenseOfferOpen = false
        LicenseOfferWindow.shared.close()
    }

    /// The License pane: the passport, and under it the purchase row while
    /// this account has to buy. Shut until it holds a license; then open on
    /// the key (a click copies it) and the stamp: Activated, or Founding
    /// Activated for an account registered before the cutoff.
    private var licensePane: some View {
        let needed = license.needsPurchase
        let stamp: String? = license.freeForGood ? L("license.stamp.founding")
            : (license.key != nil ? L("license.state.activated") : nil)
        return VStack(spacing: 16) {
            SettingsPassport(
                shut: needed,
                stamp: stamp,
                keyText: license.maskedKey.map { licenseKeyCopied ? L("license.copied") : $0 },
                note: nil,
                onCover: { openLicenseOffer() },
                onKey: { if let key = license.key { copyLicenseKey(key) } })
            // Under the window's left-aligned page title the card starts on
            // the same edge; the panel centres it.
            .frame(maxWidth: .infinity, alignment: inWindow ? .leading : .center)
            .padding(.top, 4)
            if needed, nono.snapshot != nil, !nonoRegistering {
                licenseRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await nono.load() }
        .onChange(of: license.status) { old, new in
            if case .active = new, old != new {
                enteringLicenseKey = false
                licenseKeyDraft = ""
            }
        }
    }

    /// The license row: the Balance row's shape, with its Add credit
    /// interaction. One button; "Enter key" is the chip beside it, and opening
    /// it unfolds the field to the button's left, the way the amount stepper
    /// does, with the button becoming the commit.
    /// The field is out. A debug render can force it (`_debugLicenseRow`).
    private var showsKeyField: Bool {
        #if DEBUG
        if Self._debugEntering { return true }
        #endif
        return enteringLicenseKey
    }

    private var licenseRow: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text(L("license.label"))
                    .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                    .foregroundStyle(Tokens.text2)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 10)
                // Collapsed, two chips, as the Balance row is one ("Add"). The
                // key field and its 30pt commit button come out together, as
                // the amount stepper and Add do.
                HStack(spacing: 8) {
                    if license.key != nil {
                        // Just bought or activated: the verdict. The key is
                        // on the card above.
                        Text(L("license.state.activated"))
                            .font(.sf(Tokens.TypeSize.form + 1))
                            .foregroundStyle(Tokens.text1)
                            .fixedSize()
                    } else if showsKeyField {
                        licenseKeyField
                            .transition(.scale(scale: 0.86, anchor: .trailing).combined(with: .opacity))
                        if license.phase == .activating {
                            ProgressView().controlSize(.small)
                                .frame(width: 30, height: 30)
                        } else {
                            Button { licenseAction() } label: {
                                AddCreditButtonFace(title: L("license.activate"), lit: addCreditHovering,
                                                    compact: true, height: 30)
                            }
                            .buttonStyle(GlassPressStyle())
                            .onHover { addCreditHovering = $0 }
                            .animation(.easeOut(duration: Tokens.hoverFade), value: addCreditHovering)
                        }
                    } else {
                        // The price in the Balance figure's type, its action
                        // the chip beside it.
                        Text(license.priceText)
                            .font(.sf(Tokens.TypeSize.form + 1))
                            .foregroundStyle(Tokens.text1)
                            .monospacedDigit()
                            .fixedSize()
                        if license.phase == .buying {
                            ProgressView().controlSize(.small)
                        } else {
                            ChipLink(title: L("license.buyShort"), license: true) { licenseAction() }
                                .padding(.leading, 4)
                        }
                    }
                }
                .frame(minHeight: 30)
            }
            // Under the price: what the purchase covers, and the way in for
            // someone who already holds a key.
            if license.key == nil, !showsKeyField {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(L("license.offer.body"))
                        .font(.sf(Tokens.TypeSize.meta))
                        .foregroundStyle(Tokens.text3)
                        .lineLimit(metrics.noteLines(1))
                        .fixedSize(horizontal: false, vertical: true)
                        .truncationMode(.tail)
                    Spacer(minLength: 10)
                    UnderlineLink(title: L("license.enterKey")) {
                        license.clearFailure()
                        enteringLicenseKey = true
                    }
                    .fixedSize()
                }
                .padding(.top, 2)
                .padding(.bottom, 4)
            }
            if case .failed(let why) = license.phase {
                statusPill(ok: false, message: why)
                    .padding(.top, 6)
            } else if license.awaitingPayment, license.needsPurchase {
                statusPill(ok: true, message: L("connector.waiting"))
                    .padding(.top, 6)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82), value: enteringLicenseKey)
        .onAppear { takeKeyEntryRequest() }
        .onChange(of: license.wantsKeyEntry) { takeKeyEntryRequest() }
        .onDisappear { licenseJustActivated = false }
    }

    private var licenseKeyField: some View {
        ZStack(alignment: .leading) {
            if licenseKeyDraft.isEmpty {
                Text(L("license.keyPlaceholder"))
                    .font(.sf(Tokens.TypeSize.label))
                    .foregroundStyle(Tokens.text4)
                    .allowsHitTesting(false)
            }
            TextField("", text: $licenseKeyDraft)
                .textFieldStyle(.plain)
                .font(.system(size: Tokens.TypeSize.label, design: .monospaced))
                .foregroundStyle(Tokens.text1)
                .focused($licenseKeyFocused)
                .onSubmit { licenseAction() }
                .onExitCommand { closeKeyEntry() }
                .onChange(of: licenseKeyDraft) {
                    license.clearFailure()
                    model.noteUserTyping()
                }
        }
        .frame(width: 252)
        .settingsInputBox(focused: licenseKeyFocused, height: SettingsUI.heightMD)
    }

    /// Buy; with the field open, activate what is in it, or close an empty one.
    private func licenseAction() {
        license.clearFailure()
        guard enteringLicenseKey else {
            Task { await license.buy() }
            return
        }
        let draft = licenseKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return closeKeyEntry() }
        Task {
            if await license.activate(draft) { closeKeyEntry() }
        }
    }

    private func copyLicenseKey(_ key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        licenseKeyCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            licenseKeyCopied = false
        }
    }

    private func closeKeyEntry() {
        enteringLicenseKey = false
        licenseKeyDraft = ""
        license.clearFailure()
    }

    /// The offer card's "Enter key" opened Settings: open the field.
    private func takeKeyEntryRequest() {
        guard license.wantsKeyEntry else { return }
        license.wantsKeyEntry = false
        if license.needsPurchase {
            openLicenseOffer(keyField: true)
            return
        }
        enteringLicenseKey = true
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            licenseKeyFocused = true
        }
    }

    /// Whether the first `/me` is still registering the account — the moment
    /// when there is no balance worth drawing yet.
    private var nonoRegistering: Bool {
        if case .working(.registering) = nono.phase { return true }
        return false
    }

    private func open(_ page: Section) {
        let direction = Self.direction(from: section, to: page)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
            labelColumnWidth = Self.labelColumnWidths[page] ?? 0   // see `showSection`
            paneDirection = direction
            section = page
        }
    }

    /// What the account holds: gift and bought credit together.
    @State private var balanceEntryHovering = false

    private func nonoCreditLabel(_ snapshot: NoNoAccount.Snapshot?) -> some View {
        // The pane's row label, like every other row's: a smaller, grayer
        // label sat under its own description's size in the window.
        Text(L("nono.credit"))
            .modifier(SettingsTypeFont(size: SettingsType.label))
            .foregroundStyle(Tokens.text1)
            .lineLimit(1)
            .fixedSize()
    }

    /// How the balance is spent — prepaid, per token, no expiry — on the line
    /// under the credit row.
    @ViewBuilder
    private func nonoCreditHint(_ snapshot: NoNoAccount.Snapshot?) -> some View {
        if let snapshot {
            SettingInfo(L(snapshot.hasGift ? "nono.lineup.billing.gift" : "nono.lineup.billing"))
        }
    }

    /// The balance. Opened from the prompt's grant chip, the figure starts at
    /// the balance before the grant and rolls up to the current one (see
    /// `NoNoAccount.claimGrant`). The animation has to ride the Text itself
    /// for `numericText` to fire (see `StatsFigure`). `prominent` is the
    /// Balances page's own figure; the Model pane's entry row draws it lighter.
    private func nonoFigure(_ snapshot: NoNoAccount.Snapshot, prominent: Bool) -> some View {
        let shownUSD = nono.rollFromUSD ?? snapshot.credit.remainingUSD
        return Text(Self.money(shownUSD))
            .font(.sf(prominent ? Tokens.TypeSize.form + 1 : Tokens.TypeSize.form))
            .foregroundStyle(prominent ? Tokens.text1 : Tokens.text2)
            .monospacedDigit()
            .contentTransition(.numericText(value: shownUSD))
            .animation(reduceMotion ? nil : .snappy(duration: 0.6), value: shownUSD)
            .lineLimit(1)
            .fixedSize()
            .task(id: nono.rollFromUSD != nil) {
                guard nono.rollFromUSD != nil else { return }
                // Let the settings pane finish opening so the roll is seen.
                try? await Task.sleep(for: .milliseconds(450))
                nono.finishGrantRoll()
            }
    }

    /// The head of the Balances page: the balance with Add credit, then the
    /// ways out (Pricing, Usage, Privacy), and on the Balances page itself the
    /// way to the receipts.
    @ViewBuilder
    private var nonoBalanceDetail: some View {
        if let snapshot = nono.snapshot, !nonoRegistering {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        nonoCreditLabel(snapshot)
                        nonoCreditHint(snapshot)
                    }
                    Spacer(minLength: 10)
                    nonoCreditRow(snapshot)
                }
                .frame(minHeight: 30)
                // The first two open a sub-page. Privacy leaves the app, the
                // same page About opens, so it carries the outbound arrow.
                HStack(spacing: 14) {
                    Spacer(minLength: 0)
                    UnderlineLink(title: L("model.pricing")) { open(.pricing) }
                    UnderlineLink(title: L("model.usage")) { open(.usage) }
                    UnderlineLink(title: L("nono.privacy.link"), external: true) {
                        LinkGate.shared.open(URL(string: "https://www.notch.website/privacy")!)
                    }
                    // Also outbound, to Stripe's portal. It sits with the other
                    // ways out rather than alone in the window's titlebar, where
                    // it was the only thing on the row.
                    if section == .balances,
                       balanceLines.contains(where: { $0.kind != .gift }) || license.purchasedAt != nil {
                        UnderlineLink(title: L("nono.receipts"), external: true) {
                            Task { await nono.manageBilling() }
                        }
                    }
                }
                .padding(.top, 10)
                // The one state the figures cannot explain on their own: there
                // is money in the account and it still will not spend.
                if snapshot.cappedForToday {
                    Text(L("nono.dailyCap"))
                        .font(.sf(Tokens.TypeSize.meta))
                        .foregroundStyle(Tokens.text4)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func nonoCreditRow(_ snapshot: NoNoAccount.Snapshot) -> some View {
        HStack(alignment: .center, spacing: 8) {
            nonoFigure(snapshot, prominent: true)
            if showingAmount {
                addCreditButton(bought: snapshot.credit.grantedUSD)
                    .padding(.leading, 4)
            } else {
                ChipLink(title: L("nono.add")) { showingAmount = true }
                    .padding(.leading, 4)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82),
                   value: showingAmount)
    }

    /// One row of the wallet's lineup: the name the picker already uses, and
    /// the two rates the gateway charges against this balance. `pricing` is nil
    /// until `/v1/models` has landed — a missing price is omitted rather than
    /// guessed, because a stale figure here is a price the buyer was quoted.
    private struct NonoLineupRow: Identifiable {
        let id: String
        let name: String
        let info: ModelInfo
        var pricing: ModelCatalog.ModelList.Entry.NotchiPricing? { info.notchiPricing }
    }

    /// Names and prices from the live catalog, falling back to the bundled
    /// ids so the list is never empty for someone looking at a funded
    /// wallet before the fetch has returned.
    private var nonoLineupRows: [NonoLineupRow] {
        if let live = catalog.liveByProvider[.nono], !live.isEmpty {
            return live.map { info in
                // Blend's product name is written here, same as the picker,
                // so the two cannot drift. Named-shelf entries keep the
                // catalog's own name — that is the reason they are named.
                let name = (info.id == "nono-flash" || info.id == "nono")
                    ? ModelRatings.nonoName(for: info.id)
                    : info.name
                return NonoLineupRow(id: info.id, name: name, info: info)
            }
        }
        return Provider.nono.availableModels.map { id in
            NonoLineupRow(id: id, name: ModelRatings.prettyName(for: id, provider: .nono),
                          info: ModelInfo(id: id, vendor: ModelRatings.vendor(for: id, provider: .nono)))
        }
    }

    /// What this balance pays for: every model the gateway serves and the
    /// rates it charges against the wallet. Not
    /// a picker — picking happens on the panel. One rule under the header, none
    /// between rows; it refetches the rates each time it opens.
    private var pricingSection: some View {
        VStack(spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                GridRow {
                    Text(L("nono.usage.col.model")).settingsCaption()
                    Text(L("nono.pricing.input")).settingsCaption()
                        .gridColumnAlignment(.trailing)
                    Text(L("nono.pricing.cached")).settingsCaption()
                        .gridColumnAlignment(.trailing)
                    Text(L("nono.pricing.output")).settingsCaption()
                        .gridColumnAlignment(.trailing)
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .gridColumnAlignment(.trailing)
                }
                .padding(.bottom, 8)

                Divider().overlay(Tokens.hairline).gridCellColumns(5)

                // Free models first, pay-as-you-go after. One set of column
                // headers over both runs, so the rates still line up across
                // them. A lineup that is all one kind gets no headings.
                let rows = Self.cheapestFirst(NotchiModelVisibility.ordered(nonoLineupRows, id: \.id))
                let free = rows.filter { Self.isFree($0) }
                let paid = Self.byVendor(rows.filter { !Self.isFree($0) })
                if !free.isEmpty, !paid.isEmpty {
                    pricingGroupHeader(L("nono.pricing.freeModels"))
                        .padding(.top, 12)
                    ForEach(free) { row in
                        pricingRow(row)
                    }
                    pricingGroupHeader(L("nono.pricing.payAsYouGo"))
                        .padding(.top, 18)
                    ForEach(paid) { row in
                        pricingRow(row)
                    }
                } else {
                    ForEach(free.isEmpty ? paid : rows) { row in
                        pricingRow(row)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await refreshNonoRates() }
    }

    /// Current input rate, then output, free models first. A row with no rates
    /// goes last; ties keep the order they came in.
    private static func cheapestFirst(_ rows: [NonoLineupRow]) -> [NonoLineupRow] {
        rows.enumerated().sorted { a, b in
            let left = a.element.pricing, right = b.element.pricing
            let leftRates = (left?.inputPerMTok ?? .infinity, left?.outputPerMTok ?? .infinity)
            let rightRates = (right?.inputPerMTok ?? .infinity, right?.outputPerMTok ?? .infinity)
            if leftRates != rightRates { return leftRates < rightRates }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// OpenAI, Anthropic, Google, then every other vendor. Rows of one vendor
    /// keep the order they came in (cheapest first).
    private static func byVendor(_ rows: [NonoLineupRow]) -> [NonoLineupRow] {
        let order = ["OpenAI", "Anthropic", "Google"]
        func rank(_ row: NonoLineupRow) -> Int { order.firstIndex(of: row.info.vendor) ?? order.count }
        return rows.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// Input and output both $0. A row whose rates have not loaded is not free.
    private static func isFree(_ row: NonoLineupRow) -> Bool {
        guard let pricing = row.pricing else { return false }
        return pricing.inputPerMTok == 0 && pricing.outputPerMTok == 0
            && (pricing.cachedInputPerMTok ?? 0) == 0
    }

    private func pricingGroupHeader(_ title: String) -> some View {
        Text(title)
            .settingsCaption()
            .frame(maxWidth: .infinity, alignment: .leading)
            .gridCellColumns(5)
            .padding(.bottom, 2)
    }

    private func pricingRow(_ row: NonoLineupRow) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                // Logo centered on the name line; the notes below indent to
                // the name.
                HStack(alignment: .center, spacing: 7) {
                    // Same mark and size as the model picker's closed label.
                    VendorLogo(vendor: ModelRatings.vendor(for: row.id, provider: .nono),
                               fallback: row.id)
                        .frame(width: 15, height: 15)
                    HStack(spacing: 4) {
                        Text(row.name)
                            .font(.sf(Tokens.TypeSize.meta + 0.5, weight: .regular))
                            .foregroundStyle(Tokens.text1)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        // Sold below the upstream's list price; the gateway sends
                        // the fraction as `savings`.
                        if let label = row.pricing?.discountLabel {
                            // A fully discounted row shows FREE in its rate cells.
                            if row.pricing?.isFullyDiscounted != true {
                                DiscountTag(text: label)
                                    .padding(.leading, 3)
                            }
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                // The notes that qualify the name, on the line under it:
                // blend entries only (a named-shelf row is the vendor's model
                // under the vendor's name and needs no line from us), and a
                // sale's own line when the rate is already shown.
                Group {
                    if ModelRatings.isNonoBlend(id: row.id, pricing: row.pricing) {
                        SettingInfo(L("nono.pricing.blendTagline"))
                    }
                    if let line = row.pricing?.saleLine {
                        SettingInfo(line)
                    }
                }
                .padding(.leading, 15 + 7)
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            pricingRate(row.pricing?.inputPerMTok)
            // A model billed one rate for all input quotes no cached rate, and
            // the cell is a dash rather than a repeat of the input figure.
            pricingRate(row.pricing?.cachedInputPerMTok)
            pricingRate(row.pricing?.outputPerMTok)
            Text(L(pricingOriginKey(row)))
                .font(.sf(Tokens.TypeSize.meta))
                .foregroundStyle(Tokens.text3)
                .lineLimit(1)
                // Written in full, never "US Pro…".
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 9)
    }

    /// "Official Provider" for a first-party named entry on the vendor's own
    /// API; "No Specific Region" for an entry the catalog pins to no region;
    /// "US Provider" otherwise. See `ModelRatings.nonoHost`.
    private func pricingOriginKey(_ row: NonoLineupRow) -> String {
        switch ModelRatings.nonoHost(id: row.id, pricing: row.pricing) {
        case .official: return "nono.pricing.official"
        case .us: return "nono.pricing.usBased"
        case .anyRegion: return "nono.pricing.anyRegion"
        }
    }

    /// A per-1M-token rate; "/M" is the unit. While the fetch this page started
    /// has not landed, a spinner rather than the last figure seen: that may be
    /// the price that just changed, which is why we asked. A $0 rate is a
    /// FREE tag.
    @ViewBuilder
    private func pricingRate(_ usd: Double?) -> some View {
        if usd == 0 {
            FreeTag()
        } else if let usd {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Self.moneyText(usd, size: Tokens.TypeSize.label)
                    .foregroundStyle(Tokens.text1)
                Text("/M")
                    .font(.sf(Tokens.TypeSize.meta))
                    .foregroundStyle(Tokens.text4)
            }
            .monospacedDigit()
            .lineLimit(1)
        } else if nonoRatesLoading {
            ProgressView().controlSize(.mini)
        } else {
            usageCell("—", color: Tokens.text4)
        }
    }

    /// How much the next purchase is for. Not a set of fixed tiers: the amount
    /// is the buyer's, and the gateway takes any figure between its own bounds.
    /// $5 rather than the $1 minimum, because the minimum is the one purchase
    /// where Stripe's flat fee costs the most per dollar and a default should
    /// not steer people into it.
    @State private var topUpUSD: Double = 5
    /// Whether the Copy sensing row wears its tag. Read ONCE per appearance of
    /// Settings (see `onAppear`) rather than tracked live: opening the menu
    /// records the tag as read, and this visit keeps showing it anyway.
    @State private var showsRefreshedTag = false
    @State private var addCreditHovering = false
    @State private var usageLines: [NoNoAccount.UsageLine] = []
    @State private var usageLoading = false
    @State private var usageFailed = false
    @State private var balanceLines: [NoNoAccount.BalanceLine] = []
    @State private var balancesLoading = false
    @State private var balancesFailed = false
    @State private var showingAmount = false
    /// Whether the rate fetch the Pricing page started is still in flight.
    @State private var nonoRatesLoading = false

    /// The block's action. Collapsed it is one button; opened, the stepper
    /// unfolds to its left and the button becomes the commit.
    ///
    /// The stepper lives beside the button rather than beside the balance. Two
    /// dollar figures on one line at one weight is the arrangement that made
    /// this block unreadable: the eye cannot tell the money you have from the
    /// money you are about to spend.
    @ViewBuilder
    private func addCreditButton(bought: Double) -> some View {
        HStack(spacing: 8) {
            if showingAmount {
                AmountStepper(value: $topUpUSD,
                              range: NoNoAccount.minimumTopUpUSD...NoNoAccount.maximumTopUpUSD)
                    .transition(.scale(scale: 0.86, anchor: .trailing).combined(with: .opacity))
            }

            if showingAmount {
            Button {
                if showingAmount {
                    Task {
                        await nono.buyCredit(amountUSD: topUpUSD)
                        // Stripe redirects the browser as soon as the card
                        // clears, but the webhook that credits the wallet is a
                        // separate delivery. Waiting on the bought total rising,
                        // not on the balance being non-zero, is what makes this
                        // work for a repeat purchase.
                        await nono.awaitCredit(boughtAbove: bought)
                    }
                    showingAmount = false
                } else {
                    showingAmount = true
                }
            } label: {
                AddCreditButtonFace(title: showingAmount ? L("nono.addShort") : "",
                                    lit: addCreditHovering, compact: true, height: 30)
            }
            .accessibilityLabel(showingAmount ? L("nono.addShort") : L("nono.add"))
            .buttonStyle(GlassPressStyle())
            .onHover { addCreditHovering = $0 }
            .animation(.easeOut(duration: Tokens.hoverFade), value: addCreditHovering)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82),
                   value: showingAmount)
    }

    /// Ask the gateway what it charges right now, bypassing every cache between
    /// here and it — `ModelCatalog`'s hourly per-(provider, key) entry included.
    ///
    /// A rate is the one figure in this card that must not be stale: it is a
    /// price the buyer was quoted, and unlike the balance beside it, nothing
    /// else in the app refetches it.
    private func refreshNonoRates() async {
        guard let key = APIKeyStore.current(for: .nono), !nonoRatesLoading else { return }
        nonoRatesLoading = true
        defer { nonoRatesLoading = false }
        if let fresh = await ModelCatalog.fetch(for: .nono, apiKey: key, force: true) {
            catalog.adopt(fresh, for: .nono)
        }
    }

    /// Dollars to the cent. Below a cent but above zero it reads "<$0.01":
    /// "$0.00" would say the wallet is empty while it can still answer questions.
    static func money(_ usd: Double) -> String {
        if isSubCent(usd) { return "<$0.01" }
        return String(format: "$%.2f", usd)
    }

    static func isSubCent(_ usd: Double) -> Bool { usd > 0 && usd < 0.01 }

    /// A billed or granted amount. Always the actual dollars — a sub-cent
    /// figure is "$0.003", not "<$0.01". That floor is only for the wallet.
    static func moneyCharged(_ usd: Double) -> String {
        if usd > 0 && usd < 0.01 {
            var s = String(format: "$%.4f", usd)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s
        }
        return String(format: "$%.2f", usd)
    }

    /// A per-million-token rate, the unit the lineup writes prices in. Cents
    /// for ordinary figures; four places once a rate drops below a dime, with
    /// trailing zeros stripped so "$0.0020" does not pretend at more precision
    /// than the catalog sent. A dime rather than a cent because the cached
    /// rates sit just above one: two places print $0.014 as "$0.01", which is a
    /// different price.
    static func moneyPerMillion(_ usd: Double) -> String {
        if usd > 0 && usd < 0.1 {
            var s = String(format: "$%.4f", usd)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s
        }
        return String(format: "$%.2f", usd)
    }

    /// `moneyPerMillion` as Text. Below $1 the leading "0." and any zeros up to
    /// the first significant digit are set smaller: "0.000" in "$0.0002", "0."
    /// in "$0.15", all of "0.00" in "$0.00".
    static func moneyText(_ usd: Double, size: CGFloat) -> Text {
        let s = moneyPerMillion(usd)
        guard usd >= 0 && usd < 1, s.hasPrefix("$0") else {
            return Text(s).font(.brand(size))
        }
        let digits = s.dropFirst()
        let cut = digits.firstIndex { $0 != "0" && $0 != "." } ?? digits.endIndex
        return Text("$").font(.brand(size))
            + Text(String(digits[..<cut])).font(.brand(size * 0.78))
            + Text(String(digits[cut...])).font(.brand(size))
    }

    // MARK: - OpenRouter one-click connect

    /// Whether OpenRouter has a stored key. Read straight from the store on each
    /// render — the OAuth flow writes it from outside this view, so a cached
    /// `@State` would go stale the moment Connect succeeds.
    private var openRouterConnected: Bool {
        !APIKeyStore.stored(for: .openrouter).isEmpty
    }

    /// The Account row OpenRouter shows instead of a paste field. Disconnected,
    /// it's one Connect button (browser sign-in → key lands automatically) plus a
    /// quiet manual-paste escape hatch; connected, the familiar masked summary
    /// with Test and Disconnect.
    private var openRouterAccountRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(L("model.account"))
                    .font(.sf(Tokens.TypeSize.form, weight: .regular))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: SettingsMetrics.fieldLabelWidth, alignment: .leading)

                if openRouterConnected {
                    // Same masked, read-only summary as the saved key row.
                    Text(maskedKey)
                        .font(.sf(Tokens.TypeSize.form))
                        .foregroundStyle(Tokens.text2)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .recessedSurface(in: RoundedRectangle.control, lit: false)

                    if testing {
                        ProgressView().controlSize(.small)
                    } else {
                        SettingActionButton(title: L("model.test")) { test() }
                    }
                    SettingActionButton(title: L("model.disconnect")) {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            model.confirmingDisconnect = true
                        }
                    }
                } else {
                    switch orAuth.phase {
                    case .waiting, .exchanging:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(orAuth.phase == .exchanging
                                 ? L("model.connecting")
                                 : L("model.finishSignIn"))
                                .font(.sf(Tokens.TypeSize.label))
                                .foregroundStyle(Tokens.text2)
                        }
                        .frame(height: 30)
                        SettingActionButton(title: L("model.cancel")) { orAuth.cancel() }
                    default:
                        connectButton
                        SettingActionButton(title: L("model.pasteInstead"),
                                            tone: Tokens.text3) {
                            orAuth.acknowledge()
                            manualKeyEntry = true
                            startEditingKey()
                        }
                    }
                }
            }

            if case .failed(let why) = orAuth.phase {
                statusPill(ok: false, message: why)
                    .padding(.leading, SettingsMetrics.fieldIndent)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if openRouterConnected, let result = testResult {
                testVerdict(result)
                    .padding(.leading, SettingsMetrics.fieldIndent)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Codex (ChatGPT) sign-in status

    /// Codex is keyless — it reuses `codex login` (ChatGPT sign-in), so instead of a
    /// paste field it shows whether the CLI is installed and signed in, with a link to
    /// the install docs when it isn't. There's no in-app sign-in: `codex login` runs
    /// the OAuth flow in Terminal itself, and Notch just uses the cached tokens.
    @ViewBuilder
    private var codexAccountRow: some View {
        let installed = CodexCLIService.resolvedBinaryIfReady() != nil
        let signedIn = CodexCLIService.authExists()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(L("model.account"))
                    .font(.sf(Tokens.TypeSize.form, weight: .regular))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: SettingsMetrics.fieldLabelWidth, alignment: .leading)

                if !installed {
                    // No CLI yet → link to install docs (there's nothing to sign into).
                    codexPillButton(L("codex.status.getCodex")) {
                        LinkGate.shared.open(Provider.codex.signupURL)
                    }
                } else if signedIn {
                    // Signed in → status + Re-authorize (re-run `codex login`), NOT a
                    // "get a key" link: Codex has no key, only the ChatGPT sign-in.
                    statusPill(ok: true, message: L("codex.status.connected"))
                    Spacer(minLength: 8)
                    codexPillButton(L("codex.action.reauthorize")) { CodexCLIService.reauthorize() }
                } else {
                    // Installed but not signed in → sign in (same `codex login` flow).
                    codexPillButton(L("codex.action.signIn")) { CodexCLIService.reauthorize() }
                }
            }

            Text(installed
                 ? (signedIn ? L("codex.status.hint.ready") : L("codex.status.hint.login"))
                 : L("codex.status.hint.install"))
                .settingsDescription()
                .padding(.leading, SettingsMetrics.fieldIndent)
        }
    }

    // MARK: - Claude Code sign-in status

    /// Claude Code is keyless like Codex, with one deliberate difference: there is
    /// NO in-app sign-in / re-authorize action at all. Anthropic's terms reserve
    /// the OAuth flow for the user's own use of the official CLI, so Notch never
    /// triggers it — the row just reports state and tells the user to run `claude`
    /// in Terminal themselves. Install link only when the CLI is missing.
    @ViewBuilder
    private var claudeAccountRow: some View {
        let installed = ClaudeCLIService.resolvedBinaryIfReady() != nil
        let signedIn = ClaudeCLIService.authExists()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(L("model.account"))
                    .font(.sf(Tokens.TypeSize.form, weight: .regular))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: SettingsMetrics.fieldLabelWidth, alignment: .leading)

                if !installed {
                    // No CLI yet → link to the install docs.
                    codexPillButton(L("claudecode.status.get")) {
                        LinkGate.shared.open(Provider.claudeCode.signupURL)
                    }
                } else {
                    statusPill(ok: signedIn,
                               message: L(signedIn ? "claudecode.status.connected"
                                                   : "claudecode.status.signedOut"))
                }
            }

            Text(installed
                 ? (signedIn ? L("claudecode.status.hint.ready") : L("claudecode.status.hint.login"))
                 : L("claudecode.status.hint.install"))
                .settingsDescription()
                .padding(.leading, SettingsMetrics.fieldIndent)
        }
    }

    // MARK: - Grok CLI sign-in status

    /// Grok is keyless like Codex, and — unlike Claude — offers an in-app sign-in:
    /// `grok login` is a first-class user-facing subcommand that opens the browser
    /// OAuth flow, so the row can spawn it directly (the same command the user would
    /// run in a terminal). Install link only when the CLI is missing.
    @ViewBuilder
    private var grokAccountRow: some View {
        let installed = GrokCLIService.resolvedBinaryIfReady() != nil
        let signedIn = GrokCLIService.authExists()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(L("model.account"))
                    .font(.sf(Tokens.TypeSize.form, weight: .regular))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: SettingsMetrics.fieldLabelWidth, alignment: .leading)

                if !installed {
                    // No CLI yet → link to install docs (there's nothing to sign into).
                    codexPillButton(L("grok.status.get")) {
                        LinkGate.shared.open(Provider.grokCode.signupURL)
                    }
                } else if signedIn {
                    // Signed in → status + Re-authorize (re-run `grok login`).
                    statusPill(ok: true, message: L("grok.status.connected"))
                    Spacer(minLength: 8)
                    codexPillButton(L("grok.action.reauthorize")) { GrokCLIService.reauthorize() }
                } else {
                    // Installed but not signed in → sign in (same `grok login` flow).
                    codexPillButton(L("grok.action.signIn")) { GrokCLIService.reauthorize() }
                }
            }

            Text(installed
                 ? (signedIn ? L("grok.status.hint.ready") : L("grok.status.hint.login"))
                 : L("grok.status.hint.install"))
                .settingsDescription()
                .padding(.leading, SettingsMetrics.fieldIndent)
        }
    }

    // MARK: - Command Code sign-in status

    /// Command Code is keyless like the rest, and — like Claude, unlike Grok — has NO
    /// in-app sign-in: `cmd login` renders an interactive terminal UI that needs a
    /// real TTY, so there is nothing Notch can usefully spawn. The row reports state
    /// and points at the terminal command. Install link only when the CLI is missing.
    @ViewBuilder
    private var commandCodeAccountRow: some View {
        let installed = CommandCodeCLIService.resolvedBinaryIfReady() != nil
        let signedIn = CommandCodeCLIService.authExists()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(L("model.account"))
                    .font(.sf(Tokens.TypeSize.form, weight: .regular))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: SettingsMetrics.fieldLabelWidth, alignment: .leading)

                if !installed && !signedIn {
                    // No CLI yet → link to the install docs.
                    codexPillButton(L("commandcode.status.get")) {
                        LinkGate.shared.open(Provider.commandCode.signupURL)
                    }
                } else {
                    statusPill(ok: signedIn,
                               message: L(signedIn ? "commandcode.status.connected"
                                                   : "commandcode.status.signedOut"))
                }
                Spacer(minLength: 8)
                // Detection is cached for the whole launch; this re-runs it. Same
                // chip as the model row's refresh arrow.
                SettingsButton(title: "",
                               variant: .ghost,
                               size: .icon,
                               systemImage: "arrow.clockwise",
                               loading: commandCodeRedetecting) {
                    commandCodeRedetecting = true
                    CommandCodeCLIService.redetect { commandCodeRedetecting = false }
                }
                .disabled(commandCodeRedetecting)
                .notchTooltip(L("commandcode.action.redetect"))
            }

            // Chat needs only the sign-in; the CLI matters for agent tasks alone.
            // An install that crashes on launch is neither missing nor working, so it
            // gets its own hint and the line the CLI died with.
            let startupError = installed ? nil : CommandCodeCLIService.startupError
            Text(startupError != nil
                 ? L("commandcode.status.hint.broken")
                 : signedIn
                 ? (installed ? L("commandcode.status.hint.ready") : L("commandcode.status.hint.noCLI"))
                 : (installed ? L("commandcode.status.hint.login") : L("commandcode.status.hint.install")))
                .settingsDescription()
                .padding(.leading, SettingsMetrics.fieldIndent)
            if let startupError {
                Text(startupError)
                    .font(.system(size: Tokens.TypeSize.meta, design: .monospaced))
                    .foregroundStyle(Tokens.text3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, SettingsMetrics.fieldIndent)
            }

            settingRow(label: L("commandcode.zdr"), info: L("commandcode.zdr.hint")) {
                Toggle("", isOn: $commandCodeZeroDataRetention)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Tokens.switchTint)
            }
            .padding(.top, 4)
        }
        // The probe lands on a background queue; `cliTick` is the redraw.
        .onReceive(NotificationCenter.default.publisher(for: .cliAvailabilityResolved)) { _ in
            cliTick &+= 1
        }
        .id(cliTick)
    }

    /// The Command Code row's re-detect arrow is running its probe.
    @State private var commandCodeRedetecting = false
    @AppStorage(CommandCodeCLIService.zeroDataRetentionKey) private var commandCodeZeroDataRetention = false

    // MARK: - pi sign-in status

    /// pi is keyless like the rest, and — like Claude and Command Code, unlike Grok
    /// — has NO in-app sign-in: pi's `/login` is a slash command inside its own
    /// interactive TUI, which needs a real TTY, so there is nothing Notch can
    /// usefully spawn. The row reports state and points at the terminal.
    ///
    /// "Signed in" means something wider here than for the others: pi fronts every
    /// provider separately, so the check is "at least one provider is configured" —
    /// which is exactly what a non-empty `pi --list-models` catalog says (see
    /// `PiCLIService.authExists`).
    @ViewBuilder
    private var piAccountRow: some View {
        let installed = PiCLIService.isInstalled
        let signedIn = PiCLIService.authExists()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(L("model.account"))
                    .font(.sf(Tokens.TypeSize.form, weight: .regular))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: SettingsMetrics.fieldLabelWidth, alignment: .leading)

                if !installed {
                    // No CLI yet → link to the project's install docs.
                    codexPillButton(L("pi.status.get")) {
                        LinkGate.shared.open(Provider.piCode.signupURL)
                    }
                } else {
                    statusPill(ok: signedIn,
                               message: L(signedIn ? "pi.status.connected"
                                                   : "pi.status.signedOut"))
                }
            }

            Text(installed
                 ? (signedIn ? L("pi.status.hint.ready") : L("pi.status.hint.login"))
                 : L("pi.status.hint.install"))
                .settingsDescription()
                .padding(.leading, SettingsMetrics.fieldIndent)
        }
    }

    // MARK: - dsh status

    /// dsh keeps its provider and API key in its own settings. The row reports
    /// whether the CLI is installed and whether dsh holds a model key
    /// (`DshCLIService.authExists`); the button opens dsh's Web UI, where the
    /// Models page sets the key.
    @ViewBuilder
    private var dshAccountRow: some View {
        let installed = DshCLIService.isInstalled
        let signedIn = DshCLIService.authExists()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(L("model.account"))
                    .font(.sf(Tokens.TypeSize.form, weight: .regular))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: SettingsMetrics.fieldLabelWidth, alignment: .leading)

                if !installed {
                    codexPillButton(L("dsh.status.get")) {
                        LinkGate.shared.open(Provider.dshCode.signupURL)
                    }
                } else if signedIn {
                    statusPill(ok: true, message: L("dsh.status.connected"))
                    Spacer(minLength: 8)
                    codexPillButton(L("dsh.status.openSettings")) {
                        DshCLIService.openSettings()
                    }
                } else {
                    codexPillButton(L("dsh.status.openSettings")) {
                        DshCLIService.openSettings()
                    }
                }
            }

            Text(installed
                 ? (signedIn ? L("dsh.status.hint.ready") : L("dsh.status.hint.login"))
                 : L("dsh.status.hint.install"))
                .settingsDescription()
                .padding(.leading, SettingsMetrics.fieldIndent)
        }
    }

    // MARK: - Cursor CLI sign-in status

    /// Cursor is keyless like the rest, and — like Grok, unlike Claude — offers an
    /// in-app sign-in: `cursor-agent login` is a first-class subcommand, so the row
    /// can drive it directly. Install link only when the CLI is missing.
    ///
    /// Unlike Grok's, this row *follows* the sign-in rather than firing it and
    /// forgetting: the browser half happens outside the app, so while it is in
    /// flight the row says so, and if it ends without credentials the row says that
    /// too. `CursorCLIService.reauthorize` posts `.cliAvailabilityResolved` at both
    /// edges, which `cliTick` below turns into a redraw.
    ///
    /// Re-check appears in exactly the two states whose fix happens outside the
    /// app — no CLI, and a CLI too old. The binary resolution is cached for the
    /// process lifetime, so without it the row keeps reporting launch-time state
    /// after the user has installed or updated exactly what it asked for, and the
    /// only cure is quitting Notch. Every other state resolves from inside this
    /// row, so a re-check button there would be a button with nothing to find.
    @ViewBuilder
    private var cursorAccountRow: some View {
        let installed = CursorCLIService.resolvedBinaryIfReady() != nil
        let outdated = CursorCLIService.isOutdated
        let signedIn = CursorCLIService.authExists()
        let signingIn = CursorCLIService.isSigningIn
        let rechecking = CursorCLIService.isRechecking
        let failure = CursorCLIService.lastSignInFailure
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(L("model.account"))
                    .font(.sf(Tokens.TypeSize.form, weight: .regular))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: SettingsMetrics.fieldLabelWidth, alignment: .leading)

                if !installed {
                    // No CLI yet → link to install docs (there's nothing to sign into).
                    codexPillButton(L("cursor.status.get")) {
                        LinkGate.shared.open(Provider.cursorCode.signupURL)
                    }
                    cursorRecheckButton(rechecking)
                } else if outdated {
                    // Installed, but a build Notch can't drive. Signing in here
                    // would work and still leave every turn failing, so the row
                    // offers the only thing that helps.
                    statusPill(ok: false, message: L("cursor.status.outdated"))
                    Spacer(minLength: 8)
                    codexPillButton(L("cursor.action.update")) {
                        LinkGate.shared.open(Provider.cursorCode.signupURL)
                    }
                    cursorRecheckButton(rechecking)
                } else if signingIn {
                    ProgressView().controlSize(.small)
                } else if signedIn {
                    // Signed in → status + Re-authorize (re-run `cursor-agent login`).
                    statusPill(ok: true, message: L("cursor.status.connected"))
                    Spacer(minLength: 8)
                    codexPillButton(L("cursor.action.reauthorize")) {
                        CursorCLIService.reauthorize()
                    }
                } else {
                    // Installed but not signed in → same `cursor-agent login` flow.
                    // No Re-check here: signing in is done from this row, not in a
                    // terminal, so there is nothing outside the app to go and
                    // notice.
                    codexPillButton(L("cursor.action.signIn")) {
                        CursorCLIService.reauthorize()
                    }
                }
            }

            Text(hint(installed: installed, outdated: outdated, signedIn: signedIn,
                      signingIn: signingIn, failure: failure))
                .settingsDescription(outdated || (failure != nil && !signedIn)
                                     ? Tokens.danger : Tokens.text3)
                .padding(.leading, SettingsMetrics.fieldIndent)
        }
        // The sign-in lands from a background queue minutes after the click, so the
        // row has to be told; `cliTick` is the redraw.
        .onReceive(NotificationCenter.default.publisher(for: .cliAvailabilityResolved)) { _ in
            cliTick &+= 1
        }
        .id(cliTick)
    }

    /// Probe the install again. A spinner while it runs: the probe spawns the CLI,
    /// so a click with no feedback reads as a dead button.
    @ViewBuilder
    private func cursorRecheckButton(_ rechecking: Bool) -> some View {
        if rechecking {
            ProgressView().controlSize(.small)
        } else {
            codexPillButton(L("cursor.action.recheck")) { CursorCLIService.recheck() }
        }
    }

    /// The line under the Cursor account row: what is happening, or what went wrong.
    private func hint(installed: Bool, outdated: Bool, signedIn: Bool,
                      signingIn: Bool, failure: String?) -> String {
        if !installed { return L("cursor.status.hint.install") }
        if outdated {
            // Naming the installed version is what makes the line checkable — the
            // user can compare it against what cursor.com is serving.
            let version = CursorCLIService.installedVersion
            return version.isEmpty
                ? L("cursor.status.hint.outdated")
                : L("cursor.status.hint.outdatedVersion", version)
        }
        if signingIn { return L("cursor.status.hint.waiting") }
        if let failure, !signedIn { return failure }
        return signedIn ? L("cursor.status.hint.ready") : L("cursor.status.hint.login")
    }

    /// A quiet pill button in the account row's register (Get Codex / Sign in /
    /// Re-authorize) — same chrome as the OpenRouter Connect button.
    private func codexPillButton(_ title: String, action: @escaping () -> Void) -> some View {
        SettingsButton(title: title, variant: .secondary, size: .md, action: action)
    }

    /// The primary action of the whole onboarding: one click, sign in (or sign
    /// up, free) in the browser, and the key arrives by itself. Slightly brighter
    /// than the surrounding chips because it IS the setup.
    @State private var connectHovering = false
    @State private var surveySource: String?
    @State private var surveySourceDetail = ""
    @State private var surveyRole: String?
    @State private var surveyFrequency: String?
    @State private var surveyUses: Set<String> = []
    @State private var surveyRoleOther = ""
    @State private var surveyUsesOther = ""
    @State private var surveyAlternatives: Set<String> = []
    @State private var surveyAlternativesOther = ""
    @State private var surveyWish = ""
    @State private var surveySending = false
    @State private var surveyFailed = false
    @State private var surveySubmitHovering = false

    private var connectButton: some View {
        SettingsButton(title: L("model.connectOpenRouter"),
                       variant: .primary,
                       size: .md,
                       systemImage: "link") {
            testResult = nil
            orAuth.connect()
        }
    }

    /// Drop the stored OpenRouter key and return the row to its Connect state.
    /// (The key created during Connect stays in the user's OpenRouter account —
    /// they can revoke it at openrouter.ai/settings/keys.)
    private func disconnectOpenRouter() {
        APIKeyStore.save("", for: .openrouter)   // empty clears the entry
        // If OpenRouter was the active backend, it can't answer without its
        // key — hand back the previous one.
        ModelCatalogStore.leave(.openrouter)
        apiKey = ""
        testResult = nil
        orAuth.acknowledge()
        editingKey = true
        NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
        Task { await refreshModels() }
    }

    /// Whether the Test button is actionable: a non-blank *stored* key, not
    /// env-overridden, not already running. Test only shows once a key is saved,
    /// so it probes what's on disk, never an unsaved draft.
    private var canTest: Bool {
        guard !testing, !envOverride else { return false }
        // The custom endpoint is testable on its URL alone: with no key required,
        // "is this server reachable and does it answer /v1/models?" is the whole
        // question, and it's exactly what a local server needs answered.
        if keyScope == .custom { return CustomProvider.chatEndpoint != nil }
        return !APIKeyStore.stored(for: keyScope).isEmpty
    }

    /// Swap the masked summary for an empty field ready for a fresh paste —
    /// editing never re-surfaces the stored secret on screen.
    private func startEditingKey() {
        apiKey = ""
        testResult = nil
        withAnimation(.easeOut(duration: 0.16)) { editingKey = true }
        DispatchQueue.main.async { keyFieldFocused = true }
    }

    /// Abandon the edit and fall back to the stored key's masked summary.
    private func stopEditingKey() {
        apiKey = APIKeyStore.stored(for: keyScope)
        testResult = nil
        withAnimation(.easeOut(duration: 0.16)) { editingKey = false }
    }

    /// Persist the Exa key (or clear it when blank), then tell the backend so the
    /// next turn rebuilds its tool registry — turning Exa search on/off live. Flips
    /// the button to "Saved" for a beat, then settles back into the masked summary.
    private func saveExaKey() {
        APIKeyStore.saveExaKey(exaKey)
        // Reflect what's actually stored (a trimmed/cleared value) back into state.
        exaKey = APIKeyStore.storedExaKey()
        NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
        withAnimation(.easeOut(duration: 0.16)) { editingExaKey = false }
        withAnimation(.easeOut(duration: 0.2)) { exaSaved = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run { withAnimation(.easeOut(duration: 0.2)) { exaSaved = false } }
        }
    }

    /// Abandon the Exa edit and fall back to the stored key's masked summary.
    private func stopEditingExaKey() {
        exaKey = APIKeyStore.storedExaKey()
        withAnimation(.easeOut(duration: 0.16)) { editingExaKey = false }
    }

    private func saveKeenableKey() {
        APIKeyStore.saveKeenableKey(keenableKey)
        keenableKey = APIKeyStore.storedKeenableKey()
        NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
        withAnimation(.easeOut(duration: 0.16)) { editingKeenableKey = false }
        withAnimation(.easeOut(duration: 0.2)) { keenableSaved = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run { withAnimation(.easeOut(duration: 0.2)) { keenableSaved = false } }
        }
    }

    /// Abandon the Keenable edit and fall back to the stored key's masked summary.
    private func stopEditingKeenableKey() {
        keenableKey = APIKeyStore.storedKeenableKey()
        withAnimation(.easeOut(duration: 0.16)) { editingKeenableKey = false }
    }

    private func saveAnySearchKey() {
        APIKeyStore.saveAnySearchKey(anySearchKey)
        anySearchKey = APIKeyStore.storedAnySearchKey()
        NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
        withAnimation(.easeOut(duration: 0.16)) { editingAnySearchKey = false }
        withAnimation(.easeOut(duration: 0.2)) { anySearchSaved = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) { anySearchSaved = false }
            }
        }
    }

    private func saveDeepSeekSearchKey() {
        APIKeyStore.save(deepSeekSearchKey, for: .deepseek)
        deepSeekSearchKey = APIKeyStore.stored(for: .deepseek)
        NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
        withAnimation(.easeOut(duration: 0.16)) { editingDeepSeekSearchKey = false }
        withAnimation(.easeOut(duration: 0.2)) { deepSeekSearchSaved = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) { deepSeekSearchSaved = false }
            }
        }
    }

    private func stopEditingDeepSeekSearchKey() {
        deepSeekSearchKey = APIKeyStore.stored(for: .deepseek)
        withAnimation(.easeOut(duration: 0.16)) { editingDeepSeekSearchKey = false }
    }

    private func stopEditingAnySearchKey() {
        anySearchKey = APIKeyStore.storedAnySearchKey()
        withAnimation(.easeOut(duration: 0.16)) { editingAnySearchKey = false }
    }

    /// The wire id in effect: the saved override, or the provider's default when
    /// the sentinel empty string is stored.
    private var effectiveModelID: String {
        // Codex's stored id may be the legacy "codex" sentinel — resolve it (and an
        // empty override) to the provider's real configured model so the chip shows
        // the actual model name and vendor mark, not a bare "codex".
        if provider == .codex, modelID.isEmpty || modelID == "codex" {
            return provider.defaultModel
        }
        // Claude Code's retired "claude" account-default sentinel resolves the same
        // way, to a concrete alias — the picker has no "Default" row to select.
        if provider == .claudeCode, modelID.isEmpty || modelID == "claude" {
            return provider.defaultModel
        }
        // Cursor's "cursor" sentinel likewise names no model — it is the row the
        // picker offers until the CLI's catalog lands.
        if provider == .cursorCode,
           modelID.isEmpty || modelID == CursorCLIService.defaultSentinel {
            return provider.defaultModel
        }
        return modelID.isEmpty ? provider.defaultModel : modelID
    }

    /// The mark on a setting that changed since the user last looked. Same tag
    /// shape as the Jev row's, so a badge is one species on this pane.
    struct RefreshedBadge: View {
        var body: some View {
            SenseTopUpTag(text: L("tag.refreshed"), lit: true,
                          tint: Tokens.accent, filled: true)
        }
    }

    /// The mark on a model added recently, in the Ask model menu. The
    /// Refreshed badge's fill and size, at a regular weight.
    struct NewBadge: View {
        var text = L("tag.new")
        var tint = Tokens.accent
        var tracking: CGFloat = 0.4

        var body: some View {
            Text(text)
                .font(.sf(Tokens.TypeSize.caption, weight: .regular))
                .tracking(tracking)
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(tint.opacity(0.16), in: Capsule(style: .continuous))
        }

        /// The tag's width, for a card sized by arithmetic (the Ask model menu).
        static func width(_ text: String = L("tag.new")) -> CGFloat {
            let font = NSFont.systemFont(ofSize: Tokens.TypeSize.caption, weight: .regular)
            let text = NSAttributedString(string: text,
                                          attributes: [.font: font, .kern: 0.4])
            return ceil(text.size().width) + 8
        }
    }

    /// One tag on the Jev row. Shaped like `LowBalanceTag` — same corner, same padding, same
    /// hairline — but an outline in the CTA blue rather than that one's filled
    /// rose, because nothing here is wrong: it is an offer, not a warning.
    struct SenseTopUpTag: View {
        let text: String
        let lit: Bool
        /// The ink. White is the default — a menu row is already carrying an
        /// accent when it is highlighted. The one exception is the tag that says
        /// Jev costs nothing, which is the offer itself and wears the pane's CTA
        /// blue so it is not read as another piece of fine print.
        var tint: Color = Tokens.text1
        /// Filled instead of outlined — for the one badge that is an
        /// announcement rather than a condition: outlines read as fine print,
        /// and this one has to be seen before it is read.
        var filled: Bool = false

        var body: some View {
            Text(text)
                // `LowBalanceTag`'s fitting — semibold, a little tracking, 5×2
                // padding — one size up, at caption: the badge size is for a tag
                // that sits inside a row of its own, and this one has to be read
                // across a menu. Still under the menu's own words, so it cannot
                // be mistaken for more of the name.
                .font(.sf(Tokens.TypeSize.caption, weight: .regular))
                .tracking(0.4)
                .foregroundStyle(tint.opacity(lit ? 1 : 0.92))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                // Outline only — that is what makes a menu row's tag a tag
                // rather than a block of colour sitting inside the row.
                .background(filled ? tint.opacity(0.22) : .clear, in: LowBalanceTag.shape)
                .overlay(LowBalanceTag.shape
                    .strokeBorder(tint.opacity(filled ? 0 : (lit ? 0.62 : 0.45)),
                                  lineWidth: 0.6))
                .contentShape(LowBalanceTag.shape)
        }
    }

    /// Step one: **which backend answers.** A menu of the backends you bring
    /// yourself, split into the ones that can answer right now and the ones that
    /// still need a key. Choosing one that needs a key leaves the current backend
    /// answering until the key is saved.
    ///
    /// Notchi is not in it. It is not one of these — every row here is a lab or
    /// an aggregator you pay somewhere else, and Notchi Balance is a wallet you
    /// fill here; listing it as the first of eighteen vendors filed a plan under
    /// the things it is an alternative to. It lives in the card above, always
    /// visible, and is picked by choosing one of its models.
    ///
    /// Picking an unconfigured provider is how you get to a new vendor's key
    /// field: `keySection` unfolds itself on the spot.
    ///
    /// Notchi never reaches this row — not in the menu, and not as the value it
    /// displays. `provider` is `APIKeyStore.broughtProvider`, which cannot hold it:
    /// switching to Notchi on the panel leaves this row naming the vendor it named
    /// before, because that is still the vendor this pane configures.
    private var providerRow: some View {
        settingRow(label: L("model.provider")) {
            GlassMenu(title: provider.displayName,
                      logoVendor: provider.brandVendor,
                      logoFallback: provider.displayName,
                      logoSymbol: provider.brandSymbol,
                      items: providerMenuItems)
        }
    }

    /// The provider menu's rows: the backends that can answer now, then the
    /// ones that still need a key, each group under its own title.
    private var providerMenuItems: [GlassMenuItem] {
        let theirs = Provider.offered.filter { !$0.isFirstParty }
        let ready = theirs.filter(providerReady)
        let unready = theirs.filter { !providerReady($0) }
        func rows(_ group: [Provider], header: String) -> [GlassMenuItem] {
            group.enumerated().map { index, p in
                GlassMenuItem(title: p.displayName,
                              selected: p == provider,
                              header: index == 0 ? header : nil) {
                    selectProvider(p)
                }
            }
        }
        return rows(ready, header: L("model.picker.configured"))
            + rows(unready, header: L("model.picker.unconfigured"))
    }

    /// Step two: **which of that provider's models.** The menu lists the chosen
    /// provider's catalog alone. Notchi's models are not in it — the panel's own
    /// model menu is where Notchi is picked.
    private var modelRow: some View {
        settingRow(label: L("model.label")) {
            HStack(spacing: 6) {
                // Manual refresh, left of the chip so the chip stays on the right edge: the automatic paths are all cached (the curated
                // manifest for 6h, a vendor's `/v1/models` for an hour, the CLI
                // catalogs for the whole launch), which is right until a model ships
                // mid-session and the list you're looking at is the stale one. One
                // tap re-asks every backend. Doubles as the load indicator.
                SettingsButton(title: "",
                               variant: .ghost,
                               size: .icon,
                               systemImage: "arrow.clockwise",
                               loading: modelsBusy) {
                    Task { await manualRefreshModels() }
                }
                .disabled(modelsBusy)
                .notchTooltip(L("model.refresh"))
                .opacity(refreshVisible ? 1 : 0)
                .allowsHitTesting(refreshVisible)
                // The chip anchors the model picker as a native popover.
                // A popover opens in its own window outside the island's tracking
                // area, so `model.isModelPickerOpen` suspends the panel's
                // leave-collapse for as long as it's up (see NotchModel).
                Button {
                    modelPickerOpen = true
                } label: {
                    modelPickerLabel(provider: provider, modelID: effectiveModelID)
                }
                .buttonStyle(.plain).exemptsDoubleClickPin()
                .fixedSize()
                // The rows are built only while the menu is up: this pane's body
                // re-runs on every account, catalog and updater publish, and
                // `rows` walks every provider's catalog.
                .modelMenu(isPresented: $modelPickerOpen,
                           models: modelPickerOpen ? catalog.rows(selected: provider) : [],
                           selectedProvider: provider,
                           selectedID: effectiveModelID,
                           lockedProvider: provider,
                           onSelect: { prov, id in
                               selectAcrossProviders(provider: prov, model: id)
                           },
                           onConfigure: { m in
                               // "Add key" on a keyless model: remember the pick, open
                               // the key section on that provider, and select the
                               // model the moment its key lands. The active backend
                               // stays untouched until then.
                               pendingModel = PendingModel(provider: m.provider, id: m.info.id)
                               setKeyScope(m.provider)
                               withAnimation(.easeOut(duration: 0.16)) { keySectionOpen = true }
                           })
                .onChange(of: modelPickerOpen) {
                    // Fill the list with each keyed provider's live models when the
                    // menu opens (the bundled list shows now; the refresh lands for
                    // the next open).
                    if modelPickerOpen { Task { await catalog.loadAll() } }
                    model.isModelPickerOpen = modelPickerOpen || promptModelPickerOpen
                }
            }
        }
        // Fine print: the arrow shows on the row it belongs to rather than sitting
        // beside the chip all day. It stays put while a refresh runs, so the pointer
        // wandering off mid-fetch doesn't take the spinner with it.
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: Tokens.hoverFade)) {
                modelRowHovering = hovering
            }
        }
    }

    /// The shared closed state for every full model menu. Keeping the vendor mark,
    /// name, chevrons, glass, and metrics in one label prevents a secondary picker
    /// (such as Prompt Shortcuts) from drifting into a parallel style again.
    private func modelPickerLabel(provider: Provider, modelID: String) -> some View {
        HStack(spacing: 7) {
            VendorLogo(vendor: ModelRatings.vendor(for: modelID, provider: provider),
                       fallback: modelID)
                .frame(width: 15, height: 15)
            Text(ModelRatings.prettyName(for: modelID, provider: provider))
                .font(.sf(Tokens.TypeSize.form))
                .foregroundStyle(Tokens.text1)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(icon: "chevron.up.chevron.down")
                .font(.sf(Tokens.TypeSize.caption, weight: .regular))
                .foregroundStyle(Tokens.text3)
        }
        .padding(.leading, 10)
        .padding(.trailing, 9)
        .frame(height: 30)
        .recessedSurface(in: Capsule(style: .continuous), lit: false)
        .contentShape(Capsule(style: .continuous))
    }

    /// Whether the refresh arrow is on screen — hovered, or busy and therefore
    /// owed an indicator.
    private var refreshVisible: Bool { modelRowHovering || modelsBusy }

    /// Either refresh is running — the button wears the spinner for both, so the
    /// row never shows two indicators for one idea.
    private var modelsBusy: Bool { loadingModels || refreshingModels }

    /// The refresh button's action: re-ask **everything** the model list is built
    /// from — the curated manifest, every keyed provider's live `/v1/models` (the
    /// custom endpoint included), the CLI backends' catalogs and Claude Code's
    /// alias probe — ignoring every TTL along the way (see `loadAll(force:)`).
    @MainActor
    private func manualRefreshModels() async {
        guard !refreshingModels else { return }
        refreshingModels = true
        await catalog.loadAll(force: true)
        refreshingModels = false
    }

    // MARK: - General

    // MARK: - Privacy

    /// Which screens carry a notch island. External monitors get a virtual
    /// notch that nests inside their menu bar; the choice applies immediately
    /// (AppDelegate listens and rebuilds the per-screen panels).
    ///
    /// Drawn as a two-card picker rather than a dropdown: "which screens" is a
    /// spatial choice, so each card shows a miniature laptop + external monitor
    /// with a bright pill on every screen that gets an island. No inline label:
    /// the group caption above ("SHOW ON") names it, so the cards sit at the
    /// pane's left margin with no hand-tuned vertical offset to keep true.
    private var placementRow: some View {
        settingRow(label: L("appearance.showOn"), aligned: true, verticalAlignment: .top) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(DisplayPlacement.allCases) { p in
                    placementCard(p)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func placementCard(_ p: DisplayPlacement) -> some View {
        let selected = placement == p
        return PickerCard(selected: selected, label: p.label) {
            selectPlacement(p)
        } content: {
            HStack(spacing: 10) {
                PickerGlyph(mark: PhosphorIcons.laptop)
                PickerGlyph(mark: PhosphorIcons.monitor, dimmed: p != .all)
            }
        }
    }

    private func selectPlacement(_ newValue: DisplayPlacement) {
        guard newValue != placement else { return }
        placement = newValue
        DisplayPlacement.current = newValue
        NotificationCenter.default.post(name: .displayPlacementChanged, object: nil)
    }

    /// Pick between the shipping icon and the adaptive Dot counterpart. The artwork
    /// itself is the useful preview, so this uses the same compact cards as the
    /// display-placement choice instead of hiding the difference in a menu.
    private var appIconStyleRow: some View {
        settingRow(label: L("appearance.appIcon"), verticalAlignment: .top) {
            HStack(spacing: 8) {
                ForEach(AppIconStyle.selectable) { style in
                    appIconStyleCard(style)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func appIconStyleCard(_ style: AppIconStyle) -> some View {
        let selected = appIconStyle == style
        return PickerCard(selected: selected, label: style.label) {
            selectAppIconStyle(style)
        } content: {
            let _ = appIconAppearanceRevision
            if let icon = style.image {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(style.previewScale)
                    .frame(width: 34, height: 34)
                    .clipped()
            }
        }
    }

    private func selectAppIconStyle(_ newValue: AppIconStyle) {
        guard newValue != appIconStyle else { return }
        Haptics.levelChange()
        appIconStyle = newValue
        AppIconStyle.current = newValue
        NotificationCenter.default.post(name: .appIconStyleChanged, object: nil)
    }

    /// Whether the app shows a Dock icon — mirrors the persisted value; writes go
    /// through `selectDockIconVisibility` so `AppDelegate` flips the activation
    /// policy immediately.
    ///
    /// Hidden is the app's natural state: a menu-bar-less accessory whose only
    /// presence is the island. Some users want one place to relaunch or quit
    /// from, though.
    ///
    /// Drawn as a switch, not a menu: the choice is Shown/Hidden and nothing
    /// else, and a two-item popup makes you open it to learn that. The enum
    /// stays — it carries the persisted value and the activation-policy mapping,
    /// which a raw Bool would throw away.
    private var dockIconRow: some View {
        settingRow(label: L("general.dockIcon.toggle")) {
            Toggle("", isOn: Binding(
                get: { dockIconVisibility == .shown },
                set: { Haptics.levelChange(); selectDockIconVisibility($0 ? .shown : .hidden) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.switchTint)
        }
    }

    /// Keeps the Mac awake with the lid closed while the Telegram bot is on.
    private var lidClosedRow: some View {
        settingRow(label: L("telegram.lid"), info: L("telegram.lid.hint"), aligned: true) {
            Toggle("", isOn: Binding(
                get: { telegram.answersWithLidClosed },
                set: { on in
                    Haptics.levelChange()
                    Task { await telegram.setAnswersWithLidClosed(on) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.switchTint)
            .disabled(telegram.lidBusy)
        }
    }

    /// Whether Jev may pin an answer on the menu bar card
    /// (`NotchModel.judgeCardPin`). On by default.
    private var jevAutoPinRow: some View {
        settingRow(label: L("general.jevAutoPin"), info: L("general.jevAutoPin.hint"), aligned: true) {
            Toggle("", isOn: Binding(
                get: { jevAutoPinEnabled },
                set: { Haptics.levelChange(); jevAutoPinEnabled = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.switchTint)
        }
    }

    /// Whether the app puts its icon in the menu bar. Shown by default — it's the
    /// one handle that works when the notch is behind a full-screen app and the
    /// summon shortcut has been forgotten. The choice applies immediately
    /// (AppDelegate adds/removes the status item).
    /// The glyph follows the app icon: the eyes for Eyes, the mark otherwise.
    private var menuBarIconRow: some View {
        settingRow(label: L("general.menuBarIcon"), aligned: true) {
            Toggle("", isOn: Binding(
                get: { menuBarIconVisibility == .shown },
                set: { Haptics.levelChange(); selectMenuBarIconVisibility($0 ? .shown : .hidden) }
            ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Tokens.switchTint)
        }
    }

    private func menuBarIconCard<Glyph: View>(
        selected: Bool, label: String, action: @escaping () -> Void,
        @ViewBuilder glyph: @escaping () -> Glyph
    ) -> some View {
        PickerCard(selected: selected, label: label, action: action) {
            glyph()
                .foregroundStyle(Tokens.text1)
                .frame(width: 34, height: 34)
        }
    }


    /// Where the menu bar card opens: under the icon, or flush with the
    /// screen's right edge. Same cards as the icon row above.
    private var menuBarCardPlacementRow: some View {
        settingRow(label: L("menuBarCard.position"), verticalAlignment: .top) {
            HStack(spacing: 8) {
                ForEach(MenuBarCardPlacement.allCases) { p in
                    menuBarIconCard(selected: menuBarCardPlacement == p, label: p.label) {
                        guard p != menuBarCardPlacement else { return }
                        Haptics.levelChange()
                        menuBarCardPlacement = p
                        MenuBarCardPlacement.current = p
                    } glyph: {
                        // picture-in-picture flipped so its inset sits top-right,
                        // where the card opens.
                        PickerGlyph(mark: p == .right ? PhosphorIcons.pictureInPicture
                                                      : PhosphorIcons.browser)
                            .scaleEffect(x: 1, y: p == .right ? -1 : 1)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// Where global screenshots fly into and open when Notchi is closed.
    private var screenshotDestinationRow: some View {
        settingRow(label: L("screenshot.destination"), aligned: true) {
            GlassMenu(
                title: screenshotDestination.label,
                items: ScreenshotDestination.allCases.map { dest in
                    GlassMenuItem(title: dest.label, selected: dest == screenshotDestination) {
                        guard dest != screenshotDestination else { return }
                        Haptics.levelChange()
                        screenshotDestination = dest
                        ScreenshotDestination.current = dest
                    }
                }
            )
        }
    }

    private func selectMenuBarIconVisibility(_ newValue: MenuBarIconVisibility) {
        guard newValue != menuBarIconVisibility else { return }
        menuBarIconVisibility = newValue
        MenuBarIconVisibility.current = newValue
        NotificationCenter.default.post(name: .menuBarIconVisibilityChanged, object: nil)
    }

    private func selectDockIconVisibility(_ newValue: DockIconVisibility) {
        guard newValue != dockIconVisibility else { return }
        dockIconVisibility = newValue
        DockIconVisibility.current = newValue
        NotificationCenter.default.post(name: .dockIconVisibilityChanged, object: nil)
    }

    /// Where a note-classified line files: Apple Notes (the default), or per-day
    /// Markdown files in a folder the user owns — plain text they can grep, sync,
    /// and summarize, with no Automation prompt. The folder sub-row (current path
    /// + chooser) only appears while the Markdown destination is active.
    private var noteDestinationRow: some View {
        settingRow(label: L("general.noteDestination")) {
            // Path sub-row lives in the row's content column so it left-aligns
            // with the menu above it — no guessed label-width offset.
            VStack(alignment: .leading, spacing: 8) {
                GlassMenu(title: noteDestination.label,
                          items: NoteDestination.allCases.map { d in
                    GlassMenuItem(title: d.label, selected: d == noteDestination) {
                        selectNoteDestination(d)
                    }
                })
                if noteDestination == .markdownFolder {
                    HStack(spacing: 10) {
                        Text(notesFolderDisplay)
                            .font(.sf(Tokens.TypeSize.label))
                            .foregroundStyle(Tokens.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        SettingActionButton(title: L("general.noteFolder.choose")) { chooseNotesFolder() }
                    }
                }
            }
        }
    }

    private func selectNoteDestination(_ newValue: NoteDestination) {
        guard newValue != noteDestination else { return }
        noteDestination = newValue
        NoteDestination.current = newValue
    }

    /// Standard folder picker for the Markdown destination. The modal steals key
    /// focus from the notch (the panel may fold behind it) — harmless: the pick
    /// lands in `UserDefaults`, and the row shows it whenever Settings reopens.
    private func chooseNotesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: FileNotesService.folderPath, isDirectory: true)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            FileNotesService.folderPath = url.path
            notesFolderDisplay = FileNotesService.folderDisplayPath
        }
    }

    /// Custom instructions (XII-137): personal preference the model gets
    /// appended after its built-in persona on the Ask path — "always answer in
    /// English", "prefer code", "metric units". Empty by default. Deliberately
    /// understated: the hint says it refines, never that it overrides the core
    /// rules.
    ///
    /// Always folded away at rest behind the same glass disclosure chip the API
    /// key uses — including when an instruction is already on file: it is a
    /// once-in-a-while preference, not something the pane should spend a whole
    /// field on every time it opens.
    private var customInstructionsRow: some View {
        let trimmed = model.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return SettingsCollapsible(
            title: L("general.customInstructions"),
            summary: trimmed.isEmpty ? nil : trimmed,
            isOpen: $instructionsSectionOpen
        ) {
            SettingsTextField(
                placeholder: L("general.customInstructions.placeholder"),
                text: Binding(
                    get: { model.customInstructions },
                    set: { model.customInstructions = $0 }
                ),
                lines: 1...3,
                onChange: { _ in model.noteUserTyping() }
            )
        }
    }

    /// Memory's master switch (`UserMemory.enabled`), on for new installs, beside
    /// the Memory disclosure chip.
    private var memoryToggle: some View {
        Toggle("", isOn: Binding(
            get: { memory.enabled },
            set: { on in
                Haptics.levelChange()
                // Off forgets every file, so it asks first.
                guard on || memory.entries.isEmpty else {
                    memoryForgetTarget = MemoryForgetTarget(turnsOff: true)
                    return
                }
                memory.enabled = on
                if on { model.scanHistoryForMemories() }
            }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Tokens.switchTint)
        .accessibilityLabel(L("memory.toggle"))
    }

    /// Memory's master switch, as a plain row; the folder opens in Finder from
    /// the "Manage your memories" link under the group.
    private var memoryEnableRow: some View {
        settingRow(label: L("memory.toggle"), info: L("memory.info"), aligned: true) {
            memoryToggle
        }
    }

    /// Whether Notchi launches itself when you log in. Off by default; flipping it
    /// on registers a login item via `SMAppService` so the notch is there from the
    /// first hover after every restart, with no manual relaunch.
    private var launchAtLoginRow: some View {
        settingRow(label: L("general.launchAtLogin")) {
            Toggle("", isOn: Binding(
                get: { launchAtLogin },
                set: { Haptics.levelChange(); selectLaunchAtLogin($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.switchTint)
        }
    }

    // MARK: - System permissions

    /// The protected capabilities Notchi currently consumes. Keeping the list in
    /// General makes the system's invisible TCC state explicit, and the trailing
    /// action gives every missing permission a recovery path in the same place.
    private var permissionsSection: some View {
        let grantedCount = SystemPermission.allCases.filter { permissionStatus[$0] == .granted }.count
        let summary = permissionStatus.isEmpty ? nil : "\(grantedCount) / \(SystemPermission.allCases.count)"
        return SettingsCollapsible(
            title: L("permissions.title"),
            summary: summary,
            isOpen: $permissionsSectionOpen
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(SystemPermission.allCases, id: \.self) { permission in
                    permissionRow(label: L(permission.labelKey),
                                  status: permissionStatus[permission] ?? .checking) {
                        requestPermission(permission)
                    }
                }
            }
        }
        // Probes only while the list is open. The first pass may launch Notes,
        // Mail and Music in the background, since the Apple Events check needs
        // a running target; later passes re-read every status every two
        // seconds, so a switch flipped in System Settings shows here without
        // Notchi having to become the active app (it rarely does).
        .task(id: permissionsSectionOpen) {
            guard permissionsSectionOpen else { return }
            refreshPermissions(launchingApps: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                refreshPermissions(launchingApps: false)
            }
        }
    }

    private func permissionRow(label: String,
                               status: SettingsPermissionStatus,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.sf(Tokens.TypeSize.form, weight: .regular))
                .foregroundStyle(Tokens.text2)
                .lineLimit(1)
            Spacer(minLength: 12)
            PermissionStatusPill(status: status, action: action)
        }
    }

    /// Writes only a changed value, so the two-second poll does not redraw the
    /// pane when nothing moved.
    private func setPermission(_ permission: SystemPermission, _ status: SettingsPermissionStatus) {
        if permissionStatus[permission] != status { permissionStatus[permission] = status }
    }

    /// None of this may run on the render path: every TCC probe is a blocking
    /// round-trip to a system daemon, not a property read.
    ///
    /// - `EKEventStore.authorizationStatus` measured **50–70 ms** whenever its
    ///   in-process cache is cold (it warms after two calls and drops again on
    ///   any TCC change);
    /// - `UNUserNotificationCenter.current()` opens its XPC connection on first
    ///   touch;
    /// - the Apple Events probes walk LaunchServices and may launch the target.
    ///
    /// Same rule `refreshProxyStatus` already follows: resolve off the main
    /// thread, let the pills fill in a beat later. They start on `.checking`, so
    /// there is nothing to flash. Location is the exception: its status lives
    /// on `LocationService`'s manager, which belongs to the main thread.
    private func refreshPermissions(launchingApps: Bool) {
        setPermission(.location, Self.locationStatus(LocationService.shared.authorizationStatus))
        Task.detached(priority: .userInitiated) {
            for permission in SystemPermission.allCases {
                guard let status = Self.queryStatus(permission) else { continue }
                await MainActor.run { setPermission(permission, status) }
            }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let notifications = Self.notificationsStatus(settings.authorizationStatus)
            await MainActor.run { setPermission(.notifications, notifications) }
        }
        for permission in SystemPermission.allCases {
            guard let bundleID = permission.automationTarget else { continue }
            withRunningApp(bundleID, launching: launchingApps) { pid in
                guard let pid else {
                    // Not running and not launched this pass: keep what the
                    // last probe found.
                    if launchingApps { setPermission(permission, .unavailable) }
                    return
                }
                determineAutomationPermission(permission, pid: pid, ask: false)
            }
        }
    }

    /// The live state of the permissions with a synchronous status query; nil
    /// for the ones read elsewhere (notifications, location, Apple Events).
    /// `nonisolated` on purpose: it touches no view state, and
    /// `refreshPermissions` runs it off the main thread.
    nonisolated private static func queryStatus(_ permission: SystemPermission) -> SettingsPermissionStatus? {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .authorized, .fullAccess: return .granted
            // Write-only adds events but cannot read the schedule.
            case .writeOnly:               return .limited
            case .notDetermined:           return .notDetermined
            case .denied, .restricted:     return .denied
            @unknown default:              return .unavailable
            }
        case .reminders:
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .authorized, .fullAccess: return .granted
            case .writeOnly:               return .limited
            case .notDetermined:           return .notDetermined
            case .denied, .restricted:     return .denied
            @unknown default:              return .unavailable
            }
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized:              return .granted
            case .limited:                 return .limited
            case .notDetermined:           return .notDetermined
            case .denied, .restricted:     return .denied
            @unknown default:              return .unavailable
            }
        case .photos:
            switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .authorized:              return .granted
            case .limited:                 return .limited
            case .notDetermined:           return .notDetermined
            case .denied, .restricted:     return .denied
            @unknown default:              return .unavailable
            }
        case .notifications, .location, .notes, .mail, .music:
            return nil
        }
    }

    private static func locationStatus(_ status: CLAuthorizationStatus) -> SettingsPermissionStatus {
        switch status {
        case .authorizedAlways:        return .granted
        case .notDetermined:           return .notDetermined
        // Also what macOS reports while Location Services is off system-wide.
        case .denied, .restricted:     return .denied
        @unknown default:              return .unavailable
        }
    }

    nonisolated private static func notificationsStatus(
        _ status: UNAuthorizationStatus
    ) -> SettingsPermissionStatus {
        switch status {
        case .authorized, .provisional, .ephemeral: return .granted
        case .notDetermined:                       return .notDetermined
        case .denied:                              return .denied
        @unknown default:                          return .unavailable
        }
    }

    /// A row's action. A refused or partial grant can only be changed in System
    /// Settings, and so can Accessibility, which has no in-app prompt that
    /// grants it; the rest raise the system prompt and re-read the state after.
    private func requestPermission(_ permission: SystemPermission) {
        let current = permissionStatus[permission] ?? .checking
        if permission == .screenRecording {
            ScreenPermissionGuideController.shared.showScreenRecordingGuide()
            return
        }
        if current == .denied || current == .limited || permission == .accessibility {
            openSettings(for: permission)
            return
        }
        setPermission(permission, .checking)
        // The system prompt sits outside the island; the panel stays open
        // until it is answered (`PermissionPromptGate`).
        PermissionPromptGate.enter()
        let reread: @Sendable () -> Void = {
            PermissionPromptGate.exit()
            Task { @MainActor in refreshPermissions(launchingApps: false) }
        }
        switch permission {
        case .accessibility, .screenRecording:
            PermissionPromptGate.exit()
        case .notifications:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in reread() }
        case .location:
            Task { @MainActor in
                await LocationService.shared.requestAccess()
                PermissionPromptGate.exit()
                refreshPermissions(launchingApps: false)
            }
        case .calendar:
            EKEventStore().requestFullAccessToEvents { _, _ in reread() }
        case .reminders:
            EKEventStore().requestFullAccessToReminders { _, _ in reread() }
        case .contacts:
            CNContactStore().requestAccess(for: .contacts) { _, _ in reread() }
        case .photos:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in reread() }
        case .notes, .mail, .music:
            guard let bundleID = permission.automationTarget else {
                PermissionPromptGate.exit()
                return
            }
            withRunningApp(bundleID, launching: true) { pid in
                guard let pid else {
                    PermissionPromptGate.exit()
                    setPermission(permission, .unavailable)
                    return
                }
                determineAutomationPermission(permission, pid: pid, ask: true) {
                    PermissionPromptGate.exit()
                }
            }
        }
    }

    private func openSettings(for permission: SystemPermission) {
        if permission == .notifications {
            openSystemSettings("com.apple.Notifications-Settings.extension")
        } else {
            openPrivacySettings(permission.privacyAnchor)
        }
    }

    /// Supply a running process of `bundleID` without bringing it to the
    /// foreground. Apple Events is the one protected API without a public status
    /// query for a dormant target: `AEDeterminePermission…` requires a live
    /// process, so an app that is not running is launched without activation
    /// when `launching` is set, and reported as nil otherwise.
    ///
    /// Both lookups are LaunchServices round-trips (`urlForApplication` measured
    /// ~7 ms cold). They run off the main thread; only the launch and the
    /// completion come back to it. A `pid` crosses the boundary rather than the
    /// `NSRunningApplication`, since the pid is all the AE probe wants.
    private func withRunningApp(_ bundleID: String,
                                launching: Bool,
                                _ completion: @escaping @MainActor (pid_t?) -> Void) {
        Task.detached(priority: .userInitiated) {
            if let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID).first {
                let pid = running.processIdentifier
                await MainActor.run { completion(pid) }
                return
            }
            guard launching,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                await MainActor.run { completion(nil) }
                return
            }
            await MainActor.run {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.addsToRecentItems = false
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
                    let pid = app?.processIdentifier
                    Task { @MainActor in completion(pid) }
                }
            }
        }
    }

    /// This call can block behind the secure consent sheet, so it always runs off
    /// the main thread. The result is then translated back onto the view state.
    private func determineAutomationPermission(_ permission: SystemPermission, pid: pid_t, ask: Bool,
                                               answered: @escaping @Sendable () -> Void = {}) {
        DispatchQueue.global(qos: .userInitiated).async {
            let target = NSAppleEventDescriptor(processIdentifier: pid)
            let result = AEDeterminePermissionToAutomateTarget(
                target.aeDesc,
                AEEventClass(typeWildCard),
                AEEventID(typeWildCard),
                ask)
            let status: SettingsPermissionStatus
            switch result {
            case noErr:                              status = .granted
            case OSStatus(errAEEventNotPermitted):  status = .denied
            case OSStatus(errAEEventWouldRequireUserConsent): status = .notDetermined
            default:                                 status = .unavailable
            }
            answered()
            Task { @MainActor in setPermission(permission, status) }
        }
    }

    private func openPrivacySettings(_ anchor: String) {
        openSystemSettings("com.apple.preference.security?\(anchor)")
    }

    private func openSystemSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// The message tones: sending, each reply bubble landing, and a reaction.
    /// Same flag as the row in the result header's more menu.
    private var messageSoundsRow: some View {
        settingRow(label: L("messageSounds"),
                   aligned: true) {
            Toggle("", isOn: Binding(
                get: { model.messageSoundsEnabled },
                set: { Haptics.levelChange(); model.messageSoundsEnabled = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.switchTint)
        }
    }

    /// Which model answers the decision calls: Copy Sense, emoji reactions, the
    /// link pre-check and the follow-up check.
    private var decisionModelRow: some View {
        settingRow(label: L("decision.model"), info: L("decision.model.hint")) {
            GlassMenu(title: decisionModel.label,
                      items: DecisionModel.allCases.map { m in
                GlassMenuItem(title: m.label, selected: m == decisionModel) {
                    guard m != decisionModel else { return }
                    decisionModel = m
                    DecisionModel.current = m
                    decisionTestResult = nil
                }
            })
        }
    }

    /// The user's endpoint: base URL, key (optional for a local server), and
    /// model id. Same field chrome as the custom chat endpoint's.
    @ViewBuilder
    private var decisionEndpointRows: some View {
        decisionField(label: L("model.custom.url"), placeholder: L("model.custom.urlPlaceholder"),
                      text: $decisionURL) { DecisionEndpoint.baseURL = $0 }
        if let resolved = CustomProvider.normalized(decisionURL) {
            Text(L("model.custom.resolved", resolved.absoluteString))
                .font(.sf(Tokens.TypeSize.meta))
                .foregroundStyle(Tokens.text3)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, SettingsMetrics.fieldIndent)
        }
        decisionField(label: L("decision.key"), placeholder: L("decision.keyPlaceholder"),
                      text: $decisionKey, secure: true) { DecisionEndpoint.apiKey = $0 }
        decisionField(label: L("model.custom.model"), placeholder: L("model.custom.modelPlaceholder"),
                      text: $decisionModelID) { DecisionEndpoint.model = $0 }
        if decisionURL.isEmpty || decisionModelID.isEmpty {
            Text(L("decision.incomplete"))
                .font(.sf(Tokens.TypeSize.meta))
                .foregroundStyle(Tokens.text3)
                .padding(.leading, SettingsMetrics.fieldIndent)
        }
    }

    /// Test for the picked decision model, trailing like the key section's,
    /// with the verdict under it. Offered once there is something to test.
    @ViewBuilder
    private var decisionTestRow: some View {
        let ready = decisionModel == .jevKey ? !typeSafeKey.isEmpty
            : !decisionURL.isEmpty && !decisionModelID.isEmpty
        if ready {
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                if decisionTesting {
                    ProgressView().controlSize(.small)
                } else {
                    SettingActionButton(title: L("model.test")) { testDecisionModel() }
                }
            }
            // The field sits at the pane's right edge, so Test does too.
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        if let result = decisionTestResult {
            statusPill(ok: result.isOK, message: result.isOK ? L("decision.test.ok") : result.message)
                .padding(.leading, SettingsMetrics.fieldIndent)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func testDecisionModel() {
        let target = decisionModel
        decisionTesting = true
        decisionTestResult = nil
        Task {
            let result = await OwnDecisionModel.test()
            await MainActor.run {
                decisionTesting = false
                // Drop the verdict if the user switched models mid-flight.
                guard target == decisionModel else { return }
                withAnimation(.easeOut(duration: 0.2)) { decisionTestResult = result }
            }
        }
    }

    /// The decision model's three inputs share one grid: a 64pt label column,
    /// a 12pt gap, then the field, which stops at `decisionFieldWidth` instead
    /// of running to the pane edge. These hold a server URL, a key and a model
    /// id — short values that read as a form here and as a page at full width.
    private static let decisionLabelWidth: CGFloat = 64
    private static let decisionFieldWidth: CGFloat = 280
    private static var decisionRowWidth: CGFloat {
        decisionLabelWidth + 12 + decisionFieldWidth
    }

    private func decisionField(label: String, placeholder: String, text: Binding<String>,
                               secure: Bool = false,
                               commit: @escaping (String) -> Void) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.sf(Tokens.TypeSize.form, weight: .regular))
                .foregroundStyle(Tokens.text2)
                .frame(width: Self.decisionLabelWidth, alignment: .leading)
            Spacer(minLength: 0)
            SettingsTextField(
                placeholder: placeholder,
                text: text,
                secure: secure,
                onChange: { newValue in
                    model.noteUserTyping()
                    commit(newValue)
                    decisionTestResult = nil
                }
            )
            .frame(maxWidth: Self.decisionFieldWidth, alignment: .leading)
        }
    }

    /// Copy history's own switch (`ClipboardHistory.enabled`). Off deletes
    /// every saved copy, so with any saved it asks first.
    private var clipboardHistoryRow: some View {
        settingRow(label: L("clipboardHistory.toggle"), info: L("clipboardHistory.info"), aligned: true) {
            Toggle("", isOn: Binding(
                get: { clipboardHistory.enabled },
                set: { on in
                    Haptics.levelChange()
                    let saved = on ? 0 : clipboardHistory.count()
                    guard saved == 0 else {
                        clipboardConfirm = .turnOff(count: saved)
                        return
                    }
                    clipboardHistory.enabled = on
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.switchTint)
        }
    }

    private func clipboardConfirmTitle(_ confirm: ClipboardConfirm) -> String {
        switch confirm {
        case .turnOff: return L("clipboardHistory.off")
        case .shorten: return L("clipboardHistory.shorten")
        case .clearAll: return L("clipboardHistory.clearAll")
        }
    }

    private func clipboardConfirmText(_ confirm: ClipboardConfirm) -> String {
        switch confirm {
        case .turnOff(let count): return L("clipboardHistory.off.confirm", count)
        case .shorten(let option, let count): return L("clipboardHistory.shorten.confirm", option.label, count)
        case .clearAll(let count): return L("clipboardHistory.clearAll.confirm", count)
        }
    }

    /// How long copies are kept (`ClipboardHistory.retention`): an Auto delete
    /// switch, off by default (`forever`), and once on, the period, 7 days to
    /// start. A period that would delete saved copies asks first.
    @ViewBuilder
    private var clipboardRetentionRow: some View {
        let autoDelete = clipboardHistory.retention != .forever
        settingRow(label: L("clipboardHistory.autoDelete"), aligned: true) {
            Toggle("", isOn: Binding(
                get: { autoDelete },
                set: { on in
                    Haptics.levelChange()
                    setClipboardRetention(on ? ClipboardRetention.autoDeleteDefault : .forever)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.switchTint)
        }
        if autoDelete {
            settingRow(label: L("clipboardHistory.retention"), aligned: true) {
                GlassMenu(title: clipboardHistory.retention.label, items: ClipboardRetention.periods.map { option in
                    GlassMenuItem(title: option.label, selected: clipboardHistory.retention == option) {
                        guard clipboardHistory.retention != option else { return }
                        Haptics.levelChange()
                        setClipboardRetention(option)
                    }
                })
            }
        }
    }

    private func setClipboardRetention(_ option: ClipboardRetention) {
        let doomed = clipboardHistory.count(olderThan: option)
        guard doomed == 0 else {
            clipboardConfirm = .shorten(option, count: doomed)
            return
        }
        clipboardHistory.retention = option
    }

    /// Whether a finished answer gets a predicted next question in the reply
    /// field. Same flag as `NotchModel.suggestFollowUpEnabled`.
    private var suggestFollowUpRow: some View {
        settingRow(label: L("chat.suggestFollowUp"),
                   info: L("chat.suggestFollowUp.hint"),
                   aligned: true) {
            Toggle("", isOn: Binding(
                get: { model.suggestFollowUpEnabled },
                set: { Haptics.levelChange(); model.suggestFollowUpEnabled = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.switchTint)
        }
    }

    /// How often Notchi writes first (`ProactiveLevel`), with its notebook link
    /// tucked right underneath so the two read as one setting.
    private var proactiveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            proactiveRow
            if proactive.level != .off {
                UnderlineLink(title: L("proactive.notebook.open"), external: true) { proactive.openNotebook() }
            }
        }
    }

    /// How often Notchi writes first (`ProactiveLevel`). One menu of four
    /// levels, like `copySenseRow`'s three states. Picking a level other than
    /// Off asks for Calendar and Reminders access, which the messages read.
    private var proactiveRow: some View {
        settingRow(label: L("proactive.title"), info: L("proactive.hint"), aligned: true) {
            GlassMenu(title: proactive.level.label, items: ProactiveLevel.allCases.map { level in
                GlassMenuItem(title: level.label, selected: proactive.level == level) {
                    guard proactive.level != level else { return }
                    Haptics.levelChange()
                    proactive.level = level
                    if level != .off { proactive.requestAccess() }
                }
            })
        }
    }

    /// Pages published at `*.notch.website`; opens the manager sub-page.
    private var pagesRow: some View {
        settingRow(label: L("pages.title"), info: L("pages.hint"), aligned: true) {
            TelegramStepPill(title: L("pages.manage")) { open(.pages) }
        }
    }

    /// Connect: the user's own Telegram bot (`TelegramBridge`). One toggle,
    /// like `memoryEnableRow`: off hides everything under it. On and not yet
    /// connected, the three setup steps are rows in the shape of
    /// `permissionRow` — a label and one neutral capsule on the right. On and
    /// connected, the bot and the account, and a link to start over, placed
    /// like Memory's "Manage your memories".
    private var cloudMachineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(label: L("cloud.title"), info: L("cloud.hint"), aligned: true, tag: "Beta") {
                Toggle("", isOn: Binding(
                    get: { instaBox.isOn },
                    set: { on in
                        Haptics.levelChange()
                        instaBox.setOn(on)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Tokens.switchTint)
            }
            switch instaBox.state {
            case .connected(let login):
                HStack(spacing: 12) {
                    if !login.isEmpty {
                        Text(login)
                            .font(.sf(Tokens.TypeSize.meta))
                            .foregroundStyle(Tokens.text3)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                    UnderlineLink(title: L("cloud.manage")) { instaBox.openDashboard() }
                    UnderlineLink(title: L("cloud.disconnect")) { instaBox.disconnect() }
                }
                .padding(.top, -6)
            case .claiming(let code, _):
                HStack(spacing: 12) {
                    Text(L("cloud.claiming", code))
                        .font(.sf(Tokens.TypeSize.meta))
                        .foregroundStyle(Tokens.text3)
                        .textSelection(.enabled)
                    TelegramStepPill(title: L("cloud.openPage")) { instaBox.openClaimPage() }
                }
                .padding(.top, -6)
            case .failed:
                Text(L("cloud.failed"))
                    .font(.sf(Tokens.TypeSize.meta))
                    .foregroundStyle(Tokens.danger)
                    .padding(.top, -6)
            case .off:
                EmptyView()
            }
        }
        .onAppear { instaBox.refresh() }
    }

    // MARK: - Connectors

    /// The groups the table can show: only the ones that still have a connector
    /// after `MCPConnector.all` drops those this build cannot sign in to.
    private var connectorCategories: [MCPConnector.Category] {
        MCPConnector.Category.allCases.filter { category in
            !MCPConnector.connectors(in: category).isEmpty
        }
    }

    /// The group the table is showing. Falls back to the first available one, so
    /// a stored pick that no longer exists cannot leave the table empty.
    private var activeConnectorCategory: MCPConnector.Category {
        connectorCategories.contains(connectorCategory)
            ? connectorCategory
            : (connectorCategories.first ?? .recommended)
    }

    private var connectorCategoryTabs: some View {
        SettingsTabs(
            items: connectorCategories,
            selection: activeConnectorCategory,
            title: { L("connector.category.\($0.rawValue)") },
            onSelect: { connectorCategory = $0 }
        )
    }

    private var telegramSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Laid out like a connector row: icon, name, and the status column.
            // The icon keeps the name's line, so the handles below it are the
            // row's second line and the block stays as tall as its content.
            HStack(alignment: .center, spacing: 10) {
                Image("ConnectorLogo-telegram")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("telegram.title"))
                        .font(.sf(Tokens.TypeSize.form, weight: .regular))
                        .foregroundStyle(Tokens.text1)
                        .lineLimit(1)
                    if case .connected(let bot, let owner) = telegram.state {
                        HStack(spacing: 12) {
                            ForEach(owner.isEmpty ? ["@" + bot] : ["@" + bot, owner], id: \.self) { name in
                                Text(name)
                                    .font(.sf(Tokens.TypeSize.meta))
                                    .foregroundStyle(Tokens.text3)
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                            }
                            UnderlineLink(title: L("telegram.avatar")) { saveTelegramAvatar() }
                            UnderlineLink(title: L("telegram.useAnother")) { telegramConfirmForget = true }
                        }
                    }
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(
                    get: { telegramOn },
                    set: { on in
                        Haptics.levelChange()
                        setTelegram(on)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Tokens.switchTint)
            }
            .frame(minHeight: 40)
            if telegramSettingUp {
                let completed = max(0, telegramCurrentStep - 1)
                SettingsPlanSteps(title: L("telegram.title"), completedCount: completed, totalCount: 3) {
                    SettingsPlanStep(title: L("telegram.step1"),
                                     status: telegramStepStatus(1)) {
                        TelegramStepPill(title: L("telegram.openBotFather")) {
                            openBotFather()
                            telegramOpenedBotFather = true
                        }
                    } detail: {
                        if telegramCurrentStep == 1 {
                            Text(L("telegram.step1.detail"))
                                .font(.sf(Tokens.TypeSize.meta))
                                .foregroundStyle(Tokens.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    SettingsPlanStep(title: L("telegram.step2"),
                                     status: telegramStepStatus(2)) {
                        if telegram.state == .checking {
                            TelegramStepPill(title: L("telegram.checking"), action: nil)
                        }
                    } detail: {
                        if telegramCurrentStep == 2, telegram.state != .checking {
                            telegramTokenField
                            if telegram.state == .invalidToken {
                                Text(L("telegram.invalid"))
                                    .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                                    .foregroundStyle(Tokens.danger)
                            }
                        }
                    }
                    SettingsPlanStep(title: L("telegram.step3"),
                                     status: telegramStepStatus(3),
                                     isLast: true) {
                        if case .pairing(let bot) = telegram.state {
                            TelegramStepPill(title: "@" + bot) { telegram.openPairing() }
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .onChange(of: telegramSettingUp, initial: true) { telegram.holdsPanel = telegramSettingUp }
        .onDisappear { telegram.holdsPanel = false }
        // A token copied in Telegram fills the field on its own.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            guard telegramOn, telegram.state == .off || telegram.state == .invalidToken else { return }
            let board = NSPasteboard.general
            guard board.changeCount != telegramBoardCount else { return }
            telegramBoardCount = board.changeCount
            if let copied = board.string(forType: .string), TelegramBridge.looksLikeToken(copied) {
                telegramOpenedBotFather = true
                telegramToken = copied.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    // MARK: - Signal Channel

    private var signalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image("ConnectorLogo-signal")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(L("signal.title"))
                            .font(.sf(Tokens.TypeSize.form, weight: .regular))
                            .foregroundStyle(Tokens.text1)
                            .lineLimit(1)
                        SettingsBadge(text: L("signal.tag"), variant: .secondary)
                    }
                    if case .connected(let account) = signal.state {
                        HStack(spacing: 12) {
                            Text(signal.settingUpChat ? L("signal.settingUpChat") : L("signal.noteToSelfHint"))
                                .font(.sf(Tokens.TypeSize.meta))
                                .foregroundStyle(Tokens.text3)
                                .lineLimit(1)
                            Text(account)
                                .font(.sf(Tokens.TypeSize.meta))
                                .foregroundStyle(Tokens.text3)
                                .lineLimit(1)
                                .textSelection(.enabled)
                            UnderlineLink(title: L("telegram.forget")) { signalConfirmForget = true }
                        }
                    }
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(
                    get: { signalOn },
                    set: { on in
                        Haptics.levelChange()
                        setSignal(on)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Tokens.switchTint)
            }
            .frame(minHeight: 40)
            if signalSettingUp {
                let completed = max(0, signalCurrentStep - 1)
                SettingsPlanSteps(title: L("signal.title"), completedCount: completed, totalCount: 3) {
                    SettingsPlanStep(title: L("signal.step1"),
                                     status: signalStepStatus(1)) {
                        switch signal.state {
                        case .installingCLI:
                            TelegramStepPill(title: L("signal.installing"), action: nil)
                        case .missingCLI:
                            if SignalBridge.hasBrew {
                                TelegramStepPill(title: L("signal.installBrew")) {
                                    Task { await signal.installCLI() }
                                }
                            } else {
                                TelegramStepPill(title: signalCopiedBrew ? L("signal.copied") : L("signal.copyBrew")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("brew install signal-cli", forType: .string)
                                    signalCopiedBrew = true
                                }
                            }
                        default:
                            EmptyView()
                        }
                    } detail: {
                        if signalCurrentStep == 1 {
                            Text(L("signal.step1.detail"))
                                .font(.sf(Tokens.TypeSize.meta))
                                .foregroundStyle(Tokens.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    SettingsPlanStep(title: L("signal.step2"),
                                     status: signalStepStatus(2)) {
                        switch signal.state {
                        case .checking:
                            TelegramStepPill(title: L("telegram.checking"), action: nil)
                        case .linking:
                            TelegramStepPill(title: L("signal.refreshQR")) {
                                signal.startNewLink()
                            }
                        case .failed:
                            TelegramStepPill(title: L("signal.retry")) {
                                Task { await signal.beginSetup() }
                            }
                        default:
                            EmptyView()
                        }
                    } detail: {
                        if case .linking(let uri) = signal.state {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L("signal.step2.detail"))
                                    .font(.sf(Tokens.TypeSize.meta))
                                    .foregroundStyle(Tokens.text3)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let qr = SignalBridge.qrImage(for: uri) {
                                    Image(nsImage: qr)
                                        .interpolation(.none)
                                        .resizable()
                                        .frame(width: 148, height: 148)
                                        .padding(10)
                                        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }
                        } else if case .failed(let reason) = signal.state {
                            Text(reason)
                                .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                                .foregroundStyle(Tokens.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    SettingsPlanStep(title: L("signal.step3"),
                                     status: signalStepStatus(3),
                                     isLast: true) {
                        EmptyView()
                    }
                }
                .padding(.top, 6)
                .transition(.opacity)
            }
        }
        .onChange(of: signalSettingUp, initial: true) { signal.holdsPanel = signalSettingUp }
        .onDisappear { signal.holdsPanel = false }
    }

    private var signalSettingUp: Bool {
        if case .connected = signal.state { return false }
        return signalOn
    }

    private var signalOn: Bool {
        switch signal.state {
        case .connected, .linking, .checking, .installingCLI, .missingCLI, .failed: return true
        case .paused: return false
        case .off: return signalSetupOpen
        }
    }

    private var signalCurrentStep: Int {
        switch signal.state {
        case .missingCLI, .installingCLI: return 1
        case .checking, .linking, .failed: return 2
        case .connected, .paused: return 3
        case .off: return SignalBridge.findCLI() == nil ? 1 : 2
        }
    }

    private func setSignal(_ on: Bool) {
        withAnimation(.easeOut(duration: 0.16)) {
            if on {
                if case .paused = signal.state {
                    signal.reconnect()
                } else {
                    signalSetupOpen = true
                    Task { await signal.beginSetup() }
                }
            } else {
                signalSetupOpen = false
                if case .connected = signal.state {
                    signal.disconnect()
                } else if signal.state != .off {
                    signal.forget()
                }
            }
        }
    }

    private func signalStepStatus(_ number: Int) -> SettingsPlanStepStatus {
        let current = signalCurrentStep
        if number < current { return .done }
        if number == current { return .running }
        return .pending
    }

    /// The setup steps are on screen.
    private var telegramSettingUp: Bool {
        if case .connected = telegram.state { return false }
        return telegramOn
    }

    /// On while connected or being set up; off when never set up or paused.
    private var telegramOn: Bool {
        switch telegram.state {
        case .connected, .pairing, .checking, .invalidToken: return true
        case .paused: return false
        case .off: return telegramSetupOpen
        }
    }

    /// Off pauses a connected bot (kept for one-click on) and abandons a
    /// setup in progress. On resumes a paused bot, or opens the setup steps.
    private func setTelegram(_ on: Bool) {
        withAnimation(.easeOut(duration: 0.16)) {
            if on {
                if case .paused = telegram.state {
                    Task { await telegram.reconnect() }
                } else {
                    telegramSetupOpen = true
                }
            } else {
                telegramSetupOpen = false
                if case .connected = telegram.state {
                    telegram.disconnect()
                } else if telegram.state != .off {
                    telegramOpenedBotFather = false
                    telegram.forget()
                }
            }
        }
    }

    /// Which setup step is on: 3 once the token works, 2 once BotFather was
    /// opened (or a token arrived), else 1.
    private var telegramCurrentStep: Int {
        switch telegram.state {
        case .pairing, .connected, .paused: return 3
        case .checking, .invalidToken: return 2
        case .off: return telegramOpenedBotFather ? 2 : 1
        }
    }

    private func telegramStepStatus(_ number: Int) -> SettingsPlanStepStatus {
        let current = telegramCurrentStep
        if number < current { return .done }
        if number == current { return .running }
        return .pending
    }

    private var telegramTokenField: some View {
        SettingsTextField(
            placeholder: L("telegram.pasteToken"),
            text: $telegramToken,
            invalid: telegram.state == .invalidToken,
            onSubmit: { connectTelegram() },
            onChange: { newValue in
                model.noteUserTyping()
                if TelegramBridge.looksLikeToken(newValue) { connectTelegram() }
            }
        )
    }

    /// Saves Notchi's two eyes (`NotchiMarkEyes`, the resting notch's face)
    /// as two 640pt square JPEGs in Downloads — light eyes on black, and the
    /// same inverted — and shows them in Finder. Sized so Telegram's circular
    /// crop keeps both eyes whole.
    private func saveTelegramAvatar() {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        else { return }
        var saved: [URL] = []
        for (name, light) in [("Notchi Bot Dark.jpg", false), ("Notchi Bot Light.jpg", true)] {
            let side: CGFloat = 640
            let renderer = ImageRenderer(content:
                ZStack {
                    Color.black
                    NotchiMarkEyes(pose: NotchiMarkPose(), eyeHeight: 210)
                }
                .frame(width: side, height: side)
                .modifier(InvertIf(on: light)))
            renderer.scale = 1
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.95])
            else { continue }
            let url = downloads.appendingPathComponent(name)
            if (try? data.write(to: url)) != nil { saved.append(url) }
        }
        if !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
    }

    private func openBotFather() {
        if let url = URL(string: "https://t.me/BotFather") { NSWorkspace.shared.open(url) }
    }

    /// The field keeps what was pasted while it is checked, and stays filled
    /// when the token is refused, so the user sees what was tried.
    private func connectTelegram() {
        let token = telegramToken
        Task {
            await telegram.connect(token: token)
            if telegram.state != .invalidToken { telegramToken = "" }
        }
    }

    /// Chat: the MCP servers in `mcp.json` and in other apps' settings, each
    /// with its state and where it came from, and `mcp.json` one click away.
    /// Opening the pane picks up an edited file.
    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingRow(label: L("mcp.title"), info: L("mcp.hint"), aligned: true) {
                HStack(spacing: 12) {
                    UnderlineLink(title: L("mcp.edit")) {
                        MCPConfig.ensureFile()
                        if !NSWorkspace.shared.open(MCPConfig.fileURL) {
                            NSWorkspace.shared.activateFileViewerSelecting([MCPConfig.fileURL])
                        }
                    }
                    UnderlineLink(title: L("mcp.reload")) { mcp.reload() }
                }
            }
            if let error = mcp.configError {
                Text(error)
                    .font(.sf(Tokens.TypeSize.meta))
                    .foregroundStyle(Tokens.danger)
            } else if mcp.servers.isEmpty {
                Text(L("mcp.empty"))
                    .font(.sf(Tokens.TypeSize.meta))
                    .foregroundStyle(Tokens.text3)
            }
            ForEach(mcp.servers) { server in
                mcpServerLine(server)
            }
        }
        .onAppear { mcp.reloadIfChanged() }
    }

    /// One server, laid out like `memoryFileRow`: dot and name, the state
    /// beside the name, the app it came from at the right edge. A failure's
    /// reason goes on its own line under the name, with Restart after it.
    private func mcpServerLine(_ server: MCPHub.Server) -> some View {
        let (color, state): (Color, String?) = {
            switch server.status {
            case .starting: return (Tokens.text3, L("mcp.starting"))
            case .ready(let tools): return (Tokens.success, L("mcp.tools", tools))
            case .failed: return (Tokens.danger, nil)
            case .off: return (Tokens.text3.opacity(0.5), L("mcp.off"))
            }
        }()
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(server.name)
                    .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                    .foregroundStyle(Tokens.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let state {
                    Text(state)
                        .font(.sf(Tokens.TypeSize.meta))
                        .foregroundStyle(Tokens.text3)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 12)
                if let source = server.source {
                    Text(source)
                        .font(.sf(Tokens.TypeSize.meta))
                        .foregroundStyle(Tokens.text4)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            if case .failed(let reason) = server.status {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(reason)
                        .font(.sf(Tokens.TypeSize.meta))
                        .foregroundStyle(Tokens.text3)
                        .lineLimit(metrics.noteLines(2))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    UnderlineLink(title: L("mcp.retry")) { mcp.restart(server.name) }
                        .fixedSize()
                }
                .padding(.leading, 14)
            }
        }
        .padding(.vertical, 2)
    }

    /// The collapsed-by-default tail of the General pane: plumbing nobody should
    /// have to walk past to reach the everyday rows. Same quiet disclosure line as
    /// `keySection` — it stays folded until the user opens it, whatever the proxy
    /// currently is.
    private var advancedSection: some View {
        SettingsCollapsible(
            title: L("general.advanced"),
            summary: model.proxyURL.isEmpty ? nil : model.proxyURL,
            isOpen: $advancedSectionOpen
        ) {
            VStack(alignment: .leading, spacing: 14) {
                proxyRow
                    .searchTarget("network.proxy", active: highlightedSearchKey)
                weatherCityRow
            }
        }
    }

    private var proxyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("network.proxy"))
                .font(.sf(Tokens.TypeSize.form, weight: .regular))
                .foregroundStyle(Tokens.text1)
            SettingInfo(L("network.proxy.hint"))
            SettingsTextField(
                placeholder: L("network.proxy.placeholder"),
                text: Binding(
                    get: { model.proxyURL },
                    set: { model.proxyURL = $0 }
                ),
                onChange: { _ in
                    model.noteUserTyping()
                    refreshProxyStatus()
                }
            )
            Text(proxyStatus)
                .font(.sf(Tokens.TypeSize.meta))
                .foregroundStyle(Tokens.text3)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .onAppear { refreshProxyStatus() }
    }

    private var weatherCityRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("weather.city"))
                .font(.sf(Tokens.TypeSize.form, weight: .regular))
                .foregroundStyle(Tokens.text1)
            SettingInfo(L("weather.city.hint"))
            SettingsTextField(
                placeholder: L("weather.city.placeholder"),
                text: $weatherCity,
                onChange: { _ in model.noteUserTyping() }
            )
        }
    }

    /// Resolving can spawn a login shell (the ".zshrc-only proxy" case), so it never
    /// runs on the render path — the caption fills in a beat later.
    private func refreshProxyStatus() {
        Task.detached(priority: .userInitiated) {
            let line = ProxyConfig.statusLine()
            await MainActor.run { proxyStatus = line }
        }
    }

    /// Height of the native slider itself, without the tick-label row beneath
    /// it. The row's own label centers on this, so it sits level with the track
    /// instead of drifting toward the labels below.
    static let sliderHeight: CGFloat = 22

    /// The global selected-text gesture has no keyboard binding: this is its one
    /// setting. Four ordered positions, quantized like the hover-sensitivity
    /// slider right above it — Off, Low, Balanced, Instant. Off disarms the
    /// gesture entirely; the other three set how long a still hold must last.
    private var forceClickPressureRow: some View {
        let controlWidth: CGFloat = 190
        return settingRow(label: L("general.forceClickPressure"),
                          info: L("general.forceClickPressure.hint"),
                          aligned: true,
                          verticalAlignment: .sliderTrack) {
            VStack(spacing: 1) {
                NativeDetentSlider(value: forceClickPressurePosition,
                                   ticks: ForceClickPressure.allCases.count)
                    .frame(width: controlWidth, height: Self.sliderHeight)
                    .accessibilityLabel(L("general.forceClickPressure"))

                tickLabelRow(ForceClickPressure.allCases,
                             selected: model.forceClickPressure,
                             width: controlWidth)
            }
            .alignmentGuide(.sliderTrack) { _ in Self.sliderHeight / 2 }
        }
    }

    /// The pause taken from the Force Touch popup itself, said out loud on the
    /// slider it contradicts. Without it this row reads "Medium" while pressing
    /// harder does nothing, and the only account of why is a menu-bar item the
    /// user may never open — a setting that silently lies about its own state.
    ///
    /// Only mounted while a pause is actually running, so it is a passing notice
    /// rather than a permanent line of chrome, and it carries the way out with it.
    private var forceClickPausedNotice: some View {
        HStack(spacing: 8) {
            Text(L("disable.settings.paused",
                   Self.pauseEndsAt(model.forceTouchDisabledUntil)))
                .font(.sf(Tokens.TypeSize.meta))
                .foregroundStyle(Tokens.text3)
                .fixedSize(horizontal: false, vertical: true)
            SettingActionButton(title: L("disable.settings.resume")) {
                model.resumeForceTouch()
            }
            Spacer(minLength: 0)
        }
        .padding(.top, -2)
        .transition(.opacity)
    }

    /// When the pause lapses, in the user's own short time format.
    private static func pauseEndsAt(_ date: Date?) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date ?? Date())
    }

    /// Labels under a detent slider, one per tick mark. The inner ones sit
    /// centered on the x where AppKit draws their mark (see
    /// `NativeDetentSlider.tickFractions`); the two end ones are pinned flush to
    /// the control's edges instead of centered on their mark.
    ///
    /// Pinning, not clamping: a clamp only moves an end label when it is wide
    /// enough to overhang, so `Instant` ended up flush right while `Firm` sat a
    /// few points inside it — two stacked sliders whose end columns didn't line
    /// up. Flush edges make every row's first and last label share one x, in any
    /// language, and keep an end label off the row's own text (`Off` is
    /// `Désactivé` in French).
    private func tickLabelRow<Option: Identifiable & Equatable & Hashable>(
        _ options: [Option],
        selected: Option,
        width: CGFloat
    ) -> some View where Option: RawRepresentable, Option.RawValue == String {
        let fractions = NativeDetentSlider.tickFractions(count: options.count, width: width)
        let last = options.count - 1
        return ZStack(alignment: .topLeading) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                let fraction = fractions[index]
                tickLabel(option, selected: selected)
                    .fixedSize()
                    .alignmentGuide(.leading) { label in
                        if index == 0 { return 0 }
                        if index == last { return label.width - width }
                        let centered = label.width / 2 - width * fraction
                        return Swift.min(Swift.max(centered, label.width - width), 0)
                    }
            }
        }
        .frame(width: width, height: 14)
    }

    private func tickLabel<Option: RawRepresentable & Equatable>(
        _ option: Option,
        selected: Option
    ) -> some View where Option.RawValue == String {
        let isSelected = option == selected
        return Text(optionLabel(option))
            .font(.sf(Tokens.TypeSize.meta, weight: .regular))
            .foregroundStyle(isSelected ? Tokens.text1 : Tokens.text3)
            .lineLimit(1)
    }

    private func optionLabel<Option: RawRepresentable>(_ option: Option) -> String
    where Option.RawValue == String {
        if let pressure = option as? ForceClickPressure {
            return pressure.label
        }
        if let sensitivity = option as? HoverSensitivity {
            return sensitivity.label
        }
        return ""
    }

    private var forceClickPressurePosition: Binding<Double> {
        Binding(
            get: {
                Double(ForceClickPressure.allCases.firstIndex(of: model.forceClickPressure) ?? 2)
            },
            set: { position in
                let index = min(max(Int(position.rounded()), 0), ForceClickPressure.allCases.count - 1)
                // The gate (hold the rung while macOS's own lookup is armed) lives
                // on the model, because the dialog it raises does too.
                model.selectForceClickPressure(ForceClickPressure.allCases[index])
            }
        )
    }

    /// How readily the resting notch unfurls when the pointer reaches it. The
    /// four ordered policies map directly to a native, tick-mark-only NSSlider:
    /// Click, Low, Balanced, and Instant.
    private var hoverSensitivityRow: some View {
        let controlWidth: CGFloat = 190
        return settingRow(label: L("general.hoverSensitivity"),
                          info: L("general.hoverSensitivity.hint"),
                          aligned: true,
                          verticalAlignment: .sliderTrack) {
            VStack(spacing: 1) {
                NativeDetentSlider(value: hoverSensitivityPosition,
                                   ticks: HoverSensitivity.allCases.count)
                    .frame(width: controlWidth, height: Self.sliderHeight)
                    .accessibilityLabel(L("general.hoverSensitivity"))

                tickLabelRow(HoverSensitivity.allCases,
                             selected: hoverSensitivity,
                             width: controlWidth)
            }
            .alignmentGuide(.sliderTrack) { _ in Self.sliderHeight / 2 }
        }
    }

    private var hoverSensitivityPosition: Binding<Double> {
        Binding(
            get: {
                Double(HoverSensitivity.allCases.firstIndex(of: hoverSensitivity)
                       ?? HoverSensitivity.allCases.firstIndex(of: .balanced) ?? 0)
            },
            set: { position in
                let index = min(max(Int(position.rounded()), 0), HoverSensitivity.allCases.count - 1)
                selectHoverSensitivity(HoverSensitivity.allCases[index])
            }
        )
    }

    private func selectHoverSensitivity(_ newValue: HoverSensitivity) {
        guard newValue != hoverSensitivity else { return }
        hoverSensitivity = newValue
        // Through the model, not straight to `UserDefaults`: the island renders
        // the click level's flex off an observable mirror, which has to move too.
        model.applyHoverSensitivity(newValue)
    }

    /// Register or unregister the login item, keeping the toggle in sync with the
    /// OS. On success `launchAtLogin` already matches; on failure we snap it back
    /// to the real status so the switch never lies about what the system will do.
    private func selectLaunchAtLogin(_ newValue: Bool) {
        launchAtLogin = newValue
        do {
            try LaunchAtLogin.setEnabled(newValue)
        } catch {
            // The OS refused (e.g. the item is disabled at the system level) —
            // fall back to the true status rather than leave a misleading switch.
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    /// The interface language. `System` follows the Mac; the explicit picks
    /// (English / 简体中文 / 繁體中文 / 日本語 / 한국어) each named in their own
    /// script. Switching
    /// republishes `Localization.shared`, so the whole app — this panel included —
    /// re-renders in the new language at once, no relaunch.
    private var appLanguageRow: some View {
        settingRow(label: L("general.appLanguage")) {
            GlassMenu(title: appLanguage.label,
                      items: AppLanguage.allCases.map { lang in
                GlassMenuItem(title: lang.label, selected: lang == appLanguage) {
                    selectAppLanguage(lang)
                }
            })
        }
    }

    private func selectAppLanguage(_ newValue: AppLanguage) {
        guard newValue != appLanguage else { return }
        appLanguage = newValue
        // Drives the live switch: republishing `language` re-renders every view
        // reading `L(_:)` (and rebuilds the panel subtree via `.id(loc.language)`).
        Localization.shared.language = newValue
    }

    // MARK: - Copy sensing

    /// Copy sensing: whether the *closed* notch watches ⌘C and offers to file a
    /// copied note/reminder (press ⌘C again to confirm), and which classifier
    /// reads the copy when it does.
    ///
    /// One menu, three states — off, on-device, advanced — rather than a switch
    /// with a second switch nested under it. The engine is not a separate
    /// feature to turn on; it is which grade of the same feature is running, and
    /// a nested toggle also left the pane a row taller whenever sensing was on.
    /// Advanced is listed for every account and disabled for one the gateway
    /// would refuse; the pick is stored either way, so adding balance restores
    /// it.
    private var copySenseRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // `settingRow`'s label half, rebuilt here because its ⓘ takes a
            // string and this one opens a grid.
            HStack(spacing: 3) {
                Text(L("general.copySense"))
                    .font(.sf(Tokens.TypeSize.form, weight: .regular))
                    .foregroundStyle(Tokens.text2)
                    .lineLimit(1)
                    .fixedSize()
                if showsRefreshedTag {
                    RefreshedBadge()
                        .padding(.leading, 3)
                }
                SettingInfoPopover { copySenseComparisonTable }
            }
            .frame(minWidth: 64, alignment: .leading)
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: LabelColumnWidthKey.self, value: g.size.width)
                }
            )
            .modifier(LabelColumnFloor(aligned: true))
            // Opening the menu marks the tag read, but does NOT take it off
            // the row: something disappearing under the cursor at the moment of
            // the click reads as a glitch, and the tag is still the label for
            // what is on screen. It is gone the next time Settings is opened.
            Spacer(minLength: 0)
            GlassMenu(title: copySenseModeLabel, items: copySenseMenuItems) {
                SettingsNewMarks.copySenseSeen = true
            }
        }
    }

    /// The three states as menu rows.
    private var copySenseMenuItems: [GlassMenuItem] {
        [
            GlassMenuItem(title: L("senseMode.off"), selected: copySenseMode == nil) {
                selectCopySenseMode(nil)
            },
            GlassMenuItem(title: CopySenseEngine.onDevice.label,
                           selected: copySenseMode == .onDevice) {
                selectCopySenseMode(.onDevice)
            },
            GlassMenuItem(title: CopySenseEngine.jev.label,
                           selected: copySenseMode == .jev) {
                selectCopySenseMode(.jev)
            },
        ]
    }

    /// What the menu reads right now: nil is off, otherwise the engine that
    /// would actually run.
    private var copySenseMode: CopySenseEngine? {
        model.copySenseEnabled ? effectiveCopySenseEngine : nil
    }

    private var copySenseModeLabel: String {
        copySenseMode?.label ?? L("senseMode.off")
    }

    /// Picking an engine turns the feature on as well — the menu's three states
    /// are one decision, so choosing "Advanced" from off cannot leave sensing
    /// off. Off keeps the stored engine untouched, so switching back on returns
    /// to the grade that was picked.
    private func selectCopySenseMode(_ newValue: CopySenseEngine?) {
        guard newValue != copySenseMode else { return }
        Haptics.levelChange()
        guard let engine = newValue else {
            model.copySenseEnabled = false
            return
        }
        selectCopySenseEngine(engine)
        if !model.copySenseEnabled { model.copySenseEnabled = true }
    }

    /// The two engines side by side. Every line the answer is yes or no is a
    /// check or a cross, so the difference reads at a glance instead of being
    /// assembled out of two paragraphs; the facts that are not yes/no — where
    /// Jev runs and how credentials are dropped — sit under the grid in one
    /// card. The table hangs off the row’s ⓘ, like every other note this pane
    /// keeps out of the way.
    private var copySenseComparisonTable: some View {
        CopySenseNoteUnderGrid(spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    // The row column's own head: what the two engines are being
                    // compared ON, so the leftmost column is not an unlabelled
                    // list of phrases.
                    Text(L("senseEngine.table.head"))
                        .settingsCaption()
                        .fixedSize()
                    // `fixedSize`, or the flexible mark cells below take the
                    // leftover width and the headers truncate to "ON-DE…".
                    Text(CopySenseEngine.onDevice.label)
                        .settingsCaption(comparisonTint(.onDevice))
                        .fixedSize()
                        .gridColumnAlignment(.center)
                    Text(CopySenseEngine.jev.label)
                        .settingsCaption(comparisonTint(.jev))
                        .fixedSize()
                        .gridColumnAlignment(.center)
                }
                ForEach(Self.copySenseComparisonRows) { row in
                    GridRow {
                        Text(L(row.label))
                            .font(.sf(Tokens.TypeSize.meta))
                            .foregroundStyle(Tokens.text2)
                            .fixedSize()
                        comparisonMark(row.local, engine: .onDevice)
                        comparisonMark(row.jev, engine: .jev)
                    }
                }
            }
            CopySenseNoteCard()
        }
    }

    /// Lays the notes under the comparison grid at the grid's own width: a
    /// sentence that still fits stays on one line; only overflow wraps.
    private struct CopySenseNoteUnderGrid: Layout {
        var spacing: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard subviews.count == 2 else { return .zero }
            let grid = subviews[0].sizeThatFits(.unspecified)
            let notes = subviews[1].sizeThatFits(.init(width: grid.width, height: nil))
            return CGSize(width: grid.width, height: grid.height + spacing + notes.height)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            guard subviews.count == 2 else { return }
            let grid = subviews[0].sizeThatFits(.unspecified)
            subviews[0].place(at: bounds.origin, proposal: .init(grid))
            let notes = subviews[1].sizeThatFits(.init(width: grid.width, height: nil))
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + grid.height + spacing),
                proposal: .init(width: grid.width, height: notes.height)
            )
        }
    }

    /// The prose under the comparison grid, as one card instead of three loose
    /// paragraphs: a heading, and the facts the grid cannot answer with a check
    /// or a cross.
    private struct CopySenseNoteCard: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                // The same caption the grid's own heads wear, so the card
                // reads as a section of this popover rather than a title on top
                // of one.
                Text(L("senseEngine.note.title"))
                    .settingsCaption(Tokens.text3)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("senseEngine.table.note.cloud"))
                    // The credential line reads at the card's own strength, not
                    // its footnote ink: it is the one paragraph here someone
                    // needs to have read before turning any of this on.
                    Text(L("senseEngine.table.note.secrets"))
                        .foregroundStyle(Tokens.text2)
                }
                .font(.sf(Tokens.TypeSize.meta))
                .foregroundStyle(Tokens.text4)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .recessedSurface(in: RoundedRectangle.menu, lit: false)
        }
    }

    /// One comparison line: a capability, and whether each engine has it.
    private struct CopySenseComparisonRow: Identifiable {
        let label: String
        let local: Bool
        let jev: Bool
        var id: String { label }
    }

    private static let copySenseComparisonRows: [CopySenseComparisonRow] = [
        .init(label: "senseEngine.table.notes", local: true, jev: true),
        .init(label: "senseEngine.table.tasks", local: false, jev: true),
        .init(label: "senseEngine.table.questions", local: false, jev: true),
        .init(label: "senseEngine.table.details", local: false, jev: true),
    ]

    /// The mark in one cell. Jev's column is ink and the on-device column is
    /// reference — fixed, not following the current pick: the table is read to
    /// decide whether Jev is worth it, so the column being weighed is the one
    /// that has to be legible, whichever one happens to be running. A cross
    /// never competes with a check for attention.
    private func comparisonMark(_ yes: Bool, engine: CopySenseEngine) -> some View {
        let active = engine == .jev
        return Image(icon: yes ? "checkmark" : "xmark")
            .font(.sf(Tokens.TypeSize.label, weight: .regular))
            .foregroundStyle(yes ? (active ? Tokens.text1 : Tokens.text3)
                                 : Tokens.text4.opacity(0.7))
    }

    /// Same fixed emphasis as the marks below it: Jev's head at full strength,
    /// the other as reference.
    private func comparisonTint(_ engine: CopySenseEngine) -> Color {
        engine == .jev ? Tokens.text2 : Tokens.text4
    }

    /// The engine that would actually run: an account that cannot use Jev reads
    /// on-device, whatever the stored pick says.
    private var effectiveCopySenseEngine: CopySenseEngine {
        nono.canUseRemoteSense ? copySenseEngine : .onDevice
    }

    private func selectCopySenseEngine(_ newValue: CopySenseEngine) {
        guard newValue != copySenseEngine else { return }
        copySenseEngine = newValue
        CopySenseEngine.current = newValue
    }

    // MARK: - Shortcuts

    /// One first-class settings category for every keyboard control. Product
    /// actions are editable in place; text-field conventions remain read-only so
    /// Return, arrows, paste and `/` continue to behave predictably.
    ///
    /// Chords that do exactly what every Mac app does with them — ⌘, for
    /// Settings, ⌘W to close a window, ⎋ to back out — are deliberately left
    /// out. Nobody comes to a reference for those, and they dilute the ones
    /// worth reading. A row earns its place by teaching something the system
    /// convention wouldn't.
    private var shortcutsSection: some View {
        // Groups get more air between them than the rows inside one do. A row
        // carries 7pt of padding on each side, so rows sit 14pt apart; at 18pt
        // the reference blocks ran into each other. 24 keeps each group reading
        // as one block, in step with the gap the other panes' headings take.
        VStack(alignment: .leading, spacing: 24) {
            promptShortcutsGroup
            ForEach(Array(AppShortcutReference.groups(
                summonHotKey: summonHotKey,
                screenshotHotKey: screenshotHotKey,
                shortcuts: appShortcuts
            ).enumerated()),
                    id: \.offset) { index, group in
                if index == 0 {
                    // The first group holds the screenshot shortcut; where its
                    // capture lands sits under it.
                    VStack(alignment: .leading, spacing: 14) {
                        shortcutGroup(group.title, group.entries)
                        screenshotDestinationRow
                            .searchTarget("screenshot.destination", active: highlightedSearchKey)
                    }
                } else {
                    shortcutGroup(group.title, group.entries)
                }
            }
        }
        // No top runway: this pane starts flush with the sidebar's first item,
        // like every other one. The top taper only exists once the pane is
        // actually scrolled (see `paneContent`), so resting rows are never dimmed
        // and no pane has to buy its way out of the gradient with empty space.
        .padding(.bottom, 18)
        // One monitor serves every row. Switching chips changes only the target;
        // leaving the pane dismantles the monitor automatically.
        .background(HotKeyRecorder(active: recordingShortcut != nil,
                                   onCapture: captureShortcut,
                                   onDoubleModifier: captureDoubleModifier,
                                   onCancel: { recordingShortcut = nil }))
        // Leaving the pane ends recording outright: an armed target left in
        // `@State` after the monitor is dismantled would silently re-arm the old
        // row on return, and the next chord would land on it.
        .onDisappear {
            recordingShortcut = nil
            presentedPromptShortcutID = nil
            promptTemplatePickerOpen = false
            hoveredPromptTemplateID = nil
            promptTemplateCoverflowHovering = false
            promptTemplateCoverflowDragOrigin = nil
            promptTemplateCoverflowTapLocked = false
            hoveredPromptShortcutID = nil
            dropBlankPromptShortcuts()
        }
        // Chat can rebind any of these too (`manage_app_settings`). Re-read the
        // stores when it does, so the pane never shows a binding that is no
        // longer the one the app is registering.
        .onReceive(NotificationCenter.default.publisher(for: .summonHotKeyChanged)) { _ in
            summonHotKey = .current
            cardHotKey = .card
            screenshotHotKey = .screenshot
        }
        .onReceive(NotificationCenter.default.publisher(for: .appShortcutsChanged)) { _ in
            appShortcuts = AppShortcutStore.current
        }
        .onReceive(NotificationCenter.default.publisher(for: .promptShortcutsChanged)) { _ in
            promptShortcuts = PromptShortcutStore.current
        }
    }

    /// Prompt shortcuts stay compact in the list. Selecting one presents its
    /// editor in the same centered dialog layer used by destructive confirmation;
    /// the list itself never unfolds or moves the groups below it.
    private var promptShortcutsGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The title keeps the text position of every other group's title, and
            // the add chip hangs in an OVERLAY rather than in the row: a 24pt
            // button inside the HStack would make this one header 24pt tall and
            // push its text ~5pt lower than the group titles below it.
            //
            // The header still RESERVES the chip's full height, with the text
            // pinned to the top of that box. This group is the first thing in the
            // Shortcuts pane, so its title sits at y=0 of the scroll content — a
            // 24pt chip centred on a ~12pt line would overflow ~6pt above the
            // scroll view's edge and clip the chip's upper arc.
            Text(L("shortcuts.promptAction"))
                .settingsHeading()
                .frame(maxWidth: .infinity, minHeight: Self.promptAddChipSize,
                       alignment: .topLeading)
                .overlay(alignment: .trailing) {
                    Button {
                        openPromptTemplatePicker()
                    } label: {
                        Image(icon: "plus")
                            .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                            .foregroundStyle(Tokens.text2)
                            .frame(width: Self.promptAddChipSize,
                                   height: Self.promptAddChipSize)
                    }
                    .buttonStyle(ShortcutChipStyle())
                    .notchTooltip(L("shortcuts.promptAction.add"))
                }

            // The header box already carries ~9pt of slack below the title text
            // (the chip's height minus the line's); these top pads add the rest of
            // the clearance, so the title reads as a section header rather than as
            // a label stuck to the first row.
            Group {
                if promptShortcuts.isEmpty {
                    Text(L("shortcuts.promptAction.empty"))
                        .settingsDescription()
                        .padding(.horizontal, 2)
                }
                // One row of small cards running right, scrolled rather than
                // wrapped: the group keeps a fixed height however many
                // shortcuts there are, so adding a tenth one never pushes the
                // reference groups below it off the page. It also carries the
                // library's leftovers, so an install with nothing saved yet is
                // offered the same one-click adds instead of an empty row.
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(promptShortcuts) { binding in
                            promptShortcutCardChip(binding)
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                        // The library's leftovers follow the saved cards, so
                        // the ready-made actions sit where the shortcuts
                        // themselves are instead of only behind the picker.
                        if !availablePromptTemplates.isEmpty {
                            ForEach(Array(availablePromptTemplates.enumerated()),
                                    id: \.element.id) { index, template in
                                promptTemplateGhostChip(template)
                                    .padding(.leading, index == 0 && !promptShortcuts.isEmpty
                                             ? 6 : 0)
                                    .transition(.opacity)
                            }
                        }
                    }
                    // The glow bleeds a couple of points past each card.
                    .padding(.horizontal, 3)
                    .padding(.vertical, 3)
                    // Give the last card a runway past the shared edge fade,
                    // so it can scroll fully into view instead of remaining
                    // dimmed when the list reaches its end.
                    .padding(.trailing, 24)
                    .onScrollOffsetChange(axis: .horizontal) { offset in
                        let off = offset > 0.5
                        if off != promptShortcutRailScrolled {
                            promptShortcutRailScrolled = off
                        }
                    }
                }
                .scrollIndicators(.never)
                // Match the panel's other overflowing lists: content
                // dissolves into BOTH boundaries instead of being sliced by
                // the scroll viewport — a card leaving to the left thinned out
                // the same way one arriving from the right does. The leading
                // taper is gated on the rail actually being scrolled, so at
                // rest the first card stays crisp against the section's edge.
                .scrollEdgeFade(leading: promptShortcutRailScrolled, trailing: true,
                                leadingFade: 24, trailingFade: 24)
                .padding(.horizontal, -3)
            }
            .padding(.top, 10)
        }
    }

    private struct PromptTemplateGroup: Identifiable {
        let category: String
        let templates: [RemoteModelManifest.PromptTemplate]
        var id: String { category }
    }

    /// A template the user already saved is not offered a second time — the
    /// picker is what's left to add, not a catalogue of everything that exists.
    /// Identity is the instruction itself: a saved shortcut persists its prompt,
    /// not the id of the template it came from, and the prompt is what would
    /// actually be duplicated.
    private var availablePromptTemplates: [RemoteModelManifest.PromptTemplate] {
        let added = Set(promptShortcuts
            .map { $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        guard !added.isEmpty else { return promptTemplates }
        return promptTemplates.filter {
            !added.contains($0.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Category order follows the manifest rather than an app-side enum, so the
    /// remotely maintained library can add or rearrange a group without an app
    /// release. Cover Flow is scoped to the selected group instead of flattening
    /// the library and throwing that organization away.
    private var promptTemplateGroups: [PromptTemplateGroup] {
        var order: [String] = []
        var grouped: [String: [RemoteModelManifest.PromptTemplate]] = [:]
        for template in availablePromptTemplates {
            if grouped[template.category] == nil { order.append(template.category) }
            grouped[template.category, default: []].append(template)
        }
        return order.map { PromptTemplateGroup(category: $0,
                                                templates: grouped[$0] ?? []) }
    }

    private var visiblePromptTemplates: [RemoteModelManifest.PromptTemplate] {
        promptTemplateGroups.first(where: { $0.category == selectedPromptTemplateCategory })?
            .templates ?? promptTemplateGroups.first?.templates ?? []
    }

    /// The template the picker is currently showing in full, resolved from the
    /// live library rather than held as a copy, so a manifest refresh under an
    /// open detail page updates it instead of stranding stale text.
    private var promptTemplateDetail: RemoteModelManifest.PromptTemplate? {
        guard let id = promptTemplateDetailID else { return nil }
        return promptTemplates.first { $0.id == id }
    }

    private var promptTemplatePicker: some View {
        let detail = promptTemplateDetail
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if detail != nil {
                    Button {
                        closePromptTemplateDetail()
                    } label: {
                        Image(icon: "chevron.left")
                            .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                            .foregroundStyle(Tokens.text2)
                            .frame(width: Tokens.Control.inline, height: Tokens.Control.inline)
                    }
                    .buttonStyle(PromptTemplateChipStyle(shape: Circle()))
                    .accessibilityLabel(L("shortcuts.promptAction.templates.back"))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(detail?.name ?? L("shortcuts.promptAction.templates.title"))
                        .font(.sf(Tokens.TypeSize.prompt, weight: .regular))
                        .foregroundStyle(Tokens.text1)
                        .tracking(-0.3)
                        .lineLimit(1)
                    Text(detail?.description ?? L("shortcuts.promptAction.templates.subtitle"))
                        .font(.sf(Tokens.TypeSize.meta))
                        .foregroundStyle(Tokens.text4)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    closePromptTemplatePicker()
                } label: {
                    Image(icon: "xmark")
                        .font(.sf(Tokens.TypeSize.badge, weight: .regular))
                        .foregroundStyle(Tokens.text2)
                        .frame(width: Tokens.Control.inline, height: Tokens.Control.inline)
                }
                .buttonStyle(PromptTemplateChipStyle(shape: Circle()))
                .accessibilityLabel(L("detached.close"))
            }
            .padding(.bottom, 14)

            if let detail {
                promptTemplateDetailBody(detail)
            } else {
                promptTemplateCategoryTabs
                    .padding(.bottom, 8)

                promptTemplateCoverflow

                Button {
                    addBlankPromptShortcut()
                } label: {
                    Text(L("shortcuts.promptAction.templates.custom"))
                        .font(.sf(Tokens.TypeSize.label, weight: .regular))
                        .foregroundStyle(Tokens.text2)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(PromptTemplateChipStyle(shape: Capsule(style: .continuous)))
                .padding(.top, 14)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    /// A template's own page: the instruction it will actually run, in full,
    /// over the group's colour, with adding it as the page's one action.
    private func promptTemplateDetailBody(
        _ template: RemoteModelManifest.PromptTemplate
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(promptTemplateCategoryTitle(template.category))
                .settingsCaption(Tokens.text3)
                .padding(.bottom, 8)

            ScrollView {
                Text(template.prompt)
                    .font(.sf(Tokens.TypeSize.label))
                    .foregroundStyle(Tokens.text1)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .frame(height: 128)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .recessedSurface(in: RoundedRectangle.menu,
                             lit: false)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button {
                    addPromptShortcut(from: template)
                    closePromptTemplateDetail()
                } label: {
                    Text(L("shortcuts.promptAction.templates.detail.add"))
                        .font(.sf(Tokens.TypeSize.label, weight: .regular))
                        .foregroundStyle(Tokens.text1)
                        .padding(.horizontal, 20)
                        .frame(minHeight: 32)
                }
                .buttonStyle(PromptCardActionStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
    }

    private var promptTemplateCategoryTabs: some View {
        HStack(spacing: TabChip.gap) {
            ForEach(promptTemplateGroups) { group in
                // A tab IS the heading of the rail below it, so it takes the
                // panel's small-caps caption register rather than a second size
                // of body text — the same font as the group headings elsewhere
                // in Settings.
                TabChip(
                    title: promptTemplateCategoryTitle(group.category),
                    active: group.category == selectedPromptTemplateCategory,
                    typeface: .caption
                ) {
                    selectPromptTemplateCategory(group.category)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: selectedPromptTemplateCategory)
    }

    /// The picker's chips in the island's own Liquid Glass rather than the
    /// Settings pane's flat white wash (`ShortcutChipStyle`). This dialog floats
    /// over blurred content, where a painted-on capsule reads as a sticker laid
    /// on the glass; a real glass chip refracts what is behind it like every
    /// other control on the island.
    private struct PromptTemplateChipStyle<S: InsettableShape>: ButtonStyle {
        var shape: S
        var active: Bool = false
        /// Washes the chip in a hue instead of plain white — see the tabs.
        var tint: Color? = nil

        @State private var hovering = false

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .exemptsDoubleClickPin(pressed: configuration.isPressed)
                .glassCapsule(in: shape,
                              brighter: active || hovering,
                              tint: tint,
                              rim: active ? 1 : (hovering ? 0.85 : 0.5))
                .contentShape(shape)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(configuration.isPressed ? 0.82 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        }
    }

    private static let promptTemplateCoverflowCardSize: CGFloat = 148
    private static let promptTemplateCoverflowHeight: CGFloat = 160
    private static let promptTemplateCoverflowSpacing: CGFloat = -87
    private static let promptTemplateCoverflowRotation: Double = 20
    private static let promptTemplateCoverflowNearScale: CGFloat = 0.88
    private static let promptTemplateCoverflowFarScale: CGFloat = 0.72
    private static let promptTemplateCoverflowPerspective: CGFloat = 1 / 500
    private static let promptTemplateCoverflowSpring =
        Animation.interpolatingSpring(mass: 1, stiffness: 180, damping: 22,
                                      initialVelocity: 0)

    private var promptTemplateCoverflowVirtualIndex: Int {
        Int(promptTemplateCoverflowOffset.rounded())
    }

    private var promptTemplateCoverflowIndex: Int {
        guard !visiblePromptTemplates.isEmpty else { return 0 }
        return wrappedPromptTemplateIndex(promptTemplateCoverflowVirtualIndex)
    }

    /// The reference component's classic Cover Flow, scaled to this compact
    /// dialog: square cards, inward-turned side faces, symmetric depth order,
    /// direct dragging and tap-to-focus.
    private var promptTemplateCoverflow: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ZStack {
                    promptTemplateCoverflowHaze

                    if visiblePromptTemplates.isEmpty {
                        Text(L("shortcuts.promptAction.templates.allAdded"))
                            .font(.sf(Tokens.TypeSize.label))
                            .foregroundStyle(Tokens.text3)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 44)
                    }

                    ForEach(Array(visiblePromptTemplates.enumerated()), id: \.element.id) { index, template in
                        promptTemplateCoverflowCard(template, at: index)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .overlay(promptTemplateCoverflowSmoke)
                .contentShape(Rectangle())
                // A card owns a tap, while the rail owns horizontal movement.
                // Priority keeps the child tap recognizers from starving the
                // parent's mouse-drag gesture after its 4pt threshold is crossed.
                .highPriorityGesture(promptTemplateCoverflowDragGesture)
            }
            .frame(height: Self.promptTemplateCoverflowHeight)
        }
        .background(
            PromptTemplateCoverflowScrollMonitor(
                active: promptTemplateCoverflowHovering,
                onDelta: { delta in
                    promptTemplateCoverflowTapLocked = false
                    let next = promptTemplateCoverflowOffset - delta
                        / (Self.promptTemplateCoverflowCardSize * 0.65)
                    setPromptTemplateCoverflowOffset(next, haptic: true)
                },
                onEnd: {
                    snapPromptTemplateCoverflow(to: promptTemplateCoverflowVirtualIndex)
                },
                onStep: { direction in
                    snapPromptTemplateCoverflow(to: promptTemplateCoverflowVirtualIndex + direction)
                }
            )
        )
        .onHover { promptTemplateCoverflowHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("shortcuts.promptAction.templates.title"))
    }

    /// The focused group's hue, pooled into a soft light under the rail. The
    /// colour lives in the smoke rather than on a second painted surface, so the
    /// dialog takes on the category it is showing without gaining a panel.
    private var promptTemplateCoverflowHaze: some View {
        let light = PromptShortcutCardPalette.light(selectedPromptTemplateCategory)
        return Ellipse()
            .fill(RadialGradient(colors: [light.opacity(0.28), .clear],
                                 center: .center, startRadius: 0, endRadius: 130))
            .frame(width: 300, height: 140)
            .blur(radius: 30)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.3), value: selectedPromptTemplateCategory)
    }

    /// The far cards run out into smoke instead of stopping at a hard edge — the
    /// rail's own `scrollEdgeFade`, drawn over the cards rather than masking
    /// them, since a mask would flatten their 3D transforms.
    private var promptTemplateCoverflowSmoke: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.3), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 44)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, .black.opacity(0.3)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 44)
        }
        .allowsHitTesting(false)
    }

    private func promptTemplateCoverflowCard(
        _ template: RemoteModelManifest.PromptTemplate,
        at index: Int
    ) -> some View {
        let difference = promptTemplateCoverflowDifference(for: index)
        let distance = abs(difference)
        let direction: CGFloat = difference == 0 ? 0 : (difference > 0 ? 1 : -1)
        let rotationProgress = min(distance, 1)
        let easedRotation = 1 - pow(1 - rotationProgress, 3)
        let rotation = -Double(direction * easedRotation) * Self.promptTemplateCoverflowRotation
        let scale: CGFloat
        if distance < 1 {
            scale = 1 - distance * (1 - Self.promptTemplateCoverflowNearScale)
        } else if distance < 2 {
            scale = Self.promptTemplateCoverflowNearScale
                - (distance - 1) * (Self.promptTemplateCoverflowNearScale
                    - Self.promptTemplateCoverflowFarScale)
        } else {
            scale = Self.promptTemplateCoverflowFarScale
        }

        let nearSpacing = max(20, Self.promptTemplateCoverflowCardSize
                              + Self.promptTemplateCoverflowSpacing)
        let farSpacing = nearSpacing * 0.56
        let translation = direction * (distance <= 1
            ? distance * nearSpacing
            : nearSpacing + (distance - 1) * farSpacing)
        let opacity: Double = distance <= 4 ? 1 : max(0, 1 - Double(distance - 4))
        let active = promptTemplateCoverflowIndex == index
        let hovered = hoveredPromptTemplateID == template.id
        let shape = RoundedRectangle.modal
        let textOpacity = active ? 1 : Double(max(0.16, 0.52 - distance * 0.14))

        return ZStack {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)

                // 16.5 over 11 — a 1.5x step; a closer pair reads as one grey
                // block of text. The name is the card's headline and is set like
                // one: bigger, tighter, and carrying the ink, over a gloss that
                // stays deliberately quiet.
                Text(template.name)
                    .font(.sf(Tokens.TypeSize.prompt, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.97))
                    .tracking(-0.35)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(template.description)
                    .font(.sf(Tokens.TypeSize.meta))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineSpacing(2)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                Spacer(minLength: 0)
            }
            .padding(15)
            .opacity(textOpacity)
        }
        .frame(width: Self.promptTemplateCoverflowCardSize,
               height: Self.promptTemplateCoverflowCardSize,
               alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) {
            if active {
                Button {
                    addPromptShortcut(from: template)
                } label: {
                    Image(icon: "plus")
                        .font(.sf(Tokens.TypeSize.form, weight: .regular))
                        .foregroundStyle(Tokens.text1)
                        .frame(width: Tokens.Control.rail, height: Tokens.Control.rail)
                }
                .buttonStyle(PromptTemplateChipStyle(shape: Circle(), active: true))
                .accessibilityLabel(L("shortcuts.promptAction.add"))
                .padding(10)
            }
        }
        .background(
            PromptShortcutCardSurface(stableKey: template.category,
                                      hovering: hovered,
                                      gradientContrast: 1.9,
                                      liveGlass: false,
                                      shape: shape)
        )
        .contentShape(shape)
        .shadow(color: .black.opacity(active ? 0.3 : 0.14), radius: 14, y: 8)
        .scaleEffect(scale)
        .rotation3DEffect(.degrees(rotation), axis: (x: 0, y: 1, z: 0),
                          perspective: Self.promptTemplateCoverflowPerspective)
        .offset(x: translation)
        .blur(radius: active ? 0 : min(Double(distance) * 0.55, 1.4))
        .opacity(opacity)
        .zIndex(active ? 999 : -Double(distance))
        .allowsHitTesting(distance <= 4)
        .onTapGesture { promptTemplateCoverflowTapped(template, at: index) }
        .exemptsDoubleClickPin()
        .onHover { hovering in
            withAnimation(.easeOut(duration: Tokens.hoverFade)) {
                if hovering {
                    hoveredPromptTemplateID = template.id
                } else if hoveredPromptTemplateID == template.id {
                    hoveredPromptTemplateID = nil
                }
            }
        }
        .accessibilityLabel("\(template.name). \(template.description)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var promptTemplateCoverflowDragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard !visiblePromptTemplates.isEmpty else { return }
                if promptTemplateCoverflowDragOrigin == nil {
                    promptTemplateCoverflowDragOrigin = promptTemplateCoverflowOffset
                    promptTemplateCoverflowTapLocked = false
                }
                let origin = promptTemplateCoverflowDragOrigin ?? promptTemplateCoverflowOffset
                let next = origin - value.translation.width
                    / (Self.promptTemplateCoverflowCardSize * 0.65)
                setPromptTemplateCoverflowOffset(next, haptic: true)
            }
            .onEnded { value in
                promptTemplateCoverflowDragOrigin = nil
                let velocity = value.velocity.width
                let target: Int
                if abs(velocity) > 300 {
                    target = Int((promptTemplateCoverflowOffset - velocity / 800).rounded())
                } else {
                    target = promptTemplateCoverflowVirtualIndex
                }
                snapPromptTemplateCoverflow(to: target)
            }
    }

    private func promptTemplateCoverflowTapped(
        _ template: RemoteModelManifest.PromptTemplate,
        at index: Int
    ) {
        guard promptTemplateCoverflowIndex != index else {
            // The focused card is already legible; a click on it asks to read the
            // whole thing, not to save it unseen. Adding stays on the card's `+`.
            //
            // The lock guards only THIS branch: a card that just travelled to the
            // centre slides under a pointer that is still clicking, and the second
            // click of a double belongs to the rail, not to the detail page.
            // Turning a card away, by contrast, is never blocked — gating it made
            // rapid clicks through the rail stall for the length of the window.
            guard !promptTemplateCoverflowTapLocked else { return }
            openPromptTemplateDetail(template)
            return
        }
        let target = Int((promptTemplateCoverflowOffset
                          + promptTemplateCoverflowDifference(for: index)).rounded())
        snapPromptTemplateCoverflow(to: target, lockTaps: true)
    }

    private func openPromptTemplateDetail(_ template: RemoteModelManifest.PromptTemplate) {
        hoveredPromptTemplateID = nil
        promptTemplateCoverflowHovering = false
        withAnimation(.easeOut(duration: Tokens.hoverFade)) {
            promptTemplateDetailID = template.id
        }
    }

    private func closePromptTemplateDetail() {
        withAnimation(.easeOut(duration: Tokens.hoverFade)) {
            promptTemplateDetailID = nil
        }
    }

    private func wrappedPromptTemplateIndex(_ virtualIndex: Int) -> Int {
        guard !visiblePromptTemplates.isEmpty else { return 0 }
        let count = visiblePromptTemplates.count
        return ((virtualIndex % count) + count) % count
    }

    /// Each real template is rendered exactly once. Infinite cycling comes from
    /// choosing that card's nearest equivalent position around the current
    /// virtual page, never from duplicating template views on both sides.
    private func promptTemplateCoverflowDifference(for index: Int) -> CGFloat {
        guard !visiblePromptTemplates.isEmpty else { return 0 }
        let count = CGFloat(visiblePromptTemplates.count)
        let wrappedOffset = promptTemplateCoverflowOffset
            .truncatingRemainder(dividingBy: count)
        var difference = CGFloat(index) - wrappedOffset
        let half = count / 2
        while difference > half { difference -= count }
        while difference < -half { difference += count }
        return difference
    }

    private func setPromptTemplateCoverflowOffset(_ value: CGFloat, haptic: Bool) {
        guard !visiblePromptTemplates.isEmpty else {
            promptTemplateCoverflowOffset = 0
            return
        }
        let prior = promptTemplateCoverflowIndex
        promptTemplateCoverflowOffset = value
        if haptic, promptTemplateCoverflowIndex != prior {
            Haptics.alignment()
        }
    }

    private func snapPromptTemplateCoverflow(to index: Int, lockTaps: Bool = false) {
        guard !visiblePromptTemplates.isEmpty else { return }
        promptTemplateCoverflowTapLocked = lockTaps
        withAnimation(Self.promptTemplateCoverflowSpring) {
            setPromptTemplateCoverflowOffset(CGFloat(index), haptic: true)
        }
        guard lockTaps else { return }
        promptTemplateCoverflowTapUnlockToken += 1
        let token = promptTemplateCoverflowTapUnlockToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            guard token == promptTemplateCoverflowTapUnlockToken else { return }
            promptTemplateCoverflowTapLocked = false
        }
    }

    private func promptTemplateCategoryTitle(_ category: String) -> String {
        switch category {
        case "understand": return L("shortcuts.promptAction.templates.category.understand")
        case "rewrite": return L("shortcuts.promptAction.templates.category.rewrite")
        case "respond": return L("shortcuts.promptAction.templates.category.respond")
        case "translation": return L("shortcuts.promptAction.templates.category.translation")
        default: return category.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    private func selectPromptTemplateCategory(_ category: String) {
        guard category != selectedPromptTemplateCategory else { return }
        selectedPromptTemplateCategory = category
        promptTemplateCoverflowTapLocked = false
        promptTemplateCoverflowDragOrigin = nil
        withAnimation(Self.promptTemplateCoverflowSpring) {
            promptTemplateCoverflowOffset = 0
        }
        Haptics.alignment()
    }

    private func openPromptTemplatePicker() {
        promptTemplates = RemoteModelManifest.promptTemplates
        selectedPromptTemplateCategory = promptTemplateGroups.first?.category ?? ""
        promptTemplateCoverflowOffset = 0
        promptTemplateCoverflowHovering = false
        promptTemplateCoverflowDragOrigin = nil
        promptTemplateCoverflowTapLocked = false
        promptTemplateDetailID = nil
        promptTemplatePickerOpen = true
        Task {
            await RemoteModelManifest.refreshIfDue()
            guard promptTemplatePickerOpen else { return }
            promptTemplates = RemoteModelManifest.promptTemplates
            if !promptTemplateGroups.contains(where: {
                $0.category == selectedPromptTemplateCategory
            }) {
                selectedPromptTemplateCategory = promptTemplateGroups.first?.category ?? ""
            }
            setPromptTemplateCoverflowOffset(promptTemplateCoverflowOffset, haptic: false)
        }
    }

    private func closePromptTemplatePicker() {
        promptTemplatePickerOpen = false
        promptTemplateDetailID = nil
        hoveredPromptTemplateID = nil
        promptTemplateCoverflowHovering = false
        promptTemplateCoverflowDragOrigin = nil
        promptTemplateCoverflowTapLocked = false
    }

    /// A template's `+` saves it immediately and deliberately leaves this picker
    /// open, so several ready-made actions can be added in one pass. Editing the
    /// name, prompt, model, or chord remains available from the saved cards.
    private func addPromptShortcut(from template: RemoteModelManifest.PromptTemplate) {
        let shortcut = PromptShortcut(prompt: template.prompt, name: template.name,
                                      paletteKey: template.category)
        withAnimation(Tokens.stackSpring) {
            promptShortcuts.append(shortcut)
        }
        PromptShortcutStore.save(promptShortcuts)
        NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
        Haptics.confirm()

        // Added from the rail, there is no picker to re-seat.
        guard promptTemplatePickerOpen else { return }

        // The card it was added from leaves the rail immediately, so the picker's
        // position has to be re-seated: this category may now be empty (its tab is
        // gone with it), and the offset may point past the end of a shorter group.
        withAnimation(Self.promptTemplateCoverflowSpring) {
            if !promptTemplateGroups.contains(where: {
                $0.category == selectedPromptTemplateCategory
            }) {
                selectedPromptTemplateCategory = promptTemplateGroups.first?.category ?? ""
            }
            promptTemplateCoverflowOffset = CGFloat(promptTemplateCoverflowIndex)
        }
    }

    /// The picker's last action: a blank shortcut. The blank row is kept only
    /// in memory until the user actually edits a field.
    private func addBlankPromptShortcut() {
        let shortcut = PromptShortcut()
        withAnimation(Tokens.stackSpring) {
            promptShortcuts.append(shortcut)
        }
        closePromptTemplatePicker()
        DispatchQueue.main.async {
            presentedPromptShortcutID = shortcut.id
        }
    }

    /// A prompt is usually a real instruction, so give it room for several lines
    /// instead of treating it like another compact setting.
    private static let promptEditorHeight: CGFloat = 120

    /// The header's add chip — smaller than a row's chips, and the height the
    /// title row reserves so the pane's top edge never shaves it.
    private static let promptAddChipSize: CGFloat = Tokens.Control.inline

    /// One shortcut, as a small card: its AI name over its chord. The whole card
    /// is the control — clicking it opens the editor — and the pointer is answered
    /// by the card's own surface lighting up, no revealed affordance.
    ///
    /// Width is CAPPED, not free: the name is generated prose, and one long one
    /// would otherwise set the width for the whole flow.
    private func promptShortcutCardChip(_ binding: PromptShortcut) -> some View {
        let hovered = hoveredPromptShortcutID == binding.id
        let shape = RoundedRectangle.menu
        return Button {
            presentedPromptShortcutID = binding.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(promptShortcutName(binding)
                     ?? (binding.prompt.isEmpty
                         ? L("shortcuts.promptAction.placeholder")
                         : binding.prompt))
                    .font(.sf(Tokens.TypeSize.label, weight: .regular))
                    .foregroundStyle(binding.prompt.isEmpty ? Tokens.text4 : Tokens.text1)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let chord = binding.shortcut?.displayString {
                    HStack(spacing: 3) {
                        ForEach(Array(Self.keyCaps(chord).enumerated()), id: \.offset) { _, cap in
                            keyCap(cap)
                        }
                    }
                } else {
                    Text(L("shortcuts.promptAction.set"))
                        .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                        .foregroundStyle(Tokens.text4)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 22)
                        .overlay(
                            Capsule(style: .continuous).strokeBorder(
                                Tokens.ink.opacity(0.13),
                                style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                        )
                }
            }
            .frame(width: Self.promptCardWidth, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(PromptShortcutCardSurface(id: binding.id,
                                                 paletteKey: binding.paletteSeed,
                                                  hovering: hovered,
                                                  shape: shape))
            .contentShape(shape)
        }
        .buttonStyle(.plain).exemptsDoubleClickPin()
        .accessibilityLabel(L("shortcuts.promptAction.edit"))
        // The rail is ordered, scrolls, and has no drag handles: reordering is
        // one move — put this one first — and deleting doesn't need the card
        // opened.
        .contextMenu {
            if promptShortcuts.first?.id != binding.id {
                Button(L("shortcuts.promptAction.moveToFront")) {
                    movePromptShortcutToFront(binding.id)
                }
            }
            Button(L("shortcuts.promptAction.delete"), role: .destructive) {
                deletePromptShortcut(binding.id)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: Tokens.hoverFade)) {
                if hovering {
                    hoveredPromptShortcutID = binding.id
                } else if hoveredPromptShortcutID == binding.id {
                    hoveredPromptShortcutID = nil
                }
            }
        }
    }

    /// A ready-made action the user has not saved yet, sitting in the rail after
    /// their own cards. Drawn as a SLOT rather than a card — a faint wash and a
    /// dashed edge — so it never reads as something already set up, and adding it
    /// takes one click on the plus instead of opening the picker.
    private func promptTemplateGhostChip(
        _ template: RemoteModelManifest.PromptTemplate
    ) -> some View {
        let hovered = hoveredPromptTemplateGhostID == template.id
        let shape = RoundedRectangle.menu
        return Button {
            addPromptShortcut(from: template)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(template.name)
                    .font(.sf(Tokens.TypeSize.label, weight: .regular))
                    .foregroundStyle(hovered ? Tokens.text2 : Tokens.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(icon: "plus")
                    .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                    .foregroundStyle(hovered ? Tokens.text2 : Tokens.text4)
                    .padding(.horizontal, 7)
                    .frame(minWidth: 24, minHeight: 22)
                    .background(Capsule(style: .continuous).fill(Tokens.ink.opacity(hovered ? 0.08 : 0.03)))
                    .overlay(
                        Capsule(style: .continuous).strokeBorder(Tokens.ink.opacity(hovered ? 0.2 : 0.11),
                                               lineWidth: 0.5)
                    )
            }
            .frame(width: Self.promptCardWidth, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(shape.fill(Tokens.ink.opacity(hovered ? 0.05 : 0.028)))
            .overlay(
                shape.strokeBorder(Tokens.ink.opacity(hovered ? 0.24 : 0.13),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain).exemptsDoubleClickPin()
        .accessibilityLabel(L("shortcuts.promptAction.add"))
        .notchTooltip(L("shortcuts.promptAction.add"))
        .onHover { hovering in
            withAnimation(.easeOut(duration: Tokens.hoverFade)) {
                if hovering {
                    hoveredPromptTemplateGhostID = template.id
                } else if hoveredPromptTemplateGhostID == template.id {
                    hoveredPromptTemplateGhostID = nil
                }
            }
        }
    }

    /// Order is the rail's order, and it is what the Force Click menu and the
    /// composer read too — so this writes through the same store as every other
    /// edit rather than sorting a view-local copy.
    private func movePromptShortcutToFront(_ id: UUID) {
        guard let index = promptShortcuts.firstIndex(where: { $0.id == id }),
              index != 0 else { return }
        withAnimation(Tokens.stackSpring) {
            let moved = promptShortcuts.remove(at: index)
            promptShortcuts.insert(moved, at: 0)
        }
        PromptShortcutStore.save(promptShortcuts)
        NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
        Haptics.alignment()
    }

    /// The card's text column — two of them plus their gap fit the pane's width.
    private static let promptCardWidth: CGFloat = 118

    /// The row's AI name, when it has one worth showing beside the prompt.
    private func promptShortcutName(_ binding: PromptShortcut) -> String? {
        guard let name = binding.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              name.caseInsensitiveCompare(
                binding.prompt.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame
        else { return nil }
        return name
    }

    private func closePromptShortcutEditor(_ id: UUID) {
        if presentedPromptShortcutID == id { presentedPromptShortcutID = nil }
        if recordingShortcut == .prompt(id) { recordingShortcut = nil }
        promptModelPickerOpen = false
        model.isModelPickerOpen = modelPickerOpen
        dropBlankPromptShortcuts()
    }

    /// Forget the rows nothing was ever set on. Opening the editor is how a
    /// shortcut is created, so backing out of it — Done, the ✕, or the scrim —
    /// must not leave "Prompt for the selected text / Set" standing in the list
    /// forever. A row with a prompt OR a chord is never touched: half-finished is
    /// still something the user typed.
    private func dropBlankPromptShortcuts() {
        let blanks = promptShortcuts.filter(\.isBlank).map(\.id)
        guard !blanks.isEmpty else { return }
        for id in blanks {
            shortcutHints[.prompt(id)] = nil
            if recordingShortcut == .prompt(id) { recordingShortcut = nil }
            if presentedPromptShortcutID == id { presentedPromptShortcutID = nil }
        }
        withAnimation(Tokens.stackSpring) {
            promptShortcuts.removeAll(where: \.isBlank)
        }
        PromptShortcutStore.save(promptShortcuts)
        NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
    }

    /// The editor: the full-width prompt is the subject, with its three compact
    /// settings arranged as a plain-text toolbar on its bottom edge.
    private func promptShortcutCard(_ binding: PromptShortcut) -> some View {
        let target = EditableShortcut.prompt(binding.id)
        let forceClick = promptForceTouchBinding(for: binding.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // Read-only: the name is the AI's, not a field. As a TextField the
                // heading would look like the first thing to fill in — it isn't,
                // the prompt is.
                Text(promptShortcutName(binding)
                     ?? (binding.prompt.isEmpty
                         ? L("shortcuts.promptAction")
                         : binding.prompt))
                    .font(.sf(Tokens.TypeSize.form))
                    .foregroundStyle(Tokens.text1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Button {
                    closePromptShortcutEditor(binding.id)
                } label: {
                    Image(icon: "xmark")
                        .font(.sf(Tokens.TypeSize.badge, weight: .regular))
                        .foregroundStyle(Tokens.text3)
                        .frame(width: Tokens.Control.inline, height: Tokens.Control.inline)
                }
                .buttonStyle(ShortcutChipStyle(rest: 0.035, restStroke: 0.08))
                .accessibilityLabel(L("detached.close"))
            }
            .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if binding.prompt.isEmpty {
                        Text(L("shortcuts.promptAction.placeholder"))
                            .font(.sf(Tokens.TypeSize.label))
                            .foregroundStyle(Tokens.text4)
                            .lineLimit(1)
                            .padding(.top, 1)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: promptBinding(for: binding.id), axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(4, reservesSpace: true)
                        .font(.sf(Tokens.TypeSize.label))
                        .foregroundStyle(Tokens.text1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topLeading)

                HStack(spacing: 16) {
                    Button {
                        shortcutHints[target] = nil
                        recordingShortcut = recordingShortcut == target ? nil : target
                    } label: {
                        Text(recordingShortcut == target
                             ? L("general.shortcut.recording")
                             : (binding.shortcut?.displayString
                                ?? L("shortcuts.promptAction.set")))
                            .font(.sf(Tokens.TypeSize.meta))
                            .foregroundStyle(recordingShortcut == target
                                ? Tokens.text1 : Tokens.text3)
                    }
                    .buttonStyle(.plain).exemptsDoubleClickPin()
                    .notchTooltip(L("general.shortcut"))

                    promptModelPicker(for: binding.id)

                    Spacer(minLength: 8)

                    if ForceClickFeature.isEnabled {
                        Toggle(isOn: forceClick) {
                            Text(L("shortcuts.promptAction.forceTouch"))
                                .font(.sf(Tokens.TypeSize.meta))
                                .foregroundStyle(Tokens.text2)
                                .lineLimit(1)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(Tokens.switchTint)
                        .fixedSize()
                    }
                }
                .frame(height: 30)
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity)
            .frame(height: Self.promptEditorHeight, alignment: .topLeading)
            .recessedSurface(in: RoundedRectangle.inset, lit: false)
            .padding(.bottom, 6)

            if let hint = shortcutHints[target] {
                Text(hint)
                    .font(.sf(Tokens.TypeSize.meta))
                    .foregroundStyle(Tokens.text3)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 8)
            }

            // Every field here writes through the moment it changes, but a card with
            // no way to say "that's it" leaves the user guessing whether anything
            // took — so the edit ends the way the app's other dialogs end: one
            // primary capsule that closes it, with Delete beside it in the quiet
            // register.
            //
            // Both are sized to their own words and parked at the bottom right, the
            // corner every dialog's actions live in; split full-width, Delete would
            // carry a primary action's weight for the one thing here that throws
            // work away.
            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button {
                    deletePromptShortcut(binding.id)
                } label: {
                    Text(L("shortcuts.promptAction.delete"))
                        .font(.sf(Tokens.TypeSize.label))
                        .foregroundStyle(Tokens.danger)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 30)
                }
                .buttonStyle(PromptCardActionStyle(kind: .destructive))

                Button {
                    closePromptShortcutEditor(binding.id)
                } label: {
                    Text(L("shortcuts.promptAction.done"))
                        .font(.sf(Tokens.TypeSize.label))
                        .foregroundStyle(Tokens.text1)
                        .padding(.horizontal, 20)
                        .frame(minHeight: 30)
                }
                .buttonStyle(PromptCardActionStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private func promptBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { promptShortcuts.first(where: { $0.id == id })?.prompt ?? "" },
            set: { value in
                guard let index = promptShortcuts.firstIndex(where: { $0.id == id }) else { return }
                let wasReady = promptShortcuts[index].isReady
                promptShortcuts[index].prompt = value
                model.noteUserTyping()
                PromptShortcutStore.save(promptShortcuts)
                if wasReady != promptShortcuts[index].isReady {
                    NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
                    // The prompt just settled into a ready row — ask the AI for a
                    // display name once (it only writes when one is still missing,
                    // so an already-named shortcut is never touched).
                    if promptShortcuts[index].isReady {
                        model.ensurePromptShortcutName(promptShortcuts[index])
                    }
                }
            }
        )
    }

    /// Prompt Shortcuts use the full cross-provider menu, but its closed state is
    /// deliberately just the model name inside the prompt's bottom toolbar.
    private func promptModelPicker(for id: UUID) -> some View {
        let selection = promptModelBinding(for: id)
        let pin = selection.wrappedValue
        return Button {
            promptModelPickerOpen = true
        } label: {
            Text(ModelRatings.prettyName(for: pin.model, provider: pin.provider))
                .font(.sf(Tokens.TypeSize.meta))
                .foregroundStyle(Tokens.text3)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .buttonStyle(.plain).exemptsDoubleClickPin()
        .frame(maxWidth: .infinity, alignment: .leading)
        .notchTooltip(L("shortcuts.promptAction.model"))
        .modelMenu(isPresented: $promptModelPickerOpen,
                   models: promptModelPickerOpen
                       ? catalog.rows(selected: pin.provider).filter { $0.hasKey } : [],
                   selectedProvider: pin.provider,
                   selectedID: pin.model,
                   onSelect: { provider, modelID in
                       selection.wrappedValue = ModelPin(provider: provider, model: modelID)
                   },
                   onConfigure: { _ in })
        .onChange(of: promptModelPickerOpen) {
            if promptModelPickerOpen {
                Task { await catalog.loadAll() }
            }
            model.isModelPickerOpen = modelPickerOpen || promptModelPickerOpen
        }
    }

    /// Whether the force click box offers this row as a button. Persisted like
    /// every other row property, and the composer reads the list fresh on each
    /// appearance, so a change takes effect on the next press.
    private func promptForceTouchBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                promptShortcuts.first(where: { $0.id == id })?.appearsInForceTouch ?? false
            },
            set: { value in
                guard let index = promptShortcuts.firstIndex(where: { $0.id == id }) else { return }
                promptShortcuts[index].showsInForceTouch = value
                PromptShortcutStore.save(promptShortcuts)
                NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
            }
        )
    }

    /// The row's pinned backend. Every selection is a concrete provider/model
    /// pair; changing the app-wide default cannot rewrite it.
    private func promptModelBinding(for id: UUID) -> Binding<ModelPin> {
        Binding(
            get: {
                promptShortcuts.first(where: { $0.id == id })?.pin
                    ?? PromptShortcut.currentModelPin
            },
            set: { value in
                guard let index = promptShortcuts.firstIndex(where: { $0.id == id }) else { return }
                promptShortcuts[index].pin = value
                PromptShortcutStore.save(promptShortcuts)
                NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
            }
        )
    }

    private func deletePromptShortcut(_ id: UUID) {
        let target = EditableShortcut.prompt(id)
        if recordingShortcut == target { recordingShortcut = nil }
        shortcutHints[target] = nil
        if presentedPromptShortcutID == id { presentedPromptShortcutID = nil }
        withAnimation(Tokens.stackSpring) {
            promptShortcuts.removeAll { $0.id == id }
        }
        PromptShortcutStore.save(promptShortcuts)
        NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
    }

    /// One titled block. The description reads down the left edge and the keycaps
    /// hang off the right, with a hairline between rows — a table, not a list of
    /// sentences, so the eye can drop straight to the chord it came for.
    private func shortcutGroup(_ title: String, _ rows: [AppShortcutReference.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Same heading register as every other settings group title in this
            // pane, so the shortcuts list reads as one more Settings group.
            Text(title)
                .settingsHeading()
                .padding(.bottom, 3)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                let anchorKey = Section.shortcuts.searchKeys.first { L($0) == row.label }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 12) {
                        Text(row.label)
                            .font(.sf(Tokens.TypeSize.label))
                            .foregroundStyle(row.editable == nil ? Tokens.text3 : Tokens.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        if let editable = row.editable {
                            editableShortcutControl(editable, row: row)
                        } else if let note = row.note {
                            Text(note)
                                .font(.sf(Tokens.TypeSize.label))
                                .foregroundStyle(Tokens.text4)
                        } else {
                            HStack(spacing: 6) {
                                ForEach(Array(row.chords.enumerated()), id: \.offset) { i, chord in
                                    if i > 0 {
                                        Text(L("shortcuts.or"))
                                            .font(.sf(Tokens.TypeSize.meta))
                                            .foregroundStyle(Tokens.text4)
                                    }
                                    HStack(spacing: 3) {
                                        ForEach(Array(Self.keyCaps(chord).enumerated()), id: \.offset) { _, cap in
                                            keyCap(cap, readOnly: true)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if let editable = row.editable, let hint = shortcutHints[editable] {
                        Text(hint)
                            .font(.sf(Tokens.TypeSize.meta))
                            .foregroundStyle(Tokens.text3)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.vertical, 7)
                .searchTarget(anchorKey, active: highlightedSearchKey)
                .contentShape(Rectangle())
                .onHover { hovering in
                    guard let editable = row.editable else { return }
                    withAnimation(.easeOut(duration: Tokens.hoverFade)) {
                        if hovering {
                            hoveredShortcutRow = editable
                        } else if hoveredShortcutRow == editable {
                            hoveredShortcutRow = nil
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func editableShortcutControl(
        _ target: EditableShortcut,
        row: AppShortcutReference.Entry
    ) -> some View {
        HStack(spacing: 5) {
            // Summon has two useful modifier-only presets, so its inboard control
            // is a Reset To menu instead of a one-way default reset. Other editable
            // chords keep the compact reset affordance when they differ from
            // their shipped value.
            if target == .summon || target == .card || target == .screenshot {
                let menuOpen: Binding<Bool> = switch target {
                case .summon: $summonResetMenuOpen
                case .card: $cardResetMenuOpen
                default: $screenshotResetMenuOpen
                }
                Button { menuOpen.wrappedValue.toggle() } label: {
                    Text(L("general.shortcut.resetTo"))
                        .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                        .foregroundStyle(Tokens.text3)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 24)
                }
                .buttonStyle(ShortcutChipStyle(rest: 0.055, restStroke: 0.1))
                .glassMenuCard(open: menuOpen, items: (target == .screenshot ? [
                    GlassMenuItem(title: L("general.shortcut.bothOption")) {
                        restoreModifierTrigger(target, UInt32(optionKey), side: .both)
                    },
                ] : []) + [
                    GlassMenuItem(title: L("general.shortcut.doubleTapCommand")) {
                        restoreModifierTrigger(target, UInt32(cmdKey), side: .either)
                    },
                    GlassMenuItem(title: L("general.shortcut.doubleTapLeftCommand")) {
                        restoreModifierTrigger(target, UInt32(cmdKey), side: .left)
                    },
                    GlassMenuItem(title: L("general.shortcut.doubleTapRightCommand")) {
                        restoreModifierTrigger(target, UInt32(cmdKey), side: .right)
                    },
                    GlassMenuItem(title: L("general.shortcut.doubleTapOption")) {
                        restoreModifierTrigger(target, UInt32(optionKey), side: .either)
                    },
                    GlassMenuItem(title: L("general.shortcut.off")) {
                        turnOffGlobalShortcut(target)
                    },
                ])
                // Stays up while its menu is open: the pointer is on the card
                // then, not on this row.
                .opacity(hoveredShortcutRow == target || menuOpen.wrappedValue ? 1 : 0)
                .allowsHitTesting(hoveredShortcutRow == target || menuOpen.wrappedValue)
            } else if shortcutIsModified(target) {
                Button {
                    resetShortcut(target)
                } label: {
                    Image(icon: "arrow.counterclockwise")
                        .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                        .foregroundStyle(Tokens.text3)
                        .frame(width: Tokens.Control.inline, height: Tokens.Control.inline)
                }
                .buttonStyle(ShortcutChipStyle(rest: 0.055, restStroke: 0.1))
                .notchTooltip(L("shortcuts.reset"))
                .opacity(hoveredShortcutRow == target ? 1 : 0)
                .allowsHitTesting(hoveredShortcutRow == target)
                .transition(.scale(scale: 0.72).combined(with: .opacity))
            }

            Button {
                shortcutHints[target] = nil
                recordingShortcut = recordingShortcut == target ? nil : target
            } label: {
                Text(recordingShortcut == target
                     ? L("general.shortcut.recording")
                     : (row.note ?? row.chords.first ?? L("general.shortcut.off")))
                    .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                    .foregroundStyle(recordingShortcut == target ? Tokens.text1 : Tokens.text2)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 48, minHeight: 24)
            }
            .buttonStyle(ShortcutChipStyle(active: recordingShortcut == target))
            // Turning off the global summon remains available without leaving a
            // permanent trailing control in every default row.
            .contextMenu {
                if target == .summon, summonHotKey.enabled {
                    Button(L("general.shortcut.disable")) { disableSummonHotKey() }
                }
                if target == .card, cardHotKey.enabled {
                    Button(L("general.shortcut.disable")) { commitCardHotKey(.cardDefaultConfig) }
                }
                if target == .screenshot, screenshotHotKey.enabled {
                    Button(L("general.shortcut.disable")) { disableScreenshotHotKey() }
                }
            }
        }
        .animation(.easeOut(duration: 0.16), value: shortcutIsModified(target))
    }

    private func shortcutIsModified(_ target: EditableShortcut) -> Bool {
        switch target {
        case .summon:
            return summonHotKey != .defaultConfig
        case .card:
            return cardHotKey.enabled
        case .screenshot:
            return screenshotHotKey != .screenshotDefaultConfig
        case .action(let action):
            return (appShortcuts[action] ?? action.defaultChord) != action.defaultChord
        case .prompt:
            return false
        }
    }

    /// One conflict pass for every editable chord. `AppShortcutStore` owns the
    /// fixed/local actions and summon; the two global selected-text families live
    /// beside it and therefore add their owners here.
    private func shortcutConflictOwner(
        for chord: ShortcutChord,
        editing target: EditableShortcut
    ) -> String? {
        let appOwner: String? = switch target {
        case .summon:
            AppShortcutStore.conflictOwner(for: chord, editingSummon: true)
        case .card, .screenshot:
            AppShortcutStore.conflictOwner(for: chord)
        case .action(let action):
            AppShortcutStore.conflictOwner(for: chord, editingAction: action)
        case .prompt:
            AppShortcutStore.conflictOwner(for: chord)
        }
        if let appOwner { return appOwner }

        if target != .card, cardHotKey.enabled, cardHotKey.chord == chord {
            return L("shortcuts.card")
        }
        if target != .screenshot, screenshotHotKey.enabled, screenshotHotKey.chord == chord {
            return L("shortcuts.screenshotGlobal")
        }

        let editingPromptID: UUID? = if case .prompt(let id) = target { id } else { nil }
        if promptShortcuts.contains(where: {
            $0.id != editingPromptID && $0.shortcut == chord
        }) {
            return L("shortcuts.promptAction")
        }
        return nil
    }

    /// Recorder validation is deliberately shared for summon and local actions:
    /// one real modifier is required, and a chord may have exactly one owner.
    private func captureShortcut(keyCode: UInt32, flags: NSEvent.ModifierFlags) {
        guard let target = recordingShortcut else { return }
        let chord = ShortcutChord(keyCode: keyCode,
                                  modifiers: SummonHotKey.carbonModifiers(from: flags))
        let realModifierMask = UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
        guard chord.modifiers & realModifierMask != 0 else {
            shortcutHints[target] = L("general.shortcut.needModifier")
            return
        }

        if let owner = shortcutConflictOwner(for: chord, editing: target) {
            shortcutHints[target] = L("shortcuts.conflict.usedBy", owner)
            return
        }

        let unchangedGlobal: Bool = switch target {
        case .summon:
            summonHotKey.enabled && !summonHotKey.isDoubleTap
                && summonHotKey.keyCode == chord.keyCode
                && summonHotKey.modifiers == chord.modifiers
        case .card:
            cardHotKey.enabled && !cardHotKey.isDoubleTap && cardHotKey.chord == chord
        case .screenshot:
            screenshotHotKey.enabled && !screenshotHotKey.isDoubleTap && screenshotHotKey.chord == chord
        case .prompt(let id):
            promptShortcuts.first(where: { $0.id == id })?.shortcut == chord
        case .action:
            true
        }
        let needsGlobalProbe: Bool = switch target {
        case .summon, .card, .screenshot, .prompt: true
        case .action: false
        }
        if needsGlobalProbe, !unchangedGlobal,
           !HotKey.isAvailable(keyCode: chord.keyCode,
                               modifiers: chord.modifiers) {
            shortcutHints[target] = L("shortcuts.conflict.usedBy",
                                      L("shortcuts.reserved.system"))
            return
        }

        shortcutHints[target] = nil
        recordingShortcut = nil
        switch target {
        case .summon:
            commitSummonHotKey(SummonHotKey(keyCode: chord.keyCode,
                                            modifiers: chord.modifiers,
                                            enabled: true))
        case .card:
            commitCardHotKey(SummonHotKey(keyCode: chord.keyCode,
                                          modifiers: chord.modifiers,
                                          enabled: true))
        case .screenshot:
            commitScreenshotHotKey(SummonHotKey(keyCode: chord.keyCode,
                                                modifiers: chord.modifiers,
                                                enabled: true))
        case .action(let action):
            AppShortcutStore.set(chord, for: action)
            appShortcuts[action] = chord
            NotificationCenter.default.post(name: .appShortcutsChanged, object: nil)
        case .prompt(let id):
            guard let index = promptShortcuts.firstIndex(where: { $0.id == id }) else { return }
            promptShortcuts[index].shortcut = chord
            PromptShortcutStore.save(promptShortcuts)
            NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
        }
    }

    /// A bare modifier never produces `keyDown`, so summon and prompt shortcut
    /// rows receive double-Command / double-Option separately from ordinary
    /// chords. Panel-local action shortcuts remain chord-only.
    private func captureDoubleModifier(_ modifier: UInt32) {
        guard let target = recordingShortcut else { return }
        if case .action = target { return }
        let chord = ShortcutChord.doubleTap(modifier)

        if let owner = shortcutConflictOwner(for: chord, editing: target) {
            shortcutHints[target] = L("shortcuts.conflict.usedBy", owner)
            return
        }

        switch target {
        case .summon:
            shortcutHints[target] = nil
            recordingShortcut = nil
            commitSummonHotKey(SummonHotKey(keyCode: 0,
                                            modifiers: 0,
                                            doubleTapModifier: modifier,
                                            enabled: true))
        case .card:
            shortcutHints[target] = nil
            recordingShortcut = nil
            commitCardHotKey(SummonHotKey(keyCode: 0, modifiers: 0,
                                          doubleTapModifier: modifier, enabled: true))
        case .screenshot:
            shortcutHints[target] = nil
            recordingShortcut = nil
            commitScreenshotHotKey(SummonHotKey(keyCode: 0, modifiers: 0,
                                                doubleTapModifier: modifier, enabled: true))
        case .prompt(let id):
            guard let index = promptShortcuts.firstIndex(where: { $0.id == id }) else { return }
            shortcutHints[target] = nil
            recordingShortcut = nil
            promptShortcuts[index].shortcut = chord
            PromptShortcutStore.save(promptShortcuts)
            NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
        case .action:
            break
        }
    }

    private func resetShortcut(_ target: EditableShortcut) {
        recordingShortcut = nil
        shortcutHints[target] = nil
        switch target {
        case .summon:
            commitSummonHotKey(.defaultConfig)
        case .card:
            commitCardHotKey(.cardDefaultConfig)
        case .screenshot:
            commitScreenshotHotKey(.screenshotDefaultConfig)
        case .action(let action):
            AppShortcutStore.reset(action)
            appShortcuts[action] = action.defaultChord
            NotificationCenter.default.post(name: .appShortcutsChanged, object: nil)
        case .prompt:
            break
        }
    }

    /// Summon, the top-right card, and screenshot share the same modifier-only
    /// presets. Left ⌘ on one and right ⌘ on another do not conflict.
    private func restoreModifierTrigger(_ target: EditableShortcut,
                                        _ modifier: UInt32,
                                        side: ModifierSide) {
        recordingShortcut = nil
        let config = SummonHotKey(keyCode: 0, modifiers: 0,
                                  doubleTapModifier: modifier,
                                  doubleTapSide: side, enabled: true)
        let peers: [(EditableShortcut, SummonHotKey, String)] = [
            (.summon, summonHotKey, L("shortcuts.summon")),
            (.card, cardHotKey, L("shortcuts.card")),
            (.screenshot, screenshotHotKey, L("shortcuts.screenshotGlobal")),
        ]
        var owner: String? = peers.first { $0.0 != target && config.doubleTapOverlaps($0.1) }?.2
        if owner == nil,
           promptShortcuts.contains(where: { $0.shortcut?.doubleTapModifier == modifier }) {
            owner = L("shortcuts.promptAction")
        }
        if let owner {
            shortcutHints[target] = L("shortcuts.conflict.usedBy", owner)
            return
        }
        shortcutHints[target] = nil
        switch target {
        case .summon:
            commitSummonHotKey(config)
        case .card:
            commitCardHotKey(config)
        case .screenshot:
            commitScreenshotHotKey(config)
        default:
            break
        }
    }

    private func turnOffGlobalShortcut(_ target: EditableShortcut) {
        switch target {
        case .summon:
            disableSummonHotKey()
        case .screenshot:
            disableScreenshotHotKey()
        case .card:
            recordingShortcut = nil
            shortcutHints[.card] = nil
            commitCardHotKey(.cardDefaultConfig)
        default:
            break
        }
    }

    private func disableSummonHotKey() {
        recordingShortcut = nil
        shortcutHints[.summon] = nil
        var off = summonHotKey
        off.enabled = false
        commitSummonHotKey(off)
    }

    private func disableScreenshotHotKey() {
        recordingShortcut = nil
        shortcutHints[.screenshot] = nil
        var off = screenshotHotKey
        off.enabled = false
        commitScreenshotHotKey(off)
    }

    private func commitCardHotKey(_ newValue: SummonHotKey) {
        cardHotKey = newValue
        SummonHotKey.card = newValue
        NotificationCenter.default.post(name: .summonHotKeyChanged, object: nil)
    }

    private func commitScreenshotHotKey(_ newValue: SummonHotKey) {
        screenshotHotKey = newValue
        SummonHotKey.screenshot = newValue
        NotificationCenter.default.post(name: .summonHotKeyChanged, object: nil)
    }

    private func commitSummonHotKey(_ newValue: SummonHotKey) {
        summonHotKey = newValue
        SummonHotKey.current = newValue
        NotificationCenter.default.post(name: .summonHotKeyChanged, object: nil)
    }

    /// Split a written chord ("⇧⌘I", "⌘,") into the individual caps a keyboard
    /// sheet draws — one per modifier, then the key itself as the last cap. The
    /// key half is taken whole rather than per-character, so a named key ("Space",
    /// "F5") from a recorded summon chord stays on one cap instead of exploding
    /// into letters.
    private static func keyCaps(_ chord: String) -> [String] {
        var caps: [String] = []
        var rest = Substring(chord)
        while let first = rest.first, "⌃⌥⇧⌘".contains(first) {
            caps.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { caps.append(String(rest)) }
        return caps
    }

    /// One keycap. Deliberately the same skin as the summon recorder's chip in
    /// General — that chip *is* a keycap showing a chord, so the reference's caps
    /// and the editable one read as the same object at two sizes.
    private func keyCap(_ text: String, readOnly: Bool = false) -> some View {
        Text(text)
            .font(.sf(Tokens.TypeSize.meta, weight: .regular))
            .foregroundStyle(readOnly ? Tokens.text4 : Tokens.text2)
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 22)
            .background(
                Capsule(style: .continuous)
                    .fill(Tokens.ink.opacity(readOnly ? 0.025 : 0.07))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        Tokens.ink.opacity(readOnly ? 0.075 : 0.13),
                        style: StrokeStyle(lineWidth: 0.5,
                                           dash: readOnly ? [2, 2] : [])
                    )
            )
    }

    // MARK: - About

    // MARK: - Stats

    /// Settings → **Stats**: what the archive adds up to, then the requests that
    /// produced the tokens beside it. One pane because they answer one question —
    /// the totals say how much, the flow chart says over what.
    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The request chart leads: it is the page's one live picture, and
            // its detail footer has to be on screen without scrolling — the
            // archive's own totals below it are already steady numbers.
            // Where the record lives sits above it, at the top right.
            HStack {
                Spacer(minLength: 0)
                StatsPane()
            }
            .padding(.bottom, 6)
            AuditPane(onInAppCopy: { model.rebaselineClipboardAfterInAppWrite() })
        }
        .task(id: statsFingerprint) { await refreshStats() }
    }

    /// What has to change for the digest to be stale. Not `history.count` alone:
    /// a follow-up on an open thread rewrites that thread in place and re-files it
    /// at the head, so the row count doesn't move while the word count does — the
    /// pane would sit there showing the figure from before the answer.
    private var statsFingerprint: some Hashable {
        struct Fingerprint: Hashable { let count: Int; let newest: Date? }
        return Fingerprint(count: model.history.count, newest: model.history.first?.t)
    }

    /// Fold the archive off the main thread. It's a few milliseconds over today's
    /// archives, but the walk is unbounded — it grows with every answer the app
    /// ever gives — and the panel it would block is an animating one.
    private func refreshStats() async {
        let items = model.history
        let digest = await Task.detached(priority: .userInitiated) {
            StatsDigest.make(from: items)
        }.value
        stats = digest
        // The token figure is the one number on the pane that isn't folded from
        // the archive — it's the meter's own running total (see `TokenMeter`),
        // re-read on the same beat, since the answer that grew the archive is
        // also the request that moved the meter.
        statsTokens = TokenMeter.shared.reading
    }

    /// The About pane: who the app is before the version mechanics — an
    /// identity block (icon, name, version and its update action), then the
    /// links (`aboutLinks`), then the attribution footnote.
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1 — Identity: who the app is, with the version and its update
            // action right beside the name so "what you're running / is it
            // current" reads as one thought instead of three scattered lines.
            HStack(alignment: .center, spacing: 12) {
                // App icon, if the bundle carries one — falls back gracefully.
                // The selected catalog asset, not `NSApp.applicationIconImage`:
                // on macOS 26 the running icon comes back already rendered for the
                // current appearance, which can add a system treatment inside this
                // dark panel. Reading the asset gives either artwork as drawn.
                // Both catalog assets use the same preview scale so their visible
                // icon heights stay aligned here and in Appearance.
                let _ = appIconAppearanceRevision
                let iconStyle = AppIconStyle.current
                if let icon = iconStyle.image ?? NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(iconStyle.previewScale)
                        .frame(width: 44, height: 44)
                        .clipped()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Notchi")
                        .font(.brand(18))
                        .foregroundStyle(Tokens.text1)

                    HStack(spacing: 8) {
                        Text(UpdaterService.currentVersion)
                            .font(.sf(Tokens.TypeSize.label, weight: .regular))
                            .foregroundStyle(Tokens.text4)
                        // Hairline between the version and its update action, so
                        // the two sit as one row without running together.
                        Rectangle()
                            .fill(Tokens.ink.opacity(0.12))
                            .frame(width: 0.5, height: 11)
                        updateArea
                    }
                }

                Spacer(minLength: 0)
            }

            // 2 — Where else to go: the pages that open here, then the rail of
            // places that leave.
            aboutLinks

            // 3 — Attribution. Not one of the things you *do* from About, so it
            // sits below the rail as a footnote — the last line of the pane, in
            // the place a colophon belongs.
            AboutFootnoteLink(title: L("about.licenses")) {
                withAnimation(.easeOut(duration: 0.16)) {
                    section = .licenses
                }
            }
            .padding(.top, 2)
            .searchTarget("about.licenses", active: highlightedSearchKey)
        }
        .task(id: statsFingerprint) { await refreshStats() }
    }

    /// The whole update story in one slot, right under the version number where
    /// it belongs: at rest a quiet "Check for updates" link, and every state that
    /// follows — checking, "up to date", "Update to X", updating, failed — swaps
    /// through this same spot rather than scattering across the panel. Because a
    /// newer version and the manual-check confirmation share the slot, they read
    /// as one continuous action instead of two unrelated controls.
    ///
    /// The faces differ in width, weight, and height (the failure pill especially),
    /// so any positional transition makes them jump. Deliberately plain: one face
    /// cross-fades into the next in place — opacity only, no drift, no spring — so
    /// switching states never shifts anything around it.
    private var updateArea: some View {
        ZStack(alignment: .leading) {
            updateContent
                .id(updateSlot)
                .transition(.opacity)
        }
        // Text and the small spinner report slightly different intrinsic
        // heights. Keep their shared row fixed so starting a check cannot nudge
        // the identity stack by a fraction of a point.
        .frame(height: 16, alignment: .leading)
        .animation(.easeInOut(duration: 0.18), value: updateSlot)
    }

    /// Which face the update slot is showing. Collapsing phase + manualCheck into
    /// one enum gives `updateArea` a single value to key the cross-fade on, so
    /// SwiftUI treats each face as a distinct view that fades in and out.
    private enum UpdateSlot: Hashable {
        case rest, checking, upToDate, available(String), updating, failed
    }

    private var updateSlot: UpdateSlot {
        switch updater.phase {
        case .available(let v): return .available(v)
        case .updating:         return .updating
        case .failed:           return .failed
        case .unknown, .upToDate:
            switch updater.manualCheck {
            case .checking: return .checking
            case .upToDate: return .upToDate
            case .idle:     return .rest
            }
        }
    }

    @ViewBuilder
    private var updateContent: some View {
        switch updateSlot {
        case .available(let v):
            aboutLink(L("about.update.to", v)) {
                updater.update()
            }
        case .updating:
            // The download is the long part of an update, so say how far along it
            // is rather than spinning for a minute with nothing to read. The
            // figure sits outside `updateSlot` on purpose: keying the cross-fade
            // on it would re-run the fade on every percent.
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(updater.stage == .installing ? L("about.installing") : L("about.updating"))
                    .font(.sf(Tokens.TypeSize.label, weight: .regular))
                    .foregroundStyle(Tokens.text2)
                if case .downloading(let f) = updater.stage {
                    Text("\(Int(f * 100))%")
                        .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(Tokens.text4)
                }
            }
        case .failed:
            // A statement, not an errand: no dot to decode and no jump out to a
            // web page — the update simply didn't take, and trying later is the
            // whole of what there is to do. (The chip on the panel retries.)
            Text(L("about.updateFailed"))
                .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                .foregroundStyle(Tokens.danger.opacity(0.92))
        case .checking:
            HStack(spacing: 7) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text(L("about.checking"))
                    .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                    .foregroundStyle(Tokens.text3)
            }
        case .upToDate:
            Text(L("about.upToDate"))
                .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                .foregroundStyle(Tokens.text2)
                .task {
                    // Let the confirmation linger, then recede to the link.
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    updater.clearManualConfirmation()
                }
        case .rest:
            aboutLink(L("about.checkForUpdates")) {
                updater.checkManually()
            }
        }
    }

    /// GitHub, X and Discord lead the About actions. The four quieter product/support
    /// destinations remain directly visible underneath — no nested menu and no
    /// trip back to the prompt's More menu.
    private var aboutLinks: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                AboutSocialButton(kind: .github,
                                  title: L("about.starGithub")) {
                    LinkGate.shared.open(URL(string: "https://github.com/\(UpdaterService.repo)")!)
                }
                AboutSocialButton(kind: .x,
                                  title: L("about.followX")) {
                    LinkGate.shared.open(URL(string: "https://x.com/cyrusss_7")!)
                }
                AboutSocialButton(kind: .discord,
                                  title: L("about.discord")) {
                    LinkGate.shared.open(URL(string: "https://discord.gg/wdMH3CC9CW")!)
                }
            }

            surveyEntry

            // The archive's day grid, moved out of Stats: a year of use is a
            // thing About can say, and it says it without a card around it.
            if let stats, !stats.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    StatsActivityGrid(digest: stats, hovered: $statsHover)
                    StatsSummaryLines(digest: stats, tokens: statsTokens)
                }
                .padding(.top, 14)
            }

            VStack(spacing: 0) {
                AboutUtilityButton(title: L("about.whatsNew"), leaves: false) {
                    // In the window the notes are a page of this Settings (the
                    // reader fills the pane); in the panel they take the body
                    // over, which is the flow the notch has always had.
                    if inWindow {
                        open(.whatsNew)
                    } else {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                            model.openWhatsNew(on: nil)
                        }
                    }
                }
                .searchTarget("whatsnew.title", active: highlightedSearchKey)

                aboutUtilitySeparator

                AboutUtilityButton(title: L("about.replayIntro"), leaves: false) {
                    replayIntro()
                }

                aboutUtilitySeparator

                AboutUtilityButton(title: L("about.privacy"), leaves: true) {
                    LinkGate.shared.open(URL(string: "https://www.notch.website/privacy")!)
                }

                aboutUtilitySeparator

                AboutUtilityButton(title: L("about.feedback"), leaves: true) {
                    LinkGate.shared.open(URL(string: "https://github.com/\(UpdaterService.repo)/issues")!)
                }
            }
            .recessedSurface(in: RoundedRectangle.control, lit: false)
            .clipShape(RoundedRectangle.control)
            .padding(.top, 12)
        }
    }

    /// The survey's row, between the social buttons and the utility list. Shown
    /// while the gateway runs a survey this account has not had decided: open
    /// before it answers, a status line while the answer waits for review, and
    /// after approval a link to the wallet until the Model pane has been opened.
    @ViewBuilder
    private var surveyEntry: some View {
        if let survey = nono.snapshot?.survey, survey.status == "none" || survey.status == "pending" {
            let open = survey.status == "none"
            AboutSurveyRow(title: open ? L("survey.row") : L("survey.row.sent"),
                           tag: open ? L("survey.row.credit", surveyAmount(survey.amountUSD))
                                     : L("survey.row.review"),
                           action: open ? {
                               withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { section = .survey }
                           } : nil)
                .padding(.top, 9)
        } else if let survey = nono.snapshot?.survey, surveyJustGranted {
            AboutSurveyRow(title: L("survey.row.granted", surveyAmount(survey.amountUSD)),
                           tag: L("survey.row.view"),
                           action: openGrantedCredit)
                .padding(.top, 9)
        }
    }

    private func surveyAmount(_ usd: Double) -> String {
        usd.rounded() == usd ? String(Int(usd)) : String(format: "%.2f", usd)
    }

    private var aboutUtilitySeparator: some View {
        Rectangle()
            .fill(Tokens.ink.opacity(0.065))
            .frame(height: 0.5)
            .padding(.leading, 11)
    }

    /// Blend1 requests against this wallet: when, which model, tokens, and
    /// what the balance was charged. Reached from the wallet's links, not the
    /// sidebar — it is a receipt pad for one account, not a settings category.
    private var usageSection: some View {
        let used = nono.snapshot?.credit.usedUSD
        let hasSpent = (used ?? 0) > 0
        return VStack(alignment: .leading, spacing: 12) {
            if hasSpent, let used {
                Text(L("nono.usage.spent", Self.moneyCharged(used)))
                    .font(.sf(Tokens.TypeSize.meta))
                    .foregroundStyle(Tokens.text4)
                    .monospacedDigit()
            }

            if usageLoading && usageLines.isEmpty {
                // Centred in the pane's own body, not parked under the header:
                // the table it stands in for fills that whole area, so the
                // spinner reads as "this pane is filling" rather than as a
                // first row.
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity,
                           minHeight: usagePlaceholderHeight(hasSpent: hasSpent),
                           alignment: .center)
            } else if usageFailed && usageLines.isEmpty {
                Text(L("nono.error.unreachable"))
                    .font(.sf(Tokens.TypeSize.label))
                    .foregroundStyle(Tokens.text3)
                    .fixedSize(horizontal: false, vertical: true)
            } else if usageLines.isEmpty {
                Text(L("nono.usage.empty"))
                    .font(.sf(Tokens.TypeSize.label))
                    .foregroundStyle(Tokens.text3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                usageTable
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await refreshUsage() }
    }

    /// Ruled like `MarkdownTableView`: a caption-register header, a hairline
    /// under it, fainter hairlines between rows. Model takes the spare width;
    /// the figures are right-aligned so their digits line up.
    private var usageTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
            GridRow {
                Text(L("nono.usage.col.time")).settingsCaption()
                Text(L("nono.usage.col.model")).settingsCaption()
                Text(L("nono.pricing.input")).settingsCaption()
                    .gridColumnAlignment(.trailing)
                Text(L("nono.pricing.cached")).settingsCaption()
                    .gridColumnAlignment(.trailing)
                Text(L("nono.pricing.output")).settingsCaption()
                    .gridColumnAlignment(.trailing)
                Text(L("nono.usage.col.cost")).settingsCaption()
                    .gridColumnAlignment(.trailing)
            }
            .padding(.bottom, 8)

            Divider().overlay(Tokens.hairline).gridCellColumns(6)

            ForEach(Array(usageLines.enumerated()), id: \.element.id) { index, line in
                usageRow(line)
                if index < usageLines.count - 1 {
                    Divider().overlay(Tokens.hairline.opacity(0.6)).gridCellColumns(6)
                }
            }
        }
    }

    private func usageRow(_ line: NoNoAccount.UsageLine) -> some View {
        GridRow {
            usageCell(line.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()),
                      color: Tokens.text2)
            // A request the app made on its own (a predicted question, a
            // thread title) says so, so it does not read as unexplained spend.
            HStack(spacing: 6) {
                usageCell(usageModelName(line.model), color: Tokens.text1)
                if let label = line.backgroundLabel {
                    ModelDetailCard.Tag(text: label)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            usageCell(line.promptTokens.map(StatsFormat.count) ?? "—", color: Tokens.text2)
            // Counted inside the prompt figure to its left, not beside it: the
            // cost on this row is the rest of that prompt at the input rate
            // plus this much at the cached rate.
            usageCell(line.cachedTokens.map(StatsFormat.count) ?? "—", color: Tokens.text3)
            usageCell(line.completionTokens.map(StatsFormat.count) ?? "—", color: Tokens.text2)
            usageCell(line.billedUSD.map(Self.moneyCharged) ?? "—", color: Tokens.text1)
        }
        .padding(.vertical, 9)
    }

    private func usageCell(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.sf(Tokens.TypeSize.label))
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(1)
    }

    private func usageModelName(_ id: String) -> String {
        // A web search is billed as its own line (`/v1/search`).
        if id == "web-search" { return L("usage.webSearch") }
        return ModelRatings.nonoDisplayName(for: id) ?? id
    }

    /// The height left for the pane's rows once the top runway, the bottom
    /// inset and the "spent" line above are taken out — so a placeholder can
    /// centre itself in the area the table would occupy without pushing the
    /// pane past its height cap (which would switch on the scroll taper).
    private func usagePlaceholderHeight(hasSpent: Bool) -> CGFloat {
        let body = settingsPaneHeight - metrics.paneTopRunway - 20
        return max(0, body - (hasSpent ? 26 : 0))
    }

    private func refreshUsage() async {
        usageFailed = false
        usageLoading = true
        defer { usageLoading = false }
        do {
            usageLines = try await nono.loadUsage()
        } catch {
            usageFailed = true
        }
    }

    /// Each gift and purchase against this wallet: original dollars, a kind
    /// tag, and when a gift lapses. Reached from the wallet's links, same as Usage.
    private var balancesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            nonoBalanceDetail
                .padding(.bottom, 6)
            if balancesLoading && balanceLines.isEmpty {
                // Centred the same way as Usage's.
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity,
                           minHeight: usagePlaceholderHeight(hasSpent: false),
                           alignment: .center)
            } else if balancesFailed && balanceLines.isEmpty {
                Text(L("nono.error.unreachable"))
                    .font(.sf(Tokens.TypeSize.label))
                    .foregroundStyle(Tokens.text3)
                    .fixedSize(horizontal: false, vertical: true)
            } else if balanceLines.isEmpty && license.purchasedAt == nil {
                Text(L("nono.balances.empty"))
                    .font(.sf(Tokens.TypeSize.label))
                    .foregroundStyle(Tokens.text3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                balancesTable
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await refreshBalances() }
    }

    private var balancesTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
            GridRow {
                Text(L("nono.balances.col.name")).settingsCaption()
                Text(L("nono.balances.col.amount")).settingsCaption()
                    .gridColumnAlignment(.trailing)
                Text(L("nono.balances.col.kind")).settingsCaption()
                Text(L("nono.balances.col.date")).settingsCaption()
                Text(L("nono.balances.col.expires")).settingsCaption()
                    .gridColumnAlignment(.trailing)
            }
            .padding(.bottom, 8)

            Divider().overlay(Tokens.hairline).gridCellColumns(5)

            // The license is a purchase too, though not credit: its own line,
            // in the same cells, never expiring.
            if let bought = license.purchasedAt {
                GridRow {
                    usageCell(L("license.balances.name"), color: Tokens.text1)
                    usageCell(Self.moneyCharged(license.priceUSD), color: Tokens.text1)
                    balanceKindTag(.purchase)
                    usageCell(bought.formatted(.dateTime.month(.abbreviated).day()), color: Tokens.text2)
                    usageCell("—", color: Tokens.text2)
                }
                .padding(.vertical, 9)
                if !balanceLines.isEmpty {
                    Divider().overlay(Tokens.hairline.opacity(0.6)).gridCellColumns(5)
                }
            }

            ForEach(Array(balanceLines.enumerated()), id: \.element.id) { index, line in
                balanceRow(line)
                if index < balanceLines.count - 1 {
                    Divider().overlay(Tokens.hairline.opacity(0.6)).gridCellColumns(5)
                }
            }
        }
    }

    private func balanceRow(_ line: NoNoAccount.BalanceLine) -> some View {
        GridRow {
            usageCell(balanceName(line), color: Tokens.text1)
            usageCell(Self.moneyCharged(line.amountUSD), color: Tokens.text1)
            balanceKindTag(line.kind)
            usageCell(line.date.formatted(.dateTime.month(.abbreviated).day()),
                      color: Tokens.text2)
            usageCell(line.expiresDate.map {
                $0.formatted(.dateTime.month(.abbreviated).day().year())
            } ?? "—", color: Tokens.text2)
        }
        .padding(.vertical, 9)
    }

    private func balanceName(_ line: NoNoAccount.BalanceLine) -> String {
        switch line.kind {
        case .purchase: return L("nono.balances.name.purchase")
        case .gift: return line.title ?? L("nono.balances.name.welcome")
        }
    }

    /// Gift is a smoked rose chip; a purchase is the same chip without the tint.
    private func balanceKindTag(_ kind: NoNoAccount.BalanceLine.Kind) -> some View {
        let gift = kind == .gift
        return Text(L(gift ? "nono.balances.tag.gift" : "nono.balances.tag.purchase"))
            .font(.sf(Tokens.TypeSize.meta, weight: .regular))
            .foregroundStyle(gift
                             ? Tokens.adaptive(dark: NSColor(red: 0.86, green: 0.64, blue: 0.66, alpha: 1),
                                               light: NSColor(red: 0.66, green: 0.32, blue: 0.36, alpha: 1))
                             : Tokens.text3)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous).fill(gift
                               ? Tokens.adaptive(dark: NSColor(red: 0.42, green: 0.22, blue: 0.24, alpha: 0.55),
                                                 light: NSColor(red: 0.97, green: 0.88, blue: 0.89, alpha: 1))
                               : Tokens.ink.opacity(0.06)))
    }

    private func refreshBalances() async {
        balancesFailed = false
        balancesLoading = true
        defer { balancesLoading = false }
        do {
            balanceLines = try await nono.loadBalances()
        } catch {
            balancesFailed = true
        }
    }

    // MARK: - Survey

    /// Option ids, the same lists as `SURVEY_OPTIONS` in the gateway's
    /// `survey.ts`. Brand names are not translated.
    private static let surveySources: [(id: String, title: () -> String)] = [
        ("x", { "X" }), ("github", { "GitHub" }), ("friend", { L("survey.source.friend") }),
        ("search", { L("survey.source.search") }), ("other", { L("survey.other") }),
    ]
    private static let surveyRoles = ["engineer", "designer", "product", "student", "researcher", "creator", "other"]
    private static let surveyFrequencies = ["daily", "weekly", "rarely"]
    private static let surveyUses = ["assistant", "questions", "copied", "coding", "translation", "agent", "other"]
    private static let surveyAlternatives: [(id: String, title: () -> String)] = [
        ("muse", { "Muse" }), ("grokbot", { "GrokBot" }), ("instinct", { "Instinct" }),
        ("other", { L("survey.other") }), ("none", { L("survey.alternatives.none") }),
    ]
    private static let surveyWishMin = 20

    private var surveyWishReady: Bool {
        surveyWish.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.surveyWishMin
    }

    private func surveyFilled(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Picking Other asks for the answer in words, and that answer is required.
    private var surveyReady: Bool {
        guard let source = surveySource, let role = surveyRole, surveyFrequency != nil, !surveyUses.isEmpty,
              surveyWishReady else { return false }
        if source == "other" && !surveyFilled(surveySourceDetail) { return false }
        if role == "other" && !surveyFilled(surveyRoleOther) { return false }
        if surveyUses.contains("other") && !surveyFilled(surveyUsesOther) { return false }
        if surveyAlternatives.isEmpty { return false }
        if surveyAlternatives.contains("other") && !surveyFilled(surveyAlternativesOther) { return false }
        return true
    }

    private var surveySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            surveyQuestion(L("survey.q.source")) {
                FlowLayout(hSpacing: 6, vSpacing: 6) {
                    ForEach(Self.surveySources, id: \.id) { option in
                        SurveyChoicePill(title: option.title(), active: surveySource == option.id, mode: .radio) {
                            surveySource = option.id
                        }
                    }
                }
                if surveySource == "other" {
                    surveyField(L("survey.source.otherPlaceholder"), text: $surveySourceDetail, lines: 1)
                }
            }
            surveyQuestion(L("survey.q.role")) {
                surveyPills(Self.surveyRoles, key: "survey.role", selected: surveyRole.map { [$0] } ?? [], mode: .radio) {
                    surveyRole = $0
                }
                if surveyRole == "other" {
                    surveyField(L("survey.other.placeholder"), text: $surveyRoleOther, lines: 1)
                }
            }
            surveyQuestion(L("survey.q.frequency")) {
                surveyPills(Self.surveyFrequencies, key: "survey.frequency",
                            selected: surveyFrequency.map { [$0] } ?? [], mode: .radio) {
                    surveyFrequency = $0
                }
            }
            surveyQuestion(L("survey.q.alternatives")) {
                FlowLayout(hSpacing: 6, vSpacing: 6) {
                    ForEach(Self.surveyAlternatives, id: \.id) { option in
                        SurveyChoicePill(title: option.title(), active: surveyAlternatives.contains(option.id), mode: .checkbox) {
                            toggleSurveyAlternative(option.id)
                        }
                    }
                }
                if surveyAlternatives.contains("other") {
                    surveyField(L("survey.other.placeholder"), text: $surveyAlternativesOther, lines: 1)
                }
            }
            surveyQuestion(L("survey.q.uses")) {
                surveyPills(Self.surveyUses, key: "survey.uses", selected: surveyUses, mode: .checkbox) { id in
                    if surveyUses.contains(id) { surveyUses.remove(id) } else { surveyUses.insert(id) }
                }
                if surveyUses.contains("other") {
                    surveyField(L("survey.other.placeholder"), text: $surveyUsesOther, lines: 1)
                }
            }
            surveyQuestion(L("survey.q.wish")) {
                surveyField(L("survey.wish.placeholder", Self.surveyWishMin), text: $surveyWish, lines: 4)
            }

            HStack(spacing: 12) {
                if surveyFailed {
                    Text(L("survey.failed"))
                        .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                        .foregroundStyle(Tokens.danger.opacity(0.92))
                } else if let amount = nono.snapshot?.survey?.amountUSD {
                    Text(L("survey.reviewNote", surveyAmount(amount)))
                        .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                        .foregroundStyle(Tokens.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                surveySubmitButton
            }
        }
    }

    /// Several may be picked, except None, which stands alone.
    private func toggleSurveyAlternative(_ id: String) {
        if surveyAlternatives.contains(id) {
            surveyAlternatives.remove(id)
        } else if id == "none" {
            surveyAlternatives = ["none"]
        } else {
            surveyAlternatives.remove("none")
            surveyAlternatives.insert(id)
        }
    }

    private func surveyQuestion<Content: View>(_ title: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.sf(Tokens.TypeSize.form, weight: .regular))
                .foregroundStyle(Tokens.text1)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
    }

    private func surveyPills(_ ids: [String], key: String, selected: Set<String>,
                             mode: SettingsChoiceChip.Mode,
                             choose: @escaping (String) -> Void) -> some View {
        FlowLayout(hSpacing: 6, vSpacing: 6) {
            ForEach(ids, id: \.self) { id in
                SurveyChoicePill(title: id == "other" ? L("survey.other") : L("\(key).\(id)"),
                                 active: selected.contains(id),
                                 mode: mode) { choose(id) }
            }
        }
    }

    private func surveyField(_ placeholder: String, text: Binding<String>, lines: Int) -> some View {
        SettingsTextField(
            placeholder: placeholder,
            text: text,
            lines: lines > 1 ? lines...lines : nil,
            onChange: { _ in model.noteUserTyping() }
        )
    }

    private var surveySubmitButton: some View {
        SettingsButton(title: L("survey.submit"),
                       variant: .primary,
                       size: .md,
                       loading: surveySending) {
            submitSurvey()
        }
        .disabled(!surveyReady || surveySending)
    }

    private func submitSurvey() {
        guard surveyReady, !surveySending,
              let source = surveySource, let role = surveyRole, let frequency = surveyFrequency else { return }
        let answers: [String: Any] = [
            "source": source,
            "sourceDetail": source == "other" ? surveySourceDetail.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            "role": role,
            "roleOther": role == "other" ? surveyRoleOther.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            "usesOther": surveyUses.contains("other")
                ? surveyUsesOther.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            "frequency": frequency,
            "uses": Self.surveyUses.filter { surveyUses.contains($0) },
            "alternatives": Self.surveyAlternatives.map(\.id).filter { surveyAlternatives.contains($0) },
            "alternativesOther": surveyAlternatives.contains("other")
                ? surveyAlternativesOther.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            "wish": surveyWish.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        surveySending = true
        surveyFailed = false
        Task {
            do {
                try await nono.submitSurvey(answers)
                surveySending = false
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { section = .about }
            } catch {
                surveySending = false
                surveyFailed = true
            }
        }
    }

    /// History's filter pill (`HistoryFilterPill`); the chosen one takes the
    /// accent wash, as an active History pill takes its source's colour. Two
    /// quick clicks toggle it twice rather than pinning the panel.
    private struct SurveyChoicePill: View {
        let title: String
        let active: Bool
        var mode: SettingsChoiceChip.Mode = .radio
        let action: () -> Void

        var body: some View {
            SettingsChoiceChip(title: title, active: active, mode: mode, action: action)
        }
    }

    private var licensesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("about.music"))
                .font(.sf(Tokens.TypeSize.form, weight: .regular))
                .foregroundStyle(Tokens.text1)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                aboutLink("classicals.de") {
                    LinkGate.shared.open(URL(string: "https://www.classicals.de")!)
                }
                aboutLink("CC BY 4.0") {
                    LinkGate.shared.open(URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                }
            }

            Text(L("about.thinkingOrbs"))
                .font(.sf(Tokens.TypeSize.form, weight: .regular))
                .foregroundStyle(Tokens.text1)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                aboutLink("thinking-orbs") {
                    LinkGate.shared.open(URL(string: "https://github.com/Jakubantalik/thinking-orbs")!)
                }
                aboutLink("MIT License") {
                    LinkGate.shared.open(URL(string: "https://opensource.org/license/mit")!)
                }
            }

            // The two answer-gallery interactions (the fanning image stack and
            // the image modal it opens into) are ports of Interaction Kit's web
            // components — the geometry, springs and thresholds are theirs.
            Text(L("about.interactionKit"))
                .font(.sf(Tokens.TypeSize.form, weight: .regular))
                .foregroundStyle(Tokens.text1)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                aboutLink("Interaction Kit") {
                    LinkGate.shared.open(URL(string: "https://interactionkit.org")!)
                }
                aboutLink("MIT License") {
                    LinkGate.shared.open(URL(string: "https://opensource.org/license/mit")!)
                }
            }
        }
    }

    private enum AboutSocialKind {
        case github, x, discord
    }

    /// The site's Star button translated to native SwiftUI: on hover the brand
    /// mark exits through the top while the action glyph rises from below. X
    /// uses the same grammar with X's own like-heart red, and Discord with a
    /// pair of chat bubbles in its blurple, so the three feel related without
    /// adding decorative particles around any of the marks.
    private struct AboutSocialButton: View {
        let kind: AboutSocialKind
        let title: String
        let action: () -> Void

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
        @State private var hovering = false

        private var accent: Color {
            switch kind {
            case .github: Color(red: 245 / 255, green: 166 / 255, blue: 35 / 255)
            case .x: Color(red: 249 / 255, green: 24 / 255, blue: 128 / 255)
            case .discord: Color(red: 88 / 255, green: 101 / 255, blue: 242 / 255)
            }
        }

        var body: some View {
            Button(action: action) {
                let shape = Capsule(style: .continuous)
                HStack(spacing: 9) {
                    ZStack {
                        brandMark
                            .foregroundStyle(Tokens.text2)
                            .opacity(hovering ? 0 : 1)
                            .offset(y: reduceMotion ? 0 : (hovering ? -13 : 0))
                            .scaleEffect(reduceMotion ? 1 : (hovering ? 0.8 : 1))

                        actionMark
                            .opacity(hovering ? 1 : 0)
                            .offset(y: reduceMotion ? 0 : (hovering ? 0 : 13))
                            .scaleEffect(reduceMotion ? 1 : (hovering ? 1 : 0.8))

                    }
                    .frame(width: 17, height: 17)

                    Text(title)
                        .font(.sf(Tokens.TypeSize.label, weight: .regular))
                        .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 13)
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
                .background(shape.fill(Tokens.ink.opacity(hovering ? 0.075 : 0.04)))
                .overlay(shape.strokeBorder(Tokens.ink.opacity(hovering ? 0.18 : 0.10), lineWidth: 0.5))
                .clipShape(shape)
                .contentShape(shape)
            }
            .buttonStyle(.plain).exemptsDoubleClickPin()
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        }

        @ViewBuilder
        private var brandMark: some View {
            switch kind {
            case .github:
                Image("GitHubMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            case .x:
                Image("XMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            case .discord:
                Image("DiscordMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 17, height: 17)
            }
        }

        /// What rises from below on hover: the glyph of the action itself.
        @ViewBuilder
        private var actionMark: some View {
            switch kind {
            case .github:
                Image(icon: "star.fill")
                    .font(.sf(Tokens.TypeSize.form, weight: .regular))
                    .foregroundStyle(accent)
            case .x:
                // heart.fill sits smaller in its box than star.fill at the same
                // point size, so it takes a notch more to read equal.
                Image(icon: "heart.fill")
                    .font(.sf(Tokens.TypeSize.reading, weight: .regular))
                    .foregroundStyle(accent)
            case .discord:
                Image(icon: "bubble.left.and.bubble.right.fill")
                    .font(.sf(Tokens.TypeSize.label, weight: .regular))
                    .foregroundStyle(accent)
            }
        }
    }

    private struct AboutSocialPressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .exemptsDoubleClickPin(pressed: configuration.isPressed)
                .scaleEffect(configuration.isPressed ? Tokens.chipPressScale : 1)
                .animation(Tokens.chipPressSpring, value: configuration.isPressed)
        }
    }

    /// One of the four secondary About destinations: one action per row,
    /// grouped together underneath the social row.
    private struct AboutUtilityButton: View {
        let title: String
        let leaves: Bool
        let action: () -> Void

        @State private var hovering = false
        @Environment(\.settingsWindowPaneHeight) private var windowPane

        var body: some View {
            Button(action: action) {
                HStack(spacing: 8) {
                    // In the window these are rows like the pane's others: row
                    // label size, full ink. Gray rows there read as disabled.
                    Text(title)
                        .font(.sf(windowPane != nil ? SettingsType.label + 1 : Tokens.TypeSize.meta,
                                  weight: .regular))
                        .foregroundStyle(windowPane != nil || hovering ? Tokens.text1 : Tokens.text3)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(icon: leaves ? "arrow.up.right" : "chevron.right")
                        .font(.sf(Tokens.TypeSize.badge, weight: .regular))
                        .foregroundStyle(Tokens.text4)
                        .opacity(hovering ? 1 : 0.6)
                }
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, minHeight: 33, maxHeight: 33)
                .background(Tokens.ink.opacity(hovering ? 0.05 : 0))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).exemptsDoubleClickPin()
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
        }
    }

    /// The social buttons' capsule across the whole row, lit one step brighter
    /// than they rest, with the credit it is worth as a `ModelDetailCard.Tag`.
    /// Without an action it is a status line and does not answer the pointer.
    private struct AboutSurveyRow: View {
        let title: String
        let tag: String
        let action: (() -> Void)?

        @State private var hovering = false

        var body: some View {
            Button { action?() } label: {
                HStack(spacing: 9) {
                    Image(icon: "checklist")
                        .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                        .foregroundStyle(Tokens.text1)
                        .frame(width: 17, height: 17)
                    Text(title)
                        .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                        .foregroundStyle(Tokens.text1)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    NewBadge(text: tag, tracking: 0)
                }
                .padding(.leading, 13)
                .padding(.trailing, 9)
                .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
                .background(Capsule(style: .continuous).fill(Tokens.ink.opacity(hovering ? 0.11 : 0.075)))
                .overlay(Capsule(style: .continuous).strokeBorder(Tokens.ink.opacity(hovering ? 0.22 : 0.16), lineWidth: 0.5))
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(AboutSocialPressStyle())
            .disabled(action == nil)
            .onHover { inside in
                guard action != nil else { return }
                hovering = inside
                if inside { Haptics.alignment() }
            }
            .animation(.easeInOut(duration: 0.2), value: hovering)
        }
    }

    /// The colophon link under the rail: the rows' hover grammar (quiet text
    /// brightening to text1) with none of their chrome — no row height, no
    /// chevron — so it reads as a footnote rather than a fifth action.
    private struct AboutFootnoteLink: View {
        let title: String
        let action: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                    .foregroundStyle(hovering ? Tokens.text1 : Tokens.text4)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).exemptsDoubleClickPin()
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
        }
    }

    /// Play the first-run intro again from About. The once-ever flag is left
    /// untouched — this is an on-demand replay, not an onboarding reset.
    private func replayIntro() {
        let display = model.activeDisplay
        let screen = NSScreen.screens.first { $0.displayID == display } ?? NSScreen.main
        guard let screen else { return }
        model.fullClose()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            NSApp.activate(ignoringOtherApps: true)
            IntroAnimation.shared.play(on: screen) {
                withAnimation(.spring(response: 0.46, dampingFraction: 0.78)) {
                    model.mode = .idle
                    model.openPanel(on: screen.displayID)
                }
            }
        }
    }

    private func aboutLink(_ title: String, weight: Font.Weight = .medium,
                           action: @escaping () -> Void) -> some View {
        AboutTextLink(title: title, weight: weight, action: action)
    }

    /// The quiet text-link species used throughout About. It stays visually light,
    /// but unlike inert body copy it answers the pointer.
    private struct AboutTextLink: View {
        let title: String
        let weight: Font.Weight
        let action: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(title, action: action)
                .buttonStyle(.plain).exemptsDoubleClickPin()
                .font(.sf(Tokens.TypeSize.label, weight: weight))
                .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        }
    }

    private var footer: some View {
        Group {
            if envOverride {
                Text(L("model.footer.env", keyScope.envVarName))
            } else {
                Text(footerText)
            }
        }
        .font(.sf(Tokens.TypeSize.meta))
        .foregroundStyle(Tokens.text3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2)
    }

    /// Footer help with the signup host as a clickable link, built as an
    /// `AttributedString` so the sentence stays one `Text` while only the host
    /// opens the signup page. Scoped to the key section's provider — it explains
    /// the key field above it. The pre/post fragments are localized; the host
    /// itself is the literal domain, so it stays the same in every language.
    private var footerText: AttributedString {
        if keyScope == .openrouter {
            // The free-by-default story: connect once, the key lives in the
            // user's own account, and the daily cap is theirs alone.
            var text = AttributedString(L("model.footer.openrouter.pre"))
            var host = AttributedString("openrouter.ai")
            host.link = URL(string: "https://openrouter.ai")
            host.foregroundColor = Tokens.text2
            text.append(host)
            text.append(AttributedString(L("model.footer.openrouter.post")))
            return text
        }
        // The custom endpoint has no key console to link to — the footer explains
        // what the fields above accept, and that the key is optional.
        if keyScope == .custom { return AttributedString(L("model.custom.footer")) }
        var text = AttributedString(L("model.footer.byok.pre"))
        var host = AttributedString(keyScope.signupHost)
        host.link = keyScope.signupURL
        host.foregroundColor = Tokens.text2
        text.append(host)
        text.append(AttributedString(L("model.footer.byok.post")))
        return text
    }

    // MARK: - Row scaffold

    /// A label-on-the-left, control-on-the-right row, sized so the provider and
    /// model menus line up. Pass `info` and it becomes the second line under the
    /// label, in quieter ink, instead of a ⓘ that has to be clicked.
    ///
    /// `aligned` opts the row into the pane's shared label column: it reports its
    /// natural label width up through `LabelColumnWidthKey` and takes the widest
    /// one back, so every control in the pane starts at the same x. Off by
    /// default — panes whose rows nest (`keySection`, `permissionsSection`) keep
    /// self-sizing labels.
    ///
    /// The measurement and the width are deliberately on DIFFERENT views: the
    /// label LINE stays `fixedSize()` and is what gets measured, the resolved
    /// column width is applied to a wrapper around it. Reporting from the same
    /// view the frame sizes would feed the preference back into itself and
    /// oscillate.
    private func settingRow<Content: View>(
        label: String,
        info: String? = nil,
        richInfo: AttributedString? = nil,
        aligned: Bool = false,
        tag: String? = nil,
        verticalAlignment: VerticalAlignment = .center,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        // Label on the left, control on the right edge of the pane, in every row.
        HStack(alignment: verticalAlignment, spacing: 12) {
            settingLabel(label, info: info, richInfo: richInfo, aligned: aligned, tag: tag)
            Spacer(minLength: 0)
            content()
        }
    }

    /// The label half of a setting line, extracted so the rows that don't use
    /// `settingRow`'s layout (the placement cards) can still sit in the column.
    /// The label takes the first line; the note, when there is one, the second.
    private func settingLabel(
        _ label: String,
        info: String? = nil,
        richInfo: AttributedString? = nil,
        aligned: Bool = false,
        tag: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.labelNoteSpacing) {
            HStack(spacing: 3) {
                Text(label)
                    .modifier(SettingsTypeFont(size: SettingsType.label))
                    .foregroundStyle(Tokens.text1)
                    .lineLimit(1)
                    .fixedSize()
                if let tag {
                    NewBadge(text: tag, tint: Tokens.text2)
                        .padding(.leading, 3)
                }
            }
            .fixedSize()
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: LabelColumnWidthKey.self,
                                           value: aligned ? g.size.width : 0)
                }
            )
            if let richInfo {
                SettingInfo(richInfo)
            } else if let info {
                SettingInfo(info)
            }
        }
        .frame(minWidth: 64, alignment: .leading)
        // `minWidth`, not `width`: the column is a floor, never a clamp. A hard
        // width pins the label to a number that can briefly be too small for it
        // — the pane's own measurement lands a frame late, and a language switch
        // relengthens every label before the max catches up — and the text
        // inside is `fixedSize`, so it doesn't shrink or truncate, it overflows
        // its frame straight across the control next to it. As a floor the row
        // just sits at its natural width for that frame. Steady state is
        // identical: the column IS the widest natural label, so every row is
        // exactly it.
        // `nil` keeps the row at its own width until the first measurement.
        .modifier(LabelColumnFloor(aligned: aligned))
    }

    /// Applies the pane's label column (`settingsLabelColumn`) as a minimum
    /// width. Read from the environment rather than `labelColumnWidth`
    /// directly: a pane leaving on a switch is still laid out for the length of
    /// its transition, and with the live state it took the incoming pane's
    /// column — Appearance under Chat's longer labels came out ~30pt wider
    /// than the panel and pushed both columns left.
    private struct LabelColumnFloor: ViewModifier {
        var aligned: Bool
        @Environment(\.settingsLabelColumn) private var column

        func body(content: Content) -> some View {
            content.frame(minWidth: aligned && column > 0 ? column : nil,
                          alignment: .leading)
        }
    }

    // MARK: - Logic

    /// Fetch the *current* provider's live model list into `ModelCatalogStore`, so the
    /// picker shows what the vendor serves right now for the provider in effect.
    /// Keyless providers keep their bundled shortlist (the picker falls back to
    /// `availableModels`). Cheap and cancel-safe — `ModelCatalog.fetch` caches per
    /// provider+key for an hour, so this doesn't re-hit the network unless the key
    /// changed or the cache actually expired.
    @MainActor
    private func refreshModels() async {
        let target = provider
        // Curated manifest first (no-op when fresh): keyless providers still get
        // the hot-updated bundled shortlist through `availableModels`.
        await RemoteModelManifest.refreshIfDue()
        guard target == provider else { return }
        // The custom endpoint fetches on its URL alone — its key is optional, and
        // its `/v1/models` is where its model ids have to come from.
        let optionalKey = target == .custom && CustomProvider.chatEndpoint != nil
        guard let key = APIKeyStore.current(for: target)
                ?? (optionalKey ? "" : nil) else { return }
        loadingModels = true
        let live = await ModelCatalog.fetch(for: target, apiKey: key)
        // Stop the spinner unconditionally — the staleness guard below returns
        // early after a mid-fetch provider switch and would strand it spinning.
        loadingModels = false
        // Guard against a stale response after the user switched providers.
        guard target == provider else { return }
        if let live { catalog.adopt(live, for: target) }
    }

    // MARK: - Cross-provider picker

    /// A key just landed for `p`. When `p` is the provider the Provider row names,
    /// it was chosen there and left inactive only for want of a key — make it the
    /// active backend now.
    private func activateIfShown(_ p: Provider) {
        guard p == provider, ModelCatalogStore.ready(p) else { return }
        APIKeyStore.selectedProvider = p
        notchiActive = false
    }

    /// Pick a model: point this pane at its provider (`selectProvider` re-syncs
    /// every provider-scoped row), make it the active backend, and save the model.
    /// Callers only pass a provider that can answer — a keyless model goes
    /// through the pending flow and lands here once its key is saved.
    private func selectAcrossProviders(provider newProvider: Provider, model id: String) {
        pendingModel = nil   // any committed pick settles the pending ask
        if newProvider != provider {
            // `selectProvider` resets `modelID` to that provider's stored model;
            // override it with the id the user actually clicked.
            selectProvider(newProvider)
        }
        APIKeyStore.selectedProvider = newProvider
        modelID = id
        APIKeyStore.saveModel(id, for: newProvider)
        // The custom endpoint's Model ID field is another view of the same stored
        // value — keep it in step when the pick came from the picker.
        if newProvider == .custom { customModel = id }
        // An explicit pick is a "recently used" model from the user's point of
        // view — record it so the Ask chip's quick menu keeps it after the
        // selection moves on.
        AskModelMRU.record(provider: newProvider, model: id)
        NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
    }

    /// Probe the *stored* key of the key section's provider and surface the
    /// verdict. Test is only offered once a key is saved, so it always checks
    /// what's on disk — never an unsaved draft. Guarded via `canTest`.
    private func test() {
        // A custom field still inside its save delay is saved first, so Test
        // probes what is on screen.
        if keyScope == .custom, canSaveCustom { saveCustom() }
        guard canTest else { return }
        let target = keyScope
        let key = APIKeyStore.current(for: target) ?? APIKeyStore.stored(for: target)
        testing = true
        testResult = nil
        Task {
            let result = await ConnectivityTest.run(provider: target, apiKey: key)
            await MainActor.run {
                // Drop a stale result if the user retargeted the section mid-flight.
                guard target == keyScope else { return }
                testing = false
                withAnimation(.easeOut(duration: 0.2)) { testResult = result }
            }
        }
    }

    /// Persist the key being edited for the key section's provider. When that key
    /// was blocking a picked model (the pending flow), the pick commits here —
    /// paste, save, and the model you asked for is live.
    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard editingKey, !trimmed.isEmpty else { return }
        APIKeyStore.save(apiKey, for: keyScope)
        apiKey = APIKeyStore.stored(for: keyScope)
        withAnimation(.easeOut(duration: 0.16)) { editingKey = false }
        withAnimation(.easeOut(duration: Tokens.hoverFade)) { saved = true }
        if let pending = pendingModel, pending.provider == keyScope {
            selectAcrossProviders(provider: pending.provider, model: pending.id)
        } else {
            activateIfShown(keyScope)
            NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
        }
        // A newly-saved key may unlock the live model list — refresh it.
        Task { await refreshModels() }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(.easeOut(duration: 0.3)) { saved = false }
        }
    }
}

/// The prompt editor's two closing actions: fully rounded — the same capsule
/// every other affordance on the island wears. `primary` is the island's own
/// glass; `destructive` carries no resting
/// surface at all, so ending the shortcut never reads as loud as finishing the
/// edit — it only takes a whisper of red under the pointer.
private struct PromptCardActionStyle: ButtonStyle {
    enum Kind { case primary, destructive }
    var kind: Kind

    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        Group {
            switch kind {
            case .primary:
                configuration.label
                    .exemptsDoubleClickPin(pressed: configuration.isPressed)
                    .glassCapsule(in: Capsule(style: .continuous), brighter: hovering)
            case .destructive:
                configuration.label
                    .exemptsDoubleClickPin(pressed: configuration.isPressed)
                    .background(Capsule(style: .continuous).fill(
                        Tokens.danger.opacity(hovering ? 0.13 : 0)))
            }
        }
        .contentShape(Capsule(style: .continuous))
        .opacity(kind == .destructive && configuration.isPressed ? 0.72 : 1)
        .scaleEffect(kind == .primary && configuration.isPressed ? Tokens.chipPressScale : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        .animation(Tokens.chipPressSpring, value: configuration.isPressed)
    }
}

/// The trailing chips in the Shortcuts pane — chord recorders, reset, add. Fully
/// rounded like every other affordance on the island (`PanelBackPill`), and they
/// answer the pointer: wash and hairline brighten on hover, the same easeOut fade
/// every hover on the panel uses. Recording keeps its own brighter, ringed state,
/// which outranks hover so an armed chip never dims when the pointer leaves.
private struct ShortcutChipStyle: ButtonStyle {
    /// The armed / recording chip: brighter wash and a full-weight ring.
    var active: Bool = false
    /// Resting wash and hairline, for chips that sit quieter than a chord (reset).
    var rest: Double = 0.06
    var restStroke: Double = 0.12

    @State private var hovering = false

    private var shape: Capsule { Capsule(style: .continuous) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .exemptsDoubleClickPin(pressed: configuration.isPressed)
            .background(
                shape.fill(Tokens.ink.opacity(
                    active ? 0.12 : (hovering ? rest + 0.05 : rest)))
            )
            .overlay(
                shape.strokeBorder(
                    Tokens.ink.opacity(active ? 0.45 : (hovering ? restStroke + 0.10 : restStroke)),
                    lineWidth: active ? 1 : 0.5)
            )
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? Tokens.chipPressScale : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
            .animation(Tokens.chipPressSpring, value: configuration.isPressed)
    }
}

/// Backs the quick-tools popover with the panel's glass instead of the stock light
/// popover chrome. On macOS 13.3+ it replaces the presentation background itself
/// (so no light rim shows around the edges); older systems get the glass painted
/// behind the content as a graceful fallback.
struct GlassPopoverBackground: ViewModifier {
    /// Corner radius of the glass slab — matches the content it wraps (small list
    /// popovers use the in-panel control radius).
    var cornerRadius: CGFloat = Tokens.Radius.control
    /// The smoked veil painted over the bare glass. The default (0.42) composites
    /// with the 0.34 baked tint to the panel's dark register (~0.62), so an occluding
    /// popover reads as solid material. A lower value lets far more of the liquid-glass
    /// refraction through — the airy, transparent Control-Center look — for cards that
    /// want to read as glass rather than a slab (e.g. the ⌘⇧I model picker).
    var veilOpacity: Double = 0.42
    /// Overrides the darkening baked into the glass material itself (default
    /// `GlassMaterial.bakedTint` = 0.34). The airy picker cards want to read as
    /// near-clear Liquid Glass, and the baked 0.34 is a *floor* on how transparent
    /// the card can get — no amount of lowering `veilOpacity` goes below it. Passing
    /// a lower tint (with `veilOpacity` at 0) lets the wallpaper refract through far
    /// more strongly than the standard occluding popover.
    var glassTint: Double = GlassMaterial.bakedTint

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // `nativeGlass` for the liquid refraction, PLUS a smoked veil bringing the
        // composite to the panel's own dark register (~0.62, the same number the
        // tooltip wafer and the panel's top band use). Bare glass composites to
        // only ~0.34 — a popover hangs over arbitrary windows, and at 0.34 the
        // text underneath stays legible *through* the card, reading as mud rather
        // than material. The veil is what makes it occlude like every other
        // floating layer in the app. (0.42 over the 0.34 baked tint ≈ 0.62.)
        //
        // The two touches that make it read as *glass* rather than a flat dark
        // board — the whole point of an airy card like the ⌘⇧I picker:
        //  · a soft top-down **sheen**, light pooling on the upper face, and
        //  · a directional **specular rim** — bright along the top edge, fading
        //    down the sides — the island's / detached card's edge idiom.
        // A flat, even hairline read as a drawn outline; the lit gradient edge
        // reads as the caught light on the rim of a real glass slab.
        let slab = ZStack {
            shape.fill(.clear).nativeGlass(in: shape, tintOpacity: glassTint)
                .overlay(shape.fill(Color.black.opacity(veilOpacity)))
            shape
                .fill(LinearGradient(colors: [.white.opacity(0.12), .clear],
                                     startPoint: .top, endPoint: .center))
                .blendMode(.plusLighter)
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.08)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75)
        }

        // The slab is dark glass in either system appearance, so its text
        // stays on the dark ink even when the Settings window is light.
        if #available(macOS 13.3, *) {
            content.environment(\.colorScheme, .dark).presentationBackground { slab }
        } else {
            content.environment(\.colorScheme, .dark).background { slab }
        }
    }
}

/// Inline ghost button for row actions — Save / Test / Change / Cancel /
/// Disconnect / Choose…. Quiet at rest, reveals a subtle rounded surface on hover.
struct SettingActionButton: View {
    var title: String
    /// Rest ink. Defaults to the secondary register; a de-emphasised action (a
    /// settled "Saved", a Save with nothing to save) passes something quieter.
    var tone: Color = Tokens.text2
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var shape: Capsule { Capsule(style: .continuous) }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain).exemptsDoubleClickPin()
            .font(.sf(Tokens.TypeSize.meta, weight: .regular))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(hovering && isEnabled ? Tokens.text1 : tone)
            .padding(.horizontal, 8)
            .frame(height: SettingsUI.heightSM)
            .background(shape.fill(Tokens.ink.opacity(hovering && isEnabled ? 0.08 : 0)))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

/// A dollar amount, set by two buttons around the figure.
///
/// Modelled on the pill controls this pane already uses — a recessed capsule at
/// the same 30pt height as the action buttons beside it — rather than AppKit's
/// `Stepper`, whose two stacked arrows are half the height of everything around
/// them and carry the system's own chrome into a pane that has none.
///
/// The increment is not fixed. A flat $1 step makes $200 forty clicks away, and
/// a flat $10 step cannot express the $1 minimum; so it widens with the figure,
/// which is how anyone would count money out loud.
struct AmountStepper: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    /// When set, the recessed wash follows this instead of the view's own hover.
    /// The model detail card pushes it in: `onHover` is dead beside a tracking menu.
    var lit: Bool? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    /// The minus/plus hit strip. The model detail card splits its probed frame
    /// with this so a swallowed native-menu click can still nudge.
    static let buttonWidth: CGFloat = 30

    /// The step at a given figure — and, going down, the step that got you
    /// there. Without the second reading, $10 steps up by $5 and back down by
    /// $1, and the control cannot return to where it just was.
    private static func step(at amount: Double, down: Bool) -> Double {
        let reference = down ? amount - 0.01 : amount
        if reference < 10 { return 1 }
        if reference < 50 { return 5 }
        return 10
    }

    /// Same nudge the buttons run, for a click that never reaches the buttons.
    static func nudged(_ value: Double, by direction: Double,
                       range: ClosedRange<Double>) -> Double {
        let delta = step(at: value, down: direction < 0) * direction
        return min(range.upperBound, max(range.lowerBound, (value + delta).rounded()))
    }

    private func nudge(_ direction: Double) {
        value = Self.nudged(value, by: direction, range: range)
    }

    var body: some View {
        HStack(spacing: 0) {
            button("minus", enabled: value > range.lowerBound) { nudge(-1) }
            Text(InlineSettingsView.money(value))
                .font(.brand(13))
                .foregroundStyle(Tokens.text1)
                .frame(width: 54, alignment: .center)
                // The same digit roll the Stats figures and the island's running
                // chip use. The animation has to ride the Text for
                // `numericText` to fire; on the enclosing stack it only moves
                // the layout, and one string cuts to another.
                .contentTransition(.numericText(value: value))
                .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: value)
            button("plus", enabled: value < range.upperBound) { nudge(1) }
        }
        .frame(height: 30)
        .recessedSurface(in: Capsule(style: .continuous), lit: lit ?? hovering)
        .contentShape(Capsule(style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: lit ?? hovering)
    }

    private func button(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(icon: symbol)
                .font(.sf(Tokens.TypeSize.label, weight: .regular))
                .foregroundStyle(enabled ? Tokens.text2 : Tokens.text4)
                .frame(width: Self.buttonWidth, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).exemptsDoubleClickPin()
        .disabled(!enabled)
    }
}

/// Settings' type ladder. Three steps, told apart by size and ink rather than
/// weight: a group heading names the run of rows under it, a row label names the
/// control, and a row's description sits on the line under the label in quieter,
/// smaller ink.
private enum SettingsType {
    static let heading: CGFloat = 13
    static let label: CGFloat = 12
    static let description: CGFloat = 11
    static let caption: CGFloat = 10
}

/// A step of `SettingsType`, one point larger in the Settings window. The
/// window is several times the panel's area, and at the panel's sizes its rows
/// read as small text spread over a large surface.
private struct SettingsTypeFont: ViewModifier {
    var size: CGFloat
    var panelWeight: Font.Weight = .regular
    var windowWeight: Font.Weight = .regular
    @Environment(\.settingsWindowPaneHeight) private var windowPane

    func body(content: Content) -> some View {
        let inWindow = windowPane != nil
        return content.font(.sf(size + (inWindow ? SettingsMetrics.window.typeBump : 0),
                                weight: inWindow ? windowWeight : panelWeight))
    }
}

private extension View {
    /// A group heading: larger than a row label, dimmer than it, and always
    /// sentence case — the app's copy is written that way.
    func settingsHeading(_ color: Color = Tokens.text2) -> some View {
        modifier(SettingsTypeFont(size: SettingsType.heading, windowWeight: .medium))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A table or column label inside Settings: the smallest step.
    func settingsCaption(_ color: Color = Tokens.text3) -> some View {
        font(.sf(SettingsType.caption, weight: .regular))
            .tracking(0.3)
            .foregroundStyle(color)
    }

    /// A row's explanation, on the second line under its label.
    func settingsDescription(_ color: Color = Tokens.text3) -> some View {
        modifier(SettingsTypeFont(size: SettingsType.description))
            .foregroundStyle(color)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Anchor a setting row for sidebar search scroll-to and draw a transient
    /// borderless light sweep when it is the active search destination.
    @ViewBuilder
    func searchTarget(_ key: String?, active: String?) -> some View {
        if let key {
            let lit = active == key
            self
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Tokens.ink.opacity(lit ? 0.11 : 0),
                                    Tokens.ink.opacity(lit ? 0.04 : 0),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .padding(.horizontal, -8)
                        .padding(.vertical, -5)
                        .allowsHitTesting(false)
                }
                .animation(.easeOut(duration: 0.35), value: lit)
                .id("search.\(key)")
        } else {
            self
        }
    }
}

/// A settings row's explanatory note. It used to be a ⓘ that opened a popover;
/// it is now the second line under the row's label, always visible, in the
/// description step of the settings ladder.
///
/// Takes either a plain string or a pre-built `AttributedString` (for hints with an
/// inline link). `glyph` and `hit` are kept for the few compact call sites that
/// still pass them; an inline line has no mark to size.
struct SettingInfo: View {
    private let plain: String?
    private let rich: AttributedString?
    var glyph: CGFloat = 12
    var hit: CGFloat = 20

    init(_ text: String, glyph: CGFloat = Tokens.TypeSize.label, hit: CGFloat = 20) {
        plain = text; rich = nil; self.glyph = glyph; self.hit = hit
    }
    init(_ text: AttributedString, glyph: CGFloat = Tokens.TypeSize.label, hit: CGFloat = 20) {
        plain = nil; rich = text; self.glyph = glyph; self.hit = hit
    }

    var body: some View {
        Group {
            if let rich { Text(rich) } else { Text(plain ?? "") }
        }
        .settingsDescription()
    }
}

/// `SettingInfo` for a note that is not a sentence — the Copy Sense engine
/// comparison, which is a grid. Same mark, same hover, same glass popover; only
/// the body and its width differ, so a table is not forced through a string.
struct SettingInfoPopover<Content: View>: View {
    var glyph: CGFloat = Tokens.TypeSize.label
    var hit: CGFloat = 20
    @ViewBuilder var content: () -> Content

    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(icon: "info.circle")
                .font(.sf(glyph, weight: .regular))
                .foregroundStyle(hovering ? Tokens.text2 : Tokens.text4)
                .frame(width: hit, height: hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).exemptsDoubleClickPin()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        .holdsPanelWhilePresented(showing)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            // No width of its own: the content sizes the popover. A cap here
            // clipped the widest column instead of wrapping it, so anything
            // that needs a ceiling (prose) sets its own.
            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .modifier(GlassPopoverBackground())
        }
    }
}

/// The balance card's ways into its sub-pages: underlined meta text, quiet
/// ink that brightens to text1 on hover. `external` adds the outbound arrow
/// used wherever a control leaves the app.
struct UnderlineLink: View {
    let title: String
    var external: Bool = false
    let action: () -> Void

    @State private var hovering = false

    /// One text run, so the underline is a single rule under the title and,
    /// when present, the outbound arrow.
    private var label: Text {
        let words = Text(title).font(.sf(Tokens.TypeSize.meta))
        guard external else { return words }
        let arrow = Text(Image(icon: "arrow.up.right"))
            .font(.sf(Tokens.TypeSize.badge, weight: .regular))
        return words + Text("\u{00A0}") + arrow
    }

    var body: some View {
        Button(action: action) {
            label
                .underline(hovering)
                .lineLimit(1)
                .foregroundStyle(hovering ? Tokens.text1 : Tokens.text3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).exemptsDoubleClickPin()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
    }
}

/// A secondary action button in Settings (`SettingsUI.controlRadius`, 28pt height).
private struct ChipLink: View {
    let title: String
    /// A Buy License chip: `LicenseChipSurface` instead of the plain fill.
    var license = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let shape = Capsule(style: .continuous)
        return Button(action: action) {
            Text(title)
                .font(.sf(Tokens.TypeSize.meta, weight: .regular))
                .foregroundStyle(Tokens.text1)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: SettingsUI.heightSM)
                .background {
                    if license {
                        Color.clear.licenseChipSurface(shape, hovered: hovering)
                    } else {
                        shape.fill(hovering ? Tokens.recessFillLit : Tokens.recessFill)
                    }
                }
                .overlay {
                    if !license {
                        shape.strokeBorder(hovering ? Tokens.recessRimLit : Tokens.recessRim, lineWidth: 0.5)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain).exemptsDoubleClickPin()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

/// What happens to a request paid from Notchi Balance — the Privacy sub-page,
/// behind the balance card's privacy link. Written the way What's New writes release
/// notes — a caption heading over short bulleted lines — because it is the same
/// kind of reading: separate facts, each scanned rather than read through.
/// One column, top to bottom, at What's New's 18pt between groups.
private struct NonoPrivacyNote: View {
    private static let flow = ["mac", "gateway", "network"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("stored", count: 4)
            group("sent", count: 5)
            group("route", flow: true)
            group("thirdParty", count: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func group(_ key: String, flow: Bool = false, count: Int = 3) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("nono.privacy.\(key).title"))
                .settingsHeading()
            if flow { flowLine }
            ForEach(1...count, id: \.self) { i in
                // The one fact that matters on this page: we don't keep the
                // prompt, the answer, or the files. Same weight What's New
                // uses for an emphasized bullet.
                bullet(L("nono.privacy.\(key).\(i)"),
                       emphasized: key == "stored" && i == 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Where a request goes, as a full-width strip of three equal stops —
    /// recessed plates, not the hairline version tag. The chevron is the
    /// About rows'.
    private var flowLine: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.flow.enumerated()), id: \.offset) { index, node in
                if index > 0 {
                    Image(icon: "chevron.right")
                        .font(.sf(Tokens.TypeSize.caption, weight: .regular))
                        .foregroundStyle(Tokens.text4)
                }
                Text(L("nono.privacy.route.flow.\(node)"))
                    .settingsCaption(Tokens.text1)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .recessedSurface(in: RoundedRectangle.control, lit: false)
            }
        }
    }

    /// What's New's `bulletLine`. The "we don't store your content" line is
    /// the one fact this page exists to make unmissable, so it takes the
    /// emphasized weight.
    private func bullet(_ text: String, emphasized: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(Tokens.text4)
                .frame(width: 3, height: 3)
                .padding(.top, 7)
            Text(text)
                .font(.sf(Tokens.TypeSize.label, weight: .regular))
                .lineSpacing(4)
                .foregroundStyle(emphasized ? Tokens.text1 : Tokens.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The face every picker chip on the pane wears: a recessed dark capsule with
/// the current value and an up/down chevron, brighter under the pointer. Its
/// menu is `GlassMenu`'s card.
struct GlassChipFace: View {
    var title: String
    var compact: Bool = false
    var logoVendor: String? = nil
    var logoFallback: String = ""
    var logoSymbol: String? = nil
    var aura: Bool = false
    var hovering: Bool

    typealias Metrics = (font: CGFloat, chevron: CGFloat, gap: CGFloat,
                         height: CGFloat, lead: CGFloat, trail: CGFloat,
                         logo: CGFloat)

    /// The compact fitting, one place: a 20pt pill that sits inside a 25pt bar.
    /// Its corner is always height/2 — fully round, the same capsule the effort
    /// slider's thumb and the compose row's chips use.
    static let compactMetrics: Metrics = (Tokens.TypeSize.meta, Tokens.TypeSize.badge, 5, 20, 10, 8, 12)
    static let regularMetrics: Metrics = (Tokens.TypeSize.label, Tokens.TypeSize.caption, 7, SettingsUI.heightMD, 11, 9, 15)

    private var metrics: Metrics { compact ? Self.compactMetrics : Self.regularMetrics }

    static func compactWidth(for title: String) -> CGFloat {
        let m = compactMetrics
        let font = NSFont.systemFont(ofSize: m.font, weight: .regular)
        let text = NSAttributedString(string: title, attributes: [.font: font]).size().width
        // text + gap + chevron glyph + both paddings
        return ceil(text) + m.gap + 10 + m.lead + m.trail
    }

    var body: some View {
        let m = metrics
        return HStack(spacing: m.gap) {
            if let logoVendor {
                VendorLogo(vendor: logoVendor, fallback: logoFallback,
                           symbol: logoSymbol)
                    .frame(width: m.logo, height: m.logo)
            }
            if !title.isEmpty {
                Text(title)
                    .font(.sf(m.font, weight: .regular))
                    .foregroundStyle(Tokens.text1)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Image(icon: "chevron.up.chevron.down")
                .font(.sf(m.chevron, weight: .regular))
                .foregroundStyle(Tokens.text3)
        }
        .padding(.leading, logoVendor != nil ? 10 : (title.isEmpty ? m.trail : m.lead))
        .padding(.trailing, m.trail)
        .frame(height: m.height)
        .recessedSurface(in: Capsule(style: .continuous), lit: hovering)
        .brandAura(in: Capsule(style: .continuous), active: aura)
        .contentShape(Capsule(style: .continuous))
    }
}

/// One row of a `GlassMenu`: a title, an optional tag image drawn after it, and
/// whether it is the value in effect. `header` starts a titled group above the
/// row.
struct GlassMenuItem {
    var title: String
    var tag: NSImage? = nil
    var selected: Bool = false
    var header: String? = nil
    /// Shown but not pickable.
    var disabled: Bool = false
    var action: () -> Void
}

extension View {
    /// Hang the glass menu card of `items` under this view while `open` is
    /// true. `title` is a caption above the rows.
    func glassMenuCard(open: Binding<Bool>, title: String? = nil,
                       items: [GlassMenuItem]) -> some View {
        modifier(GlassMenuCardHost(open: open, title: title, items: items))
    }
}

private struct GlassMenuCardHost: ViewModifier {
    @Binding var open: Bool
    var title: String?
    var items: [GlassMenuItem]

    func body(content: Content) -> some View {
        content
            .modifier(MenuCardWindow(
                open: open,
                onDismiss: { _ in open = false },
                card: {
                    AnyView(GlassMenuCard(title: title, items: items) { index in
                        open = false
                        guard items.indices.contains(index) else { return }
                        items[index].action()
                    })
                }))
            // The card hangs off the island in its own window, so the pointer
            // reaching a lower row reads as leaving the panel — hold the panel
            // for as long as the menu is up (see `InfoPopoverGate`).
            .holdsPanelWhilePresented(open)
    }
}

/// A picker chip in Settings. The chip is `GlassChipFace`; its menu is the
/// panel's glass menu card (`MenuCardWindow`), the same one the ⋯ and loop
/// menus use, in place of a system menu.
struct GlassMenu: View {
    var title: String
    var logoVendor: String? = nil
    var logoFallback: String = ""
    var logoSymbol: String? = nil
    var items: [GlassMenuItem]
    /// Run when the menu is opened, whether or not a row is picked — what marks
    /// a "New" badge beside it as read.
    var onOpen: (() -> Void)? = nil

    @State private var hovering = false
    @State private var open = false

    var body: some View {
        Button {
            if !open { onOpen?() }
            open.toggle()
        } label: {
            GlassChipFace(title: title, logoVendor: logoVendor,
                          logoFallback: logoFallback, logoSymbol: logoSymbol,
                          hovering: hovering || open)
        }
        .buttonStyle(.plain).exemptsDoubleClickPin()
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        .glassMenuCard(open: $open, items: items)
    }
}

/// The rows of a `GlassMenu`, on the menu card's slab. A long list scrolls
/// inside a fixed window of rows.
private struct GlassMenuCard: View {
    var title: String? = nil
    let items: [GlassMenuItem]
    let pick: (Int) -> Void

    /// Rows shown before the list scrolls.
    private static let maxRows = 10

    private var width: CGFloat {
        let rows: [(String, String?)] = items.map { item in
            // A tag takes about this much of the trailing slot.
            (item.title, item.tag == nil ? nil : "MMMMMM")
        }
        let headers: [(String, String?)] = (items.map(\.header) + [title]).compactMap { header in
            header.map { ($0, nil) }
        }
        return MenuCard.width(titles: rows + headers, max: 300)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: MenuCard.rowSpacing) {
            if let title {
                Text(title)
                    .settingsCaption(Tokens.text4)
                    .lineLimit(1)
                    .padding(.horizontal, MenuCard.rowPad)
                    .padding(.top, 4)
                    .padding(.bottom, 3)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if let header = item.header {
                    Text(header)
                        .settingsCaption(Tokens.text4)
                        .lineLimit(1)
                        .padding(.horizontal, MenuCard.rowPad)
                        .padding(.top, index == 0 ? 4 : 8)
                        .padding(.bottom, 3)
                }
                MenuCardRow(title: item.title,
                            emphasized: true,
                            selected: item.selected,
                            haptic: false,
                            action: { pick(index) })
                    .disabled(item.disabled)
                    .opacity(item.disabled ? 0.5 : 1)
                    .overlay(alignment: .trailing) {
                        if let tag = item.tag {
                            Image(nsImage: tag)
                                .padding(.trailing, MenuCard.rowPad)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
    }

    var body: some View {
        Group {
            if items.count > Self.maxRows {
                ScrollView { rows }
                    .scrollIndicators(.never)
                    .frame(height: CGFloat(Self.maxRows) * MenuCard.rowStride)
            } else {
                rows
            }
        }
        .padding(MenuCard.cardPad)
        .frame(width: width, alignment: .leading)
        .menuCardBackground()
    }
}

/// One choice drawn as a picture: a thumbnail, its name under it, and a native
/// Liquid Glass lens behind the thumbnail when it is the current choice. Every
/// picture picker in Settings uses this.
private struct PickerCard<Content: View>: View {
    let selected: Bool
    let label: String
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    static var thumbWidth: CGFloat { 96 }
    static var thumbHeight: CGFloat { 56 }

    @State private var hovering = false

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: Tokens.Radius.menu, style: .continuous)
        Button(action: action) {
            VStack(spacing: 6) {
                content()
                    .frame(width: Self.thumbWidth, height: Self.thumbHeight)
                    .background {
                        if selected {
                            cardShape.fill(.clear)
                                .glassCapsule(in: cardShape, brighter: true, rim: 1.25)
                        } else {
                            cardShape.fill(Tokens.ink.opacity(hovering ? 0.075 : 0.04))
                                .overlay(
                                    cardShape.strokeBorder(
                                        Tokens.ink.opacity(hovering ? 0.18 : 0.09),
                                        lineWidth: 0.5)
                                )
                        }
                    }
                Text(label)
                    .font(.sf(Tokens.TypeSize.meta, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Tokens.text1 : Tokens.text3)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlatePressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
        .animation(.easeOut(duration: Tokens.rowFade), value: selected)
        .accessibilityLabel(label)
    }
}

/// Centers a setting row's label on a detent slider's *track*, not on the whole
/// control. The control is a `VStack` of slider + tick labels, so both
/// `.center` and the default `.firstTextBaseline` leave the label sitting off
/// the track — visibly high against one slider, and inconsistent between two
/// stacked rows whose labels differ in height.
private enum SliderTrackAlignment: AlignmentID {
    static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
}

extension VerticalAlignment {
    static let sliderTrack = VerticalAlignment(SliderTrackAlignment.self)
}

/// A native `NSSlider` quantized to a fixed ladder of tick positions — the
/// "multi-segment" control behind the hover-sensitivity row and the Agent
/// card's thinking-strength dial. Nothing here draws: the stock AppKit control
/// keeps its own shape, tick marks and interaction animation. The representable
/// only hands it a plain host view and puts it at that host's local origin, so
/// its promoted Liquid Glass knob has no SwiftUI-origin offset to reconcile.
struct NativeDetentSlider: NSViewRepresentable {
    @Binding var value: Double
    /// Number of detents on the ladder (tick marks + the positions they mark).
    /// Two ticks are the minimum the system allows.
    let ticks: Int

    static let controlSize: NSControl.ControlSize = .regular

    /// The stock knob's width at `controlSize`, read from AppKit rather than
    /// hard-coded — but measured once at launch (`primeMetrics`), never from
    /// inside a view body. `-[NSSliderCell knobThickness]` drives an AppKit
    /// render pass, and taking that while SwiftUI is evaluating a body re-enters
    /// the view graph and trips an AttributeGraph precondition — a hard crash on
    /// opening Settings → Appearance, where the first slider is built. The
    /// measured `.regular` width stands in until the probe runs.
    /// Only trustworthy off an unlaid-out slider for `.regular` (`.small`
    /// reports 18 here but draws 10) — recheck against a rendered control
    /// before changing `controlSize`.
    private(set) static var knobWidth: CGFloat = 20

    /// Measure the stock knob off the view-update path. Called once from
    /// `applicationDidFinishLaunching`, before any settings pane can render.
    static func primeMetrics() {
        let probe = NSSlider()
        probe.controlSize = controlSize
        knobWidth = probe.knobThickness
    }

    /// Normalized x of each detent inside a control `width` points wide. The end
    /// detents rest half a knob in from the edges, and AppKit draws its tick
    /// marks on those rest positions — so a label row lines up with the marks by
    /// following these, not an equal-width split of the control.
    static func tickFractions(count: Int, width: CGFloat) -> [CGFloat] {
        guard count > 1, width > knobWidth else {
            return (0..<count).map { CGFloat($0) / CGFloat(Swift.max(count - 1, 1)) }
        }
        let step = (width - knobWidth) / CGFloat(count - 1)
        return (0..<count).map { (knobWidth / 2 + CGFloat($0) * step) / width }
    }

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    func makeNSView(context: Context) -> SliderHostView {
        let slider = NSSlider(value: value,
                              minValue: 0,
                              maxValue: Double(ticks - 1),
                              target: context.coordinator,
                              action: #selector(Coordinator.valueChanged(_:)))
        slider.sliderType = .linear
        slider.numberOfTickMarks = ticks
        slider.tickMarkPosition = .below
        slider.allowsTickMarkValuesOnly = true
        slider.altIncrementValue = 1
        slider.isContinuous = true
        // `.regular` is the wide-and-flat system knob (20 x 16); `.small` draws
        // a narrow vertical pill (10 x 18) that reads as a different control.
        slider.controlSize = Self.controlSize
        // The one appearance override: every other control in this panel is
        // tinted `Tokens.text2`, so the fill stays monochrome instead of
        // becoming the panel's lone accent-blue element.
        slider.trackFillColor = NSColor.white.withAlphaComponent(0.55)
        return SliderHostView(slider: slider)
    }

    func updateNSView(_ host: SliderHostView, context: Context) {
        let slider = host.slider
        context.coordinator.value = $value
        if slider.numberOfTickMarks != ticks {
            slider.numberOfTickMarks = ticks
            slider.maxValue = Double(ticks - 1)
        }
        let maximum = Double(ticks - 1)
        if value > maximum { value = maximum }
        if slider.doubleValue != value { slider.doubleValue = value }
    }

    /// A neutral AppKit frame owner between SwiftUI and `NSSlider`. The slider's
    /// frame is always `(0, 0, bounds.width, bounds.height)`, so its promoted
    /// interaction layer has no SwiftUI-origin offset to add or omit.
    final class SliderHostView: NSView {
        let slider: NSSlider

        init(slider: NSSlider) {
            self.slider = slider
            super.init(frame: .zero)
            addSubview(slider)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override var intrinsicContentSize: NSSize { slider.intrinsicContentSize }

        override func layout() {
            super.layout()
            slider.frame = bounds
        }
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) { self.value = value }

        @objc func valueChanged(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue
        }
    }
}

/// A Phosphor glyph on a picker card; a dimmed one is the thing the choice
/// leaves out.
private struct PickerGlyph: View {
    let mark: PhosphorIcons.Mark
    var dimmed = false

    var body: some View {
        PhosphorIcon(mark: mark, size: 26)
            .foregroundStyle(Tokens.text1.opacity(dimmed ? 0.28 : 0.85))
    }
}

/// SwiftUI's `DragGesture` covers click-and-drag, but a two-finger horizontal
/// trackpad swipe reaches AppKit as scroll-wheel events. Keep that second native
/// path local to the hovered Cover Flow so the modal's other controls and the
/// rest of Settings retain their normal scrolling behavior.
private struct PromptTemplateCoverflowScrollMonitor: NSViewRepresentable {
    var active: Bool
    var onDelta: (CGFloat) -> Void
    var onEnd: () -> Void
    var onStep: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.active = active
        context.coordinator.onDelta = onDelta
        context.coordinator.onEnd = onEnd
        context.coordinator.onStep = onStep
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.active = active
        context.coordinator.onDelta = onDelta
        context.coordinator.onEnd = onEnd
        context.coordinator.onStep = onStep
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        var active = false {
            didSet {
                guard !active else { return }
                trackingHorizontal = false
                swallowingMomentum = false
            }
        }
        var onDelta: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        var onStep: ((Int) -> Void)?

        private var monitor: Any?
        private var trackingHorizontal = false
        private var swallowingMomentum = false

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard active else { return event }

            let deltaX = event.scrollingDeltaX
            let horizontal = abs(deltaX) > abs(event.scrollingDeltaY)

            // Mouse wheels have no gesture phases. A horizontal wheel nudge is
            // one discrete page, matching the reference component's side-card
            // navigation rather than accumulating an invisible fractional drag.
            if event.phase == [], event.momentumPhase == [] {
                guard horizontal, abs(deltaX) > 1 else { return event }
                onStep?(deltaX < 0 ? 1 : -1)
                return nil
            }

            // The fingers' real travel already determines the snap. Swallow the
            // inertial tail so it cannot page again after the rail has settled.
            if event.momentumPhase != [] {
                guard swallowingMomentum || trackingHorizontal else { return event }
                if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                    swallowingMomentum = false
                }
                return nil
            }

            switch event.phase {
            case .began:
                guard horizontal else { return event }
                trackingHorizontal = true
                swallowingMomentum = false
                if deltaX != 0 { onDelta?(deltaX) }
                return nil

            case .ended, .cancelled:
                guard trackingHorizontal else { return event }
                trackingHorizontal = false
                swallowingMomentum = true
                onEnd?()
                return nil

            default:
                guard trackingHorizontal || horizontal else { return event }
                trackingHorizontal = true
                if horizontal, deltaX != 0 { onDelta?(deltaX) }
                return nil
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            trackingHorizontal = false
            swallowingMomentum = false
        }

        deinit { remove() }
    }
}

/// An invisible helper that captures the next key chord while `active` is true.
/// Installs a local `.keyDown` monitor (scoped to this app's own key window, so
/// it can't see other apps' input) and hands the virtual key code + modifier
/// flags to `onCapture`. Swallowing the event while recording keeps Esc/Space
/// from leaking into the panel underneath. The monitor is torn down the moment
/// `active` flips false or the view disappears — no global tap, no leak.
private struct HotKeyRecorder: NSViewRepresentable {
    var active: Bool
    var onCapture: (UInt32, NSEvent.ModifierFlags) -> Void
    var onDoubleModifier: (UInt32) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onCapture = onCapture
        context.coordinator.onDoubleModifier = onDoubleModifier
        context.coordinator.onCancel = onCancel
        return NSView(frame: .zero)
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.onCapture = onCapture
        context.coordinator.onDoubleModifier = onDoubleModifier
        context.coordinator.onCancel = onCancel
        context.coordinator.setActive(active)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.setActive(false)
    }

    final class Coordinator {
        var onCapture: ((UInt32, NSEvent.ModifierFlags) -> Void)?
        var onDoubleModifier: ((UInt32) -> Void)?
        var onCancel: (() -> Void)?
        private var monitor: Any?
        private var pendingModifierTap: UInt32?
        private var lastModifierTap: (modifier: UInt32, time: TimeInterval)?

        func setActive(_ active: Bool) {
            if active, monitor == nil {
                // Announce first: the global hot keys must be unregistered before
                // the monitor goes up, or the chords Notch owns still never arrive.
                ShortcutRecording.setActive(true)
                pendingModifierTap = nil
                lastModifierTap = nil
                monitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.keyDown, .flagsChanged]
                ) { [weak self] event in
                    guard let self else { return event }
                    if event.type == .flagsChanged {
                        self.captureDoubleModifierIfNeeded(event)
                        return event
                    }
                    // Esc cancels recording without committing anything. Clearing
                    // the armed target is the whole point — leaving it armed makes
                    // the *next* keystroke anywhere land on that row.
                    guard event.keyCode != UInt16(kVK_Escape) else {
                        self.onCancel?()
                        return nil
                    }
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    self.onCapture?(UInt32(event.keyCode), flags)
                    return nil // swallow — don't let the chord reach the panel
                }
            } else if !active, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
                pendingModifierTap = nil
                lastModifierTap = nil
                ShortcutRecording.setActive(false)
            }
        }

        /// Recognize two clean Command or Option down/up taps inside the same
        /// 300 ms window used by the live monitor. Any other held modifier
        /// invalidates the sequence, so normal chords never become a double tap.
        private func captureDoubleModifierIfNeeded(_ event: NSEvent) {
            let watched: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            let active = event.modifierFlags.intersection(watched)

            let pressed: UInt32? = switch active {
            case .command: UInt32(cmdKey)
            case .option: UInt32(optionKey)
            default: nil
            }
            if let pressed {
                pendingModifierTap = pressed
                return
            }

            guard active.isEmpty else {
                pendingModifierTap = nil
                lastModifierTap = nil
                return
            }

            guard let completed = pendingModifierTap else { return }
            pendingModifierTap = nil

            let now = event.timestamp
            if let last = lastModifierTap,
               last.modifier == completed, now - last.time <= 0.30 {
                lastModifierTap = nil
                onDoubleModifier?(completed)
            } else {
                lastModifierTap = (completed, now)
            }
        }

        deinit {
            if let m = monitor {
                NSEvent.removeMonitor(m)
                ShortcutRecording.setActive(false)
            }
        }
    }
}

/// The "New" marks on the settings pane, and whether they have been answered.
enum SettingsNewMarks {
    private static let copySenseKey = "settingsCopySenseSeen"
    private static let auditKey = "settingsAuditSeen"
    private static let surveyGrantKey = "settingsSurveyGrantSeen"
    private static let surveyWaitedKey = "settingsSurveyWaited"

    /// The sidebar's Audit row, until it is first clicked.
    static var auditSeen: Bool {
        get { UserDefaults.standard.bool(forKey: auditKey) }
        set { UserDefaults.standard.set(newValue, forKey: auditKey) }
    }

    /// This install has seen the survey answer waiting for review.
    static var surveyWaited: Bool {
        get { UserDefaults.standard.bool(forKey: surveyWaitedKey) }
        set { UserDefaults.standard.set(newValue, forKey: surveyWaitedKey) }
    }

    /// The survey's granted credit, until the Model pane is opened.
    static var surveyGrantSeen: Bool {
        get { UserDefaults.standard.bool(forKey: surveyGrantKey) }
        set { UserDefaults.standard.set(newValue, forKey: surveyGrantKey) }
    }

    static var copySenseSeen: Bool {
        get { UserDefaults.standard.bool(forKey: copySenseKey) }
        set { UserDefaults.standard.set(newValue, forKey: copySenseKey) }
    }
}

/// The × on a Memory or Clipboard history row: a bare glyph that lights up with
/// a faint circle on hover, as the selection context chip's × does
/// (`NotchBody`), with no glass of its own.
private struct ListRowRemoveButton: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(icon: "xmark")
                .font(.sf(Tokens.TypeSize.badge, weight: .regular))
                .foregroundStyle(hovering ? Tokens.text1 : Tokens.text4)
                .frame(width: Tokens.Control.inline, height: Tokens.Control.inline)
                .background(Circle().fill(Tokens.ink.opacity(hovering ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).exemptsDoubleClickPin()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        .accessibilityLabel(label)
    }
}

private struct SettingsWindowPaneHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// Set by `SettingsWindowController`: the pane height Settings uses in its
    /// own window. nil inside the notch panel.
    var settingsWindowPaneHeight: CGFloat? {
        get { self[SettingsWindowPaneHeightKey.self] }
        set { self[SettingsWindowPaneHeightKey.self] = newValue }
    }
}

/// Layout numbers for Settings, one set per frame it is drawn in. The panel's
/// pane is about 420pt wide and capped at 270pt tall; the window's is about
/// 680pt wide and fills the window's height. The window keeps rows at a
/// readable width and uses the extra height for spacing.
struct SettingsMetrics {
    /// Widest a pane's rows grow; nil fills the pane.
    let contentMaxWidth: CGFloat?
    /// Space between two rows in a pane.
    let rowSpacing: CGFloat
    /// Extra space above a group heading, on top of `rowSpacing`.
    let groupHeadingGap: CGFloat
    /// Space between a row's label and its description line.
    let labelNoteSpacing: CGFloat
    /// Empty inset above a pane's first row.
    let paneTopRunway: CGFloat
    /// Length of the top fade while a pane is scrolled.
    let paneTopFade: CGFloat
    /// Side inset of the pane's rows.
    let paneSideInset: CGFloat
    /// Width of the category column.
    let sidebarWidth: CGFloat
    /// Points added to every step of the settings type ladder.
    let typeBump: CGFloat
    /// Whether status and error notes show in full instead of their panel line limit.
    let notesUnclamped: Bool
    /// Opacity of the dim behind a confirmation card.
    let scrimOpacity: Double

    static let panel = SettingsMetrics(
        contentMaxWidth: nil, rowSpacing: 18, groupHeadingGap: 24,
        labelNoteSpacing: 2, paneTopRunway: 14, paneTopFade: 34,
        paneSideInset: 0, sidebarWidth: 128, typeBump: 0,
        notesUnclamped: false, scrimOpacity: 0.45)

    static let window = SettingsMetrics(
        contentMaxWidth: 560, rowSpacing: 22, groupHeadingGap: 32,
        labelNoteSpacing: 4, paneTopRunway: 24, paneTopFade: 20,
        paneSideInset: 18, sidebarWidth: 164, typeBump: 1,
        notesUnclamped: true, scrimOpacity: 0.25)

    /// `panel` for a note that the panel clamps to `lines`; nil in the window.
    func noteLines(_ lines: Int) -> Int? { notesUnclamped ? nil : lines }

    /// Label column of the key section's text fields, and where notes under
    /// those fields start (the label plus the row's 12pt gap).
    static let fieldLabelWidth: CGFloat = 64
    static let fieldIndent: CGFloat = fieldLabelWidth + 12
    /// Label column of the search-key rows, and the indent of their notes.
    static let searchKeyLabelWidth: CGFloat = 100
    static let searchKeyIndent: CGFloat = 88

    /// The Settings window's opening width: exactly the sidebar and a full
    /// `contentMaxWidth` column, so the pane has no empty strip on the right.
    /// Window gutters 15 + 15, sidebar and its 12pt gap, the pane's 14pt
    /// leading inset, and the pane's side insets.
    static let windowWidth: CGFloat = 15 * 2 + window.sidebarWidth + 12 + 14
        + window.paneSideInset * 2 + (window.contentMaxWidth ?? 560)

    /// Settings' width inside the panel: the island's settings width less the
    /// body's 15pt gutters.
    static let panelBodyWidth: CGFloat = Tokens.openWidthSettings - 2 * NotchBody.panelPadding
    /// The category pane's exact width in the panel: the body less the
    /// category column, its 12pt gap and the pane's 14pt leading inset.
    static let panelPaneWidth: CGFloat = panelBodyWidth - panel.sidebarWidth - 12 - 14
}

extension EnvironmentValues {
    /// `SettingsMetrics` for the frame Settings is drawn in, read from
    /// `settingsWindowPaneHeight`.
    var settingsMetrics: SettingsMetrics {
        settingsWindowPaneHeight != nil ? .window : .panel
    }
}

private extension EnvironmentValues {
    /// The open Settings pane's shared label column width; 0 until measured.
    var settingsLabelColumn: CGFloat {
        get { self[InlineSettingsView.SettingsLabelColumnKey.self] }
        set { self[InlineSettingsView.SettingsLabelColumnKey.self] = newValue }
    }
}

/// `colorInvert()` when `on`, for the light Telegram avatar.
private struct InvertIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.colorInvert() } else { content }
    }
}



#if DEBUG
extension InlineSettingsView {
    /// The license row alone, for `NotchiLicense._debugRender`.
    nonisolated(unsafe) static var _debugEntering = false

    @MainActor static func _debugLicenseRow(model: NotchModel, entering: Bool = false) -> some View {
        _debugEntering = entering
        return InlineSettingsView(model: model).licenseRow
    }

    @MainActor static func _debugLicensePane(model: NotchModel) -> some View {
        _debugEntering = false
        return InlineSettingsView(model: model).licensePane
    }
}
#endif

/// Holds the window a view is drawn in, without making SwiftUI redraw on it.
final class HostWindowBox {
    weak var window: NSWindow?
}

/// Writes its window into a `HostWindowBox`.
struct HostWindowProbe: NSViewRepresentable {
    let box: HostWindowBox

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.box = box
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.box = box
        box.window = view.window
    }

    final class Probe: NSView {
        weak var box: HostWindowBox?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            box?.window = window
        }
    }
}


/// Shared privacy confirmation dialog shown before connecting any third-party
/// (Composio-backed) connector, whether triggered from Settings or an in-chat card.
struct ThirdPartyConnectorConsentOverlay: View {
    let connector: MCPConnector
    @ObservedObject var auth: MCPConnectorAuth
    var floating: Bool = false

    var body: some View {
        ConfirmationDialogOverlay(onDismiss: { auth.pendingThirdPartyConsent = nil }, floating: floating) {
            SettingsAlertDialog(
                title: L("connector.thirdParty.title", connector.title),
                description: L("connector.thirdParty.body", connector.title),
                confirmTitle: L("connector.thirdParty.confirm"),
                cancelTitle: L("clear.cancel"),
                destructive: false,
                onCancel: { auth.pendingThirdPartyConsent = nil },
                onConfirm: {
                    let target = connector
                    auth.pendingThirdPartyConsent = nil
                    auth.connect(target)
                }
            ) {
                UnderlineLink(title: L("connector.thirdParty.privacy"), external: true) {
                    if let url = URL(string: "https://composio.dev/privacy") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

