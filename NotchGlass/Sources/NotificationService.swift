import Foundation
import UserNotifications

/// Posts a native macOS notification when an Ask finishes *after the user has
/// walked away* — i.e. the panel folded back to the resting notch (the three
/// thinking dots) while the round kept streaming detached. Tapping the
/// notification reopens that exact conversation in the panel.
///
/// Why this exists: the whole point of Notch is "ask and walk away." When the
/// answer lands and you're no longer looking at the panel, there's otherwise no
/// signal it's ready — the dots just quietly go out. A native banner closes that
/// loop without the app having to steal focus or pop a window on its own.
///
/// Scope is deliberately narrow: it ONLY fires for the detached case. If the
/// panel is still on screen showing the answer stream, the user is already
/// watching — no notification. (The trigger lives in `NotchModel.submit`, gated
/// on `!isOnScreen`.)
@MainActor
final class NotificationService: NSObject {
    static let shared = NotificationService()

    /// `userInfo` key carrying the finished thread's history id, so the tap
    /// handler can reopen the right conversation.
    static let threadIDKey = "threadID"
    /// Notification category — lets the tap route through one identifiable path.
    private static let answerCategory = "answerReady"

    /// Posted (via `NotificationCenter.default`) when the user taps an answer
    /// banner, carrying the thread id string in `userInfo[threadIDKey]`.
    /// `AppDelegate` observes it, summons the panel, and reopens the thread.
    static let answerTapped = Notification.Name("notchAnswerNotificationTapped")

    /// Category for a finished agent-Codex task's banner, so its tap routes
    /// to the panel's idle view (where the result card lives) instead of a thread.
    private static let agentCategory = "agentDone"

    /// Posted when the user taps an agent-task banner. `AppDelegate` observes
    /// it and summons the panel on its idle prompt, where the result card shows.
    static let agentTapped = Notification.Name("notchAgentNotificationTapped")

    /// Whether we've already asked the system for authorization this launch — we
    /// request lazily on the first answer-ready post, never at launch (an
    /// accessory app popping a permission prompt the moment it starts is noise;
    /// the user has to actually use Ask-and-walk-away before it's relevant).
    private var didRequestAuthorization = false

    private var center: UNUserNotificationCenter { .current() }

    private override init() {
        super.init()
    }

    /// Wire the agent so taps route back into the app. Call once at launch.
    func configure() {
        center.delegate = self
    }

    /// Post an "answer ready" banner for a finished, walked-away Ask. Requests
    /// authorization on first use; if the user has denied it, this is a quiet
    /// no-op (the answer is already saved to Recent either way).
    ///
    /// - Parameters:
    ///   - threadID: the history id of the finished conversation (the tap target).
    ///   - title: the short conversation title, when one is ready, else nil.
    ///   - question: the user's first question — the banner's fallback body when
    ///     there's no title yet, and always its subtitle context.
    func postAnswerReady(threadID: UUID, title: String?, question: String) {
        ensureAuthorization { [weak self] granted in
            guard granted, let self else { return }
            let content = UNMutableNotificationContent()
            content.title = L("notify.answerReady.title")
            // Prefer the generated title; fall back to the raw question so the
            // banner always says *which* question is done, never a bare generic.
            let line = (title?.isEmpty == false ? title! : question)
            content.body = line
            content.categoryIdentifier = Self.answerCategory
            content.userInfo = [Self.threadIDKey: threadID.uuidString]
            content.sound = .default

            // Immediate delivery (nil trigger). The id is the thread id so a
            // follow-up that finishes detached replaces its own prior banner
            // rather than stacking a second one for the same conversation.
            let request = UNNotificationRequest(
                identifier: threadID.uuidString,
                content: content,
                trigger: nil)
            self.center.add(request, withCompletionHandler: nil)
        }
    }

    /// Post a "agent task finished" banner (XII: agent-to-Codex). A
    /// agent run takes minutes, so the user has almost certainly walked away;
    /// this closes the loop the same way the answer-ready banner does. Tapping it
    /// summons the panel and reopens the run's Recent record (`threadID` — the
    /// history row `recordAgentHistory` filed just before this posts).
    func postAgentFinished(engineName: String, folderName: String,
                              success: Bool, threadID: UUID) {
        ensureAuthorization { [weak self] granted in
            guard granted, let self else { return }
            let content = UNMutableNotificationContent()
            content.title = L(success ? "notify.agent.done" : "notify.agent.failed",
                              engineName)
            content.body = folderName
            content.categoryIdentifier = Self.agentCategory
            content.userInfo = [Self.threadIDKey: threadID.uuidString]
            content.sound = .default
            // One agent task at a time → one stable id, so a rerun replaces
            // its prior banner instead of stacking.
            let request = UNNotificationRequest(
                identifier: "agentTask", content: content, trigger: nil)
            self.center.add(request, withCompletionHandler: nil)
        }
    }

    /// Request authorization the first time we need it, then run `completion`
    /// with whether we may post. On later calls we read the live settings instead
    /// of re-prompting (the system only shows the prompt once anyway).
    private func ensureAuthorization(_ completion: @escaping (Bool) -> Void) {
        let center = self.center
        if !didRequestAuthorization {
            didRequestAuthorization = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                Task { @MainActor in completion(granted) }
            }
            return
        }
        center.getNotificationSettings { settings in
            let ok = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            Task { @MainActor in completion(ok) }
        }
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    /// A tap on the banner: pull the thread id and hand it to `AppDelegate` (via
    /// `NotificationCenter`) to summon the panel and reopen the conversation.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        if content.categoryIdentifier == Self.agentCategory {
            // Agent-task banner: summon the panel and reopen the run's Recent
            // record when one was filed (the id rides along like an answer tap's).
            let userInfo: [String: Any] = (content.userInfo[Self.threadIDKey] as? String)
                .flatMap(UUID.init(uuidString:))
                .map { [Self.threadIDKey: $0] } ?? [:]
            Task { @MainActor in
                NotificationCenter.default.post(name: Self.agentTapped, object: nil,
                                                userInfo: userInfo)
            }
        } else if let raw = content.userInfo[Self.threadIDKey] as? String,
                  let id = UUID(uuidString: raw) {
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: Self.answerTapped,
                    object: nil,
                    userInfo: [Self.threadIDKey: id])
            }
        }
        completionHandler()
    }

    /// Show the banner even while Notch is the frontmost app — it's an accessory
    /// overlay, so "frontmost" doesn't mean the user is looking at the answer; the
    /// detached-round gate already guaranteed they've walked away from the panel.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
