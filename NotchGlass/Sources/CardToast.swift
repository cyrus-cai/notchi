import AppKit
import SwiftUI

/// Moves a window along a straight line, one step per display frame. Moving a
/// window without resizing it redraws nothing, so this keeps up with the screen's
/// refresh rate. The top-right card and its answer cards share it, so every card
/// flies the same way.
@MainActor
final class WindowFlight: NSObject {
    private weak var window: NSWindow?
    private var from: NSPoint = .zero
    private var to: NSPoint = .zero
    private var start: CFTimeInterval?
    private var link: CADisplayLink?

    func fly(_ window: NSWindow, to target: NSPoint, on screen: NSScreen?) {
        stop()
        guard let screen = screen ?? window.screen ?? NSScreen.main else { return }
        self.window = window
        from = window.frame.origin
        to = target
        let link = screen.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Change where a flight in progress ends, or move there now if none is.
    func retarget(_ window: NSWindow, to target: NSPoint, on screen: NSScreen?) {
        if link != nil {
            to = target
        } else {
            fly(window, to: target, on: screen)
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
        start = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let window else { return stop() }
        let start = self.start ?? link.timestamp
        self.start = start
        let t = min(1, (link.targetTimestamp - start) / NotchModel.cardFlightDuration)
        let eased = t * t * (3 - 2 * t)
        window.setFrameOrigin(NSPoint(x: from.x + (to.x - from.x) * eased,
                                      y: from.y + (to.y - from.y) * eased))
        if t >= 1 { stop() }
    }
}

/// The answers to questions sent from the top-right card, one card per message,
/// stacked under the menu bar. A card lands at its message's reply tone, so it is
/// never queued: with the stack full the oldest leaves. They take neither focus
/// nor activation; a click on one opens its thread in the top-right card.
@MainActor
final class CardToasts {
    static let shared = CardToasts()

    /// Opens a thread in the top-right card. Set by `AppDelegate`.
    var openThread: (UUID) -> Void = { _ in }
    /// The open top-right card's bottom edge on screen, nil while it is closed.
    /// The cards stack below it.
    var cardBottom: () -> CGFloat? = { nil }

    private static let width: CGFloat = Tokens.openWidthIdle * NotchMetrics.floatingWidthScale
    private static let gap: CGFloat = 8
    private static let maxShown = 3
    static let questionHold: TimeInterval = 30
    /// How long a card stays once the pointer leaves it.
    private static let holdAfterHover: TimeInterval = 4

    static func hold(for body: String) -> TimeInterval {
        body.count > 120 ? 12 : 8
    }

    fileprivate final class Content: ObservableObject {
        @Published var body: String
        init(body: String) { self.body = body }
    }

    /// One card. A message still arriving updates its own.
    @MainActor
    final class Toast {
        fileprivate let threadID: UUID
        fileprivate let content: Content
        fileprivate let panel = ToastPanel()
        fileprivate let flight = WindowFlight()
        fileprivate var dismissal: DispatchWorkItem?
        fileprivate var hovered = false
        fileprivate var hold: TimeInterval
        fileprivate var size: () -> CGFloat = { 0 }

        fileprivate init(threadID: UUID, body: String, hold: TimeInterval) {
            self.threadID = threadID
            self.content = Content(body: body)
            self.hold = hold
        }

        func update(body: String) {
            guard body != content.body else { return }
            content.body = body
            hold = CardToasts.hold(for: body)
            CardToasts.shared.bodyChanged(self)
        }
    }

    private var shown: [Toast] = []
    /// The screen the stack is on, kept until it empties.
    private var screen: NSScreen?

    @discardableResult
    func show(threadID: UUID, title: String, body: String, hold: TimeInterval) -> Toast {
        if shown.isEmpty {
            screen = NSScreen.containing(NSEvent.mouseLocation) ?? NSScreen.main
        }
        if shown.count >= Self.maxShown, let oldest = shown.first { dismiss(oldest) }

        let toast = Toast(threadID: threadID, body: body, hold: hold)
        let view = CardToastView(
            title: title,
            content: toast.content,
            onHover: { [weak self, weak toast] inside in
                guard let self, let toast else { return }
                toast.hovered = inside
                if inside {
                    toast.dismissal?.cancel()
                } else {
                    self.scheduleDismissal(toast, after: Self.holdAfterHover)
                }
            },
            onTap: { [weak self, weak toast] in
                guard let self, let toast else { return }
                self.openThread(toast.threadID)
                self.dismiss(toast)
            })
            .environmentObject(Localization.shared)
        let hosting = ToastHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: Self.width, height: 10)
        toast.size = { [weak hosting] in ceil(hosting?.fittingSize.height ?? 0) }
        let height = toast.size()
        hosting.frame.size.height = height
        toast.panel.contentView = hosting

        let home = homeOrigin(index: shown.count, height: height)
        toast.panel.setFrame(NSRect(x: home.x + NotchMetrics.floatingTravel, y: home.y,
                                    width: Self.width, height: height), display: false)
        toast.panel.orderFrontRegardless()
        // Drawn before it moves: the first draw of the glass would otherwise eat
        // the flight's first frames.
        toast.panel.displayIfNeeded()
        shown.append(toast)
        toast.flight.fly(toast.panel, to: home, on: screen)
        scheduleDismissal(toast, after: hold)
        return toast
    }

    /// The text of a message still arriving changed: fit the card, its top edge
    /// held, and restart its stay.
    fileprivate func bodyChanged(_ toast: Toast) {
        guard shown.contains(where: { $0 === toast }) else { return }
        scheduleDismissal(toast, after: toast.hold)
        let height = toast.size()
        var frame = toast.panel.frame
        guard height != frame.height else { return }
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        toast.panel.setFrame(frame, display: true)
        relayout()
    }

    private func scheduleDismissal(_ toast: Toast, after delay: TimeInterval) {
        toast.dismissal?.cancel()
        guard !toast.hovered else { return }
        let work = DispatchWorkItem { [weak self, weak toast] in
            guard let self, let toast else { return }
            self.dismiss(toast)
        }
        toast.dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func dismiss(_ toast: Toast) {
        toast.dismissal?.cancel()
        guard let index = shown.firstIndex(where: { $0 === toast }) else { return }
        shown.remove(at: index)
        let origin = toast.panel.frame.origin
        toast.flight.fly(toast.panel,
                         to: NSPoint(x: origin.x + NotchMetrics.floatingTravel, y: origin.y),
                         on: screen)
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchModel.cardFlightDuration) {
            toast.flight.stop()
            toast.panel.orderOut(nil)
        }
        relayout()
    }

    /// Move the cards to their places: under the menu bar, or under the open
    /// top-right card.
    func relayout() {
        for (index, toast) in shown.enumerated() {
            let home = homeOrigin(index: index, height: toast.panel.frame.height)
            if toast.panel.frame.origin != home {
                toast.flight.retarget(toast.panel, to: home, on: screen)
            }
        }
    }

    private func homeOrigin(index: Int, height: CGFloat) -> NSPoint {
        guard let screen else { return .zero }
        var top = cardBottom().map { $0 - Self.gap }
            ?? screen.visibleFrame.maxY - NotchMetrics.floatingInset
        for toast in shown.prefix(index) {
            top -= toast.panel.frame.height + Self.gap
        }
        return NSPoint(x: screen.frame.maxX - NotchMetrics.floatingInset - Self.width,
                       y: top - height)
    }
}

private final class ToastPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NotchPanel.restingLevel
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on a card lands while another app is active, so it must not be spent
/// on activating the window.
private final class ToastHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct CardToastView: View {
    let title: String
    @ObservedObject var content: CardToasts.Content
    let onHover: (Bool) -> Void
    let onTap: () -> Void

    private var shape: NotchShape {
        NotchShape(bottomRadius: Tokens.Radius.shell, topRadius: 0,
                   topCornerRadius: Tokens.Radius.shell)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.sf(Tokens.TypeSize.label))
                    .foregroundStyle(Tokens.text3)
                    .lineLimit(1)
            }
            Text(content.body)
                .font(.sf(Tokens.TypeSize.reading))
                .foregroundStyle(Tokens.text1)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(NotchBody.panelPadding + 6)
        .background(GlassMaterial(bottomRadius: Tokens.Radius.shell,
                                  topCornerRadius: Tokens.Radius.shell,
                                  expanded: true,
                                  cameraZone: 0,
                                  sweepsOnOpen: false))
        .clipShape(shape)
        .overlay(IslandRim(shape: shape))
        .contentShape(shape)
        .onHover(perform: onHover)
        .onTapGesture(perform: onTap)
    }
}
