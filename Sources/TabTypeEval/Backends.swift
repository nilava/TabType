import Foundation
import TabTypeKit

/// Document-style prompt shared by the llama backends until Phase 3 brings real
/// per-model prompting: on-screen context above, the typed text continued below.
enum EvalPrompt {
    static func document(for evalCase: EvalCase) -> String {
        let context = evalCase.context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.isEmpty else { return evalCase.prefix }
        if evalCase.category == "chat" {
            return context + "\nMe: " + evalCase.prefix
        }
        return context + "\n\n" + evalCase.prefix
    }
}

/// v2 decoder: token healing, parallel candidates, confidence scoring, phrase
/// extension. Shows the suggestion only when confidence ≥ `threshold`; records the
/// confidence either way so `sweep` can retune the threshold offline.
@MainActor
final class DecoderBackend: CompletionBackend {
    let name = "llama-decoder"
    let model: String
    private let runtime: LlamaRuntime
    private let options: DecoderOptions
    private let threshold: Double
    private(set) var lastConfidence: Double?

    init(runtime: LlamaRuntime, options: DecoderOptions, threshold: Double) {
        self.runtime = runtime
        self.options = options
        self.threshold = threshold
        model = URL(fileURLWithPath: runtime.modelPath).deletingPathExtension().lastPathComponent
    }

    func complete(_ evalCase: EvalCase) async throws -> String? {
        let result = try CompletionDecoder.complete(EvalPrompt.document(for: evalCase),
                                                    model: runtime, options: options)
        lastConfidence = result?.confidence ?? 0
        guard let result, result.confidence >= threshold else { return nil }
        return result.text
    }
}

/// Phase 0 reference: plain greedy continuation with boundary-only healing — kept so
/// decoder gains stay measurable against the raw engine.
@MainActor
final class GreedyContinuationBackend: CompletionBackend {
    let name = "llama-greedy"
    let model: String
    private let runtime: LlamaRuntime
    private let maxTokens = 16
    private let maxWords = 6

    init(runtime: LlamaRuntime) {
        self.runtime = runtime
        model = URL(fileURLWithPath: runtime.modelPath).deletingPathExtension().lastPathComponent
    }

    func complete(_ evalCase: EvalCase) async throws -> String? {
        var prompt = EvalPrompt.document(for: evalCase)
        while prompt.last == " " { prompt.removeLast() }
        let promptTokens = runtime.tokenize(prompt, addSpecial: true)
        guard !promptTokens.isEmpty else { return nil }
        let vocab = runtime.vocab
        var logits = try runtime.evaluatePrompt(promptTokens)
        runtime.fork(to: 1)
        defer { runtime.drop(sequence: 1) }
        var bytes: [UInt8] = []
        var position = promptTokens.count
        for _ in 0..<maxTokens {
            var best = 0
            for i in 0..<logits.values.count where logits.values[i] > logits.values[best] { best = i }
            if vocab.blocked[best] { break }
            bytes += vocab.pieces[best]
            let text = String(decoding: bytes, as: UTF8.self)
            if text.contains("\n") || text.split(whereSeparator: { $0.isWhitespace }).count > maxWords { break }
            logits = try runtime.decode([BatchEntry(token: TokenID(best), position: position, sequence: 1)])[0]
            position += 1
        }
        var text = String(decoding: bytes, as: UTF8.self)
        if let newline = text.firstIndex(of: "\n") { text = String(text[..<newline]) }
        text = EvalScorer.chunks(text).prefix(maxWords).joined()
        if evalCase.prefix.last?.isWhitespace == true {
            text = String(text.drop(while: { $0 == " " }))
        }
        return text
    }
}
