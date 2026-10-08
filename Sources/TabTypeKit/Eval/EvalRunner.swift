import Foundation

/// Anything that can turn a case into a suggestion — the v1 MLX pipeline (app
/// `--eval` mode) or a v2 llama.cpp backend (`tabtype-eval`).
@MainActor
public protocol CompletionBackend: AnyObject {
    var name: String { get }
    var model: String { get }
    /// The text to insert at the caret, or nil/empty when nothing would be shown.
    func complete(_ evalCase: EvalCase) async throws -> String?
}

public enum EvalRunner {
    @MainActor
    public static func run(_ cases: [EvalCase], backend: CompletionBackend,
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
                latencyMs: ms))
            progress?(i + 1, cases.count)
        }
        return EvalRun(backend: backend.name, model: backend.model,
                       summary: EvalSummary(results: results), results: results)
    }

    public static func write(_ run: EvalRun, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(run).write(to: url)
    }

    public static func load(_ url: URL) throws -> EvalRun {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EvalRun.self, from: Data(contentsOf: url))
    }
}
