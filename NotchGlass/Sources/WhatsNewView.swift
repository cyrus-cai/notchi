import AppKit
import SwiftUI

/// The "What's New" release-notes panel, rendered *inside* the notch in place of
/// the recent list — same full-body takeover as `InlineSettingsView`. Reached by
/// ⌘↵, by the input-row cue, or by the once-per-version auto-show; the back
/// chevron / Esc returns to the idle prompt.
///
/// Content comes from `WhatsNewService`, whose notes are bundled into the app —
/// so the normal case is just a scrollable column of per-version sections, always
/// available, online or off. The empty state is a defensive fallback for the (not
/// expected) case of no bundled notes; it points at the Releases page so the
/// panel still hands the user somewhere to go.
///
/// The reader is TWO columns, same shape as inline Settings: a version rail on
/// the left, the notes on the right. The notes are ONE continuous scroll — no
/// version heading repeating over each block — and the rail tracks it, lighting
/// up whichever release the reading position currently sits in. Clicking a
/// version in the rail scrolls the notes to it.
struct WhatsNewView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject private var service = WhatsNewService.shared

    /// Which release the notes column is currently parked in — the row the rail
    /// highlights. Empty until the first scroll report lands (see `activeVersion`),
    /// which reads as the newest release, the one the column opens on.
    @State private var active: String = ""

    /// The release a rail click asked the notes column to scroll to.
    @State private var jumpTarget: JumpTarget?

    /// While a rail jump animates, the scroll tracking stands down until this
    /// moment — otherwise every release the jump flies past would claim the rail.
    @State private var trackingResumesAt: Date = .distantPast

    /// Width of the version rail — enough for the "CURRENT VERSION" caps label to
    /// sit on one line, and no wider: the reading column is what the 600pt panel
    /// is for.
    private let railWidth: CGFloat = 112

    /// How far below the viewport top a release's first line must pass before the
    /// rail calls it the one being read. A little slack, so a section counts as
    /// "current" the moment it settles under the top taper rather than the instant
    /// its first pixel appears.
    private let activationLine: CGFloat = 56

    /// Coordinate space the section probes measure in — the notes scroller itself,
    /// so a section parked at the top of the viewport reports ~0.
    private let scrollSpace = "whatsnew.notes"

    /// Both columns' height — FIXED, and borrowed from Recent, exactly as inline
    /// Settings does it: the island is the same height reading release notes as it
    /// is on the recent list. Recent's immersive layout floats its prompt over the
    /// scroll surface, so the whole 320pt is list; here the back-pill header
    /// (12 + 26 + 8) comes out of the same budget. A longer history just scrolls.
    private static let headerChrome: CGFloat = 12 + 26 + 8
    private var columnHeight: CGFloat {
        NotchBody.immersiveListHeight - Self.headerChrome
    }

    /// Length of the bottom taper where the notes dissolve as they scroll past the
    /// frame edge, matching the recent list's `edgeFade`.
    private let edgeFade: CGFloat = 64

    /// Keep the in-notch reader focused on the latest changes. The website is
    /// the complete archive once the bundled history grows beyond this point.
    private let inAppEntryLimit = 10

    private var displayedEntries: [WhatsNewService.Entry] {
        Array(service.entries.prefix(inAppEntryLimit))
    }

    private var hasMoreEntries: Bool {
        service.entries.count > inAppEntryLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Group {
                if !service.entries.isEmpty {
                    releaseList
                } else {
                    emptyState
                }
            }
            .animation(.easeOut(duration: 0.2), value: service.entries)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            PanelBackPill(title: L("whatsnew.title"), help: L("whatsnew.back")) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    model.closeWhatsNew()
                }
            }

            Spacer()
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Release list

    /// Rail on the left, notes on the right. Each column owns its OWN
    /// `ScrollViewReader` — one reader wrapping both left the jump ambiguous
    /// between two scrollers — and they talk through state: a rail click writes
    /// `jumpTarget`, which the notes column scrolls to; scrolling the notes writes
    /// `active`, which the rail follows.
    private var releaseList: some View {
        HStack(alignment: .top, spacing: 0) {
            versionRail

            notesColumn
                .padding(.leading, 14)
        }
        .onAppear {
            if active.isEmpty { active = displayedEntries.first?.version ?? "" }
        }
    }

    // MARK: - Version rail

    /// The left column: one quiet row per release, the one being read lit up.
    /// Scrolls on its own once the history outgrows the panel, and follows the
    /// reading position so the active row is always in sight.
    private var versionRail: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(displayedEntries) { entry in
                        VersionItem(
                            version: entry.version,
                            isCurrent: entry.version == UpdaterService.currentVersion,
                            selected: entry.version == active
                        ) {
                            active = entry.version
                            // Hand the jump to the notes column. A fresh token each
                            // time, so clicking the same row twice still fires.
                            jumpTarget = JumpTarget(version: entry.version)
                        }
                        .id(Self.railID(entry.version))
                    }
                }
                // The rail's first row starts level with the notes' first line: both
                // columns sit below the same runway (see `notesColumn`).
                .padding(.top, 28)
                .padding(.bottom, 20)
            }
            .onChange(of: active) { _, version in
                guard !version.isEmpty else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.railID(version), anchor: .center)
                }
            }
        }
        .frame(width: railWidth, height: columnHeight)
        .scrollIndicators(.never)
        .scrollEdgeFade(top: true, bottom: true, topFade: 28, bottomFade: edgeFade)
    }

    private static func railID(_ version: String) -> String { "whatsnew.rail." + version }

    /// A rail click, carried to the notes column. Identity is the token, not the
    /// version, so re-picking the same release still scrolls.
    private struct JumpTarget: Equatable {
        var version: String
        var token = UUID()
    }

    // MARK: - Notes column

    /// The right column: every release's notes end to end, in one scroll. No
    /// per-version heading — the rail names what you're reading — just a hairline
    /// between releases so one block's FEATURES can't be mistaken for the next.
    private var notesColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(displayedEntries.enumerated()), id: \.element.id) { index, entry in
                        VStack(alignment: .leading, spacing: 0) {
                            if index > 0 {
                                Rectangle()
                                    .fill(Tokens.hairline)
                                    .frame(height: 0.5)
                                    .padding(.vertical, 26)
                            }

                            releaseSection(entry)
                        }
                        // The jump anchor sits ABOVE the divider, so landing on a
                        // release parks its rule at the viewport's faded top edge
                        // and the notes themselves start clear of it.
                        .id(entry.id)
                        // Zero-size probe: where this release sits inside the
                        // viewport, which is what the rail tracks.
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: SectionOffsetsKey.self,
                                    value: [entry.id: g.frame(in: .named(scrollSpace)).minY]
                                )
                            }
                        )
                    }

                    if hasMoreEntries {
                        Button(L("whatsnew.viewAllReleaseNotes")) {
                            NSWorkspace.shared.open(UpdaterService.releaseNotesPage)
                        }
                        .buttonStyle(.plain)
                        .font(.sf(11.5, weight: .medium))
                        .foregroundStyle(Tokens.text2)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 34)
                    }
                }
                .padding(.horizontal, 4)
                // Breathing room the top taper falls across, so the newest release
                // rests below the gradient at full strength before any scrolling.
                .padding(.top, 28)
                .padding(.bottom, 20)
            }
            .onChange(of: jumpTarget) { _, target in
                guard let target else { return }
                // The jump sweeps past every release in between; freeze the
                // tracking for its duration so the rail doesn't strobe through
                // them on the way.
                trackingResumesAt = Date().addingTimeInterval(0.4)
                withAnimation(.easeOut(duration: 0.28)) {
                    proxy.scrollTo(target.version, anchor: .top)
                }
            }
        }
        .frame(height: columnHeight)
        .scrollIndicators(.never)
        .coordinateSpace(name: scrollSpace)
        // Both edges taper, so the notes dissolve into the header the same
        // way they dissolve into the bottom.
        .scrollEdgeFade(top: true, bottom: true, topFade: 28, bottomFade: edgeFade)
        .onPreferenceChange(SectionOffsetsKey.self) { offsets in
            guard Date() >= trackingResumesAt else { return }
            if let version = activeVersion(from: offsets), version != active {
                active = version
            }
        }
    }

    /// The lowest release whose first line has passed the activation line — the
    /// one the reader is actually inside. Falls back to the newest entry while the
    /// column still sits at the very top.
    private func activeVersion(from offsets: [String: CGFloat]) -> String? {
        let ordered = displayedEntries.compactMap { entry in
            offsets[entry.id].map { (entry.version, $0) }
        }
        guard !ordered.isEmpty else { return nil }
        return (ordered.last { $0.1 <= activationLine } ?? ordered[0]).0
    }

    /// One release's notes: a quiet version/date meta line — the rail says where
    /// you are, this says it again in the column so two adjacent blocks can't blur
    /// together — over its Feature / Improvement / Fix sub-sections, each present
    /// only when it has lines. The newest entry leads the column.
    private func releaseSection(_ entry: WhatsNewService.Entry) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.version)
                    .font(.sf(11, weight: .medium))
                    .foregroundStyle(Tokens.text3)
                Spacer(minLength: 0)
                if let date = entry.date, !date.isEmpty {
                    Text(date)
                        .font(.sf(11, weight: .medium))
                        .foregroundStyle(Tokens.text4)
                }
            }

            if let heroAssetName = entry.heroAssetName {
                Image(heroAssetName)
                    .resizable()
                    .aspectRatio(2, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Tokens.hairline, lineWidth: 1)
                    )
                    .accessibilityHidden(true)
            }

            if !entry.features.isEmpty {
                noteGroup(heading: L("whatsnew.section.features"), lines: entry.features)
            }
            if !entry.improvements.isEmpty {
                noteGroup(heading: L("whatsnew.section.improvements"), lines: entry.improvements)
            }
            if !entry.fixes.isEmpty {
                noteGroup(heading: L("whatsnew.section.fixes"), lines: entry.fixes)
            }
            if !entry.others.isEmpty {
                noteGroup(heading: L("whatsnew.section.others"), lines: entry.others)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A titled sub-section — a small caps heading ("FEATURES" / "FIXES") over its
    /// own bullet list.
    private func noteGroup(heading: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading)
                .captionLabel()

            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                bulletLine(line)
            }
        }
    }

    /// One release-note bullet: a small leading dot and the line, wrapping freely.
    private func bulletLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(Tokens.text4)
                .frame(width: 3, height: 3)
                .padding(.top, 7)   // nudge the dot onto the first line's x-height
            Text(text)
                .font(.sf(12.5))
                .lineSpacing(4)     // let wrapped lines breathe
                .foregroundStyle(Tokens.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Empty fallback

    /// No bundled notes (not expected) — a quiet line plus a link to the canonical
    /// releases page, so the panel still hands the user somewhere to go.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("whatsnew.empty"))
                .font(.sf(12.5))
                .foregroundStyle(Tokens.text3)
                .fixedSize(horizontal: false, vertical: true)

            Button(L("whatsnew.viewReleases")) {
                NSWorkspace.shared.open(UpdaterService.releaseNotesPage)
            }
            .buttonStyle(.plain)
            .font(.sf(11.5, weight: .medium))
            .foregroundStyle(Tokens.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 16)
    }

    // MARK: - Rail row

    /// One version in the rail: just the number, with the running build's release
    /// carrying the "CURRENT VERSION" caps label under it. Quiet text that
    /// brightens on hover, a faint fill when it's the release being read — the
    /// same translucent-chip language as the Settings sidebar, at the panel's
    /// standard chip radius (a capsule for the one-line rows, square-ish ends for
    /// the two-line current one).
    private struct VersionItem: View {
        var version: String
        var isCurrent: Bool
        var selected: Bool
        var action: () -> Void

        @State private var hovering = false

        /// A one-line row is a full capsule — the panel's default chip. Only the
        /// current-version row, which carries a second line, steps down to a
        /// square-ish radius so its ends don't blow out into half-circles.
        private var shape: AnyShape {
            isCurrent ? AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                      : AnyShape(Capsule())
        }

        var body: some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(version)
                        .font(.sf(12.5, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(selected ? Tokens.text1 : (hovering ? Tokens.text2 : Tokens.text3))

                    if isCurrent {
                        Text(L("whatsnew.currentBadge"))
                            .font(.sf(8.5, weight: .semibold))
                            .tracking(0.6)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(Tokens.text4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(minHeight: 30)
                .background(shape.fill(.white.opacity(selected ? 0.08 : (hovering ? 0.04 : 0))))
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}

/// Where each release's notes currently sit inside the notes viewport, keyed by
/// version — the reading position the rail follows.
private struct SectionOffsetsKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
