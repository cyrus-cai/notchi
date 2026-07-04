import AppKit
import Carbon.HIToolbox
import Combine
import NaturalLanguage
import ServiceManagement
import SwiftUI

/// Owns the notch panels for the lifetime of the app — one per screen the
/// `DisplayPlacement` setting covers, each pinned to its screen's top-center.
/// All panels share one `NotchModel` (one conversation, one Recent list); the
/// model's `activeDisplay` says which screen's island is unfurled, the rest
/// keep their resting notch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The live panels, keyed by `CGDirectDisplayID` so screen plug/unplug and
    /// layout changes diff cleanly against `NSScreen.screens`.
    private var panels: [CGDirectDisplayID: NotchPanel] = [:]
    private let model = NotchModel(ai: AppDelegate.makeService())
    private var openObserver: AnyCancellable?

    /// Pick the live backend for the selected provider when an API key is
    /// available (env var or the stored entry from Settings), otherwise fall
    /// back to the offline stub so the UI still works out of the box.
    private static func makeService() -> AIService {
        let provider = APIKeyStore.selectedProvider
        guard let key = APIKeyStore.current(for: provider) else {
            return StubAIService()
        }
        let model = APIKeyStore.effectiveModel(for: provider)
        // Anthropic speaks its own protocol; everyone else is OpenAI-compatible.
        if provider.isOpenAICompatible {
            return OpenAICompatAIService(provider: provider, apiKey: key, model: model)
        } else {
            return AnthropicAIService(provider: provider, apiKey: key, model: model)
        }
    }

    /// True when a real key is available for the selected provider — i.e. the
    /// backend `makeService` builds is live rather than the offline stub. Drives
    /// the result view's "set up your model" prompt when false.
    private static func isConfigured() -> Bool {
        APIKeyStore.current(for: APIKeyStore.selectedProvider) != nil
    }

    /// Point the model at the right backend AND tell it whether that backend is
    /// live, so both move together. Called at launch and whenever Settings saves a
    /// key / switches providers.
    private func syncService() {
        model.setService(AppDelegate.makeService())
        model.isConfigured = AppDelegate.isConfigured()
    }
    /// Local key monitor backing ⌘, → Settings. App-scoped (not a global Carbon
    /// hot key), so ⌘, only opens Settings while Notch is frontmost and stays out
    /// of every other app's way. Held so it lives for the app's lifetime.
    private var settingsHotKeyMonitor: Any?
    /// The user-configurable global shortcut that toggles the panel open/closed.
    /// The default is a double-tap of ⌥ (held by `summonDoubleTap`); a recorded
    /// chord uses `summonHotKey` instead. Exactly one is live at a time. Both are
    /// held strongly so they stay registered and rebuilt whenever the Settings →
    /// General recorder changes the config; both `nil` while disabled.
    private var summonHotKey: HotKey?
    private var summonDoubleTap: DoubleTapModifierMonitor?

    /// The app that was frontmost right before the panel opened. The open path
    /// activates Notch (see the `$open` observer) so accessibility-based input
    /// tools can reach the prompt field; this is who gets activation back when
    /// the panel closes, so the user lands exactly where they were.
    private var appToRestoreOnClose: NSRunningApplication?

    /// The panel is wider/taller than the resting notch so the glass has room to
    /// unfurl downward. The SwiftUI view draws the notch at the top-center of
    /// this canvas; the empty area around it is fully transparent and
    /// click-through (see `ContentView`'s hit testing).
    private let canvasWidth: CGFloat = 760
    private let canvasHeight: CGFloat = 640

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app by default: no Dock icon, no app menu — it's a pure overlay.
        // The user can opt into a Dock icon (Settings → General), which flips this
        // to `.regular`; `applyDockIconVisibility` reads the persisted choice.
        applyDockIconVisibility()

        // Seed the configured flag to match the service the model launched with.
        model.isConfigured = AppDelegate.isConfigured()

        // Start sampling mouse movement so a hover-open can read the cursor's
        // approach vector — the entry physics in `NotchIsland` feed on it.
        MouseVelocityTracker.shared.start()

        // Warm the ask/note intent engine off the main thread: fetch/load the
        // embedding model and restore (or fit, first run ~seconds) the per-language
        // classification heads, so the first keystroke classifies in ~10ms instead
        // of paying that cost mid-typing. Background priority — typing that lands
        // before this finishes just reads as unsure → ask default.
        Task.detached(priority: .background) {
            await IntentEngine.shared.prepare()
        }

        // Quiet daily update check, deferred past launch so it never competes
        // with first paint. Result only ever surfaces as the gear dot.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            UpdaterService.shared.checkIfDue()
            // Touch the What's New service so it resolves the "unseen version"
            // cue (and records the first-launch baseline) off the launch path.
            // Notes are bundled into the app — there's nothing to fetch.
            _ = WhatsNewService.shared
            // Refresh the curated model manifest (shortlists + default models,
            // hot-updated from the website) on the same quiet cadence.
            await RemoteModelManifest.refreshIfDue()
        }

        rebuildPanels()

        // When the panel opens (on hover), make the active screen's panel the
        // key window so keystrokes land in the prompt field immediately — no
        // extra click needed — and ALSO activate the app itself. Key status
        // alone routes physical keystrokes and Apple's own dictation (both ride
        // the in-process text-input context), but third-party voice/dictation
        // tools (Typeless & co.) locate the field to fill via the Accessibility
        // API's *focused application*, which follows app activation — while we
        // stay inactive they see no focused field, or type into the app behind
        // us. Activation is what makes the prompt reachable to them; the app
        // that was frontmost is recorded and re-activated on close so focus
        // returns where the user was. (With the default `.accessory` policy the
        // menu bar stays with the front app even while we're active.) Keyed on
        // (open, activeDisplay) together so a display *switch* while open hands
        // the keyboard over with the island.
        openObserver = model.$open
            .combineLatest(model.$activeDisplay)
            .removeDuplicates(by: ==)
            .sink { [weak self] isOpen, active in
                guard let self else { return }
                if isOpen {
                    // First open ever retires the gesture glow (its job — getting the
                    // user to the panel — is done). A no-op after the first time.
                    OnboardingService.shared.markPanelOpened()
                    // …and on a fresh install, the panel opens straight into the
                    // guided first run. Deferred a runloop turn so it rides the same
                    // open spring rather than racing the expand's first frame. Guarded
                    // so it never overrides a panel the user opened INTO settings /
                    // What's New (e.g. ⌘,) — only a plain idle open leads with the guide.
                    if OnboardingService.shared.showGuide {
                        DispatchQueue.main.async {
                            guard self.model.open,
                                  !self.model.showSettings,
                                  !self.model.showWhatsNew,
                                  OnboardingService.shared.showGuide else { return }
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                self.model.openOnboarding(on: active)
                            }
                        }
                    }
                    // This fires synchronously inside the hover handler ($open
                    // publishes on willSet) — BEFORE SwiftUI commits the open
                    // animation's first frame. The key-window dance does
                    // window-server round trips, so running it inline taxes
                    // that exact frame. Defer one runloop turn: the spring's
                    // first frame renders first, the keyboard handoff lands
                    // right after (still well ahead of NotchBody raising
                    // focus at +0.08s).
                    DispatchQueue.main.async {
                        guard self.model.open else { return }
                        // Debug paths set `open` without claiming a display; fall
                        // back to the preferred screen's panel so they still key.
                        let target = active.flatMap { self.panels[$0] }
                            ?? self.preferredScreen()?.displayID.flatMap { self.panels[$0] }
                            ?? self.panels.values.first
                        for p in self.panels.values where p !== target && p.isKeyWindow {
                            p.resignKey()
                        }
                        target?.makeKeyAndOrderFront(nil)
                        // Record who was frontmost, then bring Notch forward so
                        // AX-based input tools can see the focused prompt field.
                        // A display switch while already open re-runs this block
                        // with Notch itself frontmost — the guard keeps the
                        // original app on record instead of overwriting it.
                        if let front = NSWorkspace.shared.frontmostApplication,
                           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                            self.appToRestoreOnClose = front
                        }
                        NSApp.activate(ignoringOtherApps: true)
                        // Long-running agent: piggyback the daily update check on
                        // panel opens so it still happens without relaunches.
                        UpdaterService.shared.checkIfDue()
                    }
                } else {
                    for p in self.panels.values {
                        if p.isKeyWindow { p.resignKey() }
                        // Closing mid-composition can skip the field's end-editing
                        // notification, which would strand the panel at its lowered
                        // (editing) level. Force every panel back to resting on close.
                        p.restRestingLevel()
                    }
                    // Hand activation back to the app the user came from (recorded
                    // at open). Skipped when we're no longer active — the user
                    // already switched into another app themselves, and re-activating
                    // the recorded one would fight that choice.
                    if NSApp.isActive,
                       let prev = self.appToRestoreOnClose, !prev.isTerminated {
                        NSApp.yieldActivation(to: prev)
                        prev.activate()
                    }
                    self.appToRestoreOnClose = nil
                }
            }

        // Debug aid: NOTCH_OPEN=1 opens the panel at launch (and optionally seeds
        // a result via NOTCH_DEMO=1) so the expanded glass can be inspected
        // without a live hover. No effect in normal use.
        let env = ProcessInfo.processInfo.environment
        if env["NOTCH_OPEN"] == "1" {
            model.openPanel(on: preferredScreen()?.displayID)
            if env["NOTCH_DEMO"] == "1" {
                // NOTCH_DEMO_TEXT lets us seed arbitrary markdown for inspecting
                // the answer renderer; falls back to the original one-liner.
                model.seedDemo(
                    question: env["NOTCH_DEMO_Q"] ?? "Explain liquid glass in one line",
                    answer: env["NOTCH_DEMO_TEXT"]
                        ?? "A material language built on translucency, refraction and flow — light passes **through** it, not just over it."
                )
            }
            // NOTCH_DEMO_THREAD=1 seeds a long multi-turn conversation so the
            // scrolling/edge-fade of the result view can be inspected at launch
            // without any clicking. Debug aid only.
            if env["NOTCH_DEMO_THREAD"] == "1" {
                model.seedDemoThread()
            }
            // NOTCH_DEMO_HISTORY=1 expands the recent list at launch so the idle
            // panel (RECENT header + Clear pill) can be inspected without a hover.
            if env["NOTCH_DEMO_HISTORY"] == "1" {
                model.showHistory = true
            }
            // NOTCH_DEMO_CLIP=<text> seeds a pending clipboard at launch (bypassing
            // the freshness gate) so the preset row and its note/reminder capture
            // chip can be inspected without a real copy-then-hover. Debug aid only.
            if let clip = env["NOTCH_DEMO_CLIP"], !clip.isEmpty {
                model.seedDemoClipboard(clip)
            }
        }
        // Debug aid: NOTCH_SETTINGS=1 opens the panel straight into the inline
        // settings view at launch (via the same path as ⌘,) so it can be
        // inspected/screenshotted without a hover. No effect in normal use.
        if env["NOTCH_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
            }
        }
        // Re-diff the panels when the screen layout changes (display added or
        // removed, resolution change, notebook lid open/close, etc.).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // The Settings → Display placement choice creates/destroys panels live.
        NotificationCenter.default.addObserver(
            forName: .displayPlacementChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildPanels()
            }
        }

        // The Settings → General Dock-icon choice flips the activation policy live.
        NotificationCenter.default.addObserver(
            forName: .dockIconVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyDockIconVisibility()
            }
        }

        // When the user saves an API key or switches providers in Settings,
        // rebuild the AI service so the next question goes live immediately — no
        // restart needed.
        NotificationCenter.default.addObserver(
            forName: .aiBackendChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncService()
            }
        }

        // Settings now live *inside* the panel (see `InlineSettingsView`), so the
        // request just opens the panel straight into the settings view. Making the
        // panel open also makes it the key window (via the `$open` observer above),
        // so the API-key field can take keystrokes immediately.
        NotificationCenter.default.addObserver(
            forName: .openSettingsRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    // ⌘, can fire from anywhere — open on the screen the user is
                    // actually on (mouse position), not wherever the notch lives.
                    self.model.openSettings(on: self.displayForSummon())
                }
            }
        }

        // Wire the answer-ready notification service: set its delegate so taps
        // route back here, and observe the tap so we can summon the panel and
        // reopen the conversation. (The banners themselves are posted from
        // `NotchModel.submit` when a round finishes after the user walked away.)
        NotificationService.shared.configure()
        NotificationCenter.default.addObserver(
            forName: NotificationService.answerTapped,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let id = note.userInfo?[NotificationService.threadIDKey] as? UUID
                else { return }
                // Bring the app forward so the summoned panel is interactive even
                // when Notch wasn't frontmost, then open on the screen under the
                // mouse and route straight to that thread's detail view.
                NSApp.activate(ignoringOtherApps: true)
                let display = self.displayForSummon()
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    if !self.model.open {
                        self.model.mode = .idle
                        self.model.openPanel(on: display)
                    } else if let display {
                        self.model.activeDisplay = display
                    }
                    self.model.openThread(id: id)
                }
            }
        }

        // ⌘, opens Settings — but ONLY when Notch is frontmost, so it never
        // steals the standard "Preferences" shortcut from whatever app the user
        // is actually in. A *local* NSEvent monitor sees only key events
        // delivered to our own windows (unlike Carbon's process-wide
        // RegisterEventHotKey, which fired ⌘, from anywhere and shadowed every
        // other app). It posts the same request the in-panel gear does, so both
        // share one open path.
        settingsHotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_ANSI_Comma),
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
                return nil // swallow it so it doesn't also beep / insert a comma
            }
            return event
        }

        // The configurable global summon shortcut (default: double-tap ⌥). A
        // double-tap is detected by watching `flagsChanged`; a recorded chord uses
        // the same Carbon mechanism as ⌘, (fires from anywhere, no accessibility
        // permission). User-editable in Settings → General, so it re-registers on
        // change.
        registerSummonHotKey()
        NotificationCenter.default.addObserver(
            forName: .summonHotKeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.registerSummonHotKey()
            }
        }
    }

    /// (Re)register the global summon shortcut from the persisted config. Dropping
    /// the old `HotKey`/monitor unregisters it (deinit), so this is also how
    /// "disabled" takes effect: when the config is off we just clear both refs.
    private func registerSummonHotKey() {
        summonHotKey = nil
        summonDoubleTap = nil
        let config = SummonHotKey.current
        guard config.enabled else { return }

        let fire: () -> Void = { [weak self] in
            guard let self else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                self.model.toggleSummon(on: self.displayForSummon())
            }
        }

        if config.isDoubleTap {
            summonDoubleTap = DoubleTapModifierMonitor(carbonModifier: config.doubleTapModifier,
                                                       action: fire)
        } else {
            summonHotKey = HotKey(keyCode: config.keyCode, modifiers: config.modifiers, action: fire)
        }
    }

    @objc private func screensChanged() {
        rebuildPanels()
    }

    /// Apply the persisted Dock-icon choice by setting the app's activation
    /// policy. Called at launch and whenever the Settings → General toggle flips.
    ///
    /// Switching to `.regular` mid-session doesn't reliably surface the Dock icon
    /// on its own — AppKit only commits the policy change once the app activates —
    /// so we follow a show with an explicit activation. The panels are
    /// non-activating overlays, so this never steals focus from them at rest; it
    /// just lets the Dock icon appear right after the user asks for it instead of
    /// on the next app switch. `.accessory` needs no such nudge.
    private func applyDockIconVisibility() {
        let visibility = DockIconVisibility.current
        NSApp.setActivationPolicy(visibility.activationPolicy)
        if visibility == .shown {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Panel management

    /// The screens that should carry a notch island under the current setting.
    private func targetScreens() -> [NSScreen] {
        switch DisplayPlacement.current {
        case .all:     return NSScreen.screens
        case .builtIn: return preferredScreen().map { [$0] } ?? []
        }
    }

    /// Create/destroy/re-pin panels so exactly the screens in `targetScreens()`
    /// have one. Called at launch, on screen layout changes, and when the
    /// Display setting flips. Surviving panels are only repositioned — never
    /// torn down — so flipping the setting from inside the open settings panel
    /// doesn't slam that panel shut.
    private func rebuildPanels() {
        var live: Set<CGDirectDisplayID> = []
        for screen in targetScreens() {
            guard let id = screen.displayID else { continue }
            live.insert(id)
            if let existing = panels[id] {
                position(existing, on: screen, id: id)
            } else {
                panels[id] = makePanel(on: screen, id: id)
            }
        }
        for (id, panel) in panels where !live.contains(id) {
            panel.close()
            panels.removeValue(forKey: id)
        }
        // If the open island's screen just vanished (display unplugged, placement
        // narrowed mid-use), migrate it to a surviving screen instead of dropping
        // the user's conversation / half-edited settings on the floor.
        if let active = model.activeDisplay, panels[active] == nil {
            model.activeDisplay = preferredScreen()?.displayID
        }
    }

    /// Build the transparent canvas panel for one screen, injecting per-screen
    /// metrics so the SwiftUI tree knows which display it's on, how tall its
    /// resting notch is, and whether to draw the camera dot.
    private func makePanel(on screen: NSScreen, id: CGDirectDisplayID) -> NotchPanel {
        let rect = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        let panel = NotchPanel(contentRect: rect)

        let hasNotch = screen.safeAreaInsets.top > 0
        let root = ContentView(model: model)
            .frame(width: canvasWidth, height: canvasHeight, alignment: .top)
            // The live string store — observed app-wide so an App Language switch
            // re-renders every panel's SwiftUI tree instantly, no relaunch.
            .environmentObject(Localization.shared)
            .environment(\.notchMetrics, NotchMetrics(
                canvasWidth: canvasWidth,
                displayID: id,
                // The REAL hardware notch height, not the 32pt design constant:
                // the physical notch is ~37-38pt on notched MacBooks, and the
                // busy extension sits beside it over visible screen — a drawn
                // zone even a few px shorter reads as the extension "hanging"
                // above the notch's bottom edge. (Black-on-black hid the
                // mismatch for years; the extension exposed it.) The +1 is a
                // one-sided error margin: measurement/AA residue as DRAWN-TOO-
                // SHORT shows a step at the junction, while drawn-too-tall just
                // moves the whole continuous bottom edge down a hair — so bleed
                // 1pt past the inset and let any residue land on the invisible
                // side. (Screenshots can't verify this seam — the framebuffer
                // has no notch — so the margin, not calibration, is the fix.)
                restHeight: hasNotch ? screen.safeAreaInsets.top + 1
                                     : Self.menuBarHeight(of: screen),
                hasHardwareNotch: hasNotch
            ))

        let hosting = NSHostingView(rootView: root)
        hosting.frame = rect
        // Let clicks pass through the transparent canvas to apps underneath;
        // only the glass form itself is interactive.
        panel.contentView = hosting

        position(panel, on: screen, id: id)
        panel.orderFrontRegardless()
        return panel
    }

    /// Center the canvas horizontally and flush its top edge to the very top of
    /// the screen, so the SwiftUI notch sits exactly where the hardware notch
    /// (or the menu bar, on external screens) is.
    private func position(_ panel: NSPanel, on screen: NSScreen, id: CGDirectDisplayID) {
        let full = screen.frame
        let x = full.midX - canvasWidth / 2
        // AppKit's origin is bottom-left; place the canvas so its top aligns
        // with the screen's top edge.
        let y = full.maxY - canvasHeight
        let frame = NSRect(x: x, y: y, width: canvasWidth, height: canvasHeight)
        panel.setFrame(frame, display: true)
        // Tell the model where this canvas sits on screen and how tall its
        // resting notch is — the ground-truth pointer test that filters
        // synthetic hover enter/exit events needs both (see
        // `NotchModel.pointerInsideIsland`). Same formula as the metrics
        // injection in `makePanel`.
        let hasNotch = screen.safeAreaInsets.top > 0
        model.registerPanelFrame(
            frame,
            restHeight: hasNotch ? screen.safeAreaInsets.top + 1 : Self.menuBarHeight(of: screen),
            for: id)
    }

    /// The resting-zone height for a notch-less screen: match the menu bar so
    /// the virtual notch nests inside it. `visibleFrame` already subtracts the
    /// menu bar from the top (the Dock only ever affects the bottom/sides);
    /// clamped so an auto-hidden menu bar can't yield a zero-height notch.
    private static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        let h = screen.frame.maxY - screen.visibleFrame.maxY
        return h > 4 ? min(h, 40) : 24
    }

    /// Prefer the screen that actually has a notch (its `safeAreaInsets.top`
    /// exceeds the menu-bar height). Fall back to the main screen.
    private func preferredScreen() -> NSScreen? {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Where a summoned-from-anywhere open (⌘,) should land: the screen the
    /// mouse is on when it has a panel, else the preferred screen.
    private func displayForSummon() -> CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        if let id = NSScreen.screens
            .first(where: { NSMouseInRect(mouse, $0.frame, false) })?.displayID,
           panels[id] != nil {
            return id
        }
        return preferredScreen()?.displayID
    }
}

/// Which screens carry a notch island — persisted in `UserDefaults`, edited in
/// Settings → Display, consumed by `AppDelegate.rebuildPanels()`.
enum DisplayPlacement: String, CaseIterable, Identifiable {
    /// Every connected screen gets an island: the real notch on the built-in
    /// display, a menu-bar-height virtual notch on externals. The default —
    /// the point of the app is being one hover away wherever you're working.
    case all
    /// The classic single-panel behavior: only the notched (or main) screen.
    case builtIn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:     return L("placement.all")
        case .builtIn: return L("placement.builtIn")
        }
    }

    private static let key = "displayPlacement"
    static var current: DisplayPlacement {
        get {
            UserDefaults.standard.string(forKey: key)
                .flatMap(DisplayPlacement.init) ?? .all
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}

/// Whether the app shows an icon in the Dock — persisted in `UserDefaults`,
/// edited in Settings → General, consumed by `AppDelegate` to pick the
/// activation policy. Hidden by default: this is a notch overlay, so it ships
/// as a pure menu-bar-less accessory (`.accessory`); flipping it to shown makes
/// it a `.regular` app with a Dock icon for users who want one place to relaunch
/// or quit it from.
enum DockIconVisibility: String, CaseIterable, Identifiable {
    case hidden
    case shown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hidden: return L("dock.hidden")
        case .shown:  return L("dock.shown")
        }
    }

    /// The `NSApplication.ActivationPolicy` this choice maps to. `.accessory`
    /// keeps the app off the Dock and out of the ⌘-Tab switcher (the overlay's
    /// natural home); `.regular` gives it a Dock icon and app menu.
    var activationPolicy: NSApplication.ActivationPolicy {
        switch self {
        case .hidden: return .accessory
        case .shown:  return .regular
        }
    }

    private static let key = "dockIconVisibility"
    static var current: DockIconVisibility {
        get {
            UserDefaults.standard.string(forKey: key)
                .flatMap(DockIconVisibility.init) ?? .hidden
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}

/// Whether the app launches itself when the user logs in — backed by the system
/// login-item registry via `SMAppService.mainApp`, not `UserDefaults`. The OS is
/// the source of truth (the user can also remove the item in System Settings →
/// General → Login Items), so `isEnabled` reads the live status rather than a
/// cached flag. Off by default: nothing registers until the user asks for it in
/// Settings → General.
enum LaunchAtLogin {
    /// The live registration status of the main app as a login item.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register or unregister the app as a login item. Throwing surfaces to the
    /// caller so the toggle can revert its optimistic state if the OS refuses
    /// (e.g. the item is disabled at the system level and needs the user to
    /// re-enable it in System Settings).
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            // `register` throws if already registered as *disabled*; a plain
            // `.enabled` re-register is a no-op, so only act when the state differs.
            if service.status != .enabled { try service.register() }
        } else {
            if service.status == .enabled { try service.unregister() }
        }
    }
}

/// A language the user can pick for translation. Used for both pref1 and pref2
/// of the dual-preference translation model. Persisted per-preference in
/// UserDefaults under "translationPref1" / "translationPref2".
///
/// Migration note: previous single-target key ("translationTarget") and the old
/// A/B pair keys ("translationLangA", "translationLangB") are ignored — unrecognised
/// keys fall back to their respective defaults (pref1 → .chineseSimplified,
/// pref2 → .english).
enum TranslationLanguage: String, CaseIterable, Identifiable {
    case english
    case chineseSimplified
    case chineseTraditional
    case japanese
    case korean
    case french
    case german
    case spanish
    case portuguese
    case italian
    case russian
    case arabic
    case hindi

    var id: String { rawValue }

    /// The picker label, shown in the user's interface language-agnostic form
    /// (each language named in itself, the convention OS language pickers use).
    var label: String {
        switch self {
        case .english:            return "English"
        case .chineseSimplified:  return "简体中文"
        case .chineseTraditional: return "繁體中文"
        case .japanese:           return "日本語"
        case .korean:             return "한국어"
        case .french:             return "Français"
        case .german:             return "Deutsch"
        case .spanish:            return "Español"
        case .portuguese:         return "Português"
        case .italian:            return "Italiano"
        case .russian:            return "Русский"
        case .arabic:             return "العربية"
        case .hindi:              return "हिन्दी"
        }
    }

    /// A compact label for the translate chip — short enough to pair as "中→En".
    var chipLabel: String {
        switch self {
        case .english:            return "En"
        case .chineseSimplified:  return "中"
        case .chineseTraditional: return "繁"
        case .japanese:           return "日"
        case .korean:             return "韓"
        case .french:             return "Fr"
        case .german:             return "De"
        case .spanish:            return "Es"
        case .portuguese:         return "Pt"
        case .italian:            return "It"
        case .russian:            return "Ru"
        case .arabic:             return "ع"
        case .hindi:              return "हि"
        }
    }

    /// The language named in English, for the Latin-script prompt phrase.
    var englishName: String {
        switch self {
        case .english:            return "English"
        case .chineseSimplified:  return "Simplified Chinese"
        case .chineseTraditional: return "Traditional Chinese"
        case .japanese:           return "Japanese"
        case .korean:             return "Korean"
        case .french:             return "French"
        case .german:             return "German"
        case .spanish:            return "Spanish"
        case .portuguese:         return "Portuguese"
        case .italian:            return "Italian"
        case .russian:            return "Russian"
        case .arabic:             return "Arabic"
        case .hindi:              return "Hindi"
        }
    }

    /// The language named in Chinese, for the CJK prompt phrase.
    var cjkName: String {
        switch self {
        case .english:            return "英语"
        case .chineseSimplified:  return "简体中文"
        case .chineseTraditional: return "繁体中文"
        case .japanese:           return "日语"
        case .korean:             return "韩语"
        case .french:             return "法语"
        case .german:             return "德语"
        case .spanish:            return "西班牙语"
        case .portuguese:         return "葡萄牙语"
        case .italian:            return "意大利语"
        case .russian:            return "俄语"
        case .arabic:             return "阿拉伯语"
        case .hindi:              return "印地语"
        }
    }

    // MARK: - Detection

    /// The dominant language of `text`, mapped to one of our 13 cases — or nil if
    /// detection is inconclusive or lands on a language we don't offer. Runs
    /// locally via `NLLanguageRecognizer` (no network, no third-party library).
    /// Chinese disambiguation: `NaturalLanguage` reports both scripts as
    /// `.simplifiedChinese` / `.traditionalChinese` only when confident; we fall
    /// back to a Han-presence check that maps any Chinese to Simplified, which is
    /// enough for the direction display (the AI still does the real translation).
    static func detect(in text: String) -> TranslationLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let lang = recognizer.dominantLanguage else { return nil }
        switch lang {
        case .english:            return .english
        case .simplifiedChinese:  return .chineseSimplified
        case .traditionalChinese: return .chineseTraditional
        case .japanese:           return .japanese
        case .korean:             return .korean
        case .french:             return .french
        case .german:             return .german
        case .spanish:            return .spanish
        case .portuguese:         return .portuguese
        case .italian:            return .italian
        case .russian:            return .russian
        case .arabic:             return .arabic
        case .hindi:              return .hindi
        default:                  return nil
        }
    }

    /// The translate direction the chip should advertise for a given pending
    /// clip, resolved exactly the way the AI prompt routes it:
    ///   • source is pref1            → target pref2
    ///   • source is pref2, or other  → target pref1
    /// Returns the *source* only when it's one of the two prefs (so the chip can
    /// show "src→dst"); when the source is some third language (or undetected),
    /// `source` is nil and only the guaranteed target is known ("→dst").
    static func resolveDirection(
        clip: String?, pref1: TranslationLanguage, pref2: TranslationLanguage
    ) -> (source: TranslationLanguage?, target: TranslationLanguage) {
        let detected = clip.flatMap(detect(in:))
        if detected == pref1 { return (pref1, pref2) }
        if detected == pref2 { return (pref2, pref1) }
        return (nil, pref1)
    }

    // MARK: - Persistence

    private static let pref1Key = "translationPref1"
    private static let pref2Key = "translationPref2"

    /// Load the persisted pref1 language. Falls back to `.chineseSimplified`.
    static func loadPref1() -> TranslationLanguage {
        UserDefaults.standard.string(forKey: pref1Key)
            .flatMap(TranslationLanguage.init) ?? .chineseSimplified
    }

    static func savePref1(_ value: TranslationLanguage) {
        UserDefaults.standard.set(value.rawValue, forKey: pref1Key)
    }

    /// Load the persisted pref2 language. Falls back to `.english`.
    static func loadPref2() -> TranslationLanguage {
        UserDefaults.standard.string(forKey: pref2Key)
            .flatMap(TranslationLanguage.init) ?? .english
    }

    static func savePref2(_ value: TranslationLanguage) {
        UserDefaults.standard.set(value.rawValue, forKey: pref2Key)
    }
}

extension NSScreen {
    /// The CoreGraphics display ID — the stable key panels are tracked by
    /// across layout changes.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }
}
