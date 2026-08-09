import AppKit
import ApplicationServices
import Carbon

/// A thin wrapper over Carbon's `RegisterEventHotKey` — a process-wide hot key
/// that fires even when the app isn't frontmost, with no Accessibility
/// permission required (unlike a CGEvent tap). Used for ⌘, → Settings, since
/// this accessory app has no menu bar to host the standard shortcut.
///
/// The handler is dispatched to the main actor. Hold a strong reference for as
/// long as the shortcut should stay live; deinit unregisters it.
final class HotKey {
    private var ref: EventHotKeyRef?

    // A unique id so the global Carbon dispatcher can route events to us.
    private static var nextID: UInt32 = 1
    private let id: UInt32
    /// id → what to run. Deliberately the *closure*, never the `HotKey` itself:
    /// a strong `[id: HotKey]` entry would keep every instance alive forever
    /// (nothing but `deinit` clears it, and `deinit` can't run while the table
    /// holds a reference), so `UnregisterEventHotKey` would never fire and a
    /// rebound chord would keep triggering its previous action for the whole
    /// session while the new one failed to register (`eventHotKeyExistsErr`).
    private static var actions: [UInt32: () -> Void] = [:]

    /// The process-wide Carbon dispatcher. Installed exactly once and never
    /// removed: Carbon refuses a duplicate (proc, target) install, so a
    /// per-instance handler would leave one arbitrary `HotKey` owning the only
    /// registration — and dropping *that* one would silently stop dispatching
    /// events for every other hot key still registered.
    private static var dispatcher: EventHandlerRef? = {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            if let action = HotKey.actions[hkID.id] {
                DispatchQueue.main.async { action() }
            }
            return noErr
        }, 1, &eventType, nil, &ref)
        return ref
    }()

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.id = HotKey.nextID
        HotKey.nextID += 1
        _ = HotKey.dispatcher

        let signature: OSType = 0x4E4F5443 // 'NOTC'
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode,
                                         modifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        guard status == noErr else { return nil }
        HotKey.actions[id] = action
    }

    /// Probe whether Carbon can claim a global chord (including conflicts with
    /// macOS and other apps). The temporary registration is released as soon as
    /// this function returns.
    static func isAvailable(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let probe = HotKey(keyCode: keyCode, modifiers: modifiers, action: {})
        return probe != nil
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.actions[id] = nil
    }
}

/// Whether the Shortcuts pane is currently listening for a chord.
///
/// Recording reads keys through a *local* `NSEvent` monitor, which is the last
/// link in the chain: a Carbon hot key swallows its chord system-wide before any
/// app ever sees a key event, and an earlier-installed local monitor that
/// consumes an event hides it from every monitor behind it. Without this flag the
/// recorder simply never observes the chords Notch itself owns — pressing one
/// fires the old shortcut instead of being recorded, which reads as "this key
/// can't be set".
///
/// While recording: `AppDelegate` drops every global registration, and the
/// in-app key handlers stand down so the recorder sees the raw key event.
enum ShortcutRecording {
    private(set) static var isActive = false

    static func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        NotificationCenter.default.post(name: .shortcutRecordingChanged, object: nil)
    }
}

/// Fires `action` when the user double-taps a *bare* modifier key (e.g. ⌥⌥),
/// the way Raycast/CleanShot summon on a double-tapped ⌘. Carbon's
/// `RegisterEventHotKey` can't represent a lone modifier, so this watches
/// `flagsChanged` through a global+local `NSEvent` monitor — which, unlike a
/// CGEvent tap, needs no Accessibility permission, only the ability to observe
/// modifier state (granted to ordinary apps).
///
/// A "tap" is the target modifier going down and back up with no *other*
/// modifier held at any point; two taps inside `window` seconds fire the action.
/// Hold a strong reference for as long as it should stay live; deinit removes
/// the monitors.
final class DoubleTapModifierMonitor {
    private let flag: NSEvent.ModifierFlags
    private let action: () -> Void
    private let window: TimeInterval
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Timestamp of the last completed tap (a down→up of the lone modifier),
    /// taken from the event's own `timestamp` so it's immune to dispatch jitter.
    private var lastTapTime: TimeInterval?
    /// Whether the target modifier is currently the only one held — set on the
    /// down edge, so the matching up edge knows the tap was "clean".
    private var pendingTap = false

    /// - Parameters:
    ///   - carbonModifier: the modifier to watch, as a Carbon mask (`optionKey`…).
    ///   - window: max seconds between the two taps (default 0.30 — Raycast-ish).
    init(carbonModifier: UInt32, window: TimeInterval = 0.30, action: @escaping () -> Void) {
        self.flag = DoubleTapModifierMonitor.cocoaFlag(forCarbon: carbonModifier)
        self.action = action
        self.window = window

        // Global monitor: catches taps while another app is frontmost. Local
        // monitor: catches them while our own (settings) window has focus —
        // global monitors don't see events delivered to our process.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
    }

    /// The four modifiers a double-tap cares about. Caps-lock and fn are
    /// deliberately excluded — otherwise an engaged Caps Lock would sit in every
    /// flag set and the "only the target is held" test could never be true.
    private static let watched: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    private func handle(_ event: NSEvent) {
        // An unmappable modifier (empty `flag`) can never be the sole one held, so
        // bail — otherwise `active == flag` would match every plain key-up.
        guard !flag.isEmpty else { return }

        let active = event.modifierFlags.intersection(DoubleTapModifierMonitor.watched)
        let onlyTargetHeld = active == flag

        if onlyTargetHeld {
            // Down edge: the target modifier just became the sole one held.
            pendingTap = true
            return
        }

        // Any other transition. We only care about the *release* that completes a
        // clean tap: the target went down alone (pendingTap) and now nothing is
        // held. If some other modifier joined in, the tap is dirty — reset.
        guard pendingTap else { return }
        pendingTap = false
        guard active.isEmpty else {
            lastTapTime = nil // a different modifier intruded; not a clean tap
            return
        }

        let now = event.timestamp
        if let last = lastTapTime, now - last <= window {
            lastTapTime = nil
            action()
        } else {
            lastTapTime = now
        }
    }

    /// Map a Carbon modifier mask to the Cocoa flag `NSEvent` reports. Only the
    /// four real modifiers can be double-tapped; anything else yields an empty
    /// set (never matches), which is the safe no-op.
    private static func cocoaFlag(forCarbon carbon: UInt32) -> NSEvent.ModifierFlags {
        switch carbon {
        case UInt32(cmdKey):     return .command
        case UInt32(optionKey):  return .option
        case UInt32(controlKey): return .control
        case UInt32(shiftKey):   return .shift
        default:                 return []
        }
    }
}

/// The user-configurable global shortcut that summons (toggles) the notch panel.
/// Persisted in `UserDefaults` as a `keyCode`/`modifiers` pair plus an enabled
/// flag, edited in Settings → General, registered by `AppDelegate`.
///
/// `keyCode` is a virtual key code (Carbon `kVK_*`); `modifiers` are Carbon hot
/// key modifier masks (`cmdKey`/`optionKey`/`controlKey`/`shiftKey`), which is
/// what `RegisterEventHotKey` wants.
///
/// There are two flavours of trigger, distinguished by `doubleTapModifier`:
///
/// - **Double-tap a bare modifier** (`doubleTapModifier != 0`) — the shipped
///   default is a double-tap of ⌥. `RegisterEventHotKey` can't see a lone
///   modifier, so this is detected by watching `flagsChanged` (see
///   `DoubleTapModifierMonitor`); `keyCode`/`modifiers` are unused.
/// - **A chord** (`doubleTapModifier == 0`) — e.g. ⌥Space or ⌘⇧K, recorded in
///   Settings and registered through Carbon. The original mechanism.
struct SummonHotKey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// Non-zero ⇒ this shortcut is a double-tap of a *bare* modifier, and the
    /// value is that modifier's Carbon mask (e.g. `optionKey`). Zero ⇒ it's a
    /// Carbon chord described by `keyCode`/`modifiers`.
    var doubleTapModifier: UInt32 = 0
    /// When false the shortcut isn't registered at all — hover stays the only
    /// way in, for users who don't want a global key grabbing the summon.
    var enabled: Bool

    /// Whether this config triggers on a double-tapped bare modifier.
    var isDoubleTap: Bool { doubleTapModifier != 0 }

    /// Double-tap ⌥ — the shipped default. Reachable one-handed, taken by no
    /// system shortcut, and never collides with a typed character.
    static let defaultConfig = SummonHotKey(
        keyCode: 0,
        modifiers: 0,
        doubleTapModifier: UInt32(optionKey),
        enabled: true
    )

    private static let keyCodeKey = "summonHotKey.keyCode"
    private static let modifiersKey = "summonHotKey.modifiers"
    private static let doubleTapKey = "summonHotKey.doubleTapModifier"
    private static let enabledKey = "summonHotKey.enabled"

    static var current: SummonHotKey {
        get {
            let defaults = UserDefaults.standard
            // No stored config at all (neither a recorded chord nor a double-tap
            // choice) → first run → ship the default (double-tap ⌥).
            guard defaults.object(forKey: keyCodeKey) != nil
                    || defaults.object(forKey: doubleTapKey) != nil else {
                return .defaultConfig
            }
            let code = UInt32(bitPattern: Int32(defaults.integer(forKey: keyCodeKey)))
            let mods = UInt32(bitPattern: Int32(defaults.integer(forKey: modifiersKey)))
            let dbl = UInt32(bitPattern: Int32(defaults.integer(forKey: doubleTapKey)))
            // `enabled` defaults to true when the flag was never written (e.g. a
            // config saved before the flag existed); only an explicit false disables.
            let enabled = defaults.object(forKey: enabledKey) as? Bool ?? true
            return SummonHotKey(keyCode: code, modifiers: mods,
                                doubleTapModifier: dbl, enabled: enabled)
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(Int(Int32(bitPattern: newValue.keyCode)), forKey: keyCodeKey)
            defaults.set(Int(Int32(bitPattern: newValue.modifiers)), forKey: modifiersKey)
            defaults.set(Int(Int32(bitPattern: newValue.doubleTapModifier)), forKey: doubleTapKey)
            defaults.set(newValue.enabled, forKey: enabledKey)
        }
    }

    /// A human-readable rendering for the settings row: a double-tapped modifier
    /// shows the glyph twice (e.g. `⌥⌥`); a chord shows modifiers + key (`⌘⇧K`).
    var displayString: String {
        if isDoubleTap {
            let glyph = SummonHotKey.modifierSymbols(doubleTapModifier)
            return glyph + glyph
        }
        return SummonHotKey.modifierSymbols(modifiers) + SummonHotKey.keyName(keyCode)
    }

    /// Carbon modifier mask → the glyphs macOS users expect, in the canonical
    /// ⌃⌥⇧⌘ order.
    static func modifierSymbols(_ modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s
    }

    /// Translate a Cocoa modifier-flags set (what `NSEvent` reports while
    /// recording) into the Carbon mask `RegisterEventHotKey` needs.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        return mods
    }

    /// A short printable name for a virtual key code. Covers the special keys a
    /// shortcut commonly lands on; everything else falls back to the uppercased
    /// character the key produces, and an unknown code to "Key".
    static func keyName(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space:        return "Space"
        case kVK_Return:       return "↩"
        case kVK_Tab:          return "⇥"
        case kVK_Escape:       return "⎋"
        case kVK_Delete:       return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow:    return "←"
        case kVK_RightArrow:   return "→"
        case kVK_UpArrow:      return "↑"
        case kVK_DownArrow:    return "↓"
        case kVK_F1:  return "F1";  case kVK_F2:  return "F2";  case kVK_F3:  return "F3"
        case kVK_F4:  return "F4";  case kVK_F5:  return "F5";  case kVK_F6:  return "F6"
        case kVK_F7:  return "F7";  case kVK_F8:  return "F8";  case kVK_F9:  return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default:
            return printableKeyName(keyCode) ?? "Key"
        }
    }

    /// The character a key produces with no modifiers, uppercased — so the W key
    /// reads as "W", the 5 key as "5". Resolved through the current keyboard
    /// layout so non-US layouts label correctly. `nil` when the key has no
    /// printable output (e.g. a dead modifier), letting the caller fall back.
    private static func printableKeyName(_ keyCode: UInt32) -> String? {
        guard let layoutData = TISGetInputSourceProperty(
            TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue(),
            kTISPropertyUnicodeKeyLayoutData
        ) else { return nil }
        let layout = unsafeBitCast(layoutData, to: CFData.self)
        guard let keyLayoutPtr = CFDataGetBytePtr(layout) else { return nil }
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = keyLayoutPtr.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { ptr in
            UCKeyTranslate(
                ptr,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0, // no modifiers
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let result = String(utf16CodeUnits: chars, count: length).uppercased()
        return result.isEmpty ? nil : result
    }
}

/// A local, user-editable keyboard chord. Unlike `SummonHotKey`, these only act
/// while a Notch panel is the key window, so they never steal a key from another
/// app. The stored representation intentionally matches the summon chord's
/// Carbon key-code/modifier pair, which keeps recording, rendering and conflict
/// checks identical across the whole Shortcuts pane.
struct ShortcutChord: Codable, Equatable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    var displayString: String {
        SummonHotKey.modifierSymbols(modifiers) + SummonHotKey.keyName(keyCode)
    }

    func matches(_ event: NSEvent) -> Bool {
        guard UInt32(event.keyCode) == keyCode else { return false }
        return modifiers == SummonHotKey.carbonModifiers(from: event.modifierFlags)
    }
}

/// One user-authored instruction bound directly to a global shortcut. The prompt
/// is the row's identity and always acts on the current text selection; an
/// optional AI-suggested `name` lets the shortcut surface as a named, switchable
/// mode in the `/` menu. `name` is `nil` for shortcuts created before naming
/// existed — `displayName` falls back to the prompt so those rows stay readable.
struct PromptShortcut: Codable, Equatable, Identifiable {
    var id: UUID
    var shortcut: ShortcutChord?
    var prompt: String
    /// AI-generated display name for the `/` menu. Decodes to `nil` for old
    /// persisted rows (optional Codable = zero-migration), so already-added
    /// shortcuts work without any data rewrite.
    var name: String?

    init(id: UUID = UUID(), shortcut: ShortcutChord? = nil, prompt: String = "",
         name: String? = nil) {
        self.id = id
        self.shortcut = shortcut
        self.prompt = prompt
        self.name = name
    }

    /// What the row/menu shows: the name when one has been generated, else a
    /// truncated slice of the prompt — the same fallback old rows get before
    /// their first AI naming pass runs.
    var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 24 ? String(trimmed.prefix(24)) + "…" : trimmed
    }

    var isReady: Bool {
        shortcut != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Small versionless store for the equally small `[shortcut, prompt]` list.
/// `Codable` keeps the persisted shape explicit and makes a later migration easy
/// without introducing a database for a handful of settings rows.
enum PromptShortcutStore {
    private static let key = "promptShortcuts"

    static var current: [PromptShortcut] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let shortcuts = try? JSONDecoder().decode([PromptShortcut].self, from: data)
        else { return [] }
        return shortcuts
    }

    static func save(_ shortcuts: [PromptShortcut]) {
        guard let data = try? JSONEncoder().encode(shortcuts) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func shortcut(id: UUID) -> PromptShortcut? {
        current.first { $0.id == id }
    }
}

/// Reads the selection owned by the app that is currently focused. This must run
/// before Notch opens and activates itself; after activation, the focused element
/// would be Notch's own prompt field and the outside selection would be lost.
///
/// No clipboard fallback exists here. Native controls usually expose
/// `AXSelectedText` directly; browser/Electron/PDF surfaces commonly expose only
/// a selected character range or a WebKit text-marker range, sometimes on an
/// ancestor of the focused node. Try those representations in that order so the
/// shortcut remains selection-first without mutating the user's clipboard.
enum SelectedTextCapture {
    enum CaptureResult {
        case text(String)
        case permissionRequired
        case noSelection
    }

    /// The one-shot read. Answers instantly from whatever tree exists right now —
    /// which is everything a native app needs, and (see `current(completion:)`)
    /// not always enough for web content.
    static func current(promptForPermission: Bool = true,
                        front: NSRunningApplication? = nil) -> CaptureResult {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptForPermission
        ] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            return .permissionRequired
        }

        guard var element = focusedElement(front: front) else {
            return selectionInFocusedWindow(of: front).map(CaptureResult.text) ?? .noSelection
        }

        // The selected-text representation is often owned by the focused node's
        // WebArea/scroll-area parent rather than the leaf itself. Walk upward only
        // (bounded) — scanning a whole browser accessibility tree can contain tens
        // of thousands of nodes and would make a shortcut visibly stall.
        for _ in 0..<12 {
            AXUIElementSetMessagingTimeout(element, 0.25)

            // Secure text fields must never become model input. Stop entirely,
            // rather than walking to a parent that might expose the same value in
            // a less explicitly protected representation.
            if isSecureTextField(element) { return .noSelection }
            if let selected = selectedText(in: element) { return .text(selected) }

            guard let parent = axElement(attribute(kAXParentAttribute, of: element)),
                  !CFEqual(parent, element)
            else { break }
            element = parent
        }
        // Focus can sit on a node that owns no selection of its own and whose
        // ancestors are plain containers — a Chromium window whose tree has only
        // just been built puts focus on the window itself, with the selection on
        // the web area a level or two below. Sweep down for it.
        return selectionInFocusedWindow(of: front).map(CaptureResult.text) ?? .noSelection
    }

    /// The reliable read, for the prompt shortcut. Chromium and Electron ship with
    /// their web-content accessibility tree switched OFF and only build it once an
    /// assistive client asks — which is exactly why a shortcut fired over Chrome
    /// "sometimes" comes back empty: in a browser process nobody has queried yet,
    /// there is no tree to read, and the read that finds nothing is itself what
    /// turns it on (so the *next* chord works, and the bug reads as random).
    ///
    /// So: try once (native apps answer immediately and pay nothing), and only if
    /// that finds nothing, ask the front app to switch its web tree on and re-read
    /// on a background queue until it appears. Runs while the user still owns
    /// focus — nothing has activated Notch yet — so the selection is still theirs
    /// to read. `completion` always lands on the main queue.
    static func current(promptForPermission: Bool = true,
                        completion: @escaping (CaptureResult) -> Void) {
        let front = NSWorkspace.shared.frontmostApplication
        let first = current(promptForPermission: promptForPermission, front: front)
        switch first {
        case .text, .permissionRequired:
            completion(first)
            return
        case .noSelection:
            break
        }
        DispatchQueue.global(qos: .userInitiated).async {
            enableWebAccessibility(for: front)
            for wait in webTreeRetryWaits {
                Thread.sleep(forTimeInterval: wait)
                if case .text(let selected) = current(promptForPermission: false, front: front) {
                    DispatchQueue.main.async { completion(.text(selected)) }
                    return
                }
            }
            DispatchQueue.main.async { completion(.noSelection) }
        }
    }

    /// Gaps between re-reads while a web tree is being built — tight at first (an
    /// already-warm renderer answers in one hop), spreading out to cover a cold
    /// browser process. ~0.8s in total, and only ever paid on the path that
    /// currently returns nothing at all.
    private static let webTreeRetryWaits: [TimeInterval] = [0.06, 0.09, 0.15, 0.2, 0.3]

    /// Chromium's documented opt-in for non-VoiceOver assistive clients: setting
    /// `AXManualAccessibility` on the application element makes it build the web
    /// content tree. Electron inherits it. A native app answers "unsupported", so
    /// this is safe to set blind rather than sniffing bundle identifiers — and it
    /// is only ever sent to an app whose selection the user just asked for, so no
    /// browser pays the cost of an always-on tree for a feature they never use.
    private static func enableWebAccessibility(for app: NSRunningApplication?) {
        guard let app else { return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString,
                                     kCFBooleanTrue)
    }

    /// Bounded top-down sweep of the front app's focused window for a node that
    /// owns a selection. Strictly capped (breadth, depth, and total nodes visited):
    /// a web area sits one to three levels under the window, while an uncapped walk
    /// of a browser tree is tens of thousands of nodes and would stall the chord.
    private static func selectionInFocusedWindow(of app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let window = axElement(attribute(kAXFocusedWindowAttribute, of: application))
                ?? axElement(attribute(kAXMainWindowAttribute, of: application))
        else { return nil }

        var frontier = [window]
        var visited = 0
        for _ in 0..<5 {
            var next: [AXUIElement] = []
            for element in frontier {
                visited += 1
                if visited > 60 { return nil }
                AXUIElementSetMessagingTimeout(element, 0.25)
                if isSecureTextField(element) { continue }
                if let selected = selectedText(in: element) { return selected }
                guard let children = attribute(kAXChildrenAttribute, of: element) as? [AnyObject]
                else { continue }
                for child in children.prefix(12) {
                    if let element = axElement(child as CFTypeRef) { next.append(element) }
                }
            }
            if next.isEmpty { return nil }
            frontier = Array(next.prefix(20))
        }
        return nil
    }

    /// Resolve the element that belonged to the foreground app at the instant the
    /// global shortcut fired. The system-wide focused element is the fast path;
    /// the application-level query covers frameworks that omit it there.
    private static func focusedElement(front: NSRunningApplication? = nil) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        if let focused = axElement(attribute(kAXFocusedUIElementAttribute, of: system)) {
            return focused
        }
        guard let app = front ?? NSWorkspace.shared.frontmostApplication else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        return axElement(attribute(kAXFocusedUIElementAttribute, of: application))
    }

    private static func isSecureTextField(_ element: AXUIElement) -> Bool {
        (attribute(kAXSubroleAttribute, of: element) as? String)
            == (kAXSecureTextFieldSubrole as String)
    }

    /// Read each representation used by macOS text providers. The public range
    /// API covers native editors that omit `AXSelectedText`; WebKit/Chromium expose
    /// their document selection as a text-marker range instead.
    private static func selectedText(in element: AXUIElement) -> String? {
        if let selected = nonEmptyString(attribute(kAXSelectedTextAttribute, of: element)) {
            return selected
        }

        if let range = attribute(kAXSelectedTextRangeAttribute, of: element),
           let selected = string(forCharacterRange: range, in: element) {
            return selected
        }

        if let ranges = attribute(kAXSelectedTextRangesAttribute, of: element) as? [Any] {
            let selections = ranges.compactMap { item -> String? in
                string(forCharacterRange: item as CFTypeRef, in: element)
            }
            let combined = selections.joined(separator: "\n")
            if !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return combined
            }
        }

        // Text-marker attributes are the representation used by web content.
        // Their names are stable Accessibility protocol names, but are not exposed
        // as constants in the macOS 14 SDK.
        if let markerRange = attribute("AXSelectedTextMarkerRange", of: element) {
            if let selected = nonEmptyString(parameterizedAttribute(
                "AXStringForTextMarkerRange", parameter: markerRange, of: element
            )) {
                return selected
            }
            if let selected = nonEmptyString(parameterizedAttribute(
                "AXAttributedStringForTextMarkerRange", parameter: markerRange, of: element
            )) {
                return selected
            }
        }
        return nil
    }

    private static func string(forCharacterRange range: CFTypeRef,
                               in element: AXUIElement) -> String? {
        if let selected = nonEmptyString(parameterizedAttribute(
            kAXStringForRangeParameterizedAttribute, parameter: range, of: element
        )) {
            return selected
        }
        if let selected = nonEmptyString(parameterizedAttribute(
            kAXAttributedStringForRangeParameterizedAttribute, parameter: range, of: element
        )) {
            return selected
        }

        // Some third-party controls expose the range and full value but omit the
        // parameterized substring attribute. Slice their value as a final public-
        // API fallback, using NSString because AX ranges are UTF-16 character ranges.
        guard let value = attribute(kAXValueAttribute, of: element) as? String,
              let selectedRange = cfRange(from: range),
              selectedRange.location >= 0, selectedRange.length > 0
        else { return nil }
        let string = value as NSString
        guard selectedRange.location <= string.length,
              selectedRange.length <= string.length - selectedRange.location
        else { return nil }
        let selected = string.substring(with: NSRange(
            location: selectedRange.location, length: selectedRange.length
        ))
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return selected
    }

    private static func cfRange(from value: CFTypeRef) -> CFRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func nonEmptyString(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        let string: String?
        if let plain = value as? String {
            string = plain
        } else if let attributed = value as? NSAttributedString {
            string = attributed.string
        } else {
            string = nil
        }
        guard let string,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return string
    }

    private static func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value
    }

    private static func parameterizedAttribute(_ name: String, parameter: CFTypeRef,
                                               of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, name as CFString, parameter, &value
        ) == .success else { return nil }
        return value
    }
}

/// Prompt-flow keys whose meaning is structural rather than personal. Keeping
/// these fixed preserves the fast keyboard grammar of the composer and prevents
/// editable actions (including the global summon chord) from claiming them.
enum ReservedAppShortcut {
    static let sendOther = ShortcutChord(keyCode: UInt32(kVK_Return),
                                         modifiers: UInt32(cmdKey))
    static let cycleIntent = ShortcutChord(keyCode: UInt32(kVK_Tab), modifiers: 0)
    static let bucket = ShortcutChord(keyCode: UInt32(kVK_Tab), modifiers: UInt32(shiftKey))
}

/// Product actions whose chords are useful to personalize. Editing conventions
/// such as Return to submit, arrows to move/recall, `/` to open commands, and
/// ⌘V to paste stay fixed: changing those would make the prompt stop behaving
/// like a Mac text field.
enum AppShortcutAction: String, CaseIterable, Identifiable, Hashable {
    case copyAnswer
    case regenerate
    case pin
    case newChat
    case filter
    case picker
    case detach

    var id: String { rawValue }

    var label: String {
        switch self {
        case .copyAnswer:  return L("shortcuts.copyAnswer")
        case .regenerate:  return L("shortcuts.regenerate")
        case .pin:         return L("shortcuts.pin")
        case .newChat:     return L("shortcuts.newChat")
        case .filter:      return L("shortcuts.filter")
        case .picker:      return L("shortcuts.picker")
        case .detach:      return L("shortcuts.detach")
        }
    }

    /// The stable snake_case id the settings tool speaks — chat can say
    /// "copy_answer" in any interface language and land on the same action the
    /// Shortcuts pane edits. Never localized, never renamed.
    var token: String {
        switch self {
        case .copyAnswer: return "copy_answer"
        case .regenerate: return "regenerate"
        case .pin:        return "pin"
        case .newChat:    return "new_chat"
        case .filter:     return "filter"
        case .picker:     return "picker"
        case .detach:     return "detach"
        }
    }

    /// Accepts the canonical token plus the spellings a model reaches for first.
    static func parse(_ raw: String) -> AppShortcutAction? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch token {
        case "copy_answer", "copyanswer", "copy": return .copyAnswer
        case "regenerate", "retry": return .regenerate
        case "pin": return .pin
        case "new_chat", "newchat", "new": return .newChat
        case "filter", "search": return .filter
        case "picker", "model_picker", "modelpicker": return .picker
        case "detach", "detached_window": return .detach
        default: return nil
        }
    }

    var defaultChord: ShortcutChord {
        switch self {
        case .copyAnswer:  return ShortcutChord(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey))
        case .regenerate:  return ShortcutChord(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey))
        case .pin:         return ShortcutChord(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey))
        case .newChat:     return ShortcutChord(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey))
        case .filter:      return ShortcutChord(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey))
        case .picker:
            return ShortcutChord(keyCode: UInt32(kVK_ANSI_I),
                                 modifiers: UInt32(cmdKey) | UInt32(shiftKey))
        case .detach:
            return ShortcutChord(keyCode: UInt32(kVK_ANSI_Equal),
                                 modifiers: UInt32(controlKey) | UInt32(shiftKey))
        }
    }
}

/// Persistence and validation for all in-app editable shortcuts. Each action is
/// stored independently so future actions can be added without migrating a
/// serialized blob. Validation is shared by the UI and intent-driven settings
/// changes, preventing two paths from accepting different combinations.
enum AppShortcutStore {
    private static let prefix = "appShortcut."
    /// Key events arrive for every character typed. Keep the resolved values in
    /// memory instead of consulting `UserDefaults` up to ten times per key-down;
    /// all writes flow through `set`/`reset`, which update this cache in lockstep.
    private static var cache: [AppShortcutAction: ShortcutChord] =
        Dictionary(uniqueKeysWithValues: AppShortcutAction.allCases.map {
            ($0, storedChord(for: $0))
        })

    static func chord(for action: AppShortcutAction) -> ShortcutChord {
        cache[action] ?? action.defaultChord
    }

    private static func storedChord(for action: AppShortcutAction) -> ShortcutChord {
        let defaults = UserDefaults.standard
        let base = prefix + action.rawValue
        guard defaults.object(forKey: base + ".keyCode") != nil else {
            return action.defaultChord
        }
        return ShortcutChord(
            keyCode: UInt32(bitPattern: Int32(defaults.integer(forKey: base + ".keyCode"))),
            modifiers: UInt32(bitPattern: Int32(defaults.integer(forKey: base + ".modifiers")))
        )
    }

    static var current: [AppShortcutAction: ShortcutChord] {
        cache
    }

    static func set(_ chord: ShortcutChord, for action: AppShortcutAction) {
        let base = prefix + action.rawValue
        UserDefaults.standard.set(Int(Int32(bitPattern: chord.keyCode)), forKey: base + ".keyCode")
        UserDefaults.standard.set(Int(Int32(bitPattern: chord.modifiers)), forKey: base + ".modifiers")
        cache[action] = chord
    }

    static func reset(_ action: AppShortcutAction) {
        let base = prefix + action.rawValue
        UserDefaults.standard.removeObject(forKey: base + ".keyCode")
        UserDefaults.standard.removeObject(forKey: base + ".modifiers")
        cache[action] = action.defaultChord
    }

    static func matches(_ action: AppShortcutAction, event: NSEvent) -> Bool {
        chord(for: action).matches(event)
    }

    /// Returns the name of the existing owner when a chord cannot be assigned.
    /// `nil` means it is safe to commit.
    static func conflictOwner(
        for proposed: ShortcutChord,
        editingAction: AppShortcutAction? = nil,
        editingSummon: Bool = false
    ) -> String? {
        // Fixed app commands which must retain their conventional meaning.
        let fixed: [(ShortcutChord, String)] = [
            (ReservedAppShortcut.sendOther, L("shortcuts.sendOther")),
            (ReservedAppShortcut.cycleIntent, L("shortcuts.cycleIntent")),
            (ReservedAppShortcut.bucket, L("shortcuts.bucket")),
            (ShortcutChord(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(cmdKey)),
             L("shortcuts.reserved.settings")),
            (ShortcutChord(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey)),
             L("shortcuts.pasteImage")),
        ]
        if let match = fixed.first(where: { $0.0 == proposed }) { return match.1 }

        // Combinations owned by macOS or the standard app/window menu should not
        // become a control that appears editable but never fires reliably.
        let systemReserved: [ShortcutChord] = [
            ShortcutChord(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey)),
            ShortcutChord(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey)),
            ShortcutChord(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey)),
            ShortcutChord(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey)),
            ShortcutChord(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)),
            ShortcutChord(keyCode: UInt32(kVK_Space),
                          modifiers: UInt32(cmdKey) | UInt32(optionKey)),
            ShortcutChord(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey)),
            ShortcutChord(keyCode: UInt32(kVK_Tab),
                          modifiers: UInt32(cmdKey) | UInt32(shiftKey)),
            ShortcutChord(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(controlKey)),
            ShortcutChord(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(controlKey)),
            ShortcutChord(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(controlKey)),
            ShortcutChord(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(controlKey)),
            ShortcutChord(keyCode: UInt32(kVK_ANSI_Q),
                          modifiers: UInt32(controlKey) | UInt32(cmdKey)),
        ]
        if systemReserved.contains(proposed) { return L("shortcuts.reserved.system") }

        for action in AppShortcutAction.allCases where action != editingAction {
            if chord(for: action) == proposed { return action.label }
        }

        let summon = SummonHotKey.current
        if !editingSummon, summon.enabled, !summon.isDoubleTap,
           ShortcutChord(keyCode: summon.keyCode, modifiers: summon.modifiers) == proposed {
            return L("shortcuts.summon")
        }
        return nil
    }
}

enum EditableShortcut: Hashable {
    case summon
    case action(AppShortcutAction)
    case prompt(UUID)
}

/// Replaces a legacy, hard-coded trailing chord in localized tooltip copy with
/// the action's live chord. This preserves the existing translation while making
/// every affordance agree with the Shortcuts settings pane immediately.
func shortcutHelp(_ localizationKey: String, action: AppShortcutAction) -> String {
    var base = L(localizationKey)
    if base.hasSuffix(")"), let open = base.lastIndex(of: "(") {
        base = String(base[..<open]).trimmingCharacters(in: .whitespaces)
    } else if base.hasSuffix("）"), let open = base.lastIndex(of: "（") {
        base = String(base[..<open]).trimmingCharacters(in: .whitespaces)
    }
    return "\(base) (\(AppShortcutStore.chord(for: action).displayString))"
}

/// The single source of truth for the keyboard-shortcut reference shown both in
/// Settings and to the model when somebody asks about shortcuts in chat. Keep
/// fixed chords here beside the one live, user-configurable summon shortcut so
/// those two surfaces can never drift apart.
struct AppShortcutReference {
    struct Group {
        let title: String
        let entries: [Entry]
    }

    struct Entry {
        let label: String
        let chords: [String]
        let editable: EditableShortcut?
        /// Shown instead of keycaps when the shortcut is currently disabled.
        let note: String?

        init(_ label: String, _ chords: [String], note: String? = nil,
             editable: EditableShortcut? = nil) {
            self.label = label
            self.chords = chords
            self.note = note
            self.editable = editable
        }
    }

    static func groups(
        summonHotKey: SummonHotKey = .current,
        shortcuts: [AppShortcutAction: ShortcutChord] = AppShortcutStore.current
    ) -> [Group] {
        func editable(_ action: AppShortcutAction) -> Entry {
            Entry(action.label,
                  [(shortcuts[action] ?? action.defaultChord).displayString],
                  editable: .action(action))
        }
        return [
            Group(title: L("shortcuts.group.summon"), entries: [
                Entry(L("shortcuts.summon"),
                      summonHotKey.enabled ? [summonHotKey.displayString] : [],
                      note: summonHotKey.enabled ? nil : L("general.shortcut.off"),
                      editable: .summon),
            ]),
            Group(title: L("shortcuts.group.prompt"), entries: [
                Entry(L("shortcuts.send"), ["↵"]),
                Entry(L("shortcuts.sendOther"), [ReservedAppShortcut.sendOther.displayString]),
                Entry(L("shortcuts.cycleIntent"), [ReservedAppShortcut.cycleIntent.displayString]),
                Entry(L("shortcuts.bucket"), [ReservedAppShortcut.bucket.displayString]),
                Entry(L("shortcuts.recall"), ["↑", "↓"]),
                Entry(L("shortcuts.slash"), ["/"]),
                Entry(L("shortcuts.pasteImage"), ["⌘V"]),
            ]),
            Group(title: L("shortcuts.group.answer"), entries: [
                editable(.copyAnswer),
                editable(.regenerate),
                editable(.pin),
                editable(.newChat),
                Entry(L("shortcuts.back"), ["←"]),
            ]),
            Group(title: L("shortcuts.group.panel"), entries: [
                editable(.filter),
                editable(.picker),
                editable(.detach),
            ]),
        ]
    }
}
