import Foundation

/// A tiny, local-only diagnostics ring for *failures* — so when an Ask falls over
/// there's a breadcrumb to look at, without ever phoning home (XII-85).
///
/// **It records metadata only — never payload.** No prompt text, no clipboard
/// contents, no answer, no API key. Just: when, which provider, the HTTP status
/// (when known), and a short error category string. That keeps the app's "no
/// telemetry / no account / private by default" promise intact: nothing here
/// could reconstruct what the user asked or what they had copied, and nothing
/// leaves the machine — entries live in memory and (optionally) a small local
/// file the user could read or delete themselves.
///
/// Use it from the failure paths (the `submit` catch, the service layer) via
/// `DiagnosticsLog.shared.record(...)`. The most recent entries are kept; old
/// ones roll off so the log can't grow without bound.
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()

    /// One failure breadcrumb. Deliberately holds nothing that could identify the
    /// content of a request — only the shape of the failure.
    struct Entry: Codable {
        let at: Date
        /// Provider display name (e.g. "Anthropic", "OpenRouter") — not the key.
        let provider: String
        /// HTTP status when the failure was an HTTP error, else nil (e.g. a timeout
        /// or offline drop that never reached a response).
        let status: Int?
        /// A short, payload-free category, e.g. "http", "timeout", "offline",
        /// "malformed", "cancelled", "unknown". No free-form server body, no message
        /// that could echo user content.
        let kind: String
    }

    private let maxEntries = 50
    private let queue = DispatchQueue(label: "com.notchglass.diagnostics")
    private var entries: [Entry] = []

    /// Where the optional on-disk copy lives — under Application Support, the user's
    /// own account-private area. Nil if the directory can't be resolved.
    private let fileURL: URL? = {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first
        else { return nil }
        let appDir = dir.appendingPathComponent("Notchi", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("diagnostics.json")
    }()

    private init() {
        load()
    }

    /// Record a failure breadcrumb. Categorize from a raw `Error` so callers don't
    /// have to — but they can pass an explicit `status`/`kind` when they know more
    /// (e.g. the service layer already parsed the HTTP code).
    func record(provider: String, status: Int? = nil, kind: String? = nil, error: Error? = nil) {
        let resolvedKind = kind ?? DiagnosticsLog.categorize(error)
        let entry = Entry(at: Date(), provider: provider, status: status, kind: resolvedKind)
        queue.async { [weak self] in
            guard let self else { return }
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
            self.persist()
        }
    }

    /// The recent breadcrumbs, newest last. Snapshotted so callers never touch the
    /// mutable store off-queue.
    var recent: [Entry] {
        queue.sync { entries }
    }

    /// Wipe the log (memory + disk). For a future "clear diagnostics" affordance.
    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            self.entries.removeAll()
            if let url = self.fileURL { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: - Categorization

    /// Map a raw error to a short, payload-free category. URLError cases become
    /// network categories; everything else is "unknown". Crucially this reads only
    /// the error's *type/code*, never any attached message that might carry content.
    private static func categorize(_ error: Error?) -> String {
        guard let error else { return "unknown" }
        if error is CancellationError { return "cancelled" }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:                 return "timeout"
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .cannotConnectToHost,
                 .cannotFindHost:           return "offline"
            default:                        return "network"
            }
        }
        return "unknown"
    }

    // MARK: - Persistence (best-effort, runs on `queue`)

    private func persist() {
        guard let url = fileURL else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func load() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let restored = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = Array(restored.suffix(maxEntries))
    }
}

// MARK: - Click-to-open probe

import AppKit
import os

/// Temporary instrumentation for the `.click` hover level's open path — the one
/// that "sometimes needs two clicks". It traces every left press that lands near
/// a resting notch through the four stages it has to survive:
///
///   1. `press`     — the raw `NSEvent`, and crucially whether our panel got it
///                    at all (`local`) or it went to the app underneath
///                    (`global` only ⇒ the window never saw the click).
///   2. `gesture`   — SwiftUI's tap target fired `NotchModel.notchClicked`.
///   3. `openPanel` — the model accepted it (and whether it was the closed→open
///                    edge or a no-op re-entry).
///   4. `open=true` — the island actually unfurled.
///
/// A press that dies is printed with the stages it *did* reach, so the missing
/// step names the culprit instead of leaving "it feels flaky".
///
/// **Metadata only**, same promise as `DiagnosticsLog`: stage names, geometry
/// booleans, and the press's offset from the notch rect. No keystrokes, no
/// clipboard, no pointer trail away from the notch — presses that land nowhere
/// near the island are ignored outright.
///
/// Off unless `NotchClickProbe` is set in defaults; on by default in DEBUG
/// builds, which is what `scripts/reinstall.sh` installs.
@MainActor
final class ClickOpenProbe {
    static let shared = ClickOpenProbe()

    static let isEnabled: Bool = {
        if let forced = UserDefaults.standard.object(forKey: "NotchClickProbe") as? Bool {
            return forced
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// How far outside the resting rect a press still counts as aimed at the
    /// notch — a near miss is exactly the case worth seeing.
    private static let catchSlop: CGFloat = 80
    /// How long a press gets to produce an unfurl before the verdict is printed.
    private static let verdict: TimeInterval = 0.6

    private let log = Logger(subsystem: "com.notchglass.notch", category: "click-open")
    private weak var model: NotchModel?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    /// Serial number of the press being traced, so interleaved lines group.
    private var press = 0
    /// Stages seen since the current press, with their offsets from it.
    private var trail: [String] = []
    private var pressedAt: Date?
    private var verdictTask: Task<Void, Never>?

    /// The on-disk trace, next to `diagnostics.json` in the user's own
    /// Application Support. Truncated at launch so a session reads clean.
    private lazy var fileURL: URL? = {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first
        else { return nil }
        let appDir = dir.appendingPathComponent("Notchi", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("click-open-trace.log")
    }()

    /// Install the press monitors. Both are needed and the pair IS the
    /// measurement: the local monitor only fires for events AppKit dispatched to
    /// this app, the global one only for events that went elsewhere — so a press
    /// on the notch seen by `global` alone means the panel never received it.
    func start(model: NotchModel) {
        guard Self.isEnabled, localMonitor == nil else { return }
        self.model = model
        if let fileURL { try? Data().write(to: fileURL) }
        write("── probe armed \(Self.stamp(Date())) ──")

        // Both monitors run on the main thread, and the local one runs BEFORE the
        // event reaches the window — so the state is read synchronously right
        // here. (Hopping to a `main.async` first was wrong: the hop lands after
        // SwiftUI has already handled the press, so every trace read back
        // `open=true, armed=false` — the post-open state, not the one the press
        // actually met.)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { event in
            MainActor.assumeIsolated { ClickOpenProbe.shared.mouseDown(scope: "global", event: event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            MainActor.assumeIsolated { ClickOpenProbe.shared.mouseDown(scope: "local", event: event) }
            return event
        }
        startWatch()
    }

    /// A 10Hz watch that prints ONLY when the model's answer changes — is the
    /// pointer inside the resting notch, is the peek up, is the panel open. A
    /// press trace can't explain "I moved to the very top and it went dead",
    /// because that case never produces a press; this can, and it costs one rect
    /// test per tick.
    private var watchTask: Task<Void, Never>?
    private var lastWatch = ""

    private func startWatch() {
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, let model = self.model else { return }
                let state = model.clickProbeState()
                // Only the pointer's own vertical band matters here; anything
                // further away than the press catch is not this investigation.
                guard let dy = state.dy, let dx = state.dx,
                      abs(dy) <= Self.catchSlop, abs(dx) <= Self.catchSlop else {
                    self.lastWatch = ""
                    continue
                }
                let key = "\(Self.b(state.insideRestingNotch))/\(state.peeking)/\(state.open)"
                guard key != self.lastWatch else { continue }
                self.lastWatch = key
                self.write("   watch \(Self.stamp(Date()))  \(Self.geometry(state)) "
                           + "peeking=\(state.peeking) open=\(state.open) armed=\(state.gestureArmed)")
            }
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    /// Record a stage of the current press. No-op when the probe is off, and
    /// when nothing is being traced (so background opens — hot key, notification
    /// — don't invent a press that never happened).
    func note(_ line: String) {
        guard Self.isEnabled, pressedAt != nil else { return }
        let dt = Int(Date().timeIntervalSince(pressedAt ?? Date()) * 1000)
        trail.append(line)
        write("  #\(press) +\(dt)ms  \(line)")
    }

    /// A hover-path event, logged whether or not a press is in flight — the
    /// "moving the pointer to the very top edge never wakes it" case never
    /// involves a press at all. Consecutive identical lines are folded so a
    /// polled watch can't flood the trace.
    private var lastHover = ""
    private var lastHoverAt = Date.distantPast

    func hover(_ line: String) {
        guard Self.isEnabled, let model else { return }
        let full = "\(line)  \(Self.geometry(model.clickProbeState()))"
        if full == lastHover, Date().timeIntervalSince(lastHoverAt) < 1 { return }
        lastHover = full
        lastHoverAt = Date()
        write("   hover \(Self.stamp(Date()))  \(full)")
    }

    /// The geometry half of a trace line: where the pointer is against the
    /// resting notch rect. `y` vs `top` is the boundary case — a pointer parked
    /// on the screen's very top row reports y exactly ON the rect's max edge,
    /// which `CGRect.contains` treats as outside.
    private static func geometry(_ state: NotchModel.ClickProbeState) -> String {
        "y=\(pt(state.pointerY)) top=\(pt(state.restTop)) dx=\(pt(state.dx)) dy=\(pt(state.dy)) "
        + "insideNotch=\(b(state.insideRestingNotch)) insideIsland=\(b(state.insideIsland))"
    }

    // MARK: - Press handling

    private func mouseDown(scope: String, event: NSEvent) {
        guard Self.isEnabled, let model else { return }
        let state = model.clickProbeState()
        // Only presses aimed at the notch are traced — everything else on the
        // screen is none of this probe's business.
        // Unknown geometry is NOT a reason to drop the press — that was the exact
        // state at the screen's top edge, where the failure lived, so a filter
        // that skipped it would hide the case it exists to catch.
        if let dx = state.dx, let dy = state.dy,
           abs(dx) > Self.catchSlop || abs(dy) > Self.catchSlop { return }

        // The local and global monitors both fire for a press the panel got
        // (AppKit posts it to us and the tap sees it once each on some paths):
        // fold a second sighting within a few ms into the trail rather than
        // starting a new case.
        if let pressedAt, Date().timeIntervalSince(pressedAt) < 0.05 {
            note("press also seen: \(scope)")
            return
        }

        press += 1
        pressedAt = Date()
        trail = []
        let window = event.window.map { String(describing: type(of: $0)) } ?? "none"
        write("""
        #\(press) press \(Self.stamp(Date())) scope=\(scope) window=\(window) \
        clicks=\(event.clickCount) appActive=\(NSApp.isActive)
          \(Self.geometry(state))
          open=\(state.open) closing=\(state.closing) peeking=\(state.peeking) \
        armed=\(state.gestureArmed) level=\(state.sensitivity) \
        display=\(state.display.map(String.init) ?? "nil") active=\(state.activeDisplay.map(String.init) ?? "nil")
        """)

        let id = press
        verdictTask?.cancel()
        verdictTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.verdict * 1_000_000_000))
            guard !Task.isCancelled, let self, self.press == id else { return }
            self.settle(id: id)
        }
    }

    /// Print the verdict for a press: opened, or lost — and where.
    private func settle(id: Int) {
        guard let model else { return }
        let opened = model.open
        if opened {
            write("#\(id) → OPENED\n")
        } else {
            let reached = trail.isEmpty ? "nothing after the press"
                                        : trail.joined(separator: " → ")
            write("#\(id) → NO OPEN  [\(reached)]\n")
            log.error("click on notch did not open: \(reached, privacy: .public)")
        }
        pressedAt = nil
        trail = []
    }

    // MARK: - Output

    private func write(_ line: String) {
        log.info("\(line, privacy: .public)")
        guard let fileURL, let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    private static func b(_ value: Bool?) -> String { value.map { "\($0)" } ?? "?" }
    private static func pt(_ value: CGFloat?) -> String {
        value.map { String(format: "%.0f", $0) } ?? "?"
    }
    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }
}
