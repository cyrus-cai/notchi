import Foundation
import AppKit

/// Which local agent CLI an agent task runs on. Both are the same compliant
/// pattern — spawn the user's own official binary under their own sign-in — so
/// the runner only differs in argv and JSONL dialect.
enum AgentEngine: String, CaseIterable {
    case codex
    case claude
    case grok

    var displayName: String {
        switch self {
        case .codex:  return "Codex"
        case .claude: return "Claude"
        case .grok:   return "Grok"
        }
    }

    /// Installed + signed in, per the engine's own service.
    var isAvailable: Bool {
        switch self {
        case .codex:  return CodexCLIService.isAvailable
        case .claude: return ClaudeCLIService.isAvailable
        case .grok:   return GrokCLIService.isAvailable
        }
    }

    /// The terminal command that picks this engine's session back up. Neither
    /// CLI is spawned with `--ephemeral` / `--no-session-persistence`, so a run
    /// Notch lost track of (quit, crash) is still resumable by hand — the
    /// interrupted run's Recent row hands the user the exact line.
    func resumeCommand(session: String) -> String {
        switch self {
        case .codex:  return "codex resume \(session)"
        case .claude: return "claude --resume \(session)"
        case .grok:   return "grok --resume \(session)"
        }
    }

    /// The engines that can actually run right now — drives the entry button
    /// (any) and the armed line's engine chip (a toggle only when both).
    static var available: [AgentEngine] { allCases.filter(\.isAvailable) }

    /// The engine to arm by default: the last one used, if it's still available,
    /// else whichever is. Persisted whenever the armed engine changes.
    private static let defaultsKey = "agentEngine"
    static var preferred: AgentEngine? {
        if let stored = storedPreference, stored.isAvailable { return stored }
        return available.first
    }
    /// The raw remembered choice, with NO availability probe — safe to read on
    /// the main thread at model init (`isAvailable` shells out on a cold cache).
    static var storedPreference: AgentEngine? {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(AgentEngine.init)
    }
    static func rememberPreference(_ engine: AgentEngine) {
        UserDefaults.standard.set(engine.rawValue, forKey: defaultsKey)
    }

    /// This engine's entries in the armed row's model menu — named models only,
    /// no "CLI default" rung (a bare "Default" says nothing about what you'd
    /// get). Codex's pinnable ids come from the account's own `model/list`
    /// (fetched and cached by `CodexCLIService` at launch) — never hardcoded,
    /// because Codex has no rolling aliases and a retired id 404s the whole run.
    /// Claude's are the CLI's documented rolling aliases (they always point at
    /// the current lineup), since the Claude CLI has no model-list command to
    /// query. Codex keeps ONE fallback entry when that list hasn't landed
    /// (`id == nil` → the CLI's own default): the menu is also the only way to
    /// arm an engine, so an available engine must never have an empty section.
    var modelChoices: [AgentModelChoice] {
        switch self {
        case .codex:
            let listed = CodexCLIService.listedModels.map {
                AgentModelChoice(engine: self, id: $0.id, label: $0.displayName)
            }
            return listed.isEmpty
                ? [AgentModelChoice(engine: self, id: nil, label: displayName)]
                : listed
        case .claude:
            // The rolling aliases stay the pickable ids (they're what `--model`
            // takes), but each label names the CONCRETE model the alias points
            // at today — "Claude Opus 4.8", probed from the CLI and cached by
            // `ClaudeCLIService` — because a bare family word names a shelf,
            // not a model. Falls back to the family word until a probe lands.
            let resolved = ClaudeCLIService.resolvedModels
            return [("fable", "Claude Fable"), ("opus", "Claude Opus"),
                    ("sonnet", "Claude Sonnet")].map { alias, fallback in
                AgentModelChoice(
                    engine: self, id: alias,
                    label: resolved[alias].map(ClaudeCLIService.displayName(forResolved:))
                        ?? fallback)
            }
        case .grok:
            // Grok's models come from the CLI's own cache (see `GrokCLIService`),
            // labelled with the cache's display names ("Grok 4.5" — the id's bare
            // version tail says nothing in the list). An empty cache → the one
            // flag-less default entry (an available engine must never have an
            // empty section, since the menu is the only way to arm it).
            let listed = GrokCLIService.listedModels
            if listed.isEmpty {
                return [AgentModelChoice(engine: self, id: nil, label: displayName)]
            }
            return listed.map {
                AgentModelChoice(engine: self, id: $0.id, label: $0.displayName)
            }
        }
    }
}

/// One pickable model for an agent run. The armed row's model chip mixes
/// every available engine's entries into a single menu — choosing a model
/// chooses its engine with it. `id == nil` is the engine's own CLI-config
/// default (no model flag passed at all).
struct AgentModelChoice: Hashable {
    let engine: AgentEngine
    /// The value for the engine's model flag (`-m` / `--model`); nil = default.
    let id: String?
    /// The menu / chip title. A nil-id entry (Codex before its model list lands)
    /// carries the plain engine name.
    let label: String
}

/// Reasoning effort for an agent run — the armed row's third chip. `nil`
/// (no selection) leaves both CLIs on their own defaults. The full ladder both
/// CLIs speak today; which rungs the menu actually offers comes from
/// `AgentEngine.effortChoices(forModelID:)`, since they differ per engine
/// and (for Codex) per model.
enum AgentEffort: String, CaseIterable {
    case low, medium, high, xhigh, max, ultra
}

extension AgentEngine {
    /// The effort levels pickable for a run on this engine + model pick.
    /// Claude's is the CLI's documented `--effort` set. Codex's is the pinned
    /// model's own `supportedReasoningEfforts` from `model/list` (they differ
    /// per model — e.g. only some models take `ultra`); for the default pick
    /// (`modelID == nil`) that's the account-default model's set. Until the
    /// list is fetched, the lowest common denominator every model accepts.
    func effortChoices(forModelID modelID: String?) -> [AgentEffort] {
        switch self {
        case .claude:
            return [.low, .medium, .high, .xhigh, .max]
        case .grok:
            // Grok's `--reasoning-effort` ladder (the standard rungs; grok also
            // accepts none/minimal, which have no AgentEffort case).
            return [.low, .medium, .high, .xhigh, .max]
        case .codex:
            let models = CodexCLIService.listedModels
            let picked = modelID.flatMap { id in models.first { $0.id == id } }
                ?? models.first(where: \.isDefault) ?? models.first
            guard let picked else { return [.low, .medium, .high] }
            return picked.efforts.compactMap(AgentEffort.init)
        }
    }
}

/// One step in an agent run's work trail: a tool call the agent made — the
/// input line ("$ npm test", "Editing Foo.swift", "Searching …") plus, once the tool's
/// result event lands, its output. Narration the agent emits between tool calls
/// is an entry too (`mono == false`). Feeds the task card's expandable detail
/// view; the one-line `activity` ticker stays the collapsed summary.
struct AgentLogEntry: Identifiable, Equatable, Codable {
    let id: UUID
    /// The input side: command / file / query / narration text. Capped at parse.
    let title: String
    /// Terminal-ish entries (commands, files, queries) render monospaced;
    /// narration reads as prose.
    let mono: Bool
    /// The output side, attached when the tool's result arrives. Capped at parse.
    var detail: String? = nil
}

extension Array where Element == AgentLogEntry {
    /// The work trail with its trailing narration entry dropped when that entry
    /// only repeats the `answer` rendered directly beneath it.
    ///
    /// The agent's final assistant message is captured twice by design: the stream
    /// parser can't tell mid-run which text block is the last, so every narration
    /// block becomes a trail entry AND the last one also becomes the round's answer
    /// (`finalMessage`). Any view that stacks the trail above the answer therefore
    /// printed the report twice (the "回答内容重复展示"). Drop it here, where both
    /// halves are known. Only a non-mono (narration) tail entry is eligible — a tool
    /// row (`mono`) is never the answer — and only when the answer begins with its
    /// (prefix-capped, whitespace-trimmed) title. Pass an empty `answer` (e.g. while
    /// the round still streams and no report shows yet) to keep the trail whole.
    func droppingTrailingAnswer(_ answer: String) -> [AgentLogEntry] {
        guard let last, !last.mono else { return self }
        let title = last.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !body.isEmpty, body.hasPrefix(title) else { return self }
        return Array(dropLast())
    }
}

/// Runs a **agent implementation task**: the user picks a folder, describes a
/// task, and a local agent CLI (Codex or Claude Code — `AgentEngine`) works
/// *in that folder* — reading and writing files — until it's done, then reports
/// its result back (XII: agent-to-Codex).
///
/// This is deliberately a different animal from `CodexCLIService` (the chat
/// backend), even though both shell out to the same `codex` binary:
///  · **write access** — the chat runs `-s read-only` in a throwaway temp dir; a
///    agent task runs `-s workspace-write -C <folder>` so Codex can actually
///    implement things in the user's project. (Network stays off inside the
///    sandbox — codex's own workspace-write default — so an unattended task can't
///    reach out; it can still read/write every file under the folder.)
///  · **lifetime** — a chat turn is seconds and dies with the panel; an agent
///    task is minutes and must survive the panel closing, so the process is owned
///    by this singleton, not by a view's stream. Closing the notch never cancels
///    it — and neither does quitting the app: the CLI's output goes to a file,
///    not a pipe, so the run keeps working unattended and the next launch
///    re-attaches to it (`recoverInterruptedRuns`).
///  · **user config** — the chat isolates itself (`--ignore-user-config`) for a
///    fast predictable answer; an agent task *honors* the user's own codex
///    setup (model, reasoning effort, skills), because capability matters more
///    than latency here. The session is also persisted (no `--ephemeral`), so the
///    user can pick the run up later with `codex resume` in a terminal.
///
/// Tasks run in parallel — submitting while others are working just spawns
/// another process (same folder included, by explicit decision: the CLIs cope
/// the way they do in a terminal). Each run owns its own process, parser and
/// teardown; nothing is shared between runs. Progress (the current command /
/// file edit) streams into its task's `activity` for the in-panel card;
/// completion posts a native notification (the user has almost certainly
/// walked away from a minutes-long task) and the result stays in `tasks`
/// until dismissed.
@MainActor
final class AgentTaskManager: ObservableObject {
    static let shared = AgentTaskManager()

    /// Hard ceiling on a single agent run. Generous — real implementation
    /// tasks take minutes — but bounded, so a hung codex can't spin forever.
    private static let timeout: TimeInterval = 1800   // 30 min

    /// How a finished task ended.
    enum Outcome: Equatable { case success, failure, cancelled }

    /// One settled round of a task: the prompt that kicked it off and the
    /// answer it produced. A task accumulates one per follow-up — the full
    /// conversation `recordAgentHistory` files into Recent.
    struct AgentExchange: Equatable {
        let prompt: String
        let answer: String
        /// The images pasted into this round, parked in the history image store at
        /// spawn (filenames under `NotchModel.historyImagesDirectory`). They ride
        /// into the Recent row `recordAgentHistory` files, so a task whose whole
        /// description was a screenshot still reads as one when reopened.
        var imageFiles: [String] = []
        /// This round's slice of the work trail — the entries appended between
        /// the round's spawn and its settle. Rides the round into its history
        /// record, so a reopened run shows the same tool rows the live detail
        /// page did.
        var log: [AgentLogEntry] = []
    }

    /// One agent task, live or finished. The manager keeps every undismissed
    /// task in `tasks`, in spawn order.
    struct AgentTask: Equatable, Identifiable {
        /// Fresh per run — except on a resume, which revives an interrupted run
        /// under the id its Recent row already carries (see `resume`), so the row
        /// it settles back into is the same one, not a fork. (A `var` purely so
        /// the memberwise init can take it; nothing ever reassigns it.)
        var id = UUID()
        let engine: AgentEngine
        /// The model this run actually rides — the armed row's explicit pick to
        /// begin with, then overwritten by the id the CLI itself reports on its
        /// session event, so a run on the CLI-config default still names a
        /// concrete model in the detail's info line rather than "default".
        var modelID: String? = nil
        let folder: URL
        /// The task description the run STARTED with. Follow-up prompts live in
        /// `exchanges` (and in the work trail); this stays the card's headline.
        let prompt: String
        /// Reset on every round, so the elapsed clock (and "finished in …")
        /// times the round, not the whole conversation.
        var startedAt: Date
        /// The CLI's own conversation handle — claude's `session_id` (init
        /// event) / codex's `thread_id` (thread.started). Once known, the
        /// settled card grows a follow-up input that resumes this session.
        /// Re-captured every round: claude forks a NEW id on --resume.
        var sessionID: String? = nil
        /// Tokens occupying the model's context window after the latest turn
        /// (input + cache reads/creation), from the CLI's own usage events.
        var contextUsed: Int? = nil
        /// The window those tokens sit in, when the CLI reports it (claude's
        /// result event does; codex usually doesn't — absolute count only).
        var contextWindow: Int? = nil
        /// Every settled round so far, in order — the follow-up conversation.
        var exchanges: [AgentExchange] = []
        /// The latest activity line while running ("$ npm test", "Editing Foo.swift").
        var activity: String? = nil
        /// Distinct files codex reported changing, by name — the finished card's
        /// "N files changed" summary.
        var changedFiles: [String] = []
        /// The full work trail (every tool call + its output, in order) behind
        /// the one-line `activity` — the card's tap-to-expand detail. Capped at
        /// `logCap`; oldest entries fall off a marathon run.
        var log: [AgentLogEntry] = []
        var finishedAt: Date? = nil
        var outcome: Outcome? = nil          // nil while running
        /// Codex's final message — the reported result of the implementation.
        var result: String = ""
        /// The failure reason when `outcome == .failure`.
        var failureReason: String? = nil
        /// The armed row's original model/effort picks, replayed verbatim on
        /// every follow-up spawn (`modelID` gets overwritten by the id the CLI
        /// itself reports, which isn't necessarily a valid flag value to send
        /// back).
        var armedModel: String? = nil
        var armedEffort: AgentEffort? = nil
        /// True only for a task rebuilt by `recoverInterruptedRuns` — the app died
        /// mid-run. Its Recent row keeps the CLI session behind it, so the row can
        /// offer the in-app resume (`resume`) instead of only naming a terminal
        /// command. Cleared by definition once the resumed run settles normally.
        var interrupted = false

        var isRunning: Bool { outcome == nil }
        var elapsed: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }
    }

    /// Every live or finished-but-undismissed task, in spawn order.
    @Published private(set) var tasks: [AgentTask] = []

    /// Fired on the main actor when a run settles as success or failure (never
    /// cancel — the user just did that by hand). `AppDelegate` wires this to
    /// `NotchModel.recordAgentHistory`, which files the run into Recent so a
    /// dismissed card isn't the end of the record.
    var onSettled: ((AgentTask) -> Void)? = nil

    var isRunning: Bool { tasks.contains(where: \.isRunning) }
    var runningTasks: [AgentTask] { tasks.filter(\.isRunning) }

    /// The mutable bookkeeping behind ONE spawned round: its process handle,
    /// cancel flag, temp image files, and the prompt/images `settle` pairs into
    /// the round's exchange. Keyed by task id in `runs` — created at launch,
    /// discarded at settle — so parallel runs never share a slot.
    private final class RunState {
        var process: Process? = nil
        /// The spawned pid — kept beside `process` because a re-attached run
        /// (adopted from a previous app instance by `recoverInterruptedRuns`)
        /// has no `Process` handle: the pid is all it signals and watches.
        var pid: pid_t? = nil
        /// Wall clock at spawn. On recovery it's compared against the kernel's
        /// own start time for the pid, so a recycled pid can't impersonate the run.
        var spawnedAt: Date? = nil
        /// Tails the round's stdout log file (the CLI writes to a file, not a
        /// pipe — see `launch`), feeding the parser while the app is alive.
        var stdoutTailer: RunLogTailer? = nil
        /// Exit watch for a re-attached run — kqueue via a dispatch process
        /// source, because the process is not our child and has no
        /// termination handler.
        var exitWatch: DispatchSourceProcess? = nil
        /// Set by `cancel()` so the termination handler files the run as
        /// cancelled rather than failed.
        var cancelRequested = false
        /// The temp files the round's pasted images were written to for codex's
        /// `exec -i` — deleted when the run settles.
        var tempImageURLs: [URL] = []
        /// The prompt driving this round — the task description on round one,
        /// the follow-up text after.
        var currentPrompt = ""
        /// The round's images, as filenames in the history image store.
        var currentImageFiles: [String] = []
        /// Where in the task's work trail this round began — `settle` slices the
        /// round's own entries out with it (for the exchange's `log`). Walked
        /// back when the log cap trims the front of a marathon trail.
        var logStartIndex = 0
    }
    private var runs: [UUID: RunState] = [:]

    /// Follow-ups typed while the task's round was still in flight — the CLI
    /// can't take a new instruction mid-round, and dropping the line on the
    /// floor loses user input. Each queues here (its "› " marker joins the
    /// trail immediately) and `settle` dispatches them in order, one per
    /// settle, each as its own round in the same session. A cancel clears the
    /// task's queue: the user said stop, so nothing auto-restarts.
    private struct QueuedFollowUp { let prompt: String; let imagesJPEG: [Data] }
    private var pendingFollowUps: [UUID: [QueuedFollowUp]] = [:]

    private init() {}

    #if DEBUG
    /// TEMP debug: seed N settled agent cards so the immersive Recent list renders
    /// its agent status rows without a live CLI. Remove after diagnosing.
    func _debugSeedSettled(_ n: Int) {
        let engine = AgentEngine.available.first ?? .codex
        for i in 0..<n {
            var t = AgentTask(engine: engine,
                              folder: URL(fileURLWithPath: "/tmp/demo-project"),
                              prompt: "Demo agent task \(i + 1) — implement the thing",
                              startedAt: Date())
            t.finishedAt = Date()
            t.outcome = .success
            t.result = "done"
            t.exchanges = [.init(prompt: "Demo agent task \(i + 1)", answer: "done")]
            tasks.append(t)
        }
    }

    /// TEMP debug: seed one LIVE (running) card — a fixed activity line and a
    /// clock already minutes in — so the running status row and the resting
    /// notch's busy ears can be screenshotted without a real CLI run. Never
    /// persisted (running tasks only archive on settle); a normal relaunch
    /// clears it. Used by the `NOTCH_DEMO_AGENT_RUN` env path in `AppDelegate`.
    func _debugSeedRunning(prompt: String, activity: String, elapsed: TimeInterval,
                           logLines: Int = 0) {
        let engine = AgentEngine.available.first ?? .codex
        var t = AgentTask(engine: engine,
                          folder: URL(fileURLWithPath: "/tmp/demo-project"),
                          prompt: prompt,
                          startedAt: Date().addingTimeInterval(-elapsed))
        t.activity = activity
        // Optional dense work trail (NOTCH_DEMO_AGENT_LOG=<n>) so the live
        // detail page can be exercised/screenshotted at realistic size — a
        // repeating prose → commands → edit pattern, some rows with output.
        if logLines > 0 {
            t.log = (0..<logLines).map { i in
                switch i % 6 {
                case 0: return AgentLogEntry(id: UUID(), title: "Looking at the failing test to understand the assertion before touching the implementation.", mono: false)
                case 1: return AgentLogEntry(id: UUID(), title: "$ swift test --filter NotchModelTests", mono: true,
                                             detail: "Test Suite 'NotchModelTests' passed.\n Executed 12 tests, with 0 failures.")
                case 2: return AgentLogEntry(id: UUID(), title: "Read NotchModel.swift", mono: true)
                case 3: return AgentLogEntry(id: UUID(), title: "Editing NotchModel.swift", mono: true)
                case 4: return AgentLogEntry(id: UUID(), title: "$ git diff --stat", mono: true,
                                             detail: " NotchModel.swift | 24 ++++++++-----\n 1 file changed")
                default: return AgentLogEntry(id: UUID(), title: "Searching hover collapse", mono: true)
                }
            }
        }
        tasks.append(t)
    }
    #endif

    private func taskIndex(_ id: UUID) -> Int? {
        tasks.firstIndex { $0.id == id }
    }

    /// Kick off an agent run on `engine`. Runs in parallel with anything
    /// already working — each submit is its own process. No-op only when the
    /// engine's binary/sign-in is missing (the entry button is gated on
    /// availability, so this is belt-and-braces). `model` / `effort` are the
    /// armed row's explicit picks; nil leaves the CLI on its own config.
    /// `imagesJPEG` are the pasted images riding the task (already downsampled +
    /// JPEG-encoded off-main): codex attaches them natively (one `-i <file>` per
    /// image); claude has no image flag, so the prompt goes in as a stream-json
    /// user message carrying base64 vision blocks instead of plain stdin text.
    func start(folder: URL, prompt: String, engine: AgentEngine,
               model: String? = nil, effort: AgentEffort? = nil,
               imagesJPEG: [Data] = []) {
        guard let binary = Self.binary(for: engine) else {
            // The entry button is availability-gated, so a missing binary or
            // sign-in here means the user pressed ⏎ and nothing happened —
            // worth a breadcrumb (metadata only, never the prompt).
            DiagnosticsLog.shared.record(provider: "Agent/\(engine.displayName)",
                                         kind: "agent-binary-missing")
            return
        }

        let t = AgentTask(engine: engine, modelID: model, folder: folder,
                          prompt: prompt, startedAt: Date(),
                          armedModel: model, armedEffort: effort)
        tasks.append(t)
        launch(taskID: t.id, binary: binary, engine: engine, folder: folder,
               prompt: prompt, model: model, effort: effort,
               imagesJPEG: imagesJPEG, resumeSession: nil)
    }

    /// Continue a settled task in the same CLI session — the multi-turn path.
    /// Spawns a fresh process with the engine's resume flag pointed at the
    /// session the first round persisted; the same task revives as running and
    /// its work trail carries on. A follow-up sent while the task is still
    /// running is never dropped: it queues, and `settle` dispatches it as the
    /// next round the moment the current one ends. `imagesJPEG` are images
    /// pasted into the follow-up field — they ride the round exactly like
    /// round one's (codex `exec resume -i`; claude's stream-json vision blocks
    /// work the same under `--resume`).
    func followUp(taskID: UUID, prompt: String, imagesJPEG: [Data] = []) {
        guard let i = taskIndex(taskID) else {
            DiagnosticsLog.shared.record(provider: "Agent", kind: "agent-followup-dropped")
            return
        }
        if tasks[i].isRunning {
            // Mid-round: the CLI can't take a new instruction while a round is
            // in flight, so the line queues for the next one. Its marker joins
            // the trail right away, so the user sees the instruction landed.
            pendingFollowUps[taskID, default: []].append(
                QueuedFollowUp(prompt: prompt, imagesJPEG: imagesJPEG))
            tasks[i].log.append(AgentLogEntry(id: UUID(), title: "› " + prompt,
                                              mono: false))
            return
        }
        beginFollowUpRound(index: i, prompt: prompt, imagesJPEG: imagesJPEG,
                           appendMarker: true)
    }

    /// The spawn half of `followUp`: revive the settled task as running and
    /// launch the round against its persisted session. `appendMarker` is false
    /// on a queued dispatch — that line's marker already joined the trail at
    /// queue time. No-op (with breadcrumb) when the task never got far enough
    /// to report a session id — nothing to resume, ever — in which case any
    /// queued lines are cleared too, since no future settle will dispatch them.
    private func beginFollowUpRound(index i: Int, prompt: String,
                                    imagesJPEG: [Data], appendMarker: Bool) {
        var t = tasks[i]
        guard let session = t.sessionID, let binary = Self.binary(for: t.engine) else {
            // Round one never reported a session id, or the engine's
            // binary/sign-in vanished since. Breadcrumb, metadata only.
            DiagnosticsLog.shared.record(provider: "Agent/\(t.engine.displayName)",
                                         kind: t.sessionID == nil
                                            ? "agent-followup-dropped" : "agent-binary-missing")
            pendingFollowUps[t.id] = nil
            return
        }

        t.outcome = nil
        t.finishedAt = nil
        t.startedAt = Date()
        t.result = ""
        t.failureReason = nil
        t.activity = nil
        // The follow-up joins the work trail where it happened, so the
        // transcript reads as one conversation.
        if appendMarker {
            t.log.append(AgentLogEntry(id: UUID(), title: "› " + prompt, mono: false))
        }
        tasks[i] = t
        launch(taskID: t.id, binary: binary, engine: t.engine, folder: t.folder,
               prompt: prompt, model: t.armedModel, effort: t.armedEffort,
               imagesJPEG: imagesJPEG, resumeSession: session)
    }

    /// Pick an interrupted run back up in-app — the GUI half of `resumeCommand`.
    /// The app died mid-run; the CLI's session survived on disk, so this rebuilds
    /// the task around it and re-issues the round that never finished. `taskID` is
    /// the id of the Recent row the run left behind, so the row it settles back
    /// into REPLACES that one (same id → `recordAgentHistory` overwrites in place)
    /// rather than forking a second copy of the same conversation.
    ///
    /// No model/effort flags: the armed picks didn't survive the quit, and a
    /// resumed session already carries its own model — passing none leaves the
    /// engine on exactly what it was running. No-op if that task is somehow live.
    func resume(taskID: UUID, engine: AgentEngine, folder: URL, headline: String,
                session: String, priorRounds: [AgentExchange], prompt: String,
                imagesJPEG: [Data] = []) {
        guard taskIndex(taskID) == nil, let binary = Self.binary(for: engine) else {
            // The row's resume button is gated on the engine being installed, so
            // landing here means the tap silently did nothing. Breadcrumb only.
            DiagnosticsLog.shared.record(provider: "Agent/\(engine.displayName)",
                                         kind: "agent-resume-dropped")
            return
        }
        var t = AgentTask(id: taskID, engine: engine, folder: folder,
                          prompt: headline, startedAt: Date())
        t.sessionID = session
        t.exchanges = priorRounds
        // The re-issued round opens the trail where the interruption cut it off.
        t.log.append(AgentLogEntry(id: UUID(), title: "› " + prompt, mono: false))
        tasks.append(t)
        launch(taskID: taskID, binary: binary, engine: engine, folder: folder,
               prompt: prompt, model: nil, effort: nil,
               imagesJPEG: imagesJPEG, resumeSession: session)
    }

    /// The engine's resolved binary, gated on its sign-in — nil means "can't run".
    private static func binary(for engine: AgentEngine) -> String? {
        switch engine {
        case .codex:  return CodexCLIService.authExists() ? CodexCLIService.resolveBinary() : nil
        case .claude: return ClaudeCLIService.authExists() ? ClaudeCLIService.resolveBinary() : nil
        case .grok:   return GrokCLIService.authExists() ? GrokCLIService.resolveBinary() : nil
        }
    }

    /// The event parser for an engine's JSONL dialect.
    private static func makeParser(for engine: AgentEngine) -> AgentEventParser {
        switch engine {
        case .codex:  return CodexAgentStreamState()
        case .claude: return ClaudeAgentStreamState()
        case .grok:   return GrokAgentStreamState()
        }
    }

    /// The user-facing "couldn't start the CLI" reason for an engine.
    private static func spawnFailureReason(_ engine: AgentEngine, _ detail: String) -> String? {
        switch engine {
        case .codex:  return CodexError.spawnFailed(detail).errorDescription
        case .claude: return ClaudeCodeError.spawnFailed(detail).errorDescription
        case .grok:   return GrokError.spawnFailed(detail).errorDescription
        }
    }

    /// Spawn one round's process — the shared tail of `start` (fresh session)
    /// and `followUp` (`resumeSession` != nil). Each call owns a fresh
    /// `RunState`, so parallel rounds never trample each other's bookkeeping.
    private func launch(taskID: UUID, binary: String, engine: AgentEngine, folder: URL,
                        prompt: String, model: String?, effort: AgentEffort?,
                        imagesJPEG: [Data], resumeSession: String?) {
        let run = RunState()
        runs[taskID] = run
        run.currentPrompt = prompt
        // The round's trail starts where the task's log stands now (any follow-up
        // marker already appended stays with the PREVIOUS round's tail, not this
        // round's slice — the prompt becomes the record's own user turn instead).
        run.logStartIndex = taskIndex(taskID).map { tasks[$0].log.count } ?? 0
        // Keep a copy of the round's images beside the archive, so the Recent row
        // this run settles into can show what it was handed. Same already-downsampled
        // JPEGs that go to the CLI — a couple hundred KB each, written once per spawn.
        run.currentImageFiles = imagesJPEG.compactMap { NotchModel.storeHistoryImage($0) }

        // A model flag rides only on an explicit pick from the armed row's menu
        // (`model != nil`); the default stays flag-less so the run honors the
        // user's OWN CLI configuration — a stale pinned id 404s the whole run
        // ("Model not found gpt-5.6-luna"), while the config default is what
        // the user's own CLI demonstrably runs.
        var args: [String]
        switch engine {
        case .codex:
            // Sandboxed workspace-write: can edit anything under the folder and
            // run commands inside codex's sandbox; network stays off (codex's own
            // workspace-write default). A follow-up rides `exec resume <id>`
            // instead of a fresh `exec` — same options, and the explicit `-`
            // prompt positional keeps the prompt on stdin like round one.
            args = resumeSession.map { ["exec", "resume", $0, "-"] } ?? ["exec"]
            args += ["--json", "--skip-git-repo-check", "--color", "never",
                     "-s", "workspace-write", "-C", folder.path]
            if let model { args += ["-m", model] }
            if let effort {
                args += ["-c", "model_reasoning_effort=\(effort.rawValue)"]
            }
            // Pasted images attach via codex's own flag. They need real files:
            // written to the temp dir (NOT the project folder — the run must
            // never plant artifacts in the user's repo), deleted on settle.
            // One `-i` per image is the only form BOTH paths take: `exec`'s
            // `-i` is variadic, but `exec resume`'s takes a single value per
            // occurrence, so `-i a.jpg b.jpg` is a parse error there.
            for jpeg in imagesJPEG {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("notch-agent-\(UUID().uuidString).jpg")
                if (try? jpeg.write(to: url)) != nil {
                    args += ["-i", url.path]
                    run.tempImageURLs.append(url)
                }
            }
        case .claude:
            // acceptEdits auto-approves file edits under the project (the cwd),
            // and Bash/web are pre-authorized so builds/tests/doc-lookups run
            // unattended — anything else falls to acceptEdits' auto-deny rather
            // than hanging on a prompt no one will answer. Explicit on purpose:
            // a bare spawn would inherit whatever permission defaultMode the
            // user's settings.json happens to have. Deliberately NOT --safe-mode
            // (the user's CLAUDE.md/skills are assets for implementation work)
            // and NOT --no-session-persistence (the session should be resumable
            // from a terminal with `claude --resume`, same as codex's).
            args = ["-p", "--verbose", "--output-format", "stream-json",
                    "--permission-mode", "acceptEdits",
                    "--allowedTools", "Bash,WebSearch,WebFetch"]
            // A follow-up resumes the persisted session (that's why the agent
            // path never passes --no-session-persistence). Flags don't carry
            // over from the resumed session, so everything above rides again.
            if let resumeSession { args += ["--resume", resumeSession] }
            if let model { args += ["--model", model] }
            // Same knob as Codex's, via the CLI's own flag (`--effort
            // low|medium|high|xhigh|max`).
            if let effort { args += ["--effort", effort.rawValue] }
            // With pasted images, stdin switches from plain text to one
            // stream-json user message carrying text + base64 vision blocks —
            // the CLI's only image route (there is no `-i` equivalent). The
            // output dialect is stream-json either way, so parsing is untouched.
            if !imagesJPEG.isEmpty { args += ["--input-format", "stream-json"] }
        case .grok:
            // Grok headless needs the prompt via --prompt-file: bare stdin
            // errors "Device not configured (os error 6)", and `-p` would merge
            // the stdin the shared writer sends (double prompt) — but
            // --prompt-file is authoritative and ignores stdin (verified). The
            // prompt file rides `tempImageURLs` so it's cleaned up on settle.
            // --always-approve lets file edits / shell run unattended (the twin
            // of codex's workspace-write and claude's acceptEdits); --no-plan
            // stops it pausing on a plan no one will approve. NOT sandboxed
            // (grok's sandbox profiles aren't wired) — parity with the Claude
            // engine, which likewise runs Bash unconfined. Session persists, so
            // a follow-up rides `--resume <id>` (id parsed from the `end` event).
            let promptURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("notch-grok-prompt-\(UUID().uuidString).txt")
            try? Data(prompt.utf8).write(to: promptURL)
            run.tempImageURLs.append(promptURL)
            args = ["--prompt-file", promptURL.path,
                    "--output-format", "streaming-json",
                    "--always-approve", "--no-plan", "--no-memory", "--no-subagents",
                    "--no-auto-update", "--cwd", folder.path]
            if let resumeSession { args += ["--resume", resumeSession] }
            if let model { args += ["-m", model] }
            if let effort { args += ["--reasoning-effort", effort.rawValue] }
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        p.currentDirectoryURL = folder
        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        ProxyConfig.apply(to: &env)
        env["DISABLE_AUTOUPDATER"] = "1"
        p.environment = env

        // stdout/stderr go to FILES, not pipes — deliberately. A pipe ties the
        // CLI to this process: quit the app mid-run and the orphaned CLI dies
        // of SIGPIPE at its next write. A file keeps the CLI self-sufficient,
        // so the run outlives the app that spawned it; the app streams
        // progress by tailing the file instead, and after a relaunch
        // `recoverInterruptedRuns` re-attaches to the live process (or
        // harvests the result a finished one left behind). stdin stays a
        // pipe: the prompt is written and closed within seconds of the spawn.
        let inPipe = Pipe()
        p.standardInput = inPipe
        let outURL = Self.stdoutLogURL(taskID: taskID)
        let errURL = Self.stderrLogURL(taskID: taskID)
        try? FileManager.default.createDirectory(at: Self.runLogsDirectory,
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        guard let outWrite = try? FileHandle(forWritingTo: outURL),
              let errWrite = try? FileHandle(forWritingTo: errURL) else {
            // No log files means no redirect, no recovery record and no output
            // parse — don't spawn a run we'd be blind to.
            let reason = Self.spawnFailureReason(engine, "run log unavailable")
            settle(taskID: taskID,
                   snapshot: AgentSnapshot(finalMessage: "", failure: reason,
                                           stderrTail: "", sawTerminal: false),
                   exitStatus: 1)
            return
        }
        p.standardOutput = outWrite
        p.standardError = errWrite

        let state: AgentEventParser = Self.makeParser(for: engine)

        // Progress streams off the growing log file — push became poll: the
        // pipe's readability handler used to feed these bytes; a quarter-second
        // tail tick now reads the same bytes through the same parser.
        let tailer = RunLogTailer(url: outURL) { [weak self] data in
            if let update = state.ingest(data) {
                Task { @MainActor in
                    self?.applyProgress(update, for: taskID)
                }
            }
        }

        // Watchdog: terminate a runaway run; cancelled on clean exit.
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: watchdog)

        p.terminationHandler = { [weak self] proc in
            watchdog.cancel()
            // Once the process exited, everything it wrote is in the file —
            // there is no kernel pipe buffer to race (the old TeardownLatch's
            // whole job). One final drain picks up the tail, result event
            // included; stderr rides in for the failure tail.
            tailer.finishAndDrain()
            Self.appendStderrFile(errURL, to: state)
            let status = proc.terminationStatus
            let snapshot = state.finish()
            Task { @MainActor in
                self?.settle(taskID: taskID, snapshot: snapshot, exitStatus: status)
            }
        }

        do {
            try p.run()
        } catch {
            tailer.finishAndDrain()
            try? outWrite.close()
            try? errWrite.close()
            // A run that never launched settles like any other failure — same
            // exchange, same Recent row. Hand-rolling the outcome here (as this
            // used to) skipped `onSettled`, so a spawn failure left no record
            // at all once its card was dismissed.
            let reason = Self.spawnFailureReason(engine, error.localizedDescription)
            settle(taskID: taskID,
                   snapshot: AgentSnapshot(finalMessage: "", failure: reason,
                                           stderrTail: "", sawTerminal: false),
                   exitStatus: 1)
            return
        }
        // The child holds its own dups of the log descriptors now; the
        // parent's copies would only leak.
        try? outWrite.close()
        try? errWrite.close()
        run.process = p
        run.pid = p.processIdentifier
        run.spawnedAt = Date()
        run.stdoutTailer = tailer
        // Remember the run is in flight — WITH its pid — so a quit/crash
        // mid-run re-attaches to the still-running process on the next launch
        // instead of writing the run off.
        Self.saveInFlight(task: tasks.first { $0.id == taskID }, currentPrompt: prompt,
                          pid: run.pid, spawnedAt: run.spawnedAt,
                          imageFiles: run.currentImageFiles)

        // The task description goes in on stdin (no arg ⇒ stdin is the prompt),
        // then the pipe closes so the agent starts working. Claude-with-images is
        // the one shape that differs: `--input-format stream-json` above means
        // stdin must be a JSONL user message, with the pasted images riding as
        // base64 vision blocks next to the task text.
        //
        // Written OFF the main thread: the payload can exceed the pipe buffer
        // (one base64 screenshot easily does), and the write then blocks until
        // the CLI drains it. The throwing `write(contentsOf:)` also turns a
        // broken pipe (a CLI that died on startup) into an ignorable error —
        // the legacy `write(_:)` raised an ObjC exception there, which took the
        // whole app down; the run's failure is already reported via settle.
        let writer = inPipe.fileHandleForWriting
        let isClaude = engine == .claude
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? writer.close() }
            let payload: Data
            if isClaude, !imagesJPEG.isEmpty {
                // Images lead and the task text closes — the order Anthropic's own
                // vision guidance recommends. Past one image, each gets an "Image N:"
                // label so the prompt (and every follow-up) can refer to them by name.
                var content: [[String: Any]] = []
                for (i, jpeg) in imagesJPEG.enumerated() {
                    if imagesJPEG.count > 1 {
                        content.append(["type": "text", "text": "Image \(i + 1):"])
                    }
                    content.append(["type": "image",
                                    "source": ["type": "base64",
                                               "media_type": "image/jpeg",
                                               "data": jpeg.base64EncodedString()]])
                }
                content.append(["type": "text", "text": prompt])
                let message: [String: Any] = [
                    "type": "user",
                    "message": ["role": "user", "content": content],
                ]
                guard var line = try? JSONSerialization.data(withJSONObject: message)
                else { return }
                line.append(Data("\n".utf8))
                payload = line
            } else {
                payload = Data(prompt.utf8)
            }
            try? writer.write(contentsOf: payload)
        }
    }

    /// Stop one running task. The termination handler files it as cancelled.
    func cancel(taskID: UUID) {
        guard let run = runs[taskID],
              tasks.first(where: { $0.id == taskID })?.isRunning == true else { return }
        run.cancelRequested = true
        if let p = run.process {
            p.terminate()
        } else if let pid = run.pid {
            // A re-attached run has no Process handle — signal the pid
            // directly; its exit watch files the cancel.
            kill(pid, SIGTERM)
        }
    }

    /// Dismiss one finished task's card. Never clears a running task. Any
    /// follow-ups still queued go with it — their task can no longer settle.
    func dismissFinished(taskID: UUID) {
        guard let i = taskIndex(taskID), !tasks[i].isRunning else { return }
        tasks.remove(at: i)
        pendingFollowUps[taskID] = nil
    }

    /// Reveal a task's folder in Finder — the finished card's "Open Folder".
    func openFolder(taskID: UUID) {
        guard let folder = tasks.first(where: { $0.id == taskID })?.folder else { return }
        NSWorkspace.shared.open(folder)
    }

    // MARK: - Surviving an abnormal exit

    /// A run that was still in flight, remembered on disk. The live task lives
    /// only in memory and history is written when the run *settles* — so a quit,
    /// a crash, or a kill mid-run used to erase the run entirely: no card, no
    /// Recent row, nothing but the CLI's own session on disk. This marker is
    /// written when the process spawns and cleared when it settles; anything
    /// still there at launch is by definition a run that never got to settle.
    /// (Since the reliability pass, "settle" here means *filed to disk*: the
    /// marker outlives settle itself and is cleared by `recordAgentHistory`
    /// only after the run's history row is written.)
    private struct InFlightRun: Codable {
        struct Round: Codable { let prompt: String; let answer: String }
        let engine: String
        let folderPath: String
        /// The task description the run started with (the headline).
        let prompt: String
        /// The prompt of the round that was actually interrupted — the task
        /// description on round one, the follow-up text after.
        let currentPrompt: String
        let startedAt: Date
        /// Rounds that had already settled before the interruption.
        let rounds: [Round]
        /// The CLI's own conversation handle, when the round got far enough to
        /// report one — the run is resumable from a terminal with it.
        let sessionID: String?
        // v2 (runs survive the app): identify the possibly-still-running
        // process, and carry the round's pasted images. All optional so a
        // marker written by an older build still decodes (it just can't
        // re-attach — its process died with its pipes anyway).
        /// The spawned process, for the relaunch to find again.
        let pid: Int32?
        /// Wall clock at spawn — matched against the kernel's start time for
        /// `pid` on recovery, so a recycled pid can't impersonate the run.
        let processStartedAt: Date?
        /// This round's images (filenames in the history image store), so a
        /// recovered exchange keeps its screenshots.
        let currentImageFiles: [String]?
    }

    /// Each parallel run writes its own marker under `<prefix>_<task-uuid>`.
    /// The bare prefix is also the pre-parallel single-slot key — recovery
    /// consumes it too, so an update never loses a run that was in flight.
    private nonisolated static let inFlightKeyPrefix = "notch_agent_inflight"

    // Pure string assembly — nonisolated so `clearInFlight` (called off-main
    // from the archive write's completion) can build the key too.
    private nonisolated static func inFlightKey(_ taskID: UUID) -> String {
        inFlightKeyPrefix + "_" + taskID.uuidString
    }

    private static func saveInFlight(task: AgentTask?, currentPrompt: String,
                                     pid: Int32?, spawnedAt: Date?,
                                     imageFiles: [String]) {
        guard let t = task else { return }
        let run = InFlightRun(
            engine: t.engine.rawValue,
            folderPath: t.folder.path,
            prompt: t.prompt,
            currentPrompt: currentPrompt,
            startedAt: t.startedAt,
            rounds: t.exchanges.map { .init(prompt: $0.prompt, answer: $0.answer) },
            sessionID: t.sessionID,
            pid: pid,
            processStartedAt: spawnedAt,
            currentImageFiles: imageFiles.isEmpty ? nil : imageFiles)
        guard let data = try? JSONEncoder().encode(run) else { return }
        UserDefaults.standard.set(data, forKey: inFlightKey(t.id))
    }

    /// Cleared only when the settled run's history row is on disk (see
    /// `NotchModel.recordAgentHistory`) — or consumed by launch recovery.
    /// The run's log files go with it: once the row is filed, the bytes are done.
    /// `nonisolated` so the archive write's completion can call it off-main;
    /// UserDefaults is thread-safe.
    nonisolated static func clearInFlight(taskID: UUID) {
        UserDefaults.standard.removeObject(forKey: inFlightKey(taskID))
        removeRunLogs(taskID: taskID)
    }

    /// Re-record the session id once the CLI reports it, so a run interrupted
    /// mid-flight still names a resumable session in its Recent row.
    private func refreshInFlight(_ t: AgentTask) {
        let run = runs[t.id]
        Self.saveInFlight(task: t, currentPrompt: run?.currentPrompt ?? t.prompt,
                          pid: run?.pid, spawnedAt: run?.spawnedAt,
                          imageFiles: run?.currentImageFiles ?? [])
    }

    /// What the runs that were in flight when the app last went away come back
    /// as — empty if the last exit was clean. Consumes the markers: called
    /// once, at launch, by `AppDelegate`. Also swallows the pre-parallel
    /// single-slot key. Three legs, in order of how much survived:
    ///
    ///  1. the **process is still alive** (the whole point of the file
    ///     redirect) → re-adopted in place: its task rejoins `tasks` as
    ///     running, the stdout log replays into the card, and the run settles
    ///     normally when the process exits. Not in the return value.
    ///  2. the process **finished while the app was away** (its log ends with
    ///     the stream's own terminal event) → returned as a normal
    ///     success/failure task, with the completion notification the user
    ///     never got.
    ///  3. the process **died mid-run** (killed, crashed, or an old marker
    ///     from before the redirect) → the historical interrupted row,
    ///     resumable via its session id.
    func recoverInterruptedRuns() -> [AgentTask] {
        let defaults = UserDefaults.standard
        var markers: [(taskID: UUID, marker: InFlightRun)] = []
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(Self.inFlightKeyPrefix) {
            if let data = defaults.data(forKey: key),
               let run = try? JSONDecoder().decode(InFlightRun.self, from: data) {
                // The marker key carries the task id — keeping it means the run
                // settles back into the SAME Recent row across any number of
                // app restarts. (A pre-parallel single-slot key gets a fresh one.)
                let suffix = String(key.dropFirst(Self.inFlightKeyPrefix.count + 1))
                markers.append((UUID(uuidString: suffix) ?? UUID(), run))
            }
            defaults.removeObject(forKey: key)
        }

        var settled: [AgentTask] = []
        var adopted: Set<UUID> = []
        for (taskID, marker) in markers {
            guard let engine = AgentEngine(rawValue: marker.engine) else { continue }

            // Leg 1 — alive: same pid AND same kernel start time (a recycled
            // pid fails the second check).
            if let pid = marker.pid, let spawnedAt = marker.processStartedAt,
               let kernelStart = Self.processStartTime(pid: pid_t(pid)),
               abs(kernelStart.timeIntervalSince(spawnedAt)) < 15 {
                reattach(taskID: taskID, marker: marker, engine: engine, pid: pid_t(pid))
                adopted.insert(taskID)
                continue
            }

            // Leg 2 — finished while away: harvest the log's result.
            if let done = settleFromLog(taskID: taskID, marker: marker, engine: engine) {
                DiagnosticsLog.shared.record(provider: "Agent/\(engine.displayName)",
                                             kind: "agent-recovered-finished")
                NotificationService.shared.postAgentFinished(
                    engineName: engine.displayName,
                    folderName: URL(fileURLWithPath: marker.folderPath).lastPathComponent,
                    success: done.outcome == .success,
                    threadID: done.id)
                settled.append(done)
                continue
            }

            // Leg 3 — gone: the interrupted row.
            settled.append(Self.interruptedTask(taskID: taskID, marker: marker,
                                                engine: engine))
        }

        // Sweep every log a re-attached run doesn't own — harvested,
        // interrupted and orphaned files alike (their rows are filed or moot;
        // the bytes are done).
        if let files = try? FileManager.default.contentsOfDirectory(
            at: Self.runLogsDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                let stem = file.deletingPathExtension().deletingPathExtension()
                    .lastPathComponent
                if let id = UUID(uuidString: stem), adopted.contains(id) { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
        return settled
    }

    /// Adopt a run whose process outlived the previous app instance: rebuild
    /// its live task, replay the stdout log from the top through a fresh
    /// parser (work trail, session id, model and context gauge all come
    /// back), keep tailing the file, and watch the pid for exit. From the
    /// outside it's the same run, still going.
    private func reattach(taskID: UUID, marker: InFlightRun,
                          engine: AgentEngine, pid: pid_t) {
        var t = AgentTask(id: taskID, engine: engine,
                          folder: URL(fileURLWithPath: marker.folderPath),
                          prompt: marker.prompt, startedAt: marker.startedAt)
        t.sessionID = marker.sessionID
        t.exchanges = marker.rounds.map { .init(prompt: $0.prompt, answer: $0.answer) }
        // A follow-up round reopens the trail where its prompt did originally.
        if !t.exchanges.isEmpty {
            t.log.append(AgentLogEntry(id: UUID(), title: "› " + marker.currentPrompt,
                                       mono: false))
        }
        tasks.append(t)

        let run = RunState()
        run.currentPrompt = marker.currentPrompt
        run.currentImageFiles = marker.currentImageFiles ?? []
        run.pid = pid
        run.spawnedAt = marker.processStartedAt
        runs[taskID] = run
        // Re-arm the marker this recovery just consumed — the run can outlive
        // THIS app instance too.
        Self.saveInFlight(task: t, currentPrompt: marker.currentPrompt,
                          pid: Int32(pid), spawnedAt: run.spawnedAt,
                          imageFiles: run.currentImageFiles)

        let state: AgentEventParser = Self.makeParser(for: engine)
        let outURL = Self.stdoutLogURL(taskID: taskID)
        let errURL = Self.stderrLogURL(taskID: taskID)
        // The tailer starts at offset zero, so its first tick replays
        // everything the run streamed before the app went away — the card
        // comes back mid-sentence.
        let tailer = RunLogTailer(url: outURL) { [weak self] data in
            if let update = state.ingest(data) {
                Task { @MainActor in
                    self?.applyProgress(update, for: taskID)
                }
            }
        }
        run.stdoutTailer = tailer

        // What's left of the runaway ceiling still applies, measured from the
        // round's original start.
        let elapsed = Date().timeIntervalSince(marker.startedAt)
        let watchdog = DispatchWorkItem { kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(30, Self.timeout - elapsed),
                                          execute: watchdog)

        // Exit detection for a process that is NOT our child: kqueue via a
        // dispatch process source. No exit status crosses it (launchd reaps
        // the orphan), so the stream's own terminal event stands in — reached
        // it = the CLI concluded; short of it = the run died out from under
        // us → files as interrupted (resumable), same as a death with the app.
        let once = OnceFlag()
        let finishUp: () -> Void = { [weak self] in
            guard once.tryFire() else { return }
            watchdog.cancel()
            tailer.finishAndDrain()
            Self.appendStderrFile(errURL, to: state)
            let snapshot = state.finish()
            Task { @MainActor in
                self?.settle(taskID: taskID, snapshot: snapshot,
                             exitStatus: snapshot.sawTerminal ? 0 : 1,
                             interrupted: !snapshot.sawTerminal)
            }
        }
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit,
                                                   queue: .global())
        src.setEventHandler { [weak src] in
            src?.cancel()
            finishUp()
        }
        run.exitWatch = src
        src.resume()
        // The pid could have exited in the beat between the liveness probe and
        // the source registration — in which case the source never fires.
        // Re-probe; `once` keeps the two paths from double-settling.
        if Self.processStartTime(pid: pid) == nil {
            src.cancel()
            finishUp()
        }

        DiagnosticsLog.shared.record(provider: "Agent/\(engine.displayName)",
                                     kind: "agent-reattached")
    }

    /// Harvest a run whose process finished while the app was away: parse the
    /// full stdout log; only a stream that reached its own terminal event
    /// (claude's `result`, codex's `turn.completed`/`turn.failed`) counts as
    /// finished — anything short of that returns nil and files as interrupted
    /// instead.
    private func settleFromLog(taskID: UUID, marker: InFlightRun,
                               engine: AgentEngine) -> AgentTask? {
        let outURL = Self.stdoutLogURL(taskID: taskID)
        guard let data = try? Data(contentsOf: outURL), !data.isEmpty else { return nil }
        let state: AgentEventParser = Self.makeParser(for: engine)
        let progress = state.ingest(data)
        Self.appendStderrFile(Self.stderrLogURL(taskID: taskID), to: state)
        let snapshot = state.finish()
        guard snapshot.sawTerminal else { return nil }

        var t = AgentTask(id: taskID, engine: engine,
                          folder: URL(fileURLWithPath: marker.folderPath),
                          prompt: marker.prompt, startedAt: marker.startedAt)
        // The log is fresher than the marker: `--resume` forks a new session
        // id per round, and the marker only catches up when the app was still
        // around to see the init event.
        t.sessionID = progress?.sessionID ?? marker.sessionID
        t.modelID = progress?.model
        t.contextUsed = progress?.contextUsed
        t.contextWindow = progress?.contextWindow
        t.changedFiles = progress?.changedFiles ?? []
        t.exchanges = marker.rounds.map { .init(prompt: $0.prompt, answer: $0.answer) }
        // Finished when the log stopped growing, not when we found it — keeps
        // the "finished in …" line honest.
        let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path)
        t.finishedAt = attrs?[.modificationDate] as? Date ?? Date()
        t.result = snapshot.finalMessage
        if let failure = snapshot.failure {
            t.outcome = .failure
            t.failureReason = Self.friendlyFailure(failure, engine: engine)
        } else {
            t.outcome = .success
        }

        // Same answer text a live settle would have produced.
        let answer: String
        if t.outcome == .success {
            let body = snapshot.finalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            answer = body.isEmpty
                ? L("agent.done", engine.displayName,
                    NotchModel.formatAgentElapsed(t.elapsed))
                : body
        } else {
            let reason = (t.failureReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            answer = reason.isEmpty
                ? L("agent.failed", engine.displayName)
                : L("agent.failed", engine.displayName) + "\n" + reason
        }
        t.exchanges.append(AgentExchange(prompt: marker.currentPrompt, answer: answer,
                                         imageFiles: marker.currentImageFiles ?? []))
        return t
    }

    /// Claude's raw auth-failure strings ("OAuth session expired and could
    /// not be refreshed", …) tell the user nothing actionable — swap in the
    /// terminal `/login` guidance. Codex reasons pass through verbatim (its
    /// re-auth lives in-app, not in the terminal).
    nonisolated private static func friendlyFailure(_ reason: String,
                                                    engine: AgentEngine) -> String {
        if engine == .claude, ClaudeCodeError.isAuthFailure(reason) {
            return L("claudecode.error.authExpired")
        }
        if engine == .grok, GrokError.isAuthFailure(reason) {
            return L("grok.error.authExpired")
        }
        return reason
    }

    /// The last-resort recovery: nothing left of the run but its marker (and
    /// maybe a truncated log) — the historical interrupted row.
    private static func interruptedTask(taskID: UUID, marker: InFlightRun,
                                        engine: AgentEngine) -> AgentTask {
        var t = AgentTask(id: taskID, engine: engine,
                          folder: URL(fileURLWithPath: marker.folderPath),
                          prompt: marker.prompt,
                          startedAt: marker.startedAt)
        t.sessionID = marker.sessionID
        t.exchanges = marker.rounds.map { .init(prompt: $0.prompt, answer: $0.answer) }
        t.finishedAt = Date()
        t.outcome = .failure
        t.failureReason = L("agent.interrupted")
        t.interrupted = true
        // The interrupted round closes the thread with the one fact we have.
        // How to pick it back up is NOT baked into the answer text: the session
        // id rides the Recent row instead (`HistoryItem.agentResume`), where it
        // becomes a one-tap resume — and only degrades to the terminal command
        // when the engine itself has gone missing.
        t.exchanges.append(AgentExchange(prompt: marker.currentPrompt,
                                         answer: L("agent.interrupted"),
                                         imageFiles: marker.currentImageFiles ?? []))
        return t
    }

    // MARK: - Run log files & process probing

    /// Where each round's redirected stdout/stderr live. `<taskID>.out.jsonl`
    /// doubles as the recovery record: on relaunch it replays through the same
    /// parser as if the stream had never stopped.
    nonisolated private static var runLogsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first!
            .appendingPathComponent("Notch", isDirectory: true)
            .appendingPathComponent("AgentRunLogs", isDirectory: true)
    }

    nonisolated private static func stdoutLogURL(taskID: UUID) -> URL {
        runLogsDirectory.appendingPathComponent(taskID.uuidString + ".out.jsonl")
    }

    nonisolated private static func stderrLogURL(taskID: UUID) -> URL {
        runLogsDirectory.appendingPathComponent(taskID.uuidString + ".err.log")
    }

    nonisolated private static func removeRunLogs(taskID: UUID) {
        try? FileManager.default.removeItem(at: stdoutLogURL(taskID: taskID))
        try? FileManager.default.removeItem(at: stderrLogURL(taskID: taskID))
    }

    /// Feed a run's redirected stderr file to its parser at teardown — the
    /// live pipe handler this replaces streamed the same bytes. Capped: only
    /// the tail survives into the failure reason anyway.
    nonisolated private static func appendStderrFile(_ url: URL, to state: AgentEventParser) {
        guard var data = try? Data(contentsOf: url), !data.isEmpty else { return }
        if data.count > 65_536 {
            // Re-encode through a lossy decode so a suffix cut mid-character
            // can't fail the parser's strict UTF-8 read.
            data = Data(String(decoding: data.suffix(65_536), as: UTF8.self).utf8)
        }
        state.appendStderr(data)
    }

    /// The kernel's start time for `pid` — nil when no such process exists.
    /// The pair (pid, start time) identifies a process for good: a recycled
    /// pid can't match the original's start time.
    nonisolated private static func processStartTime(pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size > 0, info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec)
                    + TimeInterval(tv.tv_usec) / 1e6)
    }

    // MARK: - Internal state transitions

    /// Hard cap on the detail log — a marathon run keeps its newest trail, not
    /// an unbounded array of every command it ever ran.
    private static let logCap = 300

    private func applyProgress(_ update: AgentProgress, for taskID: UUID) {
        guard let i = taskIndex(taskID), tasks[i].isRunning else { return }
        var t = tasks[i]
        let newSession = update.sessionID != nil && update.sessionID != t.sessionID
        if let activity = update.activity { t.activity = activity }
        if let model = update.model { t.modelID = model }
        if let session = update.sessionID { t.sessionID = session }
        if let used = update.contextUsed { t.contextUsed = used }
        if let window = update.contextWindow { t.contextWindow = window }
        for file in update.changedFiles where !t.changedFiles.contains(file) {
            t.changedFiles.append(file)
        }
        if !update.entries.isEmpty {
            t.log.append(contentsOf: update.entries)
            if t.log.count > Self.logCap {
                let dropped = t.log.count - Self.logCap
                t.log.removeFirst(dropped)
                // Keep the round-start marker pointing at the same entry.
                if let run = runs[taskID] {
                    run.logStartIndex = max(0, run.logStartIndex - dropped)
                }
            }
        }
        // Outputs arrive after their tool call (a later result event) — attach
        // in place. An id that fell off the cap is simply gone; no-op.
        for (id, detail) in update.details {
            if let j = t.log.firstIndex(where: { $0.id == id }) { t.log[j].detail = detail }
        }
        tasks[i] = t
        // The session id lands a beat after the spawn, so the in-flight marker
        // is re-written once it's known: an interrupted run's Recent row can
        // then name the command that picks the session back up.
        if newSession { refreshInFlight(t) }
    }

    /// Remove the temp image files a codex run attached, if any. Idempotent.
    private func cleanupTempImages(_ run: RunState) {
        for url in run.tempImageURLs { try? FileManager.default.removeItem(at: url) }
        run.tempImageURLs = []
    }

    /// `interrupted` is the re-attached path's verdict: the process exited
    /// without its stream ever reaching a terminal event (killed externally,
    /// crashed) — files like a death-with-the-app, resumable from its row.
    private func settle(taskID: UUID, snapshot: AgentSnapshot,
                        exitStatus: Int32, interrupted: Bool = false) {
        guard let i = taskIndex(taskID), tasks[i].isRunning,
              let run = runs[taskID] else {
            // A settle that lands here leaves NO exchange and NO history row —
            // if a run ever "vanishes", this breadcrumb is the lead. Should be
            // unreachable: the teardown latch fires exactly once per run.
            DiagnosticsLog.shared.record(provider: "Agent", kind: "agent-settle-dropped")
            return
        }
        var t = tasks[i]
        runs[taskID] = nil
        cleanupTempImages(run)
        // The in-flight crash marker is NOT cleared here: it survives until the
        // history row is safely on disk (`recordAgentHistory` clears it after
        // its immediate archive write). Clearing at settle left a window —
        // marker gone, row still in the save debounce — where a crash erased
        // the run entirely.
        t.finishedAt = Date()
        t.activity = nil
        t.result = snapshot.finalMessage

        if run.cancelRequested {
            t.outcome = .cancelled
        } else if interrupted {
            t.outcome = .failure
            t.failureReason = L("agent.interrupted")
            t.interrupted = true
        } else if let failure = snapshot.failure {
            t.outcome = .failure
            t.failureReason = Self.friendlyFailure(failure, engine: t.engine)
        } else if exitStatus != 0 && snapshot.finalMessage.isEmpty {
            t.outcome = .failure
            t.failureReason = snapshot.stderrTail.isEmpty
                ? nil : Self.friendlyFailure(snapshot.stderrTail, engine: t.engine)
        } else {
            t.outcome = .success
        }

        // Every settled round becomes an exchange — a cancel included. A run
        // the user stops after ten minutes still edited files and still has a
        // resumable CLI session; dropping it on the floor was how a stopped run
        // vanished the moment its card was dismissed. The answer text here is
        // what history shows, so empty results fall back to the same outcome
        // lines the card headline uses.
        let answer: String
        switch t.outcome {
        case .success:
            let body = t.result.trimmingCharacters(in: .whitespacesAndNewlines)
            answer = body.isEmpty
                ? L("agent.done", t.engine.displayName,
                    NotchModel.formatAgentElapsed(t.elapsed))
                : body
        case .cancelled:
            // Whatever the run had already reported before the stop is worth
            // keeping — it's the only trace of the work it did.
            let body = t.result.trimmingCharacters(in: .whitespacesAndNewlines)
            answer = body.isEmpty
                ? L("agent.cancelled")
                : L("agent.cancelled") + "\n" + body
        default:
            let reason = (t.failureReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if t.interrupted {
                // Same closing line the launch-recovery interrupted rows use.
                answer = L("agent.interrupted")
            } else {
                answer = reason.isEmpty
                    ? L("agent.failed", t.engine.displayName)
                    : L("agent.failed", t.engine.displayName) + "\n" + reason
            }
        }
        let roundLog = run.logStartIndex < t.log.count
            ? Array(t.log[run.logStartIndex...]) : []
        t.exchanges.append(AgentExchange(prompt: run.currentPrompt, answer: answer,
                                         imageFiles: run.currentImageFiles,
                                         log: roundLog))
        tasks[i] = t

        // The history record is filed FIRST (via `onSettled` → Recent, keyed by
        // the task id), so the banner's tap below can land on an existing row.
        onSettled?(t)

        // An agent task runs for minutes — the user has almost certainly moved
        // on, so a finished run announces itself. Not a cancel, though: the user
        // just did that by hand, so there's nothing to announce (the row is
        // still filed above — it just doesn't buzz).
        if t.outcome != .cancelled {
            NotificationService.shared.postAgentFinished(
                engineName: t.engine.displayName,
                folderName: t.folder.lastPathComponent,
                success: t.outcome == .success,
                threadID: t.id)
        }

        // Follow-ups typed while this round ran dispatch now, oldest first, one
        // per settle — each becomes its own round in the same session. A cancel
        // clears the queue instead: the user said stop, so nothing auto-restarts.
        if t.outcome == .cancelled {
            pendingFollowUps[taskID] = nil
        } else if var queue = pendingFollowUps[taskID], !queue.isEmpty {
            let next = queue.removeFirst()
            pendingFollowUps[taskID] = queue.isEmpty ? nil : queue
            if let i = taskIndex(taskID) {
                beginFollowUpRound(index: i, prompt: next.prompt,
                                   imagesJPEG: next.imagesJPEG, appendMarker: false)
            }
        }
    }
}

/// Tails a run's stdout log file: a quarter-second timer reads whatever grew
/// since the last tick and hands it to `onData` (the pipe readability handler
/// this replaced pushed the same bytes; the parser line-buffers, so chunk
/// boundaries don't matter). `finishAndDrain` — called once the process is
/// known to have exited — stops the timer and synchronously reads the file to
/// its end, so the final result event is always ingested before the settle.
private final class RunLogTailer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let timer: DispatchSourceTimer
    private let handle: FileHandle?
    private let onData: (Data) -> Void
    private var finished = false

    init(url: URL, onData: @escaping (Data) -> Void) {
        self.onData = onData
        queue = DispatchQueue(label: "com.lofilab.notch.agent-tail", qos: .utility)
        handle = try? FileHandle(forReadingFrom: url)
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
    }

    deinit { timer.cancel() }

    /// Runs on `queue`. `availableData` on a regular file returns what sits
    /// between the current offset and EOF — empty (without blocking) when
    /// nothing new arrived.
    private func poll() {
        guard !finished, let handle else { return }
        let data = handle.availableData
        if !data.isEmpty { onData(data) }
    }

    /// Stop polling and synchronously drain the rest of the file. Idempotent;
    /// safe from any thread.
    func finishAndDrain() {
        timer.cancel()
        queue.sync {
            guard !finished else { return }
            finished = true
            guard let handle else { return }
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { break }
                onData(data)
            }
            try? handle.close()
        }
    }
}

/// A one-shot gate for teardown paths that can race (a re-attached run's exit
/// watch vs. the immediate liveness re-probe) — first caller wins.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func tryFire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

// MARK: - Stream parsing (thread-safe)

/// One batch of progress parsed out of newly-arrived JSONL data.
private struct AgentProgress {
    var activity: String?
    /// The model id the CLI reports for this session, once it says so.
    var model: String?
    /// The CLI's conversation handle (claude session_id / codex thread_id).
    var sessionID: String?
    /// Context-window occupancy after the latest turn, and the window size,
    /// when the round's usage events carry them.
    var contextUsed: Int?
    var contextWindow: Int?
    var changedFiles: [String] = []
    /// New work-trail entries, in stream order.
    var entries: [AgentLogEntry] = []
    /// Late-arriving outputs for earlier entries, keyed by entry id.
    var details: [(id: UUID, detail: String)] = []
}

/// A finished run's distilled output.
private struct AgentSnapshot {
    let finalMessage: String
    let failure: String?
    let stderrTail: String
    /// Whether the stream reached its own terminal event (claude's `result`,
    /// codex's `turn.completed`/`turn.failed`/`error`). False means the
    /// process died before concluding — recovery uses this to tell a finished
    /// run from one that was killed out from under the app.
    let sawTerminal: Bool
}

/// What the manager needs from an engine's JSONL dialect: progress while running,
/// a snapshot at the end. One conforming parser per `AgentEngine`.
private protocol AgentEventParser: AnyObject {
    func ingest(_ data: Data) -> AgentProgress?
    func appendStderr(_ data: Data)
    func finish() -> AgentSnapshot
}

/// The **codex** dialect (`codex exec --json`). Line-buffers stdout and distills
/// it into progress + a final snapshot. Lock-guarded: the readability and
/// termination handlers fire on different queues. Mirrors `StreamState` in
/// `CodexCLIService`, but where the chat only wants `agent_message` text, the
/// agent wants the *work trail* too: commands run, files changed, the report.
private final class CodexAgentStreamState: AgentEventParser {
    private let lock = NSLock()
    private var buffer = Data()
    private var stderrTail = ""
    private var finalMessage = ""
    private var failure: String?
    private var sawTerminal = false
    /// codex item id → the log entry it opened, so `item.completed` can attach
    /// the command's output to the entry `item.started` created.
    private var openEntries: [String: UUID] = [:]

    /// Append `data`, parse complete JSONL lines, and return the progress they
    /// carry (nil when nothing user-visible changed).
    func ingest(_ data: Data) -> AgentProgress? {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var progress = AgentProgress()
        return drainLines(into: &progress) ? progress : nil
    }

    /// Parse every complete (newline-terminated) line in `buffer` into
    /// `progress`. Caller holds the lock.
    private func drainLines(into progress: inout AgentProgress) -> Bool {
        var any = false
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            // Whichever event carries it (the thread/session one, depending on
            // the codex build), the model the session resolved to — including
            // when the run rode the user's own CLI default and we passed no flag.
            if progress.model == nil,
               let model = (obj["model"] as? String)
                ?? ((obj["msg"] as? [String: Any])?["model"] as? String) {
                progress.model = model
                any = true
            }
            guard let type = obj["type"] as? String else { continue }
            switch type {
            case "thread.started":
                // The conversation handle `codex exec resume` continues from.
                if let threadID = obj["thread_id"] as? String, !threadID.isEmpty {
                    progress.sessionID = threadID
                    any = true
                }
            case "turn.completed":
                sawTerminal = true
                // Per-turn token accounting. `input_tokens` is the request's
                // full prompt (cached_input_tokens is a subset of it, not
                // additive) = what the turn occupied of the context window.
                if let usage = obj["usage"] as? [String: Any],
                   let input = usage["input_tokens"] as? Int {
                    progress.contextUsed = input
                    any = true
                }
                // Opportunistic: some codex builds name the window too.
                if let window = (obj["model_context_window"] as? Int)
                    ?? ((obj["usage"] as? [String: Any])?["model_context_window"] as? Int),
                   window > 0 {
                    progress.contextWindow = window
                    any = true
                }
            case "item.started", "item.updated", "item.completed":
                guard let item = obj["item"] as? [String: Any],
                      let itemType = item["type"] as? String else { continue }
                let itemID = item["id"] as? String
                switch itemType {
                case "agent_message":
                    // Codex may emit interim messages; the last one is the report.
                    // Each is also a narration entry in the work trail.
                    if type == "item.completed",
                       let text = item["text"] as? String, !text.isEmpty {
                        finalMessage = text
                        progress.entries.append(AgentLogEntry(
                            id: UUID(), title: String(text.prefix(500)), mono: false))
                        any = true
                    }
                case "command_execution":
                    if let cmd = item["command"] as? String, !cmd.isEmpty {
                        progress.activity = "$ " + String(cmd.prefix(80))
                        any = true
                        // One log entry per item, opened on first sight; the
                        // completed event attaches the command's output to it.
                        if let itemID, openEntries[itemID] == nil {
                            let entry = AgentLogEntry(
                                id: UUID(), title: "$ " + String(cmd.prefix(200)), mono: true)
                            openEntries[itemID] = entry.id
                            progress.entries.append(entry)
                        }
                        if type == "item.completed", let itemID,
                           let entryID = openEntries.removeValue(forKey: itemID) {
                            let out = (item["aggregated_output"] as? String ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !out.isEmpty {
                                progress.details.append((entryID, String(out.suffix(2000))))
                            }
                        }
                    }
                case "file_change":
                    // `changes: [{path, kind}]` — collect names for the summary
                    // and surface the latest as the activity line. The completed
                    // event's final list is what goes in the work trail.
                    if let changes = item["changes"] as? [[String: Any]] {
                        for change in changes {
                            guard let path = change["path"] as? String else { continue }
                            let name = (path as NSString).lastPathComponent
                            progress.changedFiles.append(name)
                            progress.activity = "Editing " + name
                            any = true
                            if type == "item.completed" {
                                progress.entries.append(AgentLogEntry(
                                    id: UUID(), title: "Editing " + name, mono: true))
                            }
                        }
                    }
                case "web_search":
                    if let query = item["query"] as? String, !query.isEmpty {
                        progress.activity = "Searching " + String(query.prefix(60))
                        any = true
                        if let itemID, openEntries[itemID] == nil {
                            let entry = AgentLogEntry(
                                id: UUID(), title: "Searching " + String(query.prefix(200)), mono: true)
                            openEntries[itemID] = entry.id
                            progress.entries.append(entry)
                        }
                    }
                case "reasoning":
                    if type == "item.started" {
                        progress.activity = L("agent.thinking")
                        any = true
                    }
                default:
                    break
                }
            case "error":
                sawTerminal = true
                if let msg = obj["message"] as? String { failure = msg }
            case "turn.failed":
                sawTerminal = true
                if let err = obj["error"] as? [String: Any],
                   let msg = err["message"] as? String { failure = msg }
            default:
                break
            }
        }
        return any
    }

    func appendStderr(_ data: Data) {
        guard let s = String(data: data, encoding: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        stderrTail += s
        if stderrTail.count > 2000 { stderrTail = String(stderrTail.suffix(2000)) }
    }

    func finish() -> AgentSnapshot {
        lock.lock(); defer { lock.unlock() }
        // A last line the stream never newline-terminated would sit in the
        // buffer unparsed — and the LAST line is exactly where the result event
        // lives. Terminate it and give it one final parse (into a discarded
        // progress: only the snapshot fields matter now).
        if !buffer.isEmpty {
            buffer.append(0x0A)
            var residue = AgentProgress()
            _ = drainLines(into: &residue)
        }
        let tail = stderrTail
            .split(separator: "\n")
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? ""
        return AgentSnapshot(finalMessage: finalMessage, failure: failure,
                             stderrTail: tail, sawTerminal: sawTerminal)
    }
}

/// The **claude** dialect (`claude -p --output-format stream-json`). Assistant
/// events carry content blocks — `text` (narration; the last one is the
/// candidate report) and `tool_use` (the work trail: Bash commands, Edit/Write
/// file changes, web lookups). The final `result` event is authoritative for
/// both the report text and failure.
private final class ClaudeAgentStreamState: AgentEventParser {
    private let lock = NSLock()
    private var buffer = Data()
    private var stderrTail = ""
    private var finalMessage = ""
    private var failure: String?
    private var sawTerminal = false
    /// tool_use id → the log entry it opened, so the matching `tool_result`
    /// (a later `user` event) can attach the tool's output to it.
    private var openEntries: [String: UUID] = [:]

    func ingest(_ data: Data) -> AgentProgress? {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var progress = AgentProgress()
        return drainLines(into: &progress) ? progress : nil
    }

    /// Parse every complete (newline-terminated) line in `buffer` into
    /// `progress`. Caller holds the lock.
    private func drainLines(into progress: inout AgentProgress) -> Bool {
        var any = false
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }
            switch type {
            case "assistant":
                guard let message = obj["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                // Each API call reports its own usage — a live context-window
                // read while the run streams (the result event refines it).
                if let usage = message["usage"] as? [String: Any],
                   let used = Self.contextTokens(usage) {
                    progress.contextUsed = used
                    any = true
                }
                for block in content {
                    switch block["type"] as? String {
                    case "text":
                        // Interim narration; the last text before the result is
                        // the fallback report if the result event lacks one.
                        // Each is also a narration entry in the work trail.
                        if let text = block["text"] as? String, !text.isEmpty {
                            finalMessage = text
                            progress.entries.append(AgentLogEntry(
                                id: UUID(), title: String(text.prefix(500)), mono: false))
                            any = true
                        }
                    case "tool_use":
                        guard let name = block["name"] as? String else { continue }
                        let input = block["input"] as? [String: Any] ?? [:]
                        // Every tool call gets a work-trail entry; the handful
                        // below also drive the collapsed activity ticker and the
                        // changed-files summary, same as before.
                        var entryTitle = name
                        switch name {
                        case "Bash":
                            if let cmd = input["command"] as? String, !cmd.isEmpty {
                                progress.activity = "$ " + String(cmd.prefix(80))
                                entryTitle = "$ " + String(cmd.prefix(200))
                                any = true
                            }
                        case "Edit", "Write", "MultiEdit", "NotebookEdit":
                            if let path = input["file_path"] as? String {
                                let file = (path as NSString).lastPathComponent
                                progress.changedFiles.append(file)
                                progress.activity = "Editing " + file
                                entryTitle = "Editing " + file
                                any = true
                            }
                        case "WebSearch":
                            if let query = input["query"] as? String, !query.isEmpty {
                                progress.activity = "Searching " + String(query.prefix(60))
                                entryTitle = "Searching " + String(query.prefix(200))
                                any = true
                            }
                        case "WebFetch":
                            if let url = input["url"] as? String, !url.isEmpty {
                                progress.activity = "Reading " + String(url.prefix(60))
                                entryTitle = "Reading " + String(url.prefix(200))
                                any = true
                            }
                        case "Read", "Grep", "Glob":
                            // Quieter reads — not on the ticker, but part of the
                            // trail. Title = tool + its primary input.
                            let arg = (input["file_path"] as? String)
                                .map { ($0 as NSString).lastPathComponent }
                                ?? (input["pattern"] as? String)
                                ?? ""
                            entryTitle = arg.isEmpty ? name : "\(name) \(String(arg.prefix(120)))"
                        default:
                            break
                        }
                        let entry = AgentLogEntry(id: UUID(), title: entryTitle, mono: true)
                        if let useID = block["id"] as? String { openEntries[useID] = entry.id }
                        progress.entries.append(entry)
                        any = true
                    default:
                        break
                    }
                }
            case "user":
                // Tool results ride back as `user` events — attach each output
                // to the entry its tool_use opened.
                guard let message = obj["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                for block in content where block["type"] as? String == "tool_result" {
                    guard let useID = block["tool_use_id"] as? String,
                          let entryID = openEntries.removeValue(forKey: useID) else { continue }
                    let text = Self.resultText(block["content"])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        progress.details.append((entryID, String(text.prefix(2000))))
                        any = true
                    }
                }
            case "system":
                // The init event names the model the session resolved to (a full
                // id like `claude-opus-4-8-…`, even when the run rode the user's
                // CLI default) — the detail's info line reports it. It also
                // carries the session id follow-ups resume; --resume forks a
                // fresh id per round, so every round re-captures it here.
                if obj["subtype"] as? String == "init" {
                    if let model = obj["model"] as? String, !model.isEmpty {
                        progress.model = model
                        any = true
                    }
                    if let session = obj["session_id"] as? String, !session.isEmpty {
                        progress.sessionID = session
                        any = true
                    }
                }
            case "result":
                sawTerminal = true
                if (obj["is_error"] as? Bool) == true {
                    failure = (obj["result"] as? String)
                        ?? (obj["subtype"] as? String)
                        ?? "unknown error"
                } else if let text = obj["result"] as? String, !text.isEmpty {
                    finalMessage = text
                }
                // The run's authoritative token accounting: `usage` totals the
                // final request, `modelUsage` names each model's window.
                if let usage = obj["usage"] as? [String: Any],
                   let used = Self.contextTokens(usage) {
                    progress.contextUsed = used
                    any = true
                }
                if let modelUsage = obj["modelUsage"] as? [String: Any] {
                    let window = modelUsage.values
                        .compactMap { ($0 as? [String: Any])?["contextWindow"] as? Int }
                        .max()
                    if let window, window > 0 {
                        progress.contextWindow = window
                        any = true
                    }
                }
            default:
                break   // stream_event, rate_limit_event, …
            }
        }
        return any
    }

    /// Context-window occupancy from an Anthropic `usage` dict: the request's
    /// fresh input plus everything read/written through the prompt cache —
    /// i.e. the conversation the model actually saw this turn.
    private static func contextTokens(_ usage: [String: Any]) -> Int? {
        guard let input = usage["input_tokens"] as? Int else { return nil }
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        return input + cacheRead + cacheCreation
    }

    /// A tool_result's `content` is either a plain string or an array of blocks
    /// (text blocks for tool output, image blocks for screenshots). Distill the
    /// text.
    private static func resultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
    }

    func appendStderr(_ data: Data) {
        guard let s = String(data: data, encoding: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        stderrTail += s
        if stderrTail.count > 2000 { stderrTail = String(stderrTail.suffix(2000)) }
    }

    func finish() -> AgentSnapshot {
        lock.lock(); defer { lock.unlock() }
        // Same residue flush as the codex parser: a final unterminated line is
        // exactly where the `result` event would be.
        if !buffer.isEmpty {
            buffer.append(0x0A)
            var residue = AgentProgress()
            _ = drainLines(into: &residue)
        }
        let tail = stderrTail
            .split(separator: "\n")
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? ""
        return AgentSnapshot(finalMessage: finalMessage, failure: failure,
                             stderrTail: tail, sawTerminal: sawTerminal)
    }
}

/// The **grok** dialect (`grok --prompt-file … --output-format streaming-json`).
/// Deliberately the thinnest of the three parsers, because grok's headless
/// streaming-json surfaces only `text` (answer deltas), `thought` (reasoning
/// deltas) and a terminal `end` — NO per-tool events, even when the run edits
/// files or runs commands (verified). So there is no fine-grained work trail to
/// build: the ticker shows the report streaming (or "Thinking…" during
/// reasoning), and the whole report lands as one narration entry at `end`. The
/// full per-command / per-file trail would need grok's ACP mode (`grok agent
/// stdio`), a bidirectional JSON-RPC protocol incompatible with this subsystem's
/// file-tailing, survive-app-quit design. The `end` event carries `sessionId`
/// (what `grok --resume` continues) and `stopReason`; no token usage is emitted,
/// so the context meter stays blank for grok.
private final class GrokAgentStreamState: AgentEventParser {
    private let lock = NSLock()
    private var buffer = Data()
    private var stderrTail = ""
    private var finalMessage = ""
    private var failure: String?
    private var sawTerminal = false
    /// The report is emitted as a work-trail entry once, at `end`.
    private var emittedReport = false

    func ingest(_ data: Data) -> AgentProgress? {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var progress = AgentProgress()
        return drainLines(into: &progress) ? progress : nil
    }

    /// Parse every complete (newline-terminated) line into `progress`. Caller
    /// holds the lock.
    private func drainLines(into progress: inout AgentProgress) -> Bool {
        var any = false
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }
            switch type {
            case "text":
                if let t = obj["data"] as? String, !t.isEmpty {
                    finalMessage += t
                    // Rolling ticker: the tail of the report as it's written, so
                    // the collapsed card shows motion even without a tool trail.
                    let flat = finalMessage
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespaces)
                    progress.activity = String(flat.suffix(80))
                    any = true
                }
            case "thought":
                progress.activity = L("agent.thinking")
                any = true
            case "end":
                sawTerminal = true
                if let sid = obj["sessionId"] as? String, !sid.isEmpty {
                    progress.sessionID = sid
                    any = true
                }
                // The turn's token accounting, when the `end` event carries it:
                // `input_tokens` is the request's full prompt = what the turn
                // occupied of the context window (same semantic as codex's).
                if let usage = obj["usage"] as? [String: Any],
                   let input = usage["input_tokens"] as? Int, input > 0 {
                    progress.contextUsed = input
                    any = true
                }
                let report = finalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                // A terminal stopReason that names an error, with no report, is a
                // failure worth surfacing.
                if report.isEmpty, let reason = obj["stopReason"] as? String {
                    let r = reason.lowercased()
                    if r.contains("error") || r.contains("refus") || r.contains("cancel") {
                        failure = reason
                    }
                }
                if !emittedReport, !report.isEmpty {
                    emittedReport = true
                    progress.entries.append(AgentLogEntry(
                        id: UUID(), title: String(report.prefix(500)), mono: false))
                    any = true
                }
            case "error":
                sawTerminal = true
                failure = (obj["message"] as? String)
                    ?? (obj["data"] as? String)
                    ?? (obj["error"] as? String)
                    ?? "unknown error"
            default:
                break   // any other event types
            }
        }
        return any
    }

    func appendStderr(_ data: Data) {
        guard let s = String(data: data, encoding: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        stderrTail += s
        if stderrTail.count > 2000 { stderrTail = String(stderrTail.suffix(2000)) }
    }

    func finish() -> AgentSnapshot {
        lock.lock(); defer { lock.unlock() }
        // A last line the stream never newline-terminated (the `end` event, if
        // the process was killed mid-flush) still gets one parse.
        if !buffer.isEmpty {
            buffer.append(0x0A)
            var residue = AgentProgress()
            _ = drainLines(into: &residue)
        }
        let tail = stderrTail
            .split(separator: "\n")
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? ""
        return AgentSnapshot(finalMessage: finalMessage, failure: failure,
                             stderrTail: tail, sawTerminal: sawTerminal)
    }
}
