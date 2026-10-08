import Foundation
import TabTypeKit

/// The v2 engine: llama.cpp + the confidence-scored decoder. Its output is the exact
/// text to insert (the typed partial word is already healed and spacing resolved),
/// so `Engine` must not run v1's echo/assistant-speak/mid-word repair on it.
@MainActor
final class LlamaEngine: SuggestionEngine {
    let displayName = "Local model"
    let models: LlamaModelManager
    var onLateSuggestion: ((String, CompletionRequest) -> Void)?

    /// The most recent shown-or-gated result, for the word picker's alternatives.
    private(set) var lastResult: TabTypeKit.CompletionResult?

    init(models: LlamaModelManager = .shared) {
        self.models = models
    }

    var isReady: Bool { models.isLoaded }

    func cancelInFlight() { _ = models.inference.beginRequest() }

    func complete(_ request: CompletionRequest) async -> String? {
        guard let template = models.template, var options = models.decoderOptions else { return nil }
        let text = PromptAssembler(template: template).assemble(context(for: request))

        // Warm-ups (`maxTokens <= 1`) only prefill the prompt into the cache.
        if request.maxTokens <= 1 {
            try? await models.inference.warmUp(text)
            return nil
        }

        options.maxWords = max(1, request.maxWords)
        let id = models.inference.beginRequest()
        let start = Date()
        guard let result = try? await models.inference.complete(text, options: options, requestID: id) else {
            return nil   // superseded by a newer keystroke, or not loaded
        }
        lastResult = result
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        guard result.confidence >= options.showThreshold else {
            Log.shared.debug("v2: \"\(result.text)\" below threshold (conf \(String(format: "%.2f", result.confidence)) < \(options.showThreshold)) \(ms)ms")
            Statistics.shared.record(.belowConfidence)
            return nil
        }
        Log.shared.debug("v2: \"\(result.text)\" conf \(String(format: "%.2f", result.confidence)) · \(result.promptTokens) prompt tokens · \(ms)ms")
        return result.text
    }

    private func context(for request: CompletionRequest) -> PromptContext {
        var screen = request.screenContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if screen.isEmpty { screen = request.documentStart.trimmingCharacters(in: .whitespacesAndNewlines) }
        let instructions = request.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return PromptContext(
            typedText: request.beforeCursor,
            appName: request.appName.isEmpty ? nil : request.appName,
            authorName: request.authorName.isEmpty ? nil : request.authorName,
            customInstructions: instructions.isEmpty ? nil : instructions,
            screenText: screen.isEmpty ? nil : screen,
            isConversation: request.screenIsConversation,
            clipboard: request.clipboard.isEmpty ? nil : request.clipboard)
    }
}
