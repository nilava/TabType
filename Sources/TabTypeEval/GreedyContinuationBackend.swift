import Foundation
import TabTypeKit

/// Phase 0 spike backend: plain greedy continuation of a base model on a simple
/// document-style prompt. Deliberately naive — no token healing, candidates, or
/// confidence gate — so it measures the raw engine + prompt shape that the v2
/// decoder will build on.
@MainActor
final class GreedyContinuationBackend: CompletionBackend {
    let name = "llama-greedy"
    let model: String
    private let runtime: LlamaRuntime
    private let maxTokens = 16
    private let maxWords = 6

    init(modelPath: String) throws {
        runtime = try LlamaRuntime(modelPath: modelPath)
        model = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
    }

    func complete(_ evalCase: EvalCase) async throws -> String? {
        // Minimal boundary healing: a prompt ending in a bare space tokenizes into
        // an unnatural final token and the model mostly emits nothing. End the
        // prompt at the last word instead; the model then generates " next…" and
        // the leading space is dropped below. (Mid-word healing is Phase 2.)
        var prompt = Self.prompt(for: evalCase)
        while prompt.last == " " { prompt.removeLast() }
        let promptTokens = runtime.tokenize(prompt, addSpecial: true)
        guard !promptTokens.isEmpty else { return nil }
        defer { runtime.truncate(to: promptTokens.count) }

        var logits = try runtime.evaluate(promptTokens)
        var bytes: [UInt8] = []
        for _ in 0..<maxTokens {
            let token = runtime.argmax(logits)
            if runtime.isEndOfGeneration(token) || runtime.isControl(token) { break }
            bytes += runtime.pieceBytes(token)
            let text = String(decoding: bytes, as: UTF8.self)
            if text.contains("\n") || Self.wordCount(text) > maxWords { break }
            logits = try runtime.append(token)
        }
        var text = String(decoding: bytes, as: UTF8.self)
        if let newline = text.firstIndex(of: "\n") { text = String(text[..<newline]) }
        // Keep at most `maxWords` words, preserving the leading space.
        let words = EvalScorer.chunks(text)
        text = words.prefix(maxWords).joined()
        // A boundary prefix already ends in a space; don't double it.
        if evalCase.prefix.last?.isWhitespace == true {
            text = String(text.drop(while: { $0 == " " }))
        }
        return text
    }

    /// The typed text continued as a document, with any on-screen context above it.
    static func prompt(for evalCase: EvalCase) -> String {
        let context = evalCase.context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.isEmpty else { return evalCase.prefix }
        if evalCase.category == "chat" {
            return context + "\nMe: " + evalCase.prefix
        }
        return context + "\n\n" + evalCase.prefix
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
