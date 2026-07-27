import SwiftUI
import AppKit

/// One model in the flat cross-provider picker: the model itself plus which provider
/// serves it and whether that provider has a usable key. Keyless models still appear
/// (so the user sees what a key would unlock) but read as greyed and non-selectable,
/// with an inline "Add key" affordance that jumps to that provider's setup.
struct PickerModel: Identifiable {
    let provider: Provider
    let providerName: String
    let hasKey: Bool
    /// Whether this model survives the picker's fold — the shortlist shown before the
    /// user asks for "all N models". For OpenRouter that means the auto-router plus
    /// the most-used few of its free lineup; for other providers, the curated
    /// shortlist; for keyless providers, one representative row. Built by
    /// `InlineSettingsView.shortlistIDs`.
    let featured: Bool
    let info: ModelInfo
    /// The title the row and the detail header carry. Usually the catalog's own
    /// name, but Claude Code rows are CLI **aliases** ("opus") and a bare family
    /// word names a shelf, not a model — once the CLI probe lands they read as the
    /// concrete model the alias runs today ("Claude Opus 4.8"). Stored rather than
    /// computed so the rows genuinely rebuild when that probe publishes.
    let displayName: String
    /// (provider, id) is unique across the flat list — the same id can appear under
    /// two aggregators, so the pair, not the id alone, identifies a row.
    var id: String { "\(provider.rawValue):\(info.id)" }
}

/// The custom cross-provider model picker — a two-pane card shown as a native popover
/// anchored on the settings model chip: a searchable **flat** list on the left (every
/// model in one list, no "pick a provider first" step), and a detail pane on the right
/// with who serves it, the context window, and the capability flags (Vision / Tool
/// Use / Reasoning).
///
/// **Availability** drives the design beyond the reference: models whose provider has
/// no key are dimmed and can't be selected; tapping one (or its inline "Add key")
/// jumps to that provider's setup.
///
/// The pane shows only facts the model itself reports. It used to carry two 5-bar
/// Speed / Intelligence meters fed by a curated table — but a bar count nobody can
/// read a unit off of ("4 of 5 what?") isn't information, so they're gone.
struct ModelPickerView: View {
    let models: [PickerModel]
    /// The provider currently in effect — its selected row carries the accent.
    let selectedProvider: Provider
    /// The id currently in effect within `selectedProvider` (empty = its default).
    let selectedID: String
    /// When set, the picker is the **second step of a two-step choice**: the provider
    /// was already picked (Settings' own Provider row), so the list shows only that
    /// provider's models and the provider filter chip disappears — filtering by
    /// provider inside a single-provider list would be a control with nothing to do.
    /// Nil = the flat cross-provider list (the ⌘⇧I picker).
    var lockedProvider: Provider? = nil
    /// Commit a selection: (provider, model id). Only fires for usable models.
    let onSelect: (Provider, String) -> Void
    /// Set up a keyless model (the "Add key" affordance): the settings pane opens
    /// that provider's key entry and, once a key lands, selects this exact model —
    /// it must NOT switch the active backend before the key exists.
    let onConfigure: (PickerModel) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    /// The providers the list is narrowed to; empty = all of them. Unlike the fold, this
    /// scopes *everything* — search included — so it reads as a filter, not a hint. It
    /// lives in `@State`, so each time the popover opens it rests on "all".
    @State private var providerFilter: Set<Provider> = []
    /// Whether the filter's dropdown is showing. It's an in-card overlay rather than a
    /// `Menu`, because an NSMenu closes on every click — unusable for ticking three
    /// providers — and rather than a nested popover, which would fight the picker's own.
    @State private var filterOpen = false
    /// False = the fold is on: only shortlisted models show (see `PickerModel.featured`).
    /// The user lifts it with the "Show all N models" row at the bottom of the list.
    /// A search bypasses it entirely, so a folded model is never unreachable.
    @State private var expanded = false
    /// The row the detail pane describes and the keyboard cursor sits on — set on
    /// hover and by arrow keys, seeded to the current selection so the pane is never
    /// blank on open.
    @State private var focused: RowKey?
    /// True only when `focused` just changed via the keyboard, so the list scrolls to
    /// keep the cursor visible. Hovering also moves `focused` (the detail pane follows
    /// the mouse) but leaves this false — so the list never scrolls under the pointer.
    /// This is the fix for the old "hover makes the list scroll wildly" behavior.
    @State private var scrollToFocused = false
    @FocusState private var searchFocused: Bool
    /// A local key monitor is the load-bearing keyboard path: while the search field
    /// holds focus, its AppKit field editor can swallow ↑/↓/Return/Esc before SwiftUI's
    /// `.onKeyPress`/`.onSubmit` ever see them. The monitor gets first refusal on
    /// keyDown, so navigation is reliable regardless. Installed while the picker is up.
    @State private var keyMonitor: Any?
    /// The current navigable rows, mirrored into `@State` so the key monitor's captured
    /// closure reads a *live* value: `models` is a plain `let` captured at install time,
    /// so nav computed from it directly would go stale the moment live models load. This
    /// mirror is refreshed whenever the visible list changes.
    @State private var navRowsMirror: [RowKey] = []

    /// Identifies a row by (provider, id) rather than by its `ModelInfo` value: the
    /// same model appears as a bundled stub before its live metadata loads and as a
    /// fully-populated entry after, and those two `ModelInfo`s are *not* equal — so
    /// keying focus by the value would strand the detail pane on the stale copy when
    /// the live list arrives.
    private struct RowKey: Hashable { let provider: Provider; let id: String }

    private func key(_ m: PickerModel) -> RowKey { RowKey(provider: m.provider, id: m.info.id) }

    /// Whether `m` is the model currently in effect.
    private func isSelected(_ m: PickerModel) -> Bool {
        m.provider == selectedProvider && m.info.id == selectedID
    }

    /// The catalog the rest of the picker reasons about: every model, or only those from
    /// the providers the filter names. Search, the fold, and the "Show all N" count all
    /// read this rather than `models`, so a filtered picker behaves exactly like an
    /// unfiltered one over a smaller catalog.
    private var scoped: [PickerModel] {
        // A locked provider outranks the filter chip (which isn't drawn at all in
        // that mode) — the provider was chosen one row up, and nothing in here may
        // widen the list back out across providers.
        if let locked = lockedProvider { return models.filter { $0.provider == locked } }
        guard !providerFilter.isEmpty else { return models }
        return models.filter { providerFilter.contains($0.provider) }
    }

    /// The rows the list actually draws, in the order handed in (usable first).
    ///
    /// A **search reaches every model**, folded or not — the fold is about the resting
    /// state, not about hiding things from the person looking for them. With no query,
    /// the fold applies unless the user lifted it; the model currently in effect always
    /// survives the fold, or the picker would open with nothing selected on screen.
    private var visible: [PickerModel] {
        let base = scoped
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.isEmpty else {
            return base.filter {
                $0.displayName.lowercased().contains(q)
                || $0.info.name.lowercased().contains(q)
                || $0.info.id.lowercased().contains(q)
                || $0.providerName.lowercased().contains(q)
            }
        }
        guard !expanded else { return base }
        return base.filter { $0.featured || isSelected($0) }
    }

    /// How many models the fold is currently keeping out of the list.
    private var foldedCount: Int { scoped.count - visible.count }

    /// One entry of the provider filter menu. Providers arrive in `models`' own order —
    /// keyed ones first — so the menu leads with what the user can actually call.
    private struct ProviderOption: Identifiable {
        let provider: Provider
        let name: String
        let count: Int
        let hasKey: Bool
        var id: Provider { provider }
    }

    private var providerOptions: [ProviderOption] {
        var order: [Provider] = []
        var counts: [Provider: Int] = [:]
        var names: [Provider: String] = [:]
        var keyed: [Provider: Bool] = [:]
        for m in models {
            if counts[m.provider] == nil { order.append(m.provider) }
            counts[m.provider, default: 0] += 1
            names[m.provider] = m.providerName
            keyed[m.provider] = m.hasKey
        }
        return order.map {
            ProviderOption(provider: $0, name: names[$0] ?? $0.rawValue,
                           count: counts[$0] ?? 0, hasKey: keyed[$0] ?? false)
        }
    }

    /// The rows the keyboard cursor can land on — only usable (keyed) ones; arrow keys
    /// skip greyed models entirely.
    private var navigableRows: [RowKey] {
        visible.filter(\.hasKey).map(key)
    }

    /// Resolve a (provider, id) key to the live row in the *current* list — so the
    /// detail pane always reflects the freshest metadata, never a stale copy.
    private func row(for k: RowKey) -> PickerModel? {
        models.first { $0.provider == k.provider && $0.info.id == k.id }
    }

    /// The model the detail pane shows: the hovered/keyboard-cursored one, else the
    /// current selection, else the first usable model available. Every fallback stays
    /// inside `scoped`, so a filtered picker never describes a model the list doesn't
    /// show — only an empty scope falls back to the whole catalog.
    private var detailModel: PickerModel? {
        if let f = focused, let m = row(for: f) { return m }
        if let sel = scoped.first(where: isSelected) { return sel }
        return scoped.first(where: \.hasKey) ?? scoped.first ?? models.first
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            listColumn
                .frame(width: 330)
            Rectangle().fill(.white.opacity(0.08)).frame(width: 0.5)
            if let m = detailModel {
                DetailPanel(model: m)
                    .frame(width: 200)
            }
        }
        .frame(width: 530, height: 360)
        // The card's surface + hairline are the popover's Liquid Glass slab, applied at
        // the call site (GlassPopoverBackground, radius 14). No fill/border here — the
        // content floats on the airy glass so the wallpaper refracts through the whole
        // card, matching the panel's LiquidGlass standard rather than a dark block.
        //
        // The filter dropdown floats over the whole card (not just the list column) so
        // its click-catcher covers the detail pane too — clicking anywhere outside it
        // closes it.
        .overlay(alignment: .topLeading) { filterDropdownLayer }
        .onAppear {
            searchFocused = true
            navRowsMirror = navigableRows
            if focused == nil { focused = initialFocus }
            installKeyMonitor()
        }
        .onDisappear(perform: removeKeyMonitor)
        // Refresh the nav mirror whenever the visible list changes — the query or the
        // provider filter narrows it, or live models replace the bundled stubs.
        .onChange(of: query) { syncNav() }
        .onChange(of: providerFilter) { syncNav() }
        .onChange(of: modelsFingerprint) { syncNav() }
    }

    /// A cheap signal that flips whenever the visible rows change, so `.onChange` can
    /// refresh the nav mirror without `models` being Equatable.
    private var modelsFingerprint: String {
        navigableRows.map { "\($0.provider.rawValue):\($0.id)" }.joined(separator: "|")
    }

    /// Recompute the nav mirror and re-anchor the cursor onto a still-visible row.
    private func syncNav() {
        navRowsMirror = navigableRows
        if focused == nil || !navRowsMirror.contains(where: { $0 == focused }) {
            focused = navRowsMirror.first
        }
    }

    /// Where the keyboard cursor starts: the current selection if it's reachable,
    /// otherwise the first usable row.
    private var initialFocus: RowKey? {
        let sel = RowKey(provider: selectedProvider, id: selectedID)
        return navigableRows.contains(sel) ? sel : navigableRows.first
    }

    /// Step the keyboard cursor by ±1 through the usable rows, clamping at the ends,
    /// and flag the move so the list scrolls to keep it visible. Reads `navRowsMirror`
    /// (live `@State`), not `navigableRows` — the key monitor's captured closure calls
    /// this, and `navigableRows` derives from the stale `let`.
    private func moveFocus(_ delta: Int) {
        let rows = navRowsMirror
        guard !rows.isEmpty else { return }
        let cur = focused.flatMap { rows.firstIndex(of: $0) } ?? -1
        let next = min(max(cur + delta, 0), rows.count - 1)
        scrollToFocused = true
        focused = rows[next]
    }

    /// Commit the row under the keyboard cursor (Return). No-op if nothing is cursored.
    private func commitFocused() {
        guard let f = focused else { return }
        onSelect(f.provider, f.id)
    }

    /// Install a local keyDown monitor that owns ↑/↓/Return/Esc while the picker is up,
    /// swallowing them (return `nil`) so the focused search field's field editor never
    /// sees them; every other key (typing) is passed through untouched.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // While an IME composition is in flight (typing Chinese/Japanese in
            // the search field), every key belongs to the composition — ↑/↓ pick
            // candidates, Return commits, Esc cancels. Hijacking them here would
            // select a model / close the picker mid-composition, so pass through.
            if let editor = event.window?.firstResponder as? NSTextView,
               editor.hasMarkedText() {
                return event
            }
            switch event.keyCode {
            case 126: moveFocus(-1); return nil           // ↑
            case 125: moveFocus(1);  return nil           // ↓
            case 36, 76: commitFocused(); return nil      // Return / keypad Enter
            // Esc peels one layer at a time: the filter dropdown first, the picker only
            // once nothing is open on top of it.
            case 53:
                if filterOpen { filterOpen = false } else { dismiss() }
                return nil
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    // MARK: - List

    /// Model names sold by more than one provider in the catalog — only these rows
    /// carry a provider subtitle, so the same model under two aggregators stops
    /// being twin rows while unique models keep the clean name-only look. Computed
    /// over the full `models` (not `visible`) so a row's subtitle never flickers
    /// with search or the fold.
    private var duplicatedNames: Set<String> {
        var seen: [String: Provider] = [:]
        var dups = Set<String>()
        for m in models {
            let k = m.info.name.lowercased()
            if let p = seen[k] {
                if p != m.provider { dups.insert(k) }
            } else {
                seen[k] = m.provider
            }
        }
        return dups
    }

    private var listColumn: some View {
        // Once per render, not per row — the set is O(catalog) to build.
        let dups = duplicatedNames
        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                searchField
                // Only the cross-provider list needs the filter; a locked picker is
                // already narrowed to one provider, so the search field takes the row.
                if lockedProvider == nil {
                    providerFilterChip
                }
            }
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visible) { m in
                            row(m, showsProvider: dups.contains(m.info.name.lowercased()))
                                .id(key(m))
                        }
                        if visible.isEmpty {
                            Text(L("model.picker.empty"))
                                .font(.sf(12))
                                .foregroundStyle(Tokens.text3)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 24)
                        }
                        // The fold's handle, riding the list's tail while it's collapsed:
                        // a shortlist is short, so the row sits in plain sight. Only
                        // while resting — a search already spans the whole catalog, so
                        // offering "show all" there would be a no-op.
                        if query.isEmpty, !expanded, foldedCount > 0 {
                            foldToggle
                        }
                    }
                    .padding(.trailing, 2)
                    // Breathing room the bottom fade falls across, so the tail row
                    // (or the fold handle) rests above the taper at full strength.
                    .padding(.bottom, 40)
                }
                // The shared dissolve (`scrollEdgeFade`) where rows scroll past the
                // column's bottom edge, instead of a hard cut. Bottom only — the
                // search field caps the top and the first row rests right under it.
                // The viewport is fixed (the card is 360pt tall), so a short result
                // list just tapers empty space.
                .scrollEdgeFade(top: false, bottom: true, fade: 40)
                // Scroll only for keyboard moves (scrollToFocused), never for hover —
                // that's what stopped the list scrolling wildly under the pointer.
                .onChange(of: focused) {
                    guard scrollToFocused, let f = focused else { return }
                    scrollToFocused = false
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(f, anchor: .center) }
                }
            }
            // Expanded, the same handle leaves the list and pins to the column's floor.
            // As a tail row it would sit sixty-odd models down — the only way out of the
            // full catalog, parked behind a scroll marathon. Pinned, it's one click from
            // anywhere in the list.
            if query.isEmpty, expanded {
                VStack(spacing: 0) {
                    Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5)
                    foldToggle.padding(.top, 4)
                }
            }
        }
        .padding(10)
    }

    /// Lift the fold ("Show all 63 models") or drop it back. Deliberately quiet — a text
    /// row, not a button chrome — so it reads as part of the list rather than a control
    /// competing with the models, whether it rides the list's tail or the pinned floor.
    private var foldToggle: some View {
        HStack(spacing: 8) {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.sf(10, weight: .semibold))
                .frame(width: 20)
            Text(expanded ? L("model.picker.showLess")
                          : L("model.picker.showAll", scoped.count))
                .font(.sf(12, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Tokens.text3)
        .padding(.horizontal, 9)
        .frame(height: 32)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.14)) { expanded.toggle() }
        }
    }

    @ViewBuilder
    private func row(_ m: PickerModel, showsProvider: Bool) -> some View {
        let k = key(m)
        let isSelected = m.provider == selectedProvider && m.info.id == selectedID
        let isFocused = focused == k
        ModelRowView(model: m, selected: isSelected, focused: isFocused,
                     showsProvider: showsProvider)
            // Hover updates the detail pane (and the row wash) but must NOT scroll —
            // scrollToFocused stays false, so `.onChange(of: focused)` is a no-op here.
            .onHover { if $0 { scrollToFocused = false; focused = k } }
            .onTapGesture {
                if m.hasKey { onSelect(m.provider, m.info.id) }
                else { onConfigure(m) }
            }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.sf(12, weight: .medium))
                .foregroundStyle(Tokens.text3)
            TextField(L("model.picker.search"), text: $query)
                .textFieldStyle(.plain)
                .font(.sf(13))
                .foregroundStyle(Tokens.text1)
                .focused($searchFocused)
                // ↑/↓/Return/Esc are handled by the local key monitor (see
                // installKeyMonitor); onSubmit is a harmless fallback.
                .onSubmit(commitFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle")
                        .font(.sf(12))
                        .foregroundStyle(Tokens.text3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
    }

    /// The provider filter: a chip riding beside the search field, resting on "All
    /// providers". It scopes the list to the ticked providers — the coarse cut a text
    /// search can't make cleanly, since a provider's name rarely appears in its models'
    /// names (searching "OpenRouter" finds nothing called that).
    ///
    /// An active filter brightens the chip, so a narrowed list is never a mystery — and it
    /// brightens into the exact wash a selected model row wears (0.14 fill / 0.20 rim), not
    /// a tint of its own. Accent stays reserved for the "Add key" jump; this is a state,
    /// not an action. At rest the chip is the search field's twin (0.06 / 0.10).
    ///
    /// The chip's width is fixed: provider names run from "GLM" to "Vercel AI Gateway", and
    /// a chip that resized per selection would shove the search field around on every tick.
    private var providerFilterChip: some View {
        let on = !providerFilter.isEmpty
        return Button {
            withAnimation(.easeOut(duration: 0.12)) { filterOpen.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.sf(10, weight: .semibold))
                    .foregroundStyle(on ? Tokens.text1 : Tokens.text3)
                Text(filterTitle)
                    .font(.sf(12, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? Tokens.text1 : Tokens.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                Image(systemName: "chevron.down")
                    .font(.sf(8, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
                    .rotationEffect(.degrees(filterOpen ? 180 : 0))
            }
            .padding(.horizontal, 8)
            .frame(width: 118, height: 34)
            .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(on ? 0.14 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(on ? 0.20 : 0.10), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    /// What the chip says: the one provider by name, else a count — a chip 118pt wide
    /// can't list three of them, and "3 providers" is the fact that matters. At rest
    /// it's the short "Providers" (not "All providers", which truncates to
    /// "All provi…" at this width — a default state must never show an ellipsis);
    /// the dropdown's first row keeps the full "All providers" wording.
    private var filterTitle: String {
        switch providerFilter.count {
        case 0: return L("model.picker.providers")
        case 1: return providerFilter.first?.displayName ?? ""
        default: return L("model.picker.someProviders", providerFilter.count)
        }
    }

    private static let filterMenuWidth: CGFloat = 200

    /// The dropdown, plus the invisible sheet that closes it on an outside click. Both
    /// float over the whole card; the panel is offset to hang under the chip's right
    /// edge (the list column is 330 wide with a 10pt inset, so the chip's edge is at 320).
    @ViewBuilder
    private var filterDropdownLayer: some View {
        if filterOpen {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { filterOpen = false } }
                providerFilterMenu
                    .frame(width: Self.filterMenuWidth)
                    .offset(x: 320 - Self.filterMenuWidth, y: 10 + 34 + 6)
            }
            .transition(.opacity)
        }
    }

    /// The rows themselves: "All providers" clears the filter, every other row ticks its
    /// provider on or off and the panel stays put — that's the whole reason this isn't a
    /// `Menu`. Unticking the last provider lands back on "all", which is the same thing.
    ///
    /// Two blocks, keyed above keyless: which providers you can actually call is the
    /// first thing to know about the list, and burying a configured provider among nine
    /// keyless ones makes the useful half hard to find. Keyless providers stay tickable —
    /// filtering to one is how you browse what a key would unlock.
    ///
    /// The fold is deliberately left alone by all of this — narrowing to OpenRouter still
    /// opens on its shortlist with "Show all N" below, now counting only what's in scope.
    private var providerFilterMenu: some View {
        let configured = providerOptions.filter(\.hasKey)
        let unconfigured = providerOptions.filter { !$0.hasKey }
        // Whether the provider list actually outgrows the 218pt cap and scrolls —
        // the gate for the shared edge fade below. String-only estimate (~30pt per
        // FilterRow incl. spacing, plus two section headers): 7+ rows overflow. A
        // menu that fits sizes to content, and fading it would dim real rows.
        let overflowing = providerOptions.count >= 7
        return VStack(alignment: .leading, spacing: 2) {
            FilterRow(name: L("model.picker.allProviders"), count: models.count,
                      checked: providerFilter.isEmpty) { providerFilter = [] }
            Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5).padding(.vertical, 3)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    section(L("model.picker.configured"), configured, isFirst: true)
                    section(L("model.picker.unconfigured"), unconfigured, isFirst: configured.isEmpty)
                }
                // Breathing room the bottom fade falls across at end of scroll.
                .padding(.bottom, overflowing ? 24 : 0)
            }
            // The shared dissolve (`scrollEdgeFade`) at the overflow edge instead of
            // a hard cut. Bottom only: the pinned "All providers" row caps the top.
            .scrollEdgeFade(top: false, bottom: overflowing, fade: 24)
            .frame(maxHeight: 218)
        }
        .padding(6)
        // The tooltip's wafer, verbatim (DesignSystem): near-black glass over a thin
        // blur, a Tokens.hairline rim, the same lifted shadow. It has to occlude the
        // rows it hangs over, so it can't be the card's airy `.clear` glass.
        .background {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            ZStack {
                shape.fill(Color.black.opacity(0.62))
                    .background(.ultraThinMaterial, in: shape)
                shape.strokeBorder(Tokens.hairline, lineWidth: 0.5)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }

    /// One block of the dropdown: a quiet caption, then its providers. An empty block
    /// draws nothing at all — a lone "Configured" header over no rows would read as a
    /// bug, and a fresh install (no keys anywhere) has exactly that block empty.
    @ViewBuilder
    private func section(_ title: String, _ opts: [ProviderOption], isFirst: Bool) -> some View {
        if !opts.isEmpty {
            Text(title)
                .captionLabel()
                .padding(.horizontal, 8)
                .padding(.top, isFirst ? 2 : 8)
                .padding(.bottom, 2)
            ForEach(opts) { opt in
                FilterRow(name: opt.name, count: opt.count,
                          checked: providerFilter.contains(opt.provider),
                          dimmed: !opt.hasKey) {
                    toggleProvider(opt.provider)
                }
            }
        }
    }

    private func toggleProvider(_ p: Provider) {
        if providerFilter.contains(p) { providerFilter.remove(p) } else { providerFilter.insert(p) }
    }
}

// MARK: - Filter row

/// One tickable provider in the filter dropdown: a checkbox, the provider's name, and
/// how many models it brings. `dimmed` marks a provider with no key — still tickable
/// (its models show greyed, with "Add key"), just quieter than one you can call.
/// Its own `View` so each row owns its hover state.
///
/// Ticked and hovered wear the model rows' own washes (0.14 + a 0.20 rim; 0.06), and the
/// checkbox is plain ink — the picker spends its one accent on "Add key", and a blue tick
/// here would out-shout it.
private struct FilterRow: View {
    let name: String
    let count: Int
    let checked: Bool
    var dimmed: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: checked ? "checkmark.square" : "square")
                .font(.sf(12, weight: .medium))
                .foregroundStyle(checked ? Tokens.text1 : Tokens.text4)
                // Native SF Symbols swap — the box fills/empties instead of hard-cutting.
                // Scoped to the symbol: `providerFilter` also drives the model list, which
                // must not animate along with the tick.
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeOut(duration: 0.18), value: checked)
                .frame(width: 14)
            Text(name)
                .font(.sf(12, weight: checked ? .semibold : .regular))
                .foregroundStyle(dimmed ? Tokens.text2 : Tokens.text1)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text("\(count)")
                .font(.sf(11))
                .foregroundStyle(Tokens.text4)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(checked ? .white.opacity(0.14) : hovering ? .white.opacity(0.06) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(checked ? .white.opacity(0.20) : .clear, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
    }
}

// MARK: - Row

/// One model row: vendor logo + model name, with a quiet "Add key" affordance when
/// its provider has no key (keyless rows are dimmed and non-selectable). Selected rows
/// carry a soft accent wash; hovered / keyboard-cursored rows a fainter white one.
private struct ModelRowView: View {
    let model: PickerModel
    let selected: Bool
    let focused: Bool
    /// True when the same model name appears under another provider too — only
    /// then does the row name its provider, so twins are tellable apart at a
    /// glance instead of only in the detail pane.
    let showsProvider: Bool

    private var enabled: Bool { model.hasKey }

    var body: some View {
        HStack(spacing: 10) {
            VendorLogo(vendor: model.info.vendor, fallback: model.info.name)
                .frame(width: 20, height: 20)
                .opacity(enabled ? 1 : 0.55)
            // The model name is (almost) the whole row — no tier badge, vendor in
            // the logo only. The provider surfaces just twice: as "Add key" when the
            // model can't be picked, and as a quiet subtitle when the same name is
            // sold by two providers and the rows would otherwise be twins.
            Text(model.displayName)
                .font(.sf(13, weight: selected ? .semibold : .regular))
                .foregroundStyle(enabled ? Tokens.text1 : Tokens.text2)
                .lineLimit(1)
                .truncationMode(.middle)
            if showsProvider {
                // Meta register (text4), a step below the labels — it disambiguates,
                // it doesn't compete with the model name.
                Text(model.providerName)
                    .font(.sf(11))
                    .foregroundStyle(Tokens.text4)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 6)
            if !enabled {
                Text(L("model.picker.addKey"))
                    .font(.sf(11, weight: .semibold))
                    .foregroundStyle(Tokens.accent)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? .white.opacity(0.14)
                      : focused ? .white.opacity(0.06) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? .white.opacity(0.20) : .clear, lineWidth: 0.5)
        )
        .opacity(enabled ? 1 : 0.5)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

// MARK: - Detail panel

/// The right-hand pane: the model name, who
/// serves it, its context window, and the capability flags — including whether
/// asking through this provider gets real web search (the steering the old
/// provider-menu grouping used to do now lives here, next to the model itself).
private struct DetailPanel: View {
    let model: PickerModel
    /// Observed for `claudeResolved` — the Claude Code alias rows fill in their
    /// concrete model id reactively when the CLI probe lands.
    @ObservedObject private var catalog = ModelCatalogStore.shared

    private var info: ModelInfo { model.info }

    /// The concrete model behind a Claude Code alias row ("opus" →
    /// "claude-opus-4-8"), once probed. Nil for every other provider, before the
    /// probe lands, or when it adds nothing over the row's own id.
    private var resolvedModelID: String? {
        guard model.provider == .claudeCode,
              let id = catalog.claudeResolved[info.id], id != info.id
        else { return nil }
        return id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: logo + name.
            HStack(alignment: .center, spacing: 9) {
                VendorLogo(vendor: info.vendor, fallback: info.name)
                    .frame(width: 24, height: 24)
                Text(model.displayName)
                    .font(.sf(15, weight: .semibold))
                    .foregroundStyle(Tokens.text1)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Facts (Provider / Context) — a quiet label↔value block, separated from
            // the name above by a hairline so the panel breaks into clean registers.
            Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5)
                .padding(.top, 16).padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 8) {
                // Claude Code rows are CLI aliases; show what the alias actually
                // runs, straight from the CLI's own resolution (probed + cached).
                if let resolved = resolvedModelID {
                    factRow(L("model.picker.resolved"), resolved)
                }
                factRow(L("model.provider"), model.providerName)
                if let ctx = info.contextLabel {
                    factRow(L("model.picker.context"), ctx)
                }
            }

            // Capabilities — tags, not a list. A model often carries only one of these
            // (a bundled stub knows nothing but its provider's web search), and a lone
            // icon+label line reads as a stray sentence hanging off the facts above it;
            // a pill reads as a deliberate tag at any count. Chips also share the
            // panel's left edge, which an icon column does not.
            FlowLayout(hSpacing: 6, vSpacing: 6) {
                if info.vision    { CapabilityChip(icon: "eye", label: L("model.picker.vision")) }
                if info.toolUse   { CapabilityChip(icon: "wrench.and.screwdriver", label: L("model.picker.tools")) }
                if info.reasoning { CapabilityChip(icon: "brain", label: L("model.picker.reasoning")) }
                if model.provider.supportsWebSearch {
                    CapabilityChip(icon: "globe", label: L("model.picker.webSearch"))
                } else {
                    // The one absence worth calling out: no provider-side web
                    // search means answers come from training data only. Vision /
                    // tools / reasoning stay positives-only — the catalog reports
                    // them as `false` until a model's live metadata lands, so an
                    // absent chip there would assert something we don't know.
                    CapabilityChip(icon: "network.slash", label: L("model.picker.noWebSearch"), dimmed: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A quiet label/value line (Provider, Context) in the panel's own register:
    /// the label sits at meta-weight on the left, the value a shade brighter and
    /// right-aligned — both well below the name and meters above.
    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.sf(12))
                .foregroundStyle(Tokens.text4)
            Spacer(minLength: 8)
            // Wrap, don't truncate — "Codex (ChatGPT)" doesn't fit the 200pt pane
            // beside its label, and a fact that reads "Codex (ChatG…" isn't a fact.
            Text(value)
                .font(.sf(12))
                .foregroundStyle(Tokens.text3)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
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

    private init() {}

    /// How many of OpenRouter's usage-ranked free models ride in the picker's unfolded
    /// view. The auto-router sits above them, outside the cap.
    private static let openRouterShortlistLimit = 4

    /// Whether `p` can actually serve a request right now. The CLI backends are keyless
    /// (installed + signed in is the test); everyone else needs a stored key.
    static func ready(_ p: Provider) -> Bool {
        switch p {
        case .codex:      return CodexCLIService.isAvailable
        case .claudeCode: return ClaudeCLIService.isAvailable
        case .grokCode:   return GrokCLIService.isAvailable
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
        // Claude Code's alias→concrete-id mapping, the CLI twin of the fetches
        // below — see `resolveClaudeAliases`.
        resolveClaudeAliases()
        await withTaskGroup(of: (Provider, ModelCatalog.Result?).self) { group in
            for p in Provider.allCases where liveByProvider[p] == nil {
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
        let live = Set(infos.map(\.id))
        let curated = p.availableModels.filter(live.contains)
        // A curated id the vendor no longer serves means the intersection is empty —
        // fall back to the curated list itself rather than folding the whole provider
        // away to nothing.
        return Set(curated.isEmpty ? p.availableModels : curated)
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
        for p in Provider.allCases {
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
            // Shortlisted models lead their provider's block, so expanding the fold
            // appends rows below what was already on screen instead of reshuffling it.
            let ordered = infos.enumerated().sorted { a, b in
                let af = short.contains(a.element.id), bf = short.contains(b.element.id)
                return af == bf ? a.offset < b.offset : af
            }.map(\.element)
            for info in ordered {
                // A model only earns the resting (unfolded) shortlist if its vendor has a
                // real logo — a monogram letter-tile in the featured list reads as
                // ugly/broken, so the long-tail vendors without a bundled mark fold away
                // (still reachable via "Show all" and search, and a selected one always
                // shows regardless).
                let hasLogo = VendorLogos.mark(for: info.vendor) != nil
                rows.append(PickerModel(
                    provider: p, providerName: p.displayName, hasKey: hasKey,
                    featured: short.contains(info.id) && hasLogo, info: info,
                    displayName: title(for: info, provider: p)))
            }
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
    /// See `ModelPickerView.installKeyMonitor` — a local keyDown monitor is the only
    /// reliable way to own the arrow keys inside a popover.
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
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows, id: \.self) { r in
                AskRecentModelRow(
                    label: ModelRatings.prettyName(for: r.id, provider: r.provider),
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
                .padding(.vertical, 3)
            AskRecentModelRow(label: L("model.picker.more"), selected: false) {
                onDone()
                onMoreModels()
            }
        }
        .padding(8)
        .frame(width: 190)
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
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

/// One row of the Ask recents menu — `AgentModelRow`'s look (soft wash when armed,
/// fainter on hover, no rims or checkmarks) with the vendor's real mark leading,
/// since these rows mix providers.
private struct AskRecentModelRow: View {
    let label: String
    let selected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.sf(11.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Tokens.text1 : Tokens.text2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 8)
        .frame(height: 25)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(selected ? .white.opacity(0.12) : hovering ? .white.opacity(0.05) : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
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

    /// See `ModelPickerView.installKeyMonitor` — the same reason applies here: a local
    /// keyDown monitor is the only reliable way to own the arrow keys inside a popover.
    @State private var keyMonitor: Any?
    /// The live mirror the key monitor's captured closure reads (`choices` is a `let`
    /// captured at install time, and Codex's model list can land after the card opens).
    @State private var choicesMirror: [AgentModelChoice] = []
    @State private var effortsMirror: [AgentEffort] = []
    /// True only when the selection just moved via ↑/↓, so the list scrolls to keep it
    /// visible. A click never sets it — the clicked row is visible by definition, and
    /// scrolling the list under the pointer is exactly the misbehavior the main picker
    /// had to fix (see `ModelPickerView.scrollToFocused`).
    @State private var scrollToSelection = false
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

    /// The card's content width. The floor (174) is the two-engine design; past
    /// that, the width is DERIVED from the bottom bar's real minimum — its engine
    /// marks (18pt each, 10pt spacing), the 8pt spacer, the 92pt effort slider and
    /// its own 16pt padding — because the bar is the card's one rigid row. A third
    /// engine (Grok) pushed that minimum to 190 while the card stayed fixed at
    /// 174: the bar overflowed, SwiftUI centered the spill, and the whole content
    /// column slid 8pt out of the popover's margins (the 边距乱 bug). Deriving the
    /// width keeps the card exactly as designed at two engines and simply grows it
    /// when the bar genuinely needs more.
    private var cardWidth: CGFloat {
        let marks = CGFloat(engines.count) * 18 + CGFloat(max(0, engines.count - 1)) * 10
        return max(174, marks + 8 + 92 + 16)
    }

    /// The list's content: only the armed engine's models. The other engine's fleet
    /// sits behind its mark in the bottom bar — half the content of the old mixed
    /// list, and the rows can stay bare names.
    private var engineChoices: [AgentModelChoice] {
        choices.filter { $0.engine == selectedEngine }
    }

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
        }
    }

    /// The row title inside a group: the caption already names the family, so
    /// "GPT-5.6-Terra" shortens to "5.6-Terra" and "Claude Fable" to "Fable".
    /// Labels without the family prefix (Codex's bare "Codex" default) pass through.
    /// Grok is exempt: its models are bare version numbers, and a row reading
    /// just "4.5" says nothing — "Grok 4.5" stays whole.
    private func shortLabel(_ c: AgentModelChoice) -> String {
        if c.engine == .grok { return c.label }
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

    /// Whether the model list actually outgrows the 200pt cap and scrolls — the
    /// gate for the shared edge fade below. Row math, no geometry read: 25pt rows
    /// at 2pt spacing → 8+ rows overflow.
    private var overflowing: Bool { engineChoices.count >= 8 }

    /// The list's height, DEMANDED explicitly rather than `.frame(maxHeight:)`:
    /// rows are fixed 25pt at 2pt spacing, so it's pure arithmetic. A flexible
    /// ScrollView inside an NSPopover accepts whatever height the popover last
    /// proposed — flipping Grok (1 row) → Claude (3 rows) left the window at the
    /// short height and the taller list clipped to a single visible row (the
    /// armed one, which `scrollTo` had centered). An explicit height forces the
    /// popover to re-size with the list in both directions.
    private var listHeight: CGFloat {
        max(0, min(CGFloat(engineChoices.count) * 27 - 2, 200))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        // Only the armed engine's models — the other engine is one
                        // tap away in the bottom bar, so the rows stay bare names.
                        ForEach(engineChoices, id: \.self) { c in
                            AgentModelRow(label: shortLabel(c), selected: isSelected(c)) {
                                // Menu semantics, same as the Ask recents menu: one
                                // click picks the model AND closes — no lingering
                                // card after the choice is made. Effort / engine
                                // tweaks below are what keep the card open.
                                if !isSelected(c) { arm(c) }
                                onDone()
                            }
                            .id(c)
                        }
                    }
                    // The armed wash: ONE persistent shape behind the row stack,
                    // riding a row-index offset (rows are fixed 25pt + 2pt spacing,
                    // so the position is pure arithmetic). Re-arming animates the
                    // offset — the springy glide between rows — with no
                    // matchedGeometryEffect and no per-row background insertion,
                    // so the wash can never disagree with the rows' geometry.
                    .background(alignment: .topLeading) {
                        if let i = engineChoices.firstIndex(where: isSelected) {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(.white.opacity(0.12))
                                .frame(height: 25)
                                .frame(maxWidth: .infinity)
                                .offset(y: CGFloat(i) * 27)
                                .animation(Self.selectionSpring, value: i)
                        }
                    }
                    // Breathing room the bottom fade falls across at end of scroll.
                    .padding(.bottom, overflowing ? 24 : 0)
                }
                // The shared dissolve (`scrollEdgeFade`) at the overflow edge instead
                // of a hard cut. Gated on actual overflow — a short engine list sizes
                // to content, and fading it would dim real rows. Bottom only: the
                // first row rests at the very top when scrolled up.
                .scrollEdgeFade(top: false, bottom: overflowing, fade: 24)
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

            Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5)
                .padding(.vertical, 6)

            // One bottom bar, two things: the engine switch (each engine's real
            // brand mark; tap to flip the whole list) on the left, and the plainest
            // possible effort slider — detent dots and a thumb, leftmost = the CLI
            // default, the top rung's dot lit in the agent tint — on the right.
            // No captions, no readouts. ←/→ still steps the effort.
            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    ForEach(engines, id: \.self) { e in
                        EngineSwitchMark(engine: e, selected: e == selectedEngine) {
                            switchEngine(e)
                        }
                    }
                }
                Spacer(minLength: 8)
                EffortSlider(rungs: efforts, selected: selectedEffort, onSelect: onSelectEffort)
                    .frame(width: 92)
            }
            .padding(.horizontal, 8)
            .frame(height: 25)
        }
        // Content width first, padding outside — sized bottom-up from what the
        // content actually needs (see `cardWidth`), never a top-down frame the
        // children can overflow. The popover canvas, the system's content
        // placement, and the `presentationBackground` slab are all negotiated
        // from this size; a child spilling past it is what desynced the three.
        .frame(width: cardWidth)
        .padding(8)
        .onAppear {
            syncMirrors()
            installKeyMonitor()
        }
        .onDisappear(perform: removeKeyMonitor)
        .onChange(of: choices) { syncMirrors() }
        .onChange(of: efforts) { syncMirrors() }
        .onChange(of: selectedEngine) { syncMirrors() }
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

/// One row of the ⌘⇧I card. Its own `View` so it owns its hover state. Deliberately
/// spare: the armed row is just a soft wash + semibold — no rim, no checkmark — and a
/// hovered row a fainter wash, so the card reads as text on glass, not a stack of
/// controls. Bare names only — the engine identity lives in the bottom bar's switch.
/// The armed wash is a single offset-driven shape behind the whole row stack (see
/// `AgentModelPickerView`), so selection *glides* between rows instead of blinking.
private struct AgentModelRow: View {
    let label: String
    let selected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.sf(11.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Tokens.text1 : Tokens.text2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 8)
        .frame(height: 25)
        // The hover wash is a CONSTANT shape whose fill changes — the row's
        // view structure never varies with state. The armed wash isn't this
        // row's business at all: it's the single gliding shape behind the
        // whole stack (see the list's `.background` in `AgentModelPickerView`).
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(hovering && !selected ? .white.opacity(0.05) : .clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
    }
}

/// One engine of the bottom bar's switch: the engine's real brand mark, bright when
/// it owns the list, dimmed otherwise, warming on hover. Just the mark — no pill,
/// no rim; the tap target is padded invisibly to row height.
private struct EngineSwitchMark: View {
    let engine: AgentEngine
    let selected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        AgentEngineMark(engine: engine, size: 13,
                        tint: selected ? Tokens.text1 : Tokens.text3)
            .opacity(selected ? 1 : hovering ? 0.85 : 0.55)
            .frame(width: 18, height: 25)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: onTap)
            .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
            .animation(.easeOut(duration: 0.12), value: selected)
    }
}

/// The reasoning-effort dial at its plainest: one detent dot per position and a round
/// thumb riding them — nothing else. The leftmost detent is the CLI default, then one
/// dot per rung; the far (rightmost) dot is lit in the agent tint to mark the
/// "hardest thinking" end. Click or drag snaps the thumb to the nearest detent; ←/→
/// drive the same state from the keyboard (the thumb is derived from `selected`,
/// never stored).
private struct EffortSlider: View {
    let rungs: [AgentEffort]
    let selected: AgentEffort?
    /// nil = the CLI's own default (position 0).
    let onSelect: (AgentEffort?) -> Void

    // Position 0 = default (nil); position i (1…count) = rungs[i-1].
    private var positionCount: Int { rungs.count + 1 }
    private var currentIndex: Int {
        guard let selected, let i = rungs.firstIndex(of: selected) else { return 0 }
        return i + 1
    }

    private let thumbD: CGFloat = 11
    private let dot: CGFloat = 2.5

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - thumbD, 1)
            let step = positionCount > 1 ? usable / CGFloat(positionCount - 1) : 0
            let thumbX = thumbD / 2 + step * CGFloat(currentIndex)

            ZStack(alignment: .leading) {
                ForEach(0..<positionCount, id: \.self) { i in
                    let isLast = i == positionCount - 1
                    Circle()
                        .fill(isLast ? Tokens.agentTint : .white.opacity(0.35))
                        .frame(width: dot, height: dot)
                        .offset(x: thumbD / 2 + step * CGFloat(i) - dot / 2)
                }

                Circle()
                    .fill(.white)
                    .frame(width: thumbD, height: thumbD)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: thumbX - thumbD / 2)
                    .animation(.spring(response: 0.24, dampingFraction: 0.82), value: currentIndex)
            }
            // Fill the GeometryReader: the dots and thumb are small offset shapes,
            // so without this the ZStack (and the contentShape hit area with it)
            // collapses to the thumb's own ~11pt — the slider stops being clickable
            // anywhere but its left edge.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in snap(toX: v.location.x, usable: usable, step: step) }
            )
        }
    }

    /// Map a touch x to the nearest detent and fire only on a real change, so a
    /// drag doesn't spam `onSelect` with the same rung every frame.
    private func snap(toX x: CGFloat, usable: CGFloat, step: CGFloat) {
        guard step > 0 else { return }
        let clamped = min(max(x - thumbD / 2, 0), usable)
        let idx = min(max(Int((clamped / step).rounded()), 0), positionCount - 1)
        guard idx != currentIndex else { return }
        onSelect(idx == 0 ? nil : rungs[idx - 1])
    }
}

/// One capability tag: icon + label in a soft pill (Vision / Tool Use / Reasoning /
/// Web search). `dimmed` renders an *absent* capability (no web search) in the quiet
/// register so it reads as a fact, not an alarm.
private struct CapabilityChip: View {
    let icon: String
    let label: String
    var dimmed: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.sf(10, weight: .medium))
            Text(label)
                .font(.sf(11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(dimmed ? Tokens.ink.opacity(0.32) : Tokens.text2)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(dimmed ? 0.03 : 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.white.opacity(dimmed ? 0.05 : 0.10), lineWidth: 0.5)
        )
    }
}
