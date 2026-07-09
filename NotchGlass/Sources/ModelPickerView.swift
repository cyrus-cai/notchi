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

    /// The rows the list actually draws, in the order handed in (usable first).
    ///
    /// A **search reaches every model**, folded or not — the fold is about the resting
    /// state, not about hiding things from the person looking for them. With no query,
    /// the fold applies unless the user lifted it; the model currently in effect always
    /// survives the fold, or the picker would open with nothing selected on screen.
    private var visible: [PickerModel] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.isEmpty else {
            return models.filter {
                $0.info.name.lowercased().contains(q)
                || $0.info.id.lowercased().contains(q)
                || $0.providerName.lowercased().contains(q)
            }
        }
        guard !expanded else { return models }
        return models.filter { $0.featured || isSelected($0) }
    }

    /// How many models the fold is currently keeping out of the list.
    private var foldedCount: Int { models.count - visible.count }

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
    /// current selection, else the first usable model available.
    private var detailModel: PickerModel? {
        if let f = focused, let m = row(for: f) { return m }
        if let sel = models.first(where: { $0.provider == selectedProvider && $0.info.id == selectedID }) {
            return sel
        }
        return models.first(where: \.hasKey) ?? models.first
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
        .onAppear {
            searchFocused = true
            navRowsMirror = navigableRows
            if focused == nil { focused = initialFocus }
            installKeyMonitor()
        }
        .onDisappear(perform: removeKeyMonitor)
        // Refresh the nav mirror whenever the visible list changes — either the query
        // narrows it, or live models replace the bundled stubs (fingerprint changes).
        .onChange(of: query) { syncNav() }
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
            case 53: dismiss(); return nil                // Esc
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    // MARK: - List

    private var listColumn: some View {
        VStack(spacing: 8) {
            searchField
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visible) { m in
                            row(m)
                                .id(key(m))
                        }
                        if visible.isEmpty {
                            Text(L("model.picker.empty"))
                                .font(.sf(12))
                                .foregroundStyle(Tokens.text3)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 24)
                        }
                        // The fold's handle. Only while resting — a search already
                        // spans the whole catalog, so offering "show all" there
                        // would be a no-op.
                        if query.isEmpty, expanded || foldedCount > 0 {
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
        }
        .padding(10)
    }

    /// The last row of the list: lift the fold ("Show all 63 models") or drop it back.
    /// Deliberately quiet — a text row, not a button chrome — so it reads as the tail
    /// of the list rather than a control competing with the models.
    private var foldToggle: some View {
        HStack(spacing: 8) {
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20)
            Text(expanded ? L("model.picker.showLess")
                          : L("model.picker.showAll", models.count))
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
    private func row(_ m: PickerModel) -> some View {
        let k = key(m)
        let isSelected = m.provider == selectedProvider && m.info.id == selectedID
        let isFocused = focused == k
        ModelRowView(model: m, selected: isSelected, focused: isFocused)
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
}

// MARK: - Row

/// One model row: vendor logo + model name, with a quiet "Add key" affordance when
/// its provider has no key (keyless rows are dimmed and non-selectable). Selected rows
/// carry a soft accent wash; hovered / keyboard-cursored rows a fainter white one.
private struct ModelRowView: View {
    let model: PickerModel
    let selected: Bool
    let focused: Bool

    private var enabled: Bool { model.hasKey }

    var body: some View {
        HStack(spacing: 10) {
            VendorLogo(vendor: model.info.vendor, fallback: model.info.name)
                .frame(width: 20, height: 20)
                .opacity(enabled ? 1 : 0.55)
            // The model name is the whole row — no provider subtitle, no tier badge.
            // The vendor lives only in the logo; the provider↔key mapping is managed
            // elsewhere, surfaced here only when a model can't be picked (Add key).
            Text(model.info.id.isEmpty ? L("model.picker.default") : model.info.name)
                .font(.sf(13, weight: selected ? .semibold : .regular))
                .foregroundStyle(enabled ? Tokens.text1 : Tokens.text2)
                .lineLimit(1)
                .truncationMode(.middle)
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

            // Capabilities — icon + label list in the same register as the facts.
            VStack(alignment: .leading, spacing: 9) {
                if info.vision    { Capability(icon: "eye", label: L("model.picker.vision")) }
                if info.toolUse   { Capability(icon: "wrench.and.screwdriver", label: L("model.picker.tools")) }
                if info.reasoning { Capability(icon: "brain", label: L("model.picker.reasoning")) }
                if model.provider.supportsWebSearch {
                    Capability(icon: "globe", label: L("model.picker.webSearch"))
                } else {
                    // The one absence worth calling out: no provider-side web
                    // search means answers come from training data only.
                    Capability(icon: "globe.slash", label: L("model.picker.noWebSearch"), dimmed: true)
                }
            }
            .padding(.top, 14)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A quiet label/value line (Provider, Context) in the panel's own register:
    /// the label sits at meta-weight on the left, the value bright and right-aligned.
    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.sf(12))
                .foregroundStyle(Tokens.text3)
            Spacer(minLength: 8)
            Text(value)
                .font(.sf(12, weight: .semibold))
                .foregroundStyle(Tokens.text1)
                .lineLimit(1)
                .truncationMode(.tail)
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

/// One capability line: icon + label, matching the reference's Vision / Tool Use /
/// Supports Reasoning list. `dimmed` renders an *absent* capability (no web
/// search) in the quiet register so it reads as a fact, not an alarm.
private struct Capability: View {
    let icon: String
    let label: String
    var dimmed: Bool = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(dimmed ? Tokens.text4 : Tokens.text2)
                .frame(width: 16)
            Text(label)
                .font(.sf(12))
                .foregroundStyle(dimmed ? Tokens.text3 : Tokens.text1)
        }
    }
}
