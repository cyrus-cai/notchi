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
struct WhatsNewView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject private var service = WhatsNewService.shared

    /// The notes column caps its height and scrolls past it, so a long history of
    /// releases can't push the island off the bottom of the screen. Generous —
    /// the notes breathe and just scroll when there are more than a few releases.
    private let maxHeight: CGFloat = 360

    /// Length of the bottom taper where the notes dissolve as they scroll past the
    /// frame edge, matching the recent list's `edgeFade`.
    private let edgeFade: CGFloat = 64

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
            Button {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    model.closeWhatsNew()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RecentEntryStyle())

            Text(L("whatsnew.title"))
                .font(.sf(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Tokens.text4)

            Spacer()
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Release list

    private var releaseList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                ForEach(service.entries) { entry in
                    releaseSection(entry)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .frame(maxHeight: maxHeight)
        .scrollIndicators(.never)
        // The header caps the top, so only the bottom tapers — the bundled history
        // always outgrows the frame (a spec-less/empty changelog takes `emptyState`
        // instead), so the notes always dissolve into this bottom edge as they scroll.
        .scrollEdgeFade(top: false, bottom: true, bottomFade: edgeFade)
    }

    /// One release: a quiet meta line (date leading, version trailing — both the
    /// same small grey) over its Feature / Fix sub-sections. Each sub-section
    /// appears only when it has lines. The newest entry leads the column.
    private func releaseSection(_ entry: WhatsNewService.Entry) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let date = entry.date, !date.isEmpty {
                    Text(date)
                        .font(.sf(11, weight: .medium))
                        .foregroundStyle(Tokens.text4)
                }
                Spacer(minLength: 0)
                if entry.version == UpdaterService.currentVersion {
                    currentBadge
                }
                Text(entry.version)
                    .font(.sf(11, weight: .medium))
                    .foregroundStyle(Tokens.text4)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A quiet pill flagging the release the running build is on. Neutral by
    /// design — the design system avoids coloured/green pills — so it's a small
    /// caps label in a hairline-bordered capsule, sitting just left of the version.
    private var currentBadge: some View {
        Text(L("whatsnew.currentBadge"))
            .font(.sf(8.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Tokens.text3)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                Capsule()
                    .fill(Tokens.ink.opacity(0.06))
                    .overlay(Capsule().stroke(Tokens.hairline, lineWidth: 1))
            )
    }

    /// A titled sub-section — a small caps heading ("FEATURES" / "FIXES") over its
    /// own bullet list.
    private func noteGroup(heading: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading)
                .font(.sf(9.5, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Tokens.text4)

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
                NSWorkspace.shared.open(UpdaterService.releasesPage)
            }
            .buttonStyle(.plain)
            .font(.sf(11.5, weight: .medium))
            .foregroundStyle(Tokens.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 16)
    }
}
