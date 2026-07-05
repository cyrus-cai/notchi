import SwiftUI

/// Entry point. The app runs as a UI-element (no Dock icon, no menu bar app
/// window) — it's a single floating panel that grows out of the Mac's notch.
/// The real work happens in `AppDelegate`, which owns the borderless panel.
@main
struct NotchGlassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No standard windows — everything lives in the notch panel created by
        // the AppDelegate. Settings now render *inside* that panel (see
        // `InlineSettingsView`), so there's no native preferences window anymore.
        // SwiftUI's `App` still requires at least one scene, so we keep a
        // `Settings` scene — but macOS wires the app menu's "Settings…" item
        // straight to it, so a menu click WILL open this window (⌘, never gets
        // here; the AppDelegate's key monitor swallows it first). Instead of a
        // blank window, the scene redirects: it closes its own window on sight
        // and routes to the in-panel settings via the same notification ⌘, uses.
        Settings { SettingsRedirectView() }
    }
}

/// Rendered inside the native Settings window when something opens it (in
/// practice: the app menu's "Settings…" item). Immediately hides + closes that
/// window and posts `.openSettingsRequested`, so every entry point lands in the
/// in-panel settings (`InlineSettingsView`) through one path.
private struct SettingsRedirectView: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .background(SettingsWindowInterceptor())
    }
}

private struct SettingsWindowInterceptor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { InterceptorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class InterceptorView: NSView {
        private var keyObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
                self.keyObserver = nil
            }
            guard let window else { return }
            redirect(window)
            // SwiftUI may keep the closed window around and re-show the same
            // instance on the next menu click (no new viewDidMoveToWindow), so
            // also redirect every time this window becomes key.
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                guard let self, let window = self.window else { return }
                self.redirect(window)
            }
        }

        private func redirect(_ window: NSWindow) {
            // Hide synchronously so the blank window never gets a visible
            // frame; defer the close so we're not tearing the window down
            // while AppKit is still mid-way through presenting it.
            window.alphaValue = 0
            NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
            DispatchQueue.main.async { [weak window] in
                window?.close()
            }
        }

        deinit {
            if let keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
            }
        }
    }
}
