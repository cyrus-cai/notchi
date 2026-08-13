import AppKit
import Carbon.HIToolbox
import Carbon.OpenScripting
import EventKit
import SwiftUI
import UserNotifications

/// A common vocabulary for the TCC-backed capabilities shown in General. Some
/// frameworks use different native enums, but the settings UI only needs these
/// four user-facing states.
private enum SettingsPermissionStatus: Equatable {
    case checking
    case notDetermined
    case denied
    case granted
    case unavailable

    var label: String {
        switch self {
        case .checking:      return L("permissions.status.checking")
        case .notDetermined: return L("permissions.status.notGranted")
        case .denied:        return L("permissions.status.denied")
        case .granted:       return L("permissions.status.granted")
        case .unavailable:   return L("permissions.status.unavailable")
        }
    }

    var pillLabel: String {
        switch self {
        case .notDetermined, .unavailable: return L("permissions.action.allow")
        case .denied:                      return L("permissions.action.settings")
        case .checking, .granted:           return label
        }
    }
}

/// A deliberately neutral system-style status capsule. Permission state is not
/// an alert or a score: granted rests in quiet grey, while a missing permission
/// uses the same shape as its action instead of introducing traffic-light color.
private struct PermissionStatusPill: View {
    let status: SettingsPermissionStatus
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Group {
            if status == .granted || status == .checking {
                pillLabel
            } else {
                Button(action: action) { pillLabel }
                    .buttonStyle(.plain)
                    .onHover { hovering = $0 }
            }
        }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }

    private var pillLabel: some View {
        Text(status.pillLabel)
            .font(.sf(11, weight: .semibold))
            .foregroundStyle(missing
                             ? Color.red.opacity(hovering ? 0.88 : 0.72)
                             : (hovering ? Tokens.text1 : Tokens.text2))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                Capsule()
                    .fill(missing
                          ? Color.red.opacity(hovering ? 0.14 : 0.09)
                          : Color.white.opacity(hovering ? 0.12 : 0.07))
            )
            .overlay(
                Capsule()
                    .strokeBorder(missing
                                  ? Color.red.opacity(hovering ? 0.22 : 0.15)
                                  : Color.white.opacity(hovering ? 0.15 : 0.08),
                                  lineWidth: 0.5)
            )
            .contentShape(Capsule())
    }

    private var missing: Bool {
        status != .granted && status != .checking
    }
}

/// Settings rendered *inside* the notch panel, in place of the recent list —
/// not a separate window. Carries the same logic as the old native `SettingsView`
/// (active provider, its API key, an optional model override, all in
/// `UserDefaults` via `APIKeyStore`) but wears the panel's Liquid Glass skin so it
/// reads as part of the island. The gear and ⌘, both swap the RECENT block for
/// this; the back chevron returns to the idle prompt.
struct InlineSettingsView: View {
    @ObservedObject var model: NotchModel
    /// Self-update state (shared app-wide — the gear badge reads the same object).
    /// Drives the Version row: a quiet number normally, an Update action when a
    /// newer release is known.
    @ObservedObject private var updater = UpdaterService.shared
    /// The one-click OpenRouter OAuth flow. Observed so the Account row tracks
    /// its phases (waiting on the browser, exchanging, failed) live.
    @ObservedObject private var orAuth = OpenRouterAuth.shared

    /// The provider whose model is in effect — the backend that answers. Changed
    /// only by picking a model; key management never touches it.
    @State private var provider: Provider = APIKeyStore.selectedProvider
    /// The provider whose key the key section is viewing/editing. Follows
    /// `provider` while the section is closed; retargeted by the picker's
    /// "Add key" flow and by the section's own provider menu. All key-editor
    /// state below (apiKey / editingKey / saved / testResult) is scoped to this,
    /// so managing a key never hijacks the active backend.
    @State private var keyScope: Provider = APIKeyStore.selectedProvider
    @State private var apiKey: String = APIKeyStore.stored(for: APIKeyStore.selectedProvider)
    /// Empty string = "use the provider's default".
    @State private var modelID: String = APIKeyStore.storedModel(for: APIKeyStore.selectedProvider)
    @State private var saved = false
    /// False once a key is saved: the row shows a masked, read-only summary of
    /// the stored key (so screenshots never carry the full secret) until the
    /// user explicitly hits Change. Starts true only when nothing is stored.
    @State private var editingKey: Bool =
        APIKeyStore.stored(for: APIKeyStore.selectedProvider).isEmpty
            && !APIKeyStore.hasEnvOverride(for: APIKeyStore.selectedProvider)

    @State private var loadingModels = false

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

    /// The model catalog behind the picker — live lists, the fold, and which providers
    /// are callable. Session-wide (the panel's ⌘⇧I picker reads the same store), so a
    /// list fetched for one surface is already warm for the other.
    @ObservedObject private var catalog = ModelCatalogStore.shared

    /// Whether the custom cross-provider model picker overlay is open.
    @State private var modelPickerOpen = false

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

    /// The custom endpoint's three fields (see `CustomProvider`), edited together
    /// and committed by one Save — unlike a key, an endpoint that's half-typed is
    /// worse than the old one, so nothing is persisted keystroke by keystroke.
    @State private var customName: String = CustomProvider.name
    @State private var customURL: String = CustomProvider.baseURL
    @State private var customModel: String = CustomProvider.model
    @State private var customSaved = false

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
        case model = "Model"     // provider, API key, model override
        case search = "Search"   // search backend + its key
        case notes = "Notes"     // the capture pipeline: note destination + copy sensing
        case appearance = "Appearance" // where it shows up: screens, full screen, Dock icon
        case general = "General" // language, launch at login, hover, + Advanced (proxy)
        case shortcuts = "Shortcuts" // editable keyboard controls, its own top-level settings category
        case about = "About"     // version + self-update
        case licenses = "Licenses" // third-party attribution and licences
        var id: String { rawValue }

        /// A sub-page rather than a category: reached from About, drawn across
        /// the whole panel, and left through the header's back pill or Esc.
        var isDetail: Bool { self == .licenses }

        /// The section a sub-page sits under — where back (and ⎋) returns to.
        /// `nil` for the top-level categories, whose back leaves settings.
        var parent: Section? { isDetail ? .about : nil }

        /// The sidebar's rows: every category, minus the sub-pages.
        static var sidebarCases: [Section] { allCases.filter { !$0.isDetail } }

        /// The sidebar label, localized. The raw value stays English (a stable
        /// identity); this is what the user actually reads.
        var title: String {
            switch self {
            case .model:      return L("sidebar.model")
            case .search:     return L("sidebar.search")
            case .notes:      return L("sidebar.notes")
            case .general:    return L("sidebar.general")
            case .shortcuts:  return L("sidebar.shortcuts")
            case .appearance: return L("sidebar.appearance")
            case .about:      return L("sidebar.about")
            case .licenses:   return L("about.licenses")
            }
        }
    }
    /// The open category, backed by `model.settingsSection` (not plain `@State`)
    /// so an App Language switch — which rebuilds this whole subtree via the
    /// root's `.id(loc.language)` — keeps the user on the pane they were on (e.g.
    /// General, where the language picker lives) instead of snapping back to Model.
    private var section: Section {
        get { Section(rawValue: model.settingsSection) ?? .model }
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

    /// Whether the app shows a menu bar icon — mirrors the persisted value; writes
    /// go through `selectMenuBarIconVisibility` so `AppDelegate` adds or removes
    /// the status item immediately.
    @State private var menuBarIconVisibility: MenuBarIconVisibility = .current

    /// Whether the app launches itself at login — seeded from the live system
    /// login-item status (`SMAppService`), not `UserDefaults`. Writes go through
    /// `selectLaunchAtLogin`, which registers/unregisters the item and reverts
    /// this optimistic flag if the OS refuses.
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled

    /// How eagerly the resting notch opens under the pointer — mirrors the
    /// persisted value; writes go through `selectHoverSensitivity`. Read live by
    /// `NotchModel.hoverEntered`, so a change applies to the very next hover.
    @State private var hoverSensitivity: HoverSensitivity = .current
    /// How much additional trackpad pressure turns a click into the global
    /// selected-text action. The monitor reads the persisted value live.
    @State private var forceClickPressure: ForceClickPressure = .current

    /// Whether the island auto-hides while a full-screen app covers its screen —
    /// mirrors the persisted value; writes go through `selectHideInFullscreen`,
    /// which nudges `AppDelegate` to re-evaluate immediately.
    @State private var hideInFullscreen: Bool = HideNotchInFullscreen.isEnabled

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
    @State private var appShortcuts: [AppShortcutAction: ShortcutChord] = AppShortcutStore.current
    /// User-authored global bindings are intentionally only a shortcut and one
    /// prompt. Their UUID exists solely so SwiftUI and AppDelegate can track rows.
    @State private var promptShortcuts: [PromptShortcut] = PromptShortcutStore.current
    /// The delete affordance stays out of the resting row until its pointer is
    /// nearby. Keeping the button's frame mounted prevents the fields from
    /// shifting when it fades in.
    @State private var hoveredPromptShortcutID: UUID?
    @State private var hoveredShortcutRow: EditableShortcut?
    /// At most one row records at a time. Hints belong to their row so a conflict
    /// stays visually attached to the shortcut that needs attention.
    @State private var recordingShortcut: EditableShortcut?
    @State private var shortcutHints: [EditableShortcut: String] = [:]

    /// Whether the General pane's folded Advanced block is open.
    @State private var advancedSectionOpen = false
    /// Permissions are diagnostic/recovery controls rather than everyday
    /// preferences, so they stay folded until the user needs them.
    @State private var permissionsSectionOpen = false

    /// Which disclosure chip owns the pointer. Permissions and Advanced can share
    /// one pane, so a single Bool would brighten both at once.
    private enum DisclosureHover { case keys, permissions, advanced }
    @State private var hoveredDisclosure: DisclosureHover?

    /// What the proxy field resolves to right now — filled in asynchronously by
    /// `refreshProxyStatus` because detection may spawn a login shell.
    @State private var proxyStatus: String = ""

    /// Live macOS authorization state for the three protected capabilities the
    /// app actually uses. These are refreshed whenever General appears and when
    /// Notchi becomes active again, so a change made in System Settings is
    /// reflected without relaunching.
    @State private var remindersPermission: SettingsPermissionStatus = .checking
    @State private var notesPermission: SettingsPermissionStatus = .checking
    @State private var notificationsPermission: SettingsPermissionStatus = .checking

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if section.isDetail {
                // A pushed sub-page (the Shortcuts reference under About): the
                // category column steps aside and the page takes the whole panel,
                // so it reads as one level deeper rather than another tab. The
                // header's back pill — now carrying this page's name — walks out.
                // No `.fixedSize(vertical:)` needed here: alone in the column, the
                // pane's own exact height (content, capped at Recent's) is the
                // whole page height.
                paneContent
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    // The sidebar drops by the pane's runway too, so the first
                    // category stays level with the pane's first row — the runway
                    // moves BOTH columns down, it doesn't stagger them.
                    sidebar
                        .padding(.top, Self.paneTopRunway)

                    // Hairline column boundary, full height of whichever side is
                    // taller. `maxHeight: .infinity` makes it greedy on its own —
                    // the `fixedSize` below is what resolves it to the columns'
                    // height instead of every point the panel can offer.
                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .frame(width: 0.5)
                        .frame(maxHeight: .infinity)

                    paneContent
                        .padding(.leading, 14)
                }
                // Take the columns' own height, nothing more: the pane already
                // carries an exact height (content, capped at Recent's), so this
                // no longer unfolds the scroll — it only stops the greedy divider
                // (and the scroll behind it) from stretching the island.
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.top, 12)
            }
        }
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
            // Un-throttled freshness check while the user is actually looking at
            // the Version row (one tiny request; failures stay silent).
            updater.check()
            // The model chip may be naming a Claude Code alias — resolve it to the
            // concrete model ("opus" → "Opus 5") without waiting for the picker to
            // be opened. Self-gating and cache-backed; usually a no-op.
            catalog.resolveClaudeAliases()
            await refreshModels()
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
    /// the same budget. Short panes leave air at the bottom; long ones scroll. It
    /// used to track each pane's measured content height, which meant the island
    /// resized on every category switch (and re-measured on every layout pass) —
    /// a fixed frame is both steadier to look at and cheaper to draw.
    private static let headerChrome: CGFloat = 12 + 26 + 4 + 12
    private var settingsPaneHeight: CGFloat {
        NotchBody.immersiveListHeight - Self.headerChrome
    }

    /// Scroll anchor for the key section — the one pane area whose unfold can
    /// push its own fields past the pane's height cap.
    private static let keySectionAnchor = "settings.keySection"

    /// The empty inset above the pane's first row, and the length of the top
    /// taper that dissolves into it. The runway is the longer of the two on
    /// purpose: a fade that outreaches its runway lands on live content.
    private static let paneTopRunway: CGFloat = 14
    private static let paneTopFade: CGFloat = 12

    /// Whether the open pane is scrolled off its top — all the top taper needs to
    /// know. A Bool, not the live offset: driving the gradient's LENGTH from the
    /// offset rebuilt the pane's mask on every scroll tick, which is what made
    /// scrolling crawl. This flips once.
    @State private var paneScrolledOffTop = false

    /// The open section's pane. Lives apart from `body` because it is drawn in
    /// two different frames — in the right-hand column beside the sidebar for a
    /// category, or across the whole panel for a pushed sub-page — and the switch
    /// itself should not have to know which.
    ///
    /// Every category scrolls inside ONE shared frame (see
    /// `settingsPaneHeight`) instead of stretching the island taller: the
    /// Shortcuts reference used to be the only pane with its own fixed-height
    /// scroll; now the whole settings body rides the same ceiling and the same
    /// edge tapers.
    @ViewBuilder
    private var paneContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch section {
            case .model:
                // Two steps, in the order you make them: pick the backend,
                // then pick one of *its* models. The API key stays supporting
                // cast — folded into `keySection`, which only unfolds when the
                // choice actually needs a key (or the user opens it by hand).
                providerRow
                modelRow
                keySection
                customInstructionsRow
            case .search:
                searchBackendRow
                    // No stored pick yet → commit the shown default so the
                    // UI and what actually runs never disagree.
                    .onAppear {
                        if searchBackend == nil { selectSearchBackend(selectedBackend) }
                    }
                // Only the picked backend's key row shows — like the model
                // section, one choice, one field to fill.
                switch selectedBackend {
                case .keenable: keenableKeyRow
                case .exa:      exaKeyRow
                case .anysearch: anySearchKeyRow
                }
            case .notes:
                // The capture pipeline in one place: where a jot files,
                // then the closed-notch copy sensing that feeds it.
                noteDestinationRow
                copySenseRow
            case .general:
                if ForceClickFeature.isEnabled {
                    forceClickPressureRow
                }
                // What the panel picks up when it opens, next to how a press
                // opens it — both are the notch reaching outside itself.
                selectionContextRow
                hoverSensitivityRow
                appLanguageRow
                launchAtLoginRow
                permissionsSection
                advancedSection
            case .shortcuts:
                shortcutsSection
            case .appearance:
                // Two groups, heaviest control first. Where it shows up —
                // which screens carry an island, whether it also sits in
                // the Dock and the menu bar — then how it behaves once
                // there: yielding to full screen, animating on background
                // work.
                placementRow
                dockIconRow
                menuBarIconRow
                fullscreenAutoHideRow
                liveActivityRow
            case .about:
                aboutSection
            case .licenses:
                licensesSection
            }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // A top RUNWAY — the whole right-hand pane rests a little lower than the
            // sidebar's first item, and this inset is what the top taper dissolves
            // into. It has to outlast the taper (see `paneTopFade`), or the fade
            // lands on live content the instant the pane moves: About's masthead
            // (a 44pt icon beside the app name, the tallest first row in the app)
            // went half-transparent on a stray trackpad nudge, which read as
            // something covering the top of the pane. With the runway, a small
            // scroll eats empty space first and the rows stay solid. The bottom
            // keeps its own runway — that edge tapers at all times.
            .padding(.top, Self.paneTopRunway)
            .padding(.bottom, 20)
            // Zero-size probe on the scroll CONTENT: it reads the real clip view's
            // offset. Only the crossing matters, so state changes at most once per
            // scroll gesture rather than on every tick.
            .onScrollOffsetChange { offset in
                let off = offset > 0.5
                if off != paneScrolledOffTop { paneScrolledOffTop = off }
            }
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
            // A required setup unfolds the key section past the pane's height
            // cap — snap the scroller to it so what just appeared is in view
            // (the anchor lives on `keySection`). The first frame of the unfold
            // lands silently: the animation here would otherwise double the
            // section's own `.easeOut` and stall the open.
            .onChange(of: setupRequired) { _, required in
                guard required, section == .model else { return }
                DispatchQueue.main.async { proxy.scrollTo(Self.keySectionAnchor, anchor: .top) }
            }
            // The top taper exists only once the pane is actually scrolled: a
            // permanent one dimmed the first row of every pane before the user had
            // scrolled anything, and the fade is there to dissolve rows leaving
            // past the back pill — nothing is leaving while the pane sits at top.
            // Kept shorter than the runway above it so it always has empty space
            // to dissolve into rather than the first row.
            .scrollEdgeFade(top: paneScrolledOffTop, bottom: true,
                            topFade: Self.paneTopFade, bottomFade: 32)
            // A pane swap starts at the top again; the observer only reports on
            // the next bounds change, so clear the flag here.
            .onChange(of: section) { paneScrolledOffTop = false }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.sidebarCases) { s in
                SidebarItem(
                    title: s.title,
                    selected: section == s,
                    // The gear's update dot continues here: it leads to settings,
                    // then the About entry carries it the rest of the way to the
                    // update action — a quiet neutral dot, never a coloured one.
                    badged: s == .about && isUpdateAvailable
                ) {
                    withAnimation(.easeOut(duration: 0.16)) { section = s }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 104, alignment: .topLeading)
        .padding(.trailing, 12)
    }

    private var isUpdateAvailable: Bool {
        if case .available = updater.phase { return true }
        return false
    }

    /// One category row: quiet text that brightens on hover, a faint fill when
    /// selected — same translucent-chip language as GlassMenu, minus the border.
    private struct SidebarItem: View {
        var title: String
        var selected: Bool
        var badged: Bool
        var action: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.sf(12.5, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(selected ? Tokens.text1 : (hovering ? Tokens.text2 : Tokens.text3))
                    if badged {
                        Circle()
                            .fill(Tokens.text2)
                            .frame(width: 5, height: 5)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    Capsule()
                        .fill(.white.opacity(selected ? 0.08 : (hovering ? 0.04 : 0)))
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
        }
    }

    // MARK: - Header

    /// The back pill names wherever you are and walks out of it: on a category
    /// that's "Settings" → leave settings; on a pushed sub-page it takes the
    /// page's own name and steps back one level to the section that owns it,
    /// so the pill never skips a floor.
    private var header: some View {
        HStack(spacing: 10) {
            PanelBackPill(
                title: section.isDetail ? section.title : L("settings.title"),
                help: section.parent.map { L("navigation.backTo", $0.title) }
                    ?? L("settings.back")
            ) {
                if let parent = section.parent {
                    withAnimation(.easeOut(duration: 0.16)) { section = parent }
                } else {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        model.closeSettings()
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Rows

    // MARK: - Provider & API key (supporting cast)

    /// Whether the pane must surface key setup right now: a picked model is
    /// waiting on a key, or the active provider itself has none (nothing can
    /// answer). Only then does key UI appear unbidden.
    private var setupRequired: Bool {
        pendingModel != nil || !providerReady(provider)
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
        let expanded = keySectionOpen || setupRequired
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    if expanded {
                        keySectionOpen = false
                        pendingModel = nil     // folding away dismisses the pending ask
                        setKeyScope(provider)  // …and the section re-tracks the backend
                    } else {
                        keySectionOpen = true
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.sf(9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(L("model.keys.section"))
                        .font(.sf(12, weight: .medium))
                }
                .foregroundStyle(Tokens.text1)
                .padding(.horizontal, 10)
                .frame(height: 26)
                // The disclosure's own glass chip — a translucent pill that
                // brightens under the pointer, so the fold itself reads as a
                // control on the panel's glass rather than a bare line of text.
                .background(
                    Capsule()
                        .fill(.white.opacity(hoveredDisclosure == .keys ? 0.12 : 0.06))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(hoveredDisclosure == .keys ? 0.22 : 0.12),
                                      lineWidth: 0.5)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { hoveredDisclosure = .keys }
                else if hoveredDisclosure == .keys { hoveredDisclosure = nil }
            }
            .animation(.easeOut(duration: Tokens.hoverFade), value: hoveredDisclosure)

            if expanded {
                // Why the section opened by itself, when it did.
                if let pending = pendingModel {
                    Text(L("model.pending.hint", pending.provider.displayName,
                           ModelRatings.prettyName(for: pending.id,
                                                   provider: pending.provider)))
                        .font(.sf(12))
                        .foregroundStyle(Tokens.text2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !providerReady(provider) {
                    Text(L("model.setup.needed", provider.displayName))
                        .font(.sf(12))
                        .foregroundStyle(Tokens.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Whose key this section is editing — shown only when that isn't the
                // active provider (the ⌘⇧I picker's "Add key" aims it elsewhere).
                // For the ordinary case the Provider row above already says it, and
                // repeating it here would read as a second, contradicting control.
                if keyScope != provider {
                    settingRow(label: L("model.provider")) {
                        Text(keyScope.displayName)
                            .font(.sf(13))
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

                // Codex has no key to paste — it shows a sign-in status row. OpenRouter
                // gets the one-click Connect row (unless the user asked to paste by
                // hand, or an env var forces a key). Everyone else gets the key field.
                if keyScope == .codex {
                    codexAccountRow
                } else if keyScope == .claudeCode {
                    claudeAccountRow
                } else if keyScope == .grokCode {
                    grokAccountRow
                } else if keyScope == .commandCode {
                    commandCodeAccountRow
                } else if keyScope == .openrouter && !manualKeyEntry && !envOverride {
                    openRouterAccountRow
                } else {
                    keyRow
                }

                // The CLI backends have no key to fetch — their own rows carry the
                // sign-in copy, so the generic "get a key at …" footer is wrong for
                // them and suppressed.
                if !keyScope.isCLI {
                    footer
                }
            }
        }
        // The scroller's anchor (see `paneContent`): a required setup unfolding
        // this block past the pane's height cap snaps it into view.
        .id(Self.keySectionAnchor)
        .animation(.easeOut(duration: 0.16), value: expanded)
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
                    text: $customURL)
        if let resolved = CustomProvider.normalized(customURL) {
            Text(L("model.custom.resolved", resolved.absoluteString))
                .font(.sf(11))
                .foregroundStyle(Tokens.text3)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 76)
        }
        customField(label: L("model.custom.model"),
                    placeholder: L("model.custom.modelPlaceholder"),
                    text: $customModel)
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            // Test lives here rather than beside the key, because for this provider
            // the thing worth probing is the endpoint — the key may not exist at all.
            if testing {
                ProgressView().controlSize(.small)
            } else if CustomProvider.chatEndpoint != nil, !canSaveCustom {
                SettingActionButton(title: L("model.test")) { test() }
            }
            SettingActionButton(title: customSaved ? L("model.saved") : L("model.save"),
                                tone: canSaveCustom || customSaved ? Tokens.text2 : Tokens.text4) {
                saveCustom()
            }
            .disabled(!canSaveCustom && !customSaved)
            .animation(.easeOut(duration: 0.2), value: customSaved)
        }
    }

    /// One labelled text field in the key section's column, matching the key row's
    /// field chrome so the block reads as one form.
    private func customField(label: String, placeholder: String,
                             text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.sf(13, weight: .medium))
                .foregroundStyle(Tokens.text2)
                .frame(width: 64, alignment: .leading)
            ZStack(alignment: .leading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.sf(13))
                        .foregroundStyle(Tokens.text3)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                TextField("", text: text)
                    .textFieldStyle(.plain)
                    .font(.sf(13))
                    .foregroundStyle(Tokens.text1)
                    .onSubmit { saveCustom() }
                    // Typing here counts as activity, so a pointer that drifted off
                    // the island can't fold the panel mid-edit.
                    .onChange(of: text.wrappedValue) { model.noteUserTyping() }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        }
    }

    /// Commit the custom endpoint. The catalog is dropped first: the model list
    /// belongs to whichever server the old URL pointed at, and keeping it would
    /// offer models the new one may not serve.
    private func saveCustom() {
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
        NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
        withAnimation(.easeOut(duration: 0.2)) { customSaved = true }
        Task { await refreshModels() }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(.easeOut(duration: 0.3)) { customSaved = false }
        }
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
        customSaved = false
        apiKey = APIKeyStore.stored(for: p)
        saved = false
        testResult = nil   // last verdict belonged to the old provider/key
        manualKeyEntry = false   // back to the Connect row next time OpenRouter shows
        editingKey = apiKey.isEmpty && !APIKeyStore.hasEnvOverride(for: p)
    }

    /// Switch the active backend — the provider whose model answers. Driven by the
    /// Provider row (step one) and by a cross-provider pick arriving from the ⌘⇧I
    /// picker. The key section always follows the backend: the only state where it
    /// aims elsewhere is a pending model (picker "Add key"), which retargets it itself.
    private func selectProvider(_ newValue: Provider) {
        guard newValue != provider else { return }
        provider = newValue
        APIKeyStore.selectedProvider = newValue
        modelID = APIKeyStore.storedModel(for: newValue)
        NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
        setKeyScope(newValue)
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
                    .font(.sf(13, weight: .medium))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: 64, alignment: .leading)

                ZStack(alignment: .leading) {
                    if editingKey {
                        // Our own placeholder, shown only while empty — SwiftUI's built-in
                        // `prompt:` ignores the color we set and renders its own dim gray,
                        // so we overlay a Text we fully control to get a clean bright hint.
                        if apiKey.isEmpty {
                            Text(L("model.pasteKey"))
                                .font(.sf(13))
                                .foregroundStyle(Tokens.text2)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $apiKey)
                            .textFieldStyle(.plain)
                            .font(.sf(13))
                            .foregroundStyle(Tokens.text1)
                            .disabled(envOverride)
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
                            .font(.sf(13))
                            .foregroundStyle(Tokens.text2)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(editingKey ? 0.06 : 0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(editingKey ? 0.12 : 0.07), lineWidth: 0.5)
                )
                .opacity(envOverride ? 0.5 : 1)

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
                    SettingActionButton(title: L("model.change")) { startEditingKey() }
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
                    .padding(.leading, 76)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// The search-backend picker. Exactly like the model picker: you pick one and
    /// that's what runs — no "Default" row, no native fallback. The picker always
    /// resolves to a concrete backend, and only that backend's key row shows below.
    private var searchBackendRow: some View {
        settingRow(label: L("search.backend")) {
            GlassMenu(title: searchBackendLabel(selectedBackend)) {
                ForEach(APIKeyStore.SearchBackend.allCases) { b in
                    Button { selectSearchBackend(b) } label: {
                        menuOption(searchBackendLabel(b), selected: b == selectedBackend)
                    }
                }
            }
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
                HStack(spacing: 3) {
                    Text(L("model.keenableApiKey"))
                        .font(.sf(13, weight: .medium))
                        .foregroundStyle(Tokens.text2)
                        .lineLimit(1)
                    // "Where to get a key" note, folded into an ⓘ beside the title.
                    if !keenableEnvOverride {
                        SettingInfo(keenableHintText)
                    }
                }
                .frame(width: 100, alignment: .leading)

                ZStack(alignment: .leading) {
                    if editingKeenableKey {
                        if keenableKey.isEmpty {
                            Text(L("model.keenablePasteKey"))
                                .font(.sf(13))
                                .foregroundStyle(Tokens.text2)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $keenableKey)
                            .textFieldStyle(.plain)
                            .font(.sf(13))
                            .foregroundStyle(Tokens.text1)
                            .disabled(keenableEnvOverride)
                            .onSubmit { saveKeenableKey() }
                            // Typing here must hold off the hover-leave fold too.
                            .onChange(of: keenableKey) { model.noteUserTyping() }
                    } else {
                        Text(maskedKeenableKey)
                            .font(.sf(13))
                            .foregroundStyle(Tokens.text2)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(editingKeenableKey ? 0.06 : 0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(editingKeenableKey ? 0.12 : 0.07), lineWidth: 0.5)
                )
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

            // Only the live env-override status stays inline (it explains why the
            // field is locked); the how-to note moved into the ⓘ above.
            if keenableEnvOverride {
                Text(L("model.footer.env", "KEENABLE_API_KEY"))
                    .font(.sf(11))
                    .foregroundStyle(Tokens.text4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 88)
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
                HStack(spacing: 3) {
                    Text(L("model.exaApiKey"))
                        .font(.sf(13, weight: .medium))
                        .foregroundStyle(Tokens.text2)
                        .lineLimit(1)
                    // "Where to get a key" note, folded into an ⓘ beside the title.
                    if !exaEnvOverride {
                        SettingInfo(exaHintText)
                    }
                }
                .frame(width: 100, alignment: .leading)

                ZStack(alignment: .leading) {
                    if editingExaKey {
                        if exaKey.isEmpty {
                            Text(L("model.exaPasteKey"))
                                .font(.sf(13))
                                .foregroundStyle(Tokens.text2)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $exaKey)
                            .textFieldStyle(.plain)
                            .font(.sf(13))
                            .foregroundStyle(Tokens.text1)
                            .disabled(exaEnvOverride)
                            .onSubmit { saveExaKey() }
                            // Typing here must hold off the hover-leave fold too.
                            .onChange(of: exaKey) { model.noteUserTyping() }
                    } else {
                        Text(maskedExaKey)
                            .font(.sf(13))
                            .foregroundStyle(Tokens.text2)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(editingExaKey ? 0.06 : 0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(editingExaKey ? 0.12 : 0.07), lineWidth: 0.5)
                )
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

            // Only the live env-override status stays inline; the how-to note
            // moved into the ⓘ above.
            if exaEnvOverride {
                Text(L("model.footer.env", "EXA_API_KEY"))
                    .font(.sf(11))
                    .foregroundStyle(Tokens.text4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 88)
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
                HStack(spacing: 3) {
                    Text(L("model.anysearchApiKey"))
                        .font(.sf(13, weight: .medium))
                        .foregroundStyle(Tokens.text2)
                        .lineLimit(1)
                    if !anySearchEnvOverride {
                        SettingInfo(anySearchHintText)
                    }
                }
                .frame(width: 100, alignment: .leading)

                ZStack(alignment: .leading) {
                    if editingAnySearchKey {
                        if anySearchKey.isEmpty {
                            Text(L("model.anysearchPasteKey"))
                                .font(.sf(13))
                                .foregroundStyle(Tokens.text2)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $anySearchKey)
                            .textFieldStyle(.plain)
                            .font(.sf(13))
                            .foregroundStyle(Tokens.text1)
                            .disabled(anySearchEnvOverride)
                            .onSubmit { saveAnySearchKey() }
                            .onChange(of: anySearchKey) { model.noteUserTyping() }
                    } else {
                        Text(maskedAnySearchKey)
                            .font(.sf(13))
                            .foregroundStyle(Tokens.text2)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(editingAnySearchKey ? 0.06 : 0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(editingAnySearchKey ? 0.12 : 0.07), lineWidth: 0.5)
                )
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

            if anySearchEnvOverride {
                Text(L("model.footer.env", "ANYSEARCH_API_KEY"))
                    .font(.sf(11))
                    .foregroundStyle(Tokens.text4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 88)
            }
        }
    }

    private var anySearchHintText: AttributedString {
        var text = AttributedString(L("model.anysearchHint"))
        var host = AttributedString(L("model.anysearchHint.host"))
        host.link = URL(string: "https://www.anysearch.com/console/api-keys")
        host.foregroundColor = Tokens.text2
        text.append(host)
        return text
    }

    /// The connectivity-test result, shown as a restrained inline pill rather than
    /// the old harsh filled-circle-plus-red-text. A small status dot (the only
    /// saturated mark), the verdict in a softened status color, sitting on a faint
    /// wash of that same color so it reads as a calm badge inside the glass — green
    /// for a working key, red for a rejected one, never shouting.
    @ViewBuilder
    private func testVerdict(_ result: ConnectivityTest.Result) -> some View {
        statusPill(ok: result.isOK, message: result.message)
    }

    /// The status line under a key/account field. Success reads as a quiet aside —
    /// a small green dot and faint text in the same register as the rest of the
    /// panel — while a failure keeps the louder red pill so a real problem still
    /// catches the eye.
    @ViewBuilder
    private func statusPill(ok: Bool, message: String) -> some View {
        if ok {
            Text(message)
                .font(.sf(11.5))
                .foregroundStyle(Tokens.text3)
                .padding(.top, 1)
        } else {
            // A failure stays a touch heavier so it reads as a problem, but in the
            // same neutral ink as the rest of the panel — no coloured dot, no pill.
            Text(message)
                .font(.sf(11.5, weight: .medium))
                .foregroundStyle(Tokens.text2)
                .padding(.top, 1)
        }
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
                    .font(.sf(13, weight: .medium))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: 64, alignment: .leading)

                if openRouterConnected {
                    // Same masked, read-only summary as the saved key row.
                    Text(maskedKey)
                        .font(.sf(13))
                        .foregroundStyle(Tokens.text2)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.white.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                        )

                    if testing {
                        ProgressView().controlSize(.small)
                    } else {
                        SettingActionButton(title: L("model.test")) { test() }
                    }
                    SettingActionButton(title: L("model.disconnect")) { disconnectOpenRouter() }
                } else {
                    switch orAuth.phase {
                    case .waiting, .exchanging:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(orAuth.phase == .exchanging
                                 ? L("model.connecting")
                                 : L("model.finishSignIn"))
                                .font(.sf(12.5))
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
                    .padding(.leading, 76)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if openRouterConnected, let result = testResult {
                testVerdict(result)
                    .padding(.leading, 76)
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
                    .font(.sf(13, weight: .medium))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: 64, alignment: .leading)

                if !installed {
                    // No CLI yet → link to install docs (there's nothing to sign into).
                    codexPillButton(L("codex.status.getCodex")) {
                        NSWorkspace.shared.open(Provider.codex.signupURL)
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
                .font(.sf(12))
                .foregroundStyle(Tokens.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 76)
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
                    .font(.sf(13, weight: .medium))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: 64, alignment: .leading)

                if !installed {
                    // No CLI yet → link to the install docs.
                    codexPillButton(L("claudecode.status.get")) {
                        NSWorkspace.shared.open(Provider.claudeCode.signupURL)
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
                .font(.sf(12))
                .foregroundStyle(Tokens.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 76)
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
                    .font(.sf(13, weight: .medium))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: 64, alignment: .leading)

                if !installed {
                    // No CLI yet → link to install docs (there's nothing to sign into).
                    codexPillButton(L("grok.status.get")) {
                        NSWorkspace.shared.open(Provider.grokCode.signupURL)
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
                .font(.sf(12))
                .foregroundStyle(Tokens.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 76)
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
                    .font(.sf(13, weight: .medium))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: 64, alignment: .leading)

                if !installed {
                    // No CLI yet → link to the install docs.
                    codexPillButton(L("commandcode.status.get")) {
                        NSWorkspace.shared.open(Provider.commandCode.signupURL)
                    }
                } else {
                    statusPill(ok: signedIn,
                               message: L(signedIn ? "commandcode.status.connected"
                                                   : "commandcode.status.signedOut"))
                }
            }

            Text(installed
                 ? (signedIn ? L("commandcode.status.hint.ready") : L("commandcode.status.hint.login"))
                 : L("commandcode.status.hint.install"))
                .font(.sf(12))
                .foregroundStyle(Tokens.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 76)
        }
    }

    /// A quiet pill button in the account row's register (Get Codex / Sign in /
    /// Re-authorize) — same chrome as the OpenRouter Connect button.
    private func codexPillButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.sf(13, weight: .medium))
            .foregroundStyle(Tokens.text1)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(.white.opacity(0.10)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.20), lineWidth: 0.5))
            .contentShape(Capsule())
    }

    /// The primary action of the whole onboarding: one click, sign in (or sign
    /// up, free) in the browser, and the key arrives by itself. Slightly brighter
    /// than the surrounding chips because it IS the setup.
    @State private var connectHovering = false

    private var connectButton: some View {
        Button {
            testResult = nil
            orAuth.connect()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "link")
                    .font(.sf(11, weight: .semibold))
                Text(L("model.connectOpenRouter"))
                    .font(.sf(13, weight: .medium))
            }
            .foregroundStyle(Tokens.text1)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .prominentSurface(in: Capsule(), lit: connectHovering)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { connectHovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: connectHovering)
    }

    /// Drop the stored OpenRouter key and return the row to its Connect state.
    /// (The key created during Connect stays in the user's OpenRouter account —
    /// they can revoke it at openrouter.ai/settings/keys.)
    private func disconnectOpenRouter() {
        APIKeyStore.save("", for: .openrouter)   // empty clears the entry
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
        return modelID.isEmpty ? provider.defaultModel : modelID
    }

    /// The closed trigger names the current value; once opened, every single-choice
    /// menu keeps that context with the same native checkmark row.
    @ViewBuilder
    private func menuOption(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    /// Step one: **which backend answers.** A plain menu of every provider, split
    /// into the ones that can answer right now and the ones that still need a key —
    /// so the useful half is never buried among a dozen unconfigured vendors.
    ///
    /// Picking an unconfigured provider is a legitimate move (it's how you get to a
    /// new vendor's key field): the switch goes through, and `keySection` unfolds
    /// itself on the spot because `setupRequired` now holds.
    private var providerRow: some View {
        settingRow(label: L("model.provider")) {
            GlassMenu(title: provider.displayName) {
                let ready = Provider.allCases.filter(providerReady)
                let unready = Provider.allCases.filter { !providerReady($0) }
                if !ready.isEmpty {
                    SwiftUI.Section(L("model.picker.configured")) {
                        ForEach(ready) { p in
                            Button { selectProvider(p) } label: {
                                menuOption(p.displayName, selected: p == provider)
                            }
                        }
                    }
                }
                if !unready.isEmpty {
                    SwiftUI.Section(L("model.picker.unconfigured")) {
                        ForEach(unready) { p in
                            Button { selectProvider(p) } label: {
                                menuOption(p.displayName, selected: p == provider)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Step two: **which of that provider's models.** The picker card is the same
    /// one the ⌘⇧I summon opens, locked to the chosen provider — its search and its
    /// fold both work over that provider's catalog alone.
    private var modelRow: some View {
        settingRow(label: L("model.label")) {
            HStack(spacing: 6) {
                // The chip anchors the model picker as a native popover.
                // A popover opens in its own window outside the island's tracking
                // area, so `model.isModelPickerOpen` suspends the panel's
                // leave-collapse for as long as it's up (see NotchModel).
                Button {
                    modelPickerOpen = true
                } label: {
                    HStack(spacing: 7) {
                        // The model wears its vendor mark and reads by name — the
                        // chip is about the model, not the plumbing behind it.
                        VendorLogo(vendor: ModelRatings.vendor(for: effectiveModelID,
                                                              provider: provider),
                                   fallback: effectiveModelID)
                            .frame(width: 15, height: 15)
                        // Claude Code's ids are rolling aliases — the chip names the
                        // concrete model behind one ("Opus 5"), not the family word.
                        Text(ModelRatings.prettyName(for: effectiveModelID,
                                                     provider: provider))
                            .font(.sf(13))
                            .foregroundStyle(Tokens.text1)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.sf(10, weight: .semibold))
                            .foregroundStyle(Tokens.text3)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 9)
                    .frame(height: 30)
                    .background(Capsule().fill(.white.opacity(0.06)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                // The system's own menu, dropped from the chip — the provider is
                // settled one row up, so it lists that provider's models flat.
                .modelMenu(isPresented: $modelPickerOpen,
                           models: catalog.rows(selected: provider),
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
                    // Suspend the panel's leave-collapse while the menu is up so
                    // moving the pointer into it (a separate window) never folds the
                    // settings out from under it.
                    model.isModelPickerOpen = modelPickerOpen
                }
                if loadingModels {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - General

    // MARK: - Privacy

    /// Which screens carry a notch island. External monitors get a virtual
    /// notch that nests inside their menu bar; the choice applies immediately
    /// (AppDelegate listens and rebuilds the per-screen panels).
    ///
    /// Drawn as a two-card picker rather than a dropdown: "which screens" is a
    /// spatial choice, so each card shows a miniature laptop + external monitor
    /// with a bright pill on every screen that gets an island.
    private var placementRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(L("general.showOn"))
                .font(.sf(13, weight: .medium))
                .foregroundStyle(Tokens.text2)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 64, alignment: .leading)
                // Sit on the cards' first inner line, roughly where the other
                // rows' baseline lands, instead of the cards' outer top edge.
                .padding(.top, 8)
            ForEach(DisplayPlacement.allCases) { p in
                placementCard(p)
            }
            Spacer(minLength: 0)
        }
    }

    private func placementCard(_ p: DisplayPlacement) -> some View {
        let selected = placement == p
        return PickerCard(selected: selected) {
            selectPlacement(p)
        } content: {
            VStack(spacing: 7) {
                HStack(alignment: .bottom, spacing: 8) {
                    MiniDisplay(kind: .laptop, hasIsland: true)
                    MiniDisplay(kind: .external, hasIsland: p == .all)
                }
                // The unselected diagram dims as a whole so the bright pills
                // read as "what you'd get", not as a second active choice.
                .opacity(selected ? 1 : 0.55)
                Text(p.label)
                    .font(.sf(11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Tokens.text1 : Tokens.text3)
                    .lineLimit(1)
            }
        }
    }

    private func selectPlacement(_ newValue: DisplayPlacement) {
        guard newValue != placement else { return }
        placement = newValue
        DisplayPlacement.current = newValue
        NotificationCenter.default.post(name: .displayPlacementChanged, object: nil)
    }

    /// Whether the app shows a Dock icon. Off by default — the notch overlay is a
    /// menu-bar-less accessory — but some users want one place to relaunch or quit
    /// it from. The choice applies immediately (AppDelegate flips the activation
    /// policy).
    ///
    /// Drawn as a two-card picker like the placement row above: "is my icon down
    /// there" is a spatial question, so each card shows a miniature screen with a
    /// Dock strip — one with this app's tile in it, one without.
    private var dockIconRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(L("general.dockIcon"))
                .font(.sf(13, weight: .medium))
                .foregroundStyle(Tokens.text2)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 64, alignment: .leading)
                // Sit on the cards' first inner line, matching the placement row.
                .padding(.top, 8)
            // Ordered "has icon" → "no icon", the same more-to-less direction the
            // placement cards read in.
            ForEach([DockIconVisibility.shown, .hidden]) { v in
                dockIconCard(v)
            }
            Spacer(minLength: 0)
        }
    }

    private func dockIconCard(_ v: DockIconVisibility) -> some View {
        let selected = dockIconVisibility == v
        return PickerCard(selected: selected) {
            selectDockIconVisibility(v)
        } content: {
            VStack(spacing: 7) {
                MiniDock(hasIcon: v == .shown)
                    // The unselected diagram dims as a whole so the lit tile
                    // reads as "what you'd get", not as a second active choice.
                    .opacity(selected ? 1 : 0.55)
                Text(v.label)
                    .font(.sf(11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Tokens.text1 : Tokens.text3)
                    .lineLimit(1)
            }
        }
    }

    /// Whether the app puts its icon in the menu bar. Shown by default — it's the
    /// one handle that works when the notch is behind a full-screen app and the
    /// summon shortcut has been forgotten. The choice applies immediately
    /// (AppDelegate adds/removes the status item).
    private var menuBarIconRow: some View {
        settingRow(label: L("general.menuBarIcon")) {
            GlassMenu(title: menuBarIconVisibility.label) {
                ForEach(MenuBarIconVisibility.allCases) { v in
                    Button { selectMenuBarIconVisibility(v) } label: {
                        menuOption(v.label, selected: v == menuBarIconVisibility)
                    }
                }
            }
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
                GlassMenu(title: noteDestination.label) {
                    ForEach(NoteDestination.allCases) { d in
                        Button { selectNoteDestination(d) } label: {
                            menuOption(d.label, selected: d == noteDestination)
                        }
                    }
                }
                if noteDestination == .markdownFolder {
                    HStack(spacing: 10) {
                        Text(notesFolderDisplay)
                            .font(.sf(12))
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

    /// Whether Notch launches itself when you log in. Off by default; flipping it
    /// on registers a login item via `SMAppService` so the notch is there from the
    /// first hover after every restart, with no manual relaunch.
    /// Custom instructions (XII-137): one short line of personal preference the
    /// model gets appended after its built-in persona on the Ask path — "always
    /// answer in English", "prefer code", "metric units". Capped at
    /// `NotchModel.customInstructionsLimit` chars (the binding truncates), empty by
    /// default. Deliberately understated: the hint says it refines, never that it
    /// overrides the core rules.
    private var customInstructionsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text(L("general.customInstructions"))
                    .font(.sf(13))
                    .foregroundStyle(Tokens.text1)
            }
            ZStack(alignment: .topLeading) {
                if model.customInstructions.isEmpty {
                    Text(L("general.customInstructions.placeholder"))
                        .font(.sf(13))
                        .foregroundStyle(Tokens.text3)
                        .allowsHitTesting(false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                TextField("", text: Binding(
                    get: { model.customInstructions },
                    set: { model.customInstructions = $0 }
                ), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .font(.sf(13))
                    .foregroundStyle(Tokens.text1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    // Typing here counts as activity so a drifting pointer can't fold
                    // the panel mid-edit (same guard the API-key field uses).
                    .onChange(of: model.customInstructions) { model.noteUserTyping() }
            }
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(.white.opacity(0.06))
            )
        }
    }

    private var launchAtLoginRow: some View {
        settingRow(label: L("general.launchAtLogin")) {
            Toggle("", isOn: Binding(
                get: { launchAtLogin },
                set: { Haptics.levelChange(); selectLaunchAtLogin($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.text2)
        }
    }

    // MARK: - System permissions

    /// The protected capabilities Notchi currently consumes. Keeping the list in
    /// General makes the system's invisible TCC state explicit, and the trailing
    /// action gives every missing permission a recovery path in the same place.
    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { permissionsSectionOpen.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.sf(9, weight: .semibold))
                        .rotationEffect(.degrees(permissionsSectionOpen ? 90 : 0))
                    Text(L("permissions.title"))
                        .font(.sf(12, weight: .medium))
                }
                .foregroundStyle(Tokens.text1)
                .padding(.horizontal, 10)
                .frame(height: 26)
                // The disclosure's own glass chip — a translucent pill that
                // brightens under the pointer, so the fold itself reads as a
                // control on the panel's glass rather than a bare line of text.
                .background(
                    Capsule()
                        .fill(.white.opacity(hoveredDisclosure == .permissions ? 0.12 : 0.06))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(hoveredDisclosure == .permissions ? 0.22 : 0.12),
                                      lineWidth: 0.5)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { hoveredDisclosure = .permissions }
                else if hoveredDisclosure == .permissions { hoveredDisclosure = nil }
            }
            .animation(.easeOut(duration: Tokens.hoverFade), value: hoveredDisclosure)

            if permissionsSectionOpen {
                VStack(alignment: .leading, spacing: 9) {
                    permissionRow(label: L("permissions.reminders"),
                                  status: remindersPermission) {
                        requestRemindersPermission()
                    }
                    permissionRow(label: L("permissions.notes"),
                                  status: notesPermission) {
                        requestNotesPermission()
                    }
                    permissionRow(label: L("permissions.notifications"),
                                  status: notificationsPermission) {
                        requestNotificationsPermission()
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func permissionRow(label: String,
                               status: SettingsPermissionStatus,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.sf(13, weight: .medium))
                .foregroundStyle(Tokens.text2)
                .lineLimit(1)
            Spacer(minLength: 12)
            PermissionStatusPill(status: status, action: action)
        }
    }

    private func refreshPermissions() {
        remindersPermission = Self.remindersStatus()

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = Self.notificationsStatus(settings.authorizationStatus)
            Task { @MainActor in notificationsPermission = status }
        }

        refreshNotesPermission()
    }

    private static func remindersStatus() -> SettingsPermissionStatus {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .authorized, .fullAccess: return .granted
        case .notDetermined:           return .notDetermined
        case .denied, .restricted:     return .denied
        case .writeOnly:               return .denied
        @unknown default:              return .unavailable
        }
    }

    private static func notificationsStatus(
        _ status: UNAuthorizationStatus
    ) -> SettingsPermissionStatus {
        switch status {
        case .authorized, .provisional, .ephemeral: return .granted
        case .notDetermined:                       return .notDetermined
        case .denied:                              return .denied
        @unknown default:                          return .unavailable
        }
    }

    private func requestRemindersPermission() {
        guard remindersPermission != .denied else {
            openPrivacySettings("Privacy_Reminders")
            return
        }
        remindersPermission = .checking
        EKEventStore().requestFullAccessToReminders { _, _ in
            Task { @MainActor in remindersPermission = Self.remindersStatus() }
        }
    }

    private func requestNotificationsPermission() {
        guard notificationsPermission != .denied else {
            openSystemSettings("com.apple.Notifications-Settings.extension")
            return
        }
        notificationsPermission = .checking
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let status = Self.notificationsStatus(settings.authorizationStatus)
                Task { @MainActor in notificationsPermission = status }
            }
        }
    }

    /// Apple Events is the one protected API without a public status query for a
    /// dormant target. `AEDeterminePermission…` requires Notes to be running, so
    /// launch it quietly (never activate it or open a window), then ask TCC for
    /// the live state without prompting.
    private func refreshNotesPermission() {
        notesPermission = .checking
        withRunningNotes { app in
            guard let app else {
                notesPermission = .unavailable
                return
            }
            determineNotesPermission(for: app, ask: false)
        }
    }

    private func requestNotesPermission() {
        guard notesPermission != .denied else {
            openPrivacySettings("Privacy_Automation")
            return
        }
        notesPermission = .checking
        withRunningNotes { app in
            guard let app else {
                notesPermission = .unavailable
                return
            }
            determineNotesPermission(for: app, ask: true)
        }
    }

    /// Supply a running Notes process without bringing it to the foreground.
    /// Existing instances are reused; otherwise the app is launched without
    /// activation because the AE permission API only accepts a live target.
    private func withRunningNotes(_ completion: @escaping (NSRunningApplication?) -> Void) {
        if let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Notes").first {
            completion(running)
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Notes") else {
            completion(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
            Task { @MainActor in completion(app) }
        }
    }

    /// This call can block behind the secure consent sheet, so it always runs off
    /// the main thread. The result is then translated back onto the view state.
    private func determineNotesPermission(for app: NSRunningApplication, ask: Bool) {
        let pid = app.processIdentifier
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
            Task { @MainActor in notesPermission = status }
        }
    }

    private func openPrivacySettings(_ anchor: String) {
        openSystemSettings("com.apple.preference.security?\(anchor)")
    }

    private func openSystemSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Whether the island tucks away while a full-screen app covers its screen.
    /// On by default; scoped to the virtual notch on external / non-notched
    /// displays (the built-in hardware notch is physical and never hides). The
    /// choice applies immediately — `AppDelegate` re-evaluates on the toggle.
    private var fullscreenAutoHideRow: some View {
        settingRow(label: L("general.fullscreenAutoHide")) {
            Toggle("", isOn: Binding(
                get: { hideInFullscreen },
                set: { Haptics.levelChange(); selectHideInFullscreen($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.text2)
        }
    }

    /// Whether opening the panel carries in whatever the user had highlighted in
    /// the app they came from (`NotchModel.selectionContext`). On by default; off
    /// stops the accessibility read itself, not just the badge.
    private var selectionContextRow: some View {
        settingRow(label: L("general.selectionContext"),
                   info: L("general.selectionContext.hint")) {
            Toggle("", isOn: Binding(
                get: { model.selectionContextEnabled },
                set: { Haptics.levelChange(); model.selectionContextEnabled = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.text2)
        }
    }

    /// Whether background work flexes the resting notch's busy ears (the verb on
    /// the left shoulder, the elapsed clock on the right). One global switch:
    /// off keeps the closed notch flat for agent runs and detached Ask rounds
    /// alike. The finished badge and the completion notification stay.
    private var liveActivityRow: some View {
        settingRow(label: L("appearance.liveActivity"),
                   info: L("appearance.liveActivity.hint")) {
            Toggle("", isOn: Binding(
                get: { model.liveActivityEnabled },
                set: { Haptics.levelChange(); model.liveActivityEnabled = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.text2)
        }
    }

    /// The collapsed-by-default tail of the General pane: plumbing nobody should
    /// have to walk past to reach the everyday rows. Same quiet disclosure line as
    /// `keySection` — it stays folded until the user opens it, whatever the proxy
    /// currently is.
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { advancedSectionOpen.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.sf(9, weight: .semibold))
                        .rotationEffect(.degrees(advancedSectionOpen ? 90 : 0))
                    Text(L("general.advanced"))
                        .font(.sf(12, weight: .medium))
                }
                .foregroundStyle(Tokens.text1)
                .padding(.horizontal, 10)
                .frame(height: 26)
                // The disclosure's own glass chip — a translucent pill that
                // brightens under the pointer, so the fold itself reads as a
                // control on the panel's glass rather than a bare line of text.
                .background(
                    Capsule()
                        .fill(.white.opacity(hoveredDisclosure == .advanced ? 0.12 : 0.06))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(hoveredDisclosure == .advanced ? 0.22 : 0.12),
                                      lineWidth: 0.5)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { hoveredDisclosure = .advanced }
                else if hoveredDisclosure == .advanced { hoveredDisclosure = nil }
            }
            .animation(.easeOut(duration: Tokens.hoverFade), value: hoveredDisclosure)

            if advancedSectionOpen {
                proxyRow
                    // Unfolds downward out of the disclosure line rather than
                    // popping in at full height.
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }

    /// The proxy the whole app connects through — a manual value is forced onto
    /// both the app's own requests (`ProxyConfig.urlSession`) and the spawned
    /// agent CLIs. Empty = auto: the app follows the system proxy natively, and
    /// the CLIs (which inherit launchd's sparse environment, never the
    /// `HTTPS_PROXY` exported in a shell profile) fall back through the inherited
    /// env, macOS Network settings, then the login shell. The caption spells out
    /// what auto actually resolved to, so an empty field is never a mystery.
    private var proxyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text(L("network.proxy"))
                    .font(.sf(13))
                    .foregroundStyle(Tokens.text1)
                SettingInfo(L("network.proxy.hint"))
            }
            ZStack(alignment: .topLeading) {
                if model.proxyURL.isEmpty {
                    Text(L("network.proxy.placeholder"))
                        .font(.sf(13))
                        .foregroundStyle(Tokens.text3)
                        .allowsHitTesting(false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                TextField("", text: Binding(
                    get: { model.proxyURL },
                    set: { model.proxyURL = $0 }
                ))
                    .textFieldStyle(.plain)
                    .font(.sf(13))
                    .foregroundStyle(Tokens.text1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    // Typing here counts as activity so a drifting pointer can't
                    // fold the panel mid-edit (same guard the API-key field uses).
                    .onChange(of: model.proxyURL) {
                        model.noteUserTyping()
                        refreshProxyStatus()
                    }
            }
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(.white.opacity(0.06))
            )
            Text(proxyStatus)
                .font(.sf(11))
                .foregroundStyle(Tokens.text3)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .onAppear { refreshProxyStatus() }
    }

    /// Resolving can spawn a login shell (the ".zshrc-only proxy" case), so it never
    /// runs on the render path — the caption fills in a beat later.
    private func refreshProxyStatus() {
        Task.detached(priority: .userInitiated) {
            let line = ProxyConfig.statusLine()
            await MainActor.run { proxyStatus = line }
        }
    }

    /// The global selected-text gesture has no keyboard binding: this is its one
    /// setting. A menu fits the three ordered pressure rungs — and under it, the
    /// pad you can actually press, because the words "Light / Medium / Firm" name
    /// a feeling and nothing on a screen can hand you a feeling except letting
    /// you try it.
    private var forceClickPressureRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingRow(label: L("general.forceClickPressure"),
                       info: L("general.forceClickPressure.hint")) {
                GlassMenu(title: forceClickPressure.label) {
                    ForEach(ForceClickPressure.allCases) { pressure in
                        Button { selectForceClickPressure(pressure) } label: {
                            menuOption(pressure.label, selected: pressure == forceClickPressure)
                        }
                    }
                }
            }
            ForceClickTestPad()
                // Hangs under the menu it belongs to, on the controls' column
                // rather than the labels'.
                .padding(.leading, 76)
        }
    }

    private func selectForceClickPressure(_ newValue: ForceClickPressure) {
        guard newValue != forceClickPressure else { return }
        forceClickPressure = newValue
        ForceClickPressure.current = newValue
    }

    /// How readily the resting notch unfurls when the pointer reaches it. The
    /// three ordered policies map directly to a native, tick-mark-only NSSlider:
    /// Low, Balanced, and Instant.
    private var hoverSensitivityRow: some View {
        let controlWidth: CGFloat = 190
        return settingRow(label: L("general.hoverSensitivity"),
                          info: L("general.hoverSensitivity.hint")) {
            VStack(spacing: 1) {
                NativeDetentSlider(value: hoverSensitivityPosition, ticks: HoverSensitivity.allCases.count)
                    .frame(width: controlWidth, height: 22)
                    .accessibilityLabel(L("general.hoverSensitivity"))

                HStack(spacing: 0) {
                    ForEach(HoverSensitivity.allCases) { sensitivity in
                        Text(sensitivity.label)
                            .font(.sf(10.5, weight: sensitivity == hoverSensitivity ? .semibold : .regular))
                            .foregroundStyle(sensitivity == hoverSensitivity ? Tokens.text1 : Tokens.text3)
                            .frame(maxWidth: .infinity,
                                   alignment: sensitivity == .low ? .leading
                                       : (sensitivity == .instant ? .trailing : .center))
                    }
                }
                .frame(width: controlWidth)
            }
        }
    }

    private var hoverSensitivityPosition: Binding<Double> {
        Binding(
            get: {
                Double(HoverSensitivity.allCases.firstIndex(of: hoverSensitivity) ?? 1)
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
        HoverSensitivity.current = newValue
    }

    private func selectHideInFullscreen(_ newValue: Bool) {
        guard newValue != hideInFullscreen else { return }
        hideInFullscreen = newValue
        HideNotchInFullscreen.isEnabled = newValue
        NotificationCenter.default.post(name: .hideNotchInFullscreenChanged, object: nil)
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
            GlassMenu(title: appLanguage.label) {
                ForEach(AppLanguage.allCases) { lang in
                    Button {
                        selectAppLanguage(lang)
                    } label: {
                        if lang == appLanguage {
                            Label(lang.label, systemImage: "checkmark")
                        } else {
                            Text(lang.label)
                        }
                    }
                }
            }
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
    /// copied note/reminder (press ⌘C again to confirm). The prose ("press ⌘C
    /// again to confirm") lives in the ⓘ beside the title.
    private var copySenseRow: some View {
        settingRow(label: L("general.copySense"), info: L("general.copySense.hint")) {
            Toggle("", isOn: Binding(
                get: { model.copySenseEnabled },
                set: { Haptics.levelChange(); model.copySenseEnabled = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.text2)
        }
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
        VStack(alignment: .leading, spacing: 18) {
            promptShortcutsGroup
            ForEach(Array(AppShortcutReference.groups(
                summonHotKey: summonHotKey,
                shortcuts: appShortcuts
            ).enumerated()),
                    id: \.offset) { _, group in
                shortcutGroup(group.title, group.entries)
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
        // Leaving the pane ends recording outright. The armed target used to
        // survive in `@State` while the monitor was dismantled, so coming back
        // silently re-armed the old row and the next chord landed on it.
        .onDisappear { recordingShortcut = nil }
        // Chat can rebind any of these too (`manage_app_settings`). Re-read the
        // stores when it does, so the pane never shows a binding that is no
        // longer the one the app is registering.
        .onReceive(NotificationCenter.default.publisher(for: .summonHotKeyChanged)) { _ in
            summonHotKey = .current
        }
        .onReceive(NotificationCenter.default.publisher(for: .appShortcutsChanged)) { _ in
            appShortcuts = AppShortcutStore.current
        }
        .onReceive(NotificationCenter.default.publisher(for: .promptShortcutsChanged)) { _ in
            promptShortcuts = PromptShortcutStore.current
        }
    }

    /// Prompt shortcuts are a flat list, one row per shortcut, and every row is
    /// its own editor: type the prompt on the left, set the chord on the right.
    /// There is no folded pile and no per-row expand step — nothing to open
    /// before a shortcut can be edited.
    private var promptShortcutsGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The title keeps the text position of every other group's title, and
            // the add chip hangs in an OVERLAY rather than in the row: a 24pt
            // button inside the HStack made this one header 24pt tall, so its text
            // sat ~5pt lower than "Summoning" below it and the block opened with a
            // band of air above the words.
            //
            // The header still RESERVES the chip's full height, with the text
            // pinned to the top of that box. This group is the first thing in the
            // Shortcuts pane, so its title sits at y=0 of the scroll content — a
            // 24pt chip centred on a ~15pt line overflowed ~5pt above the scroll
            // view's edge, which clipped the chip's upper arc clean off.
            Text(L("shortcuts.promptAction"))
                .font(.sf(12.5, weight: .semibold))
                .foregroundStyle(Tokens.text1)
                .frame(maxWidth: .infinity, minHeight: Self.promptAddChipSize,
                       alignment: .topLeading)
                .overlay(alignment: .trailing) {
                    Button {
                        withAnimation(Tokens.stackSpring) {
                            promptShortcuts.append(PromptShortcut())
                        }
                        PromptShortcutStore.save(promptShortcuts)
                    } label: {
                        Image(systemName: "plus")
                            .font(.sf(10.5, weight: .semibold))
                            .foregroundStyle(Tokens.text2)
                            .frame(width: Self.promptAddChipSize,
                                   height: Self.promptAddChipSize)
                    }
                    .buttonStyle(ShortcutChipStyle())
                    .help(L("shortcuts.promptAction.add"))
                }

            // The header box already carries ~9pt of slack below the title text
            // (the chip's height minus the line's); these top pads add the rest of
            // the clearance, so the title reads as a section header rather than as
            // a label stuck to the first row.
            VStack(alignment: .leading, spacing: 5) {
                ForEach(promptShortcuts) { binding in
                    promptShortcutRow(binding)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.top, 10)
        }
    }

    /// Field and chord chip share one height so a row reads as a single control.
    private static let promptRowHeight: CGFloat = 28

    /// The header's add chip — smaller than a row's chips, and the height the
    /// title row reserves so the pane's top edge never shaves it.
    private static let promptAddChipSize: CGFloat = 24

    private func promptShortcutRow(_ binding: PromptShortcut) -> some View {
        let target = EditableShortcut.prompt(binding.id)
        let hovered = hoveredPromptShortcutID == binding.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                ZStack(alignment: .leading) {
                    if binding.prompt.isEmpty {
                        Text(L("shortcuts.promptAction.placeholder"))
                            .font(.sf(12.5))
                            .foregroundStyle(Tokens.text4)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: promptBinding(for: binding.id))
                        .textFieldStyle(.plain)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .font(.sf(12.5))
                        .foregroundStyle(Tokens.text1)
                }
                .padding(.horizontal, 9)
                .frame(height: Self.promptRowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white.opacity(0.11), lineWidth: 0.5))

                // Where a shortcut opens is a low-frequency per-row property, so
                // it lives in the overflow menu rather than as a permanent
                // "Window" chip whose two states differed only by text colour and
                // whose label never named its own opposite. The menu's checkmark
                // is the state readout — the row itself carries no badge for it.
                //
                // One overflow chip now carries both the open-in choice and
                // delete, so the row's tail is a single control instead of three
                // abutting ones. Quiet until hover, like the reset affordance the
                // app-shortcut rows use.
                Menu {
                    // An inline Picker renders as native checkmarked items, which
                    // states the current choice outright rather than leaving it to
                    // be inferred from a chip's shade.
                    Picker("", selection: promptWindowBinding(for: binding.id)) {
                        Text(L("shortcuts.promptAction.openIn.notch")).tag(false)
                        Text(L("shortcuts.promptAction.openIn.window")).tag(true)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    Divider()

                    Button(role: .destructive) {
                        deletePromptShortcut(binding.id)
                    } label: {
                        Text(L("shortcuts.promptAction.delete"))
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.sf(10.5, weight: .semibold))
                        .foregroundStyle(Tokens.text3)
                        // Square frame so the chip style's capsule resolves to a
                        // true circle rather than a vertical oval.
                        .frame(width: Self.promptRowHeight, height: Self.promptRowHeight)
                }
                .menuStyle(.button)
                .buttonStyle(ShortcutChipStyle(rest: 0.055, restStroke: 0.1))
                .menuIndicator(.hidden)
                .help(L("shortcuts.promptAction.more"))
                .accessibilityLabel(L("shortcuts.promptAction.more"))
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)

                Button {
                    shortcutHints[target] = nil
                    recordingShortcut = recordingShortcut == target ? nil : target
                } label: {
                    Text(recordingShortcut == target
                         ? L("general.shortcut.recording")
                         : (binding.shortcut?.displayString ?? L("shortcuts.promptAction.set")))
                        .font(.sf(11.5, weight: recordingShortcut == target ? .semibold : .medium))
                        .foregroundStyle(recordingShortcut == target ? Tokens.text1 : Tokens.text2)
                        .padding(.horizontal, 10)
                        .frame(minWidth: 48, minHeight: Self.promptRowHeight)
                }
                .buttonStyle(ShortcutChipStyle(active: recordingShortcut == target))
            }
            if let hint = shortcutHints[target] {
                Text(hint)
                    .font(.sf(11))
                    .foregroundStyle(Tokens.text3)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .contentShape(Rectangle())
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

    /// The row's open-in choice as a two-value selection, so the overflow menu can
    /// drive it with a checkmarked Picker instead of a blind toggle.
    private func promptWindowBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { promptShortcuts.first(where: { $0.id == id })?.opensInPointerWindow ?? false },
            set: { value in
                guard let index = promptShortcuts.firstIndex(where: { $0.id == id }) else { return }
                let couldRun = promptShortcuts[index].canRunFromHotKey
                promptShortcuts[index].opensBesidePointer = value
                PromptShortcutStore.save(promptShortcuts)
                if couldRun != promptShortcuts[index].canRunFromHotKey {
                    NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
                }
            }
        )
    }

    private func deletePromptShortcut(_ id: UUID) {
        let target = EditableShortcut.prompt(id)
        if recordingShortcut == target { recordingShortcut = nil }
        shortcutHints[target] = nil
        if hoveredPromptShortcutID == id { hoveredPromptShortcutID = nil }
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
            Text(title)
                .font(.sf(12.5, weight: .semibold))
                .foregroundStyle(Tokens.text1)
                .padding(.bottom, 3)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 12) {
                        Text(row.label)
                            .font(.sf(12.5))
                            .foregroundStyle(row.editable == nil ? Tokens.text3 : Tokens.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        if let editable = row.editable {
                            editableShortcutControl(editable, row: row)
                        } else if let note = row.note {
                            Text(note)
                                .font(.sf(12))
                                .foregroundStyle(Tokens.text4)
                        } else {
                            HStack(spacing: 6) {
                                ForEach(Array(row.chords.enumerated()), id: \.offset) { i, chord in
                                    if i > 0 {
                                        Text(L("shortcuts.or"))
                                            .font(.sf(11))
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
                            .font(.sf(11))
                            .foregroundStyle(Tokens.text3)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.vertical, 7)
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
            if target == .summon {
                Menu {
                    Button("Double-tap Command") {
                        restoreSummonDoubleTap(UInt32(cmdKey))
                    }
                    Button("Double-tap Option") {
                        restoreSummonDoubleTap(UInt32(optionKey))
                    }
                } label: {
                    Text(L("general.shortcut.resetTo"))
                        .font(.sf(10.5, weight: .medium))
                        .foregroundStyle(Tokens.text3)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 24)
                }
                .menuStyle(.button)
                .buttonStyle(ShortcutChipStyle(rest: 0.055, restStroke: 0.1))
                .menuIndicator(.hidden)
                .opacity(hoveredShortcutRow == target ? 1 : 0)
                .allowsHitTesting(hoveredShortcutRow == target)
            } else if shortcutIsModified(target) {
                Button {
                    resetShortcut(target)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.sf(10.5, weight: .semibold))
                        .foregroundStyle(Tokens.text3)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(ShortcutChipStyle(rest: 0.055, restStroke: 0.1))
                .help(L("shortcuts.reset"))
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
                    .font(.sf(11.5, weight: recordingShortcut == target ? .semibold : .medium))
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
            }
        }
        .animation(.easeOut(duration: 0.16), value: shortcutIsModified(target))
    }

    private func shortcutIsModified(_ target: EditableShortcut) -> Bool {
        switch target {
        case .summon:
            return summonHotKey != .defaultConfig
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
        case .action(let action):
            AppShortcutStore.conflictOwner(for: chord, editingAction: action)
        case .prompt:
            AppShortcutStore.conflictOwner(for: chord)
        }
        if let appOwner { return appOwner }

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
        case .prompt(let id):
            promptShortcuts.first(where: { $0.id == id })?.shortcut == chord
        case .action:
            true
        }
        let needsGlobalProbe: Bool = switch target {
        case .summon, .prompt: true
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
        case .action(let action):
            AppShortcutStore.set(chord, for: action)
            appShortcuts[action] = chord
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
        case .action(let action):
            AppShortcutStore.reset(action)
            appShortcuts[action] = action.defaultChord
        case .prompt:
            break
        }
    }

    private func restoreSummonDoubleTap(_ modifier: UInt32) {
        recordingShortcut = nil
        let chord = ShortcutChord.doubleTap(modifier)
        if let owner = shortcutConflictOwner(for: chord, editing: .summon) {
            shortcutHints[.summon] = L("shortcuts.conflict.usedBy",
                                       owner)
            return
        }
        shortcutHints[.summon] = nil
        commitSummonHotKey(SummonHotKey(keyCode: 0,
                                        modifiers: 0,
                                        doubleTapModifier: modifier,
                                        enabled: true))
    }

    private func disableSummonHotKey() {
        recordingShortcut = nil
        shortcutHints[.summon] = nil
        var off = summonHotKey
        off.enabled = false
        commitSummonHotKey(off)
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
            .font(.sf(11, weight: .medium))
            .foregroundStyle(readOnly ? Tokens.text4 : Tokens.text2)
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 22)
            .background(
                Capsule()
                    .fill(.white.opacity(readOnly ? 0.025 : 0.07))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        .white.opacity(readOnly ? 0.075 : 0.13),
                        style: StrokeStyle(lineWidth: 0.5,
                                           dash: readOnly ? [2, 2] : [])
                    )
            )
    }

    // MARK: - About

    /// The About pane: who the app is before the version mechanics. An identity
    /// block (name, tagline, one-line description) sits above the Version row so
    /// the panel reads as more than a build number, then a quiet links row hands
    /// off to the source and release pages.
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1 — Identity: who the app is, with the version and its update
            // action right beside the name so "what you're running / is it
            // current" reads as one thought instead of three scattered lines.
            HStack(alignment: .center, spacing: 12) {
                // App icon, if the bundle carries one — falls back gracefully.
                // The catalog asset, not `NSApp.applicationIconImage`: on macOS 26
                // the running app's icon comes back already rendered for the current
                // appearance, and this panel is dark — which handed back a darkened
                // squircle wearing the system's specular rim, reading as a white
                // hairline around the corners. The catalog entry declares no
                // appearance variants, so reading it directly gives the artwork as
                // drawn.
                // The icon ships with the standard macOS ~10% transparent margin
                // (so the Dock renders it correctly), which would otherwise make it
                // read small here. Scale up by the inverse of that footprint so the
                // squircle fills the 44pt frame; the frame clips the bled-out margin.
                if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(1024.0 / 824.0)
                        .frame(width: 44, height: 44)
                        .clipped()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Notchi")
                        .font(.brand(18))
                        .foregroundStyle(Tokens.text1)

                    HStack(spacing: 8) {
                        Text(UpdaterService.currentVersion)
                            .font(.sf(12, weight: .medium))
                            .foregroundStyle(Tokens.text4)
                        // Hairline between the version and its update action, so
                        // the two sit as one row without running together.
                        Rectangle()
                            .fill(.white.opacity(0.12))
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
        }
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
            aboutLink(L("about.update.to", v), weight: .semibold) {
                updater.update()
            }
        case .updating:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(L("about.updating"))
                    .font(.sf(12, weight: .semibold))
                    .foregroundStyle(Tokens.text2)
            }
        case .failed:
            Button {
                NSWorkspace.shared.open(UpdaterService.releasesPage)
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Tokens.danger)
                        .frame(width: 6, height: 6)
                    Text(L("about.updateFailed"))
                        .font(.sf(11.5, weight: .medium))
                        .foregroundStyle(Tokens.danger.opacity(0.92))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule(style: .continuous).fill(Tokens.danger.opacity(0.12)))
                .overlay(Capsule(style: .continuous).strokeBorder(Tokens.danger.opacity(0.22), lineWidth: 0.5))
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        case .checking:
            HStack(spacing: 7) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text(L("about.checking"))
                    .font(.sf(11.5, weight: .medium))
                    .foregroundStyle(Tokens.text3)
            }
        case .upToDate:
            Text(L("about.upToDate"))
                .font(.sf(11.5, weight: .medium))
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

    /// GitHub and X lead the About actions. The four quieter product/support
    /// destinations remain directly visible underneath — no nested menu and no
    /// trip back to the prompt's More menu.
    private var aboutLinks: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                AboutSocialButton(kind: .github,
                                  title: L("about.starGithub")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdaterService.repo)")!)
                }
                AboutSocialButton(kind: .x,
                                  title: L("about.followX")) {
                    NSWorkspace.shared.open(URL(string: "https://x.com/cyrusss_7")!)
                }
                // Takes exactly the width its title needs; the two flexible
                // buttons beside it divide what's left.
                AboutSocialButton(kind: .coffee,
                                  title: L("about.buyCoffee")) {
                    NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/cyrus007")!)
                }
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }

            VStack(spacing: 0) {
                AboutUtilityButton(title: L("about.whatsNew"), leaves: false) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        model.openWhatsNew(on: nil)
                    }
                }

                aboutUtilitySeparator

                AboutUtilityButton(title: L("about.replayIntro"), leaves: false) {
                    replayIntro()
                }

                aboutUtilitySeparator

                AboutUtilityButton(title: L("about.privacy"), leaves: true) {
                    NSWorkspace.shared.open(URL(string: "https://www.notch.website/privacy")!)
                }

                aboutUtilitySeparator

                AboutUtilityButton(title: L("about.feedback"), leaves: true) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdaterService.repo)/issues")!)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.white.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .padding(.top, 12)
        }
    }

    private var aboutUtilitySeparator: some View {
        Rectangle()
            .fill(.white.opacity(0.065))
            .frame(height: 0.5)
            .padding(.leading, 11)
    }

    /// Attribution stays on its own level instead of hiding behind the replay
    /// button's hover help. This makes the bundled recording's author, source,
    /// licence, and the fact that it was edited continuously visible.
    private var licensesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("about.music"))
                .font(.sf(13, weight: .medium))
                .foregroundStyle(Tokens.text1)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                aboutLink("classicals.de") {
                    NSWorkspace.shared.open(URL(string: "https://www.classicals.de")!)
                }
                aboutLink("CC BY 4.0") {
                    NSWorkspace.shared.open(URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                }
            }

            Text(L("about.thinkingOrbs"))
                .font(.sf(13, weight: .medium))
                .foregroundStyle(Tokens.text1)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                aboutLink("thinking-orbs") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Jakubantalik/thinking-orbs")!)
                }
                aboutLink("MIT License") {
                    NSWorkspace.shared.open(URL(string: "https://opensource.org/license/mit")!)
                }
            }
        }
    }

    private enum AboutSocialKind {
        case github, x, coffee
    }

    /// The site's Star button translated to native SwiftUI: on hover the brand
    /// mark exits through the top while the action glyph rises from below. X
    /// uses the same grammar with X's own like-heart red, and Buy Me a Coffee
    /// with its own cup burst, so the three feel related without adding
    /// decorative particles around any of the marks.
    private struct AboutSocialButton: View {
        let kind: AboutSocialKind
        let title: String
        let action: () -> Void

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        private var accent: Color {
            kind == .github
                ? Color(red: 245 / 255, green: 166 / 255, blue: 35 / 255)
                : Color(red: 249 / 255, green: 24 / 255, blue: 128 / 255)
        }

        var body: some View {
            Button(action: action) {
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
                        .font(.sf(12, weight: .medium))
                        .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
                        .lineLimit(1)
                        // The row is narrower than three full titles. Coffee's
                        // is the one that must stay whole, so the other two give
                        // up a little size rather than a tail of letters.
                        .minimumScaleFactor(kind == .coffee ? 1 : 0.78)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 13)
                .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
                .background(
                    Capsule()
                        .fill(.white.opacity(hovering ? 0.075 : 0.04))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(hovering ? 0.16 : 0.08), lineWidth: 0.5)
                )
                // The coffee burst is drawn wider than its slot; keep it inside
                // the button's own edge.
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(AboutSocialPressStyle())
            .scaleEffect(reduceMotion ? 1 : (hovering ? 1.02 : 1))
            .onHover { inside in
                hovering = inside
                // One tap as the button catches under the cursor — the same one
                // the island gets when it snaps open. Only on the way in;
                // leaving is passive.
                if inside { Haptics.alignment() }
            }
            .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.2), value: hovering)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.72),
                       value: hovering)
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
            case .coffee:
                // Buy Me a Coffee's own cup, drawn as a template like the other
                // two marks — the artwork's colour arrives on hover.
                Image("CoffeeMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 17, height: 16)
            }
        }

        /// What rises from below on hover. GitHub and X answer with the glyph of
        /// the action itself; Buy Me a Coffee answers with its own artwork, a
        /// burst of cups, which is why this one isn't a symbol.
        @ViewBuilder
        private var actionMark: some View {
            switch kind {
            case .github:
                Image(systemName: "star.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
            case .x:
                // heart.fill sits smaller in its box than star.fill at the same
                // point size, so it takes a notch more to read equal.
                Image(systemName: "heart.fill")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(accent)
            case .coffee:
                // Deliberately larger than the 17pt mark slot — at slot size the
                // cups are too small to read as cups. It spills into the button's
                // own padding, which the button clips.
                AnimatedGIF(resource: "buy-me-a-coffee", animating: hovering)
                    .frame(width: 40, height: 40)
                    // The cups leave frame up and to the right, so the artwork's
                    // weight sits right of its own centre.
                    .offset(x: -4)
                    .allowsHitTesting(false)
            }
        }
    }

    /// An animated GIF from the bundle. SwiftUI's `Image` shows a single frame,
    /// so this hands the file to AppKit, which plays it. The frames only run
    /// while `animating` is true — a paused hover costs nothing — and each start
    /// rewinds to frame one.
    private struct AnimatedGIF: NSViewRepresentable {
        let resource: String
        let animating: Bool

        private static var cache: [String: Data] = [:]

        private static func data(for resource: String) -> Data? {
            if let hit = cache[resource] { return hit }
            guard let url = Bundle.main.url(forResource: resource, withExtension: "gif"),
                  let data = try? Data(contentsOf: url) else { return nil }
            cache[resource] = data
            return data
        }

        private func loadImage() -> NSImage? {
            Self.data(for: resource).flatMap(NSImage.init(data:))
        }

        /// The frames of a GIF are decoded the first time each one is drawn,
        /// which is paid for mid-playback — the opening reads as a stall. Walking
        /// them once up front, while the panel is merely open, gets that out of
        /// the way before any hover.
        private static func warm(_ image: NSImage?) {
            guard let rep = image?.representations.first as? NSBitmapImageRep,
                  let frames = rep.value(forProperty: .frameCount) as? Int else { return }
            for frame in 0..<frames {
                rep.setProperty(.currentFrame, withValue: frame)
                _ = rep.bitmapData
            }
            rep.setProperty(.currentFrame, withValue: 0)
        }

        private static func rewind(_ image: NSImage?) {
            (image?.representations.first as? NSBitmapImageRep)?
                .setProperty(.currentFrame, withValue: 0)
        }

        func makeNSView(context: Context) -> NSImageView {
            let view = NSImageView()
            view.imageScaling = .scaleProportionallyUpOrDown
            let image = loadImage()
            view.image = image
            view.animates = animating
            DispatchQueue.main.async { Self.warm(image) }
            // An image view's intrinsic size is the file's own pixel size, which
            // would otherwise draw the frames far larger than the seat they were
            // given — the SwiftUI frame only clips, it doesn't shrink AppKit.
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.setContentHuggingPriority(.defaultLow, for: .vertical)
            return view
        }

        func sizeThatFits(_ proposal: ProposedViewSize,
                          nsView: NSImageView,
                          context: Context) -> CGSize? {
            CGSize(width: proposal.width ?? 24, height: proposal.height ?? 24)
        }

        func updateNSView(_ view: NSImageView, context: Context) {
            guard view.animates != animating else { return }
            if animating {
                // Without the rewind a second hover would resume wherever the
                // last one stopped. Rewinding in place keeps the already-decoded
                // frames, which reassigning the image would throw away.
                view.animates = false
                Self.rewind(view.image)
                view.animates = true
            } else {
                view.animates = false
            }
        }
    }

    private struct AboutSocialPressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.68),
                           value: configuration.isPressed)
        }
    }

    /// One of the four secondary About destinations. They return to the original
    /// one-action-per-row rhythm, grouped together underneath the social row.
    private struct AboutUtilityButton: View {
        let title: String
        let leaves: Bool
        let action: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.sf(11.5, weight: .medium))
                        .foregroundStyle(hovering ? Tokens.text1 : Tokens.text3)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: leaves ? "arrow.up.right" : "chevron.right")
                        .font(.system(size: leaves ? 8.5 : 9, weight: .semibold))
                        .foregroundStyle(Tokens.text4)
                        .opacity(hovering ? 1 : 0.6)
                }
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, minHeight: 33, maxHeight: 33)
                .background(Color.white.opacity(hovering ? 0.05 : 0))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
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
                    .font(.sf(11, weight: .medium))
                    .foregroundStyle(hovering ? Tokens.text1 : Tokens.text4)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
    /// but unlike inert body copy it now answers the pointer consistently.
    private struct AboutTextLink: View {
        let title: String
        let weight: Font.Weight
        let action: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(title, action: action)
                .buttonStyle(.plain)
                .font(.sf(12, weight: weight))
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
        .font(.sf(11))
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
    /// model menus line up. Pass `info` to hang a collapsed ⓘ note right after the
    /// label — the same mark the answer footer uses for the model that replied.
    private func settingRow<Content: View>(
        label: String,
        info: String? = nil,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.sf(13, weight: .medium))
                    .foregroundStyle(Tokens.text2)
                    .lineLimit(1)
                    .fixedSize()
                if let info {
                    SettingInfo(info)
                }
            }
            .frame(minWidth: 64, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    // MARK: - Logic (mirrors the old SettingsView)

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
        // Stop the spinner unconditionally — an early return on the staleness
        // guard below used to strand it spinning forever after a mid-fetch
        // provider switch.
        loadingModels = false
        // Guard against a stale response after the user switched providers.
        guard target == provider else { return }
        if let live { catalog.adopt(live, for: target) }
    }

    // MARK: - Cross-provider picker

    /// Pick a model from the cross-provider picker: switch the selected provider
    /// (reusing `selectProvider`, which re-syncs every provider-scoped row), then
    /// save the chosen model under it. Selecting a model within the *current*
    /// provider skips the switch and just persists the model.
    private func selectAcrossProviders(provider newProvider: Provider, model id: String) {
        pendingModel = nil   // any committed pick settles the pending ask
        if newProvider != provider {
            // `selectProvider` resets `modelID` to that provider's stored model;
            // override it with the id the user actually clicked.
            selectProvider(newProvider)
        }
        modelID = id
        APIKeyStore.saveModel(id, for: newProvider)
        // The custom endpoint's Model ID field is another view of the same stored
        // value — keep it in step when the pick came from the picker.
        if newProvider == .custom { customModel = id }
        // An explicit pick is a "recently used" model from the user's point of
        // view — record it so the Ask chip's quick menu keeps it after the
        // selection moves on (picks made here used to vanish from the menu).
        AskModelMRU.record(provider: newProvider, model: id)
        NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
    }

    /// Probe the *stored* key of the key section's provider and surface the
    /// verdict. Test is only offered once a key is saved, so it always checks
    /// what's on disk — never an unsaved draft. Guarded via `canTest`.
    private func test() {
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
        withAnimation(.easeOut(duration: 0.18)) { saved = true }
        if let pending = pendingModel, pending.provider == keyScope {
            selectAcrossProviders(provider: pending.provider, model: pending.id)
        } else {
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

/// The trailing chips in the Shortcuts pane — chord recorders, reset, add. Fully
/// rounded like every other affordance on the island (`PanelBackPill`), and they
/// answer the pointer: wash and hairline brighten on hover, the same easeOut fade
/// every hover on the panel uses. Recording keeps its own brighter, ringed state,
/// which outranks hover so an armed chip never dims when the pointer leaves.
private struct ShortcutChipStyle: ButtonStyle {
    /// The armed / recording chip: brighter wash and a full-weight ring.
    var active: Bool = false
    /// Resting wash and hairline, for chips that sit quieter than a chord (reset).
    var rest: Double = 0.07
    var restStroke: Double = 0.13

    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule().fill(.white.opacity(
                    active ? 0.12 : (hovering ? rest + 0.055 : rest)))
            )
            .overlay(
                Capsule().strokeBorder(
                    .white.opacity(active ? 0.45 : (hovering ? restStroke + 0.11 : restStroke)),
                    lineWidth: active ? 1 : 0.5)
            )
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.72 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

/// Backs the quick-tools popover with the panel's glass instead of the stock light
/// popover chrome. On macOS 13.3+ it replaces the presentation background itself
/// (so no light rim shows around the edges); older systems get the glass painted
/// behind the content as a graceful fallback.
struct GlassPopoverBackground: ViewModifier {
    /// Corner radius of the glass slab — matches the content it wraps (small list
    /// popovers use 10; the larger model-picker card uses 14).
    var cornerRadius: CGFloat = 10
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

        if #available(macOS 13.3, *) {
            content.presentationBackground { slab }
        } else {
            content.background { slab }
        }
    }
}

/// A collapsed explanatory note: a quiet ⓘ that reveals its text in a popover on
/// click, so the settings rows stay a clean stack instead of carrying an always-on
/// caption under each one. Same register as the answer footer's model-info ⓘ — a
/// faint `info.circle` that brightens on hover, over the panel's own glass.
///
/// Takes either a plain string or a pre-built `AttributedString` (for hints with an
/// inline link), so both the terse captions and the "get a key at …" hints collapse
/// behind the same mark.
/// A bare word-action hanging off a settings row — Save / Test / Change /
/// Cancel / Disconnect / Choose…. Fourteen of these were spelled out by hand
/// across the panel as `.buttonStyle(.plain)` + a fixed ink, which made them the
/// one interactive class in the whole app that answered a hover with *nothing*;
/// several also rested at `text1`, brighter than the very row label they hang
/// off, so the eye read the escape hatch before the setting. One control now:
/// quiet at rest (secondary ink, below its label), full ink under the cursor.
struct SettingActionButton: View {
    var title: String
    /// Rest ink. Defaults to the secondary register; a de-emphasised action (a
    /// settled "Saved", a Save with nothing to save) passes something quieter.
    var tone: Color = Tokens.text2
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.sf(11, weight: .semibold))
            .foregroundStyle(hovering ? Tokens.text1 : tone)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

struct SettingInfo: View {
    private let plain: String?
    private let rich: AttributedString?

    @State private var showing = false
    @State private var hovering = false

    init(_ text: String) { plain = text; rich = nil }
    init(_ text: AttributedString) { plain = nil; rich = text }

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.sf(12, weight: .regular))
                .foregroundStyle(hovering ? Tokens.text2 : Tokens.text4)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Group {
                if let rich { Text(rich) } else { Text(plain ?? "") }
            }
            .font(.sf(12))
            .foregroundStyle(Tokens.text2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 240, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .modifier(GlassPopoverBackground())
        }
    }
}

/// A dropdown styled to match the panel instead of the stock `Picker`'s
/// white-on-light `.menu` button (which read as a bright patch on the dark
/// glass). The trigger is a translucent dark chip — faint fill, hairline border,
/// light text, a up/down chevron — that brightens on hover; the popped-open list
/// stays the system's native (dark) context menu. `content` supplies the rows as
/// plain `Button`s that mutate the bound selection.
struct GlassMenu<Content: View>: View {
    var title: String
    /// Tighter fitting for dense rows — the agent card's 25pt bottom bar. The
    /// default is the settings pane's size, where these chips live in 34pt rows.
    var compact: Bool = false
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    private typealias Metrics = (font: CGFloat, chevron: CGFloat, gap: CGFloat,
                                 height: CGFloat, lead: CGFloat, trail: CGFloat)

    /// The compact fitting, one place: a 20pt pill that sits inside a 25pt bar.
    /// Its corner is always height/2 — fully round, the same capsule the effort
    /// slider's thumb and the compose row's chips use.
    // Computed, not stored: a generic type can't hold static storage.
    private static var compactMetrics: Metrics { (11.5, 8, 5, 20, 10, 8) }
    private static var regularMetrics: Metrics { (13, 10, 7, 30, 11, 9) }

    private var metrics: Metrics { compact ? Self.compactMetrics : Self.regularMetrics }
    /// The width a compact chip needs for `title`, measured in the face SwiftUI
    /// will draw it in. Callers that must size a rigid row around the chip (the
    /// agent card's bottom bar) can then do arithmetic instead of a geometry read.
    static func compactWidth(for title: String) -> CGFloat {
        let m = compactMetrics
        let font = NSFont.systemFont(ofSize: m.font, weight: .medium)
        let text = NSAttributedString(string: title, attributes: [.font: font]).size().width
        // text + gap + chevron glyph + both paddings
        return ceil(text) + m.gap + 10 + m.lead + m.trail
    }

    var body: some View {
        let m = metrics
        return Menu {
            content()
        } label: {
            HStack(spacing: m.gap) {
                if !title.isEmpty {
                    Text(title)
                        .font(.sf(m.font, weight: compact ? .medium : .regular))
                        .foregroundStyle(Tokens.text1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.sf(m.chevron, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
            }
            // Icon-only (empty title) pills get symmetric padding so the chevron
            // sits centered; labelled pills keep the tighter trailing inset.
            .padding(.leading, title.isEmpty ? m.trail : m.lead)
            .padding(.trailing, m.trail)
            .frame(height: m.height)
            .recessedSurface(in: Capsule(), lit: hovering)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

/// An invisible helper that captures the next key chord while `active` is true.
/// Installs a local `.keyDown` monitor (scoped to this app's own key window, so
/// it can't see other apps' input) and hands the virtual key code + modifier
/// flags to `onCapture`. Swallowing the event while recording keeps Esc/Space
/// from leaking into the panel underneath. The monitor is torn down the moment
/// `active` flips false or the view disappears — no global tap, no leak.
/// The shared shell behind the placement and Dock-icon picker cards: fixed
/// width, rounded fill + hairline border, and a hover lift that brightens both
/// by the same step the About rows use — so an unselected card answers the
/// pointer instead of sitting dead until it's clicked.
private struct PickerCard<Content: View>: View {
    let selected: Bool
    /// The two-card rows keep the standard width; a three-card row asks for a
    /// narrower one so it still clears the pane's edge.
    var width: CGFloat = 108
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.vertical, 8)
                .frame(width: width)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(.white.opacity((selected ? 0.10 : 0.04) + (hovering ? 0.05 : 0)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(.white.opacity((selected ? 0.40 : 0.10) + (hovering ? 0.10 : 0)),
                                      lineWidth: selected ? 1 : 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
    }
}

/// A native `NSSlider` quantized to a fixed ladder of tick positions — the
/// "multi-segment" control behind the hover-sensitivity row (3 ticks) and the
/// agent card's thinking-strength dial (N ticks). Ticks sit below the track;
/// dragging snaps to the nearest one, so `value` only ever lands on an integer
/// position in `0…ticks-1`.
struct NativeDetentSlider: NSViewRepresentable {
    @Binding var value: Double
    /// Number of detents on the ladder (tick marks + the positions they mark).
    /// Two ticks are the minimum the system allows; 3 = the old
    /// `NativeThreeStepSlider` exactly.
    let ticks: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> NSSlider {
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
        slider.controlSize = .small
        slider.trackFillColor = NSColor.white.withAlphaComponent(0.55)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        // Re-clamp on tick-count changes (e.g. the agent card's rungs can
        // shrink when the armed model changes) so the thumb can't sit past the
        // last detent it's now allowed to hit.
        let max = Double(ticks - 1)
        if value > max { value = max }
        if slider.doubleValue != value {
            slider.doubleValue = value
        }
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }

        @objc func valueChanged(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue
        }
    }
}

/// A miniature screen with a Dock strip along its bottom edge, for the Dock-icon
/// picker: the "Shown" card lights this app's tile inside the strip, the "Hidden"
/// card leaves the strip without it. Same drawing language as `MiniDisplay` so
/// the two diagrams read as a family.
private struct MiniDock: View {
    let hasIcon: Bool

    var body: some View {
        VStack(spacing: 1) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                dock
                    .padding(.bottom, 2)
            }
            .frame(width: 40, height: 23)
            RoundedRectangle(cornerRadius: 1)
                .fill(.white.opacity(0.35))
                .frame(width: 46, height: 2)
        }
    }

    private var dock: some View {
        HStack(spacing: 2) {
            tile(bright: false)
            tile(bright: false)
            if hasIcon { tile(bright: true) }
            tile(bright: false)
        }
        .padding(.horizontal, 2.5)
        .padding(.vertical, 1.5)
        .background(
            RoundedRectangle(cornerRadius: 2.5)
                .fill(.white.opacity(0.16))
        )
    }

    private func tile(bright: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(.white.opacity(bright ? 0.95 : 0.38))
            .frame(width: 4, height: 4)
    }
}

/// A miniature display glyph for the placement picker: a screen with a bright
/// pill on its top edge when it carries a notch island, over a laptop deck or a
/// monitor stand so the pair reads as built-in vs. external at a glance.
private struct MiniDisplay: View {
    enum Kind { case laptop, external }
    let kind: Kind
    /// Whether this screen gets an island under the option being drawn — the
    /// pill and the brighter screen are the whole point of the diagram.
    let hasIsland: Bool

    var body: some View {
        VStack(spacing: kind == .laptop ? 1 : 0) {
            screen
            base
        }
    }

    private var screen: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 3)
                .fill(.white.opacity(hasIsland ? 0.16 : 0.05))
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(.white.opacity(hasIsland ? 0.55 : 0.20), lineWidth: 1)
            if hasIsland {
                Capsule()
                    .fill(.white.opacity(0.95))
                    .frame(width: 10, height: 3)
                    .padding(.top, 2)
            }
        }
        .frame(width: kind == .laptop ? 30 : 34,
               height: kind == .laptop ? 19 : 21)
    }

    @ViewBuilder private var base: some View {
        let tint = Color.white.opacity(hasIsland ? 0.45 : 0.18)
        switch kind {
        case .laptop:
            // The hinge-forward deck, a touch wider than the lid.
            RoundedRectangle(cornerRadius: 1)
                .fill(tint)
                .frame(width: 36, height: 2)
        case .external:
            // Monitor neck + foot.
            VStack(spacing: 0) {
                Rectangle()
                    .fill(tint)
                    .frame(width: 2, height: 3)
                RoundedRectangle(cornerRadius: 1)
                    .fill(tint)
                    .frame(width: 12, height: 2)
            }
        }
    }
}

/// Somewhere to try the rung you just picked.
///
/// "Light / Medium / Firm" names a pressure your finger has to find, and no
/// label, picture or recording can hand that over — you have to press. So this
/// is a live pad: rest the pointer on it, press, and the cap grows under your
/// finger exactly as the herald's does at the pointer, driven by the same
/// `ForceClickPressure.progress` that decides whether the real gesture fires.
/// It can't fire anything — the press is routed here and stops here.
///
/// One reader exists for the trackpad's raw frames (`RawTrackpadPressureSource`),
/// and the app's monitor owns it, so this borrows that stream through
/// `ForceClickProbe` rather than opening a second one.
private struct ForceClickTestPad: View {
    @ObservedObject private var probe = ForceClickProbe.shared

    /// The cap at rest is a cursor's worth of ink and it fills the outline at
    /// the moment the press would fire, so "how much further" is a distance.
    private static let seedWidth: CGFloat = 20
    private static let fullWidth: CGFloat = 128
    private static let height: CGFloat = 20

    private var reached: Double { probe.progress ?? 0 }

    var body: some View {
        if probe.isSupported {
            pad
                // Arming is just "the pointer is on the pad" — which spares the
                // pad any screen-coordinate arithmetic, and means the gesture
                // goes back to opening Notchi the moment you leave.
                .onHover { probe.isArmed = $0 }
                .onDisappear { probe.isArmed = false }
        } else {
            // A mouse or a pre-Force-Touch trackpad never sends pressure, so the
            // setting above it can't do anything either — better said once here
            // than left as a pad that ignores every press.
            Text(L("forceClick.try.unsupported"))
                .font(.sf(11))
                .foregroundStyle(Tokens.text3)
        }
    }

    private var pad: some View {
        VStack(spacing: 7) {
            ZStack {
                // Where the press has to get to.
                Capsule()
                    .strokeBorder(.white.opacity(probe.reached ? 0.55 : 0.18),
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: Self.fullWidth, height: Self.height)
                Capsule()
                    .fill(.white.opacity(probe.reached ? 0.92 : 0.24 + 0.30 * reached))
                    .frame(width: capWidth, height: Self.height)
            }
            Text(probe.reached ? L("forceClick.try.reached") : L("forceClick.try"))
                .font(.sf(11, weight: probe.reached ? .medium : .regular))
                .foregroundStyle(probe.reached ? Tokens.text1 : Tokens.text3)
                .lineLimit(1)
        }
        .frame(width: Self.fullWidth + 24, height: 52)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(.white.opacity(probe.isArmed ? 0.07 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(.white.opacity(probe.isArmed ? 0.18 : 0.10), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
        // The press phase is deliberately unanimated: the finger IS the
        // animation, and an interpolator between the two would make a rung feel
        // like a different rung. Only the arrival flashes on its own.
        .animation(.easeOut(duration: 0.12), value: probe.reached)
        .animation(.easeOut(duration: Tokens.rowFade), value: probe.isArmed)
    }

    private var capWidth: CGFloat {
        Self.seedWidth + (Self.fullWidth - Self.seedWidth) * CGFloat(reached)
    }
}

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
