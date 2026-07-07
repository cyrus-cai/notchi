import AppKit
import Carbon.HIToolbox
import SwiftUI

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

    @State private var provider: Provider = APIKeyStore.selectedProvider
    @State private var apiKey: String = APIKeyStore.stored(for: APIKeyStore.selectedProvider)
    /// Empty string = "use the provider's default" (the sentinel the model menu's
    /// "Default (…)" row binds to).
    @State private var modelID: String = APIKeyStore.storedModel(for: APIKeyStore.selectedProvider)
    @State private var saved = false
    /// False once a key is saved: the row shows a masked, read-only summary of
    /// the stored key (so screenshots never carry the full secret) until the
    /// user explicitly hits Change. Starts true only when nothing is stored.
    @State private var editingKey: Bool =
        APIKeyStore.stored(for: APIKeyStore.selectedProvider).isEmpty
            && !APIKeyStore.hasEnvOverride(for: APIKeyStore.selectedProvider)

    /// Model ids offered in the menu. Seeded from the provider's bundled shortlist,
    /// then replaced by the live `/v1/models` list once it loads (see `refreshModels`).
    @State private var modelOptions: [String] = APIKeyStore.selectedProvider.availableModels
    @State private var loadingModels = false

    /// OpenRouter only: which of `modelOptions`' free models are flagship-class,
    /// per the size ranking done at fetch time (`OpenRouterFreeModels`). Drives
    /// the menu's featured/rest sections; empty until the live list loads.
    @State private var featuredFreeModels: Set<String> = []

    /// Connectivity-test state. `testing` drives the spinner; `testResult` is the
    /// last verdict shown under the key field (nil = nothing tested yet).
    @State private var testing = false
    @State private var testResult: ConnectivityTest.Result?

    /// True while an env var forces a key for the current provider — then the field
    /// is informational only, since the env override wins over what's typed.
    private var envOverride: Bool { APIKeyStore.hasEnvOverride(for: provider) }

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

    /// The user's chosen search backend (Keenable / Exa). Pick one and that's what
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

    private var canSave: Bool {
        guard !envOverride else { return false }
        // Only the API key needs an explicit Save — a model switch auto-persists
        // (see `selectModel`), so it never lights up this button.
        return editingKey
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && apiKey != APIKeyStore.stored(for: provider)
    }

    /// The stored key rendered safe for display: enough of the head and tail to
    /// recognize which key it is, bullets for everything in between. Short keys
    /// mask entirely rather than leak most of their characters.
    private var maskedKey: String {
        let key = APIKeyStore.current(for: provider) ?? APIKeyStore.stored(for: provider)
        guard key.count > 12 else { return String(repeating: "•", count: max(key.count, 8)) }
        return "\(key.prefix(4))••••••••\(key.suffix(4))"
    }

    /// Every option plus, if the saved model isn't in the live/bundled list (a
    /// custom or newly-renamed one), that value too — so selecting it round-trips.
    private var modelRows: [String] {
        var rows = modelOptions
        if !modelID.isEmpty, !rows.contains(modelID) { rows.insert(modelID, at: 0) }
        return rows
    }

    /// The left-hand category list — the point of the column is that the next
    /// setting gets a home without redesigning the panel.
    enum Section: String, CaseIterable, Identifiable {
        case model = "Model"     // provider, API key, model override
        case search = "Search"   // search backend + its key
        case tools = "Tools"     // quick-tool chips + per-tool prefs (translation languages)
        case general = "General" // app-level toggles (shortcut, placement, Dock icon…)
        case about = "About"     // version + self-update
        var id: String { rawValue }

        /// The sidebar label, localized. The raw value stays English (a stable
        /// identity); this is what the user actually reads.
        var title: String {
            switch self {
            case .model:   return L("sidebar.model")
            case .search:  return L("sidebar.search")
            case .tools:   return L("sidebar.tools")
            case .general: return L("sidebar.general")
            case .about:   return L("sidebar.about")
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

    /// Whether the app launches itself at login — seeded from the live system
    /// login-item status (`SMAppService`), not `UserDefaults`. Writes go through
    /// `selectLaunchAtLogin`, which registers/unregisters the item and reverts
    /// this optimistic flag if the OS refuses.
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled

    /// The global summon shortcut — mirrors the persisted value; writes go through
    /// `commitSummonHotKey` so `AppDelegate` re-registers the Carbon hot key.
    @State private var summonHotKey: SummonHotKey = .current
    /// True while the recorder is armed and listening for the next chord. Drives
    /// the "Recording…" affordance and gates the local `NSEvent` monitor.
    @State private var recordingHotKey = false
    /// A transient hint shown under the row when a chord is rejected (e.g. no
    /// modifier), cleared on the next successful record or when recording ends.
    @State private var hotKeyHint: String?

    /// Whether the quick-tools checklist popover is open. A popover (not a native
    /// `Menu`) so toggling a tool keeps the list up — the user can check several in
    /// a row; clicking outside dismisses it.
    @State private var quickToolsOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            HStack(alignment: .top, spacing: 0) {
                sidebar

                // Hairline column boundary, full height of whichever side is taller
                // (the .fixedSize on the HStack is what lets the greedy rectangle
                // resolve to the content height instead of expanding forever).
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 0.5)
                    .frame(maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 14) {
                    switch section {
                    case .model:
                        providerRow
                        // OpenRouter gets the one-click Connect row instead of a
                        // paste field — unless the user asked to paste by hand, or
                        // an env var forces a key (the standard row displays that).
                        if provider == .openrouter && !manualKeyEntry && !envOverride {
                            openRouterAccountRow
                        } else {
                            keyRow
                        }
                        modelRow
                        customInstructionsRow
                        footer
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
                        }
                    case .tools:
                        // Which quick tools appear at all, then the knobs of the
                        // individual tools (today: Translate's language pair),
                        // then the closed-notch copy sensing.
                        quickToolsRow
                        translationLanguageRow
                        copySenseRow
                    case .general:
                        // How you summon it → where it appears → what language it
                        // speaks → how it sits in the system.
                        shortcutRow
                        placementRow
                        appLanguageRow
                        dockIconRow
                        launchAtLoginRow
                    case .about:
                        aboutSection
                    }
                }
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.top, 12)
        }
        .task {
            // Un-throttled freshness check while the user is actually looking at
            // the Version row (one tiny request; failures stay silent).
            updater.check()
            await refreshModels()
        }
        .onChange(of: orAuth.phase) {
            // The OAuth flow just wrote a key from outside this view — sync the
            // cached state, prove the key live (green pill), and load the free
            // model list it unlocks.
            guard orAuth.phase == .connected, provider == .openrouter else { return }
            apiKey = APIKeyStore.stored(for: .openrouter)
            modelID = APIKeyStore.storedModel(for: .openrouter)
            editingKey = false
            manualKeyEntry = false
            orAuth.acknowledge()
            test()
            Task { await refreshModels() }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.allCases) { s in
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
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(selected ? 0.08 : (hovering ? 0.04 : 0)))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    model.closeSettings()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RecentEntryStyle())
            .help(L("settings.back"))

            Text(L("settings.title"))
                .font(.sf(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Tokens.text4)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Rows

    private var providerRow: some View {
        settingRow(label: L("model.provider")) {
            GlassMenu(title: provider.displayName) {
                // Recommended providers (real web search available) sit at the top
                // level. The vendors with no search are demoted into a submenu so the
                // primary list only shows the ones we'd steer a new user toward.
                ForEach(Provider.allCases.filter(\.supportsWebSearch)) { p in
                    Button(p.displayName) { selectProvider(p) }
                }
                Divider()
                Menu(L("model.provider.noSearchGroup")) {
                    // A non-actionable caption row explaining why these are tucked
                    // away, then the providers themselves.
                    Text(L("model.provider.noSearchReason"))
                    Divider()
                    ForEach(Provider.allCases.filter { !$0.supportsWebSearch }) { p in
                        Button(p.displayName) { selectProvider(p) }
                    }
                }
            }
        }
    }

    /// Persist a provider switch and reload that provider's saved key + model, so
    /// each provider keeps its own settings.
    private func selectProvider(_ newValue: Provider) {
        guard newValue != provider else { return }
        provider = newValue
        APIKeyStore.selectedProvider = newValue
        apiKey = APIKeyStore.stored(for: newValue)
        modelID = APIKeyStore.storedModel(for: newValue)
        modelOptions = newValue.availableModels
        featuredFreeModels = []   // stale ranking belonged to the old provider
        saved = false
        testResult = nil   // last verdict belonged to the old provider/key
        editingKey = apiKey.isEmpty && !APIKeyStore.hasEnvOverride(for: newValue)
        manualKeyEntry = false   // back to the Connect row next time OpenRouter shows
        NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
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
                            // A freshly-pasted key unlocks the live model list.
                            .onSubmit { Task { await refreshModels() } }
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
                    if !APIKeyStore.stored(for: provider).isEmpty {
                        Button(L("model.cancel")) { stopEditingKey() }
                            .buttonStyle(.plain)
                            .font(.sf(11, weight: .semibold))
                            .foregroundStyle(Tokens.text2)
                    }
                } else if !envOverride {
                    // Saved state allows a liveness check of the stored key, plus
                    // the way back into editing.
                    if testing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(L("model.test")) { test() }
                            .buttonStyle(.plain)
                            .font(.sf(11, weight: .semibold))
                            .foregroundStyle(Tokens.text1)
                    }
                    Button(L("model.change")) { startEditingKey() }
                        .buttonStyle(.plain)
                        .font(.sf(11, weight: .semibold))
                        .foregroundStyle(Tokens.text1)
                }
                // One control: the button itself flips to "Saved" for a beat after
                // a save, then settles back to "Save" — no separate badge, no green
                // checkmark, just the panel's own light text.
                if editingKey || canSave || saved {
                    Button(saved ? L("model.saved") : L("model.save")) { save() }
                        .buttonStyle(.plain)
                        .font(.sf(11, weight: .semibold))
                        .foregroundStyle(saved ? Tokens.text2 : (canSave ? Tokens.text1 : Tokens.text4))
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
                    Button(searchBackendLabel(b)) { selectSearchBackend(b) }
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
                        Button(L("model.cancel")) { stopEditingKeenableKey() }
                            .buttonStyle(.plain)
                            .font(.sf(11, weight: .semibold))
                            .foregroundStyle(Tokens.text2)
                    }
                } else if !keenableEnvOverride {
                    Button(L("model.change")) { editingKeenableKey = true }
                        .buttonStyle(.plain)
                        .font(.sf(11, weight: .semibold))
                        .foregroundStyle(Tokens.text1)
                }
                if editingKeenableKey || canSaveKeenable || keenableSaved {
                    Button(keenableSaved ? L("model.saved") : L("model.save")) { saveKeenableKey() }
                        .buttonStyle(.plain)
                        .font(.sf(11, weight: .semibold))
                        .foregroundStyle(keenableSaved ? Tokens.text2 : (canSaveKeenable ? Tokens.text1 : Tokens.text4))
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
                        Button(L("model.cancel")) { stopEditingExaKey() }
                            .buttonStyle(.plain)
                            .font(.sf(11, weight: .semibold))
                            .foregroundStyle(Tokens.text2)
                    }
                } else if !exaEnvOverride {
                    Button(L("model.change")) { editingExaKey = true }
                        .buttonStyle(.plain)
                        .font(.sf(11, weight: .semibold))
                        .foregroundStyle(Tokens.text1)
                }
                if editingExaKey || canSaveExa || exaSaved {
                    Button(exaSaved ? L("model.saved") : L("model.save")) { saveExaKey() }
                        .buttonStyle(.plain)
                        .font(.sf(11, weight: .semibold))
                        .foregroundStyle(exaSaved ? Tokens.text2 : (canSaveExa ? Tokens.text1 : Tokens.text4))
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
                        Button(L("model.test")) { test() }
                            .buttonStyle(.plain)
                            .font(.sf(11, weight: .semibold))
                            .foregroundStyle(Tokens.text1)
                    }
                    Button(L("model.disconnect")) { disconnectOpenRouter() }
                        .buttonStyle(.plain)
                        .font(.sf(11, weight: .semibold))
                        .foregroundStyle(Tokens.text1)
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
                        Button(L("model.cancel")) { orAuth.cancel() }
                            .buttonStyle(.plain)
                            .font(.sf(11, weight: .semibold))
                            .foregroundStyle(Tokens.text2)
                    default:
                        connectButton
                        Button(L("model.pasteInstead")) {
                            orAuth.acknowledge()
                            manualKeyEntry = true
                            startEditingKey()
                        }
                        .buttonStyle(.plain)
                        .font(.sf(11, weight: .semibold))
                        .foregroundStyle(Tokens.text3)
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

    /// The primary action of the whole onboarding: one click, sign in (or sign
    /// up, free) in the browser, and the key arrives by itself. Slightly brighter
    /// than the surrounding chips because it IS the setup.
    private var connectButton: some View {
        Button {
            testResult = nil
            orAuth.connect()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .semibold))
                Text(L("model.connectOpenRouter"))
                    .font(.sf(13, weight: .medium))
            }
            .foregroundStyle(Tokens.text1)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(.white.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.white.opacity(0.20), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
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
        !testing && !envOverride
            && !APIKeyStore.stored(for: provider).isEmpty
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
        apiKey = APIKeyStore.stored(for: provider)
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

    /// What the model chip shows: the saved id, or the resolved default when the
    /// sentinel empty string is selected.
    private var modelLabel: String {
        modelID.isEmpty ? L("model.default", provider.defaultModel) : modelID
    }

    /// Picking a model from the menu persists it on the spot — no Save step. Only
    /// the model is written (the key is left untouched), then the backend is told
    /// to pick up the new id so the next turn uses it immediately.
    private func selectModel(_ id: String) {
        guard id != modelID else { return }
        modelID = id
        APIKeyStore.saveModel(id, for: provider)
        NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
    }

    private var modelRow: some View {
        settingRow(label: L("model.label")) {
            HStack(spacing: 6) {
                GlassMenu(title: modelLabel) {
                    Button(L("model.default", provider.defaultModel)) { selectModel("") }
                    Divider()
                    if provider == .openrouter {
                        openRouterModelMenuItems
                    } else {
                        ForEach(modelRows, id: \.self) { id in
                            Button(id) { selectModel(id) }
                        }
                    }
                }
                .disabled(envOverride)
                .opacity(envOverride ? 0.5 : 1)
                if loadingModels {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    /// OpenRouter's rotating free lineup, grouped instead of one flat list: the
    /// auto-router (plus any hand-typed id) up top, then the top few free models
    /// ("Best free models", capped at `OpenRouterFreeModels.featuredLimit`),
    /// then the long tail collapsed behind a "More free models ▸" submenu.
    /// Ranking comes from real usage fetched with the live list;
    /// `featuredFreeModels` carries the membership.
    @ViewBuilder
    private var openRouterModelMenuItems: some View {
        let groups = OpenRouterFreeModels.group(modelRows, featured: featuredFreeModels)
        // Drop the id that equals the provider default (the auto-router,
        // `openrouter/free`): the "Default (…)" row above already is it, so
        // listing it here too just reads as a duplicate.
        ForEach(groups.head.filter { $0 != provider.defaultModel }, id: \.self) { id in
            Button(id) { selectModel(id) }
        }
        // `SwiftUI.Section` spelled out — this view's own `Section` enum (the
        // sidebar categories) shadows the SwiftUI type here.
        if !groups.featured.isEmpty {
            SwiftUI.Section(L("model.freeFeatured")) {
                ForEach(groups.featured, id: \.self) { id in
                    Button(id) { selectModel(id) }
                }
            }
        }
        // The long tail is genuinely collapsed: a nested `Menu` in a native
        // menu renders as one "More free models ▸" row that only expands its
        // items when opened — not a flat, always-visible section.
        if !groups.rest.isEmpty {
            Menu(L("model.freeMore")) {
                ForEach(groups.rest, id: \.self) { id in
                    Button(id) { selectModel(id) }
                }
            }
        }
    }

    // MARK: - General

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
        return Button {
            selectPlacement(p)
        } label: {
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
            .padding(.vertical, 8)
            .frame(width: 108)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(.white.opacity(selected ? 0.10 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.white.opacity(selected ? 0.40 : 0.10),
                                  lineWidth: selected ? 1 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
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
    private var dockIconRow: some View {
        settingRow(label: L("general.dockIcon")) {
            GlassMenu(title: dockIconVisibility.label) {
                ForEach(DockIconVisibility.allCases) { v in
                    Button(v.label) { selectDockIconVisibility(v) }
                }
            }
        }
    }

    private func selectDockIconVisibility(_ newValue: DockIconVisibility) {
        guard newValue != dockIconVisibility else { return }
        dockIconVisibility = newValue
        DockIconVisibility.current = newValue
        NotificationCenter.default.post(name: .dockIconVisibilityChanged, object: nil)
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
                // What this field does, collapsed behind an ⓘ beside its title.
                SettingInfo(L("general.customInstructions.hint"))
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
                set: { selectLaunchAtLogin($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.text2)
        }
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

    /// The global summon shortcut. The chip shows the current trigger — the
    /// default reads as ⌥⌥ (double-tap ⌥). Click it to record a chord instead; the
    /// adjacent menu toggles it off (hover-only summon) or resets to double-tap ⌥.
    /// A rejected chord (no modifier, or a reserved combo) surfaces a one-line hint
    /// rather than silently doing nothing.
    private var shortcutRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            settingRow(label: L("general.shortcut")) {
                HStack(alignment: .center, spacing: 6) {
                    Button(action: toggleRecording) {
                        Text(recordingHotKey
                             ? L("general.shortcut.recording")
                             : (summonHotKey.enabled ? summonHotKey.displayString
                                                     : L("general.shortcut.off")))
                            .font(.sf(13, weight: recordingHotKey ? .semibold : .regular))
                            .foregroundStyle(recordingHotKey ? Tokens.text1 : Tokens.text2)
                            .frame(minWidth: 64)
                            .padding(.horizontal, 11)
                            .frame(height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(.white.opacity(recordingHotKey ? 0.12 : 0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .strokeBorder(
                                        .white.opacity(recordingHotKey ? 0.45 : 0.12),
                                        lineWidth: recordingHotKey ? 1 : 0.5
                                    )
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)

                    GlassMenu(title: "") {
                        Button(L("general.shortcut.reset")) { resetSummonHotKey() }
                        Button(L("general.shortcut.disable")) { disableSummonHotKey() }
                    }
                    // Pin to the chip's height: SwiftUI's `Menu` chrome otherwise
                    // makes the control a hair taller than its 30pt label, so it
                    // sat misaligned next to the shortcut chip.
                    .frame(height: 30)
                    .fixedSize()
                }
            }
            if let hint = hotKeyHint {
                Text(hint)
                    .font(.sf(11))
                    .foregroundStyle(Tokens.text3)
                    .padding(.leading, 76)
            }
        }
        // The recorder grabs the next chord via a local event monitor; tear it
        // down if the view goes away mid-recording so it never leaks.
        .background(HotKeyRecorder(active: recordingHotKey, onCapture: captureChord))
    }

    private func toggleRecording() {
        hotKeyHint = nil
        recordingHotKey.toggle()
    }

    /// Validate and commit a recorded chord. Requires a "real" modifier (⌘/⌥/⌃) —
    /// a bare key or shift-only chord would fire far too easily — and refuses the
    /// ⌘, that already opens Settings.
    private func captureChord(keyCode: UInt32, flags: NSEvent.ModifierFlags) {
        let mods = SummonHotKey.carbonModifiers(from: flags)
        let realModifierMask = UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
        let hasRealModifier = (mods & realModifierMask) != 0
        guard hasRealModifier else {
            hotKeyHint = L("general.shortcut.needModifier")
            return
        }
        // Don't let the user shadow ⌘, (opens Settings).
        if keyCode == UInt32(kVK_ANSI_Comma), mods == UInt32(cmdKey) {
            hotKeyHint = L("general.shortcut.reserved")
            return
        }
        recordingHotKey = false
        hotKeyHint = nil
        commitSummonHotKey(SummonHotKey(keyCode: keyCode, modifiers: mods, enabled: true))
    }

    private func resetSummonHotKey() {
        recordingHotKey = false
        hotKeyHint = nil
        commitSummonHotKey(.defaultConfig)
    }

    private func disableSummonHotKey() {
        recordingHotKey = false
        hotKeyHint = nil
        var off = summonHotKey
        off.enabled = false
        commitSummonHotKey(off)
    }

    private func commitSummonHotKey(_ newValue: SummonHotKey) {
        summonHotKey = newValue
        SummonHotKey.current = newValue
        NotificationCenter.default.post(name: .summonHotKeyChanged, object: nil)
    }

    /// The interface language. `System` follows the Mac; the explicit picks
    /// (English / 简体中文 / 繁體中文) each named in their own script. Switching
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

    // MARK: - Tools

    /// Which clipboard quick-tools (Summarize / Translate / Proofread …) appear as
    /// one-tap chips when text is copied (XII-111). A compact dropdown matching the
    /// other rows: the pill shows a summary ("3 enabled"); opening it lists
    /// every tool with a checkmark on the enabled ones. Selecting toggles a tool;
    /// the last enabled one can't be turned off (an empty row would strip the
    /// feature with no way back from here). Changes apply to the next copied clip.
    private var quickToolsRow: some View {
        settingRow(label: L("general.quickTools")) {
            Button {
                quickToolsOpen.toggle()
            } label: {
                HStack(spacing: 7) {
                    Text(L("general.quickTools.count", model.enabledClipboardPresets.count))
                        .font(.sf(13))
                        .foregroundStyle(Tokens.text1)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tokens.text3)
                }
                .padding(.leading, 11)
                .padding(.trailing, 9)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(.white.opacity(quickToolsOpen ? 0.10 : 0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(.white.opacity(quickToolsOpen ? 0.20 : 0.12), lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .fixedSize()
            // A popover (not a native Menu) so checking a tool keeps the list open —
            // the user can toggle several in a row; clicking outside dismisses it.
            .popover(isPresented: $quickToolsOpen, arrowEdge: .bottom) {
                quickToolsChecklist
            }
        }
    }

    /// The checklist shown inside the quick-tools popover: one row per tool, a leading
    /// checkmark on the enabled ones, the whole row tappable to toggle in place (the
    /// popover stays open). The last enabled tool is disabled so the set can't be
    /// emptied with no way back.
    private var quickToolsChecklist: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(NotchModel.ClipboardPreset.allCases) { preset in
                let on = model.enabledClipboardPresets.contains(preset)
                let isLast = on && model.enabledClipboardPresets.count == 1
                QuickToolRow(label: preset.label, on: on, disabled: isLast) {
                    model.setClipboardPreset(preset, enabled: !on)
                }
            }
        }
        .padding(.vertical, 6)
        .preferredColorScheme(.dark)
        // Replace the popover's OWN window backing — not just paint a layer inside
        // it — so no light system chrome shows around the edges (that was the white
        // rim on the earlier opaque version). The presentation background uses the
        // SAME glass the panel uses (`nativeGlass`) over a soft dark veil for text
        // legibility, so the popover reads as a piece of the same surface floated
        // out. `.presentationBackground` needs macOS 13.3+; older systems fall back
        // to the in-content glass layer.
        .modifier(GlassPopoverBackground())
    }

    /// Copy sensing: whether the *closed* notch watches ⌘C and offers to file a
    /// copied note/reminder (press ⌘C again to confirm). The in-panel capture
    /// chip is independent of this switch. A little diagram — a copied card
    /// sliding up into the notch on a ⌘C — carries the idea the way the
    /// placement cards carry "which screen"; it brightens with the toggle so the
    /// on-state reads at a glance.
    private var copySenseRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The prose ("press ⌘C again to confirm") folds into the ⓘ beside the
            // title; the diagram below stays, carrying the idea on its own.
            settingRow(label: L("general.copySense"), info: L("general.copySense.hint")) {
                Toggle("", isOn: Binding(
                    get: { model.copySenseEnabled },
                    set: { model.copySenseEnabled = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Tokens.text2)
            }
            CopySenseDiagram(active: model.copySenseEnabled)
        }
    }

    /// Pref1 picker — the primary language. Writing through `model.translationPref1`
    /// publishes the change so the chip label re-renders immediately.
    private var translationLanguageRow: some View {
        Group {
            settingRow(label: L("translation.pref1")) {
                GlassMenu(title: model.translationPref1.label) {
                    ForEach(TranslationLanguage.allCases) { lang in
                        Button {
                            model.translationPref1 = lang
                        } label: {
                            if lang == model.translationPref1 {
                                Label(lang.label, systemImage: "checkmark")
                            } else {
                                Text(lang.label)
                            }
                        }
                    }
                }
            }
            // The direction rule — when does the secondary ever apply? — collapsed
            // behind the ⓘ beside the second-language title it explains.
            settingRow(label: L("translation.pref2"), info: L("translation.hint")) {
                GlassMenu(title: model.translationPref2.label) {
                    ForEach(TranslationLanguage.allCases) { lang in
                        Button {
                            model.translationPref2 = lang
                        } label: {
                            if lang == model.translationPref2 {
                                Label(lang.label, systemImage: "checkmark")
                            } else {
                                Text(lang.label)
                            }
                        }
                    }
                }
            }
        }
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
                // The icon ships with the standard macOS ~10% transparent margin
                // (so the Dock renders it correctly), which would otherwise make it
                // read small here. Scale up by the inverse of that footprint so the
                // squircle fills the 44pt frame; the frame clips the bled-out margin.
                if let icon = NSApp.applicationIconImage {
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

            // 2 — Links, grouped inside a card so they read as one "more about
            // Notch" block rather than four bare buttons loose on the panel.
            aboutLinks
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
            Button(L("about.update.to", v)) { updater.update() }
                .buttonStyle(.plain)
                .font(.sf(12, weight: .semibold))
                .foregroundStyle(Tokens.text1)
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
                    .tint(Tokens.text3)
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

    /// Quiet text-button links inside one card, split into two labelled groups
    /// so they read as structure rather than four bare buttons: the release
    /// trail (What's New / Releases) up top, the outward links (source on
    /// GitHub, the privacy policy) below a hairline. Same understated language
    /// as the Model footer's signup host. "What's New" lives here as the fixed,
    /// always-available way into the notes, independent of the once-per-version
    /// idle cue.
    private var aboutLinks: some View {
        VStack(alignment: .leading, spacing: 0) {
            aboutLinkGroup(L("about.group.updates"), [
                (L("about.whatsNew"), {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        model.openWhatsNew(on: nil)
                    }
                }),
                (L("about.releases"), {
                    NSWorkspace.shared.open(UpdaterService.releasesPage)
                }),
            ])

            Divider()
                .overlay(.white.opacity(0.08))
                .padding(.vertical, 10)

            aboutLinkGroup(L("about.group.more"), [
                (L("about.github"), {
                    NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdaterService.repo)")!)
                }),
                (L("about.privacy"), {
                    NSWorkspace.shared.open(URL(string: "https://www.notch.website/privacy")!)
                }),
            ])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    /// One captioned group inside the About links card: a faint section label
    /// over its row of links, so each pair announces what it's for.
    private func aboutLinkGroup(_ caption: String, _ links: [(String, () -> Void)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(caption)
                .font(.sf(10.5))
                .foregroundStyle(Tokens.text4)
            HStack(spacing: 16) {
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    aboutLink(link.0, action: link.1)
                }
            }
        }
    }

    private func aboutLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.sf(12, weight: .medium))
            .foregroundStyle(Tokens.text2)
    }

    private var footer: some View {
        Group {
            if envOverride {
                Text(L("model.footer.env", provider.envVarName))
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
    /// opens `provider.signupURL`. The pre/post fragments are localized; the host
    /// itself is the literal domain, so it stays the same in every language.
    private var footerText: AttributedString {
        if provider == .openrouter {
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
        var text = AttributedString(L("model.footer.byok.pre"))
        var host = AttributedString(provider.signupHost)
        host.link = provider.signupURL
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

    /// Replace `modelOptions` with the provider's *live* model list when a key is
    /// available, so the menu reflects what the vendor serves right now. Falls back
    /// to the bundled shortlist on any failure, so the menu is never empty.
    @MainActor
    private func refreshModels() async {
        let target = provider
        // Curated manifest first (no-op when fresh): `availableModels` below reads
        // through it, so keyless providers get the hot-updated shortlist too. The
        // menu is already populated by the callers' synchronous fallback, so
        // awaiting the fetch here never leaves it empty.
        await RemoteModelManifest.refreshIfDue()
        // Same stale-response guard as below: the user may have switched
        // providers while the manifest fetch was in flight.
        guard target == provider else { return }
        guard let key = APIKeyStore.current(for: target) else {
            modelOptions = target.availableModels
            featuredFreeModels = []
            return
        }
        loadingModels = true
        let live = await ModelCatalog.fetch(for: target, apiKey: key)
        // Guard against a stale response after the user switched providers.
        guard target == provider else { return }
        loadingModels = false
        modelOptions = live?.models ?? target.availableModels
        featuredFreeModels = live?.openRouterFeatured ?? []
    }

    /// Probe the *stored* key against the current provider and surface the verdict.
    /// Test is only offered once a key is saved, so it always checks what's on disk
    /// — never an unsaved draft. Guarded against overlapping runs via `canTest`.
    private func test() {
        guard canTest else { return }
        let target = provider
        let key = APIKeyStore.current(for: target) ?? APIKeyStore.stored(for: target)
        testing = true
        testResult = nil
        Task {
            let result = await ConnectivityTest.run(provider: target, apiKey: key)
            await MainActor.run {
                // Drop a stale result if the user switched providers mid-flight.
                guard target == provider else { return }
                testing = false
                withAnimation(.easeOut(duration: 0.2)) { testResult = result }
            }
        }
    }

    private func save() {
        // Only an explicit non-blank edit replaces the stored key — a model-only
        // change saved mid-edit must not wipe it with the empty field.
        if editingKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            APIKeyStore.save(apiKey, for: provider)
        }
        APIKeyStore.saveModel(modelID, for: provider)
        apiKey = APIKeyStore.stored(for: provider)
        modelID = APIKeyStore.storedModel(for: provider)
        if !apiKey.isEmpty {
            withAnimation(.easeOut(duration: 0.16)) { editingKey = false }
        }
        NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
        withAnimation(.easeOut(duration: 0.18)) { saved = true }
        // A newly-saved key may unlock the live model list — refresh it.
        Task { await refreshModels() }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(.easeOut(duration: 0.3)) { saved = false }
        }
    }
}

/// Backs the quick-tools popover with the panel's glass instead of the stock light
/// popover chrome. On macOS 13.3+ it replaces the presentation background itself
/// (so no light rim shows around the edges); older systems get the glass painted
/// behind the content as a graceful fallback.
private struct GlassPopoverBackground: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        // No dark veil — let `nativeGlass` (the high-transparency `.clear` Liquid
        // Glass variant) show at full strength so the wallpaper refracts through and
        // the popover reads as airy glass, not a dark block. Just a faint hairline
        // rim so the edge stays defined.
        if #available(macOS 13.3, *) {
            content.presentationBackground {
                shape.fill(.clear).nativeGlass(in: shape)
                    .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
            }
        } else {
            content.background {
                shape.fill(.clear).nativeGlass(in: shape)
                    .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
            }
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
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(hovering ? Tokens.text2 : Tokens.text4)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
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

/// One row in the quick-tools popover checklist: a leading checkmark on the
/// enabled tools, a hover highlight on the whole row, and a tap that toggles in
/// place (the popover stays open). The last enabled tool comes in `disabled` so
/// the set can't be emptied with no way back from here.
private struct QuickToolRow: View {
    let label: String
    let on: Bool
    let disabled: Bool
    let toggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                // Fixed-size slot, shown/hidden via opacity — NOT via `.clear` color
                // or conditional insertion. Opacity doesn't touch layout, so the
                // checkmark appearing/disappearing on toggle can't nudge the label
                // left or right (the prior jitter came from the symbol's intrinsic
                // width participating in layout as it showed/hid).
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.text1)
                    .frame(width: 14, height: 14, alignment: .center)
                    .opacity(on ? 1 : 0)
                Text(label)
                    .font(.sf(13))
                    .foregroundStyle(on ? Tokens.text1 : Tokens.text2)
                Spacer(minLength: 16)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 184, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(hovering && !disabled ? 0.10 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
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
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 7) {
                if !title.isEmpty {
                    Text(title)
                        .font(.sf(13))
                        .foregroundStyle(Tokens.text1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
            }
            // Icon-only (empty title) pills get symmetric padding so the chevron
            // sits centered; labelled pills keep the tighter trailing inset.
            .padding(.leading, title.isEmpty ? 9 : 11)
            .padding(.trailing, 9)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(.white.opacity(hovering ? 0.10 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.white.opacity(hovering ? 0.20 : 0.12), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// An invisible helper that captures the next key chord while `active` is true.
/// Installs a local `.keyDown` monitor (scoped to this app's own key window, so
/// it can't see other apps' input) and hands the virtual key code + modifier
/// flags to `onCapture`. Swallowing the event while recording keeps Esc/Space
/// from leaking into the panel underneath. The monitor is torn down the moment
/// `active` flips false or the view disappears — no global tap, no leak.
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

/// The copy-sensing diagram: a small notch bar with a copied card tucked just
/// under it and a ⌘C tag alongside — the "press ⌘C and the notch offers it"
/// gesture frozen into one picture, in the same monochrome line-art idiom as
/// `MiniDisplay`. Brightens as a whole when the feature is on, dims when off, so
/// it reads as "what's happening" rather than a second control.
private struct CopySenseDiagram: View {
    /// Whether copy sensing is enabled — drives the same bright/dim split the
    /// placement diagram uses for selected/unselected.
    let active: Bool

    var body: some View {
        let line = Color.white.opacity(active ? 0.55 : 0.20)
        let fill = Color.white.opacity(active ? 0.14 : 0.05)
        let ink  = Color.white.opacity(active ? 0.95 : 0.35)

        VStack(spacing: 5) {
            ZStack(alignment: .top) {
                // Copied card, peeking up into the notch from below.
                RoundedRectangle(cornerRadius: 3)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(line, lineWidth: 1)
                    )
                    .overlay(alignment: .top) {
                        // Two text lines on the card — a note, not an image.
                        VStack(spacing: 2.5) {
                            Capsule().fill(ink).frame(width: 18, height: 1.5)
                            Capsule().fill(ink.opacity(0.6)).frame(width: 12, height: 1.5)
                        }
                        .padding(.top, 9)
                    }
                    .frame(width: 34, height: 22)
                    .padding(.top, 5)

                // The notch bar itself, a black island biting into the top edge.
                Capsule()
                    .fill(.black.opacity(active ? 0.9 : 0.5))
                    .overlay(Capsule().strokeBorder(line, lineWidth: 1))
                    .frame(width: 22, height: 7)
            }
            .frame(width: 40, height: 30)

            // ⌘C caption, the keystroke that files it.
            Text("⌘C")
                .font(.sf(9, weight: .semibold))
                .foregroundStyle(ink)
        }
        .frame(width: 44)
        .animation(.easeOut(duration: 0.16), value: active)
    }
}

private struct HotKeyRecorder: NSViewRepresentable {
    var active: Bool
    var onCapture: (UInt32, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onCapture = onCapture
        return NSView(frame: .zero)
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.onCapture = onCapture
        context.coordinator.setActive(active)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.setActive(false)
    }

    final class Coordinator {
        var onCapture: ((UInt32, NSEvent.ModifierFlags) -> Void)?
        private var monitor: Any?

        func setActive(_ active: Bool) {
            if active, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    // Esc cancels recording without committing anything.
                    guard event.keyCode != UInt16(kVK_Escape) else { return nil }
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    self?.onCapture?(UInt32(event.keyCode), flags)
                    return nil // swallow — don't let the chord reach the panel
                }
            } else if !active, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}
