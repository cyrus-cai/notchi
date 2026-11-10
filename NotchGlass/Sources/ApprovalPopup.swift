import AppKit
import SwiftUI

/// A question no Mac surface draws, as one card under the menu bar.
///
/// A round that came in from Telegram, or any round running detached, never
/// reaches `NotchModel.turns`: the island and the top-right card draw the
/// thread on screen, so that round's `ask_user` / confirmation card had nowhere
/// to appear and the question only ever existed as inline buttons in Telegram.
/// This puts the same `UserQuestionCard` on the desktop, so the question can be
/// answered on either side.
///
/// Answering it runs the same `NotchModel.chooseUserOption` the inline card
/// runs, which resolves the one suspended tool call. The card leaves as soon as
/// the question does — answered here, answered in the chat, answered in
/// Telegram, timed out, or the thread opened on a surface that draws it.
@MainActor
final class ApprovalPopup {
    static let shared = ApprovalPopup()

    /// The card's width: the question card's own ceiling (`UserQuestionCard`
    /// caps its content at 340) plus this card's padding, and no wider, so it
    /// reads as a card rather than a panel.
    fileprivate static let width: CGFloat = 372
    fileprivate static let padding: CGFloat = 12
    /// The gap to the menu bar, or to the open top-right card above it.
    private static let gap: CGFloat = 8

    private var panel: ToastPanel?
    private var flight = WindowFlight()
    private var hosting: NSHostingView<AnyView>?
    /// The question on the card, and how to ask whether it still needs one.
    private var shown: UUID?
    private var stillNeeded: ((UUID) -> Bool)?
    /// Checks that once a second while the card is up: a question stops needing
    /// the card when it resolves, and when its thread opens on a surface that
    /// draws it — neither path is this card's to observe, so it looks.
    private var watch: Task<Void, Never>?
    private var screen: NSScreen?
    /// Bumped on every show and dismiss, so a dismissal still in flight cannot
    /// hide the card a later question just put up.
    private var generation = 0

    private init() {}

    /// Put `question` on the card. The same question already up is a no-op.
    func show(_ question: NotchModel.PendingUserQuestion, title: String,
              choose: @escaping (String) -> Void,
              stillNeeded: @escaping (UUID) -> Bool) {
        self.stillNeeded = stillNeeded
        if shown == question.id, let panel, panel.isVisible { return }
        generation += 1
        let screen = NSScreen.containing(NSEvent.mouseLocation) ?? NSScreen.main
        self.screen = screen
        shown = question.id

        let view = ApprovalPopupView(title: title, question: question, choose: choose)
        let hosting = ToastHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(x: 0, y: 0, width: Self.width, height: 10)
        let height = ceil(hosting.fittingSize.height)
        hosting.frame.size.height = height

        let panel = self.panel ?? ToastPanel()
        panel.contentView = hosting
        panel.setFrame(NSRect(x: 0, y: 0, width: Self.width, height: height), display: true)
        // Arrives the way the answer cards do: whole, flying in from the edge.
        let home = homeOrigin(height: height)
        panel.setFrameOrigin(NSPoint(x: home.x + NotchMetrics.floatingTravel, y: home.y))
        panel.orderFrontRegardless()
        // Drawn before it moves: the glass's first draw would eat the flight.
        panel.displayIfNeeded()
        flight.fly(panel, to: home, on: screen)
        self.panel = panel
        self.hosting = hosting
        startWatching()
    }

    /// Take the card down: the question is resolved, or a surface draws it now.
    func dismiss() {
        generation += 1
        watch?.cancel()
        watch = nil
        stillNeeded = nil
        shown = nil
        guard let panel, panel.isVisible else { return }
        let origin = panel.frame.origin
        flight.fly(panel, to: NSPoint(x: origin.x + NotchMetrics.floatingTravel, y: origin.y),
                   on: screen)
        let step = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchModel.cardFlightDuration) { [weak self] in
            guard let self, self.generation == step else { return }
            self.flight.stop()
            self.panel?.orderOut(nil)
        }
    }

    /// Where the card rests: under the open top-right card, or under the menu
    /// bar when that card is closed — the same line the answer cards use.
    private func homeOrigin(height: CGFloat) -> NSPoint {
        guard let screen else { return .zero }
        let top = CardToasts.shared.cardBottom().map { $0 - Self.gap }
            ?? screen.visibleFrame.maxY - NotchMetrics.floatingInset
        return NSPoint(x: screen.frame.maxX - NotchMetrics.floatingInset - Self.width,
                       y: top - height)
    }

    private func startWatching() {
        watch?.cancel()
        watch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let id = self.shown, let check = self.stillNeeded else { return }
                if !check(id) {
                    self.dismiss()
                    return
                }
            }
        }
    }
}

/// The card itself: which conversation is asking, then the question card the
/// chat draws inline.
private struct ApprovalPopupView: View {
    let title: String
    let question: NotchModel.PendingUserQuestion
    let choose: (String) -> Void

    private var shape: NotchShape {
        NotchShape(bottomRadius: Tokens.Radius.shell, topRadius: 0,
                   topCornerRadius: Tokens.Radius.shell)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(title)
                    .font(.sf(Tokens.TypeSize.label))
                    .foregroundStyle(Tokens.text3)
                    .lineLimit(1)
            }
            UserQuestionCard(question: question,
                             font: Tokens.TypeSize.stepDown(Tokens.TypeSize.reading),
                             choose: choose)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ApprovalPopup.padding)
        .background(GlassMaterial(bottomRadius: Tokens.Radius.shell,
                                  topCornerRadius: Tokens.Radius.shell,
                                  expanded: true,
                                  cameraZone: 0,
                                  sweepsOnOpen: false))
        .clipShape(shape)
        .overlay(IslandRim(shape: shape))
        .contentShape(shape)
    }
}
