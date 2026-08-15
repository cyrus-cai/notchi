import SwiftUI

// MARK: - Digest

/// Everything Settings → Stats shows, computed **once** from the archive rather
/// than re-derived per row. It is a plain value type on purpose: the pane holds
/// one, `Equatable` keeps SwiftUI from redrawing the grid when nothing moved,
/// and the whole computation is a pure function of (rows, now) — see
/// `StatsDigest.make`, which follows `NotchModel.archiveDigest`'s precedent of
/// keeping archive math `nonisolated` and testable without a live model.
struct StatsDigest: Equatable {
    /// Messages exchanged in Ask threads — every turn, user and assistant alike,
    /// not one per conversation. A thread is a container; the messages in it are
    /// what the user actually did.
    var chatMessages = 0
    /// Notes + reminders filed. One number: both are "a line the notch put
    /// somewhere else", and splitting them would spend two of the four tiles on
    /// the app's two quietest buckets. Counted per capture — a note has no turns
    /// to count.
    var captures = 0
    /// Messages exchanged in agent runs, on the same footing as `chatMessages`.
    var agentMessages = 0

    /// Days with at least one row of any kind.
    var activeDays = 0
    /// Consecutive active days ending today — or ending yesterday, so a streak
    /// doesn't read as broken just because the day is young.
    var currentStreak = 0
    var longestStreak = 0
    /// The hour of the day (0…23) the notch is reached for most often — the one
    /// thing the rhythm card says about a *day* rather than about which days.
    /// `nil` only on an empty archive.
    var peakHour: Int?

    /// Per active day, in the same currency the totals are counted in: messages
    /// for the two thread buckets, one apiece for captures. Inactive days are
    /// simply absent, which is also how the grid draws them.
    var counts: [Date: Int] = [:]
    /// The same days, split by bucket. The header readout names what a square
    /// counted ("24 chat messages · 1 note") rather than reporting "25 items",
    /// which left the reader guessing what an item was.
    var breakdown: [Date: DayCounts] = [:]
    /// The oldest day the archive reaches back to — how far the grid's ‹ can
    /// page. `nil` on an empty archive.
    var firstDay: Date?

    /// One day's activity, by bucket — the same three the totals row is built
    /// from, counted the same way.
    struct DayCounts: Equatable {
        var chatMessages = 0
        var captures = 0
        var agentMessages = 0
        var total: Int { chatMessages + captures + agentMessages }
    }
    /// Intensity level (1…4) for those same days. Kept beside the counts — not
    /// derived in the view — because the thresholds are a property of the whole
    /// archive (they're quantiles of it), so no cell can re-derive them alone.
    var levels: [Date: Int] = [:]
    /// Every retained row, all kinds. The pane's one "is there anything at all"
    /// test — a user with only notes still has usage to show.
    var total = 0
    var isEmpty: Bool { total == 0 }

    // MARK: Computation

    /// Fold the archive into the digest. `nonisolated` and taking its rows as an
    /// argument (rather than reading `NotchModel`) so it can run off the main
    /// thread while the pane is opening, and so it can be exercised against a
    /// fixture archive.
    ///
    /// Rows still in flight (`pending`) are skipped: the question being answered
    /// right now is parked in `history` the moment it's submitted, and counting it
    /// would make the totals tick up before the answer exists.
    static func make(from items: [NotchModel.HistoryItem],
                     now: Date = Date(),
                     calendar: Calendar = .current) -> StatsDigest {
        var digest = StatsDigest()
        var perDayBuckets: [Date: DayCounts] = [:]
        var perHour = [Int](repeating: 0, count: 24)

        for item in items where !item.pending {
            digest.total += 1
            perHour[calendar.component(.hour, from: item.t)] += 1

            let day = calendar.startOfDay(for: item.t)
            var buckets = perDayBuckets[day] ?? DayCounts()
            switch item.source {
            case .ask:
                digest.chatMessages += messages(in: item)
                buckets.chatMessages += messages(in: item)
            case .note, .reminder:
                digest.captures += 1
                buckets.captures += 1
            case .agent:
                digest.agentMessages += messages(in: item)
                buckets.agentMessages += messages(in: item)
            }
            perDayBuckets[day] = buckets
        }

        let perDay = perDayBuckets.mapValues(\.total)
        digest.activeDays = perDay.count
        digest.counts = perDay
        digest.breakdown = perDayBuckets
        digest.levels = levels(for: perDay)

        let days = perDay.keys.sorted()
        digest.firstDay = days.first
        digest.longestStreak = longestStreak(in: days, calendar: calendar)
        digest.currentStreak = currentStreak(in: perDay, now: now, calendar: calendar)
        // Ties go to the earlier hour — `max(by:)` would hand them to the later
        // one, which on a flat archive makes the figure jump around between
        // launches for no reason the reader can see.
        if let peak = perHour.max(), peak > 0 {
            digest.peakHour = perHour.firstIndex(of: peak)
        }
        return digest
    }

    /// How many messages a thread holds. Legacy rows saved before multi-turn have
    /// no `turns` array and are exactly the one exchange their `q`/`a` pair
    /// records — two messages, the same as the transcript shows for them.
    private static func messages(in item: NotchModel.HistoryItem) -> Int {
        item.turns.map(\.count) ?? 2
    }

    /// How many pages of `step` weeks the archive reaches back beyond the window
    /// the grid opens on — how many times ‹ can be pressed.
    ///
    /// `windowWeeks` is what the grid already shows without paging at all; only
    /// what falls off the left edge of that needs a page. Counting from zero
    /// instead would hand the reader a last page that is empty but for a column
    /// or two at its right edge.
    func pagesBack(step: Int,
                   windowWeeks: Int,
                   now: Date = Date(),
                   calendar: Calendar = .current) -> Int {
        guard let firstDay else { return 0 }
        let days = calendar.dateComponents([.day],
                                           from: firstDay,
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let beyond = days - (windowWeeks - 1) * 7
        guard beyond > 0 else { return 0 }
        return Int((Double(beyond) / Double(step * 7)).rounded(.up))
    }

    /// Map each active day onto one of four intensities.
    ///
    /// Quantiles of the user's *own* active days, not fixed counts: a heavy user
    /// whose quiet day is 12 rows and a light user whose busy day is 3 should both
    /// see a grid with light and dark squares in it. Fixed thresholds would paint
    /// the first grid uniformly dark and the second uniformly pale — which is a
    /// grid that has stopped saying anything.
    private static func levels(for perDay: [Date: Int]) -> [Date: Int] {
        let counts = perDay.values.sorted()
        guard let last = counts.last, last > 0 else { return [:] }

        func quantile(_ p: Double) -> Int {
            counts[min(counts.count - 1, max(0, Int((Double(counts.count - 1) * p).rounded())))]
        }
        // Strictly increasing, so two levels can never claim the same count (which
        // is what a small archive — every day a single row — would otherwise do).
        let t2 = max(2, quantile(0.45))
        let t3 = max(t2 + 1, quantile(0.75))
        let t4 = max(t3 + 1, quantile(0.92))

        return perDay.mapValues { count in
            if count >= t4 { return 4 }
            if count >= t3 { return 3 }
            if count >= t2 { return 2 }
            return 1
        }
    }

    private static func longestStreak(in days: [Date], calendar: Calendar) -> Int {
        var best = 0, run = 0
        var previous: Date?
        for day in days {
            if let previous, calendar.dateComponents([.day], from: previous, to: day).day == 1 {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = day
        }
        return best
    }

    /// The run of consecutive days ending at today — or at yesterday. Anchoring on
    /// today alone would report "0 days" every morning until the first use, which
    /// reads as *losing* the streak rather than not having extended it yet.
    private static func currentStreak(in perDay: [Date: Int],
                                      now: Date,
                                      calendar: Calendar) -> Int {
        let today = calendar.startOfDay(for: now)
        var cursor = today
        if perDay[cursor] == nil {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  perDay[yesterday] != nil else { return 0 }
            cursor = yesterday
        }
        var streak = 0
        while perDay[cursor] != nil {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }
}

// MARK: - Type

extension Font {
    /// The one face every figure on this pane wears: **Prompt**, the bundled
    /// wordmark family, at display size.
    ///
    /// This is the only place in the app besides the About masthead that reaches
    /// for `.brand` — and it is the same argument. The wordmark is the app's
    /// voice for *the name of a thing*; a sheet of figures is the one other place
    /// where the number IS the content rather than a label on it, and San
    /// Francisco at semibold reads there as UI chrome. Prompt's geometric
    /// numerals give the sheet a face without inventing one.
    ///
    /// Everything else on the pane sits on three rungs and no more: figures here,
    /// `.sf(11)` for the label under a figure, `.sf(9)` for the grid's rails.
    /// 18 — the same size the About masthead sets the wordmark at, which is not a
    /// coincidence worth breaking: Prompt sets noticeably taller than San
    /// Francisco at equal point size, and every step above this pushed the
    /// activity card's bottom rim past the pane's fold.
    static var statsFigure: Font { .brand(18) }
}

// MARK: - Pane

/// Settings → **Stats**: what the archive adds up to. A read-only pane — four
/// headline numbers over one activity card — in the same recessed-card / token
/// vocabulary the rest of Settings is built from.
///
/// Everything here is derived from the local archive at display time; nothing is
/// counted, stored or sent anywhere else, which is why there is no state to reset
/// and no control on the pane.
struct StatsPane: View {
    let digest: StatsDigest
    /// The token odometer's reading. Not part of the digest on purpose: every
    /// other figure here is folded from the archive, and this one is counted from
    /// what providers reported — see `TokenMeter`.
    let tokens: TokenMeter.Reading
    /// Owned by the settings view: the day under the pointer is announced in the
    /// panel header, beside the back pill, where there is room for it and nothing
    /// it can push around.
    @Binding var hovered: StatsHoverDay?

    /// The gap between this pane's two cards — the same 14 the settings pane puts
    /// between its own rows, so Stats keeps the vertical rhythm of every other
    /// category rather than inventing a tighter one.
    private static let blockGap: CGFloat = 12

    var body: some View {
        if digest.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: Self.blockGap) {
                privacyLine
                // What was done, over the grid it was done on; the streaks — which
                // are a property of the grid, not of the archive — read below it as
                // its caption.
                StatsActivityCard(digest: digest, tokens: tokens, hovered: $hovered)
                streaks
            }
        }
    }

    /// A pane full of counts about what someone does all day is exactly where
    /// "who else sees this?" gets asked, so it's answered over the cards rather
    /// than three taps away in About → Privacy. One line, with the handling — and
    /// the policy behind it — under the same ⓘ the token tile carries.
    private var privacyLine: some View {
        HStack(spacing: 2) {
            Text(L("stats.privacy"))
                .font(.sf(11))
                .foregroundStyle(Tokens.text4)
                .lineLimit(1)
                .fixedSize()
            SettingInfo(privacyHint, glyph: 10, hit: 13)
                .accessibilityHidden(true)
        }
        .padding(.leading, 2)
    }

    /// The note, with the words "privacy policy" inside its last sentence carrying
    /// the link — the phrase is localized separately only so the range can be found
    /// in the sentence it already reads as part of. Underlined because the popover's
    /// body is already `text2`, so colour alone would make the link invisible.
    private var privacyHint: AttributedString {
        var text = AttributedString(L("stats.privacy.info"))
        if let range = text.range(of: L("stats.privacy.info.link")) {
            text[range].link = URL(string: "https://www.notch.website/privacy")
            text[range].foregroundColor = Tokens.text1
            text[range].underlineStyle = .single
        }
        return text
    }

    /// The rhythm figures, on their own row under the grid they summarize: three
    /// about *which days*, and — in the quarter the three of them left empty —
    /// one about what time of day.
    private var streaks: some View {
        HStack(spacing: 0) {
            StatsStreak(value: digest.activeDays, label: L("stats.activeDays"))
            StatsStreak(value: digest.currentStreak, label: L("stats.currentStreak"))
            StatsStreak(value: digest.longestStreak, label: L("stats.longestStreak"))
            if let peakHour = digest.peakHour {
                StatsStreak(fixed: StatsFormat.hour(peakHour), label: L("stats.peakHour"))
            }
        }
        .padding(10)
        .recessedSurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                         lit: false)
    }

    /// Same shape as the archive window's empty list — a light glyph over one
    /// line — so "nothing here yet" reads the same wherever the app says it.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar")
                .font(.sf(26, weight: .light))
                .foregroundStyle(Tokens.text4)
            Text(L("stats.empty"))
                .font(.sf(13))
                .foregroundStyle(Tokens.text3)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }
}

/// Whether the headline figures roll up from zero when the pane appears.
///
/// True everywhere the pane is looked at. False for `ImageRenderer`, which draws
/// one body pass and never fires `onAppear` — a snapshot taken through it would
/// otherwise catch the tiles at the zero they start from.
private struct StatsFigureRollKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var statsFigureRoll: Bool {
        get { self[StatsFigureRollKey.self] }
        set { self[StatsFigureRollKey.self] = newValue }
    }
}

/// Every figure on the pane, in the pane's one figure face — rolled up from zero
/// the first time it is looked at, with the native digit transition the island's
/// running chip already uses.
///
/// `value` is the number, not the string it ends on: an odometer interpolates a
/// quantity. A `nil` value is a reading that isn't one — the peak hour is a clock
/// time, and nothing counts up to 1 PM — which prints `fixed` and stays put.
private struct StatsFigure: View {
    var value: Int? = nil
    var format: (Int) -> String = StatsFormat.count
    var fixed: String = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.statsFigureRoll) private var roll

    /// What is on screen right now, as opposed to `value`, which is where it is
    /// headed. Zero until the pane appears.
    @State private var shown = 0

    /// The settled text: what the figure reads once the roll lands, and what
    /// VoiceOver is given — it must not read whatever frame it happened to catch.
    var settled: String { value.map(format) ?? fixed }

    var body: some View {
        Text(value.map { format(roll ? shown : $0) } ?? fixed)
            .font(.statsFigure)
            .foregroundStyle(Tokens.text1)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .contentTransition(.numericText(value: Double(shown)))
            // The animation has to ride the Text itself for `numericText` to
            // fire; on an enclosing stack it only moves the layout.
            .animation(reduceMotion ? nil : .snappy(duration: 0.5), value: shown)
            .onAppear { shown = value ?? 0 }
            .onChange(of: value) { _, new in shown = new ?? 0 }
    }
}

/// One headline number: its bucket's mark and the figure on one line, the label
/// under it. The mark is the same Lucide glyph that bucket wears in the composer
/// and in Recent, so the column is recognizable before the label is read.
private struct StatsTotal: View {
    let icon: LucideIcons.Mark
    let value: Int
    let format: (Int) -> String
    let label: String
    /// Only the token tile carries one — it's the single figure here the reader
    /// can't verify by counting their own rows, so a ⓘ beside its label says
    /// where it came from. The three bucket counts are exactly what they claim
    /// and stay silent.
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                // 12, up from 11: the mark has to hold its own beside an 18pt
                // Prompt figure, and at 11 it read as a stray dot next to one.
                LucideIcon(mark: icon, size: 12)
                    .foregroundStyle(Tokens.text4)
                StatsFigure(value: value, format: format)
            }
            // The longest label in the pane ("Palabras respondidas") is wider than
            // a quarter of the panel; it shrinks rather than truncating, because a
            // clipped label on a four-column sheet reads as a layout bug.
            // The label row is pinned to the height the label alone would take
            // (13 at `.sf(11)`) so the ⓘ can't set it. Left to size itself, the
            // button's own metrics made this one column's label sit a point and a
            // half below the three beside it — on a row of four tiles that reads
            // as a misprint.
            HStack(spacing: 2) {
                Text(label)
                    .font(.sf(11))
                    .foregroundStyle(Tokens.text3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                // Same ⓘ the settings rows collapse their captions behind, at the
                // smaller of its two sizes — this one trails a label inside a
                // quarter-width column, not a full row.
                if let note {
                    SettingInfo(note, glyph: 10, hit: 13)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 13)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(note.map { "\(label): \(format(value)). \($0)" }
                            ?? "\(label): \(format(value))")
    }
}

/// The rhythm block: the three lifetime totals over the day grid they were built
/// from, and the arrows that walk that grid back through the archive.
private struct StatsActivityCard: View {
    let digest: StatsDigest
    let tokens: TokenMeter.Reading

    @Binding var hovered: StatsHoverDay?

    /// How far back the grid is scrolled, in half-year steps — 0 is the window
    /// ending this week, which is where the pane always opens.
    @State private var page = 0

    /// The card's own content width, measured once, so the arrows can be asked
    /// the same question the grid answers with its geometry: how many weeks fit.
    @State private var contentWidth: CGFloat = 0

    /// How many steps the archive actually reaches back *beyond* the window the
    /// grid already shows. Zero on a young archive, which is when the arrows stay
    /// away entirely rather than sitting there greyed out over a grid that has
    /// nothing older to show.
    private var maxPage: Int {
        digest.pagesBack(step: StatsHeatmap.pageStep,
                         windowWeeks: StatsHeatmap.weeks(inCard: contentWidth))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // A real gutter between the columns, not just the labels' natural gap:
            // "Notes & reminders" beside "Agent messages" read as one run-on line
            // at spacing 0.
            HStack(alignment: .top, spacing: 8) {
                StatsTotal(icon: LucideIcons.messageCircle,
                           value: digest.chatMessages,
                           format: StatsFormat.total,
                           label: L("stats.conversations"))
                StatsTotal(icon: LucideIcons.pencilLine,
                           value: digest.captures,
                           format: StatsFormat.total,
                           label: L("stats.captures"))
                StatsTotal(icon: LucideIcons.codeXml,
                           value: digest.agentMessages,
                           format: StatsFormat.total,
                           label: L("stats.agentRuns"))
                // The fourth column the row was always laid out for. Its mark is
                // `hash` rather than a bucket glyph on purpose: the other three
                // name *which* bucket they counted, and this one is a measure
                // taken across all of them. It is also the one figure here that
                // starts at zero on an old archive, so it carries the ⓘ that
                // says why.
                StatsTotal(icon: LucideIcons.hash,
                           value: tokens.total,
                           format: StatsFormat.compact,
                           label: L("stats.tokens"),
                           note: L("stats.tokens.info"))
                pager
            }
            StatsHeatmap(digest: digest, page: min(page, maxPage), hovered: $hovered)
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { contentWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, width in contentWidth = width }
            }
        }
        .padding(10)
        .recessedSurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                         lit: false)
    }

    /// ‹ › over the newest column, on the card's top row rather than under the
    /// grid: the pane's bottom 32pt is the settings viewport's taper, and a
    /// control put there fades out exactly when it is reached for.
    @ViewBuilder
    private var pager: some View {
        if maxPage > 0 {
            HStack(spacing: 0) {
                StatsPagerButton(symbol: "chevron.left",
                                 help: L("stats.earlier"),
                                 enabled: page < maxPage) { turn(to: page + 1) }
                StatsPagerButton(symbol: "chevron.right",
                                 help: L("stats.later"),
                                 enabled: page > 0) { turn(to: page - 1) }
            }
            .frame(width: 44, alignment: .trailing)
        }
    }

    /// Turning the page moves every square under the pointer, so the ring and the
    /// header readout it feeds are cleared rather than left naming a day that has
    /// slid out from under the mouse.
    private func turn(to next: Int) {
        hovered = nil
        page = max(0, min(maxPage, next))
    }

}

/// One rhythm figure: a bare number over its label, no mark. The streaks are
/// counts of *days*, not of any one bucket, so there is no glyph that belongs to
/// them the way `messageCircle` belongs to a chat.
private struct StatsStreak: View {
    /// A count of days, which rolls up like the totals above it — or `nil` for
    /// the peak hour, which prints `fixed`. See `StatsFigure`.
    var value: Int? = nil
    var fixed: String = ""
    let label: String

    private var figure: StatsFigure { StatsFigure(value: value, fixed: fixed) }

    var body: some View {
        // No "days" unit beside the figure: the streak labels under it already end
        // in the word, and printing it twice is the reference screenshot's one
        // redundancy, not something to copy.
        VStack(alignment: .leading, spacing: 2) {
            figure
            // Four columns instead of three leaves a quarter of the card per
            // label; the longest of them ("Longest streak", "Hora punta") shrinks
            // rather than truncating, the same way the totals row's labels do.
            Text(label)
                .font(.sf(11))
                .foregroundStyle(Tokens.text3)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(figure.settled)")
    }
}

/// One of the grid's two page arrows. Same chevron the panel's back pill wears —
/// same glyph, same size, same hover brighten — without the capsule, which inside
/// an already-recessed card would read as a second surface.
private struct StatsPagerButton: View {
    let symbol: String
    let help: String
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.sf(10.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }

    private var tint: Color {
        guard enabled else { return Tokens.text4.opacity(0.4) }
        return hovering ? Tokens.text1 : Tokens.text3
    }
}

/// Which square the pointer is resting on: where to draw the ring, and the day it
/// stands for. Internal, because the readout that names it is drawn by the
/// settings header — a level above this pane.
struct StatsHoverDay: Equatable {
    let week: Int
    let row: Int
    let day: Date
}

/// The day grid — one column per week, one row per weekday, intensity by how much
/// went through the notch that day.
///
/// The window reaches back as far as the pane is wide — the grid always spans its
/// card, with the horizontal gutter taking up the remainder so the last column
/// lands flush with the right edge instead of leaving a ragged margin. It ends on
/// the current week at `page` 0, and `pageStep` weeks earlier for every press of
/// the card's ‹.
private struct StatsHeatmap: View {
    let digest: StatsDigest
    /// Windows back from the present, in `pageStep` steps.
    let page: Int

    /// Cell side and the *minimum* gutter between columns. Small enough that half
    /// a year fits the settings pane, large enough that a single day is still a
    /// target the pointer can rest on.
    private static let cell: CGFloat = 9
    private static let gap: CGFloat = 3
    private static let column: CGFloat = cell + gap
    private static let radius: CGFloat = 2.5
    /// Room for the weekday rail on the left.
    private static let railWidth: CGFloat = 14
    /// Roughly ten months — past that the columns are only meaningful on a
    /// window far wider than this panel will ever be.
    private static let maxWeeks = 44
    /// How far one press of ‹ / › travels: half a year. Deliberately shorter than
    /// the window itself (~33 weeks at this panel width), so consecutive pages
    /// overlap by a couple of months instead of butting up against each other —
    /// paging back and forth then reads as sliding one grid rather than cutting
    /// to an unrelated one. Fixed rather than "one windowful" so the card can
    /// work out how many pages exist without measuring the grid first.
    static let pageStep = 26

    private var gridHeight: CGFloat { Self.cell * 7 + Self.gap * 6 }
    /// The month rail plus the grid it labels.
    private var totalHeight: CGFloat { 11 + 3 + gridHeight }

    /// Where the ring goes and which day it names — owned by the card above, which
    /// is where the readout is drawn. Both halves travel together because the day
    /// is only knowable inside the geometry reader that resolved the window.
    @Binding var hovered: StatsHoverDay?

    private let calendar = Calendar.current

    /// How the columns fall in the width actually offered.
    private struct Grid {
        let weeks: Int
        /// Column pitch, centre to centre — the minimum gutter plus whatever the
        /// division left over, spread evenly.
        let stride: CGFloat
        var spacing: CGFloat { stride - StatsHeatmap.cell }
    }

    private func layout(for width: CGFloat) -> Grid {
        Grid(weeks: Self.weeks(for: width), stride: Self.stride(for: width))
    }

    private static func weeks(for width: CGFloat) -> Int {
        min(maxWeeks, max(1, Int((width + gap) / column)))
    }

    private static func stride(for width: CGFloat) -> CGFloat {
        let weeks = self.weeks(for: width)
        guard weeks > 1 else { return column }
        return (width - cell) / CGFloat(weeks - 1)
    }

    /// The same column count, worked out from the *card's* width — what the card
    /// needs to know how far its arrows may travel, before the grid has drawn
    /// itself. A card of unknown width (the first pass) is answered with one
    /// page step, the narrowest window the pane is designed for.
    static func weeks(inCard width: CGFloat) -> Int {
        guard width > 0 else { return pageStep }
        return weeks(for: width - railWidth - 5)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            weekdayRail
            GeometryReader { geo in
                let grid = layout(for: geo.size.width)
                let start = gridStart(weeks: grid.weeks)
                // Months on top, weekdays down the side — the arrangement a
                // contribution grid is read in. Underneath, the labels would be
                // the pane's last line, and the settings pane tapers its bottom
                // 32pt: text there fades out, cells barely notice.
                VStack(alignment: .leading, spacing: 3) {
                    monthRail(from: start, grid: grid)
                    cells(from: start, grid: grid)
                        // ONE tracking area for the whole grid, not one per day:
                        // the pointer's position maps straight onto a column and a
                        // row. Two hundred `onHover`s — or, worse, two hundred
                        // tooltips, each measuring itself with its own
                        // GeometryReaders — is the version of this that makes
                        // opening the pane cost something.
                        .onContinuousHover { phase in
                            let next: StatsHoverDay?
                            switch phase {
                            case .active(let point):
                                next = hover(at: point, grid: grid, start: start)
                            case .ended:
                                next = nil
                            }
                            // Only on a real change: `onContinuousHover` fires for
                            // every pixel the pointer moves, and a state write is an
                            // invalidation whether or not the value differs — which
                            // would rebuild every cell to land on the same drawing.
                            if next != hovered { hovered = next }
                        }
                        .overlay(alignment: .topLeading) { highlight(grid) }
                }
            }
            .frame(height: totalHeight)
        }
    }

    // MARK: Rails

    /// Every other weekday, the way a contribution grid labels its rows — seven
    /// labels at this cell size would be a wall of letters taller than the column
    /// they annotate.
    private var weekdayRail: some View {
        VStack(spacing: Self.gap) {
            ForEach(0..<7, id: \.self) { row in
                Group {
                    if row % 2 == 1 {
                        Text(weekdaySymbol(row))
                            .font(.sf(9))
                            .foregroundStyle(Tokens.text4)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: Self.railWidth, height: Self.cell, alignment: .leading)
            }
        }
    }

    /// Month names under the columns they start in, skipped when two would crowd.
    private func monthRail(from start: Date, grid: Grid) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(monthMarks(from: start, weeks: grid.weeks), id: \.column) { mark in
                Text(mark.title)
                    .font(.sf(9))
                    .foregroundStyle(Tokens.text4)
                    .fixedSize()
                    .offset(x: CGFloat(mark.column) * grid.stride)
            }
        }
        .frame(height: 11, alignment: .topLeading)
    }

    // MARK: Grid

    private func cells(from start: Date, grid: Grid) -> some View {
        let today = calendar.startOfDay(for: Date())
        return HStack(alignment: .top, spacing: grid.spacing) {
            ForEach(0..<grid.weeks, id: \.self) { week in
                VStack(spacing: Self.gap) {
                    ForEach(0..<7, id: \.self) { row in
                        let day = calendar.date(byAdding: .day,
                                                value: week * 7 + row,
                                                to: start) ?? start
                        // Days that haven't happened yet leave a hole rather than
                        // an empty well — an unlived day is not a quiet one.
                        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                            .fill(day > today ? Color.clear : Self.fill(digest.levels[day] ?? 0))
                            .frame(width: Self.cell, height: Self.cell)
                    }
                }
            }
        }
        .frame(height: gridHeight, alignment: .topLeading)
        .accessibilityElement()
        .accessibilityLabel(L("stats.activeDays"))
        .accessibilityValue(StatsFormat.count(digest.activeDays))
    }

    /// The pointer's ring, drawn once over the grid instead of per cell.
    @ViewBuilder
    private func highlight(_ grid: Grid) -> some View {
        if let hovered {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
                .frame(width: Self.cell, height: Self.cell)
                .offset(x: CGFloat(hovered.week) * grid.stride,
                        y: CGFloat(hovered.row) * (Self.cell + Self.gap))
                .allowsHitTesting(false)
        }
    }

    /// Which cell a point lands on — `nil` in the gutters, so sliding between two
    /// days clears the readout instead of snapping it to whichever is nearer, and
    /// `nil` past today, which has no day to report.
    private func hover(at point: CGPoint, grid: Grid, start: Date) -> StatsHoverDay? {
        let week = Int(point.x / grid.stride)
        let row = Int(point.y / (Self.cell + Self.gap))
        guard week >= 0, week < grid.weeks, row >= 0, row < 7 else { return nil }
        // The gutters belong to the square left of them, rather than reading as
        // "nothing": excluding them made the readout blink off and on again every
        // time the pointer crossed a 3pt gap, which is most of a sweep.
        guard let day = calendar.date(byAdding: .day, value: week * 7 + row, to: start),
              day <= calendar.startOfDay(for: Date()) else { return nil }
        return StatsHoverDay(week: week, row: row, day: day)
    }

    /// The ramp: an inert well for a day nothing happened on, then four steps that
    /// climb in brightness as much as in saturation — on dark glass a ramp built
    /// from opacity alone collapses into one blue smear at this cell size, which
    /// is a grid that has stopped saying anything.
    ///
    /// It stays inside the app's own palette — the accent it already uses for the
    /// one positive action — and ends on that colour at full strength rather than
    /// on a pastel: on this background a pale top step reads as *less*, which
    /// inverts the scale the legend just promised.
    private static func fill(_ level: Int) -> Color {
        switch level {
        case 1:  return Tokens.accent.opacity(0.20)
        case 2:  return Tokens.accent.opacity(0.42)
        case 3:  return Tokens.accent.opacity(0.70)
        case 4:  return Tokens.accent
        default: return Color.white.opacity(0.075)
        }
    }

    // MARK: Window arithmetic

    /// The first cell of the grid: the start of the week `weeks - 1` weeks before
    /// this one — plus however many pages back the reader has walked, so the
    /// newest column is the current week only while `page` is 0.
    private func gridStart(weeks: Int) -> Date {
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let intoWeek = (weekday - calendar.firstWeekday + 7) % 7
        let back = intoWeek + (weeks - 1) * 7 + page * Self.pageStep * 7
        return calendar.date(byAdding: .day, value: -back, to: today) ?? today
    }

    private func weekdaySymbol(_ row: Int) -> String {
        let symbols = StatsFormat.weekdaySymbols
        guard symbols.count == 7 else { return "" }
        return symbols[(calendar.firstWeekday - 1 + row) % 7]
    }

    private struct MonthMark { let column: Int; let title: String }

    /// One label per month the window covers, at the column that month starts in.
    /// A month whose turn falls late in the first column is skipped — a label
    /// there would sit under a column that mostly belongs to the month before it.
    private func monthMarks(from start: Date, weeks: Int) -> [MonthMark] {
        var marks: [MonthMark] = []
        var lastMonth = -1
        for week in 0..<weeks {
            guard let day = calendar.date(byAdding: .day, value: week * 7, to: start) else { continue }
            let month = calendar.component(.month, from: day)
            guard month != lastMonth else { continue }
            lastMonth = month
            let dayOfMonth = calendar.component(.day, from: day)
            let turnsHere = week == 0 ? dayOfMonth <= 14 : dayOfMonth <= 7
            guard turnsHere, marks.last.map({ week - $0.column >= 3 }) ?? true else { continue }
            // Paged back, a bare "Mar" doesn't say which March. Months outside
            // the current year carry their year; the present window, which is
            // where the pane opens, keeps the plain rail it always had.
            let thisYear = calendar.component(.year, from: Date())
            let title = calendar.component(.year, from: day) == thisYear
                ? StatsFormat.month(day)
                : StatsFormat.monthYear(day)
            marks.append(MonthMark(column: week, title: title))
        }
        return marks
    }
}

// MARK: - Formatting

/// The pane's formatters, built once per interface language.
///
/// They speak the *interface* language (Settings → General), not the system's, so
/// a Chinese UI on an English Mac still reads "8月" over its columns — and they
/// are cached, because these are read per weekday label, per month label and on
/// every hover: a `DateFormatter` allocated inside a view body is the classic way
/// to make a grid feel heavy for no reason.
@MainActor
enum StatsFormat {
    private struct Kit {
        let locale: Foundation.Locale
        let month: DateFormatter
        let monthYear: DateFormatter
        let hour: DateFormatter
        let day: DateFormatter
        let dayYear: DateFormatter
        let number: NumberFormatter
        let weekdays: [String]

        init(_ locale: Foundation.Locale) {
            self.locale = locale
            month = DateFormatter()
            month.locale = locale
            month.setLocalizedDateFormatFromTemplate("MMM")
            monthYear = DateFormatter()
            monthYear.locale = locale
            monthYear.setLocalizedDateFormatFromTemplate("MMMyy")
            hour = DateFormatter()
            hour.locale = locale
            // "j" is the locale's *own* hour field: 11 PM in English, 23時 in
            // Japanese, 23:00 where the clock runs to 24. Hard-coding "h a" would
            // put an English AM/PM on a Chinese pane.
            hour.setLocalizedDateFormatFromTemplate("j")
            day = DateFormatter()
            day.locale = locale
            day.setLocalizedDateFormatFromTemplate("MMMd")
            dayYear = DateFormatter()
            dayYear.locale = locale
            dayYear.setLocalizedDateFormatFromTemplate("MMMdyyyy")
            number = NumberFormatter()
            number.locale = locale
            number.numberStyle = .decimal
            let symbols = DateFormatter()
            symbols.locale = locale
            weekdays = symbols.veryShortWeekdaySymbols ?? []
        }
    }

    private static var cached: Kit?

    private static var kit: Kit {
        let locale = Localization.shared.language.resolved.foundation
        if let cached, cached.locale == locale { return cached }
        let fresh = Kit(locale)
        cached = fresh
        return fresh
    }

    /// Weekday initials in the calendar's own order — index 0 is Sunday, so the
    /// caller rotates by `firstWeekday`.
    static var weekdaySymbols: [String] { kit.weekdays }

    static func month(_ date: Date) -> String { kit.month.string(from: date) }
    /// "Mar 24" — the rail's label for a month outside the current year, which
    /// only the paged-back windows contain.
    static func monthYear(_ date: Date) -> String { kit.monthYear.string(from: date) }

    /// "11 PM" — an hour of the day on its own, with no date attached to it.
    static func hour(_ hour: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date())
        return date.map { kit.hour.string(from: $0) } ?? "\(hour)"
    }

    /// "Aug 6" this year, "Aug 6, 2024" in any other — the readout names a day
    /// the pointer can now reach years back, and a bare month/day there would be
    /// the one line on the pane that can mean two different squares.
    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        return calendar.component(.year, from: date) == calendar.component(.year, from: Date())
            ? kit.day.string(from: date)
            : kit.dayYear.string(from: date)
    }

    /// Plain grouped digits, every figure on the pane.
    ///
    /// The word count was compact for a while ("29K", the way the reference
    /// screenshot does it) — but compact notation rounds to one significant digit
    /// in Chinese, where 30,458 words comes back as "3万". A number that loses an
    /// order of magnitude of precision to save four characters is not worth the
    /// four characters; the tile has room for the real figure.
    static func count(_ value: Int) -> String {
        kit.number.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// A bucket total: full grouped digits for as long as the column can hold
    /// them, and the token tile's K/M/B spelling past that.
    ///
    /// The tile gives its figure about 67pt at `.statsFigure`, which six digits
    /// and a separator ("129,373") sit just inside. Seven is 80pt — the figure
    /// still fits, because `minimumScaleFactor` shrinks it to three quarters, but
    /// one column typeset smaller than the three beside it reads as a misprint on
    /// a row that goes out of its way elsewhere to keep them level. So a million
    /// hands over to `compact`, which keeps three significant digits: "1.23M"
    /// names the million and its first two decimals, at half the width.
    static func total(_ value: Int) -> String {
        abs(value) < 1_000_000 ? count(value) : compact(value)
    }

    /// The one figure on the pane that *is* compact: the token count.
    ///
    /// Everything else here counts things the user did, and those stay in full
    /// grouped digits (see `count`). Tokens are the one figure that reaches seven
    /// and eight digits — "12,847,336" is wider than a quarter of the card at any
    /// scale factor the tile will accept. Three significant digits with a K/M/B
    /// suffix, spelled here rather than taken from compact `NumberFormatter`,
    /// which rounds to one significant digit in Chinese (12.8M → "1300万"). The
    /// exact figure isn't lost — the tile's ⓘ prints it in full.
    static func compact(_ value: Int) -> String {
        func scaled(_ value: Double, _ suffix: String) -> String {
            // 12.8M and 128M, never 12.85M: the third significant digit of an
            // estimate is noise, and the tile is narrow.
            let digits = value < 10 ? 2 : (value < 100 ? 1 : 0)
            let text = String(format: "%.\(digits)f", value)
            return (kit.number.decimalSeparator.map { text.replacingOccurrences(of: ".", with: $0) } ?? text)
                + suffix
        }
        switch abs(value) {
        case 1_000_000_000...: return scaled(Double(value) / 1_000_000_000, "B")
        case 1_000_000...:     return scaled(Double(value) / 1_000_000, "M")
        case 10_000...:        return scaled(Double(value) / 1_000, "K")
        default:               return count(value)
        }
    }

    /// One day's rows, named by bucket: "24 chats · 2 notes · 1 agent run".
    ///
    /// Empty buckets are dropped rather than printed as zeros — a day is usually
    /// one bucket, and "0 notes · 0 agent runs" is three quarters of the line
    /// spent saying nothing happened. A day with nothing on it returns `nil`:
    /// the readout then shows the bare date, which already says it.
    static func dayBreakdown(_ day: StatsDigest.DayCounts) -> String? {
        var parts: [String] = []
        func add(_ value: Int, _ key: String) {
            guard value > 0 else { return }
            parts.append(L(value == 1 ? key + ".one" : key, count(value)))
        }
        add(day.chatMessages, "stats.dayTip.chat")
        add(day.captures, "stats.dayTip.notes")
        add(day.agentMessages, "stats.dayTip.agent")
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Snapshot (debug)

#if DEBUG
/// Renders the Stats pane straight to a PNG, at the exact width Settings gives
/// it, without opening the panel: `NOTCH_STATS_SNAPSHOT=<path>` on launch draws
/// the pane and quits.
///
/// It exists because the alternative is worse: screenshotting the real island
/// means waking the machine and driving the pointer through Settings, on the same
/// Mac somebody is working on. This is offscreen, headless and instant.
/// `NOTCH_STATS_SNAPSHOT_DEMO=1` swaps the real archive for a synthetic year so
/// the dense case can be looked at on a fresh install.
@MainActor
enum StatsSnapshot {
    static func renderIfRequested(history: [NotchModel.HistoryItem]) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NOTCH_STATS_SNAPSHOT"], !path.isEmpty else { return }
        let demo = env["NOTCH_STATS_SNAPSHOT_DEMO"] == "1"
        let digest = demo ? demoDigest() : StatsDigest.make(from: history)
        // The token figure is a meter reading, not a fold of the archive, so the
        // demo has to supply its own — a fresh install's meter is at zero, which
        // is exactly the case the demo exists to get past.
        let tokens = demo
            ? TokenMeter.Reading(total: 12_847_336,
                                 since: Calendar.current.date(byAdding: .day, value: -96, to: Date()),
                                 sinceVersion: "0.5.9")
            : TokenMeter.shared.reading

        // The pane's real width in the panel: the settings body's own insets, the
        // category column, and the divider taken off `openWidthSettings`.
        let width = Tokens.openWidthSettings - 16 - 104 - 12 - 0.5 - 14
        // NOTCH_STATS_SNAPSHOT_FIT=1 clips to the settings pane's real viewport
        // (`NotchBody.immersiveListHeight` less the back-pill chrome, plus the
        // pane's top runway) — the way to see what is above the fold on open,
        // rather than the pane's full unrolled height.
        let fit = env["NOTCH_STATS_SNAPSHOT_FIT"] == "1"
        let viewport: CGFloat = NotchBody.immersiveListHeight - (12 + 26 + 4 + 12)
        let content = StatsPane(digest: digest, tokens: tokens, hovered: .constant(nil))
            .frame(width: width, alignment: .topLeading)
            .padding(.top, fit ? 14 : 16)
            .padding(.bottom, fit ? 0 : 16)
            .frame(height: fit ? viewport : nil, alignment: .top)
            .clipped()
            .background(Color(red: 0.055, green: 0.055, blue: 0.06))
            .environment(\.colorScheme, .dark)
            // One body pass, no `onAppear`: the tiles print their settled figures
            // rather than the zero the roll starts from.
            .environment(\.statsFigureRoll, false)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        if let image = renderer.nsImage,
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }

    /// Nine months of plausible activity — enough to exercise a full grid, the
    /// four intensity levels, and six-figure numbers.
    ///
    /// `NOTCH_STATS_SNAPSHOT_DEMO_DAYS` stretches that history (e.g. `3650` for a
    /// decade) and `…_DEMO_BUSY` multiplies the daily ceiling, which is how the
    /// long-archive cases get looked at: the grid always shows the most recent
    /// weeks, but the figures under it keep growing.
    private static func demoDigest() -> StatsDigest {
        var items: [NotchModel.HistoryItem] = []
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var generator = SystemRandomNumberGenerator()
        let env = ProcessInfo.processInfo.environment
        let span = env["NOTCH_STATS_SNAPSHOT_DEMO_DAYS"].flatMap(Int.init) ?? 274
        let busy = env["NOTCH_STATS_SNAPSHOT_DEMO_BUSY"].flatMap(Int.init) ?? 1
        for back in 0..<span {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            // Weekends quieter, and a fortnight off in the middle, so the grid has
            // texture instead of uniform noise.
            let weekend = calendar.isDateInWeekend(day)
            let onHoliday = (120...134).contains(back)
            let ceiling = onHoliday ? 0 : (weekend ? 4 : 14) * busy
            guard ceiling > 0 else { continue }
            let count = Int.random(in: 0...ceiling, using: &generator)
            for row in 0..<count {
                let stamp = day.addingTimeInterval(TimeInterval(9 * 3600 + row * 900))
                let source: NotchModel.HistoryItem.Source =
                    row % 7 == 3 ? .note : (row % 11 == 5 ? .reminder : (row % 13 == 7 ? .agent : .ask))
                var item = NotchModel.HistoryItem(
                    q: "Demo", a: "Demo", t: stamp,
                    turns: [
                        .init(role: "user", text: "Demo"),
                        .init(role: "assistant",
                              text: String(repeating: "word ", count: Int.random(in: 40...260, using: &generator))),
                    ],
                    source: source)
                item.title = "Demo"
                items.append(item)
            }
        }
        return StatsDigest.make(from: items)
    }
}
#endif

extension Localization.Locale {
    /// The Foundation locale this interface language formats dates and numbers in.
    var foundation: Foundation.Locale {
        switch self {
        case .en:     return Foundation.Locale(identifier: "en_US")
        case .zhHans: return Foundation.Locale(identifier: "zh_Hans")
        case .zhHant: return Foundation.Locale(identifier: "zh_Hant")
        case .ja:     return Foundation.Locale(identifier: "ja_JP")
        case .ko:     return Foundation.Locale(identifier: "ko_KR")
        case .fr:     return Foundation.Locale(identifier: "fr_FR")
        case .es:     return Foundation.Locale(identifier: "es_ES")
        }
    }
}
