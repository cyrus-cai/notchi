import AppKit
import CryptoKit
import ImageIO
import LinkPresentation
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

    static func layout(_ text: String, streaming: Bool, sources: [WebSource],
                       question: String, shared: [String] = []) -> LinkCardLayout {
        let trust = allowed(sources: sources, question: question, shared: shared)
        let mayLink = text.contains("http") || text.contains("![")
            || (streaming && text.contains("["))
            || text.range(of: "share", options: .caseInsensitive) != nil
        let mayBreak = text.contains("\n\n") || text.contains("\n \n")
        guard mayLink || mayBreak else {
            return LinkCardLayout(lead: text, rest: [])
        }
        let key = ("\(streaming ? 1 : 0)\u{1e}\(trust.pages.sorted().joined(separator: ","))"
            + "\u{1e}\(trust.hosts.sorted().joined(separator: ","))\u{1e}\(text)") as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let result = compute(text, streaming: streaming, trust: trust)
        cache.setObject(Box(result), forKey: key)
        return result
    }

    private static func compute(_ text: String, streaming: Bool,
                                trust: Trust) -> LinkCardLayout {
        let lines = text.components(separatedBy: "\n")
        // The line still being written. It is never a card yet: its URL may
        // still be growing.
        let open = streaming ? lines.count - 1 : nil

        var lead: String? = nil
        var rest: [AnswerSegment] = []
        var buffer: [String] = []
        var cards = 0
        var seen = Set<String>()
        var inFence = false
        // The last line with text in `buffer`, whether it sits in a list, and
        // whether a blank line has come after it — a paragraph break the next
        // line may turn into a new bubble.
        var lastLine: String? = nil
        var inList = false
        var pendingBreak = false

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

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if !inFence { breakBefore(line) }
                inFence.toggle()
                append(line, trimmed)
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
        if last.hasPrefix("#") { return false }
        let next = line.trimmingCharacters(in: .whitespaces)
        if inList, isListItem(next) || isIndented(line) { return false }
        return true
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
        guard let i = firstIndex(where: { $0.id == answerID }) else { return "" }
        return self[..<i].last(where: { $0.role == "user" })?.text ?? ""
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

    @State private var still: NSImage?

    init(url: URL, title: String?, large: Bool = false) {
        self.url = url
        self.title = title
        self.large = large
        _still = State(initialValue: LinkCardStore.cachedStill(url: url, title: title, large: large))
    }

    var body: some View {
        FractionWidthLayout(fraction: AnswerCard<EmptyView>.widthFraction, hugs: true) {
            if let still {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(nsImage: still)
                        .resizable()
                        .aspectRatio(still.size, contentMode: .fit)
                        .frame(maxWidth: still.size.width)
                        .clipShape(RoundedRectangle(cornerRadius: ChatBubbleChrome.cardRadius,
                                                    style: .continuous))
                }
                .buttonStyle(.plain)
                .help(url.absoluteString)
                .transition(.opacity)
            }
        }
        .task(id: "\(large)\u{1e}\(url.absoluteString)\u{1e}\(title ?? "")") {
            if let hit = LinkCardStore.cachedStill(url: url, title: title, large: large) {
                if still !== hit { still = hit }
                return
            }
            if still == nil,
               let loading = await LinkCardStore.shared.loadingStill(url: url, title: title) {
                withAnimation(.easeOut(duration: 0.18)) { still = loading }
            }
            if let final = await LinkCardStore.shared.still(url: url, title: title, large: large) {
                withAnimation(.easeOut(duration: 0.18)) { still = final }
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
    private var drawing: [String: Task<NSImage?, Never>] = [:]

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
        let key = (url.absoluteString + "\u{1e}" + (title ?? "") + "\u{1e}P") as NSString
        if let hit = Self.stills.object(forKey: key) { return hit }
        let image = await draw(placeholder(url: url, title: title))
        if let image { Self.stills.setObject(image, forKey: key) }
        return image
    }

    /// Cards whose finished still could not be drawn this session. They keep
    /// the loading card instead of drawing again on every mount.
    private var failed: Set<String> = []

    /// The finished card. Falls back to the loading card when the page
    /// cannot be read.
    func still(url: URL, title: String?, large: Bool) async -> NSImage? {
        let key = Self.key(url, title, large)
        if let hit = Self.stills.object(forKey: key) { return hit }
        if failed.contains(key as String) { return nil }
        if let running = drawing[key as String] { return await running.value }
        let task = Task { () -> NSImage? in
            let fetched = await self.pageMetadata(url)
            let local = Self.mapsDetails(url)
            let card = LPLinkMetadata()
            card.originalURL = url
            card.url = fetched?.url ?? url
            card.title = fetched?.title ?? title ?? local?.title
            // A preview image switches `LPLinkView` to its tall layout; the
            // compact form carries the icon only.
            if large, let image = fetched?.imageProvider,
               let preview = await Self.previewImage(image) {
                card.iconProvider = fetched?.iconProvider
                card.imageProvider = preview
            } else {
                card.iconProvider = fetched?.iconProvider ?? fetched?.imageProvider
                    ?? local?.icon
            }
            return await self.draw(card)
        }
        drawing[key as String] = task
        let image = await task.value
        drawing[key as String] = nil
        if let image {
            Self.stills.setObject(image, forKey: key)
        } else {
            failed.insert(key as String)
        }
        return image
    }

    private func placeholder(url: URL, title: String?) -> LPLinkMetadata {
        let local = Self.mapsDetails(url)
        let card = LPLinkMetadata()
        card.originalURL = url
        card.url = url
        card.title = title ?? local?.title
        card.iconProvider = local?.icon
        return card
    }

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
    private static func fetch(_ url: URL) async -> LPLinkMetadata? {
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
        guard let data = try? Data(contentsOf: recordURL(url)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == recordVersion
        else { return nil }
        return metadata(from: record, original: url)
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
    /// `maxImageAspect` tall, or nil when it is too small to show large.
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
        guard let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
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
                let image = NSImage(size: size)
                image.addRepresentation(rep)
                return image
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

    /// An answer's only card is drawn large.
    private static func isLarge(_ items: [Item]) -> Bool {
        items.filter {
            if case .link = $0 { return true }
            return false
        }.count == 1
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
        let large = Self.isLarge(items)
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
            let key = Self.cardKey(url, title, Self.isLarge(record.items))
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
        revision += 1
        // Each bubble plays the reply tone as it lands, like the first.
        if ready, !silenced.contains(id) { MessageTone.play(MessageTone.received) }
    }
}
