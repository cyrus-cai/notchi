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
    /// (provider, id) is unique across the flat list — the same id can appear under
    /// two aggregators, so the pair, not the id alone, identifies a row.
    var id: String { "\(provider.rawValue):\(info.id)" }
}

/// The custom cross-provider model picker — a two-pane card shown as a native popover
/// anchored on the settings model chip: a searchable **flat** list on the left (every
/// model in one list, no "pick a provider first" step), and a detail pane on the right
/// with Speed / Intelligence meters, the context window, and the capability flags
/// (Vision / Tool Use / Reasoning).
///
/// Two things drive the design beyond the reference:
///  · **Availability.** Models whose provider has no key are dimmed and can't be
///    selected; tapping one (or its inline "Add key") jumps to that provider's setup.
///  · **The two meters.** The model APIs carry context + capabilities but no
///    Speed/Intelligence score; those come from `ModelRatings` (a curated table with a
///    heuristic fallback), so every model reads at a glance as fast-light vs. slow-smart.
struct ModelPickerView: View {
    let models: [PickerModel]
    /// The provider currently in effect — its selected row carries the accent.
    let selectedProvider: Provider
    /// The id currently in effect within `selectedProvider` (empty = its default).
    let selectedID: String
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
                $0.info.name.lowercased().contains(q)
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
                providerFilterChip
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
                }
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
                .font(.system(size: 10, weight: .semibold))
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
                .font(.system(size: 12, weight: .medium))
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
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
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
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(on ? Tokens.text1 : Tokens.text3)
                Text(filterTitle)
                    .font(.sf(12, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? Tokens.text1 : Tokens.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
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
        return VStack(alignment: .leading, spacing: 2) {
            FilterRow(name: L("model.picker.allProviders"), count: models.count,
                      checked: providerFilter.isEmpty) { providerFilter = [] }
            Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5).padding(.vertical, 3)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    section(L("model.picker.configured"), configured, isFirst: true)
                    section(L("model.picker.unconfigured"), unconfigured, isFirst: configured.isEmpty)
                }
            }
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
            // The settings header's caption register, verbatim: 10pt semibold, tracked
            // out, at meta weight.
            Text(title)
                .font(.sf(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Tokens.text4)
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
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(checked ? Tokens.text1 : Tokens.text4)
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
        .animation(.easeOut(duration: 0.12), value: hovering)
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
            Text(model.info.id.isEmpty ? L("model.picker.default") : model.info.name)
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

/// The right-hand pane: the model name, the two meters, who
/// serves it, its context window, and the capability flags — including whether
/// asking through this provider gets real web search (the steering the old
/// provider-menu grouping used to do now lives here, next to the model itself).
private struct DetailPanel: View {
    let model: PickerModel

    private var info: ModelInfo { model.info }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: logo + name.
            HStack(alignment: .center, spacing: 9) {
                VendorLogo(vendor: info.vendor, fallback: info.name)
                    .frame(width: 24, height: 24)
                Text(info.id.isEmpty ? L("model.picker.default") : info.name)
                    .font(.sf(15, weight: .semibold))
                    .foregroundStyle(Tokens.text1)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Meters — the two graduated bars, grouped tight so Speed and Intelligence
            // read as a pair.
            VStack(alignment: .leading, spacing: 12) {
                Meter(label: L("model.picker.speed"), value: info.speed)
                Meter(label: L("model.picker.intelligence"), value: info.intelligence)
            }
            .padding(.top, 18)

            // Facts (Provider / Context) — a quiet label↔value block, separated from
            // the meters above by a hairline so the panel breaks into clean registers.
            Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5).padding(.vertical, 14)

            VStack(alignment: .leading, spacing: 8) {
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

/// A five-segment meter (Speed / Intelligence). Filled bars are bright, empty ones
/// nearly gone — the same graduated-white idiom the rest of the panel uses.
private struct Meter: View {
    let label: String
    let value: Int   // 0…5

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.sf(12, weight: .medium))
                .foregroundStyle(Tokens.text2)
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.white.opacity(i < value ? 0.92 : 0.12))
                        .frame(height: 3.5)
                }
            }
        }
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
                .font(.system(size: 10, weight: .medium))
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
