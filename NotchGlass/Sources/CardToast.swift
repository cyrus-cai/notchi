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

/// Reading-time helpers for reply bubbles that auto-dismiss after reading.
enum ReplyTiming {
    /// How long a bubble stays: the time to read its text, plus a margin.
    /// About 7 CJK characters or 17 other characters a second.
    static func hold(for body: String) -> TimeInterval {
        var cjk = 0
        var other = 0
        for scalar in body.unicodeScalars where !scalar.properties.isWhitespace {
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF,
                 0xF900...0xFAFF, 0xFF00...0xFFEF:
                cjk += 1
            default:
                other += 1
            }
        }
        let reading = Double(cjk) / 7 + Double(other) / 17
        return min(max(2.5 + reading, 4), 20)
    }
}

final class ToastPanel: NSPanel {
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
        // The card is dark glass, like the island; without this its text follows
        // a light-mode Mac into dark ink.
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on a card lands while another app is active, so it must not be spent
/// on activating the window.
final class ToastHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
