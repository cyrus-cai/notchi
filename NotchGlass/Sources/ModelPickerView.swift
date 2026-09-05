import SwiftUI
import AppKit
import QuartzCore

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
/// providers you can call, each one opening its own models. Families keep their
/// catalog order while siblings rank by cost efficiency, so comparisons stay local
/// instead of turning the whole menu into one cross-vendor leaderboard.
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

    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: ModelMenuPresenter
        /// True from the moment a present is scheduled until the menu closes — a
        /// re-render while the menu is up must not stack a second one.
        var showing = false
        /// The card that rides beside the menu. Built lazily so a copy that never
        /// opens the picker never makes a window.
        private let detail = ModelDetailPanel.shared

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
            detail.scheduleHide()
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

        /// Every menu and submenu comes from here so each one reaches the delegate.
        /// `willHighlightItem` is per-menu, and a model row lives in a submenu two
        /// levels down — a delegate on the root alone would hear nothing.
        private func newMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }

        private func buildMenu() -> NSMenu {
            let menu = newMenu()
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
            let sub = newMenu()
            fill(sub, with: models)
            item.submenu = sub
            return item
        }

        /// A provider's models: every model with a useful cost-efficiency score,
        /// plus exceptionally intelligent 5/5 models even when their score is low.
        /// Each family contributes at most five rows; unscored, low-scoring, and
        /// overflow siblings live under "More models". If nothing meets that
        /// bar, the remaining rows sit on this menu instead of behind a door.
        private func fill(_ menu: NSMenu, with models: [PickerModel]) {
            guard !models.isEmpty else {
                let empty = NSMenuItem(title: L("model.picker.empty"), action: nil,
                                       keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
                return
            }
            let ranked = rankedWithinFamilies(models)
            var primary: [PickerModel] = []
            var moreModels: [PickerModel] = []
            var visibleByFamily: [String: Int] = [:]
            for model in ranked {
                let family = familyKey(model)
                if showsOutsideMoreModels(model), visibleByFamily[family, default: 0] < 5 {
                    primary.append(model)
                    visibleByFamily[family, default: 0] += 1
                } else {
                    moreModels.append(model)
                }
            }
            for m in primary { menu.addItem(modelItem(m)) }
            guard !moreModels.isEmpty else { return }
            // Nothing earned the main list — don't add a "More models" door
            // that opens onto the whole catalog. Put those rows here.
            if primary.isEmpty {
                for m in moreModels { menu.addItem(modelItem(m)) }
                return
            }
            menu.addItem(.separator())
            let more = NSMenuItem(title: L("model.picker.moreModels"), action: nil,
                                  keyEquivalent: "")
            let sub = newMenu()
            for m in moreModels { sub.addItem(modelItem(m)) }
            more.submenu = sub
            menu.addItem(more)
        }

        /// The main list keeps every scored model at 60 or above. Below that floor,
        /// only a model whose displayed Intelligence meter is the full 5/5 remains;
        /// the meter uses the measured bar first and the existing curated fallback.
        private func showsOutsideMoreModels(_ model: PickerModel) -> Bool {
            guard let stats = Provider.modelStats(model.info.id),
                  let value = stats.value else { return false }
            let intelligence = stats.intelligenceBar ?? model.info.intelligence
            return value >= 60 || intelligence == 5
        }

        /// Preserve the catalog's family order, but rank siblings by the same
        /// 1–100 cost-efficiency score shown on the detail card. A missing score is
        /// normal for an unbenchmarked model, so those rows stay stable at the end
        /// of their family rather than being assigned a made-up value.
        private func rankedWithinFamilies(_ models: [PickerModel]) -> [PickerModel] {
            var familyOrder: [String] = []
            var families: [String: [(offset: Int, model: PickerModel)]] = [:]
            for (offset, model) in models.enumerated() {
                let family = familyKey(model)
                if families[family] == nil { familyOrder.append(family) }
                families[family, default: []].append((offset, model))
            }
            return familyOrder.flatMap { family in
                (families[family] ?? []).sorted { a, b in
                    let av = Provider.modelStats(a.model.info.id)?.value
                    let bv = Provider.modelStats(b.model.info.id)?.value
                    switch (av, bv) {
                    case let (x?, y?) where x != y: return x > y
                    case (_?, nil):                 return true
                    case (nil, _?):                 return false
                    default:                        return a.offset < b.offset
                    }
                }.map(\.model)
            }
        }

        /// The leading product word is the family users scan: Claude, Gemini,
        /// GPT, Kimi, MiniMax, Qwen, and so on. Stop before a version digit or the
        /// first separator so Gemini and Gemma remain distinct while every Gemini
        /// generation still compares together.
        private func familyKey(_ model: PickerModel) -> String {
            let title = model.displayName.components(separatedBy: " · ").first
                ?? model.displayName
            let lower = title.lowercased()
            let boundary = lower.firstIndex { $0 == "-" || $0 == " " || $0.isNumber }
            return boundary.map { String(lower[..<$0]) } ?? lower
        }

        private func modelItem(_ m: PickerModel) -> NSMenuItem {
            let item = NSMenuItem(title: m.displayName, action: #selector(pick(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = Box(m)
            item.state = (m.provider == parent.selectedProvider
                          && m.info.id == parent.selectedID) ? .on : .off
            if let value = Provider.modelStats(m.info.id)?.value {
                item.badge = NSMenuItemBadge(string: "\(value)")
            }
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

        // MARK: Detail card

        /// Follow the highlight. Rows that aren't a model — a provider, "More
        /// models", a section header, or nothing at all — take the card away
        /// rather than leaving the last model's figures stranded next to
        /// something they don't describe.
        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            guard let m = (item?.representedObject as? Box)?.model else {
                detail.scheduleHide()
                return
            }
            detail.show(m)
        }

        /// Covers the submenu case too: stepping back out of a provider closes
        /// that menu, and the card has to go with it.
        func menuDidClose(_ menu: NSMenu) { detail.scheduleHide() }

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
// MARK: - Model detail card

/// What one model is, beside the menu that lists it.
///
/// The menu row carries the name and nothing else, on purpose: the figures that
/// decide a pick — how smart, how fast, how good a deal — are three numbers, and
/// three numbers crammed onto every row is a column of digits nobody can read
/// without a legend. So the menu stays a menu and the detail hangs off the
/// highlighted row, one model at a time, where each figure gets a label and a
/// meter instead of a bare integer.
///
/// The meters are the scale `ModelRatings` already defines (5 = the top of the
/// field, 1 = the bottom). Where Artificial Analysis has measured a model, the
/// bar comes from that measurement, ranked against the manifest's own lineup —
/// see `barScale` in `docs/api/model-stats.js` for why the lineup and not AA's
/// whole catalog. Where it hasn't, the bar falls back to the curated table, which
/// is the same scale by construction.
struct ModelDetailCard: View {
    let model: PickerModel
    /// The reading to draw *right now*, which mid-hover is somewhere between the
    /// last model's figures and this one's. See `Figures`.
    let figures: Figures
    /// Whether the pointer is over the scoring link. Pushed in rather than sensed:
    /// see `scoringLinkFrame(in:)`.
    let scoringHovered: Bool
    let onOpenScoringDetails: () -> Void

    /// Menu-adjacent, so it takes the corner radius of the things macOS pops up
    /// next to a menu rather than the tighter one a panel body uses.
    private static let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    private var stats: RemoteModelManifest.ModelStats? { Provider.modelStats(model.info.id) }

    /// The row title, split at the qualifier the catalogs append when a bare model
    /// name would collide across engines ("Gpt-5.6-terra · commandcode").
    ///
    /// Left whole it wraps wherever the column runs out, which strands the "·" on
    /// a line of its own and then truncates the engine — the separator is the
    /// narrowest thing on the line, so it is exactly where a greedy wrap lands.
    /// Split, the break is the one the name already implies.
    private var title: (name: String, qualifier: String?) {
        let parts = model.displayName.components(separatedBy: " · ")
        guard parts.count > 1, let last = parts.last else { return (model.displayName, nil) }
        return (parts.dropLast().joined(separator: " · "), last)
    }

    /// AA's measurement first, the curated guess second. `ModelInfo.speed` and
    /// `.intelligence` are always populated (heuristic at worst), so these two
    /// meters are never absent; `value` has no curated equivalent and simply
    /// doesn't draw when unmeasured.
    ///
    /// The card draws whatever it is handed rather than reading these off the
    /// model, because the interesting positions are the ones *between* two models:
    /// hovering down the menu moves the meters and the gauge from where they were
    /// to where they belong instead of cutting between stills. `targetFigures` is
    /// where that travel ends; `ModelDetailPanel` drives it.
    static func targetFigures(for model: PickerModel) -> Figures {
        let stats = Provider.modelStats(model.info.id)
        return Figures(value: Double(stats?.value ?? 0),
                       speed: Double(stats?.speedBar ?? model.info.speed),
                       intelligence: Double(stats?.intelligenceBar ?? model.info.intelligence))
    }

    /// 1–100, and only ever measured — there is no curated stand-in for "how much
    /// intelligence per dollar", so an unmeasured model simply has no ring. Its
    /// *presence* doesn't animate: the ring is part of the card's layout, and a
    /// gauge shrinking away while the title reflows next to it reads as a glitch.
    /// An unmeasured model rests at 0, so a measured neighbour still counts up
    /// from nothing.
    static func hasValue(_ model: PickerModel) -> Bool {
        Provider.modelStats(model.info.id)?.value != nil
    }

    /// The three figures mid-travel: the gauge out of 100, the two meters out of 5.
    /// Continuous rather than the integers they come from — the whole point is the
    /// positions in between.
    struct Figures: Equatable {
        var value: Double = 0
        var speed: Double = 0
        var intelligence: Double = 0

        /// Straight-line blend. The easing lives in the driver, so this stays the
        /// one obvious thing.
        func lerp(to other: Figures, _ t: Double) -> Figures {
            Figures(value: value + (other.value - value) * t,
                    speed: speed + (other.speed - speed) * t,
                    intelligence: intelligence + (other.intelligence - intelligence) * t)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.text1)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let qualifier = title.qualifier {
                        Text(qualifier)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Tokens.text3)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Tokens.ink.opacity(0.14))
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                                    )
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if Self.hasValue(model) { ValueRing(score: figures.value) }
            }

            Meter(title: L("model.detail.speed"), level: figures.speed)
            Meter(title: L("model.detail.intelligence"), level: figures.intelligence)

            if let context = model.info.contextLabel {
                HStack(spacing: 8) {
                    Text(L("model.detail.context"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.text3)
                    Spacer(minLength: 8)
                    if let words = model.info.contextWordsLabel {
                        Text(L("model.detail.words", words))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Tokens.text4)
                    }
                    Text(context)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Tokens.text1)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                // NOT `model.info.vision`. That field comes from
                // `ModelRatings.looksVision`, a 2023-shaped allowlist that reads
                // vision off the id ("claude", "gemini", "-vl") and therefore
                // tells every GLM 5 model it can't see — the exact bug
                // `Provider.modelSupportsVision` was written to replace, using the
                // manifest's generated blocklist plus what a rejected image
                // actually taught us.
                Capability(symbol: "eye", title: L("model.detail.vision"),
                           supported: Provider.modelSupportsVision(model.info.id))
                // A vendor that publishes no `supported_parameters` leaves
                // `info.toolUse` false, which is an absence of data being rendered
                // as a "no". The provider gate is the real answer.
                Capability(symbol: "wrench.and.screwdriver", title: L("model.detail.toolUse"),
                           supported: model.info.toolUse || model.provider.supportsTools)
                // Only ever stated in the positive. Reasoning has no authoritative
                // source here — `looksReasoning` matches on "thinking"/"-r1"-ish
                // ids and misses every hybrid model that reasons without saying so
                // in its name — so a "Reasoning Unsupported" row would be a guess
                // printed as a fact. No row means we don't know, which is true.
                if model.info.reasoning {
                    Capability(symbol: "brain", title: L("model.detail.reasoning"),
                               supported: true)
                }
                if stats != nil { scoringDetailsLink }
            }
        }
        .padding(12)
        .frame(width: ModelDetailPanel.width, alignment: .leading)
        .background {
            // Keep the companion genuinely transparent. A semantic `.menu`
            // `NSVisualEffectView` inside this detached panel resolves to a dense,
            // almost opaque fill; clear Liquid Glass with an integrated smoked
            // tint lets the app beneath visibly refract through the card instead.
            // 0.58 brings the glass luminance over a white page into the native
            // menu's range without adding a separate opaque veil.
            ZStack {
                Self.shape.fill(.clear)
                    .nativeGlass(in: Self.shape, tintOpacity: 0.58)
                Self.shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.07)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75)
            }
            .compositingGroup()
        }
        .environment(\.colorScheme, .dark)
    }

    /// The full methodology belongs on a durable, linkable page rather than in a
    /// translucent menu card. Only measured cards offer the link; a card running
    /// entirely on the curated fallback has no AA figures to explain.
    ///
    /// It sits below the capability rows as a footnote, not as a peer of them: at
    /// rest it is meta-weight text with the arrow barely there, and only under the
    /// pointer does it brighten to say it is a control.
    private var scoringDetailsLink: some View {
        Button(action: onOpenScoringDetails) {
            HStack(spacing: 7) {
                Text(L("model.detail.scoringDetails"))
                    .font(.system(size: 11.5, weight: .medium))
                Spacer(minLength: 4)
                // Held in the layout at rest rather than removed, so arriving on
                // the row reveals the arrow instead of shuffling the text.
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .medium))
                    .opacity(scoringHovered ? 1 : 0)
            }
            .foregroundStyle(scoringHovered ? Tokens.text1 : Tokens.text4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
    }

    /// Where the link lands on screen, given the panel it is drawn in.
    ///
    /// The card cannot sense its own hover: `onHover` is fed by tracking areas,
    /// and this card lives beside a tracking `NSMenu` whose nested event loop
    /// delivers no mouse-moved events to other windows — and even if it flipped a
    /// `@State`, SwiftUI's update pass never gets a turn to redraw it (the same
    /// reason `figures` are pushed in frame by frame). So `ModelDetailPanel`'s
    /// pointer poll does the hit test against this rect and pushes the answer back
    /// in as `scoringHovered`. Screen coordinates, so measured up from the card's
    /// bottom edge, which is where the link sits.
    static func scoringLinkFrame(in panelFrame: NSRect) -> NSRect {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let height = ceil(font.ascender - font.descender)
        return NSRect(x: panelFrame.minX + 12, y: panelFrame.minY + 12,
                      width: panelFrame.width - 24, height: height)
    }

    /// Cost efficiency, in the corner rather than as a third meter.
    ///
    /// It doesn't belong on the same scale as the other two: speed and
    /// intelligence are properties of the model, and this is a verdict about the
    /// two of them against the price — a different kind of statement, and the one
    /// people skim for. A gauge reads as a score out of a fixed maximum, which is
    /// exactly what it is (1–100 against the manifest's lineup).
    ///
    /// The label rides the outside of the arc rather than sitting under it: a line
    /// of text below the gauge was a second element competing with the model name
    /// for the top of the card, and "Cost efficiency" set flat is wider than the
    /// gauge it belongs to. Curved, it is part of the same object.
    private struct ValueRing: View {
        /// Continuous while it travels; the number in the middle is this rounded,
        /// so it counts through every value on the way rather than jumping.
        let score: Double

        private static let size: CGFloat = 40
        private static let stroke: CGFloat = 4.5
        /// Three quarters of the way round, leaving the bottom open. A closed ring
        /// reads as a pie chart — a whole divided up — and this is a scale a value
        /// travels along, which is what the gap says. The label then sits in the
        /// gap, where the arc isn't.
        private static let sweep: CGFloat = 0.75
        /// `Arc` starts at 3 o'clock and runs clockwise, so it is rotated to begin
        /// at 7:30 for its ends to land either side of the gap.
        private static let start: Double = 135
        private static let labelFont = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
        /// Clear of the stroke's outer edge.
        private static let labelRadius: CGFloat = size / 2 + stroke / 2 + 5.5

        var body: some View {
            ZStack {
                ZStack {
                    Arc(sweep: Self.sweep)
                        .stroke(Tokens.accent.opacity(0.18),
                                style: StrokeStyle(lineWidth: Self.stroke, lineCap: .round))
                    Arc(sweep: Self.sweep * CGFloat(min(100, max(1, score)) / 100))
                        .stroke(Tokens.accent,
                                style: StrokeStyle(lineWidth: Self.stroke, lineCap: .round))
                }
                .rotationEffect(.degrees(Self.start))
                .frame(width: Self.size, height: Self.size)

                Text("\(Int(score.rounded()))")
                    .font(.brand(14))
                    // Counting through 8 → 9 → 10 must not shove the digits
                    // sideways on every frame.
                    .monospacedDigit()
                    .foregroundStyle(Tokens.text1)
                    // The gap is at the bottom, so the arc's optical centre sits a
                    // hair above its geometric one.
                    .offset(y: -1)

                CurvedText(text: L("model.detail.value").uppercased(),
                           font: Self.labelFont,
                           radius: Self.labelRadius)
                    .foregroundStyle(Tokens.ink.opacity(0.50))
            }
            // Square so the arcs and the label share a centre — then the dead
            // strip underneath is taken back, because the label is on top and
            // nothing below the gauge's own radius is drawn. Left in, it sets the
            // height of the whole title row and opens a band above "Speed". The
            // larger overlap also lets Speed's label use the empty space left of
            // the gauge while its meter itself still clears the arc below.
            .frame(width: Self.labelRadius * 2 + 8, height: Self.labelRadius * 2 + 8)
            .padding(.bottom, -18)
        }
    }

    /// Text set along the top of a circle, reading left to right.
    ///
    /// Each glyph is measured and placed at its own angle rather than stepped by a
    /// constant: at this size a uniform step turns "COST EFFICIENCY" into visibly
    /// uneven spacing, because an `I` is a third the width of a `C`.
    ///
    /// It rides the top and not the bottom because the bottom is where the gauge's
    /// gap is: a line of text sitting in that gap closes the ring back up, which is
    /// the one thing the gap was opened for.
    ///
    /// Position and rotation are computed outright rather than composed from
    /// nested `rotationEffect`s. The composed version is shorter and it is how
    /// this was written twice, both times mirrored: whether a positive angle
    /// carries a glyph left or right depends on a sign convention that is easy to
    /// reason about backwards and impossible to check by reading. Trig against a
    /// stated frame — origin at the centre, y downward, φ measured from the top and
    /// positive to the right — has one reading.
    private struct CurvedText: View {
        let text: String
        let font: NSFont
        let radius: CGFloat
        /// Extra advance per glyph. Set uppercase at 7.5pt, the default fit is too
        /// tight to read; it is folded into the measured widths rather than applied
        /// as SwiftUI `.tracking`, which would space the glyphs without the arc
        /// maths knowing about it.
        var tracking: CGFloat = 1.1

        var body: some View {
            let chars = Array(text)
            let widths = chars.map { c in
                NSAttributedString(string: String(c), attributes: [.font: font])
                    .size().width + tracking
            }
            let total = widths.reduce(0, +)
            ZStack {
                ForEach(chars.indices, id: \.self) { i in
                    // Signed arc distance from the run's midpoint to this glyph's
                    // centre — negative to the left, positive to the right.
                    let offset = widths[0..<i].reduce(0, +) + widths[i] / 2 - total / 2
                    let phi = Double(offset / radius)
                    Text(String(chars[i]))
                        .font(Font(font))
                        // Over the top, the tangent tilts down to the right — a
                        // clockwise turn, which is `rotationEffect`'s positive.
                        .rotationEffect(.radians(phi))
                        .offset(x: radius * sin(phi), y: -radius * cos(phi))
                }
            }
        }
    }

    /// A circle's first `sweep` of a turn, starting at 3 o'clock. Its own shape
    /// rather than `Circle().trim(…)` because a trimmed circle still strokes a
    /// full-circle path under the hood and `lineCap: .round` on a zero-length trim
    /// leaves a dot floating at the start — a score of 0 has to draw nothing.
    private struct Arc: Shape {
        let sweep: CGFloat

        func path(in rect: CGRect) -> Path {
            var p = Path()
            guard sweep > 0.001 else { return p }
            p.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                     radius: min(rect.width, rect.height) / 2,
                     startAngle: .degrees(0),
                     endAngle: .degrees(360 * Double(min(1, sweep))),
                     clockwise: false)
            return p
        }
    }

    /// One labelled 1–5 meter, in the card's own Liquid Glass language: a lozenge
    /// of lit glass sliding along a groove cut into the panel, with ticks at the
    /// segment joins so the level is countable and not just a length.
    ///
    /// The glass here is *painted*, not sampled. A real `.glassEffect` at 7pt tall
    /// samples the same backdrop the card it sits on already samples, so it comes
    /// out as a flat grey slot — the same reason `ManageMenuRowStyle` gave up on a
    /// material for its hover wash. What actually reads as glass at this size is
    /// the lighting: a top edge in shadow and a bottom edge catching light for the
    /// groove, and for the run a vertical falloff plus one specular sliver and a
    /// little spill onto the track around it.
    private struct Meter: View {
        let title: String
        /// 0–5, continuous while it travels between two models' whole levels.
        let level: Double

        private static let height: CGFloat = 7

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.text3)
                GeometryReader { geo in
                    let w = geo.size.width
                    let filled = w * CGFloat(min(5, max(0, level)) / 5)
                    ZStack(alignment: .leading) {
                        groove
                        // Below its own height the capsule is a squashed disc, not
                        // a lozenge, and the specular sliver inside it collapses to
                        // a dot — an empty meter shows the groove and nothing else.
                        if filled >= Self.height * 0.5 {
                            lozenge.frame(width: filled)
                        }
                        ForEach(1..<5, id: \.self) { i in
                            let x = w * CGFloat(i) / 5
                            Circle()
                                // A tick inside the filled run has to knock out of
                                // it, not sit on top in the same white. Both sides
                                // are pitched to be findable rather than read: the
                                // bar's length is the figure, and ticks loud enough
                                // to count first turn it into a row of dots.
                                .fill(x <= filled ? Color.black.opacity(0.20)
                                                  : Tokens.ink.opacity(0.18))
                                .frame(width: 2, height: 2)
                                .offset(x: x - 1)
                        }
                    }
                }
                .frame(height: Self.height)
            }
        }

        /// The track, carved rather than drawn: dark inside, its top edge holding
        /// the shadow of the lip above it and its bottom edge catching the light
        /// that made it — which is the whole of what tells an eye "recessed".
        private var groove: some View {
            Capsule()
                .fill(Color.black.opacity(0.40))
                .overlay(
                    Capsule().strokeBorder(
                        LinearGradient(colors: [.black.opacity(0.8), .black.opacity(0.35),
                                                .white.opacity(0.24)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                )
        }

        /// The filled run: white, but lit rather than flat — brighter along the top
        /// where the light lands, falling off toward the bottom, one soft specular
        /// band just inside the top edge, and a faint spill onto the groove so the
        /// run sits *in* the track instead of on it.
        private var lozenge: some View {
            Capsule()
                .fill(LinearGradient(colors: [.white.opacity(0.36),
                                              .white.opacity(0.24),
                                              .white.opacity(0.13)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    Capsule()
                        .fill(LinearGradient(colors: [.white.opacity(0.58), .white.opacity(0)],
                                             startPoint: .top, endPoint: .bottom))
                        // Inset off every edge so it reads as a reflection floating
                        // in the glass, not as a second stripe drawn on top of it.
                        .padding(.horizontal, 1.6)
                        .padding(.top, 0.7)
                        .padding(.bottom, Self.height * 0.5)
                        .blur(radius: 0.7)
                        .blendMode(.plusLighter)
                )
                .overlay(
                    Capsule().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.06)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.5)
                )
                .shadow(color: .white.opacity(0.08), radius: 2.5)
                .shadow(color: .black.opacity(0.24), radius: 1.5, y: 0.5)
        }
    }

    /// A capability, present or pointedly absent. An unsupported one still gets a
    /// row — "this model cannot do it" is the answer someone is looking for, and
    /// an omitted row reads as "unknown".
    private struct Capability: View {
        let symbol: String
        let title: String
        let supported: Bool

        var body: some View {
            HStack(spacing: 7) {
                // The same glyph either way — the row is about a capability, and
                // the capability doesn't change when the answer is no. Swapping in
                // a slash made the icon column stop meaning anything, since you
                // could no longer tell which row you were on without reading it.
                // Dimming and the word carry the answer.
                Image(systemName: symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 11, weight: supported ? .medium : .regular))
                    .frame(width: 14)
                Text(supported ? title : L("model.detail.unsupported", title))
                    .font(.system(size: 11.5, weight: supported ? .medium : .regular))
            }
            // Full contrast against a quarter of it. The first pass ran these at
            // 0.74 and 0.40, which is a legible difference in isolation and not one
            // you can read at a glance down a stack of three rows — the whole job
            // of this block is to be answerable without comparing rows to
            // each other.
            .foregroundStyle(supported ? Tokens.text1 : Tokens.ink.opacity(0.26))
        }
    }
}

/// The window the card lives in.
///
/// A borderless non-activating panel rather than anything attached to the menu,
/// because `NSMenu` has no accessory view and no public frame — it is not a view
/// hierarchy you can hang something off. So the card is its own window, parked
/// against whichever menu window is currently furthest right (the open submenu),
/// and torn down when tracking ends.
///
/// The card behaves like menu-adjacent reference material and disappears as soon
/// as the pointer leaves the model menu that produced it.
final class ModelDetailPanel {
    /// There can be several SwiftUI presenter coordinators over the app's lifetime,
    /// but only one native menu can be tracked at a time. Sharing the panel prevents
    /// an old coordinator from stranding its window and a later panel from treating
    /// that orphan as the menu it should anchor beside.
    static let shared = ModelDetailPanel()

    /// Wide enough for a two-word model name beside the gauge, and no wider — the
    /// card hangs off a menu and is read at a glance, not settled into.
    static let width: CGFloat = 208
    /// Clear of the menu's shadow without reading as a separate thing.
    private static let gap: CGFloat = 6

    private var panel: NSPanel?
    private var host: NSHostingView<ModelDetailCard>?
    private var model: PickerModel?
    private var anchorFrame: NSRect?
    private var hideWork: DispatchWorkItem?
    private var hoverTimer: Timer?

    /// What the card is drawing, and the travel it is on. See `tick()`.
    private var figures = ModelDetailCard.Figures()
    private var travelFrom = ModelDetailCard.Figures()
    private var travelTo = ModelDetailCard.Figures()
    private var travelStart: CFTimeInterval = 0
    /// The pointer poll's verdict on the scoring link, pushed into the card. See
    /// `ModelDetailCard.scoringLinkFrame(in:)`.
    private var scoringHovered = false
    private var ticker: Timer?
    /// Long enough to read as movement, short enough that a fast scan down the
    /// menu never waits on it — a new row retargets mid-flight anyway.
    private static let travel: CFTimeInterval = 0.34

    /// `beside` is supplied by custom SwiftUI menus, whose window is not an
    /// `NSMenu` window and therefore cannot be discovered by `menuFrame`. Native
    /// model menus leave it nil and keep using the window scan below.
    func show(_ model: PickerModel, beside explicitAnchor: NSRect? = nil) {
        hideWork?.cancel()
        hoverTimer?.invalidate()
        hoverTimer = nil
        // A card coming back from hidden starts from nothing — the gauge sweeps up
        // and the counters count. Row to row it carries on from whatever is
        // currently on screen instead.
        let appearing = panel?.isVisible != true
        if appearing || self.model?.id != model.id {
            retarget(to: ModelDetailCard.targetFigures(for: model), fromZero: appearing)
        }
        self.model = model
        if let explicitAnchor {
            anchorFrame = explicitAnchor
        } else if let menu = menuFrame(excluding: panel) {
            anchorFrame = menu
        }
        render()
        scheduleHoverCheck()
    }

    /// Aim the figures somewhere new. Mid-flight the reading currently *drawn* is
    /// the new starting point, so running down the menu keeps moving rather than
    /// snapping back to the last model's resting numbers first.
    private func retarget(to target: ModelDetailCard.Figures, fromZero: Bool) {
        travelFrom = fromZero ? ModelDetailCard.Figures() : figures
        travelTo = target
        figures = travelFrom
        travelStart = CACurrentMediaTime()
        guard travelFrom != travelTo else { stopTicker(); return }
        startTicker()
    }

    /// The card sits beside a tracking `NSMenu`, whose nested event loop never gives
    /// SwiftUI's animation pass a turn — the same reason `render()` lays out by
    /// hand. So the travel is stepped from a timer scheduled in the common run loop
    /// modes (`NSEventTrackingRunLoopMode` is one), and every frame is pushed into
    /// the hosting view explicitly.
    private func startTicker() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard model != nil else { stopTicker(); return }
        let t = min(1, max(0, (CACurrentMediaTime() - travelStart) / Self.travel))
        // Ease out cubic: leaves at speed, settles without overshoot. A spring
        // would carry a meter past its own end cap and the gauge past 100, which
        // at this size reads as a glitch rather than as bounce.
        figures = travelFrom.lerp(to: travelTo, 1 - pow(1 - t, 3))
        if t >= 1 {
            figures = travelTo
            stopTicker()
        }
        render(reposition: false)
    }

    private func render(reposition: Bool = true) {
        guard let model else { return }
        let card = ModelDetailCard(model: model, figures: figures,
                                   scoringHovered: scoringHovered) { [weak self] in
            guard let url = URL(string: "https://notch.website/scoring") else { return }
            self?.hide()
            NSWorkspace.shared.open(url)
        }
        let host = self.host ?? {
            let h = NSHostingView(rootView: card)
            self.host = h
            return h
        }()
        host.rootView = card
        let panel = self.panel ?? makePanel(hosting: host)
        // Menu tracking runs its own event loop, which SwiftUI's normal update
        // pass does not get a turn in — lay out by hand or the card shows the
        // previous model's numbers at the previous model's height.
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        // An animation frame only redraws inside a card that is already placed;
        // re-deriving the frame and re-ordering the window sixty times a second
        // would fight the menu for stacking order for no visible gain.
        if reposition || panel.frame.size != size {
            guard let frame = position(size: size, besides: anchorFrame) else { return }
            panel.setFrame(frame, display: true)
        }
        if reposition || !panel.isVisible { panel.orderFrontRegardless() }
        panel.displayIfNeeded()
        // `displayIfNeeded` only marks the layer; the commit that puts it on screen
        // rides the run loop, and the menu's nested loop doesn't get to ours. Push
        // the transaction through by hand or a repaint that changes no geometry —
        // the hover wash, a counter that keeps its width — sits invisible until the
        // menu closes.
        CATransaction.flush()
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        hoverTimer?.invalidate()
        hoverTimer = nil
        stopTicker()
        figures = ModelDetailCard.Figures()
        scoringHovered = false
        panel?.orderOut(nil)
        model = nil
        anchorFrame = nil
    }

    /// Menu delegate callbacks cover row-to-row movement. The pointer can also leave
    /// the entire native menu while its last item remains highlighted, so keep a
    /// lightweight location watch running for the lifetime of the visible card.
    /// The card is now interactive, so the valid hover region is the menu OR the
    /// card; leaving both still closes it immediately.
    private func scheduleHoverCheck() {
        hoverTimer?.invalidate()
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] timer in
            guard let self, self.model != nil else {
                timer.invalidate()
                return
            }
            guard self.containsPointer else {
                self.hide()
                return
            }
            self.refreshScoringHover()
        }
        // `NSMenu` owns a nested event-tracking loop while it is open. A main-queue
        // delayed block can wait until that loop ends, which made the card appear to
        // gain hover only after the menu closed. Common mode runs during tracking.
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func refreshScoringHover() {
        guard let panel, panel.isVisible else { return }
        let location = NSEvent.mouseLocation
        // During native menu tracking the window server can keep reporting the menu
        // as the window under the pointer even though this higher-level panel is
        // visibly in front. The panel owns its whole frame, so use its geometry as
        // the source of truth and keep hover live before the menu closes.
        let hovered = ModelDetailCard.scoringLinkFrame(in: panel.frame).contains(location)
        guard hovered != scoringHovered else { return }
        scoringHovered = hovered
        render(reposition: false)
    }

    /// A short delay lets a new model highlight cancel an outgoing row's hide.
    func scheduleHide() {
        scheduleHide(after: 0.12)
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Crossing the small gap from the native menu into the card closes
            // the menu first. Keep the card only when the pointer actually made
            // that crossing; otherwise the old highlighted card must disappear.
            if self.panel?.frame.contains(NSEvent.mouseLocation) == true {
                self.scheduleHoverCheck()
            } else {
                self.hide()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private var containsPointer: Bool {
        let location = NSEvent.mouseLocation
        return anchorFrame?.contains(location) == true
            || panel?.frame.contains(location) == true
    }

    private func makePanel(hosting host: NSHostingView<ModelDetailCard>) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // One notch above the menus themselves, so a card that does overlap a
        // shadow lands on top of it rather than under.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        p.ignoresMouseEvents = false
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel = p
        return p
    }

    /// The open menu's frame, found by scanning for the window the menu is drawn
    /// in — `NSMenu` publishes no frame of its own.
    ///
    /// Furthest-right wins because that is the deepest open submenu, which is the
    /// one holding the highlighted row. Our own panel is excluded by number: it
    /// sits at a menu-ish level too and would otherwise leapfrog itself further
    /// right on every highlight.
    private func menuFrame(excluding mine: NSPanel?) -> NSRect? {
        let skip = mine?.windowNumber
        return NSApp.windows
            .filter { w in
                w.isVisible && w.windowNumber != skip
                    && w.level.rawValue >= NSWindow.Level.popUpMenu.rawValue
                    && w.frame.width > 60 && w.frame.height > 40
            }
            .max { $0.frame.maxX < $1.frame.maxX }?
            .frame
    }

    /// Right of the menu, top-aligned with it; flipped to the left when the right
    /// edge of the screen is closer than the card is wide, and pushed back up when
    /// a long menu would otherwise hang the card off the bottom.
    private func position(size: NSSize, besides menu: NSRect?) -> NSRect? {
        guard let menu else { return nil }
        let screen = (NSScreen.screens.first { $0.frame.intersects(menu) } ?? NSScreen.main)?
            .visibleFrame ?? .zero
        var x = menu.maxX + Self.gap
        if x + size.width > screen.maxX { x = menu.minX - Self.gap - size.width }
        x = max(screen.minX, min(x, screen.maxX - size.width))
        var y = menu.maxY - size.height
        y = max(screen.minY, min(y, screen.maxY - size.height))
        return NSRect(x: x, y: y, width: size.width, height: size.height)
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
    func resolveClaudeAliases(force: Bool = false) {
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
                ClaudeCLIService.refreshResolvedModels(aliases: probeAliases, force: force)
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
    ///
    /// `force` is the manual refresh (Settings' refresh button next to the model chip):
    /// every cache in the chain is bypassed at once — the curated manifest's 6h TTL,
    /// this store's session cache, `ModelCatalog`'s hourly per-(provider, key) cache,
    /// the CLI backends' once-per-launch catalogs and Claude Code's alias probe — so
    /// one tap answers "what does every backend serve *right now*".
    func loadAll(force: Bool = false) async {
        if force {
            // Also the escape hatch for a model wrongly learned as text-only: that
            // set has no TTL of its own, so this button is the only thing that can
            // clear it. See `VisionProbe.forget`.
            VisionProbe.forget()
            await RemoteModelManifest.refreshNow()
        } else {
            await RemoteModelManifest.refreshIfDue()
        }
        // Codex is keyless, so the keyed loop below skips it. Fetch its real model list
        // from the app-server off-main and publish it so the picker fills in reactively —
        // even if the launch warm-up hasn't finished yet. Never publish the bare "codex"
        // sentinel (that's the no-models-found fallback).
        if force || liveByProvider[.codex] == nil {
            let ids = await Task.detached(priority: .userInitiated) { () -> [String] in
                CodexCLIService.refreshModels(force: force)
                return CodexCLIService.availableModelIDs
            }.value
            if ids != ["codex"] {
                liveByProvider[.codex] = ids.map { ModelInfo(id: $0, vendor: "OpenAI") }
            }
        }
        // Grok is keyless too — its model ids come from the CLI's own cache file
        // (see `GrokCLIService`), read off-main and published so the picker fills in.
        // Never publish the bare "grok" sentinel (the no-models-found fallback).
        if force || liveByProvider[.grokCode] == nil {
            let ids = await Task.detached(priority: .userInitiated) { () -> [String] in
                GrokCLIService.refreshModels(force: force)
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
        if force || liveByProvider[.piCode] == nil {
            let ids = await Task.detached(priority: .userInitiated) { () -> [String] in
                PiCLIService.refreshModels(force: force)
                return PiCLIService.availableModelIDs
            }.value
            if ids != [PiCLIService.defaultSentinel] {
                liveByProvider[.piCode] = ids.map {
                    ModelInfo(id: $0, vendor: PiCLIService.vendor(forID: $0),
                              name: PiCLIService.displayName(forID: $0))
                }
            }
        }
        // Command Code's catalog rides its installed CLI build, so nothing in the
        // normal path re-reads it within a launch. A manual refresh re-probes it and
        // republishes the store, since its rows come from `Provider.availableModels`
        // (the static cache) rather than from `liveByProvider`.
        if force {
            await Task.detached(priority: .userInitiated) {
                CommandCodeCLIService.refreshModels(force: true)
            }.value
            cliGeneration &+= 1
        }
        // Claude Code's alias→concrete-id mapping, the CLI twin of the fetches
        // below — see `resolveClaudeAliases`.
        resolveClaudeAliases(force: force)
        await withTaskGroup(of: (Provider, ModelCatalog.Result?).self) { group in
            for p in Provider.offered where force || liveByProvider[p] == nil {
                // The custom endpoint joins the fetch as soon as it has a URL —
                // its key is optional, so "no key" must not mean "no catalog"
                // (a local Ollama / LM Studio serves `/v1/models` unauthenticated,
                // and that list is the only way to pick one of its models).
                if p == .custom {
                    guard CustomProvider.chatEndpoint != nil else { continue }
                    let key = APIKeyStore.keyOrEmpty(for: p)
                    group.addTask { (p, await ModelCatalog.fetch(for: p, apiKey: key,
                                                                 force: force)) }
                    continue
                }
                guard let key = APIKeyStore.current(for: p) else { continue }
                group.addTask { (p, await ModelCatalog.fetch(for: p, apiKey: key,
                                                             force: force)) }
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
/// recently asked through, newest first, capped at ten. Fed by every chat submit
/// (including one-shot regenerate overrides) and by explicit picks, persisted in
/// UserDefaults so the chip menu remembers across launches. This is what the Ask
/// model chip's quick menu lists — the full cross-provider catalog stays in
/// Settings.
enum AskModelMRU {
    struct Entry: Hashable {
        let provider: Provider
        let model: String
    }

    static let capacity = 10
    private static let defaultsKey = "ask_model_mru"

    /// Newest first. Entries whose provider no longer decodes (a removed enum case
    /// after an update) are dropped rather than crashing the menu, and so are
    /// entries for a provider the app no longer offers (`Provider.offered`) — a
    /// recents row is a shortcut back into a backend, so it has to be gated the
    /// same way the menus are.
    static var entries: [Entry] {
        let raw = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return raw.compactMap { line in
            guard let bar = line.firstIndex(of: "|"),
                  let provider = Provider(rawValue: String(line[..<bar])),
                  Provider.offered.contains(provider)
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
    /// Whether the list is mid-scroll at either edge — the gate for the fades.
    @State private var scrolledOffTop = false
    @State private var scrolledOffBottom = false
    /// The quick menu is a custom child panel rather than an `NSMenu`, so the
    /// shared model-detail panel cannot discover its frame from AppKit's menu
    /// windows. This probe retains the SwiftUI card's exact screen rect and lets
    /// each hovered row hang the existing detail card off its right edge.
    @StateObject private var detailAnchor = ModelDetailAnchor()

    init(rows: [Row], selectedProvider: Provider, selectedModelID: String,
         onSelect: @escaping (Row) -> Void, onMoreModels: @escaping () -> Void,
         onDone: @escaping () -> Void) {
        self.rows = rows
        self.onSelect = onSelect
        self.onMoreModels = onMoreModels
        self.onDone = onDone
        _current = State(initialValue: Row(provider: selectedProvider, id: selectedModelID))
    }

    /// The list window is a FIXED five rows. The recents run to ten, but a card
    /// that grew a row per remembered model would stand taller than the compose it
    /// hangs off — so five rows is the window and the rest scrolls, and the card's
    /// height stops depending on how many models the user has been through.
    /// Rows are a fixed height at a fixed spacing, so the height is arithmetic —
    /// demanded explicitly rather than `.frame(maxHeight:)`, which inside a
    /// floating card just takes whatever height was last proposed and clips.
    private static let listRows = 5
    /// How deep the list dissolves at whichever edge is mid-scroll — two thirds of
    /// a row, enough to see a row go instead of reading as a hard cut.
    private static let edgeFade: CGFloat = 18

    /// Sized to content while the recents are short, capped at the window once
    /// they outgrow it.
    private var listHeight: CGFloat {
        CGFloat(max(1, min(rows.count, Self.listRows))) * MenuCard.rowStride - MenuCard.rowSpacing
    }

    /// What the rows actually add up to — the other half of the bottom-edge test
    /// (the observer reports the offset, not the remaining travel).
    private var contentHeight: CGFloat {
        CGFloat(max(1, rows.count)) * MenuCard.rowStride - MenuCard.rowSpacing
    }

    /// Whether the list outgrows the window and scrolls — the gate for the fades.
    private var overflowing: Bool { rows.count > Self.listRows }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: MenuCard.rowSpacing) {
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
                                .id(r)
                                .onHover { inside in
                                    if inside, let frame = detailAnchor.frame {
                                        ModelDetailPanel.shared.show(detailModel(for: r),
                                                                     beside: frame)
                                    } else if !inside {
                                        ModelDetailPanel.shared.scheduleHide()
                                    }
                                }
                        }
                    }
                    // Zero-size probe on the scroll CONTENT reads the clip view's
                    // offset. Only the two CROSSINGS are stored, never the live
                    // offset: driving a gradient's length from the offset rebuilds
                    // the mask on every tick.
                    .onScrollOffsetChange { offset in
                        let top = offset > 0.5
                        if top != scrolledOffTop { scrolledOffTop = top }
                        let bottom = offset < contentHeight - listHeight - 0.5
                        if bottom != scrolledOffBottom { scrolledOffBottom = bottom }
                    }
                }
                // The shared dissolve at both overflow edges instead of a hard cut,
                // gated on actual overflow so a short recents list is never dimmed.
                .scrollEdgeFade(top: overflowing && scrolledOffTop,
                                bottom: overflowing && scrolledOffBottom,
                                fade: Self.edgeFade)
                .frame(height: listHeight)
                // Open on the model in effect — with ten recents it can sit below
                // the fold, and a menu that opens blind to its own selection makes
                // the user hunt for their bearings.
                .onAppear { proxy.scrollTo(current, anchor: .center) }
                // ↑/↓ re-arms live, so follow the armed row. A click picks and
                // dismisses, so this only ever runs for keyboard moves.
                .onChange(of: current) {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(current, anchor: .center)
                    }
                }
            }
            // The tail row out of the recents and into the whole catalog. It sits
            // OUTSIDE the scroller — a door you can always reach, not a row that
            // can scroll away. A hairline sets it apart from the models above: it
            // isn't a model to arm, and the ↑/↓ cursor deliberately skips it.
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
        .background(ModelDetailAnchorProbe(anchor: detailAnchor))
        .onAppear(perform: installKeyMonitor)
        .onDisappear {
            removeKeyMonitor()
            ModelDetailPanel.shared.scheduleHide()
        }
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

    /// Reuse the catalog's full metadata whenever the recent row is still present
    /// there. A stale/live-only recent can outlast the catalog snapshot, so keep a
    /// bare-id fallback; it carries the same curated speed/intelligence inference
    /// the full picker uses until richer metadata arrives.
    private func detailModel(for row: Row) -> PickerModel {
        if let model = ModelCatalogStore.shared.rows(selected: row.provider)
            .first(where: { $0.provider == row.provider && $0.info.id == row.id }) {
            return model
        }
        let name = ModelRatings.prettyName(for: row.id, provider: row.provider)
        let info = ModelInfo(id: row.id,
                             vendor: ModelRatings.vendor(for: row.id, provider: row.provider),
                             name: name)
        return PickerModel(provider: row.provider,
                           providerName: row.provider.displayName,
                           hasKey: ModelCatalogStore.ready(row.provider),
                           featured: false,
                           info: info,
                           displayName: name)
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

/// A stable reference to the custom quick menu's SwiftUI root. Its screen frame
/// is read at hover time, so the detail card follows a menu that moved with the
/// island without publishing geometry on every layout pass.
@MainActor
private final class ModelDetailAnchor: ObservableObject {
    weak var view: NSView?

    var frame: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct ModelDetailAnchorProbe: NSViewRepresentable {
    let anchor: ModelDetailAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(false)
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
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
    /// The Agent picker is also a custom child panel, so give the shared detail
    /// window the same exact screen anchor the Ask recents menu supplies.
    @StateObject private var detailAnchor = ModelDetailAnchor()
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
        .background(ModelDetailAnchorProbe(anchor: detailAnchor))
        .onAppear {
            syncMirrors()
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
            ModelDetailPanel.shared.scheduleHide()
        }
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
        .onHover { inside in
            guard inside else {
                ModelDetailPanel.shared.scheduleHide()
                return
            }
            guard let frame = detailAnchor.frame,
                  let model = detailModel(for: c) else {
                ModelDetailPanel.shared.scheduleHide()
                return
            }
            ModelDetailPanel.shared.show(model, beside: frame)
        }
    }

    /// Project an Agent CLI choice into the catalog model the shared detail card
    /// already understands. Concrete catalog metadata wins; a just-landed CLI
    /// model still gets the same curated fallback until that catalog catches up.
    private func detailModel(for choice: AgentModelChoice) -> PickerModel? {
        guard let id = choice.id else { return nil }
        let provider: Provider
        switch choice.engine {
        case .codex:       provider = .codex
        case .claude:      provider = .claudeCode
        case .grok:        provider = .grokCode
        case .commandCode: provider = .commandCode
        case .pi:          provider = .piCode
        }
        if let model = ModelCatalogStore.shared.rows(selected: provider)
            .first(where: { $0.provider == provider && $0.info.id == id }) {
            return model
        }
        let info = ModelInfo(id: id,
                             vendor: ModelRatings.vendor(for: id, provider: provider),
                             name: choice.label)
        return PickerModel(provider: provider,
                           providerName: provider.displayName,
                           hasKey: ModelCatalogStore.ready(provider),
                           featured: false,
                           info: info,
                           displayName: choice.label)
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
