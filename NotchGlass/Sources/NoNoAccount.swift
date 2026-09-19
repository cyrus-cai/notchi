import Foundation
import AppKit

/// What the app tells nono about a request besides the request itself: which
/// part of the app sent it, which user action it belongs to, and the app
/// version.
///
/// Sent to nono only — `Provider.extraHeaders` attaches these for `.nono` and
/// for no other provider — and none of it is content. The gateway stores the
/// three values next to the token counts (notch.website/privacy, "nono").
///
/// Carried as a task-local so it reaches the request without threading a
/// parameter through every `stream…` signature: the entry point binds it
/// around the call that creates the stream, and the stream's own task inherits
/// it. Unbound means `unknown`.
struct NoNoRequestContext: Sendable {
    /// Which part of the app sent the request. The gateway accepts any short
    /// identifier, so a new value needs no server change.
    var surface: String
    /// One per user action. An answer that takes three tool rounds is three
    /// requests with the same id, so the gateway can count it as one turn.
    var turnID = UUID()

    /// A question typed into the notch panel.
    static let ask = "ask"
    /// A saved prompt shortcut, run in the panel or in its pointer window.
    static let shortcut = "shortcut"
    /// The Force Touch selection popup.
    static let forceTouch = "forceTouch"
    /// A follow-up or regenerate in a detached conversation window.
    static let window = "window"
    /// Background naming of a new prompt shortcut.
    static let naming = "naming"
    /// Background titling of a conversation thread.
    static let title = "title"

    @TaskLocal static var current: NoNoRequestContext?

    /// The headers for the request being built right now.
    static var headers: [String: String] {
        var headers = [
            "X-Notchi-Surface": current?.surface ?? "unknown",
            "X-Notchi-Version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "0",
        ]
        if let turn = current?.turnID { headers["X-Notchi-Turn-Id"] = turn.uuidString }
        return headers
    }
}

/// The client half of nono's billing: getting a token, reading what credit is
/// left, and handing the user off to Stripe to buy more.
///
/// Nothing spendable is compiled into the app. On first use this asks the
/// gateway for a token and stores it in `UserDefaults` like every other key
/// (`APIKeyStore`); the gateway hands out an account with no credit behind it, so the
/// token is worth nothing until a payment puts some there. That is the whole
/// reason registration can be an open endpoint — see the gateway's `client.ts`.
///
/// Card details never reach this process. Checkout and the billing portal are
/// pages Stripe hosts; the app only opens a URL the gateway produced.
@MainActor
final class NoNoAccount: ObservableObject {
    static let shared = NoNoAccount()

    /// What the gateway says about this account. `nil` until the first refresh
    /// lands — the difference between "no plan" and "not asked yet" matters to
    /// what the settings row draws.
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var phase: Phase = .idle
    /// Dollars granted this process that the wallet card has not yet shown.
    /// Zero when this launch did not receive a gift, or after the notice is dismissed.
    @Published private(set) var justGrantedUSD: Double = 0

    private static let seenGiftsKey = "NotchiSeenGiftIDs"
    /// Gifts dated before this are from an earlier launch, not this one.
    private let sessionStart = Date()

    enum Phase: Equatable {
        case idle
        /// A request is in flight. Carries what it is, so the row can say
        /// "Connecting…" rather than showing a bare spinner.
        case working(Work)
        case failed(String)

        enum Work: Equatable {
            case registering, refreshing, checkout, portal
            /// Stripe has the browser and the payment has not come back yet.
            /// Distinct from `checkout` because it outlasts the request that
            /// opened the page — and while it holds, the buy button must not be
            /// offered again.
            case awaitingPayment
        }
    }

    // MARK: - Wire types

    struct Snapshot: Decodable, Equatable {
        var accountId: String
        var credit: Credit
        var availableUSD: Double
        var limits: Limits

        struct Credit: Decodable, Equatable {
            /// Cumulative dollars ever bought, what has been consumed, and the
            /// difference. `remainingUSD` is the headline: bought leftover plus
            /// unexpired gift. `grantedUSD` / `usedUSD` stay the bought figures.
            var grantedUSD: Double
            var usedUSD: Double
            var remainingUSD: Double
            /// Milliseconds since the epoch, or nil if nothing has ever been
            /// bought. The one date a prepaid wallet has.
            var lastToppedUpAt: Double?
        }

        /// Operator-given credit that lapses. `null` on the wire when none is
        /// left unexpired. `remainingUSD` is what of it can still spend;
        /// `expiresAt` is when the soonest of it lapses.
        struct Gift: Decodable, Equatable {
            var remainingUSD: Double
            var expiresAt: Double?
        }

        var gift: Gift?

        struct Limits: Decodable, Equatable {
            /// The ceiling actually in force today, not the configured floor —
            /// the gateway resolves that before sending it.
            var dailySpendCapUSD: Double
            var daySpentUSD: Double
            var maxRequestsPerMinute: Int
        }

        /// Whether this account has ever bought credit. Not the same as having
        /// some left: someone who bought $5 and spent it is a customer with an
        /// empty wallet, and the row says "Out of credit" rather than offering
        /// them the first-purchase copy again.
        var hasEverPaid: Bool { credit.grantedUSD > 0 }

        var isEmpty: Bool { credit.remainingUSD <= 0 }

        /// Blocked by today's ceiling rather than by an empty wallet. Two
        /// different problems: one is fixed by waiting, the other by paying,
        /// and telling someone with $18 left to buy more would be wrong.
        var cappedForToday: Bool {
            !isEmpty && limits.daySpentUSD >= limits.dailySpendCapUSD
        }

        var lastToppedUp: Date? {
            guard let ms = credit.lastToppedUpAt, ms > 0 else { return nil }
            return Date(timeIntervalSince1970: ms / 1000)
        }

        var hasGift: Bool { (gift?.remainingUSD ?? 0) > 0 }

        var giftExpires: Date? {
            guard let ms = gift?.expiresAt, ms > 0 else { return nil }
            return Date(timeIntervalSince1970: ms / 1000)
        }
    }

    private struct Registration: Decodable { let token: String }
    private struct Redirect: Decodable { let url: String; let amountUSD: Double? }
    private struct Failure: Decodable {
        struct Body: Decodable { let message: String?; let code: String? }
        let error: Body
    }

    // MARK: - Reading

    var token: String { APIKeyStore.stored(for: .nono) }
    var hasToken: Bool { !token.isEmpty }

    /// Ask the gateway for a token if this install has none, then read the
    /// account. Safe to call on every appearance of the settings pane: it is a
    /// no-op once a token exists and a refresh is not already running.
    func load() async {
        if case .working = phase { return }
        if !hasToken {
            await register()
            guard hasToken else { return }
        }
        await refresh()
    }

    func register() async {
        phase = .working(.registering)
        do {
            let response: Registration = try await post("/register", body: [:], authorized: false)
            APIKeyStore.save(response.token, for: .nono)
            phase = .idle
        } catch {
            phase = .failed(message(for: error))
        }
    }

    private var lastRefreshAt: Date?

    /// The refresh the panel runs each time it opens, so a grant sent while the
    /// app is running shows without a relaunch. At most once per 30 seconds.
    func refreshIfStale() async {
        guard hasToken else { return }
        if case .working = phase { return }
        if let last = lastRefreshAt, Date().timeIntervalSince(last) < 30 { return }
        await refresh()
    }

    func refresh() async {
        guard hasToken else { return }
        lastRefreshAt = Date()
        phase = .working(.refreshing)
        do {
            snapshot = try await get("/me")
            phase = .idle
        } catch {
            phase = .failed(message(for: error))
            return
        }
        await refreshJustGranted()
    }

    /// `/v1/me` only says whether any gift is live, so the ids come from
    /// `/v1/balances`. The card shows only what landed this launch, not the
    /// leftover of earlier grants.
    private func refreshJustGranted() async {
        guard snapshot?.hasGift == true else { return }
        guard let lines = try? await loadBalances() else { return }
        let now = Date()
        let gifts = lines.filter {
            $0.kind == .gift && ($0.expiresDate.map { $0 > now } ?? true)
        }
        var known = Set(UserDefaults.standard.stringArray(forKey: Self.seenGiftsKey) ?? [])
        let fresh: [BalanceLine]
        if known.isEmpty {
            // First observation on this install: an older grant must not pop
            // just because its id was never stored. Only a gift dated around
            // this process counts as this launch's.
            let floor = sessionStart.addingTimeInterval(-30)
            fresh = gifts.filter { $0.date >= floor }
        } else {
            fresh = gifts.filter { !known.contains($0.id) }
        }
        let amount = fresh.reduce(0) { $0 + $1.amountUSD }
        if amount > 0.0000005 { justGrantedUSD += amount }
        for gift in gifts { known.insert(gift.id) }
        UserDefaults.standard.set(Array(known), forKey: Self.seenGiftsKey)
    }

    /// The prompt's grant chip was tapped: hide it, and have the wallet card
    /// start its figure at the balance before the grant so it rolls up to the
    /// current one. The gift stays on the balance.
    func claimGrant() {
        if let remaining = snapshot?.credit.remainingUSD {
            let from = remaining - justGrantedUSD
            rollFromUSD = from < 0.01 ? 0 : from
        }
        justGrantedUSD = 0
    }

    /// The figure the wallet card starts from after `claimGrant`. Nil once the
    /// card has rolled to the current balance.
    @Published private(set) var rollFromUSD: Double?

    func finishGrantRoll() {
        rollFromUSD = nil
    }

    /// One settled request against this wallet, as `/v1/usage` returns it.
    struct UsageLine: Decodable, Identifiable, Equatable {
        var requestId: String
        var at: Double
        var model: String
        var promptTokens: Int?
        /// The part of `promptTokens` served from the upstream's cache, billed
        /// at the cached rate. `nil` on a model with one input rate.
        var cachedTokens: Int?
        var completionTokens: Int?
        var billedUSD: Double?

        var id: String { requestId }

        var date: Date { Date(timeIntervalSince1970: at / 1000) }
    }

    private struct UsagePage: Decodable {
        var data: [UsageLine]
    }

    /// Newest first. Does not touch `phase`: the wallet card must not spin
    /// because the usage page asked for a list.
    func loadUsage(limit: Int = 100) async throws -> [UsageLine] {
        guard hasToken else { return [] }
        let page: UsagePage = try await get("/usage?limit=\(limit)")
        return page.data
    }

    /// One credit as `/v1/balances` returns it. `amountUSD` is the original amount.
    struct BalanceLine: Decodable, Identifiable, Equatable {
        enum Kind: String, Decodable, Equatable {
            case gift, purchase
        }

        var id: String
        var kind: Kind
        /// A gift's name, set by the operator per campaign. Nil on a purchase
        /// and on gifts from before names existed, which are welcome gifts.
        var title: String?
        var amountUSD: Double
        var expiresAt: Double?
        var at: Double

        var date: Date { Date(timeIntervalSince1970: at / 1000) }
        var expiresDate: Date? {
            guard let ms = expiresAt, ms > 0 else { return nil }
            return Date(timeIntervalSince1970: ms / 1000)
        }
    }

    private struct BalancesPage: Decodable {
        var data: [BalanceLine]
    }

    func loadBalances() async throws -> [BalanceLine] {
        guard hasToken else { return [] }
        let page: BalancesPage = try await get("/balances")
        return page.data
    }

    // MARK: - Stripe hand-off

    /// The bounds the gateway enforces on one purchase. Mirrored here so the
    /// stepper cannot offer a figure the server will refuse; the server is still
    /// the authority, and a mismatch surfaces as its own error message.
    static let minimumTopUpUSD: Double = 1
    static let maximumTopUpUSD: Double = 200

    /// Open Stripe's hosted checkout for `amountUSD`. The credit is not there
    /// when this returns — it arrives when Stripe's webhook reaches the gateway
    /// — so the caller polls afterwards rather than assuming success.
    func buyCredit(amountUSD: Double) async {
        let clamped = min(Self.maximumTopUpUSD, max(Self.minimumTopUpUSD, amountUSD))
        await openHostedPage("/billing/topup", work: .checkout, body: ["amountUSD": clamped])
    }

    /// Open Stripe's billing portal: the receipts, and the card on file.
    func manageBilling() async {
        await openHostedPage("/billing/portal", work: .portal)
    }

    private func openHostedPage(_ path: String, work: Phase.Work, body: [String: Any] = [:]) async {
        guard hasToken else { return }
        phase = .working(work)
        do {
            let redirect: Redirect = try await post(path, body: body, authorized: true)
            guard let url = URL(string: redirect.url) else {
                phase = .failed(L("nono.error.badRedirect"))
                return
            }
            NSWorkspace.shared.open(url)
            // Checkout keeps the busy state after the browser opens: the
            // payment happens over there, and a buy button that comes back the
            // instant the tab appears is an invitation to pay twice.
            phase = work == .checkout ? .working(.awaitingPayment) : .idle
        } catch {
            phase = .failed(message(for: error))
        }
    }

    /// Poll for the credit landing after checkout.
    ///
    /// Stripe redirects the browser the moment the payment clears, but the
    /// webhook that credits the wallet is a separate delivery and lands a beat
    /// later. Without this the user comes back to a pane that still shows the
    /// old balance, having just paid.
    ///
    /// The test is the bought total (`credit.grantedUSD`) rising above what it
    /// was before checkout. Not "has any credit": a repeat purchase is the
    /// normal case, and the wallet already had money in it. Not `remainingUSD`
    /// either: that includes gifts, and a welcome gift landing on the first poll
    /// would end the wait before the card was charged.
    ///
    /// A checkout that never opened has nothing to wait for, and the failure it
    /// left in `phase` stays on screen.
    func awaitCredit(boughtAbove previousUSD: Double, timeout: TimeInterval = 90) async {
        guard phase == .working(.awaitingPayment) else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await reload()
            if let now = snapshot?.credit.grantedUSD, now > previousUSD + 0.0000005 {
                phase = .idle
                return
            }
        }
        // The timeout is not a verdict. The payment may still land a moment
        // later, and the row reads whatever `/v1/me` last said rather than
        // assuming failure.
        phase = .idle
    }

    /// Refresh without disturbing a busy phase — used while waiting on Stripe,
    /// where `refresh()`'s own phase writes would clear the awaiting state and
    /// put the buy button back.
    private func reload() async {
        guard hasToken else { return }
        snapshot = try? await get("/me")
    }

    /// What the wallet holds right now, gifts included.
    var remainingUSD: Double { snapshot?.credit.remainingUSD ?? 0 }

    // MARK: - Transport

    /// The gateway's API root — the chat endpoint minus its method path, so the
    /// local-development override in `Provider.nonoEndpoint` carries over here
    /// rather than being configured twice.
    private var base: String {
        let endpoint = Provider.nonoEndpoint
        guard let range = endpoint.range(of: "/chat/completions", options: .backwards) else { return endpoint }
        return String(endpoint[endpoint.startIndex..<range.lowerBound])
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: URL(string: base + path)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], authorized: Bool) async throws -> T {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        // The gateway gives the welcome gift only to a `/v1/me` that carries
        // the app's version: a request without one is a build too old to send
        // it on completions either, and those would read as a script's.
        var request = request
        for (field, value) in NoNoRequestContext.headers where field == "X-Notchi-Version" {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failed.transport }
        guard (200..<300).contains(http.statusCode) else {
            // The gateway answers in the same error envelope every provider
            // uses, so its own words are the best message available.
            let decoded = try? JSONDecoder().decode(Failure.self, from: data)
            throw Failed.api(status: http.statusCode,
                             code: decoded?.error.code ?? "",
                             message: decoded?.error.message ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private enum Failed: Error {
        case transport
        case api(status: Int, code: String, message: String)
    }

    private func message(for error: Error) -> String {
        guard case Failed.api(_, _, let text)? = error as? Failed, !text.isEmpty else {
            return L("nono.error.unreachable")
        }
        return text
    }
}
