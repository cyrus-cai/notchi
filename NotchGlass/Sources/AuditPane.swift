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
    /// Newest first, as the pane holds them. Empty draws nothing: the chart
    /// rides under Stats, and a session with no requests leaves the pane as the
    /// archive's own sheet.
    let entries: [RequestAudit.Entry]
    /// The bar under the pointer. Owned by the settings view: the header also
    /// names it, beside the Stats hover readout.
    @Binding var hovered: RequestAudit.Entry?

    var body: some View {
        if !entries.isEmpty {
            AuditFlow(entries: entries, hovered: $hovered)
        }
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
    @Binding var hovered: RequestAudit.Entry?

    /// Points per second on the compressed axis. Fixed, so a bar of the same
    /// width is the same duration on every day; a day longer than the pane
    /// scrolls sideways instead of being squeezed to fit.
    private static let pointsPerSecond: CGFloat = 2
    private static let laneHeight: CGFloat = 14
    private static let laneGap: CGFloat = 5
    /// Idle gaps are drawn no wider than this. Without the cap, a chart of a
    /// working day is a few ticks at either end with an hour of nothing between
    /// them — and the gap worth seeing is the one between two requests in the
    /// same burst.
    private static let maxGap: TimeInterval = 10

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

    /// The days that have records, newest first (the entries already are).
    private var days: [Date] {
        var seen = Set<Date>()
        var out: [Date] = []
        for entry in entries {
            let day = Calendar.current.startOfDay(for: entry.at)
            if seen.insert(day).inserted { out.append(day) }
        }
        return out
    }

    private var pageCount: Int { max(1, days.count) }

    /// The selected day's records, oldest first.
    private var items: [RequestAudit.Entry] {
        let days = self.days
        guard page < days.count else { return [] }
        return entries.filter { Calendar.current.isDate($0.at, inSameDayAs: days[page]) }.reversed()
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
                        VStack(alignment: .leading, spacing: Self.laneGap) {
                            lane(inputSegments(width: width), width: width)
                            lane(generationSegments(notchi: false, width: width), width: width)
                            lane(generationSegments(notchi: true, width: width), width: width)
                            lane(toolSegments(width: width), width: width)
                        }
                        .offset(x: -max(0, width - geo.size.width - back))
                        .frame(width: geo.size.width, alignment: .leading)
                        .clipped()
                        // An edge with more of the day past it fades out, which
                        // is the cue that the lanes scroll sideways.
                        .mask(edgeFade(leading: width - geo.size.width - back > 0.5,
                                       trailing: back > 0.5))
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
                AuditDetail(entry: current)
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: pageCount) { _, new in
            if page >= new { page = max(0, new - 1) }
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

    /// One lane. The whole lane is the hover surface, not the bars: a 40 ms
    /// request is a three-point sliver, and asking the pointer to land on it
    /// would make "hover a request for details" a game of skill. The bar nearest
    /// the pointer's x wins, so the lane answers wherever it is touched.
    private func lane(_ segments: [Segment], width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // A faint track, so an empty lane still reads as a lane.
            RoundedRectangle(cornerRadius: 3)
                .fill(.white.opacity(0.05))
                .frame(width: width, height: Self.laneHeight)
            ForEach(segments) { segment in
                bar(segment)
            }
        }
        .frame(width: width, height: Self.laneHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard case .active(let point) = phase,
                  let segment = nearest(in: segments, to: point.x),
                  hovered?.id != segment.entry.id else { return }
            hovered = segment.entry
        }
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

    private func bar(_ segment: Segment) -> some View {
        let isHovered = hovered?.id == segment.entry.id
        // With one bar selected the rest step back, so the card below and the
        // bar it describes are unmistakably the same request.
        let ink = isHovered ? 1 : (hovered == nil ? 0.78 : 0.32)
        return RoundedRectangle(cornerRadius: 3)
            .fill(segment.color.opacity(ink))
            .overlay {
                if isHovered {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(.white.opacity(0.85), lineWidth: 1)
                }
            }
            .frame(width: segment.width, height: Self.laneHeight)
            .offset(x: segment.x)
            .accessibilityLabel(barLabel(segment.entry))
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

    /// Walk the records oldest first, charging each idle gap at most `maxGap`.
    /// The absolute clock is gone after this — only the two ends are printed,
    /// and the note says the middle was squeezed.
    private var placements: [Placement] {
        var out: [Placement] = []
        var cursor: TimeInterval = 0
        var previousEnd: TimeInterval = 0
        var started = false
        for entry in items {
            let real = entry.at.timeIntervalSinceReferenceDate
            if started {
                cursor += min(max(real - previousEnd, 0), Self.maxGap)
            }
            started = true
            let seconds = max(Double(entry.milliseconds) / 1000, 0.001)
            out.append(Placement(entry: entry, start: cursor, seconds: seconds))
            cursor += seconds
            previousEnd = real + seconds
        }
        return out
    }

    private var axisLength: TimeInterval {
        max(placements.last.map { $0.start + $0.seconds } ?? 1, 0.001)
    }

    private struct Segment: Identifiable {
        let id: String
        let entry: RequestAudit.Entry
        let x: CGFloat
        let width: CGFloat
        let color: Color
    }

    /// A request's share of the input lane: send → first token. Jev calls have
    /// no stream to wait on — one round trip, no first token — so they appear in
    /// the Notchi lane alone.
    private func inputSegments(width: CGFloat) -> [Segment] {
        placements.filter { $0.entry.transport == .http || $0.entry.transport == .cli }.map { placement in
            let wait = min(Double(placement.entry.firstToken ?? placement.entry.milliseconds) / 1000,
                           placement.seconds)
            return segment(id: "input-\(placement.entry.id)", placement: placement,
                           from: placement.start, length: wait,
                           width: width, color: color(for: placement.entry))
        }
    }

    /// Whether the request went to Notchi's own models (Notchi Balance, Auto,
    /// Jev) rather than to a key or CLI the user set up.
    private static func isNotchi(_ entry: RequestAudit.Entry) -> Bool {
        entry.transport == .jev || entry.provider == Provider.nono.displayName
    }

    /// The two generation lanes, split by whose model answered: first token →
    /// end for a streamed request, the whole round trip for a Jev call. A
    /// request that never got a token occupies the input lane only — it never
    /// reached generation.
    private func generationSegments(notchi: Bool, width: CGFloat) -> [Segment] {
        placements.compactMap { placement in
            let entry = placement.entry
            guard entry.transport != .tool, Self.isNotchi(entry) == notchi else { return nil }
            if entry.transport == .jev {
                return segment(id: "model-\(entry.id)", placement: placement,
                               from: placement.start, length: placement.seconds,
                               width: width, color: color(for: entry))
            }
            guard let ttft = entry.firstToken else { return nil }
            let start = placement.start + Double(ttft) / 1000
            let length = placement.seconds - Double(ttft) / 1000
            guard length > 0 else { return nil }
            return segment(id: "model-\(entry.id)", placement: placement,
                           from: start, length: length,
                           width: width, color: color(for: entry))
        }
    }

    /// Tool runs sit in their own lane, one bar per run, in the same ink.
    private func toolSegments(width: CGFloat) -> [Segment] {
        placements.filter { $0.entry.transport == .tool }.map { placement in
            segment(id: "tool-\(placement.entry.id)", placement: placement,
                    from: placement.start, length: placement.seconds,
                    width: width, color: color(for: placement.entry))
        }
    }

    private func segment(id: String, placement: Placement,
                         from start: TimeInterval, length: TimeInterval,
                         width: CGFloat, color: Color) -> Segment {
        let from = x(for: start, width: width)
        let to = x(for: start + length, width: width)
        // A 40 ms request still has to be visible: three points is the floor.
        let barWidth = min(width, max(3, to - from))
        let origin = min(max(0, from), max(0, width - barWidth))
        return Segment(id: id, entry: placement.entry, x: origin,
                       width: barWidth, color: color)
    }

    private func x(for seconds: TimeInterval, width: CGFloat) -> CGFloat {
        min(max(0, CGFloat(seconds) * Self.pointsPerSecond), width)
    }

    // MARK: Color

    /// One ink for every bar. The chart encodes time and duration, not vendor —
    /// a rainbow of hues makes the reader hunt for a legend that doesn't exist,
    /// and every provider's bar would mean the same thing anyway. The one color
    /// that carries information is the failure red; a stopped request fades out.
    private func color(for entry: RequestAudit.Entry) -> Color {
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

/// The card's footer, laid out like the harness's request panel: a **Summary** of
/// what was asked and what came back, and the **Request timing** that says where
/// the wait went. Two columns rather than two stacked sections because the pane
/// is a settings column, not a window — the whole card has to stay on screen.
///
/// There is no payload here by design: `RequestAudit` never stores a prompt, an
/// answer or a response body, so the reference's Preview has nothing to show.
private struct AuditDetail: View {
    let entry: RequestAudit.Entry

    /// Whether the secondary half is unfolded. Closed by default: the facts that
    /// matter for every request are on screen, the rest is one click away instead
    /// of competing with them.
    @State private var detailed = false
    @State private var hoveringDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // One two-column grid for everything, actions included: the same
            // size, the same face, one label column, one value column. The
            // request's own name is the first row's value, so it lines up with
            // the rest instead of sitting above them in a style of its own.
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                field(kindLabel, nameText)
                field(L("audit.status"), statusText, tint: statusTint)
                field(L("audit.duration"), Self.duration(entry.milliseconds))
                if entry.transport != .tool, entry.tokens > 0 {
                    field(L("audit.tokens"), tokensText)
                }
                field(L("audit.source"), sourceText)
                if detailed {
                    field(L("audit.started"), startText)
                    if let ttft = entry.firstToken {
                        field(L("audit.ttfb"), Self.duration(ttft))
                        field(L("audit.generation"), Self.duration(max(entry.milliseconds - ttft, 0)))
                    }
                    if let rate = throughputText {
                        field(L("audit.throughput"), rate)
                    }
                }
            }
            .transition(.opacity)

            HStack(spacing: 16) {
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

            }
        }
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
        "audit.generation", "audit.throughput",
    ]

    private func field(_ label: String, _ value: String, tint: Color = Tokens.text1,
                       weight: Font.Weight = .light) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            // Every label the card can show sits hidden underneath, so the label
            // column is as wide collapsed as expanded and the values don't shift
            // when Details opens.
            ZStack(alignment: .leading) {
                ForEach(Self.labelKeys, id: \.self) { key in
                    Text(L(key)).hidden()
                }
                Text(label)
            }
            .font(AuditType.text(Tokens.TypeSize.meta))
            .foregroundStyle(Tokens.text4)
            .lineLimit(1)
            Text(value)
                .font(AuditType.text(Tokens.TypeSize.meta + 0.5, weight: weight))
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// Where it went: the endpoint for an HTTP request, the binary for a CLI run,
    /// the tool's own name for a tool run.
    private var sourceText: String {
        if entry.transport == .tool { return entry.model }
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
