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
    /// Posted after a prompt shortcut is added, removed, or re-recorded, so the
    /// live set of global Carbon hot keys follows the Shortcuts pane immediately.
    static let promptShortcutsChanged = Notification.Name("promptShortcutsChanged")
    /// Posted after an in-app action chord is rebound or reset from chat, so an
    /// open Shortcuts pane redraws instead of showing the pre-change binding.
    static let appShortcutsChanged = Notification.Name("appShortcutsChanged")
    /// Posted when the Shortcuts pane starts or stops listening for a chord, so
    /// every global hot key stands down and the recorder can actually observe the
    /// keys Notch itself owns (see `ShortcutRecording`).
    static let shortcutRecordingChanged = Notification.Name("shortcutRecordingChanged")
    /// Posted by the Recent list's "See all" action, so `AppDelegate` can open the
    /// standalone History window showing the complete, uncapped archive.
    static let openHistoryArchiveRequested = Notification.Name("openHistoryArchiveRequested")
    /// Posted when a CLI service's launch resolution lands (the `claude` / `codex` /
    /// `grok` / `cmd` binary probe finished), so the views that asked `isAvailable`
    /// while the answer was still unknown redraw with the real one. See
    /// `resolvedBinaryIfReady()` — availability reads never block a render, so this
    /// is what closes the loop.
    static let cliAvailabilityResolved = Notification.Name("cliAvailabilityResolved")
}
