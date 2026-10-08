import Foundation
import TabTypeKit

/// Headless quality run of the v1 (MLX) pipeline over an eval case file, so v2 has a
/// measured baseline. Launched as:
///   TabType.app/Contents/MacOS/TabType --eval <cases.jsonl> [--out run.json] [--model <id>]
@MainActor
enum EvalMode {
    static func isRequested(_ arguments: [String]) -> Bool { arguments.contains("--eval") }

    static func start(arguments: [String]) {
        func option(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        Task { @MainActor in
            do {
                guard let casesPath = option("--eval") else { throw EvalModeError("--eval needs a cases .jsonl path") }
                let modelId = option("--model") ?? AppSettings.shared.modelId
                let provider = ModelProvider.shared
                print("loading \(modelId)…")
                provider.load(modelId: modelId)
                while !provider.isReady {
                    if case .failed(_, let message) = provider.state { throw EvalModeError("model load failed: \(message)") }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                let cases = try JSONL.read(EvalCase.self, from: URL(fileURLWithPath: casesPath))
                let backend = V1PipelineBackend(modelId: modelId, provider: provider)
                let run = try await EvalRunner.run(cases, backend: backend) { done, total in
                    if done % 25 == 0 || done == total { print("  \(done)/\(total)") }
                }
                let out = URL(fileURLWithPath: option("--out") ?? "eval/results/v1-\(Int(Date().timeIntervalSince1970)).json")
                try EvalRunner.write(run, to: out)
                print(EvalReport.render(run))
                print("results → \(out.path)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("eval failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }
}

private struct EvalModeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Runs a case through exactly what v1 does at runtime: the MLX engine (prompt
/// builder, sampling, trimming) followed by Engine's post-processing filters and
/// mid-word reconciliation.
@MainActor
final class V1PipelineBackend: CompletionBackend {
    let name = "v1-mlx"
    let model: String
    private let engine: MLXEngine
    private let settings = AppSettings.shared

    init(modelId: String, provider: ModelProvider) {
        model = modelId
        engine = MLXEngine(provider: provider)
    }

    func complete(_ evalCase: EvalCase) async throws -> String? {
        let prefix = evalCase.prefix
        let request = CompletionRequest(
            beforeCursor: prefix,
            afterCursor: "",
            screenContext: evalCase.context,
            screenIsConversation: evalCase.category == "chat",
            maxWords: settings.maxWords,
            maxTokens: settings.maxTokens,
            temperature: settings.temperature)
        guard let raw = await engine.complete(request), !raw.isEmpty,
              let deEchoed = Engine.stripEcho(raw, prefix: prefix),
              let clean = Engine.stripAssistantSpeak(deEchoed, inputTail: String(prefix.suffix(10))) else {
            return nil
        }
        let suggestion = Engine.reconcile(clean, prefix: prefix)
        guard let last = prefix.last, last.isLetter || last.isNumber else { return suggestion }
        return await reconcileMidWord(suggestion, prefix: prefix, context: evalCase.context)
    }

    /// Same decision order as `Engine.reconcileMidWord`.
    private func reconcileMidWord(_ suggestion: String, prefix: String, context: String) async -> String? {
        let noLeadingSpace = suggestion.hasPrefix(" ") ? String(suggestion.dropFirst()) : suggestion
        guard !noLeadingSpace.isEmpty else { return nil }
        let partial = String(prefix.reversed().prefix { $0.isLetter }.reversed())
        let fragment = String(noLeadingSpace.prefix { $0.isLetter || $0 == "'" })
        if let stripped = Engine.stripPartialOverlap(suggestion: noLeadingSpace, partial: partial, fragment: fragment) {
            return stripped.isEmpty ? nil : stripped
        }
        let language = settings.autocorrectLanguage
        if await SpellChecker.shared.isPlausibleContinuation(partial: partial, fragment: fragment, language: language) {
            return noLeadingSpace
        }
        let joined = (partial + fragment).lowercased()
        if !partial.isEmpty, joined.count >= 3,
           context.lowercased().contains(joined) || prefix.dropLast(partial.count).lowercased().contains(joined) {
            return noLeadingSpace
        }
        guard await SpellChecker.shared.isPlausibleContinuation(partial: "", fragment: fragment, language: language) else {
            return nil
        }
        return " " + noLeadingSpace
    }
}
