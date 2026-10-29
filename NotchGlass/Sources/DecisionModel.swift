import Foundation

/// Which model makes the small yes/no calls: Copy Sense, emoji reactions, the
/// link pre-check, and whether a next question is worth suggesting.
///
/// `jev` asks the gateway's Jev routes (`NoNoAccount`), free for any account
/// with a token. `jevKey` asks Jev on TypeSafe's API with the user's own key,
/// the same questions the gateway sends (`TypeSafeJevClient`). `custom` asks a
/// model on the user's own OpenAI-compatible endpoint (`DecisionEndpointClient`).
/// The last two need no Notchi account, and nothing goes through Notchi: the
/// user's provider bills the calls.
enum DecisionModel: String, CaseIterable, Identifiable {
    case jev
    case jevKey
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .jev:    return L("decision.jev")
        case .jevKey: return L("decision.jevKey")
        case .custom: return L("decision.custom")
        }
    }

    private static let key = "decisionModel"
    static var current: DecisionModel {
        get { UserDefaults.standard.string(forKey: key).flatMap(DecisionModel.init) ?? .jev }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Whether the calls skip the gateway: Jev with the user's key, or the
    /// custom endpoint, picked and filled in.
    static var usesOwn: Bool {
        switch current {
        case .jev:    return false
        case .jevKey: return !TypeSafeKey.value.isEmpty
        case .custom: return DecisionEndpoint.isConfigured
        }
    }
}

/// The user's TypeSafe API key for `DecisionModel.jevKey`.
enum TypeSafeKey {
    private static let key = "decision_typesafe.key"
    static var value: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
            else { UserDefaults.standard.set(trimmed, forKey: key) }
        }
    }
}

/// The user's own decision model: Jev on TypeSafe with their key, or their
/// custom endpoint, whichever `DecisionModel.current` names.
enum OwnDecisionModel {
    static func sense(_ text: String) async -> NoNoAccount.SenseVerdict? {
        DecisionModel.current == .jevKey ? await TypeSafeJevClient.sense(text)
            : await DecisionEndpointClient.sense(text)
    }
    static func react(to text: String, previous: String) async -> NoNoAccount.ReactVerdict? {
        DecisionModel.current == .jevKey ? await TypeSafeJevClient.react(to: text, previous: previous)
            : await DecisionEndpointClient.react(to: text, previous: previous)
    }
    static func checkLink(_ address: String) async -> NoNoAccount.LinkVerdict? {
        DecisionModel.current == .jevKey ? await TypeSafeJevClient.checkLink(address)
            : await DecisionEndpointClient.checkLink(address)
    }
    /// Settings' Test: one link check of a plain address through the picked
    /// model, so it probes the key, the endpoint and the reply format at once.
    static func test() async -> ConnectivityTest.Result {
        DecisionModel.current == .jevKey ? await TypeSafeJevClient.test()
            : await DecisionEndpointClient.test()
    }
    static func checkFollowUp(question: String, answer: String) async -> NoNoAccount.FollowUpVerdict? {
        DecisionModel.current == .jevKey
            ? await TypeSafeJevClient.checkFollowUp(question: question, answer: answer)
            : await DecisionEndpointClient.checkFollowUp(question: question, answer: answer)
    }
}

/// Jev on TypeSafe's own API (`POST /v1/systemone`) with the user's key. The
/// state and questions are the gateway's, word for word (`backend/src/sense.ts`,
/// `react.ts`, `linkcheck.ts`, `followup.ts`), and so is reading the answers.
enum TypeSafeJevClient {
    private static let url = URL(string: "https://api.typesafe.ai/v1/systemone")!

    private static let memoryKinds: [String: String] = [
        "action": "Something to do or attend: a task, errand, appointment, deadline, or anything tied to a date or time.",
        "about_person": "Something that shows who the person is or what they care about: their work, projects, people, places, interests, plans, or preferences.",
        "reference": "Information they may want again later: an article or passage they are reading, an idea, a quotation, a product, a name, an address, a number, a link to something they care about.",
        "none": "Nothing of later use: code, shell commands, file paths, interface labels, a throwaway chat reply, a fragment, or filler.",
    ]

    private static let memoryInstructions = "Someone just copied `copied_text` on their Mac. Their assistant keeps a memory of them and acts on their behalf. Decide whether anything in the text could be useful to the assistant later, to act on or to know the person better, and which kind it is; `none` only if it has no later use. The text may be in any language."

    /// Name, glyph, and when that glyph is the tapback. `none` has no glyph.
    private static let tapbacks: [(name: String, emoji: String, criterion: String)] = [
        ("none", "", "No single emoji fits. An ordinary task, piece of code, how-to, comparison, or request with no one subject."),
        ("thumbs_up", "👍", "Agrees, confirms, or answers what the assistant just asked."),
        ("heart", "❤️", "Thanks, affection, or something warm or personal."),
        ("laugh", "😂", "A joke, or clearly meant to be funny."),
        ("exclaim", "‼️", "Surprise or excitement, and no closer emoji in this list."),
        ("sad", "😢", "Bad news, a loss, or a hard time."),
        ("celebrate", "🎉", "An achievement, a milestone, or a celebration."),
        ("fire", "🔥", "Impressed, or calling something excellent."),
        ("clap", "👏", "Praise or applause."),
        ("pray", "🙏", "A wish, a hope, or a plea."),
        ("think", "🤔", "Wondering, or not sure."),
        ("eyes", "👀", "Curious, or asking to look at something."),
        ("wave", "👋", "A greeting or a goodbye."),
        ("muscle", "💪", "Effort, a workout, or encouragement."),
        ("sleep", "😴", "Tired, or going to sleep."),
        ("angry", "😠", "Anger or frustration."),
        ("cool", "😎", "Something cool, or unbothered."),
        ("mind_blown", "🤯", "Amazed or overwhelmed."),
        ("hundred", "💯", "Strong agreement, or a perfect score."),
        ("cake", "🎂", "A cake, a birthday, or dessert."),
        ("pizza", "🍕", "Pizza."),
        ("coffee", "☕", "Coffee."),
        ("tea", "🍵", "Tea."),
        ("boba", "🧋", "Milk tea or boba."),
        ("beer", "🍺", "Beer."),
        ("wine", "🍷", "Wine."),
        ("burger", "🍔", "A burger or fast food."),
        ("noodles", "🍜", "Noodles or ramen."),
        ("dumpling", "🥟", "Dumplings."),
        ("rice", "🍚", "Rice or a meal."),
        ("sushi", "🍣", "Sushi or Japanese food."),
        ("apple", "🍎", "Fruit, or an apple."),
        ("ice_cream", "🍦", "Ice cream."),
        ("cookie", "🍪", "A cookie or a snack."),
        ("spicy", "🌶️", "Spicy food."),
        ("car", "🚗", "A car, driving, or a ride."),
        ("bus", "🚌", "A bus."),
        ("train", "🚆", "A train or the subway."),
        ("plane", "✈️", "A flight or a plane."),
        ("bike", "🚲", "A bicycle."),
        ("ship", "🚢", "A ship, a boat, or a ferry."),
        ("rocket", "🚀", "A rocket, a launch, or space."),
        ("dog", "🐶", "A dog."),
        ("cat", "🐱", "A cat."),
        ("bird", "🐦", "A bird."),
        ("fish", "🐟", "A fish."),
        ("rabbit", "🐰", "A rabbit."),
        ("bear", "🐻", "A bear."),
        ("panda", "🐼", "A panda."),
        ("sun", "☀️", "Sun, heat, or a sunny day."),
        ("rain", "🌧️", "Rain or a storm."),
        ("snow", "❄️", "Snow or the cold."),
        ("rainbow", "🌈", "A rainbow."),
        ("flower", "🌸", "A flower, or spring."),
        ("tree", "🌳", "A tree, a forest, or a plant."),
        ("moon", "🌙", "Night, or the moon."),
        ("ocean", "🌊", "The sea or the ocean."),
        ("mountain", "⛰️", "A mountain or a hike."),
        ("home", "🏠", "Home or a house."),
        ("office", "🏢", "Being at work or the office, as the subject rather than a task."),
        ("school", "🏫", "School or class."),
        ("hospital", "🏥", "A hospital, a clinic, or going to see a doctor."),
        ("beach", "🏖️", "The beach."),
        ("hotel", "🏨", "A hotel or a stay."),
        ("run", "🏃", "Running or exercise."),
        ("ball", "⚽", "Football or soccer."),
        ("basketball", "🏀", "Basketball."),
        ("music", "🎵", "Music or a song."),
        ("movie", "🎬", "A movie or a show."),
        ("game", "🎮", "A game."),
        ("book", "📚", "A book or reading."),
        ("camera", "📷", "A photo or a camera."),
        ("art", "🎨", "Drawing, design, or art."),
        ("cook", "🍳", "Cooking."),
        ("money", "💰", "Money, a price, or getting paid, as the subject."),
        ("gift", "🎁", "A gift."),
        ("red_envelope", "🧧", "A red envelope."),
        ("baby", "👶", "A baby or a pregnancy."),
        ("ring", "💍", "A wedding, an engagement, or a ring."),
        ("pill", "💊", "Medicine or a pill."),
    ]

    private static let tapInstructions = "A friend would tap one emoji on `message` immediately, before typing a reply, because the message has a clear feeling or names one concrete thing with an obvious emoji."

    private static let tapCriteria: [String: String] = [
        "true": "A feeling is clear, or one subject is obvious: food, a vehicle, an animal, a place, weather, an object, or an activity. A question about that thing still counts.",
        "false": "An ordinary request for work — a task, code, a how-to, a comparison — with no single subject worth an emoji. Also no when an emoji would be a stretch.",
    ]

    private static let reactionInstructions = "Someone just sent `message` to their assistant. `previous_reply` is what the assistant said before it, if anything. Pick the one emoji a friend would tap on the message right away, so the person sees a reaction while the answer is still coming. Prefer the emoji for the concrete thing the message is about — a car, a cake, a dog, rain, a plane — even when the message is a question about that thing. Use a feeling emoji when the message is mostly a feeling and no thing fits better. Use `none` when nothing in the list is an obvious tapback. The text may be in any language."

    private static let linkInstructions = "Someone is about to open `url` in their browser; `host` is its host name. Judging only by the address, opening it is likely to put them at risk: phishing, a scam, or malware."

    private static let linkCriteria: [String: String] = [
        "true": "The host imitates a well-known brand with a misspelled, padded, or lookalike domain; the brand name sits in a subdomain, a path, or before an `@` while the real domain is unrelated; the host is a raw IP address or punycode; a sign-in, verify, prize, refund, or wallet lure sits on an unrelated domain; the address downloads an executable, installer, or script from a host that is not the software's own; or a sign-in or payment page uses plain http.",
        "false": "An ordinary address: a known site on its own domain, documentation, news, a code host, a store, a forum, a blog, a search result, or any unremarkable page. A long path, tracking parameters, or an unfamiliar but plain domain are not risks by themselves.",
    ]

    private static let followUpInstructions = "Someone asked their assistant `question` and got `answer`. They are likely to send another message on the same topic: a follow-up question, a doubt about the answer, or the next step. The text may be in any language."

    private static let followUpCriteria: [String: String] = [
        "true": "The answer is substantive and leaves something open: a comparison, a recommendation with trade-offs, an explanation with details worth asking about, a plan with next steps, or a claim the person may doubt.",
        "false": "The exchange reads as finished: the person thanked the assistant, said goodbye, or confirmed; the answer is a single fact, a short acknowledgement, a translation, a rewrite, or a saved note or reminder; or the message was small talk.",
    ]

    static func sense(_ text: String) async -> NoNoAccount.SenseVerdict? {
        let questions: [String: Any] = ["kind": ["type": "choice", "instructions": memoryInstructions,
                                                 "criteria": memoryKinds]]
        guard let answers = await ask(surface: "sense", state: ["copied_text": text],
                                      questions: questions, timeout: 5),
              let kind = answers["kind"] as? [String: Any],
              let choice = kind["choice"] as? String, memoryKinds[choice] != nil else { return nil }
        let probabilities = kind["probabilities"] as? [String: Any] ?? [:]
        let none = (probabilities["none"] as? NSNumber)?.doubleValue ?? (choice == "none" ? 1 : 0)
        return NoNoAccount.SenseVerdict(kind: choice, saveProbability: min(1, max(0, 1 - none)))
    }

    static func react(to text: String, previous: String) async -> NoNoAccount.ReactVerdict? {
        var criteria: [String: String] = [:]
        for t in tapbacks { criteria[t.name] = t.criterion }
        let questions: [String: Any] = [
            "tap": ["type": "noul", "instructions": tapInstructions, "criteria": tapCriteria],
            "reaction": ["type": "choice", "instructions": reactionInstructions, "criteria": criteria],
        ]
        guard let answers = await ask(surface: "react",
                                      state: ["message": text, "previous_reply": previous],
                                      questions: questions, timeout: 5),
              let reaction = answers["reaction"] as? [String: Any],
              let choice = reaction["choice"] as? String,
              let tapback = tapbacks.first(where: { $0.name == choice }) else { return nil }
        let probabilities = reaction["probabilities"] as? [String: Any] ?? [:]
        let tap = ((answers["tap"] as? [String: Any])?["noul"] as? NSNumber)?.doubleValue
        let p = tap ?? (probabilities[choice] as? NSNumber)?.doubleValue ?? 1
        return NoNoAccount.ReactVerdict(reaction: choice, probability: min(1, max(0, p)),
                                        emoji: tapback.emoji.isEmpty ? nil : tapback.emoji)
    }

    static func checkLink(_ address: String) async -> NoNoAccount.LinkVerdict? {
        let host = URL(string: address)?.host ?? ""
        let questions: [String: Any] = ["risky": ["type": "noul", "instructions": linkInstructions,
                                                  "criteria": linkCriteria]]
        // The click is waiting on this.
        guard let answers = await ask(surface: "linkcheck", state: ["url": address, "host": host],
                                      questions: questions, timeout: 3),
              let p = ((answers["risky"] as? [String: Any])?["noul"] as? NSNumber)?.doubleValue
        else { return nil }
        return NoNoAccount.LinkVerdict(verdict: p >= 0.5 ? "warn" : "open", probability: p)
    }

    static func checkFollowUp(question: String, answer: String) async -> NoNoAccount.FollowUpVerdict? {
        let questions: [String: Any] = ["continues": ["type": "noul", "instructions": followUpInstructions,
                                                      "criteria": followUpCriteria]]
        guard let answers = await ask(surface: "followup", state: ["question": question, "answer": answer],
                                      questions: questions, timeout: 4),
              let p = ((answers["continues"] as? [String: Any])?["noul"] as? NSNumber)?.doubleValue
        else { return nil }
        return NoNoAccount.FollowUpVerdict(verdict: p >= 0.5 ? "suggest" : "skip", probability: p)
    }

    static func test() async -> ConnectivityTest.Result {
        guard !TypeSafeKey.value.isEmpty else { return .missingKey }
        let address = "https://www.apple.com"
        let questions: [String: Any] = ["risky": ["type": "noul", "instructions": linkInstructions,
                                                  "criteria": linkCriteria]]
        return await send(surface: "test", state: ["url": address, "host": "www.apple.com"],
                          questions: questions, timeout: 12).result
    }

    private static func ask(surface: String, state: [String: Any], questions: [String: Any],
                            timeout: TimeInterval) async -> [String: Any]? {
        await send(surface: surface, state: state, questions: questions, timeout: timeout).answers
    }

    /// Send one request and return its `answers`. Recorded on Settings → Audit
    /// as a Jev call to api.typesafe.ai.
    private static func send(surface: String, state: [String: Any], questions: [String: Any],
                             timeout: TimeInterval) async -> (answers: [String: Any]?, result: ConnectivityTest.Result) {
        let key = TypeSafeKey.value
        guard !key.isEmpty else { return (nil, .missingKey) }
        let body: [String: Any] = ["model": "jev-latest", "state": state, "questions": questions]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return (nil, .failed(L("conn.unexpected"))) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = data

        let audit = RequestAudit.shared.beginJev(surface: surface, host: url.host ?? "api.typesafe.ai")
        audit.attempt()
        audit.request(request)
        do {
            let (reply, response) = try await ProxyConfig.urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                audit.finish(.failed, status: status)
                return (nil, DecisionTestResult.status(status))
            }
            guard let root = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
                  let answers = root["answers"] as? [String: Any]
            else {
                audit.finish(.failed, status: status)
                return (nil, .failed(L("conn.unexpected")))
            }
            if let usage = root["usage"] as? [String: Any] {
                audit.tokens(input: usage["input_tokens"] as? Int ?? 0,
                             output: usage["output_tokens"] as? Int ?? 0)
            }
            audit.finish(.ok, status: status)
            return (answers, .ok)
        } catch {
            audit.finish(.failed, error: error)
            return (nil, DecisionTestResult.error(error))
        }
    }
}

/// Maps a failed decision call to the Test verdict, the same way
/// `ConnectivityTest.run` reads a key probe.
private enum DecisionTestResult {
    static func status(_ code: Int) -> ConnectivityTest.Result {
        code == 401 || code == 403 ? .unauthorized(code) : .http(code)
    }
    static func error(_ error: Error) -> ConnectivityTest.Result {
        guard let error = error as? URLError else { return .failed(error.localizedDescription) }
        switch error.code {
        case .timedOut:                   return .timedOut
        case .notConnectedToInternet,
             .cannotConnectToHost,
             .cannotFindHost,
             .networkConnectionLost,
             .dnsLookupFailed:            return .offline
        default:                          return .failed(error.localizedDescription)
        }
    }
}

/// The user's endpoint for `DecisionModel.custom`: a base URL, an optional
/// key, and a model id. Kept apart from `CustomProvider` so the chat model and
/// the decision model can be different servers. Stored like every other key
/// (see `APIKeyStore` for why not the Keychain).
enum DecisionEndpoint {
    private static let urlKey = "decision_endpoint.url"
    private static let apiKeyKey = "decision_endpoint.key"
    private static let modelKey = "decision_endpoint.model"

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
        set { store(newValue, at: urlKey) }
    }

    static var apiKey: String {
        get { UserDefaults.standard.string(forKey: apiKeyKey) ?? "" }
        set { store(newValue, at: apiKeyKey) }
    }

    static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? "" }
        set { store(newValue, at: modelKey) }
    }

    /// The chat URL, normalized the same way the custom chat provider's is.
    static var chatEndpoint: URL? { CustomProvider.normalized(baseURL) }

    static var isConfigured: Bool { chatEndpoint != nil && !model.isEmpty }

    private static func store(_ value: String, at key: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
        else { UserDefaults.standard.set(trimmed, forKey: key) }
    }
}

/// The four decisions asked of the user's endpoint. Each is one non-streamed
/// chat completion that must answer with a JSON object; the questions are the
/// ones the gateway's Jev routes ask (`backend/src/sense.ts`, `react.ts`,
/// `linkcheck.ts`, `followup.ts`). Nil on any failure, as with Jev.
enum DecisionEndpointClient {
    static func sense(_ text: String) async -> NoNoAccount.SenseVerdict? {
        let system = """
        Someone just copied a piece of text on their Mac. Their assistant keeps a memory of them and acts on their behalf. \
        Decide whether anything in the text could be useful to the assistant later, to act on or to know the person better, \
        and which kind it is. The text may be in any language.
        Kinds:
        - action: something to do or attend: a task, errand, appointment, deadline, or anything tied to a date or time.
        - about_person: something that shows who the person is or what they care about: their work, projects, people, places, interests, plans, or preferences.
        - reference: information they may want again later: an article or passage, an idea, a quotation, a product, a name, an address, a number, a link to something they care about.
        - none: nothing of later use: code, shell commands, file paths, interface labels, a throwaway chat reply, a fragment, or filler.
        Answer with only a JSON object: {"kind": "<one kind>", "probability_none": <0 to 1, how likely the answer is none>}
        """
        guard let answer = await ask(surface: "sense", system: system,
                                     user: text, timeout: 5) else { return nil }
        let kinds: Set<String> = ["action", "about_person", "reference", "none"]
        guard let kind = answer["kind"] as? String, kinds.contains(kind) else { return nil }
        let none = probability(answer["probability_none"]) ?? (kind == "none" ? 1 : 0)
        return NoNoAccount.SenseVerdict(kind: kind, saveProbability: 1 - none)
    }

    static func react(to text: String, previous: String) async -> NoNoAccount.ReactVerdict? {
        let system = """
        Someone just sent a message to their assistant. Pick the one emoji a friend would tap on the message right away, \
        before typing a reply, so the person sees a reaction while the answer is still coming. Prefer the emoji for the \
        concrete thing the message is about (a car, a cake, a dog, rain, a plane), even when the message is a question \
        about that thing. Use a feeling emoji when the message is mostly a feeling and no thing fits better. Use an empty \
        string when no single emoji is an obvious tapback: an ordinary task, piece of code, how-to, comparison, or request \
        with no one subject. The text may be in any language.
        Answer with only a JSON object: {"emoji": "<one emoji, or empty>", "probability": <0 to 1, how likely a friend would tap any emoji>}
        """
        let user = previous.isEmpty ? "Message:\n\(text)"
            : "Previous reply from the assistant:\n\(previous)\n\nMessage:\n\(text)"
        guard let answer = await ask(surface: "react", system: system,
                                     user: user, timeout: 5) else { return nil }
        let emoji = (answer["emoji"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let p = probability(answer["probability"]) ?? (emoji.isEmpty ? 0 : 1)
        return NoNoAccount.ReactVerdict(reaction: emoji.isEmpty ? "none" : "custom",
                                        probability: p, emoji: emoji.isEmpty ? nil : emoji)
    }

    private static let linkSystem = """
    Someone is about to open a web address in their browser. Judging only by the address, decide how likely opening \
    it is to put them at risk: phishing, a scam, or malware.
    Risky: the host imitates a well-known brand with a misspelled, padded, or lookalike domain; the brand name sits in \
    a subdomain, a path, or before an @ while the real domain is unrelated; the host is a raw IP address or punycode; \
    a sign-in, verify, prize, refund, or wallet lure sits on an unrelated domain; the address downloads an executable, \
    installer, or script from a host that is not the software's own; or a sign-in or payment page uses plain http.
    Not risky: an ordinary address: a known site on its own domain, documentation, news, a code host, a store, a forum, \
    a blog, a search result, or any unremarkable page. A long path, tracking parameters, or an unfamiliar but plain \
    domain are not risks by themselves.
    Answer with only a JSON object: {"probability": <0 to 1, how likely it is risky>}
    """

    static func checkLink(_ address: String) async -> NoNoAccount.LinkVerdict? {
        let system = linkSystem
        // The click is waiting on this.
        guard let answer = await ask(surface: "linkcheck", system: system,
                                     user: address, timeout: 3),
              let p = probability(answer["probability"]) else { return nil }
        return NoNoAccount.LinkVerdict(verdict: p >= 0.5 ? "warn" : "open", probability: p)
    }

    static func checkFollowUp(question: String, answer: String) async -> NoNoAccount.FollowUpVerdict? {
        let system = """
        Someone asked their assistant a question and got an answer. Decide how likely they are to send another message \
        on the same topic: a follow-up question, a doubt about the answer, or the next step. The text may be in any language.
        Likely: the answer is substantive and leaves something open: a comparison, a recommendation with trade-offs, an \
        explanation with details worth asking about, a plan with next steps, or a claim the person may doubt.
        Unlikely: the exchange reads as finished: the person thanked the assistant, said goodbye, or confirmed; the answer \
        is a single fact, a short acknowledgement, a translation, a rewrite, or a saved note or reminder; or the message \
        was small talk.
        Answer with only a JSON object: {"probability": <0 to 1, how likely they continue>}
        """
        guard let reply = await ask(surface: "followup", system: system,
                                    user: "Question:\n\(question)\n\nAnswer:\n\(answer)", timeout: 4),
              let p = probability(reply["probability"]) else { return nil }
        return NoNoAccount.FollowUpVerdict(verdict: p >= 0.5 ? "suggest" : "skip", probability: p)
    }

    static func test() async -> ConnectivityTest.Result {
        guard DecisionEndpoint.isConfigured else { return .failed(L("decision.incomplete")) }
        let (answer, result) = await send(surface: "test", system: linkSystem,
                                          user: "https://www.apple.com", timeout: 20)
        guard result == .ok else { return result }
        return probability(answer?["probability"]) == nil ? .failed(L("conn.unexpected")) : .ok
    }

    private static func ask(surface: String, system: String, user: String,
                            timeout: TimeInterval) async -> [String: Any]? {
        await send(surface: surface, system: system, user: user, timeout: timeout).answer
    }

    /// Send one question and return the JSON object in the reply. Recorded on
    /// Settings → Audit under the endpoint's host, with the surface as purpose.
    private static func send(surface: String, system: String, user: String,
                             timeout: TimeInterval) async -> (answer: [String: Any]?, result: ConnectivityTest.Result) {
        guard let url = DecisionEndpoint.chatEndpoint, DecisionEndpoint.isConfigured else {
            return (nil, .failed(L("decision.incomplete")))
        }
        let model = DecisionEndpoint.model
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "temperature": 0,
            "max_tokens": 200,
            "messages": [["role": "system", "content": system],
                         ["role": "user", "content": user]],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = DecisionEndpoint.apiKey
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return (nil, .failed(L("conn.unexpected"))) }
        request.httpBody = data

        let audit = RequestAudit.Ticket(provider: url.host ?? "Endpoint", model: model,
                                        host: url.host ?? "", transport: .http, surface: surface)
        audit.attempt()
        audit.request(request)
        do {
            let (reply, response) = try await ProxyConfig.urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                audit.finish(.failed, status: status)
                return (nil, DecisionTestResult.status(status))
            }
            guard let root = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String,
                  let object = jsonObject(in: content)
            else {
                audit.finish(.failed, status: status)
                return (nil, .failed(L("conn.unexpected")))
            }
            if let usage = root["usage"] as? [String: Any] {
                audit.tokens(input: usage["prompt_tokens"] as? Int ?? 0,
                             output: usage["completion_tokens"] as? Int ?? 0)
            }
            audit.finish(.ok, status: status)
            return (object, .ok)
        } catch {
            audit.finish(.failed, error: error)
            return (nil, DecisionTestResult.error(error))
        }
    }

    /// The first `{…}` in `content`. Models wrap JSON in code fences or put a
    /// reasoning block before it.
    private static func jsonObject(in content: String) -> [String: Any]? {
        var text = content
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        let slice = Data(text[start...end].utf8)
        return (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any]
    }

    private static func probability(_ value: Any?) -> Double? {
        let n: Double?
        switch value {
        case let d as Double: n = d
        case let i as Int:    n = Double(i)
        case let s as String: n = Double(s)
        default:              n = nil
        }
        guard let n, n.isFinite else { return nil }
        return min(1, max(0, n))
    }
}
