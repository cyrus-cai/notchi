import AppKit
import SwiftUI

/// The top-right card as a chat that hangs under the menu bar icon: no panel
/// around it, each message its own bubble of the floating card's glass, and under them
/// the island's own prompt in the same glass, with its bottom row under the pointer
/// (`NotchBody` with `composerOnly`). The conversation on screen is the thread being
/// read, or on the idle page the main thread, so a line sent from here lands
/// under the messages already showing. Older messages scroll up and fade out at
/// the top edge.
///
/// Settings, What's New, Recent and the agent pages keep the card's panel (see
/// `takesOver`).
struct MenuBarChat: View {
    @ObservedObject var model: NotchModel
    let isOpen: Bool

    /// Whether this view draws the card for what the model shows now. Recent
    /// and What's New open in their own windows from here (`openPagesInWindows`),
    /// so they never take the card.
    static func takesOver(_ model: NotchModel) -> Bool {
        !model.showSettings && model.agentDetailTaskID == nil && !model.agentComposeActive
    }

    /// The messages scroll past this height.
    static let maxMessagesHeight: CGFloat = 440
    /// The fade older messages scroll into, under the menu bar.
    private static let topFade: CGFloat = 36
    /// Room under the last message while the messages scroll, so it rests
    /// clear of most of `bottomBlur`.
    private static let bottomFade: CGFloat = 18
    /// The band above the composer where scrolling messages blur out.
    private static let bottomBlur: CGFloat = 28
    /// How far the scrolling messages run on under the composer: the gap
    /// above it plus the depth of its rounded corners, so no strip of
    /// backdrop shows between the two and a message blurs on behind it.
    private static let composerOverlap: CGFloat = 10 + 24
    private static let bubbleGap: CGFloat = 8
    /// Space kept around the bubbles inside the scroll view for the glass's
    /// edge to draw into.
    private static let glassGutter: CGFloat = 6
    private static let bottomID = "menuBarChat.bottom"
    private static let topID = "menuBarChat.top"
    /// The widest a bubble gets, as a share of the column. The composer is as
    /// wide, so the column has one right edge.
    private static let bubbleWidthFraction: CGFloat = 0.86

    /// The messages' height, unpadded.
    @State private var contentHeight: CGFloat = 0
    /// The messages have outgrown `maxMessagesHeight` for this thread. Held
    /// once true, so the lazy list's height estimates, which shift as rows
    /// scroll into view, stop resizing the scroll view and re-rendering the
    /// card mid-scroll.
    @State private var overflowLatched = false
    /// Bumped on each open, to put the messages back at their end.
    @State private var endRequest = 0
    /// The messages are scrolled to their end. A streaming answer keeps them
    /// there only while they are.
    @State private var scroll = ChatScrollEnd()
    /// `scroll.atBottom` as view state, for the size-change anchor. It changes
    /// only when the reader leaves or returns to the end.
    @State private var followsEnd = true
    @State private var recentCardsCache = RecentCardsCache()
    /// 0 folded up into the menu bar icon, 1 unfolded. Driven on open and on
    /// `cardRetracting`.
    @State private var revealed = false
    /// Underdamped, so the card overshoots its rest size and settles back.
    static let unfoldSpring = Animation.spring(response: 0.5, dampingFraction: 0.6)
    /// The pointer is over the composer: its bottom row shows.
    @State private var composerHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - What is shown

    /// The thread on screen, else the main thread.
    private var thread: [NotchModel.Turn] {
        if !model.turns.isEmpty { return model.turns }
        guard let peek = model.mainThreadPeek else { return [] }
        return peek.live ?? peek.item.conversation
    }

    /// The messages to draw: the whole thread, without the turns the panel
    /// does not draw as bubbles either.
    private var shownTurns: [NotchModel.Turn] {
        thread.filter { turn in
            turn.example == nil && !(turn.role == "user" && turn.hidesUserBubble)
        }
    }

    /// The thread is the one `model.turns` holds, so its messages take actions.
    private var onScreen: Bool { !model.turns.isEmpty }

    private var overflows: Bool { overflowLatched || contentHeight > Self.maxMessagesHeight }

    // MARK: - Body

    var body: some View {
        let turns = shownTurns
        VStack(alignment: .leading, spacing: 10) {
            if !turns.isEmpty {
                messages(turns)
                    .padding(.bottom, overflows ? -Self.composerOverlap : 0)
                    .transition(.opacity)
                    .transaction(stillWhileClosed)
            }
            if let feedback = noteFeedback {
                feedbackBubble(feedback)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
                    .transaction(stillWhileClosed)
            }
            composer
        }
        .frame(width: NotchMetrics.chatWidth)
        .modifier(UnfoldFromTop(progress: revealed ? 1 : 0, reduceMotion: reduceMotion))
        .padding(.top, NotchMetrics.chatTopGap)
        .environment(\.chatBubbleGlass, true)
        .environment(\.cardWidthFraction, Self.bubbleWidthFraction)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: turns.count)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: noteFeedback)
        .onAppear {
            if isOpen { opened() }
        }
        .onChange(of: isOpen) { _, open in
            if open {
                openPagesInWindows()
                opened()
            } else {
                var quiet = Transaction()
                quiet.disablesAnimations = true
                withTransaction(quiet) { revealed = false }
            }
        }
        .onAppear { openPagesInWindows() }
        .onChange(of: model.showHistory) { _, _ in openPagesInWindows() }
        .onChange(of: model.showWhatsNew) { _, _ in openPagesInWindows() }
        .onChange(of: model.cardRetracting) { _, retracting in
            if retracting {
                withAnimation(.easeIn(duration: NotchModel.cardFlightDuration * 0.9)) {
                    revealed = false
                }
            } else if isOpen, !revealed {
                // A reopen turned the fold back: unfold from where it is.
                withAnimation(Self.unfoldSpring) { revealed = true }
            }
        }
    }

    /// While the card is closed the thread under it can change (a new chat,
    /// the main thread taking over). Those changes land without animation: a
    /// fade-in started in a hidden window can stay at its first frame, and the
    /// messages then open laid out but invisible.
    private func stillWhileClosed(_ transaction: inout Transaction) {
        guard !isOpen else { return }
        transaction.animation = nil
        transaction.disablesAnimations = true
    }

    private func opened() {
        if model.mode == .idle, model.turns.isEmpty {
            model.attachLiveMainThreadRound()
        }
        scroll.atBottom = true
        endRequest += 1
        unfold()
    }

    /// Recent and What's New, asked for from the card (its ⋯ menu, ↓ on the
    /// prompt, the menu bar menu), open in their own windows.
    private func openPagesInWindows() {
        // The card's view stays mounted while the card is closed; the island's
        // own Recent and What's New pages are not this view's to move.
        guard isOpen else { return }
        if model.showHistory {
            model.showHistory = false
            HistoryArchiveWindowController.shared.present(model: model)
        }
        if model.showWhatsNew {
            model.showWhatsNew = false
            WhatsNewWindowController.shared.present(model: model)
        }
    }

    /// Unfold down out of the menu bar icon, from folded.
    private func unfold() {
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { revealed = false }
        DispatchQueue.main.async {
            withAnimation(Self.unfoldSpring) { revealed = true }
        }
    }


    // MARK: - Messages

    private func messages(_ turns: [NotchModel.Turn]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
              VStack(spacing: 0) {
                Color.clear.frame(height: 0).id(Self.topID)
                // Lazy: a long thread builds only the messages near the
                // viewport.
                // Keyed by id alone: diffing `[Turn]` compared every message's
                // full text on each update, which froze long threads for
                // seconds mid-scroll.
                let thread = self.thread
                let byID = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let index = Dictionary(thread.enumerated().map { ($1.id, $0) },
                                       uniquingKeysWith: { _, b in b })
                let lastID = turns.last?.id
                LazyVStack(alignment: .leading, spacing: Self.bubbleGap) {
                    ForEach(turns.map(\.id), id: \.self) { id in
                        if let turn = byID[id] {
                            ChatRow(turn: turn, model: model,
                                    isLast: id == thread.last?.id,
                                    question: index[id].map { thread.question(at: $0) } ?? "",
                                    recentCards: turn.role == "assistant"
                                        ? recentCardsCache.cards(for: turn, at: index[id], in: thread,
                                                                 fresh: id == lastID)
                                        : [],
                                    onScreen: onScreen,
                                    live: turn.streaming ? model.chatLiveStatus : nil,
                                    streamingNow: id == lastID && model.isStreaming,
                                    askFailed: id == lastID && model.visibleAskError != nil)
                                .equatable()
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    // Any growth (streamed text, a settled answer's layout,
                    // cards) keeps the end in view while the reader is there.
                    if overflowLatched {
                        if scroll.atBottom { scrollToEnd(proxy, animated: false) }
                        return
                    }
                    if height > Self.maxMessagesHeight {
                        overflowLatched = true
                        // The scroll view just took its capped height: put the
                        // end back in view.
                        if scroll.atBottom { endRequest += 1 }
                    } else if height != contentHeight {
                        contentHeight = height
                    }
                }
                .padding(.top, overflows ? Self.topFade : 0)
                .padding(.bottom, overflows ? Self.bottomFade + Self.composerOverlap : 0)
                Color.clear.frame(height: 0).id(Self.bottomID)
              }
              // Room for the glass's lit edge, which the scroll view would
              // otherwise cut flat at the column's sides.
              .padding(.horizontal, Self.glassGutter)
              .padding(.vertical, overflows ? 0 : Self.glassGutter)
            }
            // A new thread gets a new scroll view, so no offset from the last
            // one carries over.
            .id(turns.first?.id)
            .modifier(OpensAtEnd(followsEnd: followsEnd))
            .scrollDisabled(!overflows)
            .modifier(TrackScrollEnd(position: scroll) { end in
                if followsEnd != end { followsEnd = end }
            })
            .frame(height: overflows ? Self.maxMessagesHeight + Self.composerOverlap
                   : contentHeight + Self.glassGutter * 2)
            .mask(fadeMask)
            // Messages scrolling down toward the composer blur out instead of
            // fading to clear.
            .overlay(alignment: .bottom) {
                if overflows {
                    BackdropBlur(radius: 14)
                        .frame(height: Self.bottomBlur + Self.composerOverlap)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, -Self.glassGutter)
            .padding(.vertical, overflows ? 0 : -Self.glassGutter)
            // The gaps between bubbles take the wheel too, instead of passing
            // it to the window underneath, and a right-click.
            .background(Color.black.opacity(0.001).contextMenu { chatMenu })
            // A new message (one sent, or the answer starting) always brings
            // the end into view, even after a scroll up.
            .onChange(of: turns.last?.id) { _, _ in
                scroll.atBottom = true
                scroll.pinnedUntil = Date().addingTimeInterval(0.8)
                scrollToEnd(proxy, animated: true)
                // Again once the new message has laid out: the lazy list's
                // estimate of its height stops the first scroll short.
                for delay in [0.15, 0.4, 0.75] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        scrollToEnd(proxy, animated: false)
                    }
                }
            }
            // A streaming answer and a settled one that changed keep the end
            // in view, unless the reader has scrolled up.
            .onReceive(model.liveAnswer.$text) { _ in
                if scroll.atBottom { scrollToEnd(proxy, animated: false) }
            }
            .onChange(of: turns.last?.text) { _, _ in
                if scroll.atBottom { scrollToEnd(proxy, animated: false) }
            }
            .onChange(of: endRequest) { _, _ in scrollToEnd(proxy, animated: false) }
            // Another thread on screen: measure it afresh.
            .onChange(of: turns.first?.id) { _, _ in
                overflowLatched = false
                contentHeight = 0
                recentCardsCache.clear()
                scroll.atBottom = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { endRequest += 1 }
            }
            .onAppear {
                scrollToEnd(proxy, animated: false)
                // Again once the answers' text has laid out.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    scrollToEnd(proxy, animated: false)
                }
            }
        }
    }

    /// Messages that fit are not scrolled: the scroll view is disabled then,
    /// so an offset it was given would never be taken back, and the messages
    /// would sit out of view. They are held at the top instead.
    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            guard overflows else {
                proxy.scrollTo(Self.topID, anchor: .top)
                return
            }
            if animated {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var fadeMask: some View {
        if overflows {
            GeometryReader { geo in
                let h = max(geo.size.height, 1)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: Self.topFade / h),
                        // The bottom fades out behind the composer, so a
                        // message is never cut off by the column's edge.
                        .init(color: .black, location: 1 - Self.composerOverlap / h),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom)
            }
        } else {
            Color.black
        }
    }

    // MARK: - Note feedback

    /// What a line sent to Notes or Reminders did, as a message from Notchi.
    private var noteFeedback: String? {
        if let error = model.noteError { return error }
        if let cue = model.lastSavedNote { return cue }
        if model.noteSaving { return L("input.saving") }
        return nil
    }

    private func feedbackBubble(_ text: String) -> some View {
        AnswerCard {
            Text(text)
                .sfFont(Tokens.TypeSize.stepDown(Tokens.TypeSize.reading))
                .foregroundStyle(model.noteError != nil ? Tokens.text1 : Tokens.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Composer

    /// The island's prompt and bottom row, in the floating card's glass.
    private var composer: some View {
        let shape = NotchShape(bottomRadius: Tokens.Radius.shell,
                               topCornerRadius: Tokens.Radius.shell)
        return NotchBody(model: model, composerOnly: true, showsBottomRow: composerHovering)
            .background(GlassMaterial(bottomRadius: Tokens.Radius.shell,
                                      topCornerRadius: Tokens.Radius.shell,
                                      expanded: true,
                                      cameraZone: 0,
                                      sweepsOnOpen: false,
                                      floating: true))
            .clipShape(shape)
            .overlay(IslandRim(shape: shape))
            .contentShape(shape)
            .contextMenu { chatMenu }
            .onHover { hovering in
                withAnimation(.easeOut(duration: Tokens.hoverFade)) { composerHovering = hovering }
            }
            .frame(width: NotchMetrics.chatWidth * Self.bubbleWidthFraction)
    }
}

// MARK: - Menu

extension MenuBarChat {
    /// Right-click on the chat (between the messages, or on the composer's
    /// edge): what the island's header and its ⋯ cluster hold, which this card
    /// draws no chrome for.
    @ViewBuilder
    var chatMenu: some View {
        Button(L("shortcuts.newChat")) {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { model.newChat() }
        }
        .disabled(model.turns.isEmpty)
        Button(Self.bare(L("menuBar.history"))) { model.showHistory = true }
        if !model.turns.isEmpty {
            Button(Self.bare(L(model.isAnswerPinned ? "result.unpin" : "result.pin"))) {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    model.toggleAnswerPin()
                }
            }
            if NotchModel.detachedWindowsEnabled {
                Button(Self.bare(L("detached.open"))) { model.openDetachedWindow() }
            }
        }
        Divider()
        Button(Self.bare(L("menuBar.settings"))) { model.openSettings() }
        Button(L("menuBar.whatsNew")) { model.showWhatsNew = true }
    }

    /// A menu title without its trailing "…" or "(⌘P)" shortcut note.
    static func bare(_ title: String) -> String {
        var base = title
        for (open, close) in [("(", ")"), ("（", "）")] where base.hasSuffix(close) {
            if let i = base.range(of: open, options: .backwards) {
                base = String(base[..<i.lowerBound])
            }
        }
        base = base.trimmingCharacters(in: .whitespaces)
        if base.hasSuffix("…") { base.removeLast() }
        return base
    }
}

// MARK: - Pieces

/// One message. Equatable on what it draws, so a model update elsewhere (the
/// pointer entering, a clipboard read) does not rebuild every answer's text,
/// which is what stalled the first frame of a scroll. Its closures reach the
/// model by reference and need no comparing.
private struct ChatRow: View, Equatable {
    let turn: NotchModel.Turn
    let model: NotchModel
    /// The thread's last message.
    let isLast: Bool
    /// The user's words this answer replies to, and the link cards shown just
    /// before it (`AssistantTurnView.question`, `.recentCards`).
    let question: String
    let recentCards: Set<String>
    let onScreen: Bool
    /// The round's wait state, for the answer still streaming only.
    let live: ChatLiveStatus?
    /// For the last message: an answer is streaming, or the round failed.
    let streamingNow: Bool
    let askFailed: Bool

    static func == (a: ChatRow, b: ChatRow) -> Bool {
        a.turn == b.turn && a.onScreen == b.onScreen && a.live == b.live
            && a.streamingNow == b.streamingNow && a.askFailed == b.askFailed
            && a.isLast == b.isLast && a.question == b.question
            && a.recentCards == b.recentCards
    }

    var body: some View {
        if turn.role == "user" {
            VStack(alignment: .leading, spacing: 5) {
                if !turn.imageFiles.isEmpty {
                    SavedTurnImages(files: turn.imageFiles)
                }
                UserQuestionBubble(text: turn.text, isAgent: turn.isAgent,
                                   reaction: turn.reaction, fromTelegram: turn.fromTelegram)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            assistantRow
        }
    }

    private var assistantRow: some View {
        let canRegenerate = onScreen && isLast && !turn.isAgent && !streamingNow && !askFailed
        return LiveText(live: turn.streaming ? model.liveAnswer : .inert,
                        id: turn.id, fallback: turn.text) { text in
            AssistantTurnView(
                text: text,
                streaming: turn.streaming,
                activity: turn.streaming ? (turn.toolActivity ?? live?.activity) : nil,
                orbState: turn.streaming
                    ? (turn.thinkingOrbState ?? live?.orb ?? .composing) : .composing,
                thinkingWord: turn.thinkingWord ?? live?.word ?? "",
                thinkingSince: turn.streaming
                    ? (turn.thinkingStartedAt ?? live?.since) : nil,
                sources: turn.sources,
                isAgent: turn.isAgent,
                showsFooterMetadata: !turn.isAgent,
                onInAppCopy: { model.rebaselineClipboardAfterInAppWrite() },
                onRegenerate: canRegenerate ? { model.regenerateLastAnswer() } : nil,
                regenerateModels: canRegenerate ? model.regenerateModelOptions : [],
                onRegenerateWith: canRegenerate ? { model.regenerateLastAnswer(model: $0) } : nil,
                regenModel: turn.regenModel,
                answerModel: turn.answerModel,
                agentTrail: turn.isAgent
                    ? (turn.agentLog?.droppingTrailingAnswer(text) ?? []) : [],
                pendingQuestion: turn.streaming
                    ? (turn.pendingQuestion ?? model.pendingQuestion(for: turn.id)) : nil,
                onChooseOption: { questionID, option in
                    model.chooseUserOption(option, questionID: questionID)
                },
                onContinue: onScreen && turn.interrupted && isLast && !streamingNow
                    ? { model.continueAnswer(turnID: turn.id) } : nil,
                question: question,
                sharedLinks: turn.sharedLinks,
                recentCards: recentCards,
                captures: turn.captures,
                usedCloudMachine: turn.usedCloudMachine,
                folders: turn.folders,
                onOpenCapture: { model.openTurnCapture($0) },
                onUndoCapture: { model.undoTurnCapture($0) },
                turnID: turn.id)
        }
    }
}

/// The chat unfolding down out of the menu bar icon: it grows down from its
/// top edge while it drops into place and fades in. The spring overshoots, so
/// the card stretches past its height and springs back. At rest it is the
/// plain view, with no mask or offscreen pass left on the glass. Reduce Motion
/// fades instead.
private struct UnfoldFromTop: ViewModifier, Animatable {
    var progress: CGFloat
    let reduceMotion: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = max(0, progress)
        content
            .scaleEffect(x: reduceMotion ? 1 : 0.92 + 0.08 * p,
                         y: reduceMotion ? 1 : 0.55 + 0.45 * p, anchor: .top)
            .offset(y: reduceMotion ? 0 : -30 * (1 - p))
            .opacity(Double(min(1, p * 1.6)))
    }
}

/// An answer's text: the live store's while it streams, else the turn's own.
private struct LiveText<Content: View>: View {
    @ObservedObject var live: LiveAnswerText
    let id: UUID
    let fallback: String
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        content(live.id == id ? live.text : fallback)
    }
}

/// The messages open at their end, and while the reader is at the end every
/// size change (an answer streaming, a tool's results, a settled answer's
/// layout) keeps the bottom in place. Once the reader scrolls up, size changes
/// keep the top in place instead, so a scroll up is not pushed back. macOS 14
/// has no per-role anchor.
private struct OpensAtEnd: ViewModifier {
    let followsEnd: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(followsEnd ? .bottom : nil, for: .sizeChanges)
        } else {
            content.defaultScrollAnchor(.bottom)
        }
    }
}

/// Each answer's `recentCards`, kept per message. Working them out parses the
/// links of the messages before it, and doing that for every row on every
/// rebuild of the list was most of the time a scroll froze for. A settled
/// answer's set does not change; the last one is worked out afresh.
private final class RecentCardsCache {
    private var cards: [UUID: Set<String>] = [:]

    func cards(for turn: NotchModel.Turn, at index: Int?, in thread: [NotchModel.Turn],
               fresh: Bool) -> Set<String> {
        guard let index else { return [] }
        if !fresh, let known = cards[turn.id] { return known }
        let value = thread.recentCards(at: index)
        cards[turn.id] = value
        return value
    }

    func clear() { cards = [:] }
}

/// Whether the messages sit at their end. A plain reference, not view state:
/// it flips each time a scroll turns from up to down, and as state that
/// re-rendered the whole card at that moment.
private final class ChatScrollEnd {
    var atBottom = true
    /// Until this time, the messages are held at their end whatever the
    /// geometry reports: a new message grows the content before the scroll to
    /// it runs, and that growth reads as "scrolled up".
    var pinnedUntil = Date.distantPast
    var pinned: Bool { Date() < pinnedUntil }
    /// The reader's finger or wheel is moving the messages.
    var userScrolling = false
}

private struct ScrollSample: Equatable {
    var offset: CGFloat
    var end: Bool
}

/// Keeps `ChatScrollEnd` current, so a growing answer only follows when the
/// reader has not scrolled up. Without the scroll geometry API the answer
/// always follows.
private struct TrackScrollEnd: ViewModifier {
    let position: ChatScrollEnd
    var changed: (Bool) -> Void = { _ in }

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: ScrollSample.self) { geo in
                ScrollSample(offset: geo.contentOffset.y,
                             end: geo.contentOffset.y + geo.containerSize.height
                                 >= geo.contentSize.height - 24)
            } action: { _, new in
                // Only the reader's own scroll lets go of the end. Content
                // growing or shrinking under the offset (an answer streaming,
                // settling, a message laying out) is not the reader leaving.
                if new.end || position.pinned {
                    position.atBottom = true
                } else if position.userScrolling {
                    position.atBottom = false
                }
                changed(position.atBottom)
            }
            .onScrollPhaseChange { _, phase in
                position.userScrolling = phase == .interacting || phase == .decelerating
                    || phase == .tracking
            }
        } else {
            content
        }
    }
}

/// The wait line's state for the answer still streaming (`ChatRow.live`).
struct ChatLiveStatus: Equatable {
    var activity: String?
    var orb: OrbState
    var word: String
    var since: Date?
}

extension NotchModel {
    var chatLiveStatus: ChatLiveStatus {
        ChatLiveStatus(activity: currentActivity, orb: thinkingOrbState,
                       word: currentThinkingWord, since: thinkingStartedAt)
    }
}

/// A blur of what the window draws under it, and nothing else: where no
/// message is underneath, it stays clear. The blur is none at the top edge and
/// `radius` at the bottom (a variable blur driven by a gradient mask image), so
/// the band has no edge of its own. A backdrop layer with a blur filter;
/// neither has public API on macOS. A SwiftUI `.mask` does not reach a
/// backdrop layer, so the gradient is set on the layer itself.
private struct BackdropBlur: NSViewRepresentable {
    var radius: CGFloat

    func makeNSView(context: Context) -> BackdropBlurView { BackdropBlurView(radius: radius) }
    func updateNSView(_ view: BackdropBlurView, context: Context) {}
}

private final class BackdropBlurView: NSView {
    private let radius: CGFloat
    /// The filter is a variable blur (`inputMaskImage`), or a plain Gaussian
    /// when the system has no variable blur; the plain one is faded in by a
    /// gradient mask on the layer instead.
    private var variable = false
    private var maskedHeight: CGFloat = -1

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer {
        guard let backdrop = NSClassFromString("CABackdropLayer") as? CALayer.Type else {
            return CALayer()
        }
        let layer = backdrop.init()
        if let filter = Self.filter("variableBlur") {
            filter.setValue(radius, forKey: "inputRadius")
            filter.setValue(true, forKey: "inputNormalizeEdges")
            filter.setValue(Self.rampImage(), forKey: "inputMaskImage")
            layer.filters = [filter]
            variable = true
        } else if let filter = Self.filter("gaussianBlur") {
            filter.setValue(radius, forKey: "inputRadius")
            filter.setValue(true, forKey: "inputNormalizeEdges")
            layer.filters = [filter]
        }
        return layer
    }

    override func layout() {
        super.layout()
        guard let layer, bounds.height != maskedHeight else { return }
        maskedHeight = bounds.height
        // The fade of the band itself: clear at the top, whole at the bottom.
        let gradient = CAGradientLayer()
        gradient.frame = layer.bounds
        gradient.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        gradient.locations = variable ? [0, 0.35] : [0, 1]
        // AppKit layers are flipped relative to the gradient's unit space.
        gradient.startPoint = CGPoint(x: 0.5, y: layer.contentsAreFlipped() ? 0 : 1)
        gradient.endPoint = CGPoint(x: 0.5, y: layer.contentsAreFlipped() ? 1 : 0)
        layer.mask = gradient
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static func filter(_ type: String) -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as AnyObject as? NSObjectProtocol else {
            return nil
        }
        return filterClass.perform(NSSelectorFromString("filterWithType:"), with: type)?
            .takeUnretainedValue() as? NSObject
    }

    /// The variable blur's strength, top to bottom: alpha 0 is no blur, alpha
    /// 1 is `radius`. The filter stretches it over the layer.
    private static func rampImage() -> CGImage? {
        let height = 64
        guard let context = CGContext(data: nil, width: 1, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: [CGColor(red: 0, green: 0, blue: 0, alpha: 0),
                                                 CGColor(red: 0, green: 0, blue: 0, alpha: 1)] as CFArray,
                                        locations: [0, 1])
        else { return nil }
        // CoreGraphics' origin is the bottom: draw full strength there.
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: CGFloat(height)),
                                   end: .zero, options: [])
        return context.makeImage()
    }
}
