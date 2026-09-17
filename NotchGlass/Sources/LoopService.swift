import SwiftUI
import AppKit

// MARK: - /loop

/// `/loop` re-runs one prompt on an interval: as an Agent task (the same CLI
/// session, round after round — `AgentTaskManager`) or as an Ask thread (the
/// same conversation — `ChatLoopManager` below). This file holds what both
/// share: the interval vocabulary, the wall clock rounds wait on, the interval
/// card the compose chip opens, and the round column a loop's record reads in.
enum LoopInterval {
    /// The interval card's preset rows, in minutes.
    static let presets = [10, 30, 60, 360, 1440]
    /// What a typed value may be: one minute to one day.
    static let typedRange = 1...1440
    static let defaultMinutes = 60
    /// A loop ends on its own a week after it started.
    static let lifetime: TimeInterval = 7 * 24 * 3600
    /// What an agent writes at the end of a report to end its own loop.
    static let doneMarker = "[loop:done]"
    private static let lastKey = "loop.lastIntervalMinutes"

    /// The interval `/loop` last picked, so the next arming lands on it.
    static var lastMinutes: Int {
        let stored = UserDefaults.standard.integer(forKey: lastKey)
        return typedRange.contains(stored) ? stored : defaultMinutes
    }

    static func remember(_ minutes: Int) {
        guard typedRange.contains(minutes) else { return }
        UserDefaults.standard.set(minutes, forKey: lastKey)
    }

    /// Appended to every agent loop round's prompt on the wire only — the
    /// record keeps the prompt the user wrote.
    static func agentWireSuffix(minutes: Int) -> String {
        "\n\n(This task repeats every \(short(minutes)). When it is complete and no "
            + "further runs are needed, end your reply with \(doneMarker).)"
    }

    /// "45m" · "1h" · "1h 30m" · "6h" · "1d".
    static func short(_ minutes: Int) -> String {
        if minutes >= 1440, minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        return "\(minutes)m"
    }

    /// A waiting loop's countdown: the elapsed clock's own format under an hour
    /// ("8m 40s"), hours and minutes past it ("23h 41m").
    static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        if s >= 3600 { return String(format: "%dh %02dm", s / 3600, s % 3600 / 60) }
        return s < 60 ? "\(s)s" : String(format: "%dm %02ds", s / 60, s % 60)
    }

    /// Wait for a wall-clock moment. Checked every 30s rather than slept out in
    /// one go, so a Mac that sleeps past the deadline runs the round once on
    /// wake instead of sleeping the whole remainder again.
    static func wait(until date: Date) async throws {
        while true {
            let remaining = date.timeIntervalSinceNow
            if remaining <= 0 { return }
            try await Task.sleep(nanoseconds: UInt64(min(remaining, 30) * 1_000_000_000))
        }
    }
}

/// What a loop's ⌘ card shows about it — the same for a chat loop and an agent
/// loop.
struct LoopMenuInfo: Equatable {
    let intervalMinutes: Int
    let rounds: Int
    let nextRoundAt: Date?
    let active: Bool
}

// MARK: - Chat loops

/// Ask threads on a loop. The rounds themselves run through the ordinary chat
/// pipeline (`NotchModel.runChatLoopRound` — tools, persistence and Recent all
/// unchanged); this owns only the schedule: when the next round is due, how
/// many have run, and when the loop is over.
///
/// Active loops are written to `UserDefaults` so a quit does not end them; the
/// thread itself already lives in Recent. A finished loop's tray row does not
/// come back — tap it before quit, or find the thread in Recent.
@MainActor
final class ChatLoopManager: ObservableObject {
    static let shared = ChatLoopManager()

    struct ChatLoop: Identifiable, Equatable {
        /// The thread's id — also its Recent row's.
        let id: UUID
        let prompt: String
        var intervalMinutes: Int
        let startedAt: Date
        /// Loop rounds started so far.
        var rounds = 1
        /// Set while a loop round is running.
        var roundStartedAt: Date? = Date()
        var lastRoundDuration: TimeInterval = 0
        var nextRoundAt: Date? = nil
        var active = true
        /// Ended on a failed round, for the settled row's dot.
        var failed = false

        var isRunning: Bool { roundStartedAt != nil }
        var isWaiting: Bool { active && !isRunning }
        var interval: TimeInterval { TimeInterval(intervalMinutes * 60) }
    }

    /// Disk shape of an active loop. A round that was in flight is stored as
    /// waiting: the stream died with the process, and the next round starts
    /// after one interval (or immediately if `nextRoundAt` is already due).
    private struct Record: Codable {
        let id: UUID
        let prompt: String
        let intervalMinutes: Int
        let startedAt: Date
        let rounds: Int
        let lastRoundDuration: TimeInterval
        let nextRoundAt: Date?
    }

    private static let persistKey = "notch_chat_loops"

    /// Every loop not yet dismissed, in start order.
    @Published private(set) var loops: [ChatLoop] = []
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var restored = false

    /// Starts round `round` on the thread; false when it could not start. Set by
    /// `NotchModel`, which owns the chat pipeline.
    var runRound: ((_ threadID: UUID, _ prompt: String, _ round: Int) -> Bool)?
    /// Whether any round is streaming on the thread right now.
    var isThreadBusy: ((UUID) -> Bool)?

    private init() {
        loadFromDisk()
    }

    func loop(for id: UUID) -> ChatLoop? { loops.first { $0.id == id } }
    func isActive(_ id: UUID) -> Bool { loop(for: id)?.active == true }

    /// Arm the waits. `NotchModel` calls this after Recent is on disk and
    /// `runRound` is wired, so a due round continues the saved thread.
    func restore() {
        guard !restored else { return }
        restored = true
        let now = Date()
        loops.removeAll {
            $0.startedAt.addingTimeInterval(LoopInterval.lifetime) < now
        }
        persist()
        for loop in loops where loop.active && !loop.isRunning {
            let next = loop.nextRoundAt
                ?? now.addingTimeInterval(loop.interval)
            schedule(loop.id, at: next)
        }
    }

    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistKey),
              let records = try? JSONDecoder().decode([Record].self, from: data)
        else { return }
        let now = Date()
        for record in records {
            let next = record.nextRoundAt
                ?? now.addingTimeInterval(TimeInterval(record.intervalMinutes * 60))
            loops.append(ChatLoop(id: record.id, prompt: record.prompt,
                                  intervalMinutes: record.intervalMinutes,
                                  startedAt: record.startedAt, rounds: record.rounds,
                                  roundStartedAt: nil,
                                  lastRoundDuration: record.lastRoundDuration,
                                  nextRoundAt: next, active: true))
        }
    }

    /// Round one has just been handed to the chat pipeline under `id`.
    func register(id: UUID, prompt: String, minutes: Int) {
        loops.removeAll { $0.id == id }
        loops.append(ChatLoop(id: id, prompt: prompt, intervalMinutes: minutes,
                              startedAt: Date()))
        persist()
    }

    /// A round on a loop's thread finished. `loopRound` is the round number its
    /// answer carried — nil for a follow-up the user typed into the thread,
    /// which restarts the wait from now without counting as a round. `quietly`
    /// is a round superseded before it answered: the wait restarts, no banner.
    func roundFinished(threadID: UUID, loopRound: Int?, failed: Bool,
                       quietly: Bool = false, answer: String = "") {
        guard let i = loops.firstIndex(where: { $0.id == threadID }), loops[i].active
        else { return }
        if loopRound != nil, let started = loops[i].roundStartedAt {
            loops[i].lastRoundDuration = Date().timeIntervalSince(started)
            loops[i].roundStartedAt = nil
        }
        if quietly {
            schedule(threadID)
            return
        }
        let loop = loops[i]
        let pastLifetime = Date().addingTimeInterval(loop.interval)
            > loop.startedAt.addingTimeInterval(LoopInterval.lifetime)
        if (loopRound != nil && failed) || pastLifetime {
            end(threadID, failed: loopRound != nil && failed)
            notify(loop, subtitle: L("notify.loop.ended", loop.rounds),
                   silent: false, answer: answer)
            return
        }
        if loopRound != nil {
            notify(loop, subtitle: L("notify.loop.round", loop.rounds),
                   silent: true, answer: answer)
        }
        schedule(threadID)
    }

    /// The Stop in the loop's ⌘ card. A round already streaming finishes; no
    /// further round starts.
    func stop(_ id: UUID) {
        end(id, failed: false)
    }

    /// Drop a finished loop's row from the task list. The thread stays in Recent.
    func dismiss(_ id: UUID) {
        guard loop(for: id)?.active != true else { return }
        loops.removeAll { $0.id == id }
    }

    /// The header chip's new pick. A waiting loop restarts its wait from now;
    /// a round already streaming keeps going and uses the new gap after it.
    func setInterval(_ id: UUID, minutes: Int) {
        guard LoopInterval.typedRange.contains(minutes),
              let i = loops.firstIndex(where: { $0.id == id }), loops[i].active
        else { return }
        LoopInterval.remember(minutes)
        loops[i].intervalMinutes = minutes
        persist()
        if loops[i].isWaiting { schedule(id) }
    }

    private func end(_ id: UUID, failed: Bool) {
        timers[id]?.cancel()
        timers[id] = nil
        guard let i = loops.firstIndex(where: { $0.id == id }) else { return }
        loops[i].active = false
        loops[i].failed = failed
        loops[i].nextRoundAt = nil
        if let started = loops[i].roundStartedAt {
            loops[i].lastRoundDuration = Date().timeIntervalSince(started)
        }
        loops[i].roundStartedAt = nil
        persist()
    }

    private func schedule(_ id: UUID, after delay: TimeInterval? = nil, at date: Date? = nil) {
        guard let i = loops.firstIndex(where: { $0.id == id }), loops[i].active else { return }
        let next = date ?? Date().addingTimeInterval(delay ?? loops[i].interval)
        loops[i].nextRoundAt = next
        persist()
        timers[id]?.cancel()
        timers[id] = Task { [weak self] in
            do { try await LoopInterval.wait(until: next) } catch { return }
            self?.fire(id)
        }
    }

    private func persist() {
        let records: [Record] = loops.compactMap { loop in
            guard loop.active else { return nil }
            return Record(id: loop.id, prompt: loop.prompt,
                          intervalMinutes: loop.intervalMinutes,
                          startedAt: loop.startedAt, rounds: loop.rounds,
                          lastRoundDuration: loop.lastRoundDuration,
                          nextRoundAt: loop.isRunning ? nil : loop.nextRoundAt)
        }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.persistKey)
        }
    }

    private func fire(_ id: UUID) {
        timers[id] = nil
        guard let i = loops.firstIndex(where: { $0.id == id }), loops[i].active,
              !loops[i].isRunning else { return }
        // A follow-up is streaming on the thread: let it finish. Its own finish
        // restarts the wait; this is only the fallback if that never lands.
        if isThreadBusy?(id) == true {
            schedule(id, after: 60)
            return
        }
        loops[i].rounds += 1
        loops[i].roundStartedAt = Date()
        loops[i].nextRoundAt = nil
        persist()
        let loop = loops[i]
        guard runRound?(id, loop.prompt, loop.rounds) != true else { return }
        // The round could not start (a stream still open on the thread, an
        // archive that hasn't caught up). A missed round is not a dead loop:
        // give the round number back and wait out another interval. A round
        // that starts and then fails ends the loop from `roundFinished`.
        guard let j = loops.firstIndex(where: { $0.id == id }) else { return }
        loops[j].rounds -= 1
        loops[j].roundStartedAt = nil
        schedule(id)
    }

    private func notify(_ loop: ChatLoop, subtitle: String, silent: Bool,
                        answer: String) {
        NotificationService.shared.postAnswerReady(
            threadID: loop.id, title: nil, question: loop.prompt,
            answer: answer, subtitle: subtitle, silent: silent)
    }
}

// MARK: - Interval card

/// The interval chip's card: a minutes field on top, then the presets, then —
/// when the compose chip opened it — a row that lifts `/loop` without wiping
/// the prompt. A menu card never takes key focus (`MenuCardPanel`), so the
/// field reads keys through a local monitor while the card is up and the
/// prompt under it never sees them.
struct LoopIntervalMenu: View {
    let selected: Int
    let onSelect: (Int) -> Void
    let onDone: () -> Void
    /// Lifts the armed loop and keeps whatever is already in the prompt. Nil
    /// on a loop already running — that one stops from its own Stop, not here.
    var onClear: (() -> Void)? = nil

    /// The number the caret sits in — digits only. The unit is its own segment
    /// at the field's trailing edge, so a Delete takes a digit, never the unit.
    @State private var digits = ""
    @State private var unit: LoopUnit = .minutes
    /// The seeded value, not yet edited: the first digit or Delete replaces it
    /// whole, the way a selected field behaves.
    @State private var pristine = true
    @State private var highlight: Int? = nil
    @State private var keyMonitor: Any? = nil
    @State private var caretOn = true

    enum LoopUnit: Character {
        case minutes = "m", hours = "h", days = "d"

        var label: String {
            switch self {
            case .minutes: return L("loop.minutes")
            case .hours:   return L("loop.hours")
            case .days:    return L("loop.days")
            }
        }

        var factor: Int {
            switch self {
            case .minutes: return 1
            case .hours:   return 60
            case .days:    return 1440
            }
        }
    }

    private var parsed: Int? {
        guard let n = Int(digits), n > 0 else { return nil }
        let minutes = n * unit.factor
        return LoopInterval.typedRange.contains(minutes) ? minutes : nil
    }
    private var valid: Bool { digits.isEmpty || parsed != nil }
    private var offIndex: Int { LoopInterval.presets.count }
    private var rowCount: Int { LoopInterval.presets.count + (onClear == nil ? 0 : 1) }

    private var matchingPreset: Int? {
        parsed.flatMap { LoopInterval.presets.firstIndex(of: $0) }
    }

    private var width: CGFloat {
        var titles: [(String, String?)] = LoopInterval.presets.map {
            (LoopInterval.short($0), String?.none)
        }
        let unitWidest = [LoopUnit.minutes, .hours, .days]
            .max(by: { $0.label.count < $1.label.count })?.label
        titles.append(("0000", unitWidest))
        if onClear != nil { titles.append((L("loop.off"), nil)) }
        return MenuCard.width(titles: titles)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MenuCard.rowSpacing) {
            field
                .padding(.bottom, 3)
            ForEach(Array(LoopInterval.presets.enumerated()), id: \.offset) { index, minutes in
                MenuCardRow(title: LoopInterval.short(minutes),
                            emphasized: rowSelected(index),
                            selected: rowSelected(index),
                            onHoverIn: { highlight = index },
                            action: { pick(minutes) })
            }
            if onClear != nil {
                MenuCardRow(title: L("loop.off"),
                            selected: highlight == offIndex,
                            onHoverIn: { highlight = offIndex },
                            action: { onClear?() })
                    .padding(.top, 3)
            }
        }
        .padding(MenuCard.cardPad)
        .frame(width: width, alignment: .leading)
        .onAppear {
            seedField()
            installKeyMonitor()
        }
        .onDisappear(perform: removeKeyMonitor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("loop.chip.help"))
    }

    private func rowSelected(_ index: Int) -> Bool {
        if let highlight { return highlight == index }
        return matchingPreset == index
    }

    /// Settings' recessed field (`recessedSurface`, lit — it holds the keyboard
    /// while the card is up) at the card's row height. It opens on the interval
    /// already in effect, so the field is never a blank slot: digits at the
    /// caret, unit pinned to the trailing edge, switched with m / h / d.
    private var field: some View {
        HStack(spacing: 0) {
            Text(digits)
                .font(.sf(MenuCard.fontSize, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(valid ? Tokens.text1 : Tokens.danger)
            Rectangle()
                .fill(Tokens.text1)
                .frame(width: 1.5, height: 13)
                .opacity(caretOn ? 1 : 0)
                .padding(.leading, 1)
            Spacer(minLength: 8)
            Text(unit.label)
                .font(.sf(MenuCard.fontSize))
                .foregroundStyle(Tokens.text3)
        }
        .padding(.horizontal, 10)
        .frame(height: MenuCard.rowHeight)
        .recessedSurface(in: RoundedRectangle.control, lit: true)
        .accessibilityLabel(L("loop.chip.help"))
        .accessibilityValue("\(digits) \(unit.label)")
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 530_000_000)
                caretOn.toggle()
            }
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods.isDisjoint(with: [.command, .control, .option]) else { return event }
            switch event.keyCode {
            case 51, 117:                    // Delete / Forward Delete
                if pristine { digits = "" } else if !digits.isEmpty { digits.removeLast() }
                pristine = false
                highlight = nil
                return nil
            case 36, 76: commit(); return nil // Return / keypad Enter
            case 53: onDone(); return nil     // Esc
            case 126: step(-1); return nil    // ↑
            case 125: step(1); return nil     // ↓
            default:
                guard let raw = event.charactersIgnoringModifiers, let c = raw.first, c.isASCII
                else { return event }
                if c.isNumber {
                    if pristine { digits = "" }
                    pristine = false
                    if digits.count < 4 { digits.append(c) }
                    highlight = nil
                    return nil
                }
                if let key = c.lowercased().first, let picked = LoopUnit(rawValue: key) {
                    unit = picked
                    pristine = false
                    highlight = nil
                    return nil
                }
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    private func pick(_ minutes: Int) {
        LoopInterval.remember(minutes)
        onSelect(minutes)
    }

    private func commit() {
        // A row under the pointer (or the arrow keys) is the pick; typing into
        // the field drops the highlight, so the field wins after an edit.
        if let h = highlight {
            if h == offIndex { onClear?() } else { pick(LoopInterval.presets[h]) }
            return
        }
        if let value = parsed {
            pick(value)
            return
        }
        if !digits.isEmpty {
            Haptics.alignment()
            return
        }
        onDone()
    }

    /// Arrow keys walk the presets and mirror the highlighted one into the
    /// field, so Return commits what the field reads.
    private func step(_ delta: Int) {
        let current = highlight ?? matchingPreset ?? -1
        let next = min(max(current + delta, 0), rowCount - 1)
        highlight = next
        if next < LoopInterval.presets.count { setField(LoopInterval.presets[next]) }
    }

    private func seedField() { setField(selected) }

    /// Split minutes into the coarsest whole unit it fits: 1440 → `1 day`,
    /// 360 → `6 hr`, 90 → `90 min`.
    private func setField(_ minutes: Int) {
        if minutes % 1440 == 0 { digits = "\(minutes / 1440)"; unit = .days }
        else if minutes % 60 == 0 { digits = "\(minutes / 60)"; unit = .hours }
        else { digits = "\(minutes)"; unit = .minutes }
        pristine = true
    }
}

/// The compose chip's card, glass already on. Live loops reuse `LoopIntervalMenu`
/// without `onClear` — stopping is its own control.
struct LoopIntervalMenuCard: View {
    let selected: Int
    let onSelect: (Int) -> Void
    let onDone: () -> Void
    var onClear: (() -> Void)? = nil

    var body: some View {
        LoopIntervalMenu(selected: selected, onSelect: onSelect, onDone: onDone,
                         onClear: onClear)
            .preferredColorScheme(.dark)
            .menuCardBackground()
    }
}

/// Quiet header control for a loop already running. Hover brightens it so it
/// reads as a chip, not a label; the card is the compose interval menu.
struct LoopScheduleChip: View {
    let minutes: Int
    @Binding var open: Bool
    let onSelect: (Int) -> Void

    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                LucideIcon(mark: LucideIcons.loop, size: 11)
                Text(L("loop.every", LoopInterval.short(minutes)))
                    .monospacedDigit()
            }
            .font(.sf(Tokens.TypeSize.meta))
            .foregroundStyle(hovering ? Tokens.text2 : Tokens.text4)
            .lineLimit(1)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        .help(L("loop.change"))
        .accessibilityLabel(L("loop.change"))
        .modifier(MenuCardWindow(
            open: open,
            onDismiss: { _ in open = false },
            card: {
                AnyView(LoopIntervalMenuCard(
                    selected: minutes,
                    onSelect: { value in
                        onSelect(value)
                        open = false
                    },
                    onDone: { open = false }))
            }))
    }
}

// MARK: - Round column

/// A loop record's right column: one row per round, plus any follow-up typed
/// between rounds (named by its own words, a step dimmer). The rows are
/// Settings' sidebar rows (`InlineSettingsView.SidebarItem`) one-for-one — a
/// 104pt column of 28pt capsules, the 0.08 wash on the selected one.
///
/// The column is *sticky*: it rides the visible top of the record instead of
/// the record's layout top, so a round taller than the viewport doesn't carry
/// the round list off screen. Mount it as a `.overlay(alignment: .topTrailing)`
/// on the record body, with the body padded by `width` + its gutter — the
/// overlay's frame is the travel the column slides along. See
/// `stickyOffset(in:)`.
struct LoopRoundSidebar: View {
    struct Item: Identifiable {
        let id: Int
        let title: String
        var isFollowUp = false
        var running = false
    }

    static let width: CGFloat = 104

    let items: [Item]
    let selected: Int
    let onSelect: (Int) -> Void

    /// How many round rows sit on screen before the column scrolls. Matches
    /// the `/` menu's nine-row window, so a long loop doesn't stretch the
    /// record past the rest of the page.
    private static let visibleRows = 9
    private static var rowStride: CGFloat { 28 + 2 }

    /// The column's laid-out height for `rows` rounds. The record reserves this
    /// much height so a short round can't let the column hang off its bottom.
    static func height(rows: Int) -> CGFloat {
        CGFloat(min(max(rows, 1), visibleRows)) * rowStride - 2
    }

    @Environment(\.stickyScrollTopInset) private var stickyTopInset

    var body: some View {
        let list = LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                LoopRoundSidebarRow(item: item, selected: item.id == selected) {
                    withAnimation(.easeOut(duration: 0.16)) { onSelect(item.id) }
                }
            }
        }
        Group {
            if items.count > Self.visibleRows {
                ScrollViewReader { proxy in
                    ScrollView {
                        list
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: CGFloat(Self.visibleRows) * Self.rowStride - 2)
                    .onAppear { proxy.scrollTo(selected, anchor: .center) }
                    .onChange(of: selected) { _, id in
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            } else {
                list
            }
        }
        .frame(width: Self.width, alignment: .topTrailing)
        .modifier(StickyColumn(rows: items.count, topInset: stickyTopInset))
    }
}

/// Holds the round column at the visible top of the record it overlays.
/// `bounds(of: .scrollView)` hands back the thread scroller's visible rect in
/// the overlay's own coordinates, so a positive `minY` is exactly the slice of
/// the record that has scrolled up past the viewport top — push the column down
/// by that much, plus the host's dissolve band (`stickyScrollTopInset`).
///
/// Clamped at both ends: never above the record's top, and never past the point
/// where the column's own bottom reaches the record's, so it leaves with the
/// record instead of hanging off it. Returns 0 where there is no scroller —
/// then the column sits at the record's top, as it did before.
private struct StickyColumn: ViewModifier {
    let rows: Int
    let topInset: CGFloat

    func body(content: Content) -> some View {
        GeometryReader { geo in
            content.offset(y: offset(in: geo))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(width: LoopRoundSidebar.width)
    }

    private func offset(in geo: GeometryProxy) -> CGFloat {
        guard let visible = geo.bounds(of: .scrollView) else { return 0 }
        let travel = max(geo.size.height - LoopRoundSidebar.height(rows: rows), 0)
        return min(max(visible.minY + topInset, 0), travel)
    }
}

private struct LoopRoundSidebarRow: View {
    let item: LoopRoundSidebar.Item
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(item.title)
                    .font(.sf(Tokens.TypeSize.label, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(selected ? Tokens.text1
                        : (hovering ? Tokens.text2
                           : (item.isFollowUp ? Tokens.text4 : Tokens.text3)))
                if item.running {
                    AgentStatusDot(running: true, outcome: nil)
                        .scaleEffect(5.0 / 7.0)
                        .frame(width: 5, height: 5)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                Capsule().fill(.white.opacity(selected ? 0.08 : (hovering ? 0.04 : 0)))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityValue(item.running ? L("agent.thinking") : "")
        .id(item.id)
    }
}
