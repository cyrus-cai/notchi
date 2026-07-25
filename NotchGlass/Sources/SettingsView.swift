import SwiftUI

/// Notification names shared between the settings UI and `AppDelegate`.
///
/// Settings used to live in a native `Settings` window; they now render inside
/// the notch panel (see `InlineSettingsView`). These names survived that move:
/// `aiBackendChanged` still rebuilds the AI service after a save, and
/// `openSettingsRequested` still opens settings — only now it opens the panel's
/// inline view rather than a separate window.
extension Notification.Name {
    /// Posted after the user saves an API key or switches providers, so
    /// `AppDelegate` can rebuild the AI service and the next question goes live
    /// without a restart.
    static let aiBackendChanged = Notification.Name("aiBackendChanged")
    /// Posted by ⌘, (and the `NOTCH_SETTINGS` debug flag) so `AppDelegate` can
    /// open the panel straight into the inline settings view.
    static let openSettingsRequested = Notification.Name("openSettingsRequested")
    /// Posted by the app menu's "Check for Updates…" command so `AppDelegate`
    /// can open Settings → About and kick off a user-initiated update check.
    static let checkForUpdatesRequested = Notification.Name("checkForUpdatesRequested")
    /// Posted after the user changes the Display placement (Settings → Display),
    /// so `AppDelegate` can create/destroy per-screen panels immediately.
    static let displayPlacementChanged = Notification.Name("displayPlacementChanged")
    /// Posted after the user toggles the Dock icon (Settings → General), so
    /// `AppDelegate` can switch the app's activation policy live.
    static let dockIconVisibilityChanged = Notification.Name("dockIconVisibilityChanged")
    /// Posted after the user toggles the menu bar icon (Settings → Appearance),
    /// so `AppDelegate` can add or remove the status item right away.
    static let menuBarIconVisibilityChanged = Notification.Name("menuBarIconVisibilityChanged")
    /// Posted after the user toggles "Hide in full screen" (Settings → General),
    /// so `AppDelegate` re-evaluates which panels to hide right away.
    static let hideNotchInFullscreenChanged = Notification.Name("hideNotchInFullscreenChanged")
    /// Posted after the user changes the global summon shortcut (Settings →
    /// General), so `AppDelegate` re-registers the Carbon hot key immediately.
    static let summonHotKeyChanged = Notification.Name("summonHotKeyChanged")
    /// Posted by the Recent list's "See all" action, so `AppDelegate` can open the
    /// standalone History window showing the complete, uncapped archive.
    static let openHistoryArchiveRequested = Notification.Name("openHistoryArchiveRequested")
}
