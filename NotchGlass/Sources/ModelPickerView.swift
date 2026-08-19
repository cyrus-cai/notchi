import SwiftUI
import AppKit

/// One model in the picker's menu: the model itself plus which provider serves it and
/// whether that provider has a usable key. Keyless models still appear (so the user
/// sees what a key would unlock); picking one runs the "Add key" route into that
/// provider's setup instead of switching the backend.
struct PickerModel: Identifiable {
    let provider: Provider
    let providerName: String
    let hasKey: Bool
    /// Whether this model rides above its provider's separator — the shortlist. For
    /// OpenRouter that's the auto-router plus the most-used few of its free lineup;
    /// for other providers, the curated picks topped up with the newest models the
    /// vendor serves; for keyless providers, one representative row. Built by
    /// `ModelCatalogStore.shortlistIDs`.
    let featured: Bool
    let info: ModelInfo
    /// The title the menu item carries. Usually the catalog's own
    /// name, but Claude Code rows are CLI **aliases** ("opus") and a bare family
    /// word names a shelf, not a model — once the CLI probe lands they read as the
    /// concrete model the alias runs today ("Claude Opus 4.8"). Stored rather than
    /// computed so the rows genuinely rebuild when that probe publishes.
    let displayName: String
    /// (provider, id) is unique across the catalog — the same id can appear under
    /// two aggregators, so the pair, not the id alone, identifies a row.
    var id: String { "\(provider.rawValue):\(info.id)" }
}

// MARK: - The picker

/// The model chooser is the **system's own menu** — no card, no search field, no
/// custom list. It was a 300pt floating panel whose rows arrived in one long
/// cross-provider run, which is both more screen than the question deserves and an
/// order nobody could name. An `NSMenu` fixes both at once: the top level is the
/// providers you can call, each one opening its own models, so the ordering is a
/// fact ("who serves it, then that provider's own order") instead of a ranking, and
/// the whole thing occupies exactly as much space as a menu.
///
/// Within a provider, its shortlist (`PickerModel.featured` — the picks plus the
/// newest arrivals) sits above a separator, the rest of the catalog below it, so the
/// good ones are on top without anything becoming unreachable. Providers with no key
/// live under their own section header; picking one of their models runs the "Add
/// key" route rather than switching the backend.
///
/// The menu is a snapshot taken when it opens: a live-model refresh that lands while
/// it's up shows on the next open, which is how every other menu on the system
/// behaves.
extension View {
    /// Pop the model menu from this view's bottom edge when `isPresented` turns true.
    ///
    /// - Parameters:
    ///   - lockedProvider: when set, the provider was already chosen one row up, so
    ///     the menu is that provider's models flat — no provider level at all.
    ///   - centered: hang the menu centred under the anchor (the panel body) rather
    ///     than from its left edge (a chip).
    func modelMenu(isPresented: Binding<Bool>,
                   models: [PickerModel],
                   selectedProvider: Provider,
                   selectedID: String,
                   lockedProvider: Provider? = nil,
                   centered: Bool = false,
                   onSelect: @escaping (Provider, String) -> Void,
                   onConfigure: @escaping (PickerModel) -> Void) -> some View {
        background(
            ModelMenuPresenter(isPresented: isPresented, models: models,
                               selectedProvider: selectedProvider, selectedID: selectedID,
                               lockedProvider: lockedProvider, centered: centered,
                               onSelect: onSelect, onConfigure: onConfigure)
        )
    }
}

/// The AppKit half: an empty view that matches the anchor's frame (it's a
/// `.background`) and pops the menu from it. A menu needs a real `NSView` to
/// position against, which is the only reason this exists.
private struct ModelMenuPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    let models: [PickerModel]
    let selectedProvider: Provider
    let selectedID: String
    let lockedProvider: Provider?
    let centered: Bool
    let onSelect: (Provider, String) -> Void
    let onConfigure: (PickerModel) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        // Decoration only — the SwiftUI content in front of it takes every click.
        v.setAccessibilityElement(false)
        return v
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        guard isPresented, !context.coordinator.showing else { return }
        context.coordinator.showing = true
        // Never from inside a view update: `popUp` runs its own event loop.
        DispatchQueue.main.async { context.coordinator.present(from: view) }
    }

    final class Coordinator: NSObject {
        var parent: ModelMenuPresenter
        /// True from the moment a present is scheduled until the menu closes — a
        /// re-render while the menu is up must not stack a second one.
        var showing = false

        init(_ parent: ModelMenuPresenter) { self.parent = parent }

        // MARK: Presenting

        func present(from view: NSView) {
            // ⌘⇧I can arm the menu while the island is still springing open, and a
            // menu pins to the anchor's frame at present time only — so wait for the
            // anchor to hold still first (`SettledPopover` does the same for the
            // popovers, for the same reason).
            afterSettle(view, frame: view.window?.frame ?? .zero,
                        deadline: Date().addingTimeInterval(1.2)) { [weak view] in
                guard let view, view.window != nil else {
                    self.finish()
                    return
                }
                let menu = self.buildMenu()
                // The anchor's bottom edge in its own coordinates, whichever way the
                // view is flipped — the menu drops from there.
                let bottom = view.isFlipped ? view.bounds.maxY : view.bounds.minY
                let x = self.parent.centered
                    ? max(0, (view.bounds.width - menu.size.width) / 2)
                    : 0
                // Blocks in a nested event loop until the menu closes.
                menu.popUp(positioning: nil, at: NSPoint(x: x, y: bottom), in: view)
                self.finish()
            }
        }

        private func finish() {
            showing = false
            if parent.isPresented { parent.isPresented = false }
        }

        /// Run `action` once the anchor's window has held still for a beat, checking
        /// on short hops (a spring's tail emits no "done" signal), giving up at
        /// `deadline` and running anyway.
        private func afterSettle(_ view: NSView, frame: NSRect, deadline: Date,
                                 _ action: @escaping () -> Void) {
            let now = view.window?.frame ?? .zero
            if now == frame || Date() >= deadline {
                action()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view] in
                    guard let view else { return action() }
                    self.afterSettle(view, frame: now, deadline: deadline, action)
                }
            }
        }

        // MARK: Building

        private func buildMenu() -> NSMenu {
            let menu = NSMenu()
            let models = parent.models
            // Locked to one provider: its models, flat. A single-item provider level
            // would be a step that leads nowhere.
            if let locked = parent.lockedProvider {
                fill(menu, with: models.filter { $0.provider == locked })
                return menu
            }
            var order: [Provider] = []
            var byProvider: [Provider: [PickerModel]] = [:]
            for m in models {
                if byProvider[m.provider] == nil { order.append(m.provider) }
                byProvider[m.provider, default: []].append(m)
            }
            let keyed = order.filter { byProvider[$0]?.first?.hasKey == true }
            let keyless = order.filter { byProvider[$0]?.first?.hasKey != true }
            for p in keyed { menu.addItem(providerItem(p, byProvider[p] ?? [])) }
            // Providers you'd have to set up first, under their own heading and
            // below everything callable — the same "what a key would unlock" shelf
            // the old card kept at the bottom of its list.
            if !keyless.isEmpty {
                if !keyed.isEmpty { menu.addItem(.separator()) }
                menu.addItem(.sectionHeader(title: L("model.picker.unconfigured")))
                for p in keyless { menu.addItem(providerItem(p, byProvider[p] ?? [])) }
            }
            if menu.items.isEmpty { fill(menu, with: []) }
            return menu
        }

        /// One provider: its name, a tick when it's the one in effect, and the model
        /// it's currently serving as the subtitle — so the active model reads off the
        /// top level without opening anything.
        private func providerItem(_ p: Provider, _ models: [PickerModel]) -> NSMenuItem {
            let item = NSMenuItem(title: p.displayName, action: nil, keyEquivalent: "")
            item.state = p == parent.selectedProvider ? .on : .off
            if #available(macOS 14.4, *),
               p == parent.selectedProvider,
               let current = models.first(where: { $0.info.id == parent.selectedID }) {
                item.subtitle = current.displayName
            }
            let sub = NSMenu()
            fill(sub, with: models)
            item.submenu = sub
            return item
        }

        /// A provider's models: the shortlist, then one "More models" item holding the
        /// rest of its catalog. The tail is the long half — dozens of near-duplicate
        /// and single-purpose ids — so it goes behind a door instead of being laid out
        /// under the picks. An empty list still says so rather than opening blank.
        private func fill(_ menu: NSMenu, with models: [PickerModel]) {
            guard !models.isEmpty else {
                let empty = NSMenuItem(title: L("model.picker.empty"), action: nil,
                                       keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
                return
            }
            // The model in effect always rides up top, shortlisted or not — its tick is
            // the one thing the menu must show without opening anything.
            let isCurrent = { (m: PickerModel) in
                m.provider == self.parent.selectedProvider && m.info.id == self.parent.selectedID
            }
            var featured = models.filter { $0.featured || isCurrent($0) }
            var rest = models.filter { !$0.featured && !isCurrent($0) }
            // Nothing shortlisted (a gateway of vendors we ship no mark for): show the
            // catalog itself rather than a lone "More models" wrapping the whole list.
            if featured.isEmpty { featured = rest; rest = [] }
            for m in featured { menu.addItem(modelItem(m)) }
            guard !rest.isEmpty else { return }
            menu.addItem(.separator())
            let more = NSMenuItem(title: L("model.picker.moreModels"), action: nil,
                                  keyEquivalent: "")
            let sub = NSMenu()
            for m in rest { sub.addItem(modelItem(m)) }
            more.submenu = sub
            menu.addItem(more)
        }

        private func modelItem(_ m: PickerModel) -> NSMenuItem {
            let item = NSMenuItem(title: m.displayName, action: #selector(pick(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = Box(m)
            item.state = (m.provider == parent.selectedProvider
                          && m.info.id == parent.selectedID) ? .on : .off
            // A model whose provider has no key can still be picked — it just routes
            // to that provider's key setup instead of switching the backend, and says
            // so rather than sitting there greyed with no explanation. Pre-14.4 has no
            // subtitle to say it in, so the title carries it.
            if !m.hasKey {
                if #available(macOS 14.4, *) {
                    item.subtitle = L("model.picker.addKey")
                } else {
                    item.title = "\(m.displayName)  ·  \(L("model.picker.addKey"))"
                }
            }
            return item
        }

        /// `representedObject` is `Any?`; `PickerModel` is a struct, so it rides in a
        /// class box rather than relying on bridging.
        private final class Box: NSObject {
            let model: PickerModel
            init(_ model: PickerModel) { self.model = model }
        }

        @objc private func pick(_ sender: NSMenuItem) {
            guard let m = (sender.representedObject as? Box)?.model else { return }
            if m.hasKey {
                parent.onSelect(m.provider, m.info.id)
            } else {
                parent.onConfigure(m)
            }
        }
    }
}
// MARK: - Catalog store

/// The catalog every picker reads: what each provider serves, which of those models
/// survive the fold, and which providers are callable at all.
///
/// It's a session-wide store rather than per-view state because the picker now has two
/// front doors — the settings chip and the panel's ⌘⇧I summon — and a per-view cache
/// would re-fetch (and re-fold) the whole catalog for each of them.
@MainActor
final class ModelCatalogStore: ObservableObject {
    static let shared = ModelCatalogStore()

    /// Live `/v1/models` results per provider. Absent = the provider falls back to its
    /// bundled shortlist (`Provider.availableModels`).
    @Published private(set) var liveByProvider: [Provider: [ModelInfo]] = [:]
    /// OpenRouter's usage-ranked ids — what its fold keeps.
    @Published private(set) var featuredByProvider: [Provider: Set<String>] = [:]
    /// Claude Code alias → concrete model id ("opus" → "claude-opus-4-8"), from
    /// `ClaudeCLIService`'s probe. The detail pane shows it as a fact row so the
    /// alias rows still say what they actually run. Empty until a probe lands.
    @Published private(set) var claudeResolved: [String: String] = [:]
    /// Guards against a second picker-open kicking off a duplicate probe run
    /// while the first (seconds of CLI spawns) is still in flight.
    private var claudeResolveInFlight = false

    /// Bumped when a CLI's launch resolution lands. Availability reads are
    /// non-blocking (`resolvedBinaryIfReady`), so a view that rendered before the
    /// probe finished drew the CLI providers as unavailable — this republishes the
    /// store so those rows come back with the real answer.
    @Published private(set) var cliGeneration = 0

    private init() {
        NotificationCenter.default.addObserver(
            forName: .cliAvailabilityResolved, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ModelCatalogStore.shared.cliGeneration &+= 1 }
        }
    }

    /// How many of OpenRouter's usage-ranked free models ride in the picker's unfolded
    /// view. The auto-router sits above them, outside the cap.
    private static let openRouterShortlistLimit = 4

    /// How many rows a keyed provider contributes at rest. Big enough to hold the
    /// curated picks plus a couple of models that landed after the last manifest edit,
    /// small enough that ten configured providers still read as a list rather than a
    /// catalog dump.
    private static let shortlistLimit = 8

    /// Whether `p` can actually serve a request right now. The CLI backends are keyless
    /// (installed + signed in is the test); everyone else needs a stored key.
    static func ready(_ p: Provider) -> Bool {
        switch p {
        case .codex:      return CodexCLIService.isAvailable
        case .claudeCode: return ClaudeCLIService.isAvailable
        case .grokCode:   return GrokCLIService.isAvailable
        case .commandCode: return CommandCodeCLIService.isAvailable
        case .piCode:     return PiCLIService.isAvailable
        // The user's own endpoint needs a URL and a model, not necessarily a key.
        case .custom:     return CustomProvider.isConfigured
        default:          return APIKeyStore.current(for: p) != nil
        }
    }

    /// Commit a pick made outside Settings (the ⌘⇧I picker): switch the serving
    /// provider when it changed, save the model under it, and tell the backend to
    /// rebuild. Settings has its own path (`selectAcrossProviders`), which additionally
    /// re-syncs the provider-scoped rows on screen.
    static func select(provider: Provider, model id: String) {
        if APIKeyStore.selectedProvider != provider {
            APIKeyStore.selectedProvider = provider
        }
        APIKeyStore.saveModel(id, for: provider)
        // An explicit pick counts as "recently used" right away, so the chip's
        // quick menu surfaces it even before the first ask goes out.
        AskModelMRU.record(provider: provider, model: id)
        NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
    }

    /// Kick off the Claude alias→concrete-id probes ("opus" → "claude-opus-5").
    /// Detached and un-awaited: each probe spawns the CLI (seconds), and no picker
    /// should wait on them — consumers fill in reactively when `claudeResolved`
    /// publishes. `refreshResolvedModels` gates itself on the CLI's fingerprint,
    /// so a call that has nothing to learn reads the persisted cache and publishes
    /// instantly. Covers the chat aliases AND the agent picker's ("fable" isn't a
    /// chat alias), so both surfaces get concrete names from one probe run.
    ///
    /// Deliberately *not* gated on `claudeResolved.isEmpty`: Notch is a menu-bar
    /// app that stays up for days, and a once-per-launch probe meant a CLI that
    /// updated underneath it kept showing the previous model until a relaunch.
    /// Re-asking on every picker open is what makes the update land; the real
    /// cost control lives in `refreshResolvedModels`.
    func resolveClaudeAliases() {
        guard !claudeResolveInFlight, ClaudeCLIService.isAvailable
        else { return }
        claudeResolveInFlight = true
        var aliases = Provider.claudeCode.availableModels
        for extra in ["fable", "opus", "sonnet"] where !aliases.contains(extra) {
            aliases.append(extra)
        }
        let probeAliases = aliases
        Task { [weak self] in
            let resolved = await Task.detached(priority: .utility) { () -> [String: String] in
                ClaudeCLIService.refreshResolvedModels(aliases: probeAliases)
                return ClaudeCLIService.resolvedModels
            }.value
            guard let self else { return }
            self.claudeResolveInFlight = false
            if !resolved.isEmpty { self.claudeResolved = resolved }
        }
    }

    /// Forget everything cached for `p`, session cache and catalog cache alike, so
    /// the next picker open refetches. Used when a provider's *endpoint* changes
    /// under it — only the custom one can (see `CustomProvider`).
    func forget(_ p: Provider) {
        liveByProvider[p] = nil
        featuredByProvider[p] = nil
        ModelCatalog.invalidate(p)
    }

    /// Cache a freshly fetched list (Settings fetches the current provider on open).
    func adopt(_ result: ModelCatalog.Result, for p: Provider) {
        guard !result.infos.isEmpty else { return }
        liveByProvider[p] = result.infos
        featuredByProvider[p] = result.openRouterFeatured
    }

    /// Fetch every keyed provider's live model list once, when a picker opens, so the
    /// rows fill in with real names/metadata. Keyless providers are skipped (they show
    /// their bundled list). Cheap and cancel-safe: results just overwrite the cache, a
    /// provider already cached this session is not re-fetched — nor, thanks to
    /// `ModelCatalog`'s own per-provider+key cache, is one fetched in an earlier session.
    func loadAll() async {
        await RemoteModelManifest.refreshIfDue()
        // Codex is keyless, so the keyed loop below skips it. Fetch its real model list
        // from the app-server off-main and publish it so the picker fills in reactively —
        // even if the launch warm-up hasn't finished yet. Never publish the bare "codex"
        // sentinel (that's the no-models-found fallback).
        if liveByProvider[.codex] == nil {
            let ids = await Task.detached(priority: .userInitiated) { () -> [String] in
                CodexCLIService.refreshModels()
                return CodexCLIService.availableModelIDs
            }.value
            if ids != ["codex"] {
                liveByProvider[.codex] = ids.map { ModelInfo(id: $0, vendor: "OpenAI") }
            }
        }
        // Grok is keyless too — its model ids come from the CLI's own cache file
        // (see `GrokCLIService`), read off-main and published so the picker fills in.
        // Never publish the bare "grok" sentinel (the no-models-found fallback).
        if liveByProvider[.grokCode] == nil {
            let ids = await Task.detached(priority: .userInitiated) { () -> [String] in
                GrokCLIService.refreshModels()
                return GrokCLIService.availableModelIDs
            }.value
            if ids != ["grok"] {
                liveByProvider[.grokCode] = ids.map { ModelInfo(id: $0, vendor: "xAI") }
            }
        }
        // pi is keyless too, and the widest aggregator of the five: its catalog is
        // every provider the user has signed pi into (`pi --list-models`), and each
        // id is `<pi-provider>/<model>` — the model half names the real lab, so the
        // rows carry the right mark rather than one house brand (see
        // `PiCLIService.vendor(forID:)`). Never publish the bare sentinel.
        if liveByProvider[.piCode] == nil {
            let ids = await Task.detached(priority: .userInitiated) { () -> [String] in
                PiCLIService.refreshModels()
                return PiCLIService.availableModelIDs
            }.value
            if ids != [PiCLIService.defaultSentinel] {
                liveByProvider[.piCode] = ids.map {
                    ModelInfo(id: $0, vendor: PiCLIService.vendor(forID: $0),
                              name: PiCLIService.displayName(forID: $0))
                }
            }
        }
        // Claude Code's alias→concrete-id mapping, the CLI twin of the fetches
        // below — see `resolveClaudeAliases`.
        resolveClaudeAliases()
        await withTaskGroup(of: (Provider, ModelCatalog.Result?).self) { group in
            for p in Provider.offered where liveByProvider[p] == nil {
                // The custom endpoint joins the fetch as soon as it has a URL —
                // its key is optional, so "no key" must not mean "no catalog"
                // (a local Ollama / LM Studio serves `/v1/models` unauthenticated,
                // and that list is the only way to pick one of its models).
                if p == .custom {
                    guard CustomProvider.chatEndpoint != nil else { continue }
                    let key = APIKeyStore.keyOrEmpty(for: p)
                    group.addTask { (p, await ModelCatalog.fetch(for: p, apiKey: key)) }
                    continue
                }
                guard let key = APIKeyStore.current(for: p) else { continue }
                group.addTask { (p, await ModelCatalog.fetch(for: p, apiKey: key)) }
            }
            for await (p, live) in group {
                if let live { adopt(live, for: p) }
            }
        }
    }

    /// The ids provider `p` contributes to the picker's **collapsed** list — the fold
    /// that keeps a hundred-model catalog from landing as one undifferentiated wall.
    ///
    ///  · **Keyless** providers contribute exactly one row (their default model):
    ///    enough to advertise what a key would unlock, without ten rows you can't call.
    ///  · **OpenRouter** contributes the auto-router plus the top few of its free
    ///    lineup ranked by real usage — millions of users voting with their feet
    ///    (`ModelCatalog` fetches the ranking; `OpenRouterFreeModels.group` cuts it).
    ///  · **Everyone else** contributes their curated shortlist (`availableModels`,
    ///    hot-updated by the remote manifest), intersected with what the live catalog
    ///    actually serves — so an 80-id `/v1/models` dump (embeddings, TTS, whisper…)
    ///    collapses to the handful of chat models we vouch for.
    ///
    /// Everything outside this set still exists in the list — it just lives behind the
    /// picker's "Show all N models" row, and search always reaches it.
    private func shortlistIDs(for p: Provider, infos: [ModelInfo], hasKey: Bool) -> Set<String> {
        guard hasKey else { return Set([infos.first?.id].compactMap { $0 }) }
        if let featured = featuredByProvider[p], !featured.isEmpty {
            let g = OpenRouterFreeModels.group(infos.map(\.id), featured: featured,
                                               limit: Self.openRouterShortlistLimit)
            return Set(g.head + g.featured)
        }
        // The user's own endpoint serves exactly what they chose to host — there's no
        // vendor long tail to cut, and folding a self-hosted model away would leave it
        // unpickable.
        if p == .custom { return Set(infos.map(\.id)) }
        // Nothing live yet: `infos` IS the curated list, so it's already the shortlist.
        guard !infos.isEmpty else { return Set(p.availableModels) }
        let live = Set(infos.map(\.id))
        var keep = Set(p.availableModels.filter(live.contains))
        // Fill the remaining slots with the newest models the vendor serves that the
        // manifest doesn't name. This is the half that maintains itself: a flagship
        // shipped after the last `models.json` edit still shows up, on the vendor's own
        // `created` timestamp, without an app release *or* a manifest deploy. Previews
        // never outrank a stable model — being newest is exactly how an `-exp` build
        // would otherwise take the top slot.
        let fill = infos.filter { !keep.contains($0.id) }
            .enumerated()
            .sorted(by: Self.newerFirst)
            .map(\.element.id)
        keep.formUnion(fill.prefix(max(0, Self.shortlistLimit - keep.count)))
        return keep
    }

    /// **Newest first** — the order every model list in the app is drawn in.
    ///
    /// A vendor's catalog arrives in whatever order its API felt like (roughly
    /// alphabetical for most, insertion order for others), which is why the picker
    /// used to read as a jumble: `gpt-5.4-nano` above `gpt-5.6`, three generations
    /// interleaved. The vendor's own `created` timestamp is the one signal that says
    /// which model is the current one, and it keeps working without a manifest edit.
    ///
    /// Two riders on the date: a preview / experimental build never outranks a
    /// shipped model (being newest is exactly how an `-exp` would otherwise take the
    /// top slot), and models the vendor ships no timestamp for fall in behind the
    /// dated ones in the catalog's own order rather than being scattered at random.
    private static func newerFirst(_ a: (offset: Int, element: ModelInfo),
                                   _ b: (offset: Int, element: ModelInfo)) -> Bool {
        let ap = isPrerelease(a.element.id), bp = isPrerelease(b.element.id)
        if ap != bp { return !ap }
        switch (a.element.created, b.element.created) {
        case let (x?, y?) where x != y: return x > y
        case (_?, nil):                 return true
        case (nil, _?):                 return false
        default:                        return a.offset < b.offset
        }
    }

    /// Whether `id` names a preview / experimental build rather than a shipped model.
    /// Matched loosely and on purpose — the cost of misreading one is that it sorts a
    /// few rows lower, not that it disappears.
    private static func isPrerelease(_ id: String) -> Bool {
        let l = id.lowercased()
        return l.contains("preview") || l.contains("-exp") || l.contains("experimental")
            || l.contains("-beta")
    }

    /// A row's title. Claude Code's ids are the CLI's rolling aliases, so a row
    /// would otherwise read "Opus" — a family, not a model; once the probe has
    /// landed it names the concrete model the alias runs ("Claude Opus 5"). The
    /// account-default sentinel that used to head that list ("claude", shown as
    /// "Default · …") is gone — it was a twin of whichever alias it resolved to,
    /// and "Default" names nothing you can point at.
    private func title(for info: ModelInfo, provider p: Provider) -> String {
        if info.id.isEmpty { return L("model.picker.default") }
        guard p == .claudeCode, let resolved = claudeResolved[info.id]
        else { return info.name }
        return ClaudeCLIService.displayName(forResolved: resolved)
    }

    /// The rows the cross-provider picker shows: every provider's models in one flat
    /// list, ordered as the provider menu is, each tagged with whether it has a usable
    /// key and whether it survives the fold (`featured`). Providers with a key list
    /// their live models (once fetched) or their bundled shortlist; providers without a
    /// key still appear — greyed — so the user sees what a key would unlock and can jump
    /// straight to configuring it. `selected` is the provider in effect: its rows lead.
    func rows(selected: Provider) -> [PickerModel] {
        var rows: [PickerModel] = []
        for p in Provider.offered {
            let hasKey = Self.ready(p)
            let infos: [ModelInfo]
            if let live = liveByProvider[p], !live.isEmpty {
                infos = live
            } else {
                // The provider names the vendor for the ids that don't name their own —
                // Codex's "codex", Claude Code's bare "opus"/"sonnet" aliases — so every
                // row wears its vendor's mark instead of a monogram.
                infos = p.availableModels.map {
                    ModelInfo(id: $0, vendor: ModelRatings.vendor(for: $0, provider: p))
                }
            }
            let short = shortlistIDs(for: p, infos: infos, hasKey: hasKey)
            // Shortlisted models lead their provider's block (the menu splits the block
            // there — picks above, "More models" below), and **within each half the
            // newest model is first** (`newerFirst`). The vendor's own catalog order is
            // only the last tiebreak now.
            let ordered = infos.enumerated().sorted { a, b in
                let af = short.contains(a.element.id), bf = short.contains(b.element.id)
                if af != bf { return af }
                return Self.newerFirst(a, b)
            }.map(\.element)
            var block: [PickerModel] = []
            for info in ordered {
                // A model only earns the resting shortlist if its vendor has a real logo —
                // a monogram letter-tile in the featured list reads as ugly/broken, so the
                // long-tail vendors without a bundled mark fold away (still reachable by
                // search, and a selected one always shows regardless).
                let hasLogo = VendorLogos.mark(for: info.vendor) != nil
                block.append(PickerModel(
                    provider: p, providerName: p.displayName, hasKey: hasKey,
                    featured: short.contains(info.id) && hasLogo, info: info,
                    displayName: title(for: info, provider: p)))
            }
            // The logo gate can zero out a whole provider's shortlist — a gateway fronting
            // vendors we ship no mark for. Now that the fold has no "show all" escape
            // hatch, that would strand the provider behind search, so its first row rides
            // regardless.
            if hasKey, !block.contains(where: \.featured), let first = block.first {
                block[0] = PickerModel(provider: first.provider, providerName: first.providerName,
                                       hasKey: true, featured: true, info: first.info,
                                       displayName: first.displayName)
            }
            rows.append(contentsOf: block)
        }
        // Usable models first (the current provider's leading), greyed ones after — the
        // list reads as "what you can pick now" above "what a key would unlock". A stable
        // secondary sort keeps rows from reshuffling as live lists load.
        return rows.enumerated().sorted { a, b in
            if a.element.hasKey != b.element.hasKey { return a.element.hasKey }
            let aCur = a.element.provider == selected
            let bCur = b.element.provider == selected
            if aCur != bCur { return aCur }
            return a.offset < b.offset
        }.map(\.element)
    }
}

// MARK: - Agent folder recents quick menu

/// The agent compose's "recently worked-in projects" memory — the folder chip's
/// twin of `AskModelMRU`. Fed by every folder that becomes the compose's (a pick,
/// a drop), newest first, persisted in UserDefaults. Folders that have since been
/// moved or deleted are dropped on read rather than offered as dead rows.
enum AgentFolderMRU {
    static let capacity = 6
    private static let defaultsKey = "agent_folder_mru"

    /// Newest first, existing-on-disk only.
    static var entries: [URL] {
        (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func record(_ folder: URL) {
        let path = folder.path
        guard !path.isEmpty else { return }
        var list = (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(capacity)), forKey: defaultsKey)
    }
}

/// What the agent compose's folder chip opens: the Ask recents menu's exact card,
/// listing the projects most recently worked in — a click switches the compose to
/// that folder and dismisses. The tail row ("Change folder") is the way out into
/// the real NSOpenPanel, mirroring the model menu's "More models…" door.
struct AgentFolderPickerView: View {
    let folders: [URL]
    let selected: URL?
    let onSelect: (URL) -> Void
    /// Open the full folder panel. The menu closes on its own first.
    let onBrowse: () -> Void
    let onDone: () -> Void

    @State private var current: URL?
    /// A local keyDown monitor is the only reliable way to own the arrow keys inside a
    /// popover — a focused field editor swallows them before SwiftUI sees them.
    @State private var keyMonitor: Any?

    init(folders: [URL], selected: URL?, onSelect: @escaping (URL) -> Void,
         onBrowse: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.folders = folders
        self.selected = selected
        self.onSelect = onSelect
        self.onBrowse = onBrowse
        self.onDone = onDone
        _current = State(initialValue: selected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(folders, id: \.self) { f in
                MenuCardRow(title: f.lastPathComponent, emphasized: true,
                            selected: f == current) {
                    // Menu semantics: one click picks and dismisses. Clicking the
                    // already-armed row just dismisses.
                    if f != current { arm(f) }
                    onDone()
                }
            }
            // The door out of the recents and into the file panel — not a folder
            // to arm, so the ↑/↓ cursor deliberately skips it.
            Rectangle().fill(.white.opacity(0.07))
                .frame(height: 0.5)
                .padding(.horizontal, MenuCard.rowPad)
                .padding(.vertical, 3)
            MenuCardRow(title: L("agent.folder.switch"), selected: false) {
                onDone()
                onBrowse()
            }
        }
        .padding(MenuCard.cardPad)
        .frame(width: cardWidth, alignment: .leading)
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
    }

    /// Wide enough for the longest folder name, and for the door under them.
    private var cardWidth: CGFloat {
        MenuCard.width(titles: folders.map { ($0.lastPathComponent, nil) }
                        + [(L("agent.folder.switch"), nil)], max: 260)
    }

    private func arm(_ f: URL) {
        current = f
        onSelect(f)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 126: step(-1); return nil               // ↑
            case 125: step(1);  return nil               // ↓
            case 36, 76, 53: onDone(); return nil        // Return / keypad Enter / Esc
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    private func step(_ delta: Int) {
        guard !folders.isEmpty else { return }
        let cur = current.flatMap { folders.firstIndex(of: $0) } ?? -1
        arm(folders[min(max(cur + delta, 0), folders.count - 1)])
    }
}

// MARK: - Ask recents quick menu

/// The Ask side's "recently used models" memory: the (provider, model) pairs most
/// recently asked through, newest first, capped at five. Fed by every chat submit
/// (including one-shot regenerate overrides) and by explicit picks, persisted in
/// UserDefaults so the chip menu remembers across launches. This is what the Ask
/// model chip's quick menu lists — the full cross-provider catalog stays in
/// Settings.
enum AskModelMRU {
    struct Entry: Hashable {
        let provider: Provider
        let model: String
    }

    static let capacity = 5
    private static let defaultsKey = "ask_model_mru"

    /// Newest first. Entries whose provider no longer decodes (a removed enum case
    /// after an update) are dropped rather than crashing the menu.
    static var entries: [Entry] {
        let raw = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return raw.compactMap { line in
            guard let bar = line.firstIndex(of: "|"),
                  let provider = Provider(rawValue: String(line[..<bar]))
            else { return nil }
            let model = String(line[line.index(after: bar)...])
            return model.isEmpty ? nil : Entry(provider: provider, model: model)
        }
    }

    static func record(provider: Provider, model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = Entry(provider: provider, model: trimmed)
        var list = entries
        list.removeAll { $0 == entry }
        list.insert(entry, at: 0)
        UserDefaults.standard.set(
            list.prefix(capacity).map { "\($0.provider.rawValue)|\($0.model)" },
            forKey: defaultsKey)
    }
}

/// What the Ask model chip opens: the agent quick picker's little glass card, on the
/// chat side — one row per recently used model (vendor mark + pretty name), nothing
/// else. Unlike the agent card (which stays open for its effort slider), this is a
/// plain menu: a click picks the model AND closes — one gesture, done. ↑/↓ still
/// arm live for keyboard users (Return / Esc close). The armed row is mirrored in
/// local state because a pick commits straight to UserDefaults, which re-renders
/// nothing on its own.
struct AskRecentModelPickerView: View {
    struct Row: Hashable {
        let provider: Provider
        let id: String
    }

    let rows: [Row]
    let onSelect: (Row) -> Void
    /// The way out of the recents: open Settings' Model pane, where the full
    /// cross-provider catalog lives. The menu closes on its own first.
    let onMoreModels: () -> Void
    let onDone: () -> Void

    @State private var current: Row
    /// A local keyDown monitor is the only reliable way to own the arrow keys inside a
    /// popover — a focused field editor swallows them before SwiftUI sees them.
    @State private var keyMonitor: Any?

    init(rows: [Row], selectedProvider: Provider, selectedModelID: String,
         onSelect: @escaping (Row) -> Void, onMoreModels: @escaping () -> Void,
         onDone: @escaping () -> Void) {
        self.rows = rows
        self.onSelect = onSelect
        self.onMoreModels = onMoreModels
        self.onDone = onDone
        _current = State(initialValue: Row(provider: selectedProvider, id: selectedModelID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(rows, id: \.self) { r in
                MenuCardRow(
                    title: ModelRatings.prettyName(for: r.id, provider: r.provider),
                    // Backends driven by the user's own signed-in CLI wear the tag:
                    // in a list that otherwise means "a key we hold", it says where
                    // this one actually runs and why it needed no setup.
                    accessory: r.provider.isCLI ? "CLI" : nil,
                    // The highlight here means "the model in effect", not "where the
                    // cursor is" — so it carries the emphasized weight, and hover
                    // does NOT move it (arming commits the pick straight to the
                    // store; the `/` menu's follow-the-pointer highlight would
                    // switch models just by sweeping past a row).
                    emphasized: true,
                    selected: r == current) {
                        // Menu semantics: one click picks and dismisses. Clicking
                        // the already-armed row just dismisses.
                        if r != current { arm(r) }
                        onDone()
                    }
            }
            // The tail row out of the recents and into the whole catalog. A
            // hairline sets it apart from the models above: it isn't a model to
            // arm, it's a door — and the ↑/↓ cursor deliberately skips it.
            Rectangle().fill(.white.opacity(0.07))
                .frame(height: 0.5)
                .padding(.horizontal, MenuCard.rowPad)
                .padding(.vertical, 3)
            MenuCardRow(title: L("model.picker.more"), selected: false) {
                onDone()
                onMoreModels()
            }
        }
        .padding(MenuCard.cardPad)
        // Sized by its own rows like the `/` card, capped so one long model id
        // can't stretch the menu across the panel.
        .frame(width: cardWidth, alignment: .leading)
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
    }

    /// Wide enough for every row whole — the models with their CLI tags, and the
    /// "More models…" door under them.
    private var cardWidth: CGFloat {
        let models = rows.map {
            (ModelRatings.prettyName(for: $0.id, provider: $0.provider),
             $0.provider.isCLI ? "CLI" : nil)
        }
        return MenuCard.width(titles: models + [(L("model.picker.more"), nil)], max: 260)
    }

    private func arm(_ r: Row) {
        current = r
        onSelect(r)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 126: step(-1); return nil               // ↑
            case 125: step(1);  return nil               // ↓
            case 36, 76, 53: onDone(); return nil        // Return / keypad Enter / Esc
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    private func step(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let cur = rows.firstIndex(of: current) ?? -1
        arm(rows[min(max(cur + delta, 0), rows.count - 1)])
    }
}

// MARK: - Agent model recents

/// The agent side's "recently run models" memory — `AskModelMRU`'s twin, and what
/// the quick picker's top section lists. Fed by every explicit pick and by every
/// launched run, newest first, persisted in UserDefaults.
///
/// Stored as ONE cross-engine list but read per engine: the picker only ever
/// shows the armed engine's fleet, and a per-engine cap that lived in the store
/// would let a busy engine's picks evict a quiet one's history entirely.
///
/// A nil model — the engine's own CLI-config default — is a real choice here
/// (it's what Codex runs before its model list lands), so it rides as an empty
/// id rather than being dropped on the way in.
enum AgentModelMRU {
    struct Entry: Hashable {
        let engine: AgentEngine
        /// nil = the engine's CLI-config default.
        let model: String?
    }

    /// How much history the store keeps, across every engine. Comfortably more
    /// than the picker shows per engine (`AgentModelPickerView.recentRows`), so
    /// switching engines back and forth doesn't erode either one's list.
    static let capacity = 24
    private static let defaultsKey = "agent_model_mru"

    /// Newest first. Entries whose engine no longer decodes (a removed case
    /// after an update) are dropped rather than crashing the picker.
    static var entries: [Entry] {
        let raw = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return raw.compactMap { line in
            guard let bar = line.firstIndex(of: "|"),
                  let engine = AgentEngine(rawValue: String(line[..<bar]))
            else { return nil }
            let model = String(line[line.index(after: bar)...])
            return Entry(engine: engine, model: model.isEmpty ? nil : model)
        }
    }

    /// One engine's history, newest first.
    static func entries(for engine: AgentEngine) -> [Entry] {
        entries.filter { $0.engine == engine }
    }

    static func record(engine: AgentEngine, model: String?) {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = Entry(engine: engine, model: (trimmed?.isEmpty ?? true) ? nil : trimmed)
        var list = entries
        list.removeAll { $0 == entry }
        list.insert(entry, at: 0)
        UserDefaults.standard.set(
            list.prefix(capacity).map { "\($0.engine.rawValue)|\($0.model ?? "")" },
            forKey: defaultsKey)
    }
}

// MARK: - Agent quick picker (⌘⇧I)

/// An agent engine's brand mark, tinted like the surrounding text — Codex's bundled
/// template asset, Claude's the Anthropic sunburst already bundled for the model
/// picker. Shared by the compose chip's row and the ⌘⇧I quick picker.
struct AgentEngineMark: View {
    let engine: AgentEngine
    let size: CGFloat
    let tint: Color

    var body: some View {
        switch engine {
        case .codex:
            Image("CodexMark")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundStyle(tint)
        case .claude:
            if let mark = VendorLogos.mark(for: "Anthropic") {
                SVGPathShape(pathData: mark.path, viewBox: mark.viewBox)
                    .fill(tint, style: FillStyle(eoFill: true))
                    .frame(width: size, height: size)
            }
        case .grok:
            if let mark = VendorLogos.mark(for: "xAI") {
                SVGPathShape(pathData: mark.path, viewBox: mark.viewBox)
                    .fill(tint, style: FillStyle(eoFill: true))
                    .frame(width: size, height: size)
            }
        case .commandCode:
            if let mark = VendorLogos.mark(for: "Command Code") {
                SVGPathShape(pathData: mark.path, viewBox: mark.viewBox)
                    .fill(tint, style: FillStyle(eoFill: true))
                    .frame(width: size, height: size)
            }
        case .pi:
            if let mark = VendorLogos.mark(for: "PI") {
                SVGPathShape(pathData: mark.path, viewBox: mark.viewBox)
                    .fill(tint, style: FillStyle(eoFill: true))
                    .frame(width: size, height: size)
            }
        }
    }
}

/// The agent's two dials — model and reasoning effort — as one card, and what ⌘⇧I
/// summons anywhere in the panel. It's the compose chip's NSMenu without the menu: the
/// whole model list across engines is on screen at once, with the effort ladder for the
/// current pick right under it, so raising Opus to `xhigh` is one chord and two keys
/// instead of a menu, a submenu, and a hunt.
///
/// **Everything applies live.** The cursor *is* the selection: ↑/↓ arms the model it
/// lands on, ←/→ steps the effort. Nothing here is destructive — these are the picks
/// the *next* run will use — so a card that committed only on Return would just be a
/// second thing to remember. Return and Esc both simply close it. A mouse click on a
/// model row picks it and closes in one gesture (plain menu semantics); only the
/// effort slider and the engine switch keep the card open, since those are dials
/// you adjust, not a choice you make once.
struct AgentModelPickerView: View {
    /// Every available engine's model choices, flattened in menu order — picking a
    /// model picks its engine with it, exactly as the chip's menu does.
    let choices: [AgentModelChoice]
    let selectedEngine: AgentEngine
    let selectedModelID: String?
    let selectedEffort: AgentEffort?
    let onSelectModel: (AgentModelChoice) -> Void
    /// nil = clear back to the CLI's own default effort.
    let onSelectEffort: (AgentEffort?) -> Void
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A local keyDown monitor is the only reliable way to own the arrow keys inside a
    /// popover — a focused field editor swallows them before SwiftUI sees them.
    @State private var keyMonitor: Any?
    /// The live mirror the key monitor's captured closure reads (`choices` is a `let`
    /// captured at install time, and Codex's model list can land after the card opens).
    @State private var choicesMirror: [AgentModelChoice] = []
    @State private var effortsMirror: [AgentEffort] = []
    /// Bumped when a CLI answers a question the card asked while drawing — today
    /// that's Command Code's effort probe (`AgentEffortCatalog`), which spawns on
    /// the first look at a model and lands about a second later. Mutating it
    /// re-evaluates `efforts`, so the rungs fill in under the pointer instead of
    /// waiting for the next open. Never read: the invalidation IS the effect.
    @State private var probeGeneration = 0
    /// True only when the selection just moved via ↑/↓, so the list scrolls to keep it
    /// visible. A click never sets it — the clicked row is visible by definition, and
    /// scrolling the list under the pointer is exactly the misbehavior a hover-driven
    /// list has to avoid.
    @State private var scrollToSelection = false
    /// Hover on the engine row — its wash, matching a model row's.
    @State private var engineHovering = false
    /// Which edge of the list is mid-scroll, and so has something to dissolve.
    /// Bools rather than the live offset — see the observer in `body`.
    @State private var scrolledOffTop = false
    @State private var scrolledOffBottom = false
    /// The armed row's wash is one shared shape that *slides* between rows
    /// instead of blinking off one row and on another — the springy glide is the
    /// card's one piece of motion. It lives as a single offset-driven shape
    /// BEHIND the row stack (see `body`), not as a per-row
    /// `matchedGeometryEffect` background: one persistent shape whose offset is
    /// plain row arithmetic can't desync from the rows, and the rows themselves
    /// keep constant view structure.

    /// The spring every selection change rides — the wash glide, the label
    /// weight shift, and the effort bars all share it so the card moves as one.
    private static let selectionSpring = Animation.spring(response: 0.28, dampingFraction: 0.85)

    /// The engines on offer, in the order their choices were handed in — what the
    /// bottom bar's switch shows.
    private var engines: [AgentEngine] {
        var out: [AgentEngine] = []
        for c in choices where !out.contains(c.engine) { out.append(c.engine) }
        return out
    }

    /// The card's content width — a FIXED constant, deliberately not derived
    /// from the armed engine's rows. Deriving it meant the card resized on every
    /// engine flip (a short fleet shrank it, a long id grew it) and the rows
    /// slid out from under the pointer mid-switch — the same class of jump the
    /// fixed four-row list window already fixed vertically. So width is pinned
    /// to the narrow end: names longer than it truncate (`MenuCardRow` is
    /// `lineLimit(1)` + tail), which is the right trade for a card that hangs
    /// off the notch and carries two- or three-token model names.
    private var cardWidth: CGFloat { Self.fixedWidth }

    /// The one width every engine draws at — the old design's floor. It fits the
    /// engine caption ("Command Code") and the model names that exist; anything
    /// past it was only ever a vendor id spending width it hadn't earned.
    private static let fixedWidth: CGFloat = 174

    /// The armed engine's whole fleet. The other engine's sits behind its mark in
    /// the bottom bar — half the content of the old mixed list, and the rows can
    /// stay bare names.
    private var allEngineChoices: [AgentModelChoice] {
        choices.filter { $0.engine == selectedEngine }
    }

    /// The models this engine was most recently run with, newest first, capped at
    /// `recentRows` — the list's top half. An aggregator's catalog is twenty-odd
    /// ids of which any one user touches three or four, so the vendor's own order
    /// buries the models you actually use behind ones you never will. Entries the
    /// engine no longer offers are dropped rather than shown as dead rows.
    private var recentChoices: [AgentModelChoice] {
        let fleet = allEngineChoices
        var out: [AgentModelChoice] = []
        for entry in AgentModelMRU.entries(for: selectedEngine) {
            guard out.count < Self.recentRows,
                  let hit = fleet.first(where: { $0.id == entry.model }),
                  !out.contains(hit)
            else { continue }
            out.append(hit)
        }
        return out
    }

    /// Everything the recents don't already carry, in the engine's own order —
    /// the list's bottom half. Nothing is hidden here, and nothing is listed
    /// twice: this is the SAME fleet, just with the used few lifted out of it.
    private var otherChoices: [AgentModelChoice] {
        let recent = Set(recentChoices)
        return allEngineChoices.filter { !recent.contains($0) }
    }

    /// The list's content, in the order it's drawn: recents, then the rest.
    /// Everything downstream — ↑/↓, the gliding wash's row arithmetic, the
    /// overflow fades — reads this one flat array, so the split is a rule about
    /// ORDER, not a second list to keep in sync.
    private var engineChoices: [AgentModelChoice] { recentChoices + otherChoices }

    /// How many rows the recents section holds. Two rows past the list's own
    /// four-row window, so the section is worth scrolling into but can never
    /// become the whole list on a big catalog.
    private static let recentRows = 8

    /// Whether the two halves both exist and so want a rule between them. A
    /// first-ever open (no history) and an engine whose whole fleet is already
    /// recent both draw one plain list.
    private var showsDivider: Bool { !recentChoices.isEmpty && !otherChoices.isEmpty }

    /// What was last armed per engine while this card is up, so flipping
    /// GPT → Claude → GPT lands back on the GPT model you had, not on the
    /// list's first row.
    @State private var lastPick: [AgentEngine: AgentModelChoice] = [:]

    /// What the group caption says — the family name, not the CLI's ("GPT", not
    /// "Codex": the rows under it are GPT models, and that's the word the user knows).
    private func groupTitle(for e: AgentEngine) -> String {
        switch e {
        case .codex:  return "GPT"
        case .claude: return "Claude"
        case .grok:   return "Grok"
        // No family to name — the rows under it are Claude, GPT, Qwen, Kimi …, so
        // the caption is the account they all run through.
        case .commandCode: return "Command Code"
        // Same, one level out: pi's rows span several accounts as well as several
        // labs, so the caption is the CLI itself.
        case .pi:     return "PI"
        }
    }

    /// The row title inside a group: the caption already names the family, so
    /// "GPT-5.6-Terra" shortens to "5.6-Terra" and "Claude Fable" to "Fable".
    /// Labels without the family prefix (Codex's bare "Codex" default) pass through.
    /// Grok is exempt: its models are bare version numbers, and a row reading
    /// just "4.5" says nothing — "Grok 4.5" stays whole.
    private func shortLabel(_ c: AgentModelChoice) -> String {
        // Grok's models are bare version numbers ("4.5" alone says nothing), and
        // Command Code's span a dozen families the caption can't stand in for —
        // both keep their labels whole.
        if c.engine == .grok || c.engine == .commandCode || c.engine == .pi {
            return c.label
        }
        let family = groupTitle(for: c.engine).lowercased()
        for sep in ["-", " "] {
            let p = family + sep
            if c.label.lowercased().hasPrefix(p), c.label.count > p.count {
                return String(c.label.dropFirst(p.count))
            }
        }
        return c.label
    }

    /// The effort ladder for the model in effect — Codex's rungs differ per model, so
    /// this re-reads on every pick.
    private var efforts: [AgentEffort] {
        selectedEngine.effortChoices(forModelID: selectedModelID)
    }

    private func isSelected(_ c: AgentModelChoice) -> Bool {
        c.engine == selectedEngine && c.id == selectedModelID
    }

    /// The list window is a FIXED four rows for every engine. Sizing it to content
    /// made the card jump on every engine flip — Grok (1 row) → Claude (3) → the
    /// Command Code fleet (20) resized the popover under the pointer each time,
    /// and the rows the pointer was aimed at moved out from under it. Four rows is
    /// the window; anything shorter leaves air, anything longer scrolls.
    private static let listRows = 4
    /// How deep the list dissolves at whichever edge is actually mid-scroll. At
    /// the old 6pt (the card's own padding) the taper was a sliver — rows ended
    /// on what read as a hard cut. Two thirds of a row is enough to see a row go.
    /// Rows are a fixed 25pt at 2pt spacing, so the height is pure arithmetic —
    /// DEMANDED explicitly rather than `.frame(maxHeight:)`, because a flexible
    /// ScrollView inside an NSPopover just accepts whatever height the popover
    /// last proposed and clips.
    private static let edgeFade: CGFloat = 18

    private var listHeight: CGFloat {
        CGFloat(Self.listRows) * MenuCard.rowStride - MenuCard.rowSpacing
    }

    /// What the rows actually add up to — the other half of the bottom-edge test
    /// (the observer reports the offset, not the remaining travel).
    private var contentHeight: CGFloat {
        CGFloat(engineChoices.count) * MenuCard.rowStride - MenuCard.rowSpacing
            + (showsDivider ? Self.dividerStride : 0)
    }

    /// Whether the list actually outgrows the window and scrolls — the gate for
    /// the edge fades below.
    private var overflowing: Bool { engineChoices.count > Self.listRows }

    var body: some View {
        // Model, then effort, then engine: the card reads top-down from the
        // choice you came to make to the dials that qualify it. The model list
        // leads because it's what the card is for; the engine sits last because
        // it's the rarest change and it re-fills everything above it.
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: MenuCard.rowSpacing) {
                        // Only the armed engine's models — the other engine is one
                        // tap away in the engine switch above, so the rows stay
                        // bare names. The ones this engine actually gets run with
                        // lead; the rest of its catalog follows under a rule.
                        ForEach(recentChoices, id: \.self, content: modelRow)
                        if showsDivider { listDivider }
                        ForEach(otherChoices, id: \.self, content: modelRow)
                    }
                    // The armed wash: ONE persistent shape behind the row stack,
                    // riding a row-index offset (rows are fixed 25pt + 2pt spacing,
                    // so the position is pure arithmetic). Re-arming animates the
                    // offset — the springy glide between rows — with no
                    // matchedGeometryEffect and no per-row background insertion,
                    // so the wash can never disagree with the rows' geometry.
                    .background(alignment: .topLeading) {
                        if let i = engineChoices.firstIndex(where: isSelected) {
                            Capsule(style: .continuous)
                                .fill(.white.opacity(0.14))
                                .frame(height: MenuCard.rowHeight)
                                .frame(maxWidth: .infinity)
                                .offset(y: washOffset(row: i))
                                .animation(Self.selectionSpring, value: i)
                        }
                    }
                    // No runway. A card this small can't spend two thirds of a row
                    // on empty space at each end just to give a taper something to
                    // dissolve into — reserved at rest, it reads as the list hung
                    // too low under the card's top edge. The fades are gated on
                    // real scroll position instead (see `scrolledOffTop`), so at
                    // rest the first row sits where every other menu's first row
                    // does, and the taper only exists while rows are leaving.
                    // Zero-size probe on the scroll CONTENT reads the clip view's
                    // offset. Only the two CROSSINGS are stored, never the live
                    // offset: driving a gradient's length from the offset rebuilds
                    // the mask on every tick, which is what made the settings pane
                    // crawl (see `paneScrolledOffTop`). These flip once each.
                    .onScrollOffsetChange { offset in
                        let top = offset > 0.5
                        if top != scrolledOffTop { scrolledOffTop = top }
                        let bottom = offset < contentHeight - listHeight - 0.5
                        if bottom != scrolledOffBottom { scrolledOffBottom = bottom }
                    }
                }
                // The shared dissolve (`scrollEdgeFade`) at both overflow edges instead
                // of a hard cut. Gated on actual overflow — a short engine list sizes
                // to content, and fading it would dim real rows. The feather is the
                // runway's depth, so a row is either standing in the window or on its
                // way out through it — never half-dimmed at rest.
                .scrollEdgeFade(top: scrolledOffTop, bottom: scrolledOffBottom,
                                fade: Self.edgeFade)
                .frame(height: listHeight)
                // Open centered on the current pick — with the fleet of models the
                // armed one can sit below the fold, and a picker that opens blind to
                // its own selection makes the user hunt for their bearings.
                .onAppear {
                    if let c = engineChoices.first(where: isSelected) {
                        // Seed the per-engine memory so switching away and back
                        // restores what was armed when the card opened.
                        lastPick[c.engine] = c
                        proxy.scrollTo(c, anchor: .center)
                    }
                }
                // ↑/↓ re-arms live, so follow the selection — but only for keyboard
                // moves (see `scrollToSelection`).
                .onChange(of: selectedModelID) { followSelection(proxy) }
                .onChange(of: selectedEngine) { followSelection(proxy) }
            }

            // Thinking strength — the same native detent slider the settings
            // pane's hover-sensitivity row uses: one tick per rung, the
            // leftmost detent = the CLI's own default, a label under every
            // detent. ←/→ still step the effort.
            //
            // Dropped whole for a model with no rungs, rather than shown as a
            // one-detent dial that does nothing. Over half of Command Code's
            // fleet has no adjustable reasoning effort at all (the CLI says so
            // in as many words), and a dead slider claims a choice that isn't
            // there. Its hairlines go with it — a section that isn't drawn
            // shouldn't leave its rules behind.
            if !efforts.isEmpty {
                hairline
                effortBar
                    // Caption, slider and marks share the model rows' left edge —
                    // the card has ONE text column, not one per section.
                    .padding(.horizontal, MenuCard.rowPad)
            }

            hairline

            // The engine — the single switch that chooses whose fleet the list
            // above shows. A full-width row in the list's own language (bare
            // word, hover wash, no border), because it IS a row of this card,
            // not a control parked in a bar.
            engineRow
        }
        // Content width first, padding outside — sized bottom-up from what the
        // content actually needs (see `cardWidth`), never a top-down frame the
        // children can overflow. The popover canvas, the system's content
        // placement, and the `presentationBackground` slab are all negotiated
        // from this size; a child spilling past it is what desynced the three.
        .frame(width: cardWidth)
        .padding(MenuCard.cardPad)
        .onAppear {
            syncMirrors()
            installKeyMonitor()
        }
        .onDisappear(perform: removeKeyMonitor)
        .onChange(of: choices) { syncMirrors() }
        .onChange(of: efforts) { syncMirrors() }
        .onChange(of: selectedEngine) { syncMirrors() }
        .onReceive(NotificationCenter.default.publisher(for: .cliAvailabilityResolved)) { _ in
            probeGeneration &+= 1
        }
    }

    /// One model row. The shared menu row, minus its own wash: the armed
    /// highlight here is the single gliding shape behind the stack.
    @ViewBuilder
    private func modelRow(_ c: AgentModelChoice) -> some View {
        MenuCardRow(title: shortLabel(c), emphasized: true,
                    selected: isSelected(c), wash: false) {
            // Menu semantics, same as the Ask recents menu: one click picks the
            // model AND closes — no lingering card after the choice is made. The
            // effort dial below is what keeps the card open.
            if !isSelected(c) { arm(c) }
            onDone()
        }
        .id(c)
    }

    /// The rule between the used few and the rest of the catalog. Tighter than
    /// the card's section `hairline` (7pt of air each side would spend a quarter
    /// of the window on a gap): this is the recents card's own tail rule — 3pt
    /// each side — because it separates rows inside one list rather than two
    /// sections of the card.
    private var listDivider: some View {
        Rectangle().fill(.white.opacity(0.07))
            .frame(height: 0.5)
            .padding(.horizontal, MenuCard.rowPad)
            .padding(.vertical, 3)
    }

    /// What the divider costs every row under it: its own height plus the extra
    /// stack spacing its insertion adds. The wash rides pure row arithmetic (it
    /// never measures the rows), so the one thing that isn't a row has to be
    /// counted by hand here and in `contentHeight`.
    private static let dividerStride: CGFloat = 0.5 + 3 * 2 + MenuCard.rowSpacing

    /// Where the armed wash sits: its row's offset, plus the divider once the
    /// armed row is below it.
    private func washOffset(row i: Int) -> CGFloat {
        CGFloat(i) * MenuCard.rowStride
            + (showsDivider && i >= recentChoices.count ? Self.dividerStride : 0)
    }

    /// The rule between the card's three sections — inset to the rows' own
    /// text column so it reads as a fold in the list, not a bar across the card.
    private var hairline: some View {
        Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5)
            .padding(.horizontal, MenuCard.rowPad)
            .padding(.vertical, 7)
    }

    /// The engine switch: a plain full-width row carrying the family name, and a
    /// chevron that surfaces with the hover wash. Borderless on purpose — a chip
    /// here would be the only outlined thing on the card.
    private var engineRow: some View {
        let shape = Capsule(style: .continuous)
        return Menu {
            ForEach(engines, id: \.self) { e in
                Button { switchEngine(e) } label: {
                    if e == selectedEngine {
                        Label(groupTitle(for: e), systemImage: "checkmark")
                    } else {
                        Text(groupTitle(for: e))
                    }
                }
            }
        } label: {
            // At rest it's just the word, in the quietest ink on the card — the
            // engine is the thing you change least here, so it reads as a
            // footnote naming whose models these are. The chevron is the part
            // that says "this is a control", and it only has to say that once
            // the pointer is here, so it fades in with the wash. Spelled out
            // whole, which a full row has the width for ("Command Code", not
            // the old chip's "Cmd").
            HStack(spacing: 6) {
                Text(groupTitle(for: selectedEngine))
                    .font(.sf(MenuCard.fontSize, weight: .regular))
                    .foregroundStyle(engineHovering ? Tokens.text2 : Tokens.text4)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.sf(8, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
                    .opacity(engineHovering ? 1 : 0)
            }
            .padding(.horizontal, MenuCard.rowPad)
            .frame(height: MenuCard.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { if engineHovering { shape.fill(.white.opacity(0.06)) } }
            .contentShape(shape)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { engineHovering = $0 }
        .animation(.easeOut(duration: Tokens.rowFade), value: engineHovering)
    }

    /// The thinking-strength dial: one line naming the dial AND where it stands
    /// ("Effort High"), then the native detent slider. Not a label per rung, and
    /// not even the two ends — the thumb's position already carries the range,
    /// so words at both margins were furniture. This says the one thing the
    /// thumb can't: which rung it's sitting on.
    private var effortBar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(L("agent.effort"))
                // Only the rung word changes, so only it animates — and it
                // SUBSTITUTES rather than edits, so a cross-fade in place read as
                // one word smearing through another. `blurReplace` is the native
                // transition for exactly that: the outgoing word defocuses and
                // shrinks away while the incoming one resolves out of blur.
                //
                // It's a transition, not a `contentTransition`, so it needs a
                // real insertion/removal — hence the `.id`, which makes each rung
                // its own view. The ZStack holds them in one place while they
                // overlap (a plain swap would let the HStack reflow mid-flight),
                // and `fixedSize` keeps each word typeset at its ideal width so
                // neither re-wraps on the way through.
                ZStack(alignment: .leading) {
                    Text(effortLabel(for: currentEffortIndex))
                        .fixedSize()
                        .id(currentEffortIndex)
                        .transition(.blurReplace)
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.3),
                           value: currentEffortIndex)
            }
            .font(.sf(10.5, weight: .regular))
            .foregroundStyle(Tokens.text3)
            .lineLimit(1)
            NativeDetentSlider(value: effortPosition, ticks: positionCount)
                .frame(height: 20)
        }
    }

    /// The detent ladder's position count — rungs plus the CLI default's empty
    /// leftmost detent.
    private var positionCount: Int { efforts.count + 1 }

    /// Position 0 = default (nil); position i (1…count) = rungs[i-1].
    private var currentEffortIndex: Int {
        guard let selectedEffort, let i = efforts.firstIndex(of: selectedEffort) else { return 0 }
        return i + 1
    }

    /// The slider's position binding. Writes snap to the nearest detent and
    /// fire only on a real change, so a drag doesn't spam `onSelectEffort`
    /// with the same rung every frame.
    private var effortPosition: Binding<Double> {
        Binding(
            get: { Double(currentEffortIndex) },
            set: { position in
                let idx = min(max(Int(position.rounded()), 0), positionCount - 1)
                guard idx != currentEffortIndex else { return }
                onSelectEffort(idx == 0 ? nil : efforts[idx - 1])
            }
        )
    }

    private func effortLabel(for index: Int) -> String {
        index == 0 ? L("agent.effort.default") : L("agent.effort.\(efforts[index - 1].rawValue)")
    }

    private func syncMirrors() {
        choicesMirror = engineChoices
        effortsMirror = efforts
    }

    /// Arm a model and remember it as its engine's pick, so the bottom bar's
    /// switch can restore it later.
    private func arm(_ c: AgentModelChoice) {
        lastPick[c.engine] = c
        onSelectModel(c)
    }

    /// Flip the list to another engine, re-arming what was last picked there (or
    /// its first model). The armed row may sit below the fold of the freshly
    /// swapped list, so this scrolls to it like a keyboard step does.
    private func switchEngine(_ e: AgentEngine) {
        guard e != selectedEngine,
              let pick = lastPick[e] ?? choices.first(where: { $0.engine == e })
        else { return }
        scrollToSelection = true
        withAnimation(Self.selectionSpring) { arm(pick) }
    }

    /// Scroll the armed row into view after a keyboard step. Reads and clears the
    /// `scrollToSelection` flag so click-driven selection changes never move the list.
    private func followSelection(_ proxy: ScrollViewProxy) {
        guard scrollToSelection else { return }
        scrollToSelection = false
        guard let c = choicesMirror.first(where: isSelected) else { return }
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(c, anchor: .center) }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 126: stepModel(-1); return nil          // ↑
            case 125: stepModel(1);  return nil          // ↓
            case 123: stepEffort(-1); return nil         // ←
            case 124: stepEffort(1);  return nil         // →
            case 36, 76, 53: onDone(); return nil        // Return / keypad Enter / Esc
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    /// Arm the model ±1 along the flat list, clamping at the ends, and flag the move
    /// so the list scrolls to keep the armed row visible.
    private func stepModel(_ delta: Int) {
        let rows = choicesMirror
        guard !rows.isEmpty else { return }
        let cur = rows.firstIndex(where: isSelected) ?? -1
        let next = min(max(cur + delta, 0), rows.count - 1)
        scrollToSelection = true
        withAnimation(Self.selectionSpring) { arm(rows[next]) }
    }

    /// Step the effort ±1 along the ladder. Index -1 is the CLI default (nothing lit),
    /// so ← off the first rung lands back there — the only way out of an effort once
    /// picked, short of clicking the lit pill.
    private func stepEffort(_ delta: Int) {
        let rungs = effortsMirror
        guard !rungs.isEmpty else { return }
        let cur = selectedEffort.flatMap { rungs.firstIndex(of: $0) } ?? -1
        let next = min(max(cur + delta, -1), rungs.count - 1)
        onSelectEffort(next < 0 ? nil : rungs[next])
    }
}
