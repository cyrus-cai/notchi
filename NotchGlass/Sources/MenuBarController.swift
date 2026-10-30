import AppKit
import SwiftUI

/// The menu bar item — the app's only always-visible affordance besides the
/// notch itself. Notch is an `.accessory` app with no Dock icon by default, so
/// without it the only way in is hovering the notch or the summon shortcut.
///
/// Layout follows the usual menu-bar utility convention: the two or three
/// things you actually come here to *do* on top, the one setting you flip most
/// often as a submenu, then the housekeeping block (version / what's new /
/// update) and Quit. Nothing here is a feature of its own — every item routes
/// into a path the panel already owns, so the menu can never drift from the app.
///
/// One click on the icon opens or closes the top-right card (`Actions.toggleCard`).
/// A double-click, right-click or control-click shows the menu.
///
/// The menu is rebuilt on every open (`menuNeedsUpdate`) rather than held live:
/// the model list, the update phase and the interface language all change under
/// it, and a rebuild is microseconds against a user-initiated click.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// What the menu can ask the app to do. Injected by `AppDelegate` so the
    /// display-resolution logic (which screen a summoned panel lands on) stays
    /// in one place instead of being reimplemented here.
    struct Actions {
        var toggleCard: () -> Void
        var closeCard: () -> Void
        var openNotch: () -> Void
        var openHistory: () -> Void
        var openSettings: () -> Void
        var openModelSettings: () -> Void
        var openWhatsNew: () -> Void
        var checkForUpdates: () -> Void
        /// The Force Touch pause. While it runs the gesture's own popup — where it
        /// was turned off — can't be summoned, so this menu is the only place it can
        /// be brought back early, which is why it reports the window, offers the way
        /// out, and stays installed for the duration (see `apply`).
        var isForceTouchDisabled: () -> Bool
        var forceTouchResumesAt: () -> Date?
        var resumeForceTouch: () -> Void
        /// True while a screen's panel sits in the top-right corner (a Dynamic
        /// Island screen). That panel has no resting island to hover, so this
        /// item and the summon shortcut are the only ways to open it.
        var isRequired: () -> Bool
    }

    private var statusItem: NSStatusItem?
    private let actions: Actions
    /// The mood of the work running now, nil when idle. With the face style
    /// the eyes play it, the same forms the resting notch's NotchiMark plays.
    private var workMood: NotchiMark.Mood?
    private var frameTimer: Timer?
    /// When the last left click landed, to tell a double-click from a single one.
    private var lastClickAt: TimeInterval?

    init(actions: Actions) {
        self.actions = actions
        super.init()
    }

    // MARK: - Presence

    /// Create or tear down the status item to match the persisted setting — with
    /// two overrides: while Force Touch is paused the icon stays, because it is the
    /// only place the gesture can be brought back before the window is up; and
    /// while a corner panel exists (`Actions.isRequired`).
    func apply() {
        if MenuBarIconVisibility.current == .shown || actions.isForceTouchDisabled()
            || actions.isRequired() {
            install()
            statusItem?.button?.image = Self.statusIcon(MenuBarIconStyle.current)
        } else {
            remove()
        }
        updateAnimation()
    }

    /// Called whenever the notch's work changes: a round or an agent run
    /// starts, changes what it is doing, or ends.
    func setWork(_ mood: NotchiMark.Mood?) {
        guard mood != workMood else { return }
        workMood = mood
        updateAnimation()
    }

    private func updateAnimation() {
        let animate = workMood != nil && statusItem != nil
            && MenuBarIconStyle.current == .face
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate {
            guard frameTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.drawFrame() }
            }
            // .common keeps it running while the menu is open.
            RunLoop.main.add(timer, forMode: .common)
            frameTimer = timer
        } else if let timer = frameTimer {
            timer.invalidate()
            frameTimer = nil
            statusItem?.button?.image = Self.statusIcon(MenuBarIconStyle.current)
        }
    }

    private func drawFrame() {
        guard let mood = workMood else { return }
        let blobs = NotchiDirector.work.blobs(at: Date.timeIntervalSinceReferenceDate, mood: mood)
        statusItem?.button?.image = Self.faceIcon(blobs)
    }

    private func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.statusIcon(MenuBarIconStyle.current)
            button.imagePosition = .imageOnly
            button.toolTip = "Notchi"
            button.setAccessibilityLabel("Notchi")
            if DebugFeatureFlags.menuBarCard {
                button.target = self
                button.action = #selector(statusItemClicked)
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
        }
        if !DebugFeatureFlags.menuBarCard {
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
        }
        statusItem = item
    }

    private func remove() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    /// The app icon's mark, drawn at menu-bar size — the glyph alone, without the
    /// cream plate the Dock icon sits on. That's the menu bar's own convention
    /// (every system item and every well-behaved third-party one is a bare
    /// glyph), and it's the only version that survives both bars: a fixed cream
    /// plate all but disappears on a light menu bar, while a template glyph
    /// inverts with the appearance for free.
    ///
    /// Drawn rather than scaled from the PNG so it stays crisp at any scale. The
    /// geometry is lifted off the app icon, which is built on a 3×3 grid: an
    /// L covering the top-left 2×2 block plus the cell below its left half, and a
    /// dot inscribed in the bottom-right cell.
    ///
    /// Two departures from the Dock icon, both to stop it shouting: the corners
    /// are filleted, and the whole mark sits at 13pt rather than filling the
    /// bar's full content height. Hard 90° corners at 13pt, against a row of
    /// light SF Symbols, read as a black wedge louder than everything beside it.
    static func statusIcon(_ style: MenuBarIconStyle) -> NSImage {
        if style == .face { return faceIcon() }
        let side: CGFloat = 13
        let icon = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let u = rect.width / 3
            NSColor.black.setFill()
            // The L, counter-clockwise from the bottom-left. AppKit's y grows
            // upward, so the icon's top-left block is the high one. The vertex at
            // (u, u) is the inside corner, and gets an inward fillet from the same
            // tangent-arc call — no special case needed.
            let corners: [NSPoint] = [
                NSPoint(x: 0, y: 0), NSPoint(x: u, y: 0), NSPoint(x: u, y: u),
                NSPoint(x: 2 * u, y: u), NSPoint(x: 2 * u, y: 3 * u), NSPoint(x: 0, y: 3 * u),
            ]
            let radius = u * 0.24
            let path = NSBezierPath()
            // Start mid-edge so the first arc has a full straight run to sit on.
            let last = corners[corners.count - 1]
            path.move(to: NSPoint(x: (last.x + corners[0].x) / 2,
                                  y: (last.y + corners[0].y) / 2))
            for (i, corner) in corners.enumerated() {
                path.appendArc(from: corner, to: corners[(i + 1) % corners.count],
                               radius: radius)
            }
            path.close()
            path.fill()
            NSBezierPath(ovalIn: NSRect(x: 2 * u, y: 0, width: u, height: u)).fill()
            return true
        }
        // Template: macOS paints it in the menu bar's own label color, so it reads
        // on a light bar and a dark one without shipping two assets.
        icon.isTemplate = true
        return icon
    }

    /// The face's two eyes (`NotchiEyeShape`) at menu-bar size, as a template
    /// like the mark: 10pt tall, about 18pt wide. Drawn from `NotchiBlob`s so
    /// the same image can show any frame of a `NotchiDirector` run; the canvas
    /// is 22pt square so forms that travel past the eyes stay inside it, and
    /// the item does not change width when the eyes start moving.
    private static func faceIcon(_ blobs: [NotchiBlob] = NotchiForm.restingEyes) -> NSImage {
        let unit: CGFloat = 10
        let side: CGFloat = 22
        let icon = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let c = CGPoint(x: rect.midX, y: rect.midY)
            for b in blobs.sorted(by: { $0.z < $1.z }) {
                let w = CGFloat(b.w) * unit, h = CGFloat(b.h) * unit
                guard w > 0.05, h > 0.05, b.alpha > 0.01 else { continue }
                let cap = min(w, h) / 2
                func r(_ v: Double) -> CGFloat { min(CGFloat(v) * unit, cap) }
                let shape = UnevenRoundedRectangle(
                    cornerRadii: .init(topLeading: r(b.tl), bottomLeading: r(b.bl),
                                       bottomTrailing: r(b.br), topTrailing: r(b.tr)),
                    style: .continuous
                ).path(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                let move = CGAffineTransform(translationX: c.x + CGFloat(b.x) * unit,
                                             y: c.y + CGFloat(b.y) * unit)
                    .rotated(by: CGFloat(b.rot))
                ctx.addPath(shape.applying(move).cgPath)
                ctx.setFillColor(NSColor.black.withAlphaComponent(b.alpha).cgColor)
                ctx.fillPath()
            }
            return true
        }
        icon.isTemplate = true
        return icon
    }

    // MARK: - Clicks

    /// The first click acts at once, so a single click has no double-click delay.
    /// The second click of a double-click closes the card that click opened and
    /// shows the menu.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastClickAt, now - last <= NSEvent.doubleClickInterval {
            lastClickAt = nil
            actions.closeCard()
            // After the close hands activation back, so the menu's tracking
            // does not run through it.
            DispatchQueue.main.async { [weak self] in self?.showMenu() }
        } else {
            lastClickAt = now
            actions.toggleCard()
        }
    }

    /// A status item with a `menu` opens it on every click, so the menu is
    /// attached only for this call. `performClick` returns when the menu closes.
    private func showMenu() {
        guard let item = statusItem, let button = item.button else { return }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // What you came here to do.
        menu.addItem(item(L("menuBar.open"), #selector(openNotch)))
        menu.addItem(item(L("menuBar.history"), #selector(openHistory)))

        menu.addItem(.separator())

        // A running Force Touch pause. This is the only place it can be ended
        // early — the popup that owns the chip is exactly what is not opening —
        // so the row says when it comes back and offers to do it now.
        if actions.isForceTouchDisabled() {
            let status = NSMenuItem(
                title: L("disable.menuBar.status", Self.timeString(actions.forceTouchResumesAt())),
                action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(item(L("disable.menuBar.resume"), #selector(resumeForceTouch)))
        }

        // The one setting worth reaching without opening Settings — Notch's
        // equivalent of a recorder's input-device picker.
        let modelItem = NSMenuItem(title: L("menuBar.model"), action: nil, keyEquivalent: "")
        modelItem.submenu = buildModelMenu()
        menu.addItem(modelItem)

        let settings = item(L("menuBar.settings"), #selector(openSettings))
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = [.command]
        menu.addItem(settings)

        menu.addItem(.separator())

        // Housekeeping: which build this is, what changed, is there a newer one.
        let version = NSMenuItem(
            title: L("menuBar.version", UpdaterService.currentVersion),
            action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(item(L("menuBar.whatsNew"), #selector(openWhatsNew)))
        // A pending update takes over the check row — the menu is where a user
        // who never opens Settings would find out at all.
        if case .available(let latest) = UpdaterService.shared.phase {
            menu.addItem(item(L("menuBar.update", latest), #selector(checkForUpdates)))
        } else {
            menu.addItem(item(L("menuBar.checkUpdates"), #selector(checkForUpdates)))
        }

        menu.addItem(.separator())

        let quit = item(L("menuBar.quit"), #selector(quit))
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)
    }

    /// When the pause lapses, in the user's own short time format ("3:45 PM").
    private static func timeString(_ date: Date?) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date ?? Date())
    }

    /// The recently-used models, same list the in-panel ⌘⇧I picker shows, with
    /// the serving one checked — so switching model is one click from the menu
    /// bar without any of the picker's chrome. Picking commits through
    /// `ModelCatalogStore.select`, the same path the picker uses.
    private func buildModelMenu() -> NSMenu {
        let menu = NSMenu()
        let current = APIKeyStore.selectedProvider
        let currentModel = APIKeyStore.effectiveModel(for: current) ?? current.defaultModel

        // MRU first (newest first), with the serving model pinned in front so it's
        // always present even on a fresh install that has never picked anything.
        var rows: [AskModelMRU.Entry] = []
        if ModelCatalogStore.ready(current), !currentModel.isEmpty {
            rows.append(AskModelMRU.Entry(provider: current, model: currentModel))
        }
        for entry in AskModelMRU.entries where ModelCatalogStore.ready(entry.provider) {
            if !rows.contains(entry) { rows.append(entry) }
        }

        if rows.isEmpty {
            let empty = NSMenuItem(title: L("menuBar.noModel"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, row) in rows.prefix(AskModelMRU.capacity).enumerated() {
                let name = ModelRatings.prettyName(for: row.model, provider: row.provider)
                let title = "\(name)  ·  \(row.provider.displayName)"
                let entry = NSMenuItem(title: title, action: #selector(selectModel(_:)),
                                       keyEquivalent: "")
                entry.target = self
                entry.tag = index
                entry.representedObject = row
                entry.state = (row.provider == current && row.model == currentModel) ? .on : .off
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item(L("menuBar.modelSettings"), #selector(openModelSettings)))
        return menu
    }

    /// Menu items are built with `target = self` explicitly: a status-item menu
    /// has no responder chain to walk, so an untargeted action would simply be
    /// disabled.
    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func openNotch() { actions.openNotch() }
    @objc private func openHistory() { actions.openHistory() }
    @objc private func openSettings() { actions.openSettings() }
    @objc private func openModelSettings() { actions.openModelSettings() }
    @objc private func openWhatsNew() { actions.openWhatsNew() }
    @objc private func checkForUpdates() { actions.checkForUpdates() }
    @objc private func resumeForceTouch() { actions.resumeForceTouch() }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? AskModelMRU.Entry else { return }
        ModelCatalogStore.select(provider: row.provider, model: row.model)
    }
}

/// Whether the app puts an icon in the menu bar — persisted in `UserDefaults`,
/// toggled in Settings → General, consumed by `AppDelegate` via
/// `MenuBarController`. Shown by default: with no Dock icon and no app menu, it
/// is the only handle on the app that doesn't depend on remembering a shortcut
/// or on the notch being reachable. Users who want the bar clean can hide it —
/// the notch and the summon shortcut still work.
enum MenuBarIconVisibility: String, CaseIterable, Identifiable {
    case shown
    case hidden

    var id: String { rawValue }

    /// Reuses the Dock row's Shown/Hidden strings — same two words, same meaning.
    var label: String {
        switch self {
        case .shown:  return L("dock.shown")
        case .hidden: return L("dock.hidden")
        }
    }

    private static let key = "menuBarIconVisibility"
    static var current: MenuBarIconVisibility {
        get {
            UserDefaults.standard.string(forKey: key)
                .flatMap(MenuBarIconVisibility.init) ?? .shown
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}

/// What the menu bar icon draws: the app icon's mark, or the face's two eyes.
enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case mark
    case face

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mark: return L("menuBarIcon.style.mark")
        case .face: return L("menuBarIcon.style.face")
        }
    }

    private static let key = "menuBarIconStyle"
    static var current: MenuBarIconStyle {
        get {
            UserDefaults.standard.string(forKey: key)
                .flatMap(MenuBarIconStyle.init) ?? .mark
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}
