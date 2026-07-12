import Accelerate
import CryptoKit
import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Decides, from the text in the input box alone, whether the user is **asking
/// the AI** or **jotting a note** — the brain behind the panel's auto-routing.
///
/// This replaced the original hand-written rules engine, which topped out around
/// "openers and question marks" and misread anything phrased naturally. The
/// engine is model-based but still fully **on-device and provider-independent**:
///
///   1. The user's line is embedded with `NLContextualEmbedding` — the OS's
///      built-in multilingual transformer (NaturalLanguage framework, macOS 14+,
///      no Apple Intelligence requirement, available in mainland China).
///   2. A tiny **logistic head** over that embedding space scores ask vs. note.
///      The head is fit *on this device, once* from the bundled labeled examples
///      in `IntentExamples` (a few hundred lines per language), then cached to
///      disk keyed by the embedding model's identity — so a future OS model
///      revision retrains automatically instead of misreading a shifted space.
///   3. On machines where Apple Intelligence is live (macOS 26+), the system LLM
///      (`FoundationModels`) is consulted as a **second opinion only for lines
///      the head is unsure about** — never on the hot path.
///
/// Latency: one embed + dot product is ~1 ms on a background thread, so the
/// caller can classify on (debounced) keystrokes without touching typing
/// performance. Until `prepare()` finishes (first launch trains the head in the
/// background, a few seconds at most), every read is `.empty` — which the UI
/// already treats as "no signal → default to Ask", so the app degrades to
/// exactly the old resting behavior rather than blocking on the model.
actor IntentEngine {
    static let shared = IntentEngine()

    /// What the text reads as. `ambiguous` means no usable signal (engine not
    /// ready, embedding failed) — the caller decides the default (here: ask).
    enum Intent: Equatable, Sendable {
        case ask
        case note
        case ambiguous
    }

    /// The verdict for one piece of text. `confidence` is the margin of the
    /// model's lean mapped to 0…1 (|2p−1| for the head's note-probability p — 0
    /// is a coin flip, 1 is certain); `source` says which layer produced it
    /// ("embedding" / "llm" / "none"), kept for debugging and never shown.
    struct Reading: Equatable, Sendable {
        var intent: Intent
        var confidence: Double
        var source: String

        static let empty = Reading(intent: .ambiguous, confidence: 0, source: "none")
    }

    // MARK: - Spaces (one per embedding model)

    /// The OS ships separate contextual-embedding models per script family, with
    /// *different, incomparable* vector spaces — so each gets its own model + its
    /// own trained head. Text containing any Han/Kana/Hangul routes to the CJK
    /// space; everything else to the Latin one.
    private final class Space {
        enum State { case idle, ready, unavailable }
        let language: NLLanguage
        let embedding: NLContextualEmbedding
        let examples: IntentExampleSet
        var state: State = .idle
        var head: LogisticHead?
        /// The training embeddings, kept for the kNN vote (see `classify`). The
        /// logistic head carves one global plane; the neighbor vote captures the
        /// local structure of two classes that are each a *bag* of genres
        /// (todos/logs/lists vs. questions/imperatives). Their average beats
        /// either alone on held-out data.
        var noteVectors: [[Double]] = []
        var askVectors: [[Double]] = []

        init?(language: NLLanguage, examples: IntentExampleSet) {
            guard let embedding = NLContextualEmbedding(language: language) else { return nil }
            self.language = language
            self.embedding = embedding
            self.examples = examples
        }
    }

    private var cjk: Space?
    private var latin: Space?
    private var prepared = false

    /// Recent verdicts by exact text — typing is incremental, but deletes and
    /// IME candidate cycling revisit the same string constantly. Tiny LRU.
    private var cache: [String: Reading] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 256

    /// LLM second opinions are much more expensive than embeddings, so they get
    /// their own (also tiny) cache. Separate because an LLM verdict should not
    /// be evicted by a flood of cheap embedding reads.
    private var llmCache: [String: Reading] = [:]
    private var llmCacheOrder: [String] = []

    /// The system-LLM resolver, created lazily on first refine. Typed `Any?`
    /// because stored properties can't carry an `@available` type directly.
    private var llmResolverStorage: Any?
    private var llmResolverChecked = false

    init() {
        cjk = Space(language: .simplifiedChinese, examples: IntentExamples.chinese)
        latin = Space(language: .english, examples: IntentExamples.english)
    }

    // MARK: - Prepare (assets → load → train-or-restore the heads)

    /// Bring both spaces up: download embedding assets if the OS hasn't already,
    /// load the models, and fit (or restore from disk) the logistic heads. Safe
    /// to call repeatedly; runs once. Kick this off in the background at app
    /// launch — classification quietly returns `.empty` until it lands.
    ///
    /// `useDiskCache: false` is for the offline evaluation harness, which trains
    /// on deliberate subsets and must not poison the real cache.
    func prepare(useDiskCache: Bool = true) async {
        guard !prepared else { return }
        prepared = true
        for space in [cjk, latin].compactMap({ $0 }) {
            await prepareSpace(space, useDiskCache: useDiskCache)
        }
    }

    /// Evaluation entry: rebuild the spaces around injected example sets (e.g. a
    /// train split) and fit fresh heads, bypassing the disk cache entirely.
    func prepareForEvaluation(chinese: IntentExampleSet, english: IntentExampleSet) async {
        cjk = Space(language: .simplifiedChinese, examples: chinese)
        latin = Space(language: .english, examples: english)
        cache = [:]; cacheOrder = []
        prepared = true
        for space in [cjk, latin].compactMap({ $0 }) {
            await prepareSpace(space, useDiskCache: false)
        }
    }

    private func prepareSpace(_ space: Space, useDiskCache: Bool) async {
        guard space.state == .idle else { return }

        if !space.embedding.hasAvailableAssets {
            let available = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                space.embedding.requestAssets { result, _ in
                    cont.resume(returning: result == .available)
                }
            }
            guard available else { space.state = .unavailable; return }
        }
        do { try space.embedding.load() } catch {
            space.state = .unavailable
            return
        }

        // The cached fit is only valid for the exact embedding model revision
        // and training data it was fit against — both are baked into the key.
        let cacheURL = headCacheURL(for: space)
        if useDiskCache,
           let data = try? Data(contentsOf: cacheURL),
           let model = try? PropertyListDecoder().decode(FittedModel.self, from: data),
           model.head.weights.count == space.embedding.dimension * 2 {
            space.head = model.head
            space.noteVectors = model.noteVectors
            space.askVectors = model.askVectors
            space.state = .ready
            return
        }

        // Fit fresh: embed every example, then batch gradient descent for the
        // head. One-time cost (seconds, off the main thread).
        let noteVectors = space.examples.note.compactMap { sentenceVector($0, space: space) }
        let askVectors = space.examples.ask.compactMap { sentenceVector($0, space: space) }
        guard noteVectors.count > 10, askVectors.count > 10 else {
            space.state = .unavailable
            return
        }
        let head = LogisticHead.fit(positives: noteVectors, negatives: askVectors)
        space.head = head
        space.noteVectors = noteVectors
        space.askVectors = askVectors
        space.state = .ready

        if useDiskCache {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            if let data = try? encoder.encode(
                FittedModel(head: head, noteVectors: noteVectors, askVectors: askVectors)) {
                try? FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
        }
    }

    /// What gets cached to disk after a fit: the head plus the training
    /// embeddings the kNN vote needs. Binary plist, a few MB.
    private struct FittedModel: Codable {
        var head: LogisticHead
        var noteVectors: [[Double]]
        var askVectors: [[Double]]
    }

    /// Where this space's fitted head lives on disk. The filename hashes the
    /// embedding model's identity (identifier + revision) AND the training data,
    /// so an OS model update or an edit to `IntentExamples` silently invalidates
    /// the stale head and triggers a background refit on next launch.
    private func headCacheURL(for space: Space) -> URL {
        let dataDigest = SHA256.hash(data: Data(
            (space.examples.ask + ["␞"] + space.examples.note).joined(separator: "\n").utf8))
        let key = "\(space.embedding.modelIdentifier)|r\(space.embedding.revision)|\(dataDigest)"
        let keyDigest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16)
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent(
            "NotchGlass/IntentHeads/fit-\(space.language.rawValue)-\(keyDigest).plist")
    }

    // MARK: - Classify (the hot path)

    /// Score one line. Synchronous compute (~1 ms: one transformer embed + one
    /// dot product) but actor-isolated, so callers hop off the main thread by
    /// construction. Returns `.empty` (→ caller defaults to Ask) whenever there's
    /// no usable model — not ready yet, assets unavailable, embedding error.
    func classify(_ raw: String) -> Reading {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        if let hit = cache[text] { return hit }

        let space = Self.routesToCJK(text) ? cjk : latin
        guard let space, space.state == .ready, let head = space.head,
              let vector = sentenceVector(text, space: space) else {
            return .empty
        }

        let p = 0.5 * head.probability(vector)
              + 0.5 * Self.neighborVote(vector, space: space) // both P(note)
        let reading = Reading(
            intent: p >= 0.5 ? .note : .ask,
            confidence: abs(2 * p - 1),
            source: "embedding")
        remember(text, reading)
        return reading
    }

    /// kNN over the training embeddings: cosine similarity (vectors are unit
    /// length, so a dot product), top-k across both classes, similarity-weighted
    /// vote → P(note). ~600 dot products of 1024 dims — microseconds next to the
    /// ~11 ms the embedding itself costs.
    private static func neighborVote(_ vector: [Double], space: Space,
                                     k: Int = 9) -> Double {
        var scored: [(sim: Double, isNote: Bool)] = []
        scored.reserveCapacity(space.noteVectors.count + space.askVectors.count)
        let n = vDSP_Length(vector.count)
        for v in space.noteVectors {
            var sim = 0.0
            vDSP_dotprD(v, 1, vector, 1, &sim, n)
            scored.append((sim, true))
        }
        for v in space.askVectors {
            var sim = 0.0
            vDSP_dotprD(v, 1, vector, 1, &sim, n)
            scored.append((sim, false))
        }
        let top = scored.sorted { $0.sim > $1.sim }.prefix(k)
        // Sharpen: similarities cluster high, so vote on (sim − margin)₊.
        let floor = (top.map(\.sim).min() ?? 0) - 1e-9
        var noteMass = 0.0, totalMass = 0.0
        for (sim, isNote) in top {
            let w = sim - floor
            totalMass += w
            if isNote { noteMass += w }
        }
        guard totalMass > 0 else { return 0.5 }
        return noteMass / totalMass
    }

    private func remember(_ text: String, _ reading: Reading) {
        if cache[text] == nil {
            cacheOrder.append(text)
            if cacheOrder.count > cacheLimit {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
        }
        cache[text] = reading
    }

    /// Any Han / Kana / Hangul routes to the CJK embedding model (it's trained
    /// for those scripts and copes with embedded Latin tokens, e.g. "买 airpods");
    /// pure-Latin text takes the Latin model.
    private static func routesToCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,   // CJK ext A
                 0x4E00...0x9FFF,   // CJK unified
                 0xF900...0xFAFF,   // CJK compatibility
                 0x3040...0x30FF,   // Hiragana + Katakana
                 0xAC00...0xD7AF:   // Hangul
                return true
            default:
                return false
            }
        }
    }

    /// Sentence vector from the contextual embedding: mean-pool ⧺ max-pool over
    /// the token vectors (2× the model dimension), L2-normalized. Max-pooling
    /// preserves strong single-token cues ("吗", "remind", a wh-word) that a mean
    /// over a long line would wash out; the mean keeps the overall register.
    private func sentenceVector(_ text: String, space: Space) -> [Double]? {
        guard let result = try? space.embedding.embeddingResult(for: text,
                                                                language: space.language)
        else { return nil }
        let dimension = space.embedding.dimension
        var mean = [Double](repeating: 0, count: dimension)
        var peak = [Double](repeating: -.infinity, count: dimension)
        var tokens = 0.0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            vDSP.add(mean, vector, result: &mean)
            vDSP.maximum(peak, vector, result: &peak)
            tokens += 1
            return true
        }
        guard tokens > 0 else { return nil }
        vDSP.divide(mean, tokens, result: &mean)
        var combined = mean + peak
        let norm = sqrt(vDSP.sum(vDSP.multiply(combined, combined)))
        guard norm > 0 else { return nil }
        vDSP.divide(combined, norm, result: &combined)
        return combined
    }

    // MARK: - LLM second opinion (Apple Intelligence devices only)

    /// Ask the on-device system LLM to break a tie the embedding head wasn't
    /// confident about. Returns `nil` whenever that's not possible (pre-macOS 26,
    /// Apple Intelligence off/ineligible/region-blocked, model busy, error) —
    /// callers just keep the embedding reading. Expect a few hundred ms; only
    /// call this after the user has paused, never per keystroke.
    func refine(_ raw: String) async -> Reading? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let hit = llmCache[text] { return hit }

        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return nil }
        if !llmResolverChecked {
            llmResolverChecked = true
            llmResolverStorage = IntentLLMResolver.makeIfAvailable()
        }
        guard let resolver = llmResolverStorage as? IntentLLMResolver else { return nil }
        guard let intent = await resolver.classify(text) else { return nil }

        let reading = Reading(intent: intent, confidence: 1.0, source: "llm")
        llmCache[text] = reading
        llmCacheOrder.append(text)
        if llmCacheOrder.count > cacheLimit {
            llmCache.removeValue(forKey: llmCacheOrder.removeFirst())
        }
        return reading
        #else
        return nil
        #endif
    }
}

// MARK: - Logistic head

/// A logistic regression over the embedding space — the entire trainable part of
/// the classifier: 512 weights and a bias. Fit on-device with plain batch
/// gradient descent (vDSP-vectorized, so the one-time fit is fast even in Debug),
/// L2-regularized to keep it sane on a few hundred examples.
struct LogisticHead: Codable {
    var weights: [Double]
    var bias: Double

    /// P(positive class) — here, P(note).
    func probability(_ vector: [Double]) -> Double {
        var dot = 0.0
        vDSP_dotprD(weights, 1, vector, 1, &dot, vDSP_Length(min(weights.count, vector.count)))
        return 1.0 / (1.0 + exp(-(dot + bias)))
    }

    /// Fit by batch gradient descent: positives label 1, negatives label 0.
    /// Class imbalance is handled by per-class sample weights so neither side
    /// can win by volume alone.
    static func fit(positives: [[Double]], negatives: [[Double]],
                    epochs: Int = 4000, l2: Double = 1e-5) -> LogisticHead {
        let dimension = positives.first?.count ?? negatives.first?.count ?? 0
        let samples = positives.map { ($0, 1.0) } + negatives.map { ($0, 0.0) }
        let total = Double(samples.count)
        // Per-class weights: each class contributes half the gradient mass.
        let posWeight = total / (2.0 * Double(max(positives.count, 1)))
        let negWeight = total / (2.0 * Double(max(negatives.count, 1)))

        var weights = [Double](repeating: 0, count: dimension)
        var bias = 0.0
        var rate = 3.0

        for epoch in 0..<epochs {
            var gradW = [Double](repeating: 0, count: dimension)
            var gradB = 0.0
            for (x, y) in samples {
                var dot = 0.0
                vDSP_dotprD(weights, 1, x, 1, &dot, vDSP_Length(dimension))
                let p = 1.0 / (1.0 + exp(-(dot + bias)))
                var err = (p - y) * (y > 0.5 ? posWeight : negWeight)
                // gradW += err * x
                vDSP_vsmaD(x, 1, &err, gradW, 1, &gradW, 1, vDSP_Length(dimension))
                gradB += err
            }
            // weights -= rate * (gradW / n + l2 * weights)
            var scale = -rate / total
            vDSP_vsmaD(gradW, 1, &scale, weights, 1, &weights, 1, vDSP_Length(dimension))
            var decay = 1.0 - rate * l2
            vDSP_vsmulD(weights, 1, &decay, &weights, 1, vDSP_Length(dimension))
            bias -= rate * gradB / total
            // Step the rate down as it converges.
            if (epoch + 1) % 1000 == 0 { rate *= 0.5 }
        }
        return LogisticHead(weights: weights, bias: bias)
    }
}

// MARK: - FoundationModels resolver

#if canImport(FoundationModels)
/// Wraps the Apple Intelligence on-device LLM as a binary classifier with guided
/// generation — the model literally cannot answer anything but `ask` or `note`.
@available(macOS 26.0, *)
private final class IntentLLMResolver {
    @Generable
    enum Verdict: String {
        case ask
        case note
    }

    private let session: LanguageModelSession

    /// `nil` unless the system model is actually usable right now (Apple
    /// Intelligence enabled, device eligible, region allowed, model downloaded).
    static func makeIfAvailable() -> IntentLLMResolver? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        return IntentLLMResolver()
    }

    private init() {
        session = LanguageModelSession(instructions: """
            You route single lines typed into a Mac quick-input bar.
            Answer `ask` when the line is a question, a task the person wants \
            an AI assistant to do (explain, write, translate, look up, compute), \
            or a greeting / social / meta line addressed to the assistant \
            (hello, thanks, who are you, continue).
            Answer `note` when the line is something the person is writing down \
            for themselves to keep: a todo, reminder, appointment, idea, \
            shopping item, password, measurement, or log entry.
            Lines may be in Chinese or English.
            """)
        session.prewarm()
    }

    func classify(_ text: String) async -> IntentEngine.Intent? {
        // One request at a time; if a previous refine is still streaming, skip —
        // the caller keeps the embedding verdict, which is never wrong-by-much.
        guard !session.isResponding else { return nil }
        do {
            let response = try await session.respond(to: text, generating: Verdict.self)
            switch response.content {
            case .ask: return .ask
            case .note: return .note
            }
        } catch {
            return nil
        }
    }
}
#endif
