import Foundation

/// Anything that can turn a case into a suggestion — the v1 MLX pipeline (app
/// `--eval` mode) or a v2 llama.cpp backend (`tabtype-eval`).
@MainActor
public protocol CompletionBackend: AnyObject {
    var name: String { get }
    var model: String { get }
    /// The text to insert at the caret, or nil/empty when nothing would be shown.
    func complete(_ evalCase: EvalCase) async throws -> String?
    /// Confidence of the most recent `complete` result, if the backend scores one.
    var lastConfidence: Double? { get }
    var lastWords: [WordScore]? { get }
    var lastFollowsHint: Bool { get }
    var lastHintSupport: Int { get }
}

extension CompletionBackend {
    public var lastConfidence: Double? { nil }
    public var lastWords: [WordScore]? { nil }
    public var lastFollowsHint: Bool { false }
    public var lastHintSupport: Int { 0 }
}

public enum EvalRunner {
    @MainActor
    public static func run(_ cases: [EvalCase], backend: CompletionBackend,
                           configuration: [String: String]? = nil,
                           progress: ((Int, Int) -> Void)? = nil) async throws -> EvalRun {
        var results: [CaseResult] = []
        results.reserveCapacity(cases.count)
        for (i, c) in cases.enumerated() {
            let start = DispatchTime.now().uptimeNanoseconds
            let suggestion = try await backend.complete(c) ?? ""
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            results.append(CaseResult(
                id: c.id, category: c.category, kind: c.kind, suggestion: suggestion,
                truth: c.truth, score: EvalScorer.score(suggestion: suggestion, truth: c.truth),
                latencyMs: ms, confidence: backend.lastConfidence, words: backend.lastWords,
                followsHint: backend.lastWords == nil ? nil : backend.lastFollowsHint,
                hintSupport: backend.lastWords == nil ? nil : backend.lastHintSupport,
                midword: PredictionStyle.isMidword(c.prefix)))
            progress?(i + 1, cases.count)
        }
        return EvalRun(backend: backend.name, model: backend.model,
                       summary: EvalSummary(results: results), results: results, configuration: configuration)
    }

    public static func write(_ run: EvalRun, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(run).write(to: url)
    }

    /// Re-scores a run as if suggestions below each confidence threshold had not
    /// been shown. Requires a run whose backend reported confidences.
    public static func sweep(_ run: EvalRun, thresholds: [Double]) -> [(threshold: Double, summary: EvalSummary)] {
        thresholds.map { t in
            let gated = run.results.map { r -> CaseResult in
                guard let c = r.confidence, c < t else { return r }
                var hidden = r
                hidden.suggestion = ""
                hidden.score = EvalScorer.score(suggestion: "", truth: r.truth)
                return hidden
            }
            return (t, EvalSummary(results: gated))
        }
    }

    public static func load(_ url: URL) throws -> EvalRun {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EvalRun.self, from: Data(contentsOf: url))
    }

    public enum ReplayError: Error { case incompleteWordScores }

    /// Replay output trimming/gating on the same phrase search. Latencies remain
    /// the original measurements, not fresh per-style timing samples.
    public static func replay(_ run: EvalRun, style: PredictionStyle, baseThreshold: Double,
                              repeatedPhraseFactor: Double = 0.5) throws -> EvalRun {
        guard let extensionValue = run.configuration?["extensionThreshold"].flatMap(Double.init),
              extensionValue == 0 else { throw ReplayError.incompleteWordScores }
        let results = try run.results.map { result -> CaseResult in
            guard let words = result.words, let confidence = result.confidence else {
                throw ReplayError.incompleteWordScores
            }
            var replayed = result
            let threshold = style.threshold(base: baseThreshold,
                midword: result.midword ?? (result.kind == .midword),
                followsHint: result.followsHint ?? false, hintSupport: result.hintSupport ?? 0,
                repeatedPhraseFactor: repeatedPhraseFactor)
            replayed.suggestion = confidence >= threshold
                ? ScoredPhrase.prefix(words, extensionThreshold: style.extensionThreshold).map(\.text).joined() : ""
            replayed.score = EvalScorer.score(suggestion: replayed.suggestion, truth: replayed.truth)
            return replayed
        }
        var configuration = run.configuration ?? [:]
        configuration["replayStyle"] = style.rawValue
        configuration["baseShowThreshold"] = String(baseThreshold)
        configuration["repeatedPhraseFactor"] = String(repeatedPhraseFactor)
        configuration["latencySource"] = "original inference run"
        return EvalRun(backend: run.backend + "/replay-" + style.rawValue, model: run.model, date: run.date,
            summary: EvalSummary(results: results), results: results, configuration: configuration)
    }
}
