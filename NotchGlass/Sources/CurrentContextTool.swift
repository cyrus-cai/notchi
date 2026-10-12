import AppKit
import ApplicationServices
import Foundation

/// The last app other than Notchi that was frontmost. Opening the panel and
/// typing in it can make Notchi the frontmost app, so "what the user is looking
/// at" is the app before it. Started at launch (`AppDelegate`).
@MainActor
final class FrontAppTracker {
    static let shared = FrontAppTracker()
    private(set) var lastExternal: NSRunningApplication?
    private var observer: NSObjectProtocol?

    private init() {
        let own = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own {
            lastExternal = front
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != own else { return }
            MainActor.assumeIsolated { FrontAppTracker.shared.lastExternal = app }
        }
    }

    /// The app the user is working in: the frontmost one, or the one before
    /// Notchi when Notchi is in front.
    var current: NSRunningApplication? {
        let own = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own {
            return front
        }
        return lastExternal?.isTerminated == false ? lastExternal : nil
    }
}

/// `current_context`: what the user has in front of them — the app, its window
/// title, and for a browser the page (address and text), for Mail the selected
/// message. Lets "这篇文章讲了什么" or "帮我回这封邮件" work without copying.
struct CurrentContextTool: NotchTool {
    static let toolName = "current_context"
    let name = toolName
    let description = """
    Reads what the user is looking at on this Mac: the app in front, its window \
    title, the open web page (address and text) when it is a browser, the \
    selected message when it is Mail, and the selected files when it is Finder. Call only when the question points at \
    something on screen that they did not paste or select — "this article", \
    "this page", "this email", "这篇", "这封", "这个页面" — and answer from the result.
    """
    let schema: [String: Any] = ["type": "object", "properties": [String: Any]()]

    /// Page text and message bodies, cut to this.
    private static let textLimit = 8000

    private static let browsers: [String: Browser] = [
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.brave.Browser": .chromium,
        "company.thebrowser.Browser": .chromium,   // Arc
        "com.vivaldi.Vivaldi": .chromium,
    ]

    private enum Browser { case safari, chromium }

    /// What the model is told when a read did not work.
    private struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    func execute(_ input: [String: Any]) async throws -> String {
        guard let app = await MainActor.run(body: { FrontAppTracker.shared.current }) else {
            return "No app is in front."
        }
        let appName = app.localizedName ?? "an app"
        let bundleID = app.bundleIdentifier ?? ""
        var lines = ["App in front: \(appName)" + (bundleID.isEmpty ? "" : " (\(bundleID))")]
        if let title = Self.windowTitle(pid: app.processIdentifier) {
            lines.append("Window: \(title)")
        }

        if let browser = Self.browsers[bundleID] {
            switch Self.frontTab(browser: browser, appName: appName) {
            case .success(let tab):
                lines.append("Page title: \(tab.title)")
                lines.append("Address: \(tab.url)")
                if tab.url.hasPrefix("http"),
                   let text = try? await ReadPageTool().execute(["url": tab.url]) {
                    lines.append("Page text (fetched from the address, may differ from a signed-in view):\n"
                                 + Self.cut(text))
                }
            case .failure(let failure):
                lines.append(failure.message)
            }
        } else if bundleID == "com.apple.finder" {
            switch Self.finderSelection() {
            case .success(let files): lines.append(files)
            case .failure(let failure): lines.append(failure.message)
            }
        } else if bundleID == "com.apple.mail" {
            switch Self.selectedMail() {
            case .success(let mail): lines.append(mail)
            case .failure(let failure): lines.append(failure.message)
            }
        } else if let text = Self.focusedText(pid: app.processIdentifier) {
            lines.append("Text in the focused field:\n" + Self.cut(text))
        }
        return lines.joined(separator: "\n")
    }

    private static func cut(_ text: String) -> String {
        text.count > textLimit ? String(text.prefix(textLimit)) + "…" : text
    }

    // MARK: Accessibility (window title, focused text) — skipped without the grant

    private static func windowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        let text = (title as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private static func focusedText(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if (subrole as? String) == (kAXSecureTextFieldSubrole as String) { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success
        else { return nil }
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    // MARK: AppleScript (browser tab, Mail selection) — the first call raises
    // the Automation prompt for that app

    private static func run(_ source: String) -> Result<NSAppleEventDescriptor, Failure> {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failure(Failure("Could not prepare the script.")) }
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            if number == -1743 || number == -1744 {
                return .failure(Failure("Notchi is not allowed to read that app. The user can allow it in System Settings → Privacy & Security → Automation."))
            }
            return .failure(Failure(error[NSAppleScript.errorMessage] as? String ?? "The app did not answer."))
        }
        return .success(result)
    }

    private static func frontTab(browser: Browser, appName: String) -> Result<(title: String, url: String), Failure> {
        let name = appName.replacingOccurrences(of: "\"", with: "")
        let source: String
        switch browser {
        case .safari:
            source = """
            tell application "\(name)" to return {name of front document, URL of front document}
            """
        case .chromium:
            source = """
            tell application "\(name)" to return {title of active tab of front window, URL of active tab of front window}
            """
        }
        switch run(source) {
        case .failure(let failure): return .failure(failure)
        case .success(let list):
            guard list.numberOfItems == 2,
                  let url = list.atIndex(2)?.stringValue, !url.isEmpty else {
                return .failure(Failure("No page is open in \(appName)."))
            }
            return .success((list.atIndex(1)?.stringValue ?? "", url))
        }
    }

    /// The files selected in Finder (paths), or the front window's folder when
    /// nothing is selected. read_file reads them when they are in Downloads,
    /// Desktop or Documents.
    private static func finderSelection() -> Result<String, Failure> {
        let source = """
        tell application "Finder"
            set picked to selection as alias list
            set out to {}
            repeat with f in picked
                set end of out to POSIX path of f
            end repeat
            if out is {} and (count of Finder windows) > 0 then
                return {"folder", POSIX path of (target of front Finder window as alias)}
            end if
            return {"selection"} & out
        end tell
        """
        switch run(source) {
        case .failure(let failure): return .failure(failure)
        case .success(let list):
            let items = list.numberOfItems > 0 ? (1...list.numberOfItems).compactMap { list.atIndex($0)?.stringValue } : []
            guard let head = items.first else { return .failure(Failure("Nothing is selected in Finder.")) }
            let paths = items.dropFirst().map { ($0 as NSString).abbreviatingWithTildeInPath }
            if head == "folder", let folder = paths.first {
                return .success("Nothing selected. Front Finder window shows: \(folder)")
            }
            guard !paths.isEmpty else { return .failure(Failure("Nothing is selected in Finder.")) }
            let shown = paths.prefix(50).map { "- \($0)" }.joined(separator: "\n")
            return .success("Selected in Finder:\n\(shown)" + (paths.count > 50 ? "\n…and \(paths.count - 50) more." : ""))
        }
    }

    private static func selectedMail() -> Result<String, Failure> {
        let source = """
        tell application "Mail"
            set picked to selection
            if picked is {} then return {}
            set m to item 1 of picked
            return {subject of m, sender of m, (date received of m) as string, content of m}
        end tell
        """
        switch run(source) {
        case .failure(let failure): return .failure(failure)
        case .success(let list):
            guard list.numberOfItems == 4 else { return .failure(Failure("No message is selected in Mail.")) }
            let field = { (i: Int) in list.atIndex(i)?.stringValue ?? "" }
            return .success("""
            Selected message
            Subject: \(field(1))
            From: \(field(2))
            Received: \(field(3))
            \(cut(field(4)))
            """)
        }
    }
}
