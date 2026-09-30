import AppKit
import SwiftUI

/// The link pre-check (Settings → Chat, off by default). With it on, a clicked
/// http(s) link is sent to the gateway's Jev route (`/v1/linkcheck`) before it
/// reaches the browser. `open` opens it as usual; `warn` puts a confirmation
/// card on the surface the click came from.
///
/// With the setting off, without an account token, or when the gateway gives no
/// answer, the link opens directly — the same behaviour as before this existed.
@MainActor
final class LinkGate: ObservableObject {
    static let shared = LinkGate()

    static let defaultsKey = "linkPrecheckEnabled"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// A flagged link waiting for the user's answer, and the window it was
    /// clicked in.
    struct Pending: Equatable {
        var url: URL
        var window: ObjectIdentifier
    }

    @Published private(set) var pending: Pending?

    /// Windows that mount `linkGateHost` and can show the card themselves.
    private var hosts: Set<ObjectIdentifier> = []
    /// Verdicts from this run, keyed by the address sent. True means `warn`.
    private var verdicts: [String: Bool] = [:]

    /// Open a link the user clicked. Anything that is not http(s) skips the check.
    func open(_ url: URL) {
        guard Self.applies(to: url) else {
            NSWorkspace.shared.open(url)
            return
        }
        let window = NSApp.currentEvent?.window.map(ObjectIdentifier.init)
        Task {
            guard await warns(url) else {
                NSWorkspace.shared.open(url)
                return
            }
            if let window, hosts.contains(window) {
                pending = Pending(url: url, window: window)
            } else {
                confirmWithAlert(url)
            }
        }
    }

    /// Whether Jev flags `url`. False when the check does not apply or fails.
    func warns(_ url: URL) async -> Bool {
        guard Self.applies(to: url) else { return false }
        let address = Self.address(for: url)
        if let known = verdicts[address] { return known }
        guard let verdict = await NoNoAccount.shared.checkLink(address) else { return false }
        let warn = verdict.verdict == "warn"
        verdicts[address] = warn
        return warn
    }

    /// The user confirmed the card: open the link.
    func confirm() {
        guard let pending else { return }
        self.pending = nil
        NSWorkspace.shared.open(pending.url)
    }

    /// Drop the card without opening. Returns whether there was one.
    @discardableResult
    func cancel() -> Bool {
        guard pending != nil else { return false }
        pending = nil
        return true
    }

    /// `cancel`, for a key pressed in `window`: drops the card only when it is
    /// shown there.
    @discardableResult
    func cancel(in window: NSWindow?) -> Bool {
        guard let pending, window.map(ObjectIdentifier.init) == pending.window else { return false }
        self.pending = nil
        return true
    }

    /// The surface that should show the card cannot (a closed island): ask in
    /// an alert instead of dropping the click.
    func moveToAlert() {
        guard let pending else { return }
        self.pending = nil
        confirmWithAlert(pending.url)
    }

    fileprivate func register(_ window: ObjectIdentifier) { hosts.insert(window) }
    fileprivate func unregister(_ window: ObjectIdentifier) {
        hosts.remove(window)
        if pending?.window == window { moveToAlert() }
    }

    private static func applies(to url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return isEnabled && (scheme == "http" || scheme == "https") && NoNoAccount.shared.hasToken
    }

    /// What is sent: the address without its password and fragment. The query
    /// is dropped too when it looks like it holds a credential or the address
    /// is longer than the gateway accepts.
    private static func address(for url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return String(url.absoluteString.prefix(2000))
        }
        parts.password = nil
        parts.fragment = nil
        var text = parts.string ?? url.absoluteString
        if parts.query != nil, ClipPrivacy.containsSecret(text) || text.count > 2000 {
            parts.query = nil
            text = parts.string ?? text
        }
        return String(text.prefix(2000))
    }

    private func confirmWithAlert(_ url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("linkCheck.warn.title")
        alert.informativeText = L("linkCheck.warn.body", url.host ?? url.absoluteString)
        alert.addButton(withTitle: L("clear.cancel"))
        alert.addButton(withTitle: L("linkCheck.warn.open"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }
}

extension View {
    /// Route this surface's link clicks through `LinkGate` and show its
    /// confirmation card here. `active` is false while the surface is not on
    /// screen (a closed island); a flagged link then asks in an alert.
    func linkGateHost(active: Bool = true) -> some View {
        modifier(LinkGateHost(active: active))
    }
}

private struct LinkGateHost: ViewModifier {
    var active: Bool
    @ObservedObject private var gate = LinkGate.shared
    @State private var window: ObjectIdentifier?

    private var mine: LinkGate.Pending? {
        guard let pending = gate.pending, pending.window == window else { return nil }
        return pending
    }

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                LinkGate.shared.open(url)
                return .handled
            })
            .background(WindowReader { found in
                if let window { gate.unregister(window) }
                window = found
                if let found { gate.register(found) }
            })
            .overlay {
                if let pending = mine, active {
                    LinkWarningConfirm(
                        host: pending.url.host ?? pending.url.absoluteString,
                        onCancel: { gate.cancel() },
                        onConfirm: { gate.confirm() }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.easeOut(duration: 0.16), value: mine)
            .onChange(of: mine) { _, pending in
                if pending != nil, !active { gate.moveToAlert() }
            }
            .onChange(of: active) { _, active in
                if !active, mine != nil { gate.moveToAlert() }
            }
    }
}

/// Reports the window this view sits in, and nil when it leaves.
private struct WindowReader: NSViewRepresentable {
    var onChange: (ObjectIdentifier?) -> Void

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.onChange = onChange
    }

    final class Probe: NSView {
        var onChange: ((ObjectIdentifier?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let found = window.map(ObjectIdentifier.init)
            DispatchQueue.main.async { [weak self] in self?.onChange?(found) }
        }
    }
}
