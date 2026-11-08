import Foundation
import TabTypeKit

/// The suggestion engine: llama.cpp + the confidence-scored decoder. Its output is
/// the exact text to insert (the typed partial word is already healed and spacing
/// resolved).
@MainActor
final class LlamaEngine {
    let displayName = "Local model"
    let models: LlamaModelManager

    /// The most recent shown-or-gated result, for the word picker's alternatives.
    private(set) var lastResult: TabTypeKit.CompletionResult?

    /// Recent results by exact prompt + options: re-typing, deleting back, or a
    /// repeat request for unchanged input is answered without running the model.
    private var recent = CompletionCache()

    init(models: LlamaModelManager = .shared) {
        self.models = models
    }

    var isReady: Bool { models.isLoaded }

    func cancelInFlight() { _ = models.inference.beginRequest() }

    func complete(_ request: CompletionRequest) async -> String? {
        guard let template = models.template, var options = models.decoderOptions else { return nil }
        let style = request.predictionStyle
            ?? AppSettings.shared.predictionStyle
        options.extensionThreshold = style.extensionThreshold
        let text = PromptAssembler(template: template, situationHeader: true).assemble(context(for: request))

        // Warm-ups only prefill the prompt into the cache.
        if request.warmUpOnly {
            try? await models.inference.warmUp(text)
            return nil
        }

        options.maxWords = max(1, request.maxWords)
        // What the author wrote after these words before, if they opted in.
        var hintSupport = 0
        if let hint = PersonalIndex.shared.hint(after: request.beforeCursor, bundleId: request.appBundleId ?? "",
            scope: AppSettings.shared.personalizationScope, enabled: request.learnsFromWriting) {
            options.hint = Array(hint.text.utf8)
            options.hintBonus = AppSettings.shared.personalization.bonus
            hintSupport = hint.support
        }
        let cacheKey = CompletionCache.Key(modelID: models.loadedID ?? "", options: options, prompt: text)
        let start = Date()
        let result: TabTypeKit.CompletionResult
        let cached: Bool
        if let hit = recent.result(for: cacheKey) {
            _ = models.inference.beginRequest()   // still supersedes older work
            result = hit
            cached = true
        } else {
            let id = models.inference.beginRequest()
            guard let fresh = try? await models.inference.complete(text, options: options, requestID: id) else {
                return nil   // superseded by a newer keystroke, or not loaded
            }
            result = fresh
            cached = false
        }
        if !cached { recent.insert(result, for: cacheKey) }
        lastResult = result
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        // Shared with the evaluator: Balanced retains the historical boundary
        // and midword bars; the other styles trade suggestion frequency for
        // precision. The model's first-word confidence is not a correctness rate.
        let midWord = PredictionStyle.isMidword(request.beforeCursor)
        // Repeated learned phrases keep the existing personalization discount.
        let threshold = style.threshold(base: options.showThreshold, midword: midWord,
            followsHint: result.followsHint, hintSupport: hintSupport,
            repeatedPhraseFactor: AppSettings.shared.personalization.repeatedPhraseBar)
        // Lookahead (speculative) results stay out of the statistics.
        let quiet = request.speculative
        guard result.confidence >= threshold else {
            if quiet { return nil }
            Log.shared.debug("v2: \"\(result.text)\" below threshold (conf \(String(format: "%.2f", result.confidence)) < \(String(format: "%.2f", threshold))) \(ms)ms\(cached ? " [cached]" : "")")
            Statistics.shared.record(.belowConfidence)
            return nil
        }
        if quiet { return result.text }
        Statistics.shared.recordLatency(ms: ms)
        Log.shared.debug("v2: \"\(result.text)\" conf \(String(format: "%.2f", result.confidence))\(result.followsHint ? " · from your writing" : "") · \(result.promptTokens) prompt tokens · \(ms)ms\(cached ? " [cached]" : "")")
        return result.text
    }

    /// Forget cached results (model or settings changed).
    func clearRecent() {
        lastResult = nil
        recent.removeAll()
    }

    /// Words that fit in place of `word`, given the text before it — the word
    /// picker's synonyms for a selection. `base` supplies the screen/app context.
    func synonyms(for word: String, before: String, after: String, base: CompletionRequest?) async -> [String] {
        guard let template = models.template else { return [] }
        var request = base ?? CompletionRequest(beforeCursor: before, afterCursor: "", screenContext: "", maxWords: 1)
        request.beforeCursor = before
        let text = PromptAssembler(template: template, situationHeader: true).assemble(context(for: request))
        let id = models.inference.beginRequest()
        let words = (try? await models.inference.replacements(before: text, selected: word, after: after,
                                                                count: 4, requestID: id)) ?? []
        return words.map(\.text)
    }

    private func context(for request: CompletionRequest) -> PromptContext {
        var screen = request.screenContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if screen.isEmpty { screen = request.documentStart.trimmingCharacters(in: .whitespacesAndNewlines) }
        screen = SecretSanitizer.sanitize(screen)
        let clipboard = SecretSanitizer.sanitize(request.clipboard)
        let instructions = request.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return PromptContext(
            typedText: Self.sanitizeEarlierLines(request.beforeCursor),
            appName: request.appName.isEmpty ? nil : request.appName,
            windowTitle: request.windowTitle.isEmpty ? nil : request.windowTitle,
            fieldPlaceholder: request.fieldPlaceholder.isEmpty ? nil : request.fieldPlaceholder,
            authorName: request.authorName.isEmpty ? nil : request.authorName,
            customInstructions: instructions.isEmpty ? nil : instructions,
            screenText: screen.isEmpty ? nil : screen,
            isConversation: request.screenIsConversation,
            clipboard: clipboard.isEmpty ? nil : clipboard)
    }

    /// Scrubs secrets from earlier lines of the field but leaves the line being typed
    /// exactly as is — it's what gets continued, and token healing needs its bytes.
    static func sanitizeEarlierLines(_ text: String) -> String {
        guard let newline = text.lastIndex(of: "\n") else { return text }
        return SecretSanitizer.sanitize(String(text[...newline])) + text[text.index(after: newline)...]
    }
}
