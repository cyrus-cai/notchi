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

// MARK: - Floating Drag-to-Authorize Permission Guide

/// A floating dark-glass helper panel that docks beside macOS System Settings
/// and lets the user drag `Notchi.app` straight into the Privacy & Security
/// permission list (e.g. Screen & System Audio Recording).
@MainActor
final class ScreenPermissionGuideController {
    static let shared = ScreenPermissionGuideController()

    private var panel: NSPanel?
    private var trackTimer: Timer?
    private var sawSettingsWindow = false
    private let state = GuideState()

    @MainActor
    final class GuideState: ObservableObject {
        @Published var granted = false
    }

    private init() {}

    func showScreenRecordingGuide() {
        state.granted = CGPreflightScreenCaptureAccess()
        sawSettingsWindow = false

        _ = CGRequestScreenCaptureAccess()
        openScreenRecordingSettings()

        if let existing = panel {
            positionBesideSettings(existing, animated: false)
            existing.orderFrontRegardless()
            startTracking()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 204, height: 164),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NotchPanel.restingLevel
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let rootView = ScreenPermissionGuideView(
            state: state,
            onClose: { [weak self] in self?.dismiss() }
        )
        let host = ToastHostingView(rootView: rootView)
        host.wantsLayer = true
        host.layer?.cornerRadius = 14
        host.layer?.masksToBounds = true
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        let fit = host.fittingSize
        let size = NSSize(
            width: max(204, fit.width),
            height: max(156, fit.height)
        )
        panel.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        panel.invalidateShadow()

        self.panel = panel
        positionBesideSettings(panel, animated: false)
        panel.orderFrontRegardless()
        startTracking()
    }

    func dismiss() {
        trackTimer?.invalidate()
        trackTimer = nil
        sawSettingsWindow = false
        panel?.orderOut(nil)
        panel = nil
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startTracking() {
        trackTimer?.invalidate()
        trackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    private func tick() {
        guard let panel else {
            dismiss()
            return
        }

        if CGPreflightScreenCaptureAccess() {
            if !state.granted {
                state.granted = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                    self?.dismiss()
                }
            }
            return
        }

        if let settingsFrame = Self.systemSettingsWindowFrame() {
            sawSettingsWindow = true
            position(panel, beside: settingsFrame, animated: true)
        } else if sawSettingsWindow {
            // System Settings was closed by the user: dismiss the helper too.
            dismiss()
        }
    }

    private func positionBesideSettings(_ panel: NSPanel, animated: Bool) {
        if let settingsFrame = Self.systemSettingsWindowFrame() {
            sawSettingsWindow = true
            position(panel, beside: settingsFrame, animated: animated)
            return
        }
        // Fallback before System Settings finishes opening: center-right on main screen.
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX + 180,
            y: visible.midY - size.height / 2
        )
        panel.setFrameOrigin(clamped(origin, size: size, in: visible))
    }

    private func position(_ panel: NSPanel, beside settingsFrame: NSRect, animated: Bool) {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(settingsFrame) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        let gap: CGFloat = 14

        // Dock cleanly outside System Settings (never overlapping its toggles):
        // prefer right, then left, then centered below.
        let rightX = settingsFrame.maxX + gap
        let leftX = settingsFrame.minX - size.width - gap
        let origin: NSPoint
        if rightX + size.width <= visible.maxX - 8 {
            origin = NSPoint(x: rightX, y: settingsFrame.midY - size.height / 2)
        } else if leftX >= visible.minX + 8 {
            origin = NSPoint(x: leftX, y: settingsFrame.midY - size.height / 2)
        } else {
            origin = NSPoint(
                x: settingsFrame.midX - size.width / 2,
                y: settingsFrame.minY - size.height - gap
            )
        }
        let target = clamped(origin, size: size, in: visible)

        let current = panel.frame.origin
        guard hypot(target.x - current.x, target.y - current.y) > 2 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrameOrigin(target)
            }
        } else {
            panel.setFrameOrigin(target)
        }
    }

    private func clamped(_ origin: NSPoint, size: NSSize, in visible: NSRect) -> NSPoint {
        let minX = visible.minX + 8
        let maxX = max(minX, visible.maxX - size.width - 8)
        let minY = visible.minY + 8
        let maxY = max(minY, visible.maxY - size.height - 8)
        return NSPoint(
            x: min(max(origin.x, minX), maxX),
            y: min(max(origin.y, minY), maxY)
        )
    }

    /// Finds the frontmost on-screen System Settings window in AppKit screen coordinates.
    private static func systemSettingsWindowFrame() -> NSRect? {
        guard let settingsApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.systempreferences"
        ).first else { return nil }
        let pid = settingsApp.processIdentifier

        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid else { continue }
            guard (info[kCGWindowLayer as String] as? Int ?? -1) == 0 else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict),
                  cgRect.width >= 300, cgRect.height >= 240 else { continue }
            let appKitY = primaryHeight - cgRect.origin.y - cgRect.height
            return NSRect(x: cgRect.origin.x, y: appKitY,
                          width: cgRect.width, height: cgRect.height)
        }
        return nil
    }
}

private struct ScreenPermissionGuideView: View {
    @ObservedObject var state: ScreenPermissionGuideController.GuideState
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if state.granted {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.green)
                    Text(L("permissions.status.granted"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                VStack(spacing: 8) {
                    DraggableAppBundleTile()
                        .frame(width: 64, height: 64)

                    Text(L("screenshot.permission.dragCaption"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)

                    Text(L("screenshot.permission.dragHint"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
                .padding(.bottom, 16)
                .padding(.horizontal, 16)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(6)
        }
        .frame(width: 204)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

/// Native AppKit drag source exposing `Bundle.main.bundleURL` as a real Finder
/// file-URL pasteboard item so macOS System Settings accepts the drop reliably.
private struct DraggableAppBundleTile: NSViewRepresentable {
    func makeNSView(context: Context) -> DraggableBundleNSView {
        DraggableBundleNSView()
    }

    func updateNSView(_ nsView: DraggableBundleNSView, context: Context) {}
}

private final class DraggableBundleNSView: NSView, NSDraggingSource {
    private var dragOrigin: NSPoint?
    private var isDragging = false
    private let iconView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let appURL = Bundle.main.bundleURL
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 56, height: 56)
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.push()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.pop()
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, !isDragging else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - origin.x, current.y - origin.y) >= 3 else { return }

        isDragging = true
        let url = Bundle.main.bundleURL as NSURL
        let item = NSDraggingItem(pasteboardWriter: url)
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = NSSize(width: 56, height: 56)
        let frame = NSRect(x: current.x - 28, y: current.y - 28, width: 56, height: 56)
        item.setDraggingFrame(frame, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .link]
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        isDragging = false
        dragOrigin = nil
    }
}

// MARK: - Screenshot Fly-In Animation

/// Animates a newly captured screenshot flying smoothly into the notch, the
/// top-right menu bar card, or a detached thread window, calling `onArrive`
/// right as the card enters the target so the panel opens and catches it in
/// one continuous motion.
@MainActor
enum ScreenshotFlyInAnimator {
    enum Style {
        /// Full-screen capture: starts at the full display frame with a brief
        /// shutter flash, then shrinks and arcs into the target.
        case fullScreen
        /// Interactive area capture: lifts from near the pointer / screen
        /// center as a rounded card and flies into the target.
        case area
    }

    private static var activeWindows: [NSWindow] = []

    /// Computes the screen-space landing point for the notch or menu bar card.
    static func targetPoint(
        for display: CGDirectDisplayID?,
        captureDisplay: CGDirectDisplayID? = nil,
        activeDisplay: CGDirectDisplayID?,
        panelOpen: Bool,
        detachedWindow: NSWindow? = nil
    ) -> (point: NSPoint, screen: NSScreen) {
        if let detachedWindow, detachedWindow.isVisible {
            let f = detachedWindow.frame
            let screen = detachedWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
            return (NSPoint(x: f.midX, y: f.minY + min(72, f.height * 0.25)), screen)
        }

        let effectiveDisplay = panelOpen ? (activeDisplay ?? display) : display
        let isMenuBarCard = effectiveDisplay == NotchModel.menuBarCardDisplay

        // If a NotchPanel is currently visible on screen, fly straight into its
        // composer region rather than the resting edge.
        if panelOpen,
           let panel = NSApp.windows.first(where: { $0 is NotchPanel && $0.isVisible && $0.frame.height > 80 }) {
            let f = panel.frame
            let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
            return (NSPoint(x: f.midX, y: f.maxY - min(110, f.height * 0.45)), screen)
        }

        let screen = screenForDisplay(isMenuBarCard ? captureDisplay : (effectiveDisplay ?? captureDisplay))
            ?? NSScreen.containing(NSEvent.mouseLocation)
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        if isMenuBarCard {
            return (NSPoint(x: screen.frame.maxX - 160, y: screen.frame.maxY - 28), screen)
        }
        return (NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 18), screen)
    }

    static func play(
        image: NSImage,
        style: Style,
        targetPoint: NSPoint,
        on screen: NSScreen,
        onArrive: @escaping @MainActor () -> Void
    ) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            onArrive()
            return
        }

        let screenFrame = screen.frame
        let overlay = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        overlay.level = NSWindow.Level(rawValue: NotchPanel.restingLevel.rawValue + 2)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.ignoresMouseEvents = true
        overlay.hasShadow = false
        overlay.isReleasedWhenClosed = false
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let root = NSView(frame: NSRect(origin: .zero, size: screenFrame.size))
        root.wantsLayer = true
        overlay.contentView = root
        guard let rootLayer = root.layer else {
            onArrive()
            return
        }

        // Convert screen-space target to overlay-local coordinates.
        let localTarget = CGPoint(
            x: targetPoint.x - screenFrame.origin.x,
            y: targetPoint.y - screenFrame.origin.y
        )

        // Starting rectangle in overlay-local coordinates.
        let startRect: CGRect
        switch style {
        case .fullScreen:
            startRect = CGRect(origin: .zero, size: screenFrame.size)
        case .area:
            let aspect = max(0.35, min(2.8, CGFloat(cgImage.width) / max(1, CGFloat(cgImage.height))))
            let maxW: CGFloat = 280
            let maxH: CGFloat = 200
            let w: CGFloat
            let h: CGFloat
            if maxW / aspect <= maxH {
                w = maxW
                h = maxW / aspect
            } else {
                h = maxH
                w = maxH * aspect
            }
            let mouse = NSEvent.mouseLocation
            let localMouse = CGPoint(
                x: mouse.x - screenFrame.origin.x,
                y: mouse.y - screenFrame.origin.y
            )
            let cx = min(max(localMouse.x, w / 2 + 24), screenFrame.width - w / 2 - 24)
            let cy = min(max(localMouse.y, h / 2 + 24), screenFrame.height - h / 2 - 60)
            startRect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        }

        // Subtle shutter flash on full-screen capture so the instant capture
        // feels tactile and responsive.
        if style == .fullScreen {
            let flash = CALayer()
            flash.frame = CGRect(origin: .zero, size: screenFrame.size)
            flash.backgroundColor = NSColor.white.cgColor
            flash.opacity = 0
            rootLayer.addSublayer(flash)

            let flashAnim = CAKeyframeAnimation(keyPath: "opacity")
            flashAnim.values = [0.0, 0.22, 0.0]
            flashAnim.keyTimes = [0.0, 0.2, 1.0]
            flashAnim.duration = 0.16
            flashAnim.isRemovedOnCompletion = true
            flash.add(flashAnim, forKey: "flash")
        }

        // Flying screenshot card layer (shadow container + rounded image mask).
        let endSize = CGSize(width: 44, height: 30)
        let endRect = CGRect(
            x: localTarget.x - endSize.width / 2,
            y: localTarget.y - endSize.height / 2,
            width: endSize.width,
            height: endSize.height
        )

        let card = CALayer()
        card.frame = startRect
        card.contents = cgImage
        card.contentsGravity = .resizeAspectFill
        card.masksToBounds = true
        card.cornerRadius = style == .fullScreen ? 0 : 12
        card.borderWidth = style == .fullScreen ? 0 : 1
        card.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        rootLayer.addSublayer(card)

        activeWindows.append(overlay)
        overlay.orderFrontRegardless()

        let duration: CFTimeInterval = style == .fullScreen ? 0.36 : 0.30
        let timing = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)

        let posAnim = CABasicAnimation(keyPath: "position")
        posAnim.fromValue = CGPoint(x: startRect.midX, y: startRect.midY)
        posAnim.toValue = CGPoint(x: endRect.midX, y: endRect.midY)

        let boundsAnim = CABasicAnimation(keyPath: "bounds")
        boundsAnim.fromValue = CGRect(origin: .zero, size: startRect.size)
        boundsAnim.toValue = CGRect(origin: .zero, size: endRect.size)

        let radiusAnim = CABasicAnimation(keyPath: "cornerRadius")
        radiusAnim.fromValue = card.cornerRadius
        radiusAnim.toValue = CGFloat(10)

        let borderAnim = CABasicAnimation(keyPath: "borderWidth")
        borderAnim.fromValue = card.borderWidth
        borderAnim.toValue = CGFloat(1.2)

        let opacityAnim = CAKeyframeAnimation(keyPath: "opacity")
        opacityAnim.values = [1.0, 1.0, 0.0]
        opacityAnim.keyTimes = [0.0, 0.72, 1.0]

        let group = CAAnimationGroup()
        group.animations = [posAnim, boundsAnim, radiusAnim, borderAnim, opacityAnim]
        group.duration = duration
        group.timingFunction = timing
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        card.add(group, forKey: "flyIn")

        // Trigger panel open + attachment right as the card enters the notch/card
        // so the island catches the screenshot in one continuous motion.
        let arriveDelay = duration * 0.62
        DispatchQueue.main.asyncAfter(deadline: .now() + arriveDelay) {
            onArrive()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.04) {
            overlay.orderOut(nil)
            activeWindows.removeAll { $0 === overlay }
        }
    }

    private static func screenForDisplay(_ displayID: CGDirectDisplayID?) -> NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }
}
