import AppKit

/// The menu bar item — the app's only always-visible affordance besides the
/// notch itself. Notch is an `.accessory` app with no Dock icon by default, so
/// until now the *only* way in was hovering the notch or firing the summon
/// shortcut; a user who forgot the shortcut and was on a full-screen Space had
/// no handle at all. This is that handle: click the icon, get a menu.
///
/// Shape follows the convention every mature menu-bar utility settles on (and
/// the Typeless menu Cyrus pointed at): the two or three things you actually
/// come here to *do* on top, the one setting you flip most often as a submenu,
/// then the housekeeping block (version / what's new / update) and Quit. Nothing
/// here is a feature of its own — every item routes into a path the panel
/// already owns, so the menu can never drift from the app.
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
        var openNotch: () -> Void
        var newChat: () -> Void
        var openHistory: () -> Void
        var openSettings: () -> Void
        var openModelSettings: () -> Void
        var openWhatsNew: () -> Void
        var checkForUpdates: () -> Void
    }

    private var statusItem: NSStatusItem?
    private let actions: Actions

    init(actions: Actions) {
        self.actions = actions
        super.init()
    }

    // MARK: - Presence

    /// Create or tear down the status item to match the persisted setting.
    /// Idempotent — safe to call at launch and on every toggle.
    func apply() {
        if MenuBarIconVisibility.current == .shown {
            install()
        } else {
            remove()
        }
    }

    private func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.statusIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "Notch"
            button.setAccessibilityLabel("Notch")
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
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
    /// bar's full content height. At Dock size those hard 90° corners read as
    /// precision; at 13pt, against a row of light SF Symbols, they read as a
    /// black wedge — the mark ends up louder than everything beside it. Rounding
    /// costs nothing at this size (the silhouette is unchanged) and buys back the
    /// softness the plate used to provide.
    private static func statusIcon() -> NSImage {
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

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // What you came here to do.
        menu.addItem(item(L("menuBar.open"), #selector(openNotch)))
        menu.addItem(item(L("menuBar.newChat"), #selector(newChat)))
        menu.addItem(item(L("menuBar.history"), #selector(openHistory)))

        menu.addItem(.separator())

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
                let title = "\(ModelRatings.prettyName(for: row.model))  ·  \(row.provider.displayName)"
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
    @objc private func newChat() { actions.newChat() }
    @objc private func openHistory() { actions.openHistory() }
    @objc private func openSettings() { actions.openSettings() }
    @objc private func openModelSettings() { actions.openModelSettings() }
    @objc private func openWhatsNew() { actions.openWhatsNew() }
    @objc private func checkForUpdates() { actions.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? AskModelMRU.Entry else { return }
        ModelCatalogStore.select(provider: row.provider, model: row.model)
    }
}

/// Whether the app puts an icon in the menu bar — persisted in `UserDefaults`,
/// toggled in Settings → Appearance, consumed by `AppDelegate` via
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
