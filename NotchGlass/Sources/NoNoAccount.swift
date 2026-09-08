import Foundation
import AppKit

/// The client half of nono's billing: getting a token, reading what is left of
/// the month, and handing the user off to Stripe.
///
/// Nothing spendable is compiled into the app. On first use this asks the
/// gateway for a token and stores it exactly where every other provider's key
/// lives; the gateway hands out an account with no allowance behind it, so the
/// token is worth nothing until a subscription pays for one. That is the whole
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
            /// opened the page — and while it holds, the Subscribe button must
            /// not be offered again.
            case awaitingPayment
        }
    }

    // MARK: - Wire types

    struct Snapshot: Decodable, Equatable {
        var accountId: String
        var subscription: Subscription
        var allowance: Pool
        var credit: Pool
        var availableUSD: Double

        struct Subscription: Decodable, Equatable {
            var status: String
            var active: Bool
            /// Milliseconds since the epoch, as the gateway stores it.
            var currentPeriodEnd: Double?
            var cancelAtPeriodEnd: Bool
        }

        struct Pool: Decodable, Equatable {
            var monthlyUSD: Double?
            var grantedUSD: Double?
            var usedUSD: Double
            var remainingUSD: Double
        }

        /// Whether Stripe already holds a subscription, spendable or not.
        ///
        /// Deliberately wider than `subscription.active`. A `past_due` plan
        /// cannot spend, but offering Subscribe there is offering to sell a
        /// second subscription to someone whose only problem is a dead card —
        /// the server refuses it, and the button should never have been there.
        /// Same for a period that has elapsed while the renewal webhook is in
        /// flight.
        var hasPlan: Bool {
            ["active", "trialing", "past_due", "incomplete", "paused"].contains(subscription.status)
        }

        /// How much of this month's allowance is gone, 0…1. Drives the fill on
        /// the allowance row.
        var usedFraction: Double {
            guard let total = allowance.monthlyUSD, total > 0 else { return 0 }
            return min(1, max(0, allowance.usedUSD / total))
        }

        var renewsAt: Date? {
            guard let ms = subscription.currentPeriodEnd, ms > 0 else { return nil }
            return Date(timeIntervalSince1970: ms / 1000)
        }
    }

    private struct Registration: Decodable { let token: String }
    private struct Redirect: Decodable { let url: String }
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

    func refresh() async {
        guard hasToken else { return }
        phase = .working(.refreshing)
        do {
            snapshot = try await get("/me")
            phase = .idle
        } catch {
            phase = .failed(message(for: error))
        }
    }

    // MARK: - Stripe hand-off

    /// Open Stripe's hosted checkout. The subscription is not live when this
    /// returns — it becomes live when Stripe's webhook reaches the gateway — so
    /// the caller polls afterwards rather than assuming success.
    func subscribe() async {
        await openHostedPage("/billing/checkout", work: .checkout)
    }

    /// Open Stripe's billing portal: change the card, or cancel.
    func manageBilling() async {
        await openHostedPage("/billing/portal", work: .portal)
    }

    private func openHostedPage(_ path: String, work: Phase.Work) async {
        guard hasToken else { return }
        phase = .working(work)
        do {
            let redirect: Redirect = try await post(path, body: [:], authorized: true)
            guard let url = URL(string: redirect.url) else {
                phase = .failed(L("nono.error.badRedirect"))
                return
            }
            NSWorkspace.shared.open(url)
            // Checkout keeps the busy state after the browser opens: the
            // payment happens over there, and a Subscribe button that comes
            // back the instant the tab appears is an invitation to buy twice.
            phase = work == .checkout ? .working(.awaitingPayment) : .idle
        } catch {
            phase = .failed(message(for: error))
        }
    }

    /// Poll for the subscription going live after checkout.
    ///
    /// Stripe redirects the browser the moment the payment clears, but the
    /// webhook that grants the allowance is a separate delivery and lands a
    /// beat later. Without this the user comes back to a pane that still says
    /// they have no plan, having just paid.
    func awaitActivation(timeout: TimeInterval = 90) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await reload()
            // Any plan state ends the wait, not just a spendable one: an
            // `incomplete` or `past_due` result means the payment was seen and
            // the answer is the billing portal, never a second checkout.
            if snapshot?.hasPlan == true {
                phase = .idle
                return
            }
        }
        // The timeout is not a verdict. The subscription may still land a
        // moment later, and the row reads whatever `/v1/me` last said rather
        // than assuming failure.
        phase = .idle
    }

    /// Refresh without disturbing a busy phase — used while waiting on Stripe,
    /// where `refresh()`'s own phase writes would clear the awaiting state and
    /// put the Subscribe button back.
    private func reload() async {
        guard hasToken else { return }
        snapshot = try? await get("/me")
    }

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

    private func post<T: Decodable>(_ path: String, body: [String: String], authorized: Bool) async throws -> T {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
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
