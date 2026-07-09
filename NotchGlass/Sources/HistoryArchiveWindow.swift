import AppKit
import SwiftUI

/// The standalone **History** window: a genuinely self-contained top-level window
/// showing the COMPLETE conversation/capture archive — not the newest-slice the
/// notch list keeps (see `NotchModel.notchRecentCap`).
///
/// It is deliberately DECOUPLED from the notch panel. Clicking a conversation here
/// expands its full transcript *inside this window* (a list ↔ detail split); it
/// never summons the notch, never mutates the notch's on-screen state, and never
/// closes itself. The only thing it shares with the rest of the app is the
/// persisted history data itself (read-only browsing + delete) and the
/// Notes/Reminders jump, which is an explicit "leave the app" action by nature.
///
/// Visually it wears the **same Liquid Glass language as the notch island**: a
/// transparent window filled with one dark smoked-glass slab (real system
/// `.glassEffect` on macOS 26+, a dark blur below), the island's specular hairline
/// rim, and the panel's whole token/chip vocabulary — glass capsules for the
/// search field and filters, `Tokens.text*` ink, `glassCapsule`/`GlassPressStyle`
/// chips — so opening History reads as the same surface as the notch, not a stock
/// AppKit window.
@MainActor
final class HistoryArchiveWindowController: NSObject, NSWindowDelegate {
    static let shared = HistoryArchiveWindowController()

    private var window: NSWindow?

    /// True while the History window is on screen. The notch-close path checks this
    /// before yielding activation back to the app the user came from: with the
    /// History window up, pushing Notch to the background would drag this window
    /// down with the whole `.accessory` app, reading as "the window closed itself".
    var isVisible: Bool { window?.isVisible ?? false }

    private override init() {}

    /// Open (or bring to front) the History window. Reuses the single instance so
    /// repeated invocations don't stack duplicates.
    func present(model: NotchModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L("history.window.title")
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 400)

        // Go transparent so the dark Liquid Glass slab the SwiftUI content draws is
        // the ONLY visible surface — no stock light `windowBackgroundColor` behind
        // it. The traffic-light controls and the drag-to-move titlebar stay (it's a
        // `.titled` window with `fullSizeContentView`), but the title text and the
        // titlebar's own material are hidden so the glass reaches edge to edge.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titleVisibility = .hidden
        // Force the dark side of every system control (traffic lights aside, the
        // resize cursor, focus rings, text-selection) so they read against the dark
        // glass instead of flipping to a light-mode treatment on a light desktop.
        window.appearance = NSAppearance(named: .darkAqua)

        window.contentView = NSHostingView(rootView: HistoryArchiveView(model: model))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("NotchHistoryArchive")

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the instance so the next open builds a fresh window bound to the
        // current model, rather than reviving a torn-down one.
        window = nil
    }
}

// MARK: - Window glass surface

/// The window's background — a rectangular sibling of the notch island's
/// `GlassMaterial`: one even slab of dark smoked Liquid Glass (real system glass on
/// macOS 26+, a dark blur below) wrapped in the island's specular hairline rim, so
/// the whole History window reads as the same material as the notch. Rectangular
/// (the window is resizable), so it uses a plain `Rectangle`/rounded-none surface
/// rather than the `NotchShape` silhouette.
private struct WindowGlassBackground: View {
    var body: some View {
        Rectangle()
            .fill(.clear)
            .nativeGlass(in: Rectangle())
            // One even dark veil so the slab reads as dark smoked glass and keeps
            // text legible — the same idea as the panel's `darkVeil`, flattened to a
            // single value since a rectangular window has no notch/melt band. The
            // baked glass tint (see `GlassMaterial.bakedTint`) already carries part
            // of the darkening, so this veil layers to the panel's settled tone.
            .overlay(Color.black.opacity(0.30))
            .overlay(
                // A whisper-thin top sheen — the same touch of depth the island's
                // veil paints just under its lip.
                LinearGradient(
                    colors: [.white.opacity(0.05), .white.opacity(0.0)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 90)
                .frame(maxHeight: .infinity, alignment: .top)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            )
            .ignoresSafeArea()
    }
}

/// A soft glass hairline used in place of AppKit's `Divider()` — the same
/// whisper-white rule the notch panel uses to separate sections, so seams read as
/// light caught on the glass rather than a stock grey line.
private struct GlassHairline: View {
    var horizontal: Bool = true
    var body: some View {
        Rectangle()
            .fill(Tokens.hairline)
            .frame(width: horizontal ? nil : 1, height: horizontal ? 1 : nil)
    }
}

// MARK: - Content

/// The archive's content: a master list on the left (search + source filter + every
/// retained item) and a detail pane on the right that renders the selected
/// conversation's full transcript. Entirely self-hosted — selecting a row only
/// changes this window's own `selection`, nothing outside it. Everything sits over
/// the one `WindowGlassBackground` slab; the panes are transparent so the glass
/// shows through the whole window.
private struct HistoryArchiveView: View {
    @ObservedObject var model: NotchModel

    @State private var query = ""
    @State private var sourceFilter: NotchModel.HistoryItem.Source? = nil
    @State private var selection: UUID? = nil

    private var items: [NotchModel.HistoryItem] {
        var items = model.history
        if let sourceFilter {
            items = items.filter { $0.source == sourceFilter }
        }
        guard !query.isEmpty else { return items }
        return items.filter { $0.displayTitle.localizedCaseInsensitiveContains(query) }
    }

    private var selected: NotchModel.HistoryItem? {
        guard let selection else { return nil }
        return model.history.first { $0.id == selection }
    }

    var body: some View {
        HSplitView {
            master
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            detail
                .frame(minWidth: 300, maxWidth: .infinity)
        }
        .frame(minWidth: 560, minHeight: 380)
        .background(WindowGlassBackground())
        // The specular hairline rim that wraps the whole window, the same lit bevel
        // the island wears — stamped over the composited content so it traces the
        // window edge crisply.
        .overlay(
            Rectangle()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.14), .white.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        )
        .ignoresSafeArea()
    }

    // MARK: - Master (list)

    private var master: some View {
        VStack(spacing: 0) {
            header
            GlassHairline()
            if items.isEmpty {
                emptyList
            } else {
                list
            }
        }
        // Transparent: the window glass shows through. A whisper-faint left-column
        // wash sets the master apart from the detail without a solid fill.
        .background(Color.white.opacity(0.02))
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text3)
                TextField(L("history.window.search"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.sf(13))
                    .foregroundStyle(Tokens.text1)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Tokens.text4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // The search field wears the panel's glass-capsule chrome — a real
            // translucent glass pill with the specular rim, matching the notch's
            // own input affordances.
            .glassCapsule(in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                          brighter: false)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 6) {
                filterPill(nil, L("history.window.filter.all"))
                filterPill(.ask, L("history.window.filter.ask"))
                filterPill(.note, L("history.window.filter.notes"))
                filterPill(.reminder, L("history.window.filter.reminders"))
                Spacer()
                Text(L("history.window.count", items.count))
                    .font(.sf(11, weight: .medium))
                    .foregroundStyle(Tokens.text4)
                    .monospacedDigit()
            }
        }
        .padding(12)
    }

    private func filterPill(_ source: NotchModel.HistoryItem.Source?, _ title: String) -> some View {
        HistoryFilterPill(
            title: title,
            active: sourceFilter == source,
            tint: source?.archiveTint,
            action: { sourceFilter = source }
        )
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(items) { item in
                    HistoryArchiveRow(
                        item: item,
                        selected: selection == item.id,
                        select: { selection = item.id },
                        delete: {
                            if selection == item.id { selection = nil }
                            model.deleteHistory(id: item.id)
                        },
                        jump: { model.openCaptureInApp(item) }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    private var emptyList: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Tokens.text4)
            Text(query.isEmpty && sourceFilter == nil
                 ? L("history.window.empty")
                 : L("history.window.empty.filtered"))
                .font(.sf(13))
                .foregroundStyle(Tokens.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Detail (transcript)

    @ViewBuilder
    private var detail: some View {
        if let item = selected {
            HistoryDetailView(item: item, jump: { model.openCaptureInApp(item) })
                .id(item.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Tokens.text4)
                Text(L("history.window.detail.empty"))
                    .font(.sf(13))
                    .foregroundStyle(Tokens.text3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One source-filter pill in the master header — the same Liquid Glass chip family
/// as the notch's `ManageFilterChip`: plain glass that brightens on hover, wearing
/// its source's tint when active. Tapping toggles the filter.
private struct HistoryFilterPill: View {
    let title: String
    let active: Bool
    /// The source's app colour (Notes amber, Reminders orange, Ask blue), washed
    /// into the glass when the pill is active. `nil` for the "All" pill.
    let tint: Color?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.sf(11, weight: .medium))
                .foregroundStyle(active ? Tokens.text1 : (hovering ? Tokens.text2 : Tokens.text3))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .glassCapsule(in: Capsule(), brighter: active || hovering,
                              tint: active ? tint : nil)
                .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
    }
}

/// One master-list row: title + date, a trailing time/destination affordance, a
/// selected glass wash, and a right-click Delete. Selecting only sets this window's
/// selection — it does not touch the notch. The selected/hover states use the same
/// `HistoryRowStyle` glass-hint the notch's Recent rows use, not a solid accent fill.
private struct HistoryArchiveRow: View {
    let item: NotchModel.HistoryItem
    let selected: Bool
    let select: () -> Void
    let delete: () -> Void
    let jump: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle)
                        .font(.sf(13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(selected ? Tokens.text1 : Tokens.text2)
                    Text(item.t, style: .date)
                        .font(.sf(11))
                        .foregroundStyle(Tokens.text4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(HistoryRowStyle(selected: selected))
        .contextMenu {
            Button(L("recent.delete"), role: .destructive, action: delete)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if item.source == .ask {
            Text(relativeTime(item.t))
                .font(.sf(11, weight: .medium).monospacedDigit())
                .foregroundStyle(Tokens.text4)
        } else {
            Button(action: jump) {
                HStack(spacing: 3) {
                    Text(item.source == .note ? L("recent.badge.notes") : L("recent.badge.reminders"))
                        .font(.sf(11, weight: .medium))
                    Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(Tokens.text3)
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .glassCapsule(in: Capsule(), brighter: false, tint: item.source.archiveTint)
                .contentShape(Capsule())
            }
            .buttonStyle(GlassPressStyle())
        }
    }
}

/// The detail pane: the full transcript of one conversation, rendered entirely
/// inside this window from the saved `Turn`s. A Note/Reminder capture has no
/// transcript, so it shows a short card with a jump button instead. Transparent so
/// the window glass shows through; the transcript bubbles carry their own glass.
private struct HistoryDetailView: View {
    let item: NotchModel.HistoryItem
    let jump: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            GlassHairline()
            if item.source == .ask {
                transcript
            } else {
                capture
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var titleBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.displayTitle)
                .font(.sf(16, weight: .semibold))
                .foregroundStyle(Tokens.text1)
                .lineLimit(2)
            Text(item.t.formatted(date: .abbreviated, time: .shortened))
                .font(.sf(11))
                .foregroundStyle(Tokens.text4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(item.conversation) { turn in
                    TranscriptBubble(turn: turn)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private var capture: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.q)
                .font(.sf(14))
                .foregroundStyle(Tokens.text1)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: jump) {
                HStack(spacing: 5) {
                    Text(item.source == .note ? L("recent.badge.notes") : L("recent.badge.reminders"))
                        .font(.sf(12, weight: .medium))
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Tokens.text2)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassCapsule(in: Capsule(), brighter: false, tint: item.source.archiveTint)
                .contentShape(Capsule())
            }
            .buttonStyle(GlassPressStyle())
            Spacer()
        }
        .padding(16)
    }
}

/// One transcript bubble in the detail pane — a labelled, selectable block per
/// turn (You / Assistant), with an optional trailing model tag on answers. The
/// bubble sits on a faint glass wash (a hint, not a slab) in the panel's language:
/// the user's turn leans toward the Ask blue, the assistant's stays neutral ink.
private struct TranscriptBubble: View {
    let turn: NotchModel.Turn

    private var isUser: Bool { turn.role == "user" }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(isUser ? L("history.detail.you") : L("history.detail.assistant"))
                    .font(.sf(11, weight: .semibold))
                    .foregroundStyle(isUser ? NotchModel.Panel.chat.intentInk : Tokens.text3)
                if let model = turn.answerModel ?? turn.regenModel, !model.isEmpty {
                    Text(prettyModel(model))
                        .font(.sf(10))
                        .foregroundStyle(Tokens.text4)
                }
            }
            Text(turn.text)
                .font(.sf(14))
                .foregroundStyle(Tokens.text1)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        // A whisper of glass on the bubble: a faint tinted floor, a
                        // thin real-material shimmer, and a hairline rim — the same
                        // "hint of glass, not a slab" recipe the notch rows use.
                        .fill(isUser
                              ? NotchModel.Panel.chat.intentTint.opacity(0.06)
                              : Color.white.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.thinMaterial)
                                .opacity(0.14)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Tokens.hairline, lineWidth: 0.5)
                        )
                )
        }
    }

    /// Strip the vendor prefix / `:free` suffix so a bare model name shows, matching
    /// the notch footer's presentation.
    private func prettyModel(_ raw: String) -> String {
        var s = raw
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        if s.hasSuffix(":free") { s = String(s.dropLast(":free".count)) }
        return s
    }
}

/// The source→tint mapping for the archive's chips, kept local to this window so it
/// doesn't reach into `NotchBody`'s `fileprivate` copy. Same palette everywhere a
/// source shows its face: Ask a cool blue, Note the Notes amber, Remind the
/// Reminders orange.
private extension NotchModel.HistoryItem.Source {
    var archiveTint: Color {
        switch self {
        case .ask:      return .blue
        case .note:     return .yellow
        case .reminder: return .orange
        }
    }
}
