import AppKit
import Charts
import SwiftUI

// MARK: - Spec
//
// The model writes one of these as a fenced block in its answer:
//
//   ```viz
//   {"type":"barh","title":"磁盘占用","items":[{"label":"Xcode","value":48.2}]}
//   ```
//
// The shape is deliberately small — the same trade Slack's `data_visualization`
// block makes: a title, one of five marks, and labelled values. Every field is
// optional except the ones a mark cannot be drawn without, and anything that
// fails validation falls back to the code block it came from (see
// `MarkdownBlockRow`), so a malformed answer never loses its content and never
// renders an empty card.

/// One labelled value. `note` is the byline the model wants printed at the end
/// of the row ("48 GB"), so a bare number never has to carry its unit alone.
struct VisualItem: Equatable {
    var label: String
    var value: Double
    var note: String?
}

struct VisualPoint: Equatable {
    var label: String
    var value: Double
}

struct VisualFact: Equatable {
    var label: String
    var value: String
}

/// A card about one thing — a place, an event, a file — with its source mark.
struct VisualEntity: Equatable {
    var icon: String?
    var title: String
    var subtitle: String?
    var facts: [VisualFact]
    var actionLabel: String?
    var actionURL: URL?
}

enum VisualSpec: Equatable {
    /// Ranked bars: "what is taking the space", largest first.
    case ranked(title: String, total: String?, items: [VisualItem], footer: String?)
    /// A line over ordered labels (days, months, years).
    case trend(title: String, note: String?, points: [VisualPoint])
    /// Share of a whole, at most six slices.
    case donut(title: String, items: [VisualItem])
    /// One figure with an optional change.
    case stat(label: String, value: String, delta: String?, note: String?)
    case entity(VisualEntity)

    var isEmpty: Bool {
        switch self {
        case .ranked(_, _, let items, _): return items.isEmpty
        case .trend(_, _, let points): return points.isEmpty
        case .donut(_, let items): return items.isEmpty
        case .stat(_, let value, _, _): return value.isEmpty
        case .entity(let e): return e.title.isEmpty
        }
    }
}

// MARK: - Parsing

private struct Payload: Decodable {
    struct Item: Decodable {
        var label: String?
        var value: Double?
        var note: String?
    }

    struct Action: Decodable {
        var label: String?
        var url: String?
    }

    var type: String?
    var title: String?
    var unit: String?
    var total: String?
    var footer: String?
    var note: String?
    var label: String?
    var value: String?
    var delta: String?
    var icon: String?
    var subtitle: String?
    var items: [Item]?
    var points: [Item]?
    var facts: [[String]]?
    var action: Action?
}

enum VisualSpecParser {
    /// The fence tags an answer may use. Both are ordinary code fences to the
    /// markdown parser, so nothing upstream has to know about them.
    static let languages: Set<String> = ["viz", "chart", "card"]

    private final class Box {
        let spec: VisualSpec?
        init(_ spec: VisualSpec?) { self.spec = spec }
    }

    /// A block re-parses on every streaming flush; the cache keeps repeats free
    /// the same way `MarkdownParser` and `LinkCardSplitter` do.
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 64
        return cache
    }()

    static func isVisual(_ language: String?) -> Bool {
        guard let language else { return false }
        return languages.contains(language.lowercased())
    }

    /// `nil` when the text is not a complete, valid spec — the caller decides
    /// whether that means "still streaming" or "fall back to code".
    static func parse(_ text: String, language: String?) -> VisualSpec? {
        guard isVisual(language) else { return nil }
        let key = "\(language ?? "")\u{1e}\(text)" as NSString
        if let hit = cache.object(forKey: key) { return hit.spec }
        let spec = build(text)
        cache.setObject(Box(spec), forKey: key)
        return spec
    }

    private static func build(_ text: String) -> VisualSpec? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let data = trimmed.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        let type = (payload.type ?? "").lowercased()
        switch type {
        case "barh", "bar", "rank", "ranking":
            guard let items = normalized(payload.items) else { return nil }
            return .ranked(title: clean(payload.title) ?? "", total: clean(payload.total),
                           items: items, footer: clean(payload.footer))
        case "line", "trend", "area":
            let points = (payload.points ?? payload.items ?? []).compactMap { item -> VisualPoint? in
                guard let label = clean(item.label), let value = item.value else { return nil }
                return VisualPoint(label: label, value: value)
            }
            guard points.count >= 2 else { return nil }
            return .trend(title: clean(payload.title) ?? "", note: clean(payload.note),
                          points: Array(points.prefix(24)))
        case "donut", "pie", "share":
            guard let items = normalized(payload.items) else { return nil }
            return .donut(title: clean(payload.title) ?? "", items: items)
        case "stat", "number", "figure":
            guard let value = clean(payload.value) else { return nil }
            return .stat(label: clean(payload.label) ?? clean(payload.title) ?? "",
                         value: value, delta: clean(payload.delta), note: clean(payload.note))
        case "card", "entity":
            guard let title = clean(payload.title) else { return nil }
            let facts = (payload.facts ?? []).compactMap { pair -> VisualFact? in
                guard pair.count >= 2,
                      let label = clean(pair[0]), let value = clean(pair[1]) else { return nil }
                return VisualFact(label: label, value: value)
            }
            let actionLabel = clean(payload.action?.label)
            let actionURL = payload.action?.url.flatMap { URL(string: $0) }
                .flatMap { url -> URL? in
                    guard let scheme = url.scheme?.lowercased(),
                          scheme == "http" || scheme == "https" else { return nil }
                    return url
                }
            return .entity(VisualEntity(icon: clean(payload.icon), title: title,
                                        subtitle: clean(payload.subtitle),
                                        facts: Array(facts.prefix(4)),
                                        actionLabel: actionURL == nil ? nil : actionLabel,
                                        actionURL: actionURL))
        default:
            return nil
        }
    }

    /// Ordering is the reader's, not the model's: a ranked bar chart is sorted
    /// by value, with an "other" bucket kept at the end where it belongs.
    private static func normalized(_ raw: [Payload.Item]?) -> [VisualItem]? {
        let items = (raw ?? []).compactMap { item -> VisualItem? in
            guard let label = clean(item.label), let value = item.value, value >= 0 else { return nil }
            return VisualItem(label: label, value: value, note: clean(item.note))
        }
        guard !items.isEmpty else { return nil }
        let capped = Array(items.prefix(8))
        let other = capped.filter { isOther($0.label) }
        let ranked = capped.filter { !isOther($0.label) }.sorted { $0.value > $1.value }
        return ranked + other
    }

    private static func isOther(_ label: String) -> Bool {
        ["其他", "其它", "其余", "other", "others", "rest"].contains(label.lowercased())
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Rendering

/// One visual block, as the answer draws it. It is boxed the way a table is
/// (`MarkdownTableView`): the same faint fill, hairline and corner, and the
/// same header row ruled off from the body, so a chart and a table in one
/// answer read as the same kind of island.
struct VisualBlockView: View {
    let spec: VisualSpec
    var baseFont: CGFloat = Tokens.TypeSize.reading

    var body: some View {
        Group {
            switch spec {
            case .ranked(let title, let total, let items, let footer):
                RankedBarsView(title: title, total: total, items: items, footer: footer)
            case .trend(let title, let note, let points):
                TrendView(title: title, note: note, points: points)
            case .donut(let title, let items):
                DonutView(title: title, items: items)
            case .stat(let label, let value, let delta, let note):
                StatView(label: label, value: value, delta: delta, note: note)
                    .padding(.vertical, Viz.bodyPadding)
            case .entity(let entity):
                EntityCardView(entity: entity)
                    .padding(.vertical, Viz.bodyPadding)
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 240, idealWidth: 280, maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle.control.fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle.control.strokeBorder(Tokens.hairline, lineWidth: 0.5))
    }
}

/// The shapes the model writes, drawn in the panel's one type + colour scale.
/// Text sits at the table cell's size (answer size one point down).
private enum Viz {
    static let title = Font.sf(12, weight: .semibold)
    static let axis = Font.sf(Tokens.TypeSize.caption)
    static let value = Font.sf(12).monospacedDigit()
    static let row = Font.sf(12)
    static let bodyPadding: CGFloat = 10
}

/// The table's header row: title left, a figure right, a hairline under it.
private struct VizHeader: View {
    let title: String
    var trailing: String? = nil
    var trailingTint: Color = Tokens.text3

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(Viz.title)
                    .foregroundStyle(Tokens.text1.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing)
                        .font(Viz.value)
                        .foregroundStyle(trailingTint)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 7)
            Divider().overlay(Tokens.hairline)
        }
    }
}

private struct RankedBarsView: View {
    let title: String
    let total: String?
    let items: [VisualItem]
    let footer: String?

    private var maxValue: Double { max(items.map(\.value).max() ?? 1, 0.0001) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !title.isEmpty || total != nil {
                VizHeader(title: title, trailing: total)
            }
            // A Grid so the label column takes the widest label (up to a cap)
            // and every bar starts and ends on the same x.
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    let other = Self.isOther(item.label)
                    GridRow {
                        Text(item.label)
                            .font(Viz.row)
                            .foregroundStyle(other ? Tokens.text3 : Tokens.text1)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 120, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.06))
                                Capsule()
                                    .fill(other ? Color.white.opacity(0.24) : Tokens.accent)
                                    .frame(width: max(4, geo.size.width * item.value / maxValue))
                            }
                        }
                        .frame(height: 5)
                        .frame(maxWidth: .infinity)
                        Text(item.note ?? format(item.value))
                            .font(Viz.value)
                            .foregroundStyle(Tokens.text2)
                            .lineLimit(1)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            .padding(.vertical, Viz.bodyPadding)
            if let footer {
                Text(footer)
                    .font(Viz.axis)
                    .foregroundStyle(Tokens.text4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Viz.bodyPadding)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private static func isOther(_ label: String) -> Bool {
        ["其他", "其它", "其余", "other", "others", "rest"].contains(label.lowercased())
    }

    private func format(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value)
    }

    private var accessibilitySummary: String {
        let rows = items.map { "\($0.label) \($0.note ?? format($0.value))" }
        return ([title] + rows).filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

private struct TrendView: View {
    let title: String
    let note: String?
    let points: [VisualPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !title.isEmpty || note != nil {
                VizHeader(title: title, trailing: note, trailingTint: Tokens.accent)
            }
            TrendPlot(points: points)
                .frame(height: 92)
                .padding(.top, Viz.bodyPadding)
                .padding(.bottom, 6)
            // Only the ends are labelled. A seven-day axis at panel width
            // squeezes into ticks Charts then drops, and the one the reader is
            // looking for is the last.
            HStack(spacing: 0) {
                Text(points.first?.label ?? "")
                Spacer(minLength: 8)
                Text(points.last?.label ?? "")
            }
            .font(Viz.axis)
            .foregroundStyle(Tokens.text4)
            .padding(.leading, 20)
            .padding(.trailing, 3)
            .padding(.bottom, Viz.bodyPadding)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func short(_ value: Double) -> String {
        if abs(value) >= 1000 {
            return String(format: "%.1fk", value / 1000)
        }
        return value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value)
    }

    private var accessibilitySummary: String {
        let rows = points.map { "\($0.label) \(short($0.value))" }
        return ([title] + rows).filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// The line itself, drawn rather than handed to Charts: the panel only needs a
/// filled line with both ends visible, and owning the geometry keeps the first
/// and last points off the frame's edge.
private struct TrendPlot: View {
    let points: [VisualPoint]

    /// Room for the two scale labels. Without a scale a line on a dark panel
    /// reads as decoration: the reader can see the shape but not the size.
    private let gutter: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let height = max(geo.size.height, 1)
            let values = points.map(\.value)
            let top = max(values.max() ?? 1, 0.0001)
            let bottom = min(values.min() ?? 0, 0)
            let span = max(top - bottom, 0.0001)
            let inset: CGFloat = 3
            let usable = max(width - gutter - inset, 1)
            let step = points.count > 1 ? usable / CGFloat(points.count - 1) : usable
            let coords = points.enumerated().map { index, point in
                CGPoint(x: gutter + step * CGFloat(index),
                        y: height - 3 - (height - 6) * CGFloat((point.value - bottom) / span))
            }

            ZStack(alignment: .topLeading) {
                Path { path in
                    guard let first = coords.first, let last = coords.last else { return }
                    path.move(to: CGPoint(x: first.x, y: height))
                    path.addLine(to: first)
                    coords.dropFirst().forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: last.x, y: height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(colors: [Tokens.accent.opacity(0.26),
                                            Tokens.accent.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                )

                Path { path in
                    guard let first = coords.first else { return }
                    path.move(to: first)
                    coords.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(Tokens.accent,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                if let last = coords.last {
                    Circle()
                        .fill(Tokens.accent)
                        .frame(width: 6, height: 6)
                        .position(last)
                }

                Path { path in
                    path.move(to: CGPoint(x: gutter, y: height - 0.5))
                    path.addLine(to: CGPoint(x: width, y: height - 0.5))
                }
                .stroke(Color.white.opacity(0.07), lineWidth: 1)

                VStack(alignment: .leading, spacing: 0) {
                    Text(short(top))
                    Spacer(minLength: 0)
                    Text(short(bottom))
                }
                .font(Viz.axis)
                .foregroundStyle(Tokens.text4)
                .monospacedDigit()
                .frame(width: gutter - 6, height: height, alignment: .leading)
                .offset(y: -1)
            }
        }
    }

    private func short(_ value: Double) -> String {
        if abs(value) >= 1000 {
            return String(format: "%.1fk", value / 1000)
        }
        return value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value)
    }
}

private struct DonutView: View {
    let title: String
    let items: [VisualItem]

    /// Six slices and a legend is the most the panel draws without shrinking
    /// either; the rest folds into one bucket.
    private var slices: [VisualItem] {
        guard items.count > 6 else { return items }
        let head = Array(items.prefix(5))
        let rest = items.dropFirst(5).reduce(0) { $0 + $1.value }
        return head + [VisualItem(label: "其他", value: rest, note: nil)]
    }

    private var total: Double { slices.reduce(0) { $0 + $1.value } }

    private var colors: [Color] {
        let ramp: [Color] = [Tokens.accent,
                             Color.white.opacity(0.55),
                             Color.white.opacity(0.34),
                             Color.white.opacity(0.24),
                             Color.white.opacity(0.17),
                             Color.white.opacity(0.12)]
        return slices.indices.map { ramp[$0 % ramp.count] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !title.isEmpty {
                VizHeader(title: title)
            }
            HStack(spacing: 14) {
                Chart(Array(slices.enumerated()), id: \.offset) { index, slice in
                    SectorMark(angle: .value("Value", slice.value),
                               innerRadius: .ratio(0.66),
                               angularInset: 1.5)
                        .cornerRadius(2.5)
                        .foregroundStyle(colors[index])
                }
                .chartLegend(.hidden)
                .frame(width: 76, height: 76)

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(slices.enumerated()), id: \.offset) { index, slice in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(colors[index])
                                .frame(width: 6, height: 6)
                            Text(slice.label)
                                .font(Viz.row)
                                .foregroundStyle(Tokens.text1)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(percent(slice.value))
                                .font(Viz.value)
                                .foregroundStyle(Tokens.text2)
                        }
                    }
                }
            }
            .padding(.vertical, Viz.bodyPadding)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func percent(_ value: Double) -> String {
        guard total > 0 else { return "0%" }
        return "\(Int((value / total * 100).rounded()))%"
    }

    private var accessibilitySummary: String {
        let rows = slices.map { "\($0.label) \(percent($0.value))" }
        return ([title] + rows).filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

private struct StatView: View {
    let label: String
    let value: String
    let delta: String?
    let note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.sf(Tokens.TypeSize.figure, weight: .semibold))
                    .foregroundStyle(Tokens.text1)
                    .monospacedDigit()
                if !label.isEmpty {
                    Text(label)
                        .font(Viz.value)
                        .foregroundStyle(Tokens.text4)
                }
            }
            Spacer(minLength: 0)
            if delta != nil || note != nil {
                VStack(alignment: .trailing, spacing: 3) {
                    if let delta {
                        Text(delta)
                            .font(Viz.value)
                            .foregroundStyle(Tokens.accent)
                    }
                    if let note {
                        Text(note)
                            .font(.sf(10))
                            .foregroundStyle(Tokens.text4)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([label, value, delta, note].compactMap { $0 }.joined(separator: ", "))
    }
}

private struct EntityCardView: View {
    let entity: VisualEntity

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                badge
                VStack(alignment: .leading, spacing: 1) {
                    Text(entity.title)
                        .font(.sf(13, weight: .medium))
                        .foregroundStyle(Tokens.text1)
                        .lineLimit(2)
                    if let subtitle = entity.subtitle {
                        Text(subtitle)
                            .font(Viz.value)
                            .foregroundStyle(Tokens.text4)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            if !entity.facts.isEmpty {
                VStack(spacing: 4) {
                    ForEach(Array(entity.facts.enumerated()), id: \.offset) { _, fact in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(fact.label)
                                .font(Viz.value)
                                .foregroundStyle(Tokens.text4)
                            Spacer(minLength: 0)
                            Text(fact.value)
                                .font(Viz.row)
                                .foregroundStyle(Tokens.text2)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            if let label = entity.actionLabel, let url = entity.actionURL {
                Button {
                    LinkGate.shared.open(url)
                } label: {
                    HStack(spacing: 5) {
                        Text(label)
                            .font(.sf(11, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Tokens.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The mark is provenance, not decoration: a symbol the answer names, in
    /// the same recessed chip the panel uses for quiet controls.
    private var badge: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Tokens.recessFill)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Tokens.recessRim, lineWidth: 1)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text2)
            )
            .frame(width: 26, height: 26)
    }

    /// An SF Symbol the model named, or the neutral one when it named nothing
    /// the system has.
    private var symbol: String {
        guard let icon = entity.icon,
              NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil else {
            return "square.text.square"
        }
        return icon
    }
}

/// What the answer shows while the fence is still open — the shape of the block
/// about to arrive, so the thread does not jump from a line of text to a chart.
struct VisualSkeletonView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white.opacity(0.09))
                .frame(width: 88, height: 8)
                .padding(.vertical, 11)
            Divider().overlay(Tokens.hairline)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white.opacity(0.04))
                .frame(height: 64)
                .padding(.vertical, 10)
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 240, idealWidth: 280, maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle.control.fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle.control.strokeBorder(Tokens.hairline, lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
