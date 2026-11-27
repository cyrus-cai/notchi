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
/// Agent compose draws here too, as the prompt alone. An agent task's detail
/// page keeps the card's panel (see `takesOver`).
struct MenuBarChat: View {
    @ObservedObject var model: NotchModel
    let isOpen: Bool

    /// Whether this view draws the card for what the model shows now. Recent
    /// and What's New open in their own windows from here (`openPagesInWindows`),
    /// and so does Settings (`openSettings`), so none of them take the card.
    static func takesOver(_ model: NotchModel) -> Bool {
        model.agentDetailTaskID == nil
    }

    /// The messages scroll past this height.
    static let maxMessagesHeight: CGFloat = 220
    /// The messages' second height. A pull down at the end of the list opens
    /// it, a swipe up at the end closes it (`ChatHeightPull`). At rest the
    /// messages take one of the two heights, never one in between.
    static let expandedMessagesHeight: CGFloat = 440
    /// The fade older messages scroll into, under the menu bar.
    private static let topFade: CGFloat = 36
    /// Room under the last message while the messages scroll. None: the
    /// column's own 10pt gap is the only space above the composer.
    private static let bottomFade: CGFloat = 0
    /// The band above the composer where scrolling messages blur out. No
    /// taller than the gap, so the resting last message stays sharp.
    private static let bottomBlur: CGFloat = 10
    /// How far the scrolling messages run on under the composer: the gap
    /// above it plus the depth of its rounded corners, so no strip of
    /// backdrop shows between the two and a message blurs on behind it.
    private static let composerOverlap: CGFloat = 10 + 24
    private static let bubbleGap: CGFloat = 8
    /// Space kept around the bubbles inside the scroll view for the glass's
    /// edge to draw into.
    static let glassGutter: CGFloat = 6
    private static let bottomID = "menuBarChat.bottom"
    private static let topID = "menuBarChat.top"
    /// The widest a bubble gets, as a share of the column. The composer is as
    /// wide, so the column has one right edge.
    private static let bubbleWidthFraction: CGFloat = 0.86
    /// The column's width right of the bubbles.
    static var trailingSlack: CGFloat { NotchMetrics.chatWidth * (1 - bubbleWidthFraction) }
    /// The chat sets its messages one size under the panel's (`baseFont`).
    static let baseFont: CGFloat = Tokens.TypeSize.form
    /// The size message text ends up in, and the prompt with it.
    static let answerFont: CGFloat = Tokens.TypeSize.stepDown(baseFont)
    /// An answer paragraph's line spacing (`baseFont * 0.6` in the markdown view).
    static let answerLineSpacing: CGFloat = answerFont * 0.6

    /// The messages' height, unpadded.
    @State private var contentHeight: CGFloat = 0
    /// The composer's height, so the messages leave it room in the canvas.
    @State private var composerHeight: CGFloat = 0

    /// The messages' cap: `maxMessagesHeight`, or less when a tall composer
    /// would otherwise push the card past the canvas's bottom edge.
    private var messagesCap: CGFloat {
        let room = NotchMetrics.canvasHeight - NotchMetrics.chatTopGap - 10 - shownComposerHeight - 12
        return max(120, min(Self.maxMessagesHeight, room))
    }
    /// The messages' taller height (`expandedMessagesHeight`).
    private var expandedCap: CGFloat {
        let room = NotchMetrics.canvasHeight - NotchMetrics.chatTopGap - 10 - shownComposerHeight - 12
        return max(messagesCap, min(Self.expandedMessagesHeight, room))
    }
    private var shownComposerHeight: CGFloat { showsComposer ? composerHeight : 0 }
    /// A card unfolded for a reply shows its composer once the pointer is over it.
    private var showsComposer: Bool {
        // The side pages (Routines, Sub-thread, Websites) take no message.
        if model.showRoutines { return false }
        return !model.replyOnly || model.replyComposerShown
    }
    /// The messages have outgrown `maxMessagesHeight` for this thread. Held
    /// once true, so the lazy list's height estimates, which shift as rows
    /// scroll into view, stop resizing the scroll view and re-rendering the
    /// card mid-scroll.
    @State private var overflowLatched = false
    /// Between the two heights: 0 `messagesCap`, 1 `expandedCap`.
    @StateObject private var heightPull = ChatHeightPull()
    /// The messages' AppKit scroll view, held at its end while the height
    /// moves.
    @State private var scrollRef = MessagesScrollRef()
    /// Bumped on each open, to put the messages back at their end.
    @State private var endRequest = 0
    /// The messages are scrolled to their end. A streaming answer keeps them
    /// there only while they are.
    @State private var scroll = ChatScrollEnd()
    /// The visible part of each message list, for `CullsOffscreenGlass`.
    @StateObject private var glassViewport = GlassCullViewport()
    /// `scroll.atBottom` as view state, for the size-change anchor. It changes
    /// only when the reader leaves or returns to the end.
    @State private var followsEnd = true
    @State private var recentCardsCache = RecentCardsCache()
    /// The oldest message mounted. A long thread opens with its newest
    /// `mountBatch`; scrolling to the top mounts the next batch above. Back to
    /// one batch on each open and on a thread change.
    ///
    /// An id, not a count of the newest: counted from the end, every message
    /// sent pushed the two oldest out of the list. The lazy list then took
    /// their height off its own while the scroll offset stayed, and the
    /// messages left the viewport until the next scroll to the end.
    @State private var mountedFromID: UUID?
    static let mountBatch = 24
    /// The card is drawn. False while it is closed, so the window comes up
    /// empty and `fold` unfolds the card into it.
    @State private var revealed = false
    /// The fold down out of the menu bar icon and back up into it.
    @State private var fold = CardFold()
    /// The pointer is over the composer: its bottom row shows.
    @State private var composerHovering = false
    /// Redraws the header when the cloud machine turns on or off (its ⋯).
    @ObservedObject private var cloudAccount = InstaBoxAccount.shared
    /// The header's side-page mark has its menu down.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    // MARK: - What is shown

    /// Sub-thread is open: the copy thread takes the messages' place and is
    /// drawn by the same `messages`.
    private var showsCopies: Bool { false }

    /// The thread on screen, else the main thread; the copy thread while
    /// Sub-thread is open.
    private var thread: [NotchModel.Turn] {
        if showsCopies { return model.copyThreadConversation }
        if !model.turns.isEmpty { return model.turns }
        guard let peek = model.mainThreadPeek else { return [] }
        return peek.live ?? peek.item.conversation
    }

    /// The messages to draw: the whole thread, without the turns the panel
    /// does not draw as bubbles either.
    private var shownTurns: [NotchModel.Turn] {
        // An agent task runs on its own, not in this thread, so the agent
        // prompt shows no messages above it.
        if model.agentComposeActive, !showsCopies { return [] }
        if showsCopies { return thread.filter(\.isDrawn) }
        // Unfolded for a reply: the messages after the last question only.
        if model.replyOnly {
            let start = thread.lastIndex(where: { $0.role == "user" }).map { $0 + 1 } ?? 0
            return Array(thread[start...])
        }
        return thread.filter { turn in
            !(turn.role == "user" && turn.hidesUserBubble)
        }
    }

    /// The thread is the one `model.turns` holds, so its messages take actions.
    private var onScreen: Bool { !showsCopies && !model.turns.isEmpty }

    private var overflows: Bool { overflowLatched || contentHeight > messagesCap }

    // MARK: - Body

    var body: some View {
        let turns = shownTurns
        VStack(alignment: .leading, spacing: 10) {
            if model.showRoutines && (!showsCopies || turns.isEmpty) {
                sidePage
                    .transition(.opacity)
                    .transaction(stillWhileClosed)
            } else if !turns.isEmpty {
                messages(turns)
                    // Messages that don't scroll start under the header row;
                    // scrolling ones already leave it `topFade`.
                    .padding(.top, overflows ? 0 : Self.topFade)
                    // Over the messages' top, ending at the bubbles' right
                    // edge.
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 6) {
                            if showsCopies { subThreadTitle }
                            // ⌘F: the notch's thread search bar, in the
                            // chips' place while it is up.
                            if model.threadSearchOpen, !showsCopies {
                                ThreadSearchBar(search: model.threadSearch,
                                                position: model.threadSearch.position) {
                                    model.closeThreadSearch()
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                            Spacer(minLength: 0)
                            if !(model.threadSearchOpen && !showsCopies) { headerChips }
                        }
                        .frame(width: NotchMetrics.chatWidth * Self.bubbleWidthFraction)
                        .padding(.top, 10)
                    }
                    .padding(.bottom, overflows && showsComposer ? -Self.composerOverlap : 0)
                    .transition(.opacity)
                    .transaction(stillWhileClosed)
            }
            if let feedback = noteFeedback {
                feedbackBubble(feedback)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
                    .transaction(stillWhileClosed)
            }
            if showsComposer {
                composer
                    .transition(.opacity)
            }
            if model.usingPromptShortcutContext, showsComposer {
                quotedShortcutCards
                    .transition(.opacity)
            }
        }
        .frame(width: NotchMetrics.chatWidth)
        .opacity(revealed ? 1 : 0)
        .background(CardFoldAnchor(fold: fold))
        .padding(.top, NotchMetrics.chatTopGap)
        .environment(\.chatBubbleGlass, true)
        .environment(\.bubblesGone, model.replyOnly ? model.replyBubblesGone : 0)
        .environment(\.cardWidthFraction, Self.bubbleWidthFraction)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: turns.count)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: noteFeedback)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: showsComposer)
        .onChange(of: model.pointerInside) { _, inside in
            model.replyCardHovered(inside)
        }
        .onAppear {
            if isOpen { opened() }
        }
        .onChange(of: isOpen) { _, open in
            if open {
                openPagesInWindows(whatsNew: false)
                opened()
            } else {
                var quiet = Transaction()
                quiet.disablesAnimations = true
                withTransaction(quiet) {
                    revealed = false
                    heightPull.uninstall()
                    heightPull.reset()
                    // Like leaving the thread in the panel: the next open
                    // shows the chat, not the side page.
                    model.showRoutines = false
                    model.closeThreadSearch()
                }
                fold.reset()
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: model.showRoutines)
        .onAppear { openPagesInWindows(whatsNew: false) }
        .onChange(of: model.showHistory) { _, _ in openPagesInWindows() }
        .onChange(of: model.showWhatsNew) { _, _ in openPagesInWindows() }
        .onChange(of: model.cardRetracting) { _, retracting in
            if retracting {
                fold.fold(duration: NotchModel.cardFlightDuration * 0.9, reduceMotion: reduceMotion)
            } else if isOpen, fold.isFolding {
                // A reopen turned the fold back: unfold from where it is.
                show()
                fold.unfold(fromCurrent: true, reduceMotion: reduceMotion)
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
        heightPull.reset()
        installHeightPull()
        model.judgeCardPinOnOpen(thread: thread)
        // The open scrolls to the end after the first layout; until then the
        // top of the list is in view, and must not read as a reader there.
        scroll.pinnedUntil = Date().addingTimeInterval(0.6)
        pinMountedBatch()
        endRequest += 1
        unfold()
    }

    /// Recent, asked for from the card (its ⋯ menu, ↓ on the prompt, the menu bar
    /// menu), opens in its own window; What's New is a page of the Settings
    /// window, which is the only window that reads release notes now.
    /// `whatsNew` false: the card is opening. A What's New page left up in
    /// the notch stays there; only a request made from the card moves it.
    private func openPagesInWindows(whatsNew: Bool = true) {
        // The card's view stays mounted while the card is closed; the island's
        // own Recent and What's New pages are not this view's to move.
        guard isOpen else { return }
        if model.showHistory {
            model.showHistory = false
            HistoryArchiveWindowController.shared.present(model: model)
        }
        if whatsNew, model.showWhatsNew {
            model.showWhatsNew = false
            model.settingsSection = InlineSettingsView.Section.whatsNew.rawValue
            SettingsWindowController.shared.present(model: model)
        }
    }

    /// Unfold down out of the menu bar icon, from folded.
    private func unfold() {
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { revealed = false }
        DispatchQueue.main.async {
            // The layer is held folded while SwiftUI draws the card for the
            // first time since it was hidden. That draw blocks the main
            // thread, so the timer below fires once it is done, and the
            // spring starts on a card that is already on the layer. Started
            // here, the spring ran while the card was still being drawn and
            // was over by the time it showed.
            fold.holdFolded()
            show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                guard isOpen else { return }
                fold.unfold(fromCurrent: false, reduceMotion: reduceMotion)
            }
        }
    }

    /// Draw the card at its rest size, without animation: `fold` moves it.
    private func show() {
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { revealed = true }
    }


    // MARK: - Header chips

    /// The panel's header chips on this card: the pin and ⋯
    /// (the cloud machine's status, while it is on). Laid over the top of the messages, right-aligned with the
    /// bubbles. One group: bare glyphs over a single soft dark blur.
    private var headerChips: some View {
        HStack(spacing: 6) {
            // Jev set the pin (`NotchModel.judgeCardPin`): the pin and its
            // label in one capsule, like the Recent chip's "N running".
            let jevPinned = model.isAnswerPinned && model.pinIsAuto
            if jevPinned {
                JevPinnedChip {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        model.toggleAnswerPin()
                    }
                }
                // Unfolds leftward out of the pin's slot, and folds back
                // into it.
                .transition(.scale(scale: 0.3, anchor: .trailing).combined(with: .opacity))
            }
            GlassSegmentCluster(segments: (jevPinned ? [] : [
                .init(id: "pin",
                      engaged: model.isAnswerPinned,
                      tooltip: shortcutHelp(model.isAnswerPinned ? "result.unpin" : "result.pin",
                                            action: .pin),
                      action: {
                          withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                              model.toggleAnswerPin()
                          }
                      }) {
                    PinStateGlyph(pinned: model.isAnswerPinned, size: 12, weight: .light)
                },
            ]) + [
                .init(id: "more",
                      engaged: model.isCardMoreMenuOpen,
                      tooltip: L("nono.more"),
                      action: { model.isCardMoreMenuOpen.toggle() }) {
                    Image(icon: "ellipsis")
                        .sfFont(12, weight: .light)
                },
            ], glass: false, bareChip: false, restsBright: true)
            .modifier(MenuCardWindow(
                open: model.isCardMoreMenuOpen,
                lowerTrailing: true,
                onDismiss: { _ in model.isCardMoreMenuOpen = false },
                card: {
                    AnyView(cardMoreMenu)
                }))
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82),
                   value: model.isAnswerPinned && model.pinIsAuto)
        .padding(.horizontal, 4)
        .background {
            ZStack {
                BackdropBlur(radius: 12, spot: true)
                    .padding(-Self.chipBlurSpread)
                // Dark behind the chips in dark mode, white in light mode,
                // where a dark smudge turned the icons grey on grey.
                Capsule(style: .continuous)
                    .fill(colorScheme == .light ? Color.white.opacity(0.92)
                                                : Color.black.opacity(0.7))
                    .padding(-4)
                    .blur(radius: 8)
            }
            .allowsHitTesting(false)
        }
    }

    /// How far the blur behind the header chips spreads past them.
    private static let chipBlurSpread: CGFloat = 16

    /// Open the side page on `tab`, or close it when that tab already shows.
    /// The ⋯ menu: Routines and Sub-thread open the side page on their tab, and
    /// the cloud machine's row follows while it is on. Same rows as the
    /// notch's ⋯ menu (`ResultTrailingCluster.cloudMenu`).
    private var cardMoreMenu: some View {
        let routines = L("routines.title")
        let copies = L("copyThread.tab")
        let websites = "Websites"
        return VStack(alignment: .leading, spacing: MenuCard.rowSpacing) {
            MenuCardRow(title: routines,
                        selected: model.showRoutines && model.sidePageTab == .routines) {
                model.isCardMoreMenuOpen = false
                openSidePage(.routines)
            }
            MenuCardRow(title: copies,
                        selected: model.showRoutines && model.sidePageTab == .copies) {
                model.isCardMoreMenuOpen = false
                openSidePage(.copies)
            }
            MenuCardRow(title: websites,
                        selected: model.showRoutines && model.sidePageTab == .websites) {
                model.isCardMoreMenuOpen = false
                openSidePage(.websites)
            }
            if CloudMachineStatusMenuRow.isShown {
                CloudMachineStatusMenuRow(compact: false)
            }
        }
        .padding(MenuCard.cardPad)
        .frame(width: max(MenuCard.pickerCardWidth,
                          MenuCard.width(titles: [(routines, ""), (copies, ""), (websites, "")])),
               alignment: .leading)
        .manageMenuCardBackground()
    }

    private func openSidePage(_ tab: NotchModel.SidePageTab) {
        if model.showRoutines, model.sidePageTab == tab {
            model.showRoutines = false
        } else {
            model.sidePageTab = tab
            model.showRoutines = true
        }
    }

    // MARK: - Side page

    /// Routines and Sub-thread, in the messages' place. The card has no
    /// panel for the side page to cover, so it takes the messages' column.
    private var sidePage: some View {
        RoutinesPanel(tab: model.sidePageTab, model: model, onClose: { model.showRoutines = false },
                      copies: { AnyView(copyThreadTab) },
                      subThread: { id in AnyView(subThreadTab(id)) },
                      onCard: true)
            // The messages' column: full width, bubbles at the card's own
            // fraction (`cardWidthFraction` from the body), so every bubble
            // and its actions sit where the thread's do.
            .frame(width: NotchMetrics.chatWidth, height: sidePageHeight)
    }

    @ViewBuilder
    private func subThreadTab(_ id: UUID) -> some View {
        let subTurns = model.subThreadConversation(for: id).filter(\.isDrawn)
        if subTurns.isEmpty {
            VStack(spacing: 0) {
                Text(L("subThread.empty"))
                    .sfFont(Tokens.TypeSize.label)
                    .foregroundStyle(Tokens.text4)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                Spacer(minLength: 0)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(subTurns.enumerated()), id: \.element.id) { index, turn in
                        ChatRow(turn: turn, model: model,
                                isLast: index == subTurns.count - 1,
                                question: subTurns.question(at: index),
                                recentCards: subTurns.recentCards(at: index),
                                timestamp: subTurns.timestamp(at: index),
                                onScreen: false,
                                live: nil, streamingNow: false, askFailed: false,
                                editable: false, quotable: false)
                            .equatable()
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            // The gaps between bubbles take the wheel, as in `messages`.
            .background(Color.black.opacity(0.001))
        }
    }

    /// The messages' own height, so opening the page moves neither the card
    /// nor the composer: the pulled height while they overflow, else their
    /// natural height, and at least room for the page's header.
    private var sidePageHeight: CGFloat {
        let messages = overflows
            ? messagesCap + (expandedCap - messagesCap) * heightPull.progress
            : contentHeight + Self.glassGutter * 2
        return max(messages, 160)
    }

    /// The Sub-thread page with no copies yet. With copies, Sub-thread is
    /// drawn by `messages`, exactly as the thread is.
    private var copyThreadTab: some View {
        VStack(spacing: 0) {
            Text(L("copyThread.empty"))
                .sfFont(Tokens.TypeSize.label)
                .foregroundStyle(Tokens.text4)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Spacer(minLength: 0)
        }
    }

    /// Sub-thread's name and its ×, at the top left of the messages, on the
    /// same blur as the header chips.
    private var subThreadTitle: some View {
        HStack(spacing: 6) {
            Text(L("copyThread.tab")).captionLabel()
            SidePageCloseButton { model.showRoutines = false }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .background {
            ZStack {
                BackdropBlur(radius: 12, spot: true)
                    .padding(-Self.chipBlurSpread)
                Capsule(style: .continuous)
                    .fill(colorScheme == .light ? Color.white.opacity(0.92) : Color.black.opacity(0.7))
                    .padding(-4)
                    .blur(radius: 8)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Messages

    private func messages(_ turns: [NotchModel.Turn]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
              VStack(spacing: 0) {
                Color.clear.frame(height: 0).id(Self.topID)
                // Not lazy. Only `mountBatch` messages are mounted, so all of
                // them are built. A lazy stack built the ones near the offset
                // it was closed at, and when the card reopened and jumped to
                // the end it did not build the ones there: the messages area
                // stayed empty until something else laid the list out again.
                // Keyed by id alone: diffing `[Turn]` compared every message's
                // full text on each update, which froze long threads for
                // seconds mid-scroll.
                let thread = self.thread
                let byID = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let index = Dictionary(thread.enumerated().map { ($1.id, $0) },
                                       uniquingKeysWith: { _, b in b })
                let lastID = turns.last?.id
                let start = mountedStart(in: turns)
                let shown = turns[start...].map(\.id)
                if #unavailable(macOS 15.0) {
                  if start > 0, let firstShown = shown.first {
                    // Without scroll geometry: mounts the next batch when the
                    // view is inserted. On macOS 15 `TrackScrollEnd` reports
                    // the reader reaching the top instead; this view sits in a
                    // plain VStack, so its onAppear ran once, at the bottom,
                    // and older messages never mounted.
                    Color.clear.frame(height: 1)
                        .onAppear { loadOlder(proxy, keeping: firstShown) }
                  }
                }
                VStack(alignment: .leading, spacing: Self.bubbleGap) {
                    ForEach(shown, id: \.self) { id in
                        if let turn = byID[id] {
                            ChatRow(turn: turn, model: model,
                                    isLast: id == thread.last?.id,
                                    question: index[id].map { thread.question(at: $0) } ?? "",
                                    recentCards: turn.role == "assistant"
                                        ? recentCardsCache.cards(for: turn, at: index[id], in: thread,
                                                                 fresh: id == lastID)
                                        : [],
                                    timestamp: index[id].flatMap { thread.timestamp(at: $0) } ?? turn.sentAt,
                                    onScreen: onScreen,
                                    live: turn.streaming && !showsCopies ? model.chatLiveStatus : nil,
                                    streamingNow: !showsCopies && id == lastID && model.isStreaming,
                                    askFailed: !showsCopies && id == lastID && model.visibleAskError != nil,
                                    holdsAnswer: model.welcomeHeldAnswers.contains(id),
                                    holdsLink: model.welcomeHeldLinks.contains(id),
                                    editable: !showsCopies && !model.turns.isEmpty,
                                    quotable: !showsCopies)
                                .equatable()
                                .modifier(ThreadSearchMark(search: model.threadSearch, turnID: id))
                                .modifier(CullsOffscreenGlass(viewport: glassViewport))
                        }
                    }
                }
                .coordinateSpace(name: GlassCullViewport.space)
                .background(EnclosingScrollViewReporter { [scrollRef] in scrollRef.view = $0 })
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    scroll.measured = height
                    // Any growth (streamed text, a settled answer's layout,
                    // cards) keeps the end in view while the reader is there.
                    if overflowLatched {
                        if scroll.atBottom { scrollToEnd(proxy, animated: false) }
                        return
                    }
                    if height > messagesCap {
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
            .modifier(TracksGlassViewport(viewport: glassViewport))
            .modifier(TrackScrollEnd(position: scroll, changed: { end in
                if followsEnd != end { followsEnd = end }
            }, reachedTop: {
                let turns = shownTurns
                let start = mountedStart(in: turns)
                guard start > 0 else { return }
                loadOlder(proxy, keeping: turns[start].id)
            }))
            .modifier(PulledHeight(
                pull: heightPull,
                overflows: overflows,
                collapsed: messagesCap + Self.composerOverlap,
                expanded: expandedCap + Self.composerOverlap,
                natural: contentHeight + Self.glassGutter * 2,
                blurHeight: Self.bottomBlur + Self.composerOverlap,
                mask: AnyView(fadeMask),
                // The height moves only with the list at its end: keep it
                // there through every frame of the move. Not gated on
                // `scroll.atBottom`: the shrinking frame itself, under fingers
                // on the trackpad, reads as the reader leaving the end.
                resized: {
                    scrollRef.holdEnd()
                    scroll.atBottom = true
                }))
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
                // Not animated. The new message's own spring (`turns.count`,
                // on the card) already moves the list, and the end stays in
                // view through it by the size-change anchor. An animated
                // scroll on top of that put the list 291 pt short of its end
                // for a frame, which showed as every message jumping away.
                scrollToEnd(proxy, animated: false)
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
            // ⌘F: bring the current match into view, mounting older
            // messages first when it lies above the mounted ones.
            .onReceive(model.threadSearch.position.$target.removeDuplicates()) { target in
                guard let target, !showsCopies,
                      let index = turns.firstIndex(where: { $0.id == target }) else { return }
                scroll.atBottom = false
                scroll.pinnedUntil = .distantPast
                let mounted = index >= mountedStart(in: turns)
                if !mounted { mountedFromID = target }
                DispatchQueue.main.async {
                    if mounted {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .center) }
                    } else {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
            // Another thread on screen: measure it afresh.
            // Not zeroed here: the new list may already have reported its
            // height, and a zero would then stick and hide every message.
            // Re-judged on the next turn of the run loop, from the last report.
            .onChange(of: turns.first?.id) { _, _ in
                DispatchQueue.main.async {
                    overflowLatched = scroll.measured > messagesCap
                    contentHeight = scroll.measured
                }
                recentCardsCache.clear()
                heightPull.reset()
                pinMountedBatch()
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

    /// Hands the pull what it judges a gesture by. Reads the view's state
    /// through its storage, so the closures see current values.
    private func installHeightPull() {
        heightPull.span = { expandedCap - messagesCap }
        heightPull.accepts = { [scrollRef] event in
            overflows && (!model.showRoutines || showsCopies) && model.pointerInside
                && event.window != nil && event.window === scrollRef.view?.window
        }
        heightPull.atEnd = { scroll.atBottom }
        heightPull.acceptsDismiss = { [scrollRef] event in
            (!model.showRoutines || showsCopies) && model.pointerInside
                && !model.isFloatingCardOpen
                && event.window != nil && event.window === scrollRef.view?.window
        }
        heightPull.dismiss = { model.fullClose() }
        heightPull.revealsThread = { [scrollRef] event in
            model.replyOnly && model.pointerInside
                && event.window != nil && event.window === scrollRef.view?.window
        }
        heightPull.revealThread = { model.showWholeThreadFromReply() }
        heightPull.install()
    }

    /// The index of the oldest mounted message: `mountedFromID`'s, or with
    /// none pinned (or one that left the thread) the newest batch's first.
    private func mountedStart(in turns: [NotchModel.Turn]) -> Int {
        if let id = mountedFromID, let index = turns.lastIndex(where: { $0.id == id }) {
            return index
        }
        return max(0, turns.count - Self.mountBatch)
    }

    /// Mount the newest batch, and hold its first message as the list's start.
    private func pinMountedBatch() {
        let turns = shownTurns
        mountedFromID = turns.isEmpty ? nil : turns[max(0, turns.count - Self.mountBatch)].id
    }

    /// Mount the next batch of older messages above the ones shown, and keep
    /// the message that was at the top where it was.
    private func loadOlder(_ proxy: ScrollViewProxy, keeping anchor: UUID) {
        guard overflowLatched, !scroll.pinned else { return }
        if #available(macOS 15.0, *), scroll.atBottom { return }
        let turns = shownTurns
        guard !turns.isEmpty else { return }
        mountedFromID = turns[max(0, mountedStart(in: turns) - Self.mountBatch)].id
        DispatchQueue.main.async {
            proxy.scrollTo(anchor, anchor: .top)
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
                .sfFont(Self.answerFont)
                .foregroundStyle(model.noteError != nil ? Tokens.text1 : Tokens.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Composer

    /// The island's prompt and bottom row, in the floating card's glass.
    ///
    /// The pin holds the CARD open, not this row: a pinned answer keeps the
    /// bottom row hover-only like every other state, so pinning doesn't grow
    /// the composer by a row height.
    private var composer: some View {
        let shape = NotchShape(bottomRadius: Tokens.Radius.shell,
                               topCornerRadius: Tokens.Radius.shell)
        return NotchBody(model: model, composerOnly: true, showsBottomRow: composerHovering || bottomRowMenuOpen)
            .background(GlassMaterial(bottomRadius: Tokens.Radius.shell,
                                      topCornerRadius: Tokens.Radius.shell,
                                      expanded: true,
                                      cameraZone: 0,
                                      sweepsOnOpen: false,
                                      floating: true))
            .clipShape(shape)
            .overlay(IslandRim(shape: shape))
            .background(LightGlassShadow(shape: shape))
            .contentShape(shape)
            .contextMenu { chatMenu }
            .onHover { hovering in
                withAnimation(.easeOut(duration: Tokens.hoverFade)) { composerHovering = hovering }
            }
            .frame(width: NotchMetrics.chatWidth * Self.bubbleWidthFraction)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
    }

    /// The user's Text actions under the composer while it carries quoted
    /// text, each its own glass pill. One is selected (the first on open):
    /// ← / → move it, Enter on an empty field runs it, hover selects.
    @ViewBuilder
    private var quotedShortcutCards: some View {
        let picks = model.quotedPicks
        if !picks.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(Array(picks.enumerated()), id: \.element.id) { index, pick in
                            QuotedShortcutCard(title: pick.displayName,
                                               selected: index == model.quotedPickIndex,
                                               onHover: { model.quotedPickIndex = index }) {
                                model.runShortcutOnQuotedText(pick)
                            }
                            .id(pick.id)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                }
                .scrollIndicators(.never)
                .onChange(of: model.quotedPickIndex) { _, index in
                    guard picks.indices.contains(index) else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(picks[index].id) }
                }
            }
            .frame(width: NotchMetrics.chatWidth * Self.bubbleWidthFraction + 8)
        }
    }

    /// A menu opened from the bottom row is up. The pointer has left the
    /// composer for the menu, and the row (the menu's anchor) has to stay.
    private var bottomRowMenuOpen: Bool {
        model.showModelPicker || model.showAskModelPicker || model.showAgentPicker
            || model.showAgentFolderPicker || model.showLoopIntervalPicker
            || model.isAttachMenuOpen || model.isFolderPickerOpen || model.isScreenCaptureOpen
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
    let timestamp: Date?
    let onScreen: Bool
    /// The round's wait state, for the answer still streaming only.
    let live: ChatLiveStatus?
    /// For the last message: an answer is streaming, or the round failed.
    let streamingNow: Bool
    let askFailed: Bool
    /// The welcome guide's example card still holds back its answer, or its
    /// link card (`NotchModel.welcomeHeldAnswers`, `.welcomeHeldLinks`).
    var holdsAnswer = false
    var holdsLink = false
    /// The thread is the one on screen (`model.turns`), not the main thread's
    /// peek or the copy thread: Reply, Edit and Delete act on it, as in the
    /// notch.
    var editable = false
    /// Quote works on the main thread's peek too: the prompt continues it.
    var quotable = false

    static func == (a: ChatRow, b: ChatRow) -> Bool {
        a.turn == b.turn && a.onScreen == b.onScreen && a.live == b.live
            && a.editable == b.editable && a.quotable == b.quotable
            && a.holdsAnswer == b.holdsAnswer && a.holdsLink == b.holdsLink
            && a.streamingNow == b.streamingNow && a.askFailed == b.askFailed
            && a.isLast == b.isLast && a.question == b.question
            && a.recentCards == b.recentCards && a.timestamp == b.timestamp
    }

    var body: some View {
        if let target = turn.threadLink, !turn.threadReport {
            SubThreadLinkLine(title: turn.text) { model.openSubThread(target) }
        } else if let example = turn.example {
            WelcomeExampleCard(example: example, showsAnswer: !holdsAnswer, showsLink: !holdsLink)
        } else if turn.licenseCard {
            WelcomeLicenseCard(model: model)
        } else if turn.role == "user" {
            VStack(alignment: .leading, spacing: 5) {
                if !turn.imageFiles.isEmpty {
                    SavedTurnImages(files: turn.imageFiles)
                } else if turn.usedClipboard {
                    // The notch's line over a question asked with the clipboard.
                    Text(L("result.basedOnCopied"))
                        .sfFont(Tokens.TypeSize.meta)
                        .tracking(0.2)
                        .foregroundStyle(Tokens.text4)
                        .padding(.leading, 12)
                }
                UserQuestionBubble(text: turn.text, baseFont: MenuBarChat.baseFont,
                                   isAgent: turn.isAgent,
                                   reaction: turn.reaction, fromTelegram: turn.fromTelegram, fromSignal: turn.fromSignal, savedOnly: turn.savedOnly,
                                   sentAt: timestamp)
                    .contextMenu { QuestionTurnMenu(onReply: onReply, onEdit: onEdit, onDelete: onDelete) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            assistantRow
        }
    }

    /// Right-click on a message, as in the notch (`NotchBody.turnView`).
    private var onReply: (() -> Void)? {
        editable ? { model.beginReply(to: turn) } : nil
    }
    private var onEdit: (() -> Void)? {
        editable && model.canEdit(turn) ? { model.beginEdit(of: turn) } : nil
    }
    private var onDelete: (() -> Void)? {
        guard editable, !model.threadIsAgentRun, !model.isStreaming else { return nil }
        return {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                model.deleteTurn(turn.id, threadID: model.threadHistoryID)
            }
        }
    }

    private var assistantRow: some View {
        let subReportTarget = turn.threadReport ? turn.threadLink : nil
        let subReportTitle = subReportTarget.flatMap { model.subThreadTitle(for: $0) }
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
                baseFont: MenuBarChat.baseFont,
                isAgent: turn.isAgent,
                completedAt: turn.isAgent && isLast && editable ? model.currentThreadCompletedAt : nil,
                showsFooterMetadata: !turn.isAgent,
                onInAppCopy: { model.rebaselineClipboardAfterInAppWrite() },
                onReply: onReply,
                onQuote: quotable ? { quote in model.beginReply(quote: quote) } : nil,
                onDelete: onDelete,
                regenModel: turn.regenModel,
                answerModel: turn.answerModel,
                agentTrail: turn.isAgent
                    ? (turn.agentLog?.droppingTrailingAnswer(text) ?? []) : [],
                pendingQuestion: turn.streaming
                    ? (turn.pendingQuestion ?? model.pendingQuestion(for: turn.id)) : nil,
                onChooseOption: { questionID, option in
                    model.chooseUserOption(option, questionID: questionID)
                },
                onReplaceOriginal: editable && model.replaceTargets[turn.id] != nil
                    ? { model.replaceOriginal(turnID: turn.id) } : nil,
                onContinue: onScreen && turn.interrupted && isLast && !streamingNow
                    ? { model.continueAnswer(turnID: turn.id) } : nil,
                question: question,
                sharedLinks: turn.sharedLinks,
                recentCards: recentCards,
                captures: turn.captures,
                usedCloudMachine: turn.usedCloudMachine,
                folders: turn.folders,
                subThreadTitle: subReportTitle,
                onOpenSubThread: subReportTarget.map { target in { model.openSubThread(target) } },
                onOpenCapture: { model.openTurnCapture($0) },
                onUndoCapture: { model.undoTurnCapture($0) },
                turnID: turn.id,
                sentAt: timestamp)
        }
    }
}

/// The chat unfolding down out of the menu bar icon: it grows down from its
/// top edge while it drops into place and fades in. The spring overshoots, so
/// the card stretches past its height and springs back. Reduce Motion fades
/// instead.
///
/// The motion runs on the window's content layer, in the render server. As a
/// SwiftUI scale on the card it was laid out and drawn again on the main
/// thread for every frame, each bubble's glass included, at 80 to 100 ms a
/// frame on a long thread. SwiftUI now draws the card once, at rest.
final class CardFold {
    /// A view with the card's frame (`CardFoldAnchor`).
    weak var anchor: NSView?
    /// A fold back into the icon is running or held.
    private(set) var isFolding = false

    private static let key = "menuBarChat.fold"
    /// Underdamped, so the card overshoots its rest size and settles back.
    private static let response: Double = 0.5
    private static let dampingFraction: Double = 0.6
    private static let frame: Double = 1.0 / 120

    /// Unfold to rest: from folded, or with `fromCurrent` from wherever a fold
    /// under way has got to.
    func unfold(fromCurrent: Bool, reduceMotion: Bool) {
        guard let layer else { return }
        isFolding = false
        let start = fromCurrent ? currentProgress(of: layer) : 0
        guard start < 1 else { return }
        let omega = 2 * Double.pi / Self.response
        let zeta = Self.dampingFraction
        let damped = omega * (1 - zeta * zeta).squareRoot()
        // Until the spring is within a thousandth of rest.
        let duration = log(1000) / (zeta * omega)
        var samples: [CGFloat] = []
        var t = 0.0
        while t < duration {
            let spring = 1 - exp(-zeta * omega * t)
                * (cos(damped * t) + zeta * omega / damped * sin(damped * t))
            samples.append(start + (1 - start) * CGFloat(spring))
            t += Self.frame
        }
        samples.append(1)
        run(samples, duration: duration, on: layer, holds: false, reduceMotion: reduceMotion)
    }

    /// Fold back up into the icon, easing in, and stay folded until `reset`.
    func fold(duration: Double, reduceMotion: Bool) {
        guard let layer else { return }
        isFolding = true
        let start = currentProgress(of: layer)
        let ease = CAMediaTimingFunction(name: .easeIn)
        var c1: [Float] = [0, 0], c2: [Float] = [0, 0]
        ease.getControlPoint(at: 1, values: &c1)
        ease.getControlPoint(at: 2, values: &c2)
        let count = max(2, Int(duration / Self.frame))
        let samples = (0...count).map { i -> CGFloat in
            let eased = Self.bezier(Double(i) / Double(count),
                                    Double(c1[0]), Double(c1[1]), Double(c2[0]), Double(c2[1]))
            return start * CGFloat(1 - eased)
        }
        run(samples, duration: duration, on: layer, holds: true, reduceMotion: reduceMotion)
    }

    /// Drop a held fold: the card is closed and SwiftUI no longer draws it.
    func reset() {
        isFolding = false
        layer?.removeAnimation(forKey: Self.key)
    }

    /// Keep the card folded and clear until `unfold` replaces this.
    func holdFolded() {
        guard let layer else { return }
        run([0, 0], duration: 1, on: layer, holds: true, reduceMotion: false)
    }

    private var layer: CALayer? { anchor?.window?.contentView?.layer }

    private func currentProgress(of layer: CALayer) -> CGFloat {
        guard layer.animation(forKey: Self.key) != nil,
              let shown = layer.presentation() else { return 1 }
        // Opacity is `min(1, 1.6 p)`, so it gives p below 0.625; the y scale,
        // `0.55 + 0.45 p`, gives it above (and under Reduce Motion is 1).
        let opacity = CGFloat(shown.opacity)
        if opacity < 1 { return opacity / 1.6 }
        return min(1, max(0.625, (shown.transform.m22 - 0.55) / 0.45))
    }

    private func run(_ samples: [CGFloat], duration: Double, on layer: CALayer,
                     holds: Bool, reduceMotion: Bool) {
        guard let anchor, let content = anchor.window?.contentView else { return }
        // The card's top centre, which the scale holds still, and the layer's
        // own centre, which the layer's transform is taken about.
        let top = NSPoint(x: anchor.bounds.midX,
                          y: anchor.isFlipped ? anchor.bounds.minY : anchor.bounds.maxY)
        let pivot = content.convert(top, from: anchor)
        let centre = CGPoint(x: layer.bounds.minX + layer.bounds.width * layer.anchorPoint.x,
                             y: layer.bounds.minY + layer.bounds.height * layer.anchorPoint.y)
        // The layer's transform has y up from the bottom edge, whichever way
        // the view's own coordinates run.
        let pivotY = content.isFlipped ? layer.bounds.height - pivot.y : pivot.y
        let up: CGFloat = 1
        let transforms = samples.map { raw -> CATransform3D in
            let p = max(0, raw)
            guard !reduceMotion else { return CATransform3DIdentity }
            let dx = pivot.x - centre.x, dy = pivotY - centre.y
            let affine = CGAffineTransform(translationX: -dx, y: -dy)
                .concatenating(CGAffineTransform(scaleX: 0.92 + 0.08 * p, y: 0.55 + 0.45 * p))
                .concatenating(CGAffineTransform(translationX: dx, y: dy + up * 30 * (1 - p)))
            return CATransform3DMakeAffineTransform(affine)
        }
        let scale = CAKeyframeAnimation(keyPath: "transform")
        scale.values = transforms.map { NSValue(caTransform3D: $0) }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = samples.map { Float(min(1, max(0, $0) * 1.6)) }
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = duration
        if holds {
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
        }
        layer.add(group, forKey: Self.key)
    }

    /// y of the cubic Bézier through (0,0), (x1,y1), (x2,y2), (1,1) at `x`.
    private static func bezier(_ x: Double, _ x1: Double, _ y1: Double,
                               _ x2: Double, _ y2: Double) -> Double {
        func at(_ t: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
        }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if at(mid, x1, x2) < x { low = mid } else { high = mid }
        }
        return at((low + high) / 2, y1, y2)
    }
}

/// Gives `CardFold` a view with the card's frame, to find the card's window
/// and its top centre by.
private struct CardFoldAnchor: NSViewRepresentable {
    let fold: CardFold

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        fold.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        fold.anchor = view
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
/// The menu bar chat's message scroll view, for `ChatHeightPull`.
final class MessagesScrollRef {
    weak var view: NSScrollView? {
        didSet {
            guard view !== oldValue else { return }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            frameObserver = nil
            guard let view else { return }
            view.postsFrameChangedNotifications = true
            // In the layout pass that resizes the scroll view, before it
            // draws: the list never shows a frame away from its end.
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: view, queue: nil
            ) { [weak self] _ in
                guard let self, self.holdsEnd else { return }
                self.scrollToEnd()
            }
        }
    }
    private var frameObserver: NSObjectProtocol?
    private var release: DispatchWorkItem?
    /// The height is moving: every resize puts the list back at its end.
    private(set) var holdsEnd = false

    /// Holds the end through the resizes of the next moment.
    func holdEnd() {
        holdsEnd = true
        scrollToEnd()
        release?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.holdsEnd = false }
        release = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    deinit {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
    }

    /// Puts the list's end at the bottom of the scroll view now, in the
    /// layout pass that changed its height.
    func scrollToEnd() {
        guard let view, let doc = view.documentView else { return }
        let clip = view.contentView
        let height = clip.bounds.height
        let y = doc.isFlipped ? max(0, doc.frame.height - height) : 0
        guard abs(clip.bounds.minY - y) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        view.reflectScrolledClipView(clip)
    }
}

/// The messages' frame in the menu bar chat: as tall as they are while they
/// fit, else between the two heights by `ChatHeightPull.progress`. Observes
/// the pull itself, so a pull frame re-runs this and not the whole chat.
private struct PulledHeight: ViewModifier {
    @ObservedObject var pull: ChatHeightPull
    let overflows: Bool
    let collapsed: CGFloat
    let expanded: CGFloat
    let natural: CGFloat
    let blurHeight: CGFloat
    let mask: AnyView
    let resized: () -> Void

    func body(content: Content) -> some View {
        let height = overflows
            ? collapsed + (max(expanded, collapsed) - collapsed) * pull.progress
            : natural
        content
            .frame(height: height)
            .mask(mask)
            // Messages scrolling down toward the composer blur out instead of
            // fading to clear.
            .overlay(alignment: .bottom) {
                if overflows {
                    BackdropBlur(radius: 14)
                        .frame(height: blurHeight)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: pull.progress) { _, _ in resized() }
    }
}

/// The menu bar chat's two heights, moved the way the notch's thread pull
/// moves (`NotchModel.handleThreadPullScroll`): at the end of the list a
/// two-finger pull down grows the messages point for point with the
/// fingers, and a swipe up shrinks them. Lifted mid-way, the height
/// settles on one of the two by distance and speed. A gesture that starts
/// anywhere else, or that goes the other way, scrolls the list.
final class ChatHeightPull: ObservableObject {
    /// 0 is the short height, 1 the tall one.
    @Published private(set) var progress: CGFloat = 0

    /// Points between the two heights.
    var span: () -> CGFloat = { 0 }
    /// The event is over the chat and the messages overflow.
    var accepts: (NSEvent) -> Bool = { _ in false }
    /// The list is scrolled to its end.
    var atEnd: () -> Bool = { true }
    /// The event is over the chat and a swipe up may close the card, whether
    /// or not the messages overflow.
    var acceptsDismiss: (NSEvent) -> Bool = { _ in false }
    /// Closes the card: a swipe up at the short height, at the end of the list.
    var dismiss: () -> Void = {}
    /// The card unfolded for a reply and the event is over it: a pull down
    /// shows the whole thread (`revealThread`) before the height can move.
    var revealsThread: (NSEvent) -> Bool = { _ in false }
    var revealThread: () -> Void = {}

    /// Points a swipe up travels at the short height before it closes the card.
    private static let dismissDistance: CGFloat = 24

    private enum Gesture { case none, pendingOpen, pendingClose, pendingDismiss, pendingReveal, tracking, ignoring, coasting }
    private var gesture: Gesture = .none
    private var closing = false
    private var distance: CGFloat = 0
    private var samples: [(time: TimeInterval, delta: CGFloat)] = []
    private var monitor: Any?
    private var ticker: Timer?
    private var settleID = 0

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Back to the short height at once.
    func reset() {
        settleID += 1
        ticker?.invalidate()
        ticker = nil
        gesture = .none
        set(0)
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        ticker?.invalidate()
    }

    private var room: CGFloat { max(span(), 0) }

    /// Positive `scrollingDeltaY` moves content down (fingers down, with
    /// natural scrolling): the pull that opens.
    private func handle(_ event: NSEvent) -> Bool {
        // The coast after the fingers lift belongs to the gesture that ended.
        if event.momentumPhase != [] {
            guard gesture == .coasting else { return false }
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                gesture = .none
            }
            return true
        }
        let dy = event.scrollingDeltaY
        // A mouse wheel has no phases: one notch plays the whole move.
        if event.phase == [] {
            if dy > 0, revealsThread(event) { revealThread(); return true }
            guard ticker == nil, room > 1, accepts(event), atEnd() else { return false }
            if dy > 0, progress == 0 { settle(open: true, velocity: 0); return true }
            if dy < 0, progress == 1 { settle(open: false, velocity: 0); return true }
            return false
        }
        switch event.phase {
        case .began:
            samples = []
            distance = 0
            if revealsThread(event) {
                // Not consumed until it turns out to be a pull down.
                gesture = .pendingReveal
                return false
            }
            guard ticker == nil, room > 1, accepts(event), atEnd() else {
                // No room to grow, or not over the messages: only the close.
                if ticker == nil, progress == 0, acceptsDismiss(event), atEnd() {
                    gesture = .pendingDismiss
                } else {
                    gesture = .ignoring
                }
                return false
            }
            if progress == 0 {
                gesture = .pendingOpen
                return true
            }
            if progress == 1 {
                // Not consumed: until it turns out to be a swipe up, it may be
                // a scroll, and the list needs its start.
                gesture = .pendingClose
                return false
            }
            gesture = .ignoring
            return false
        case .changed:
            switch gesture {
            case .pendingReveal:
                if dy < 0 || abs(event.scrollingDeltaX) > abs(dy) {
                    gesture = .ignoring
                    return false
                }
                guard dy > 0 else { return false }
                // The rest of this gesture is spent; the next pull moves the
                // height of the thread now on screen.
                gesture = .coasting
                let reveal = revealThread
                DispatchQueue.main.async { reveal() }
                return true
            case .pendingOpen:
                // Up, at the short height, is the close.
                if dy < 0, abs(event.scrollingDeltaX) <= 2 * abs(dy), acceptsDismiss(event) {
                    gesture = .pendingDismiss
                    return trackDismiss(dy)
                }
                // Up, or mostly sideways, isn't a pull.
                if dy < 0 || abs(event.scrollingDeltaX) > abs(dy) {
                    gesture = .ignoring
                    return false
                }
                guard dy > 0 else { return true }
                closing = false
                gesture = .tracking
                track(dy)
                return true
            case .pendingClose:
                if dy > 0 || abs(event.scrollingDeltaX) > 2 * abs(dy) && dy != 0 {
                    gesture = .ignoring
                    return false
                }
                guard dy < 0 else { return false }
                closing = true
                gesture = .tracking
                track(dy)
                return true
            case .pendingDismiss:
                if dy > 0 || abs(event.scrollingDeltaX) > 2 * abs(dy) && dy != 0 {
                    gesture = .ignoring
                    return false
                }
                guard dy < 0 else { return false }
                return trackDismiss(dy)
            case .tracking:
                track(dy)
                return true
            case .coasting:
                return true
            case .none, .ignoring:
                return false
            }
        case .ended, .cancelled:
            switch gesture {
            case .tracking:
                gesture = .coasting
                release()
                return true
            case .pendingOpen, .coasting:
                gesture = .coasting
                return true
            case .pendingClose, .pendingDismiss, .pendingReveal, .none, .ignoring:
                gesture = .none
                return false
            }
        default:
            return gesture == .tracking
        }
    }

    /// Counts the swipe up; past `dismissDistance` the card closes and the
    /// rest of the gesture is consumed.
    private func trackDismiss(_ dy: CGFloat) -> Bool {
        distance += -dy
        guard distance >= Self.dismissDistance else { return true }
        gesture = .coasting
        let dismiss = dismiss
        DispatchQueue.main.async { dismiss() }
        return true
    }

    /// The height follows the fingers point for point. Reaching either
    /// height ends the move without waiting for the fingers to lift.
    private func track(_ dy: CGFloat) {
        let step = closing ? -dy : dy
        distance = max(0, distance + step)
        let now = ProcessInfo.processInfo.systemUptime
        samples.append((now, step))
        samples.removeAll { now - $0.time > 0.08 }
        let travelled = min(distance / max(room, 1), 1)
        set(closing ? 1 - travelled : travelled)
        if travelled >= 1 {
            gesture = .coasting
        }
    }

    /// Fingers lifted mid-way: the same thresholds as the notch's thread pull.
    private func release() {
        let times = samples.map(\.time)
        let elapsed = max((times.max() ?? 0) - (times.min() ?? 0), 1.0 / 120)
        let velocity = samples.reduce(0) { $0 + $1.delta } / elapsed
        let speed = velocity / max(room, 1)
        if closing {
            let travelled = 1 - progress
            let closes = (travelled > 0.2 && velocity > -250) || (travelled > 0.1 && velocity > 400)
            settle(open: !closes, velocity: -speed)
        } else {
            let opens = velocity > 500 || (progress > 0.33 && velocity > -250)
            settle(open: opens, velocity: speed)
        }
    }

    /// Written one un-animated value per frame, like the thread pull's
    /// settle (`NotchModel.settleThreadPull`).
    private func settle(open opens: Bool, velocity: CGFloat) {
        let from = Double(progress)
        let to: Double = opens ? 1 : 0
        let remaining = to - from
        guard abs(remaining) > 0.0005 else { set(CGFloat(to)); return }
        let initial = abs(remaining) > 0.01
            ? min(max(Double(velocity) / remaining, -10), 10) * remaining : 0
        let spring = Spring(duration: 0.42, bounce: 0)
        let duration = spring.settlingDuration(fromValue: from, toValue: to,
                                               initialVelocity: initial, epsilon: 0.001)
        settleID += 1
        let id = settleID
        let start = CACurrentMediaTime()
        ticker?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            guard let self, self.settleID == id else {
                timer.invalidate()
                return
            }
            let t = CACurrentMediaTime() - start
            let value = spring.value(fromValue: from, toValue: to, initialVelocity: initial, time: t)
            // Done once within half a point of the end: the spring's tail
            // moves nothing on screen, and a new gesture waits for it.
            if t >= duration || abs(value - to) * Double(max(self.room, 1)) < 0.5 {
                timer.invalidate()
                self.ticker = nil
                self.set(CGFloat(to))
                return
            }
            self.set(CGFloat(value))
        }
        ticker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func set(_ value: CGFloat) {
        guard progress != value else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { progress = value }
    }
}

/// The card header's pin while Jev holds it: "Jev pinned" and the tack in
/// one glass capsule, drawn like the Recent chip's "N running" capsule
/// (`IdleTrailingCluster.runningRecentChip`). A click takes the pin off.
private struct JevPinnedChip: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(L("result.jevPinned"))
                    .sfFont(Tokens.TypeSize.label, weight: .medium)
                PinStateGlyph(pinned: true, size: 11, weight: .regular)
            }
            .foregroundStyle(Color.primary.opacity(hovering ? 1 : 0.82))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .glassCapsule(in: Capsule(style: .continuous), brighter: hovering)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        .help(L("result.unpin"))
    }
}

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
    /// The messages' last measured height, kept even while the scroll view is
    /// capped, so a thread change can re-judge overflow without a fresh report.
    var measured: CGFloat = 0
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
    /// The reader scrolled to within `topReach` of the top.
    var reachedTop: () -> Void = {}
    static let topReach: CGFloat = 240

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: ScrollSample.self) { geo in
                ScrollSample(offset: geo.contentOffset.y,
                             end: geo.contentOffset.y + geo.containerSize.height
                                 >= geo.contentSize.height - 24)
            } action: { old, new in
                // Once per crossing: the batch it mounts moves the offset
                // back down past the line.
                if position.userScrolling, new.offset < Self.topReach,
                   old.offset >= Self.topReach {
                    reachedTop()
                }
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
    /// A round patch, whole at the centre and fading out to its edges, instead
    /// of a band fading in from the top.
    var spot: Bool = false

    func makeNSView(context: Context) -> BackdropBlurView { BackdropBlurView(radius: radius, spot: spot) }
    func updateNSView(_ view: BackdropBlurView, context: Context) {}
}

private final class BackdropBlurView: NSView {
    private let radius: CGFloat
    private let spot: Bool
    /// The filter is a variable blur (`inputMaskImage`), or a plain Gaussian
    /// when the system has no variable blur; the plain one is faded in by a
    /// gradient mask on the layer instead.
    private var variable = false
    private var maskedSize: CGSize = CGSize(width: -1, height: -1)

    init(radius: CGFloat, spot: Bool = false) {
        self.radius = radius
        self.spot = spot
        super.init(frame: .zero)
        wantsLayer = true
        // After another window or app comes forward, the backdrop kept showing
        // what was behind the card before the switch. Rebuild it on those events.
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                  object: nil, queue: .main) { [weak self] _ in self?.refresh() },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                               object: nil, queue: .main) { [weak self] _ in self?.refresh() },
            center.addObserver(forName: NSWindow.didResignKeyNotification,
                               object: nil, queue: .main) { [weak self] _ in self?.refresh() },
        ]
    }

    private var observers: [NSObjectProtocol] = []

    deinit {
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    /// Takes the backdrop off and puts it back a frame later, so the window
    /// server samples it again instead of reusing the old capture.
    private func refresh() {
        guard let layer, window != nil else { return }
        let filters = layer.filters
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(false, forKey: "enabled")
        layer.filters = nil
        CATransaction.commit()
        DispatchQueue.main.async { [weak layer] in
            guard let layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.filters = filters
            layer.setValue(true, forKey: "enabled")
            CATransaction.commit()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer {
        guard let backdrop = NSClassFromString("CABackdropLayer") as? CALayer.Type else {
            return CALayer()
        }
        let layer = backdrop.init()
        // The window server caches the filtered backdrop and on screen kept
        // showing what was behind the card before (screenshots re-render and
        // did not show it). Filter every frame from the current backdrop.
        layer.setValue(true, forKey: "disableFilterCache")
        if !spot, let filter = Self.filter("variableBlur") {
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
        guard let layer, bounds.size != maskedSize else { return }
        maskedSize = bounds.size
        if spot {
            // Whole in the middle, clear at the edges.
            let gradient = CAGradientLayer()
            gradient.type = .radial
            gradient.frame = layer.bounds
            gradient.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            gradient.locations = [0, 0.45, 1]
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 1)
            layer.mask = gradient
            return
        }
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

/// The visible part of a message list, in the coordinates of its message
/// stack (`space`), rounded out to `step` so a scroll republishes it once per
/// `step` points instead of every frame. `nil` until the scroll view reports,
/// which draws every message's glass.
final class GlassCullViewport: ObservableObject {
    static let space = "chatGlassCull"
    private static let step: CGFloat = 80
    @Published private(set) var visible: ClosedRange<CGFloat>?

    func update(_ rect: CGRect) {
        guard rect.height > 0 else { return }
        let lo = (rect.minY / Self.step).rounded(.down) * Self.step
        let hi = (rect.maxY / Self.step).rounded(.up) * Self.step
        if visible != lo...hi { visible = lo...hi }
    }

    func reset() {
        if visible != nil { visible = nil }
    }
}

/// Feeds a message list's scroll view's visible rect to its `GlassCullViewport`.
/// Before macOS 15 there is no scroll geometry, and nothing is culled.
private struct TracksGlassViewport: ViewModifier {
    let viewport: GlassCullViewport

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in
                    viewport.update(rect)
                }
                // A new scroll view (a new thread) starts with nothing culled
                // until it reports.
                .onAppear { viewport.reset() }
        } else {
            content
        }
    }
}

/// Draws a message's glass only while the message is within `margin` of the
/// visible part of the list. Each bubble's glass is a platform view that the
/// scroll view moves on every frame, and on a long thread moving all of them
/// took most of each scroll frame. Messages out of view are not seen, so
/// dropping their glass changes nothing on screen; the margin puts it back
/// before the message scrolls in.
///
/// The message's frame is read in the message stack's coordinates, which
/// change only with layout, and the visible range comes from the scroll view's
/// own geometry. Reading the message's bounds in the scroll view's space
/// instead missed scrolls, and a message on screen kept its glass off.
private struct CullsOffscreenGlass: ViewModifier {
    @ObservedObject var viewport: GlassCullViewport
    @State private var span: ClosedRange<CGFloat>?
    private static let margin: CGFloat = 320

    private var culled: Bool {
        guard let visible = viewport.visible, let span else { return false }
        return span.upperBound < visible.lowerBound - Self.margin
            || span.lowerBound > visible.upperBound + Self.margin
    }

    func body(content: Content) -> some View {
        content
            .environment(\.chatGlassCulled, culled)
            .onGeometryChange(for: CGRect.self) { geo in
                geo.frame(in: .named(GlassCullViewport.space))
            } action: { frame in
                span = frame.minY...max(frame.minY, frame.maxY)
            }
    }
}

/// One Text action under the menu bar composer: its name in a glass pill, the
/// surface the chat's bubbles use.
private struct QuotedShortcutCard: View {
    let title: String
    let selected: Bool
    let onHover: () -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .sfFont(Tokens.TypeSize.stepDown(Tokens.TypeSize.label), weight: .regular)
                .foregroundStyle(selected ? Tokens.text1 : Tokens.text3)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                // The selected wash menu rows use (`MenuCardRow`).
                .background(Capsule(style: .continuous)
                    .fill(Tokens.ink.opacity(selected ? 0.2 : 0)))
                .smokedGlass(radius: 14)
                // The others step back, as `MenuCardRow`'s dimmed rows do.
                .opacity(selected ? 1 : 0.45)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { if $0 { onHover() } }
        .animation(.easeOut(duration: Tokens.hoverFade), value: selected)
    }
}
