import AppKit
import CryptoKit
import ImageIO
import LinkPresentation
import MapKit
import SwiftUI

// MARK: - Splitting an answer into bubbles

/// One piece of an answer after the lead text: a page handed over on a line of
/// its own, or a message of text.
enum AnswerSegment: Equatable {
    /// `label` is the link text when the line was a lone `[label](url)`.
    case link(URL, label: String?)
    case text(String)
    /// Lines that hold only `![alt](url)` images, drawn without a bubble.
    case media(String)
}

/// An answer as the thread draws it. `lead` is the first message (the whole
/// answer when there is one); `rest` holds the cards and the messages after
/// it, in order. Each piece is its own bubble.
struct LinkCardLayout: Equatable {
    var lead: String
    var rest: [AnswerSegment]

    var hasMore: Bool { !rest.isEmpty }
}

/// Cuts an answer into bubbles. A blank line between two paragraphs starts a
/// new message, unless what follows continues the block above (a list and the
/// line that introduces it, a list's own items, a code block). A line that is a
/// single URL and nothing else becomes a card, up to `maxCards` of them — but
/// only when it is a page this answer's search returned, a page on a host the
/// user wrote, or a page the harness found open (`Turn.sharedLinks`). Any
/// other link line is left out: the model cannot hand over a page nobody
/// fetched, named, or checked. Parsing the line is `LinkLine`'s.
enum LinkCardSplitter {
    static let maxCards = 3

    private final class Box {
        let value: LinkCardLayout
        init(_ value: LinkCardLayout) { self.value = value }
    }

    /// The body of an assistant turn re-evaluates on every streaming flush, for
    /// every mounted copy of the turn; the cache makes repeats free.
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 64
        return cache
    }()

    /// The last few layouts handed out, checked before `cache`. One body
    /// evaluation asks for the same answer's layout a dozen times (`hasText`,
    /// `hasLeadText`, …), and the `cache` key copies the whole text and hashes
    /// it as an NSString each time — on a long streaming answer that was most
    /// of each flush. Comparing against the same text is a length check or an
    /// identity check.
    private struct Recent {
        let params: String
        let text: String
        let value: LinkCardLayout
    }
    nonisolated(unsafe) private static var recentLayouts: [Recent] = []
    private static let recentLock = NSLock()

    /// `recent` holds the `LinkLine.key` of pages the answers just above
    /// already carded; those pages get no second card here.
    static func layout(_ text: String, streaming: Bool, sources: [WebSource],
                       question: String, shared: [String] = [],
                       recent: Set<String> = []) -> LinkCardLayout {
        let trust = allowed(sources: sources, question: question, shared: shared)
        let params = "\(streaming ? 1 : 0)\u{1e}\(trust.pages.sorted().joined(separator: ","))"
            + "\u{1e}\(trust.hosts.sorted().joined(separator: ","))"
            + "\u{1e}\(recent.sorted().joined(separator: ","))"
        recentLock.lock()
        let hit = recentLayouts.first { $0.text == text && $0.params == params }
        recentLock.unlock()
        if let hit { return hit.value }
        let value = layoutUncached(text, streaming: streaming, trust: trust, recent: recent, params: params)
        recentLock.lock()
        recentLayouts.insert(Recent(params: params, text: text, value: value), at: 0)
        if recentLayouts.count > 8 { recentLayouts.removeLast() }
        recentLock.unlock()
        return value
    }

    private static func layoutUncached(_ text: String, streaming: Bool, trust: Trust,
                                       recent: Set<String>, params: String) -> LinkCardLayout {
        let mayLink = text.contains("http") || text.contains("![")
            || (streaming && text.contains("["))
            || text.range(of: "share", options: .caseInsensitive) != nil
        let mayBreak = text.contains("\n\n") || text.contains("\n \n")
        guard mayLink || mayBreak else {
            return LinkCardLayout(lead: text, rest: [])
        }
        let key = (params + "\u{1e}" + text) as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let result = compute(text, streaming: streaming, trust: trust, recent: recent, params: params)
        cache.setObject(Box(result), forKey: key)
        return result
    }

    // MARK: Streaming: split only what changed

    /// Everything `compute` carries from one line to the next.
    private struct SplitState {
        var lead: String? = nil
        var rest: [AnswerSegment] = []
        var buffer: [String] = []
        var cards = 0
        var seen: Set<String>
        var inFence = false
        var lastLine: String? = nil
        var inList = false
        var pendingBreak = false
    }

    /// The state before the last line of a text that was split, so the next,
    /// longer version of that text resumes there. Every line before the last
    /// one is whole and splits the same way when more text arrives; only the
    /// last line, still being written, is split again.
    private struct Checkpoint {
        let params: String
        let prefix: String
        let lineIndex: Int
        let state: SplitState
    }

    nonisolated(unsafe) private static var checkpoints: [Checkpoint] = []
    private static let checkpointLock = NSLock()

    private static func compute(_ text: String, streaming: Bool,
                                trust: Trust, recent: Set<String>,
                                params: String) -> LinkCardLayout {
        let lines = text.components(separatedBy: "\n")
        // The line still being written. It is never a card yet: its URL may
        // still be growing.
        let open = streaming ? lines.count - 1 : nil

        checkpointLock.lock()
        let resume = checkpoints.last { $0.params == params && text.hasPrefix($0.prefix) }
        checkpointLock.unlock()
        let start = resume.map { min($0.lineIndex, lines.count) } ?? 0
        let initial = resume?.state ?? SplitState(seen: recent)

        var lead = initial.lead
        var rest = initial.rest
        var buffer = initial.buffer
        var cards = initial.cards
        var seen = initial.seen
        var inFence = initial.inFence
        // The last line with text in `buffer`, whether it sits in a list, and
        // whether a blank line has come after it — a paragraph break the next
        // line may turn into a new bubble.
        var lastLine = initial.lastLine
        var inList = initial.inList
        var pendingBreak = initial.pendingBreak

        func flush() {
            let body = buffer.joined(separator: "\n")
            buffer.removeAll()
            lastLine = nil
            inList = false
            pendingBreak = false
            if lead == nil {
                lead = body.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            } else {
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { rest.append(.text(trimmed)) }
            }
        }

        // Start a new bubble at `line` when a blank line came before it and it
        // does not continue the block above.
        func breakBefore(_ line: String) {
            defer { pendingBreak = false }
            guard pendingBreak, let last = lastLine else { return }
            if startsNewMessage(after: last, inList: inList, next: line) { flush() }
        }

        func append(_ line: String, _ trimmed: String) {
            buffer.append(line)
            if isListItem(trimmed) {
                inList = true
            } else if !isIndented(line) {
                inList = false
            }
            lastLine = trimmed
        }

        func trusted(_ links: [(URL, String?)]) -> Bool {
            links.allSatisfy(trust.allows)
        }

        // `links` as cards after the text so far. False when they would pass
        // `maxCards`; the line then stays text. Pages already shown are dropped.
        func takeCards(_ links: [(URL, String?)], after text: String?, of line: String) -> Bool {
            let fresh = links.filter { !seen.contains(LinkLine.key($0.0)) }
            guard cards + fresh.count <= maxCards else { return false }
            if let text {
                breakBefore(line)
                let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                append(indent + text, text)
            }
            guard !fresh.isEmpty else { return true }
            fresh.forEach { seen.insert(LinkLine.key($0.0)) }
            flush()
            for (url, label) in fresh { rest.append(.link(url, label: label)) }
            cards += fresh.count
            return true
        }

        for i in start..<lines.count {
            let line = lines[i]
            if i == lines.count - 1, i > start {
                let cut = text.range(of: "\n", options: .backwards)?.upperBound ?? text.startIndex
                let checkpoint = Checkpoint(
                    params: params, prefix: String(text[..<cut]), lineIndex: i,
                    state: SplitState(lead: lead, rest: rest, buffer: buffer, cards: cards,
                                      seen: seen, inFence: inFence, lastLine: lastLine,
                                      inList: inList, pendingBreak: pendingBreak))
                checkpointLock.lock()
                checkpoints.removeAll { $0.params == params && checkpoint.prefix.hasPrefix($0.prefix) }
                checkpoints.append(checkpoint)
                if checkpoints.count > 4 { checkpoints.removeFirst(checkpoints.count - 4) }
                checkpointLock.unlock()
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fenceTag = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                if !inFence {
                    if fenceTag == "connector" {
                        flush()
                    } else {
                        breakBefore(line)
                    }
                }
                inFence.toggle()
                append(line, trimmed)
                if !inFence, let first = buffer.first?.trimmingCharacters(in: .whitespaces).lowercased(),
                   first == "```connector" || first == "~~~connector" {
                    flush()
                }
                continue
            }
            if inFence {
                buffer.append(line)
                continue
            }
            if trimmed.isEmpty {
                if lastLine != nil { pendingBreak = true }
                buffer.append(line)
                continue
            }
            if i == open {
                // An image still being written shows once it is whole.
                if trimmed == "!" || trimmed.hasPrefix("![") { continue }
                // Hold back a line that may still turn into a lone URL, so it
                // never shows as text for a moment and then jumps into a card.
                if cards < maxCards, LinkLine.couldBecome(trimmed) { continue }
                // Too short yet to tell whether it starts a list item, which
                // decides whether it opens a new bubble.
                if pendingBreak, trimmed.count < 4 { continue }
                breakBefore(line)
                // Links being written after the line's last sentence are held
                // back the same way.
                if cards < maxCards, let head = LinkLine.headBeforeGrowingLinks(trimmed) {
                    let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                    append(indent + head, head)
                } else {
                    append(line, trimmed)
                }
                continue
            }
            // A placeholder for a card the model never sent.
            if LinkLine.isCardStub(trimmed) { continue }
            // Images go outside the bubble. Consecutive image lines stay one
            // segment, so they fold into one pile.
            if isMediaOnly(trimmed) {
                flush()
                if case .media(let above)? = rest.last {
                    rest[rest.count - 1] = .media(above + "\n" + trimmed)
                } else {
                    rest.append(.media(trimmed))
                }
                continue
            }
            // A link line whose page is not trusted is left out. While the
            // reply streams it may still be found open as it ends.
            if let links = LinkLine.parseAll(trimmed) {
                if !trusted(links) { continue }
                if takeCards(links, after: nil, of: line) { continue }
            }
            // Links after the line's last sentence, on the same line.
            if let split = LinkLine.splitTrailing(trimmed) {
                let kept = split.links.filter(trust.allows)
                if takeCards(kept, after: split.text, of: line) { continue }
            }
            breakBefore(line)
            append(line, trimmed)
        }
        flush()
        return LinkCardLayout(lead: lead ?? "", rest: rest)
    }

    /// Whether the text after a blank line is a new message rather than more of
    /// the block above. A list stays with the line that introduces it and with
    /// its own items; a heading stays with what it heads.
    private static func startsNewMessage(after last: String, inList: Bool,
                                         next line: String) -> Bool {
        if last.hasSuffix(":") || last.hasSuffix("：") { return false }
        if isHeading(last) { return false }
        let next = line.trimmingCharacters(in: .whitespaces)
        if inList, isListItem(next) || isIndented(line) { return false }
        // A chart or a card belongs to the sentence that introduces it: the
        // blank line in front of its fence is breathing room, not a new bubble.
        // A `connector` card is its own bubble so it never draws a box inside a box.
        if next.hasPrefix("```") || next.hasPrefix("~~~") {
            let tag = String(next.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
            if VisualSpecParser.isVisual(tag), tag != "connector" { return false }
        }
        return true
    }

    /// `# Title`, or a line that is all bold: `**Title**`, `__Title__`.
    private static func isHeading(_ s: String) -> Bool {
        if s.hasPrefix("#") { return true }
        for mark in ["**", "__"] where s.count > 4 && s.hasPrefix(mark) && s.hasSuffix(mark) {
            return !s.dropFirst(2).dropLast(2).contains(mark)
        }
        return false
    }

    private static let imageRef = #/!\[[^\]]*\]\(\s*\S+?(?:\s+"[^"]*")?\s*\)/#

    /// A line with nothing but `![alt](url)` images on it.
    private static func isMediaOnly(_ line: String) -> Bool {
        guard line.hasPrefix("![") else { return false }
        return line.replacing(imageRef, with: "")
            .trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `- item`, `* item`, `+ item`, `• item`, `1. item`, `1) item`.
    private static func isListItem(_ s: String) -> Bool {
        if let first = s.first, "-*+•".contains(first) {
            return s.dropFirst().first == " "
        }
        let digits = s.prefix(while: { $0.isASCII && $0.isNumber })
        guard (1...3).contains(digits.count) else { return false }
        let after = s.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")" else { return false }
        return after.dropFirst().first == " "
    }

    private static func isIndented(_ line: String) -> Bool {
        line.hasPrefix("  ") || line.hasPrefix("\t")
    }

    static func normalizedHost(_ host: String) -> String {
        LinkLine.normalizedHost(host)
    }

    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    private final class HostBox {
        let hosts: Set<String>
        init(_ hosts: Set<String>) { self.hosts = hosts }
    }

    private static let questionHosts: NSCache<NSString, HostBox> = {
        let cache = NSCache<NSString, HostBox>()
        cache.countLimit = 32
        return cache
    }()

    /// The pages this answer may hand over: every page its search returned
    /// and every page the harness found open, by `LinkLine.key`; and any page
    /// on a host the user's message names.
    struct Trust {
        var pages: Set<String>
        var hosts: Set<String>

        func allows(_ link: (URL, String?)) -> Bool {
            pages.contains(LinkLine.key(link.0)) || hosts.contains(LinkLine.host(link.0))
        }
    }

    static func allowed(sources: [WebSource], question: String,
                        shared: [String] = []) -> Trust {
        let pages = Set((sources.map(\.url) + shared)
            .compactMap { URL(string: $0) }.map(LinkLine.key))
        var trust = Trust(pages: pages, hosts: [])
        guard !question.isEmpty else { return trust }
        let key = question as NSString
        if let hit = questionHosts.object(forKey: key) {
            trust.hosts = hit.hosts
            return trust
        }
        var found = Set<String>()
        if let detector {
            let range = NSRange(question.startIndex..<question.endIndex, in: question)
            for match in detector.matches(in: question, options: [], range: range) {
                if let host = match.url?.host { found.insert(normalizedHost(host)) }
            }
        }
        questionHosts.setObject(HostBox(found), forKey: key)
        trust.hosts = found
        return trust
    }
}

extension Array where Element == NotchModel.Turn {
    /// The user's words the answer `answerID` replies to: the nearest user turn
    /// above it.
    func question(before answerID: UUID) -> String {
        guard let i = lastIndex(where: { $0.id == answerID }) else { return "" }
        return question(at: i)
    }

    /// `question(before:)` for the answer at index `i`.
    func question(at i: Int) -> String {
        self[..<i].last(where: { $0.role == "user" })?.text ?? ""
    }

    /// When the turn at index `i` was sent or answered. Assistant turns saved
    /// before they recorded their own `sentAt` fall back to the user turn that
    /// opened the same round.
    func timestamp(at i: Int) -> Date? {
        guard indices.contains(i) else { return nil }
        if let at = self[i].sentAt { return at }
        guard self[i].role == "assistant" else { return nil }
        for j in stride(from: i - 1, through: 0, by: -1) {
            if self[j].role == "assistant" { return nil }
            if let at = self[j].sentAt { return at }
        }
        return nil
    }

    func timestamp(for turnID: UUID) -> Date? {
        guard let i = lastIndex(where: { $0.id == turnID }) else { return nil }
        return timestamp(at: i)
    }

    /// The pages the `window` answers above `answerID` hand over as cards, by
    /// `LinkLine.key`. Those answers are laid out on their own, without this
    /// filter, so a page every answer repeats still stays hidden until it
    /// leaves the window.
    func recentCards(before answerID: UUID, window: Int = 3) -> Set<String> {
        guard let i = lastIndex(where: { $0.id == answerID }) else { return [] }
        return recentCards(at: i, window: window)
    }

    /// `recentCards(before:)` for the answer at index `i`.
    func recentCards(at i: Int, window: Int = 3) -> Set<String> {
        var keys = Set<String>()
        var counted = 0
        for j in stride(from: i - 1, through: 0, by: -1) where counted < window {
            let turn = self[j]
            guard turn.role == "assistant", !turn.isError else { continue }
            counted += 1
            let text = CitationMarkup.rendered(
                turn.text, sources: turn.sources,
                stripUnresolved: CitationMarkup.shouldStripUnresolved(
                    answerModel: turn.answerModel, regenModel: turn.regenModel))
            let layout = LinkCardSplitter.layout(
                text, streaming: false, sources: turn.sources,
                question: question(at: j), shared: turn.sharedLinks)
            for case .link(let url, _) in layout.rest { keys.insert(LinkLine.key(url)) }
        }
        return keys
    }

    /// Draws the cards of the answer `answerID` as the thread would show
    /// them. An answer that finished with no thread on screen (one asked from
    /// Telegram, or one the user walked away from) otherwise reads its pages
    /// only when the thread is opened, and shows the loading card meanwhile.
    @MainActor
    func prepareCards(for answerID: UUID) {
        guard let i = lastIndex(where: { $0.id == answerID }) else { return }
        let turn = self[i]
        guard turn.role == "assistant", !turn.isError else { return }
        let text = CitationMarkup.rendered(
            ReasoningTags.visible(turn.text), sources: turn.sources,
            stripUnresolved: CitationMarkup.shouldStripUnresolved(
                answerModel: turn.answerModel, regenModel: turn.regenModel))
        let layout = LinkCardSplitter.layout(
            text, streaming: false, sources: turn.sources,
            question: question(at: i), shared: turn.sharedLinks,
            recent: recentCards(at: i))
        var links: [(URL, String?)] = []
        for case .link(let url, let label) in layout.rest {
            let target = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let title = turn.sources.first {
                $0.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == target
            }?.title ?? label
            links.append((url, title))
        }
        for (url, title) in links {
            Task { _ = await LinkCardStore.shared.still(url: url, title: title, large: false) }
        }
    }
}

// MARK: - The card

/// A page handed over on its own line, drawn the way Messages draws a link:
/// the system's `LPLinkView` in its compact form — title, host, and the site's
/// icon on the right, on a background tinted from that icon.
///
/// The view is drawn once off screen and shown as an image. A live AppKit view
/// cannot sit in the thread: the panel's edge blur renders a copy of the
/// thread inside a drawing group, where an AppKit view draws as an error
/// placeholder.
struct LinkCardView: View {
    let url: URL
    /// A title for the page before (or instead of) the page's own.
    var title: String?
    /// Draw the page's preview image above the title when it has one. The
    /// answer asks for it when this is its only card.
    var large: Bool
    /// Quiet hover timestamp shown beside the card's bottom-right corner.
    var timestamp: Date? = nil

    @State private var still: NSImage?
    /// The size this card was last shown at, from an earlier mount or launch.
    /// Until the still is ready the card holds this much room, so the thread
    /// does not change height under the reader when it arrives.
    private let knownSize: CGSize?

    init(url: URL, title: String?, large: Bool = false, timestamp: Date? = nil) {
        self.url = url
        self.title = title
        self.large = large
        self.timestamp = timestamp
        _still = State(initialValue: LinkCardStore.cachedStill(url: url, title: title, large: large))
        knownSize = LinkCardStore.knownSize(url: url, title: title, large: large)
    }

    @Environment(\.cardWidthFraction) private var cardWidthFraction

    var body: some View {
        if let slug = PagesService.slug(from: url) {
            NotchiPageCard(url: url, slug: slug, fallbackTitle: title, timestamp: timestamp)
        } else {
            standardCard
        }
    }

    private var standardCard: some View {
        FractionWidthLayout(fraction: cardWidthFraction, hugs: true) {
            if let still {
                Button {
                    LinkGate.shared.open(url)
                } label: {
                    Image(nsImage: still)
                        .resizable()
                        .aspectRatio(still.size, contentMode: .fit)
                        .frame(maxWidth: still.size.width)
                        .clipShape(RoundedRectangle(cornerRadius: ChatBubbleChrome.cardRadius,
                                                    style: .continuous))
                }
                .buttonStyle(PlatePressStyle())
                .modifier(BubbleHoverTimestamp(date: timestamp))
                .transition(.opacity)
            } else if let knownSize {
                Color.clear
                    .aspectRatio(knownSize, contentMode: .fit)
                    .frame(maxWidth: knownSize.width)
            }
        }
        .task(id: "\(large)\u{1e}\(url.absoluteString)\u{1e}\(title ?? "")") {
            if let hit = LinkCardStore.cachedStill(url: url, title: title, large: large) {
                if still !== hit { still = hit }
                return
            }
            if still == nil,
               let saved = await LinkCardStore.shared.savedStill(url: url, title: title, large: large) {
                withAnimation(.easeOut(duration: 0.18)) { still = saved }
                return
            }
            // The loading card is shorter than a large finished one. Shown in
            // room kept for the finished card, it would change the height twice.
            if still == nil,
               let loading = await LinkCardStore.shared.loadingStill(url: url, title: title),
               knownSize == nil || knownSize == loading.size {
                withAnimation(.easeOut(duration: 0.18)) { still = loading }
            }
            if let final = await LinkCardStore.shared.still(url: url, title: title, large: large) {
                withAnimation(.easeOut(duration: 0.18)) { still = final }
            } else if still == nil,
                      let loading = await LinkCardStore.shared.loadingStill(url: url, title: title) {
                LinkCardStore.shared.remember(size: loading.size, url: url, title: title, large: large)
                withAnimation(.easeOut(duration: 0.18)) { still = loading }
            }
        }
    }
}

/// Bespoke card for a Notchi page (`https://<slug>.notch.website`): a compact
/// warm-ivory paper card matching the webpage's `#fbfbfa` editorial canvas.
private struct NotchiPageCard: View {
    let url: URL
    let slug: String
    let fallbackTitle: String?
    let timestamp: Date?

    @ObservedObject private var pages = PagesService.shared
    @Environment(\.cardWidthFraction) private var cardWidthFraction
    @State private var hovering = false

    private var summary: PagesService.PageSummary? {
        pages.pages.first { $0.slug == slug }
    }

    private var displayTitle: String {
        summary?.title ?? PagesService.cachedTitle(forSlug: slug) ?? fallbackTitle ?? slug
    }

    private var isPublic: Bool {
        summary?.isPublic == true
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let ink = Color(red: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255)
        let muted = Color(red: 0x7A / 255, green: 0x7A / 255, blue: 0x80 / 255)
        let paperTop = Color(red: 0xFC / 255, green: 0xFB / 255, blue: 0xF8 / 255)
        let paperBottom = Color(red: 0xF3 / 255, green: 0xF2 / 255, blue: 0xEE / 255)

        FractionWidthLayout(fraction: cardWidthFraction, hugs: true) {
            Button {
                LinkGate.shared.open(url)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 0) {
                        Text("\(slug).\(PagesService.domain)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if isPublic {
                            Text(" · Public")
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(muted)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .frame(minWidth: 230, maxWidth: 310, alignment: .leading)
                .background(
                    shape.fill(
                        LinearGradient(
                            colors: [paperTop, paperBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                )
                .overlay(
                    shape.strokeBorder(
                        Color.black.opacity(hovering ? 0.14 : 0.08),
                        lineWidth: 0.75
                    )
                )
                .shadow(color: Color.black.opacity(hovering ? 0.16 : 0.10),
                        radius: hovering ? 10 : 7, x: 0, y: hovering ? 4 : 2)
                .contentShape(shape)
            }
            .buttonStyle(PlatePressStyle())
            .onHover { over in
                withAnimation(.easeOut(duration: 0.16)) { hovering = over }
            }
            .modifier(BubbleHoverTimestamp(date: timestamp))
        }
        .task(id: slug) {
            if summary == nil && PagesService.cachedTitle(forSlug: slug) == nil {
                _ = try? await PagesService.shared.get(slug: slug, entries: 0)
            }
        }
    }
}

/// Fetches page metadata with `LPMetadataProvider`, keeps it on disk, and
/// draws the cards.
@MainActor
final class LinkCardStore {
    static let shared = LinkCardStore()

    /// Width the card is drawn at. `LPLinkView` stops growing a little past it.
    private static let drawWidth: CGFloat = 340

    private nonisolated(unsafe) static let stills: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    private var metadata: [String: LPLinkMetadata] = [:]
    private var inflight: [String: Task<LPLinkMetadata?, Never>] = [:]
    private var drawing: [String: Task<(image: NSImage?, complete: Bool), Never>] = [:]

    /// Longest side of the preview image a large card shows, as a multiple of
    /// its width. A portrait photo is cut to a square from near its top, where
    /// a face usually is.
    private static let maxImageAspect: CGFloat = 1
    /// Narrower preview images are drawn as the compact card: stretched to the
    /// card's width they blur.
    private static let minImagePixels = 300

    private nonisolated static func key(_ url: URL, _ title: String?, _ large: Bool) -> NSString {
        (url.absoluteString + "\u{1e}" + (title ?? "") + (large ? "\u{1e}L" : "")) as NSString
    }

    /// The finished card, when it has been drawn this session.
    nonisolated static func cachedStill(url: URL, title: String?, large: Bool) -> NSImage? {
        stills.object(forKey: key(url, title, large))
    }

    /// The card while the page's details are still loading: the title we
    /// already have, the host, and the system's placeholder icon.
    ///
    /// Kept like the finished card: every mount of a card that has no finished
    /// still draws this first, and a thread mounts its cards again each time it
    /// is opened, pulled or closed.
    func loadingStill(url: URL, title: String?) async -> NSImage? {
        let key = Self.loadingKey(url, title)
        if let hit = Self.stills.object(forKey: key) { return hit }
        let image = await draw(placeholder(url: url, title: title))
        if let image { Self.stills.setObject(image, forKey: key) }
        return image
    }

    /// When a card's finished still last could not be drawn. It keeps the
    /// loading card instead of drawing again on every mount, until
    /// `retryAfter` has passed: a page that timed out once often loads on
    /// the next try.
    private var failed: [String: Date] = [:]
    private static let retryAfter: TimeInterval = 60

    /// The finished card. Falls back to the loading card when the page
    /// cannot be read.
    func still(url: URL, title: String?, large: Bool) async -> NSImage? {
        let key = Self.key(url, title, large)
        if let hit = Self.stills.object(forKey: key) { return hit }
        if let at = failed[key as String], Date().timeIntervalSince(at) < Self.retryAfter { return nil }
        if let running = drawing[key as String] { return await running.value.image }
        let task = Task { () -> (image: NSImage?, complete: Bool) in
            if let page = Self.notchiPageDetails(url) {
                let card = LPLinkMetadata()
                card.originalURL = url
                card.url = url
                card.title = title ?? page.title
                card.iconProvider = page.icon
                let image = await self.draw(card)
                return (image, image != nil)
            }
            let local = Self.mapsDetails(url)
            // Drawn while the page is read: reading a Maps link runs to the
            // provider's timeout.
            async let map: Data? = large && local != nil ? Self.mapImage(url, query: local?.title) : nil
            let fetched = await self.pageMetadata(url)
            let mapImage = await map
            let card = LPLinkMetadata()
            card.originalURL = url
            card.url = fetched?.url ?? url
            card.title = Self.pageTitle(fetched?.title, url: url) ?? title ?? local?.title
                ?? Self.pathTitle(url)
            // A preview image switches `LPLinkView` to its tall layout; the
            // compact form carries the icon only.
            if let mapImage {
                card.iconProvider = local?.icon
                card.imageProvider = NSItemProvider(item: mapImage as NSData, typeIdentifier: "public.png")
            } else if large, let image = fetched?.imageProvider,
               let preview = await Self.previewImage(image) {
                card.iconProvider = fetched?.iconProvider
                card.imageProvider = preview
            } else {
                card.iconProvider = fetched?.iconProvider ?? fetched?.imageProvider
                    ?? local?.icon
            }
            return (await self.draw(card), card.iconProvider != nil)
        }
        drawing[key as String] = task
        let (image, complete) = await task.value
        drawing[key as String] = nil
        if let image {
            Self.stills.setObject(image, forKey: key)
            // A card drawn without the page's icon (the page could not be
            // read) is kept for this session only; the next launch reads the
            // page again.
            if complete { saveStill(image, key: key) } else { remember(size: image.size, key: key) }
        } else {
            failed[key as String] = Date()
            if let loading = Self.stills.object(forKey: Self.loadingKey(url, title)) {
                remember(size: loading.size, key: key)
            }
        }
        return image
    }

    // MARK: Finished cards on disk

    /// Point sizes of cards drawn before, by `stillName`. Read once, small.
    private lazy var sizes: [String: CGSize] = {
        // "Stills" held cards drawn before a card without a page title took
        // the name in its link's path; they showed the host alone.
        Self.diskQueue.async {
            // "Stills2" held cards drawn when the page could not be read
            // (kimi.com showed its host and a compass).
            for old in ["Stills", "Stills2"] {
                try? FileManager.default.removeItem(
                    at: Self.directory.appendingPathComponent(old, isDirectory: true))
            }
        }
        guard let data = try? Data(contentsOf: Self.sizesURL),
              let pairs = try? JSONDecoder().decode([String: [CGFloat]].self, from: data)
        else { return [:] }
        return pairs.compactMapValues { $0.count == 2 ? CGSize(width: $0[0], height: $0[1]) : nil }
    }()

    private static let diskQueue = DispatchQueue(label: "LinkCardStore.disk", qos: .utility)

    private nonisolated static var stillsDirectory: URL {
        directory.appendingPathComponent("Stills3", isDirectory: true)
    }

    private nonisolated static var sizesURL: URL {
        stillsDirectory.appendingPathComponent("sizes.json")
    }

    private nonisolated static func stillName(_ key: NSString) -> String {
        SHA256.hash(data: Data((key as String).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func stillURL(_ name: String) -> URL {
        stillsDirectory.appendingPathComponent(name + ".png")
    }

    private nonisolated static func loadingKey(_ url: URL, _ title: String?) -> NSString {
        (url.absoluteString + "\u{1e}" + (title ?? "") + "\u{1e}P") as NSString
    }

    /// The size this card was last shown at, if it has been drawn before.
    static func knownSize(url: URL, title: String?, large: Bool) -> CGSize? {
        if let hit = stills.object(forKey: key(url, title, large)) { return hit.size }
        return shared.sizes[stillName(key(url, title, large))]
    }

    func remember(size: CGSize, url: URL, title: String?, large: Bool) {
        remember(size: size, key: Self.key(url, title, large))
    }

    private func remember(size: CGSize, key: NSString) {
        let name = Self.stillName(key)
        guard sizes[name] != size else { return }
        sizes[name] = size
        let pairs = sizes.mapValues { [$0.width, $0.height] }
        Self.diskQueue.async {
            guard let data = try? JSONEncoder().encode(pairs) else { return }
            try? FileManager.default.createDirectory(at: Self.stillsDirectory,
                                                     withIntermediateDirectories: true)
            try? data.write(to: Self.sizesURL, options: .atomic)
        }
    }

    private func saveStill(_ image: NSImage, key: NSString) {
        guard let cg = (image.representations.first as? NSBitmapImageRep)?.cgImage
                ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        remember(size: image.size, key: key)
        let url = Self.stillURL(Self.stillName(key))
        Self.diskQueue.async {
            try? FileManager.default.createDirectory(at: Self.stillsDirectory,
                                                     withIntermediateDirectories: true)
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, cg, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    /// A finished card saved by an earlier launch, drawn at the size it was
    /// shown at.
    func savedStill(url: URL, title: String?, large: Bool) async -> NSImage? {
        let key = Self.key(url, title, large)
        let name = Self.stillName(key)
        guard let size = sizes[name] else { return nil }
        let file = Self.stillURL(name)
        let cg: CGImage? = await withCheckedContinuation { done in
            Self.diskQueue.async {
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(
                        source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                else { return done.resume(returning: nil) }
                done.resume(returning: image)
            }
        }
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: size)
        Self.stills.setObject(image, forKey: key)
        return image
    }

    private func placeholder(url: URL, title: String?) -> LPLinkMetadata {
        let local = Self.notchiPageDetails(url) ?? Self.mapsDetails(url)
        let card = LPLinkMetadata()
        card.originalURL = url
        card.url = url
        card.title = title ?? local?.title ?? Self.pathTitle(url)
        card.iconProvider = local?.icon
        return card
    }

    /// The page's own title, unless it leaves out the name the link carries in
    /// its path. A site that turns scripts away (Baidu Baike answers 403) hands
    /// back its block page, titled with the site's name only.
    private static func pageTitle(_ fetched: String?, url: URL) -> String? {
        guard let fetched else { return nil }
        if let name = pathTitle(url), name.unicodeScalars.contains(where: { !$0.isASCII }),
           !fetched.localizedCaseInsensitiveContains(name) {
            return nil
        }
        return fetched
    }

    /// The name a link carries in its path, for a card with no other title:
    /// `baike.baidu.com/item/胡辣汤/11170263` → "胡辣汤",
    /// `en.wikipedia.org/wiki/Dario_Amodei` → "Dario Amodei". Taken only from a
    /// segment that reads as words: one with letters outside ASCII, or ASCII
    /// words split by spaces or underscores. A hyphenated slug or a bare word
    /// ("detail.shtml") is passed over.
    static func pathTitle(_ url: URL) -> String? {
        for segment in url.pathComponents.reversed() where segment != "/" {
            var name = segment.removingPercentEncoding ?? segment
            if let dot = name.lastIndex(of: "."),
               ["html", "htm", "shtml", "php", "aspx"].contains(name[name.index(after: dot)...].lowercased()) {
                name = String(name[..<dot])
            }
            name = name.replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.count <= 60, name.contains(where: \.isLetter) else { continue }
            if name.unicodeScalars.contains(where: { !$0.isASCII && CharacterSet.letters.contains($0) })
                || name.contains(" ") {
                return name
            }
        }
        return nil
    }

    /// A Notchi page (`<slug>.notch.website`) drawn from its cached title and
    /// the app icon without fetching the URL — private pages answer 403 to
    /// `LPMetadataProvider`.
    private static func notchiPageDetails(_ url: URL) -> (title: String?, icon: NSItemProvider?)? {
        guard let slug = PagesService.slug(from: url) else { return nil }
        let title = PagesService.cachedTitle(forSlug: slug) ?? slug
        let icon = notchiAppIcon.map { NSItemProvider(item: $0 as NSData, typeIdentifier: "public.png") }
        return (title, icon)
    }

    private static let notchiAppIcon: Data? = {
        guard let icon = NSApp.applicationIconImage,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }()

    /// An Apple Maps link as a card without reading the page: the place it
    /// searches for and the Maps icon. `LPMetadataProvider` reads such a link
    /// by searching Apple's map servers, which takes 13 s or more and fails
    /// when they cannot be reached.
    private static func mapsDetails(_ url: URL) -> (title: String?, icon: NSItemProvider?)? {
        guard let host = url.host, LinkLine.normalizedHost(host) == "maps.apple.com" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let place = ["q", "address", "daddr"].lazy
            .compactMap { name in items.first(where: { $0.name == name })?.value }
            .map { $0.removingPercentEncoding ?? $0 }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
        let icon = mapsIcon.map { NSItemProvider(item: $0 as NSData, typeIdentifier: "public.png") }
        return (place, icon)
    }

    private static let mapsIcon: Data? = {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Maps")
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        // Drawn into one 128 pt bitmap. `tiffRepresentation` encoded every
        // size the icon carries, up to 1024 px, and took ~0.4 s on the main
        // thread the first time a Maps card was drawn.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }()

    /// Point size of the map a large Maps card shows, as wide as `drawWidth`.
    private nonisolated static let mapSize = CGSize(width: 340, height: 190)

    /// The map a large Maps card shows, as PNG: the place the link's `ll`
    /// gives, else the first place Maps finds for its query, with a pin on it.
    /// Nil when Maps finds nothing or has not drawn it within 10 s; the card
    /// then shows the Maps icon.
    private nonisolated static func mapImage(_ url: URL, query: String?) async -> Data? {
        await within(10) {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            var center: CLLocationCoordinate2D?
            var meters: CLLocationDistance = 1_200
            if let ll = items.first(where: { $0.name == "ll" })?.value {
                let parts = ll.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 2 { center = CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]) }
            }
            if center == nil, let query, let item = await TravelTimeTool.place(query) {
                center = item.placemark.coordinate
                // A city or a park comes with its extent; a shop, with a few
                // hundred metres.
                if let area = item.placemark.region as? CLCircularRegion {
                    meters = max(meters, area.radius * 4)
                }
            }
            guard let center, CLLocationCoordinate2DIsValid(center) else { return nil }
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(center: center,
                                                latitudinalMeters: meters * mapSize.height / mapSize.width,
                                                longitudinalMeters: meters)
            options.size = mapSize
            options.appearance = NSAppearance(named: .darkAqua)
            guard let shot = try? await MKMapSnapshotter(options: options).start() else { return nil }
            return pinned(shot.image)
        }
    }

    /// The snapshot with a pin at its centre, which is the place, as PNG at
    /// the snapshot's own resolution.
    private nonisolated static func pinned(_ map: NSImage) -> Data? {
        let size = map.size
        let pixels = map.representations.map(\.pixelsWide).max() ?? Int(size.width)
        let scale = max(1, CGFloat(pixels) / size.width)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        map.draw(in: NSRect(origin: .zero, size: size))
        let mid = NSPoint(x: size.width / 2, y: size.height / 2)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: mid.x - 9, y: mid.y - 9, width: 18, height: 18)).fill()
        NSShadow().set()
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: mid.x - 6.5, y: mid.y - 6.5, width: 13, height: 13)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// `work`'s result, or nil when it has not finished within `seconds`.
    /// `work` is left to finish on its own.
    private nonisolated static func within<T>(_ seconds: Double,
                                              _ work: @escaping @Sendable () async -> T?) async -> T? {
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { once.finish(await work()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.finish(nil)
            }
        }
    }

    // MARK: Metadata

    private func pageMetadata(_ url: URL) async -> LPLinkMetadata? {
        let key = url.absoluteString
        if let hit = metadata[key] { return hit }
        if let running = inflight[key] { return await running.value }
        let task = Task { () -> LPLinkMetadata? in
            if let saved = Self.readRecord(url) { return saved }
            guard let fetched = await Self.fetch(url) else { return nil }
            let saved = await Self.saveRecord(url: url, title: fetched.title,
                                              resolved: fetched.url,
                                              icon: fetched.iconProvider,
                                              image: fetched.imageProvider)
            return saved ?? fetched
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        if let result { metadata[key] = result }
        return result
    }

    /// Reads the page. A heavy page (Wikipedia: 6–12 s) often runs past the
    /// timeout after its title, icon and image are already in; the provider
    /// then hands back that metadata together with the timeout error, which
    /// the `async` form throws away. Keep it when it has a title.
    ///
    /// When the provider comes back without an icon, the page's head is read
    /// directly. `LPMetadataProvider` fails some redirects outright
    /// (kimi.com → www.kimi.com: LPError 2), so it is tried once more at the
    /// address the page ended up at; failing that, the card is built from the
    /// head's title, preview image and icon links, then `/favicon.ico`.
    /// Reads the page's `<head>` directly first (pure URLSession — avoids spinning
    /// up WebKit via `LPMetadataProvider` for ordinary links). Falls back to
    /// `LPMetadataProvider` only when direct head parsing yields neither a title
    /// nor an icon (e.g. JS-only SPAs or Apple Maps deep links).
    private static func fetch(_ url: URL) async -> LPLinkMetadata? {
        if let head = await PageHead.read(url) {
            let icon = await head.icon()
            if head.title != nil || icon != nil {
                let card = LPLinkMetadata()
                card.originalURL = url
                card.url = head.url ?? url
                card.title = head.title
                card.iconProvider = icon.map { NSItemProvider(item: $0 as NSData, typeIdentifier: "public.png") }
                card.imageProvider = head.imageProvider()
                return card
            }
        }
        let fallback = await provide(url)
        if fallback?.iconProvider != nil { return fallback }
        return fallback
    }

    private static func provide(_ url: URL) async -> LPLinkMetadata? {
        await withCheckedContinuation { done in
            let provider = LPMetadataProvider()
            provider.timeout = 10
            provider.startFetchingMetadata(for: url) { metadata, error in
                if error == nil || metadata?.title != nil {
                    done.resume(returning: metadata)
                } else {
                    done.resume(returning: nil)
                }
            }
        }
    }

    /// What is kept per page: its title, where it resolved to, and the bytes
    /// of its icon and preview image. `LPLinkMetadata`'s own archive drops an
    /// image it has not drawn.
    private struct Record: Codable {
        var title: String?
        var url: String?
        var icon: Data?
        var iconType: String?
        var image: Data?
        var imageType: String?
        /// Records written before the preview image was kept have none and
        /// are fetched again.
        var version: Int?
    }

    private static let recordVersion = 2
    /// Disk cache bounds for `LinkCards/`: drop records untouched for 30 days
    /// and evict oldest entries once total size exceeds 10 MB (down to 8 MB).
    private nonisolated static let diskMaxBytes = 10 * 1024 * 1024
    private nonisolated static let diskTargetBytes = 8 * 1024 * 1024
    private nonisolated static let diskMaxAge: TimeInterval = 30 * 24 * 60 * 60
    private nonisolated static let diskPruneQueue = DispatchQueue(
        label: "com.notchglass.linkcards-prune", qos: .utility)

    private nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Notch", isDirectory: true)
            .appendingPathComponent("LinkCards", isDirectory: true)
    }

    private nonisolated static func recordURL(_ url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return directory.appendingPathComponent(
            digest.map { String(format: "%02x", $0) }.joined() + ".json")
    }

    private nonisolated static func readRecord(_ url: URL) -> LPLinkMetadata? {
        let file = recordURL(url)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let mod = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mod) > diskMaxAge {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        guard let data = try? Data(contentsOf: file),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == recordVersion,
              record.icon != nil
        else { return nil }
        // Touch mtime so active cards stay ahead of LRU eviction.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return metadata(from: record, original: url)
    }

    /// Evicts expired (>30 days) and oldest records once `LinkCards/` exceeds 10 MB.
    nonisolated static func pruneDiskCache() {
        diskPruneQueue.async {
            let dir = directory
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: Array(keys)) else { return }
            let cutoff = Date().addingTimeInterval(-diskMaxAge)
            var kept: [(url: URL, size: Int, date: Date)] = []
            var totalBytes = 0
            for url in files {
                let name = url.lastPathComponent
                guard name.hasSuffix(".json"), name != "sizes.json" else { continue }
                guard let vals = try? url.resourceValues(forKeys: keys),
                      vals.isRegularFile == true else { continue }
                let mod = vals.contentModificationDate ?? .distantPast
                if mod < cutoff {
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                let size = vals.fileSize ?? 0
                kept.append((url, size, mod))
                totalBytes += size
            }
            guard totalBytes > diskMaxBytes else { return }
            kept.sort { $0.date < $1.date }
            for item in kept {
                guard totalBytes > diskTargetBytes else { break }
                try? FileManager.default.removeItem(at: item.url)
                totalBytes -= item.size
            }
        }
    }

    private nonisolated static func metadata(from record: Record, original: URL) -> LPLinkMetadata {
        let card = LPLinkMetadata()
        card.originalURL = original
        card.url = record.url.flatMap(URL.init(string:)) ?? original
        card.title = record.title
        if let icon = record.icon, let type = record.iconType {
            card.iconProvider = NSItemProvider(item: icon as NSData, typeIdentifier: type)
        }
        if let image = record.image, let type = record.imageType {
            card.imageProvider = NSItemProvider(item: image as NSData, typeIdentifier: type)
        }
        return card
    }

    private static func saveRecord(url: URL, title: String?, resolved: URL?,
                                   icon: NSItemProvider?,
                                   image: NSItemProvider?) async -> LPLinkMetadata? {
        var record = Record(title: title, url: resolved?.absoluteString,
                            version: recordVersion)
        if let loaded = await load(icon), loaded.data.count <= 2_000_000 {
            record.icon = loaded.data
            record.iconType = loaded.type
        }
        if let loaded = await load(image), loaded.data.count <= 4_000_000 {
            record.image = loaded.data
            record.imageType = loaded.type
        }
        if let data = try? JSONEncoder().encode(record) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: recordURL(url), options: .atomic)
            Self.pruneDiskCache()
        }
        return Self.metadata(from: record, original: url)
    }

    private nonisolated static func load(_ provider: NSItemProvider?) async -> (data: Data, type: String)? {
        guard let provider, let type = provider.registeredTypeIdentifiers.first else { return nil }
        let data: Data? = await withCheckedContinuation { done in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                done.resume(returning: data)
            }
        }
        return data.map { (data: $0, type: type) }
    }

    /// The page's preview image as a large card shows it: cut to at most
    /// `maxImageAspect` tall, downscaled to the card's @2x display width (680 px),
    /// and stored as JPEG so cached link cards stay tens of KB instead of multi-MB PNGs.
    private nonisolated static func previewImage(_ provider: NSItemProvider) async -> NSItemProvider? {
        guard let data = await load(provider)?.data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width >= minImagePixels
        else { return nil }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let maxHeight = (width * maxImageAspect).rounded(.down)
        var cropped = image
        if height > maxHeight {
            let top = ((height - maxHeight) * 0.2).rounded(.down)
            guard let cut = image.cropping(to: CGRect(x: 0, y: top, width: width, height: maxHeight))
            else { return nil }
            cropped = cut
        }
        let maxWidth: CGFloat = drawWidth * 2
        var finalImage = cropped
        if CGFloat(cropped.width) > maxWidth {
            let scale = maxWidth / CGFloat(cropped.width)
            let tw = max(1, Int((CGFloat(cropped.width) * scale).rounded()))
            let th = max(1, Int((CGFloat(cropped.height) * scale).rounded()))
            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let ctx = CGContext(data: nil, width: tw, height: th,
                                   bitsPerComponent: 8, bytesPerRow: tw * 4,
                                   space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: tw, height: th))
                if let scaled = ctx.makeImage() { finalImage = scaled }
            }
        }
        let rep = NSBitmapImageRep(cgImage: finalImage)
        if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) {
            return NSItemProvider(item: jpeg as NSData, typeIdentifier: "public.jpeg")
        }
        guard let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return NSItemProvider(item: png as NSData, typeIdentifier: "public.png")
    }

    // MARK: Drawing

    /// The draw before the newest one. Cards are drawn one at a time: of several
    /// `LPLinkView`s created together (a reopened thread mounts all its cards
    /// at once), only one loads its icon; the rest keep the spinner and time
    /// out as the placeholder.
    private var lastDraw: Task<Void, Never>?

    private func draw(_ card: LPLinkMetadata) async -> NSImage? {
        let previous = lastDraw
        let task = Task { () -> NSImage? in
            await previous?.value
            return await self.render(card)
        }
        lastDraw = Task { _ = await task.value }
        return await task.value
    }

    /// The capture with `LPLinkView`'s own rounded corners filled in with the
    /// card's colour, taken near the middle of its bottom edge. The card is
    /// clipped to our continuous corner (`ChatBubbleChrome.cardRadius`); left
    /// in, the system's circular corner crossed that curve and showed as a cut
    /// at each corner.
    private static func filledCorners(_ rep: NSBitmapImageRep, size: CGSize) -> NSImage {
        let fallback = NSImage(size: size)
        fallback.addRepresentation(rep)
        let scale = CGFloat(rep.pixelsWide) / max(size.width, 1)
        let sampleY = max(0, rep.pixelsHigh - 1 - Int(4 * scale))
        guard let fill = rep.colorAt(x: rep.pixelsWide / 2, y: sampleY),
              fill.alphaComponent > 0.99,
              let out = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: out)
        else { return fallback }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
        let corner = 24 * scale
        fill.setFill()
        for origin in [CGPoint(x: 0, y: 0), CGPoint(x: w - corner, y: 0),
                       CGPoint(x: 0, y: h - corner), CGPoint(x: w - corner, y: h - corner)] {
            NSRect(origin: origin, size: CGSize(width: corner, height: corner)).fill()
        }
        rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero,
                 operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(out)
        return image
    }

    /// Lay `LPLinkView` out in a window that is never shown, wait until it has
    /// loaded its icon and two captures in a row match, and keep that capture.
    private func render(_ card: LPLinkMetadata) async -> NSImage? {
        let view = LPLinkView(metadata: card)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000,
                                                  width: Self.drawWidth, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        defer { window.close() }

        var previous: Data? = nil
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 60_000_000)
            let size = Self.fittingSize(view, width: Self.drawWidth)
            guard size.width > 1, size.height > 1 else { continue }
            if view.frame.size != size {
                window.setContentSize(size)
                view.frame = NSRect(origin: .zero, size: size)
            }
            view.layoutSubtreeIfNeeded()
            if Self.isLoading(view) {
                previous = nil
                continue
            }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            // The raw pixels, not `tiffRepresentation`: the capture runs up to
            // 50 times per card on the main thread, and encoding it each time
            // cost more than drawing it.
            let bytes = rep.bitmapData.map {
                Data(bytes: $0, count: rep.bytesPerRow * rep.pixelsHigh)
            }
            if bytes != nil, bytes == previous {
                return Self.filledCorners(rep, size: size)
            }
            previous = bytes
        }
        return nil
    }

    /// While it loads the icon, `LPLinkView` draws a spinner and the host in
    /// place of the card. The spinner turns in a layer animation, which a
    /// capture does not see, so two captures of it match.
    private static func isLoading(_ view: NSView) -> Bool {
        if view is NSProgressIndicator, !view.isHiddenOrHasHiddenAncestor { return true }
        return view.subviews.contains(where: isLoading)
    }

    private typealias SizeThatFits = @convention(c) (AnyObject, Selector, CGSize) -> CGSize

    /// `LPLinkView` answers `sizeThatFits:` on macOS too, but does not declare
    /// it; Auto Layout's `fittingSize` stays at a fixed default.
    private static func fittingSize(_ view: NSView, width: CGFloat) -> CGSize {
        let selector = NSSelectorFromString("sizeThatFits:")
        guard view.responds(to: selector) else { return view.fittingSize }
        let fit = unsafeBitCast(view.method(for: selector), to: SizeThatFits.self)
        let size = fit(view, selector, CGSize(width: width, height: 10_000))
        return CGSize(width: ceil(min(size.width, width)), height: ceil(size.height))
    }
}

/// Resumes its continuation with the first value it is given.
/// A page's `<head>`, read without `LPMetadataProvider`: where the page ended
/// up after redirects, its title, its preview image and its icon links.
struct PageHead: Sendable {
    var url: URL
    var title: String?
    var image: URL?
    /// Icon candidates, best first.
    var icons: [URL]

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            "Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
            "Accept-Language": Locale.preferredLanguages.prefix(3).joined(separator: ","),
        ]
        return URLSession(configuration: config)
    }()

    /// Bytes read at most; the head is almost always within the first 100 KB.
    private static let maxBytes = 512 * 1024

    static func read(_ url: URL) async -> PageHead? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }
        let final = http.url ?? url
        var data = Data()
        data.reserveCapacity(64 * 1024)
        let end = Data("</head>".utf8)
        var checked = 0
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= maxBytes { break }
                if data.count - checked >= 8 * 1024 {
                    if data.range(of: end, in: max(0, checked - end.count)..<data.count) != nil { break }
                    checked = data.count
                }
            }
        } catch {
            if data.isEmpty { return nil }
        }
        let html = decode(data, contentType: http.value(forHTTPHeaderField: "Content-Type"))
        return parse(html, base: final)
    }

    private static func decode(_ data: Data, contentType: String?) -> String {
        func charset(_ s: String) -> String? {
            guard let r = s.range(of: #"charset\s*=\s*["']?([A-Za-z0-9_\-]+)"#,
                                  options: [.regularExpression, .caseInsensitive])
            else { return nil }
            return String(s[r]).components(separatedBy: "=").last?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        let sniff = String(decoding: data.prefix(4096), as: UTF8.self)
        if let name = charset(contentType ?? "") ?? charset(sniff), name.lowercased() != "utf-8" {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId,
               let s = String(data: data, encoding: String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                return s
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func parse(_ html: String, base: URL) -> PageHead {
        let head: Substring = html.range(of: "</head>", options: .caseInsensitive)
            .map { html[..<$0.lowerBound] } ?? Substring(html)
        let text = String(head)

        var metas: [String: String] = [:]
        var links: [(rel: String, href: String, sizes: String?, type: String?)] = []
        for tag in matches(#"<(meta|link)\b[^>]*>"#, in: text) {
            let attrs = attributes(tag)
            if tag.lowercased().hasPrefix("<meta") {
                if let key = (attrs["property"] ?? attrs["name"])?.lowercased(),
                   let content = attrs["content"], metas[key] == nil {
                    metas[key] = content
                }
            } else if let rel = attrs["rel"]?.lowercased(), let href = attrs["href"] {
                links.append((rel, href, attrs["sizes"], attrs["type"]))
            }
        }

        var title = metas["og:title"] ?? metas["twitter:title"]
        if title == nil, let r = text.range(of: #"<title[^>]*>[\s\S]*?</title>"#,
                                           options: [.regularExpression, .caseInsensitive]) {
            title = String(text[r])
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        }
        title = title.map(entities)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if title?.isEmpty == true { title = nil }

        let image = (metas["og:image"] ?? metas["og:image:url"] ?? metas["twitter:image"])
            .flatMap { URL(string: entities($0), relativeTo: base)?.absoluteURL }

        func side(_ sizes: String?) -> Int {
            guard let sizes else { return 0 }
            return sizes.split(separator: " ").compactMap {
                $0.lowercased().split(separator: "x").first.flatMap { Int($0) }
            }.max() ?? 0
        }
        let ranked = links
            .filter { $0.rel.split(separator: " ").contains { $0.contains("icon") } }
            .filter { $0.rel != "mask-icon" }
            .map { link -> (URL?, Int) in
                // apple-touch-icon is 180 px when it gives no size.
                let touch = link.rel.contains("apple-touch-icon")
                let size = max(side(link.sizes), touch ? 180 : 0)
                return (URL(string: entities(link.href), relativeTo: base)?.absoluteURL, size)
            }
            .sorted { $0.1 > $1.1 }
            .compactMap(\.0)
        var icons: [URL] = []
        let fallbacks = ["/apple-touch-icon.png", "/favicon.ico"]
            .compactMap { URL(string: $0, relativeTo: base)?.absoluteURL }
        for u in ranked + fallbacks where !icons.contains(u) { icons.append(u) }
        return PageHead(url: base, title: title, image: image, icons: icons)
    }

    /// The first icon that loads and decodes, as a PNG at most 128 px a side.
    func icon() async -> Data? {
        for candidate in icons.prefix(5) {
            guard let (data, response) = try? await Self.session.data(from: candidate),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let png = Self.png(data, maxSide: 128)
            else { continue }
            return png
        }
        return nil
    }

    /// The preview image, loaded only when the card asks for it.
    func imageProvider() -> NSItemProvider? {
        guard let image else { return nil }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: "public.png", visibility: .all) { done in
            Task {
                let data = try? await Self.session.data(from: image).0
                done(data.flatMap { Self.png($0, maxSide: 1200) }, nil)
            }
            return nil
        }
        return provider
    }

    /// Any image NSImage reads (PNG, JPEG, ICO, WebP, SVG), redrawn as PNG.
    static func png(_ data: Data, maxSide: CGFloat) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        var pixels = CGSize(width: image.representations.map(\.pixelsWide).max() ?? 0,
                            height: image.representations.map(\.pixelsHigh).max() ?? 0)
        // SVG and PDF reps report no pixels; draw them at the largest size.
        if pixels.width <= 0 || pixels.height <= 0 {
            guard image.size.width > 0, image.size.height > 0 else { return nil }
            let scale = maxSide / max(image.size.width, image.size.height)
            pixels = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        }
        guard pixels.width >= 16, pixels.height >= 16 else { return nil }
        let scale = min(1, maxSide / max(pixels.width, pixels.height))
        let w = max(1, Int((pixels.width * scale).rounded()))
        let h = max(1, Int((pixels.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = CGSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    private static let attributeRegex = try? NSRegularExpression(
        pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)

    private static func attributes(_ tag: String) -> [String: String] {
        guard let regex = attributeRegex else { return [:] }
        let ns = tag as NSString
        var out: [String: String] = [:]
        for m in regex.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            for i in 2...4 where m.range(at: i).location != NSNotFound {
                out[name] = ns.substring(with: m.range(at: i))
                break
            }
        }
        return out
    }

    private static func entities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"),
                       ("&gt;", ">"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        if let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9A-Fa-f]+);"#) {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                let digits = ns.substring(with: m.range(at: 2))
                if let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    result.unicodeScalars.append(scalar)
                } else {
                    result += ns.substring(with: m.range)
                }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}

private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

    func finish(_ value: T?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

// MARK: - Pacing the bubbles

/// Paces the bubbles that follow an answer's first one, so they arrive the way
/// messages from a person do. The model sends the whole answer in one stream;
/// here each later bubble waits until it is complete, a typing bubble holds its
/// place for a beat, and then it lands. The first bubble still streams in.
///
/// State is shared per turn, not kept in the view: the panel, the detached
/// window and the panel's blurred edge copy all draw the same turn and must
/// show the same bubbles.
@MainActor
final class BubblePacer: ObservableObject {
    static let shared = BubblePacer()

    /// One bubble after the first, as the pacer sees it.
    enum Item: Equatable {
        case link(URL, title: String?)
        /// Text bubble, by its length in characters.
        case text(Int)
        /// A run of images.
        case media
    }

    /// Bumped whenever a bubble lands or the typing bubble comes or goes —
    /// the views redraw and the threads follow their tail on it.
    @Published private(set) var revision = 0

    private struct Record {
        var items: [Item] = []
        /// How many of `items` are complete and may land.
        var ready = 0
        var shown = 0
        var streaming = true
        /// When the previous bubble landed (for the first, when the first
        /// bubble finished).
        var lastLanded: Date? = nil
        /// Cards that have been drawn, by `cardKey`.
        var drawn: Set<String> = []
        /// When each card was requested, by `cardKey`.
        var requested: [String: Date] = [:]
        var timer: Task<Void, Never>? = nil
    }

    private var records: [UUID: Record] = [:]
    /// Turns whose bubbles land without the reply tone (/loop rounds).
    private var silenced: Set<UUID> = []

    /// Land this turn's bubbles without the reply tone.
    func silence(_ id: UUID) { silenced.insert(id) }

    /// Called with a bubble's index as it lands, at its tone. For a turn no view
    /// is drawing, whose bubbles arrive as cards (`NotchModel.cardStreamTick`).
    var landed: [UUID: (Int) -> Void] = [:]

    /// A card whose page is slow to load lands anyway after this long. Past
    /// `LPMetadataProvider`'s 10 s timeout, so a card lands only once drawn:
    /// a Wikipedia page takes 4–7 s to read, and landing before that played
    /// the tone over an empty bubble.
    private static let cardWaitCap: TimeInterval = 12

    /// The pause before a bubble lands, counted from the previous one: about a
    /// second before a link, a little more before text, longer for longer text.
    private static func pause(before item: Item) -> TimeInterval {
        switch item {
        case .link: return 1.0
        case .text(let length): return 0.9 + min(Double(length) / 40, 1.3)
        case .media: return 0.9
        }
    }

    /// A card as `LinkCardStore` draws it. A link that moves to another place
    /// in the answer keeps its key.
    private static func cardKey(_ url: URL, _ title: String?, _ large: Bool) -> String {
        url.absoluteString + "\u{1e}" + (title ?? "") + (large ? "\u{1e}L" : "")
    }


    /// How many bubbles after the first to draw.
    func shown(_ id: UUID, total: Int, streaming: Bool) -> Int {
        if let record = records[id] { return min(record.shown, total) }
        // Not seen yet: a live answer starts with none, a settled one (history)
        // shows everything.
        return streaming ? 0 : total
    }

    /// Whether the typing bubble is up: a bubble is on its way, or the answer is
    /// still streaming after its first bubble finished.
    func typing(_ id: UUID) -> Bool {
        guard let record = records[id], !record.items.isEmpty else { return false }
        return record.shown < record.items.count || record.streaming
    }

    func sync(_ id: UUID, items: [Item], streaming: Bool) {
        let typingBefore = typing(id)
        var record: Record
        if let existing = records[id] {
            record = existing
            // A regenerate reuses the turn and starts over.
            if streaming, items.isEmpty, existing.shown > 0 || !existing.items.isEmpty {
                existing.timer?.cancel()
                record = Record()
            }
        } else {
            // First seen settled: history, or an answer that finished while no
            // view was up. Everything is there at once.
            guard streaming else {
                records[id] = Record(items: items, ready: items.count,
                                     shown: items.count, streaming: false)
                return
            }
            record = Record()
        }

        if record.lastLanded == nil, !items.isEmpty { record.lastLanded = Date() }
        record.items = items
        record.streaming = streaming
        // The last text bubble is complete only once the stream has ended; a
        // link is complete as soon as its line is.
        if streaming, case .text = items.last {
            record.ready = items.count - 1
        } else {
            record.ready = items.count
        }
        let large = false
        for item in items {
            guard case .link(let url, let title) = item else { continue }
            let key = Self.cardKey(url, title, large)
            guard record.requested[key] == nil else { continue }
            record.requested[key] = Date()
            Task { [weak self] in
                _ = await LinkCardStore.shared.still(url: url, title: title, large: large)
                guard let self, var current = self.records[id] else { return }
                current.drawn.insert(key)
                self.records[id] = current
                self.advance(id)
            }
        }
        records[id] = record
        advance(id)
        if typing(id) != typingBefore { revision += 1 }
    }

    /// Land the next bubble if its time has come, else wait for it.
    private func advance(_ id: UUID) {
        guard var record = records[id] else { return }
        record.timer?.cancel()
        record.timer = nil
        guard record.shown < record.ready else {
            records[id] = record
            return
        }

        let index = record.shown
        let item = record.items[index]
        let now = Date()
        var due = (record.lastLanded ?? now).addingTimeInterval(Self.pause(before: item))
        // Whether the bubble shows its content the moment it lands. A card
        // landing past the cap, or images still downloading, show later, so
        // they land without the tone.
        var ready = true
        if case .media = item { ready = false }
        if case .link(let url, let title) = item {
            let key = Self.cardKey(url, title, false)
            if !record.drawn.contains(key) {
                ready = false
                // Hold for the card while the typing bubble covers the wait, but
                // not past the cap.
                let cap = (record.requested[key] ?? now).addingTimeInterval(Self.cardWaitCap)
                due = max(due, cap)
            }
        }
        guard now >= due else {
            record.timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(due.timeIntervalSince(now) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.advance(id)
            }
            records[id] = record
            return
        }
        record.shown += 1
        record.lastLanded = now
        // The next one waits its own pause from this landing.
        record.timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            self?.advance(id)
        }
        // Store the landing before publishing it. Bumping `revision` redraws
        // the thread right away (the panel scrolls to its tail on it), and that
        // draw reads `records`: published first, it drew the typing bubble
        // again and nothing drew the landed bubble until something else did,
        // well after its tone.
        records[id] = record
        // One transaction for the landing and the scroll that follows it: the
        // threads scroll to their tail on `revision`, inside this block. On
        // separate animations the scroll and the bubbles moved on different
        // curves, and the rows under the new bubble shifted by up to 14pt and
        // back while it landed.
        withAnimation(AssistantTurnView.landingSpring) { revision += 1 }
        // Each bubble plays the reply tone as it lands, like the first.
        if ready, !silenced.contains(id) { MessageTone.play(MessageTone.received) }
        landed[id]?(index)
    }
}
