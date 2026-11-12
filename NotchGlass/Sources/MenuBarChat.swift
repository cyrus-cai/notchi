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
    static let maxMessagesHeight: CGFloat = 440
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
    private static let glassGutter: CGFloat = 6
    private static let bottomID = "menuBarChat.bottom"
    private static let topID = "menuBarChat.top"
    /// The widest a bubble gets, as a share of the column. The composer is as
    /// wide, so the column has one right edge.
    private static let bubbleWidthFraction: CGFloat = 0.86
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
        let room = NotchMetrics.canvasHeight - NotchMetrics.chatTopGap - 10 - composerHeight - 12
        return max(120, min(Self.maxMessagesHeight, room))
    }
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
    /// The header's side-page mark has its menu down.
    @State private var sidePageMenuOpen = false
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
        // An agent task runs on its own, not in this thread, so the agent
        // prompt shows no messages above it.
        if model.agentComposeActive { return [] }
        return thread.filter { turn in
            turn.example == nil && !(turn.role == "user" && turn.hidesUserBubble)
        }
    }

    /// The thread is the one `model.turns` holds, so its messages take actions.
    private var onScreen: Bool { !model.turns.isEmpty }

    private var overflows: Bool { overflowLatched || contentHeight > messagesCap }

    // MARK: - Body

    var body: some View {
        let turns = shownTurns
        VStack(alignment: .leading, spacing: 10) {
            if model.showRoutines {
                sidePage
                    .transition(.opacity)
                    .transaction(stillWhileClosed)
            } else if !turns.isEmpty {
                messages(turns)
                    // Over the messages' top, ending at the bubbles' right
                    // edge. Takes no height of its own.
                    .overlay(alignment: .topLeading) {
                        headerChips
                            .frame(width: NotchMetrics.chatWidth * Self.bubbleWidthFraction,
                                   alignment: .trailing)
                            .padding(.top, 10)
                    }
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
        .opacity(revealed ? 1 : 0)
        .background(CardFoldAnchor(fold: fold))
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
                withTransaction(quiet) {
                    revealed = false
                    // Like leaving the thread in the panel: the next open
                    // shows the chat, not the side page.
                    model.showRoutines = false
                }
                fold.reset()
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: model.showRoutines)
        .onAppear { openPagesInWindows() }
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

    /// The panel's header trio on this card: the side page, the cloud machine,
    /// and the pin. Laid over the top of the messages, right-aligned with the
    /// bubbles. One group: bare glyphs over a single soft dark blur.
    private var headerChips: some View {
        HStack(spacing: 6) {
            CloudMachineStatusChip(glass: false, bareChip: false) {
                model.settingsSection = InlineSettingsView.Section.chat.rawValue
                model.openSettings()
            }
            GlassSegmentCluster(segments: [
                .init(engaged: model.isAnswerPinned,
                      tooltip: shortcutHelp(model.isAnswerPinned ? "result.unpin" : "result.pin",
                                            action: .pin),
                      action: {
                          withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                              model.toggleAnswerPin()
                          }
                      }) {
                    PinStateGlyph(pinned: model.isAnswerPinned, size: 12, weight: .light)
                },
                .init(id: "sidePage",
                      engaged: model.showRoutines,
                      tooltip: L("recent.manage"),
                      action: { sidePageMenuOpen.toggle() }) {
                    Image(systemName: "sidebar.right")
                        .sfFont(13, weight: .light)
                },
            ], glass: false, bareChip: false)
            .modifier(MenuCardWindow(open: sidePageMenuOpen,
                                     lowerTrailing: true,
                                     onDismiss: { _ in sidePageMenuOpen = false },
                                     card: { AnyView(sidePageMenu) }))
        }
        .padding(.horizontal, 4)
        .background {
            ZStack {
                BackdropBlur(radius: 12, spot: true)
                    .padding(-Self.chipBlurSpread)
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.6))
                    .padding(-4)
                    .blur(radius: 8)
            }
            .allowsHitTesting(false)
        }
    }

    /// How far the blur behind the header chips spreads past them.
    private static let chipBlurSpread: CGFloat = 16

    /// The side-page mark's card: the same three rows the panel's ⋯ holds.
    /// Choosing a tab shows the side page in place of the messages.
    private var sidePageMenu: some View {
        let detach = L("detached.open")
        let routines = L("routines.title")
        let copies = L("copyThread.tab")
        return VStack(alignment: .leading, spacing: MenuCard.rowSpacing) {
            if NotchModel.detachedWindowsEnabled {
                MenuCardRow(title: detach, selected: false) {
                    sidePageMenuOpen = false
                    model.openDetachedWindow()
                }
            }
            MenuCardRow(title: routines,
                        selected: model.showRoutines && model.sidePageTab == .routines) {
                sidePageMenuOpen = false
                openSidePage(.routines)
            }
            MenuCardRow(title: copies,
                        selected: model.showRoutines && model.sidePageTab == .copies) {
                sidePageMenuOpen = false
                openSidePage(.copies)
            }
        }
        .padding(MenuCard.cardPad)
        .frame(width: MenuCard.width(titles: [(detach, nil), (routines, nil), (copies, nil)]))
        .manageMenuCardBackground()
    }

    /// Open the side page on `tab`, or close it when that tab already shows.
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
        RoutinesPanel(tab: $model.sidePageTab,
                      onClose: { model.showRoutines = false },
                      copies: { AnyView(copyThreadTab) })
            .frame(width: NotchMetrics.chatWidth * Self.bubbleWidthFraction,
                   height: messagesCap)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.shell, style: .continuous))
    }

    /// The Sub-thread tab: the copy thread, as this card draws messages.
    @ViewBuilder
    private var copyThreadTab: some View {
        let turns = model.copyThreadConversation.filter(\.isDrawn)
        if turns.isEmpty {
            Text(L("copyThread.empty"))
                .sfFont(Tokens.TypeSize.label)
                .foregroundStyle(Tokens.text4)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Spacer(minLength: 0)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: Self.bubbleGap) {
                        ForEach(Array(turns.enumerated()), id: \.element.id) { i, turn in
                            ChatRow(turn: turn, model: model,
                                    isLast: i == turns.count - 1,
                                    question: turns.question(at: i),
                                    recentCards: [],
                                    onScreen: false,
                                    live: nil, streamingNow: false, askFailed: false)
                                .equatable()
                                .modifier(ThreadScrollLagOffset())
                        }
                    }
                    .modifier(ThreadScrollLagHost())
                    .padding(.bottom, NotchBody.panelPadding)
                    .background(EnclosingScrollViewReporter { ThreadScrollLag.shared.attach($0) })
                    Color.clear.frame(height: 0).id(Self.bottomID)
                }
                .environment(\.cardWidthFraction, 1)
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
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
                                    onScreen: onScreen,
                                    live: turn.streaming ? model.chatLiveStatus : nil,
                                    streamingNow: id == lastID && model.isStreaming,
                                    askFailed: id == lastID && model.visibleAskError != nil)
                                .equatable()
                                .modifier(ThreadScrollLagOffset())
                        }
                    }
                }
                .modifier(ThreadScrollLagHost())
                .background(EnclosingScrollViewReporter { ThreadScrollLag.shared.attach($0) })
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
            .modifier(TrackScrollEnd(position: scroll, changed: { end in
                if followsEnd != end { followsEnd = end }
            }, reachedTop: {
                let turns = shownTurns
                let start = mountedStart(in: turns)
                guard start > 0 else { return }
                loadOlder(proxy, keeping: turns[start].id)
            }))
            .frame(height: overflows ? messagesCap + Self.composerOverlap
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
            .contentShape(shape)
            .contextMenu { chatMenu }
            .onHover { hovering in
                withAnimation(.easeOut(duration: Tokens.hoverFade)) { composerHovering = hovering }
            }
            .frame(width: NotchMetrics.chatWidth * Self.bubbleWidthFraction)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
    }

    /// A menu opened from the bottom row is up. The pointer has left the
    /// composer for the menu, and the row (the menu's anchor) has to stay.
    private var bottomRowMenuOpen: Bool {
        model.showModelPicker || model.showAskModelPicker || model.showAgentPicker
            || model.showAgentFolderPicker || model.showLoopIntervalPicker
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
                UserQuestionBubble(text: turn.text, baseFont: MenuBarChat.baseFont,
                                   isAgent: turn.isAgent,
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
                baseFont: MenuBarChat.baseFont,
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer {
        guard let backdrop = NSClassFromString("CABackdropLayer") as? CALayer.Type else {
            return CALayer()
        }
        let layer = backdrop.init()
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
