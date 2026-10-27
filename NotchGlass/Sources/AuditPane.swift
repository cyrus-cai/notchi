import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The chart and its card use the app's chart register (`VisualBlocks`' `Viz`):
/// SF with tabular figures, so durations and token counts line up as columns
/// without setting the whole card in a terminal face.
private enum AuditType {
    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .sf(size, weight: weight).monospacedDigit()
    }
}

/// Settings → **Stats**'s request chart: what the app asked for, drawn as the
/// processing flow it is — the wait before the first token, the generation after
/// it, and the tools a turn ran — on one shared clock, newest at the right.
///
/// It draws from `RequestAudit`, which keeps metadata only, so there is nothing
/// here to redact and nothing to send. The bar under the pointer is detailed in
/// the card's own footer; with nothing under it the newest request is shown, so
/// the card always names a concrete request instead of staying a picture.
struct AuditPane: View {
    /// Re-baselines the clipboard after the sent-data copy button writes to it.
    private let onInAppCopy: (() -> Void)?

    /// Newest first. Held here rather than by the settings view, so a request
    /// finishing while the pane is open redraws the chart and nothing else.
    @State private var entries: [RequestAudit.Entry] = []
    /// A fixed log instead of the live one, for the offscreen snapshot
    /// (`ImageRenderer` runs no `onAppear`, so it is laid out up front).
    private let preset: [RequestAudit.Entry]?

    init(onInAppCopy: (() -> Void)? = nil, preset: [RequestAudit.Entry]? = nil) {
        self.onInAppCopy = onInAppCopy
        self.preset = preset
        if let preset { _entries = State(initialValue: preset) }
    }

    var body: some View {
        // Empty draws nothing: the chart rides under Stats, and a session with
        // no requests leaves the pane as the archive's own sheet.
        VStack(spacing: 0) {
            if !entries.isEmpty {
                AuditFlow(entries: entries, onInAppCopy: onInAppCopy, laidOut: preset != nil)
            }
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: RequestAudit.didChange)) { _ in
            reload()
        }
    }

    private func reload() {
        guard preset == nil else { return }
        entries = Array(RequestAudit.shared.recent.reversed())
    }
}

// MARK: - Flow

/// The chart itself: four lanes over one day.
///
/// `Input` is the wait between sending and the first token — prefill, queueing,
/// connect. `Customize Models` is what follows, up to the last token, on a key
/// or CLI the user set up. `Notchi Models` is Notchi's own models, Jev included. `Tools` is the tool
/// runs a turn made, in their own lane so they read as work happening beside the
/// model calls, not as more waiting.
private struct AuditFlow: View {
    /// Newest first.
    let entries: [RequestAudit.Entry]
    let onInAppCopy: (() -> Void)?
    /// The bar under the pointer. Kept here, not in the settings view: every
    /// pointer move over the lanes changes it, and only the chart and its card
    /// depend on it.
    @State private var hovered: RequestAudit.Entry?
    /// Everything the lanes draw, rebuilt only when the records, the page or
    /// the lanes' width change — never on a hover or a scroll step.
    @State private var chart = Chart.empty

    init(entries: [RequestAudit.Entry], onInAppCopy: (() -> Void)?, laidOut: Bool = false) {
        self.entries = entries
        self.onInAppCopy = onInAppCopy
        if laidOut { _chart = State(initialValue: Chart(entries: entries, page: 0, viewport: 0)) }
    }

    /// Points per second on the compressed axis. Fixed, so a bar of the same
    /// width is the same duration on every day; a day longer than the pane
    /// scrolls sideways instead of being squeezed to fit.
    fileprivate static let pointsPerSecond: CGFloat = 2
    private static let laneHeight: CGFloat = 14
    private static let laneGap: CGFloat = 5
    /// Idle gaps are drawn no wider than this. Without the cap, a chart of a
    /// working day is a few ticks at either end with an hour of nothing between
    /// them — and the gap worth seeing is the one between two requests in the
    /// same burst.
    fileprivate static let maxGap: TimeInterval = 10

    /// Which day is on screen: 0 is the newest day with records, and each step
    /// back is the next earlier day the log holds.
    @State private var page = 0
    /// The lanes' visible width, and how far they are scrolled back from the
    /// newest end. Measured from that end so a new request arriving while the
    /// day is open doesn't move what is on screen, and 0 keeps following it.
    @State private var viewport: CGFloat = 0
    @State private var back: CGFloat = 0
    @State private var hoveringLanes = false
    /// The lane labels' width, so the times under the lanes start where they do.
    @State private var railWidth: CGFloat = 0

    private var contentWidth: CGFloat {
        max(viewport, CGFloat(axisLength) * Self.pointsPerSecond)
    }

    /// Where the visible stretch starts, in content points.
    private var visibleStart: CGFloat {
        max(0, contentWidth - viewport - back)
    }

    private static let fadeWidth: CGFloat = 28

    private func edgeFade(leading: Bool, trailing: Bool) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(leading ? 0 : 1), .black],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.fadeWidth)
            Color.black
            LinearGradient(colors: [.black, .black.opacity(trailing ? 0 : 1)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.fadeWidth)
        }
        .animation(.easeOut(duration: 0.15), value: leading)
        .animation(.easeOut(duration: 0.15), value: trailing)
    }

    private func scroll(by delta: CGFloat) {
        back = min(max(0, back + delta), max(0, contentWidth - viewport))
    }

    private var pageCount: Int { max(1, chart.dayCount) }
    private var items: [RequestAudit.Entry] { chart.items }
    private var placements: [Placement] { chart.placements }
    private var axisLength: TimeInterval { chart.axisLength }

    /// What `chart` was built from. The records are compared by count and
    /// newest id: the log only ever appends at the new end and prunes the old.
    private struct ChartKey: Equatable {
        let count: Int
        let newest: UUID?
        let page: Int
        let viewport: CGFloat
    }

    private var chartKey: ChartKey {
        ChartKey(count: entries.count, newest: entries.first?.id, page: page, viewport: viewport)
    }

    /// Paging back clears the selection: the bar it named may not be on the page
    /// that just arrived, and a detail card describing something off-screen is
    /// worse than showing the page's newest.
    private func turn(to next: Int) {
        hovered = nil
        back = 0
        page = max(0, min(pageCount - 1, next))
    }

    /// The first record reaching into the visible stretch, and the last one
    /// starting inside it: the two ends of what is on screen.
    private var visibleOldest: Date {
        placements.first { CGFloat($0.start + $0.seconds) * Self.pointsPerSecond >= visibleStart }?.entry.at
            ?? items.first?.at ?? Date()
    }

    private var visibleNewest: Date {
        placements.last { CGFloat($0.start) * Self.pointsPerSecond <= visibleStart + viewport }?.entry.at
            ?? items.last?.at ?? Date()
    }

    /// What the footer details: the bar under the pointer, else the newest one.
    private var current: RequestAudit.Entry? { hovered ?? items.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: Self.laneGap) {
                        laneLabel(L("audit.lane.input"))
                        laneLabel(L("audit.lane.model"))
                        laneLabel(L("audit.lane.notchi"))
                        laneLabel(L("audit.lane.tools"))
                    }
                    .fixedSize()
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { railWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, next in railWidth = next }
                    })

                    GeometryReader { geo in
                        let width = max(geo.size.width,
                                        CGFloat(axisLength) * Self.pointsPerSecond)
                        let start = max(0, width - geo.size.width - back)
                        VStack(alignment: .leading, spacing: Self.laneGap) {
                            ForEach(0..<4, id: \.self) { index in
                                lane(chart.lanes[index], start: start, viewport: geo.size.width)
                            }
                        }
                        .frame(width: geo.size.width, alignment: .leading)
                        // An edge with more of the day past it fades out, which
                        // is the cue that the lanes scroll sideways.
                        .mask(edgeFade(leading: start > 0.5, trailing: back > 0.5))
                        .onAppear { viewport = geo.size.width }
                        .onChange(of: geo.size.width) { _, next in viewport = next }
                    }
                    // A two-finger sideways swipe over the lanes moves along the
                    // day, and is consumed here so nothing around the card moves.
                    .background(AuditScrollMonitor(active: hoveringLanes) { scroll(by: $0) })
                    .onHover { hoveringLanes = $0 }
                .frame(height: Self.laneHeight * 4 + Self.laneGap * 3)
            }
            axis
            if let current {
                AuditDetail(entry: current, onInAppCopy: onInAppCopy)
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: chartKey, initial: true) { _, key in
            chart = Chart(entries: entries, page: key.page, viewport: key.viewport)
            if page >= pageCount { page = max(0, pageCount - 1) }
        }
    }

    // MARK: Lanes

    private func laneLabel(_ text: String) -> some View {
        Text(text)
            .font(AuditType.text(Tokens.TypeSize.caption))
            .foregroundStyle(Tokens.text4)
            .lineLimit(1)
            .frame(height: Self.laneHeight)
    }

    /// One lane, drawn as one `Canvas` over the visible stretch only: a busy
    /// day is hundreds of bars, and a view per bar meant re-diffing all of them
    /// on every hover and scroll step.
    ///
    /// The whole lane is the hover surface, not the bars: a 40 ms request is a
    /// three-point sliver, and asking the pointer to land on it would make
    /// "hover a request for details" a game of skill. The bar nearest the
    /// pointer's x wins, so the lane answers wherever it is touched.
    private func lane(_ segments: [Segment], start: CGFloat, viewport: CGFloat) -> some View {
        let selected = hovered?.id
        return Canvas { context, size in
            // A faint track, so an empty lane still reads as a lane.
            let track = CGRect(x: -start, y: 0, width: max(size.width + start, contentWidth),
                               height: size.height)
            context.fill(Path(roundedRect: track, cornerRadius: 3), with: .color(.white.opacity(0.05)))
            // With one bar selected the rest step back, so the card below and
            // the bar it describes are unmistakably the same request.
            for segment in segments where segment.x + segment.width >= start
                                       && segment.x <= start + size.width {
                let rect = CGRect(x: segment.x - start, y: 0, width: segment.width, height: size.height)
                let path = Path(roundedRect: rect, cornerRadius: 3)
                let isSelected = segment.entry.id == selected
                let ink = isSelected ? 1 : (selected == nil ? 0.78 : 0.32)
                context.fill(path, with: .color(segment.color.opacity(ink)))
                if isSelected {
                    context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2.5),
                                   with: .color(.white.opacity(0.85)), lineWidth: 1)
                }
            }
        }
        .frame(width: viewport, height: Self.laneHeight)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard case .active(let point) = phase,
                  let segment = nearest(in: segments, to: point.x + start),
                  hovered?.id != segment.entry.id else { return }
            hovered = segment.entry
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(segments.last.map { barLabel($0.entry) } ?? "")
    }

    /// The bar closest to the pointer on x. Distance is measured to the bar's
    /// span, so a pointer over the bar itself always wins over one beside it;
    /// past `slop` nothing is chosen and the selection stays where it was.
    private func nearest(in segments: [Segment], to x: CGFloat) -> Segment? {
        var best: Segment?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for segment in segments {
            let distance = max(0, max(segment.x - x, x - (segment.x + segment.width)))
            if distance < bestDistance {
                bestDistance = distance
                best = segment
            }
        }
        return bestDistance <= 14 ? best : nil
    }

    /// The times at the two visible ends of the lanes, and the pager between days.
    private var axis: some View {
        HStack(spacing: 6) {
            // Arrows only once the log actually has more than one page: on a
            // young log they would sit there greyed out over nothing to see.
            if pageCount > 1 {
                pagerButton("‹", enabled: page < pageCount - 1) { turn(to: page + 1) }
            }
            Text(stamp(visibleOldest))
            Spacer(minLength: 8)
            Text(stamp(visibleNewest))
            if pageCount > 1 {
                pagerButton("›", enabled: page > 0) { turn(to: page - 1) }
            }
        }
        .font(AuditType.text(Tokens.TypeSize.caption))
        .foregroundStyle(Tokens.text4)
        .lineLimit(1)
        .padding(.leading, railWidth + 8)
    }

    /// The pager's one arrow, drawn as text, the same as the activity grid's
    /// (`StatsActivityGrid.arrow`).
    private func pagerButton(_ glyph: String, enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(enabled ? Tokens.text3 : Tokens.text4.opacity(0.35))
                .frame(width: 12, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).exemptsDoubleClickPin()
        .disabled(!enabled)
    }

    /// A short stamp for the rail. Built from two fields rather than one locale
    /// format so the glue word ("at") the English style inserts can't cost the
    /// row the width the note needs.
    private func stamp(_ date: Date) -> String {
        guard !Calendar.current.isDateInToday(date) else {
            return date.formatted(.dateTime.hour().minute())
        }
        let day = date.formatted(.dateTime.month(.abbreviated).day())
        let time = date.formatted(.dateTime.hour().minute())
        return "\(day) \(time)"
    }

    // MARK: Drawing model

    /// A record on the compressed axis: where it starts and how long it runs,
    /// both in the seconds the lanes are drawn in.
    private struct Placement {
        let entry: RequestAudit.Entry
        let start: TimeInterval
        let seconds: TimeInterval
    }

    private struct Segment {
        let entry: RequestAudit.Entry
        let x: CGFloat
        let width: CGFloat
        let color: Color
    }

    /// The selected day laid out once: its records, their placements on the
    /// compressed axis, and the four lanes' bars in content points.
    private struct Chart {
        var dayCount = 0
        var items: [RequestAudit.Entry] = []
        var placements: [Placement] = []
        var axisLength: TimeInterval = 1
        /// Input, Customize Models, Notchi Models, Tools.
        var lanes: [[Segment]] = [[], [], [], []]

        static let empty = Chart()

        private init() {}

        init(entries: [RequestAudit.Entry], page: Int, viewport: CGFloat) {
            // One pass over the log: the days it holds, newest first, and the
            // selected day's records. `startOfDay` is the costly call, so a run
            // of records on the same day reuses the last answer.
            let calendar = Calendar.current
            var dayIndex = -1
            var dayEnd = Date.distantFuture
            var dayStart = Date.distantFuture
            var picked: [RequestAudit.Entry] = []
            for entry in entries {
                if entry.at < dayStart || entry.at >= dayEnd {
                    dayStart = calendar.startOfDay(for: entry.at)
                    dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
                    dayIndex += 1
                }
                if dayIndex == page { picked.append(entry) }
            }
            dayCount = dayIndex + 1
            items = picked.reversed()

            // Walk the records oldest first, charging each idle gap at most
            // `maxGap`. The absolute clock is gone after this — only the two
            // ends are printed.
            var cursor: TimeInterval = 0
            var previousEnd: TimeInterval = 0
            for (index, entry) in items.enumerated() {
                let real = entry.at.timeIntervalSinceReferenceDate
                if index > 0 { cursor += min(max(real - previousEnd, 0), AuditFlow.maxGap) }
                let seconds = max(Double(entry.milliseconds) / 1000, 0.001)
                placements.append(Placement(entry: entry, start: cursor, seconds: seconds))
                cursor += seconds
                previousEnd = real + seconds
            }
            axisLength = max(placements.last.map { $0.start + $0.seconds } ?? 1, 0.001)

            let width = max(viewport, CGFloat(axisLength) * AuditFlow.pointsPerSecond)
            for placement in placements {
                let entry = placement.entry
                let ink = AuditFlow.color(for: entry)
                func bar(_ from: TimeInterval, _ length: TimeInterval) -> Segment {
                    let lo = min(max(0, CGFloat(from) * AuditFlow.pointsPerSecond), width)
                    let hi = min(max(0, CGFloat(from + length) * AuditFlow.pointsPerSecond), width)
                    // A 40 ms request still has to be visible: three points is the floor.
                    let barWidth = min(width, max(3, hi - lo))
                    return Segment(entry: entry, x: min(lo, max(0, width - barWidth)),
                                   width: barWidth, color: ink)
                }
                switch entry.transport {
                case .tool:
                    // Tool runs sit in their own lane, one bar per run.
                    lanes[3].append(bar(placement.start, placement.seconds))
                case .jev:
                    // One round trip, no stream to wait on: the Notchi lane alone.
                    lanes[2].append(bar(placement.start, placement.seconds))
                case .http, .cli:
                    // Send → first token in Input; first token → end in the lane
                    // of whose model answered. No token means it never reached
                    // generation.
                    let wait = min(Double(entry.firstToken ?? entry.milliseconds) / 1000,
                                   placement.seconds)
                    lanes[0].append(bar(placement.start, wait))
                    if let ttft = entry.firstToken {
                        let length = placement.seconds - Double(ttft) / 1000
                        if length > 0 {
                            lanes[AuditFlow.isNotchi(entry) ? 2 : 1]
                                .append(bar(placement.start + Double(ttft) / 1000, length))
                        }
                    }
                }
            }
        }
    }

    /// Whether the request went to Notchi's own models (Notchi Balance, Auto,
    /// Jev) rather than to a key or CLI the user set up.
    fileprivate static func isNotchi(_ entry: RequestAudit.Entry) -> Bool {
        entry.transport == .jev || entry.provider == Provider.nono.displayName
    }

    // MARK: Color

    /// One ink for every bar. The chart encodes time and duration, not vendor —
    /// a rainbow of hues makes the reader hunt for a legend that doesn't exist,
    /// and every provider's bar would mean the same thing anyway. The one color
    /// that carries information is the failure red; a stopped request fades out.
    fileprivate static func color(for entry: RequestAudit.Entry) -> Color {
        switch entry.outcome {
        case .failed:    return Tokens.danger
        case .cancelled: return Tokens.text4
        case .ok:        return Tokens.text2
        }
    }

    private func barLabel(_ entry: RequestAudit.Entry) -> String {
        entry.transport == .tool
            ? "\(entry.model), \(AuditDetail.duration(entry.milliseconds))"
            : "\(entry.provider), \(AuditDetail.duration(entry.milliseconds))"
    }
}

// MARK: - Detail

/// One record's sent copy, prepared off the main thread. `shown` caps each line
/// and the line count: a chat body's system prompt is a single JSON string of
/// many thousands of characters, and laying that out in the card is what made
/// it slow. Copy takes `full`.
private struct AuditPayload {
    let id: UUID
    let full: String
    let shown: String

    private static let lineLimit = 1_000
    private static let maxLines = 400

    init(id: UUID, full: String) {
        self.id = id
        self.full = full
        var lines: [Substring] = []
        for line in full.split(separator: "\n", omittingEmptySubsequences: false) {
            if lines.count == Self.maxLines { lines.append("…"); break }
            lines.append(line.count > Self.lineLimit ? line.prefix(Self.lineLimit) + "…" : line)
        }
        shown = lines.joined(separator: "\n")
    }
}

/// The card's footer, laid out like the harness's request panel: a **Summary** of
/// what was asked and what came back, and the **Request timing** that says where
/// the wait went. Two columns rather than two stacked sections because the pane
/// is a settings column, not a window — the whole card has to stay on screen.
///
/// Details ends with the copy of what went out (`RequestAudit.payload(for:)`),
/// in the answer's code block so it copies the same way. Answers are never
/// kept, so there is no response half to show.
private struct AuditDetail: View {
    let entry: RequestAudit.Entry
    let onInAppCopy: (() -> Void)?

    /// Whether the secondary half is unfolded. Closed by default: the facts that
    /// matter for every request are on screen, the rest is one click away instead
    /// of competing with them.
    @State private var detailed = false
    @State private var hoveringDetails = false
    /// The payload of `entry`, read from disk while Details is open: the
    /// whole of it for Copy, and the capped copy the block shows.
    @State private var payload: AuditPayload?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // One two-column grid for everything, actions included: the same
            // size, the same face, one label column, one value column. The
            // request's own name is the first row's value, so it lines up with
            // the rest instead of sitting above them in a style of its own.
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                field(kindLabel, nameText, sizesColumn: true)
                if let callText {
                    field(callLabel, callText, lines: 2)
                }
                if let surfaceText {
                    field(L("audit.from"), surfaceText)
                }
                field(L("audit.status"), statusText, tint: statusTint)
                field(L("audit.duration"), Self.duration(entry.milliseconds))
                if entry.transport != .tool, entry.tokens > 0 {
                    field(L("audit.tokens"), tokensText)
                }
                if entry.transport != .tool {
                    field(L("audit.source"), sourceText)
                }
                if detailed {
                    field(L("audit.started"), startText)
                    if let ttft = entry.firstToken {
                        field(L("audit.ttfb"), Self.duration(ttft))
                        field(L("audit.generation"), Self.duration(max(entry.milliseconds - ttft, 0)))
                    }
                    if let rate = throughputText {
                        field(L("audit.throughput"), rate)
                    }
                    if entry.transport != .tool, !entry.model.isEmpty, entry.model != nameText {
                        field(L("audit.modelID"), entry.model)
                    }
                    if entry.attempts > 1 {
                        field(L("audit.attempts"), "\(entry.attempts)")
                    }
                    if let error = entry.error {
                        field(L("audit.error"), error, tint: Tokens.danger, lines: 3)
                    }
                }
            }
            .transition(.opacity)

            Button {
                withAnimation(.easeOut(duration: 0.12)) { detailed.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.sf(Tokens.TypeSize.badge, weight: .semibold))
                        .rotationEffect(.degrees(detailed ? 90 : 0))
                    Text(L("audit.details"))
                        .font(AuditType.text(Tokens.TypeSize.meta))
                }
                .foregroundStyle(hoveringDetails ? Tokens.text2 : Tokens.text4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).exemptsDoubleClickPin()
            .onHover { hoveringDetails = $0 }
            .accessibilityLabel(L("audit.details"))

            if detailed, let payload, payload.id == entry.id {
                CodeBlockView(text: payload.shown, language: "json",
                              baseFont: Tokens.TypeSize.meta + 0.5,
                              color: Tokens.text2,
                              onInAppCopy: onInAppCopy,
                              copyText: payload.full)
                    .transition(.opacity)
            }
        }
        // The card follows the selected bar, so the copy follows it too. Read
        // off the main thread, and only once the pointer settles: sweeping
        // across a row of bars with Details open would otherwise read and lay
        // out every payload it passes.
        .task(id: detailed ? entry.id : nil) {
            guard detailed, entry.hasPayload == true, payload?.id != entry.id else { return }
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            let id = entry.id
            let loaded = await Task.detached(priority: .userInitiated) {
                RequestAudit.shared.payload(for: id).map { AuditPayload(id: id, full: $0) }
            }.value
            guard !Task.isCancelled else { return }
            payload = loaded
        }
    }

    /// What the call asked for — the search query, the page, the command, the
    /// file — when the record kept it. Only a tool run has one: a request's own
    /// content is in its payload, and the payload is not parsed for the card.
    private var callText: String? {
        guard entry.transport == .tool else { return nil }
        return entry.call
    }

    /// The label for that argument, in the tool's own name for it: a search is a
    /// query, a page is a URL, a shell run is a command.
    private var callLabel: String {
        switch entry.callName {
        case "query":             return L("audit.call.query")
        case "url":               return L("audit.call.url")
        case "command":           return L("audit.call.command")
        case "file_path", "path": return L("audit.call.path")
        case "pattern":           return L("audit.call.pattern")
        default:                  return L("audit.call.input")
        }
    }

    /// The call site in words. A surface this build has no name for is shown
    /// as the identifier itself rather than hidden.
    private var surfaceText: String? {
        guard let surface = entry.surface, !surface.isEmpty else { return nil }
        let key = "audit.surface.\(surface)"
        let name = L(key)
        return name == key ? surface : name
    }

    /// What the selected bar is: a tool run, or a request (to a model or to Jev).
    /// It is the first row's label, in the same register as "Status".
    private var kindLabel: String {
        entry.transport == .tool ? L("audit.detail.tool") : L("audit.detail.request")
    }

    private var nameText: String {
        switch entry.transport {
        case .tool: return entry.model
        case .jev:  return entry.provider
        default:    return modelText
        }
    }

    private static let labelKeys = [
        "audit.detail.request", "audit.detail.tool", "audit.status", "audit.duration",
        "audit.tokens", "audit.source", "audit.started", "audit.ttfb",
        "audit.generation", "audit.throughput", "audit.from", "audit.modelID",
        "audit.attempts", "audit.error", "audit.call.query", "audit.call.url",
        "audit.call.command", "audit.call.path", "audit.call.pattern", "audit.call.input",
    ]

    private func field(_ label: String, _ value: String, tint: Color = Tokens.text1,
                       weight: Font.Weight = .light, lines: Int = 1,
                       sizesColumn: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            // Every label the card can show sits hidden under the first row's,
            // so the label column is as wide collapsed as expanded and the
            // values don't shift when Details opens. One row is enough: a grid
            // column is as wide as its widest cell.
            ZStack(alignment: .leading) {
                if sizesColumn {
                    ForEach(Self.labelKeys, id: \.self) { key in
                        Text(L(key)).hidden()
                    }
                }
                Text(label)
            }
            .font(AuditType.text(Tokens.TypeSize.meta))
            .foregroundStyle(Tokens.text4)
            .lineLimit(1)
            Text(value)
                .font(AuditType.text(Tokens.TypeSize.meta + 0.5, weight: weight))
                .foregroundStyle(tint)
                .lineLimit(lines)
                .truncationMode(lines == 1 ? .middle : .tail)
        }
    }

    /// Where it went: the endpoint for an HTTP request, the binary for a CLI run,
    /// the tool's own name for a tool run.
    private var sourceText: String {
        if entry.transport == .tool { return entry.model }
        if let url = entry.url, let parts = URLComponents(string: url), let host = parts.host {
            return host + parts.path
        }
        return entry.host.isEmpty ? entry.provider : entry.host
    }

    /// The model's name as the app itself shows it. Notchi's gateway ids are
    /// routing ids — "auto-us" is what the app sends, never what it calls the
    /// tier — so they are mapped to their display name here. Every other
    /// provider's id is already the name on the wire and is shown verbatim; the
    /// CSV export keeps the raw id either way.
    private var modelText: String {
        guard !entry.model.isEmpty else { return L("audit.defaultModel") }
        if entry.provider == Provider.nono.displayName {
            return ModelRatings.prettyName(for: entry.model, provider: .nono)
        }
        return entry.model
    }

    private var startText: String {
        entry.at.formatted(.dateTime.year().month(.abbreviated).day()
            .hour().minute().second().timeZone(.localizedGMT(.short)))
    }

    private var tokensText: String {
        L("audit.tokensValue",
          StatsFormat.compact(entry.inputTokens),
          StatsFormat.compact(entry.outputTokens))
    }

    /// Output tokens over the generation phase — what the reference calls
    /// throughput. Shown only when there is a generation phase to divide by.
    private var throughputText: String? {
        guard let ttft = entry.firstToken, entry.outputTokens > 0 else { return nil }
        let generation = Double(entry.milliseconds - ttft) / 1000
        guard generation > 0.05 else { return nil }
        return L("audit.throughputValue",
                 String(format: "%.1f", Double(entry.outputTokens) / generation))
    }

    /// The HTTP status when the request got one, with the verdict word beside it;
    /// without a status — a timeout, a refused connection, a CLI run — just the
    /// word.
    private var statusText: String {
        let word: String
        switch entry.outcome {
        case .ok:        word = L("audit.status.completed")
        case .failed:    word = L("audit.status.failed")
        case .cancelled: word = L("audit.status.stopped")
        }
        guard let code = entry.status else { return word }
        return "\(code) \(word)"
    }

    private var statusTint: Color {
        entry.outcome == .failed ? Tokens.danger : Tokens.text2
    }

    /// "820 ms" under a second, "2.44 s" under ten, one decimal past that — the
    /// precision a wait is actually judged with.
    static func duration(_ milliseconds: Int) -> String {
        if milliseconds < 1000 { return "\(milliseconds) ms" }
        let seconds = Double(milliseconds) / 1000
        return String(format: seconds < 10 ? "%.2f s" : "%.1f s", seconds)
    }
}

/// Horizontal scroll-wheel and trackpad events over the lanes, read from AppKit
/// because the lanes are not a `ScrollView`: the visible stretch is computed
/// from `back` directly, so the times printed under it are always right.
private struct AuditScrollMonitor: NSViewRepresentable {
    var active: Bool
    var onDelta: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.active = active
        context.coordinator.onDelta = onDelta
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.active = active
        context.coordinator.onDelta = onDelta
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        var active = false
        var onDelta: ((CGFloat) -> Void)?
        private var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.active else { return event }
                let dx = event.scrollingDeltaX
                guard dx != 0, abs(dx) >= abs(event.scrollingDeltaY) else { return event }
                self.onDelta?(event.hasPreciseScrollingDeltas ? dx : dx * 10)
                return nil
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
