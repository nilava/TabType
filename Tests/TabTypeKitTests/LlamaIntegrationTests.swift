import XCTest
@testable import TabTypeKit

/// Runs against every GGUF in the repo's `models/` folder (gitignored); skipped when
/// there are none, so CI without models stays green. Covers both tokenizer families
/// when present (SentencePiece/Gemma and byte-level BPE/Qwen).
final class LlamaIntegrationTests: XCTestCase {
    nonisolated(unsafe) private static var runtimes: [String: LlamaRuntime] = [:]

    /// ggml aborts at process exit if a Metal-backed model is still alive.
    override class func tearDown() {
        runtimes.removeAll()
        super.tearDown()
    }

    private static var modelPaths: [String] {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = repo.appendingPathComponent("models")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".gguf") }.sorted().map { dir.appendingPathComponent($0).path }
    }

    private func eachModel(_ body: (LlamaRuntime) throws -> Void) throws {
        let paths = Self.modelPaths
        guard !paths.isEmpty else { throw XCTSkip("no GGUF models in models/") }
        for path in paths {
            let runtime = try Self.runtimes[path] ?? LlamaRuntime(modelPath: path)
            Self.runtimes[path] = runtime
            try body(runtime)
        }
    }

    func testTokenizationRoundTrips() throws {
        let samples = ["Hello, world!", "I'll take a look at it.", "naïve café — 10% off",
                       "  leading spaces", "line one\nline two", "emoji 👍🏽 ok", "Nilava's PR #2276"]
        try eachModel { runtime in
            for s in samples {
                XCTAssertEqual(runtime.detokenize(runtime.tokenize(s, addSpecial: false, parseSpecial: false)), s,
                               "\(runtime.modelDescription): \(s)")
            }
        }
    }

    /// Logits after reusing a cached prefix must match logits computed from scratch.
    func testPrefixReuseMatchesFreshEvaluation() throws {
        try eachModel { runtime in
            let a = runtime.tokenize("The quarterly planning session is scheduled for Monday", addSpecial: true)
            let b = runtime.tokenize("The quarterly planning session is scheduled for Monday at ten in the large room", addSpecial: true)
            runtime.reset()
            _ = try runtime.evaluatePrompt(a)
            let reused = Array(try runtime.evaluatePrompt(b).values)
            XCTAssertLessThan(runtime.lastPrefillCount, b.count, "cache was not reused")
            runtime.reset()
            let fresh = Array(try runtime.evaluatePrompt(b).values)
            XCTAssertEqual(argmax(reused), argmax(fresh), runtime.modelDescription)
            XCTAssertLessThan(maxTopDifference(reused, fresh), 0.1, runtime.modelDescription)
        }
    }

    /// Removing a span from the middle of the prompt: the spliced cache is an
    /// approximation (kept tokens attended to the removed span), so require the
    /// same top prediction and a mostly shared top-5, not identical logits.
    func testSpliceMatchesFreshEvaluation() throws {
        try eachModel { runtime in
            guard runtime.supportsSplice else { return }
            let head = "Notes from the vendor call. "
            let removed = "They mentioned several unrelated things about their office move and new hires. "
            let rest = "The vendor agreed to reduce the setup fee if we sign for two years, and they will send a revised quote by Thursday"
            runtime.reset()
            _ = try runtime.evaluatePrompt(runtime.tokenize(head + removed + rest, addSpecial: true))
            let target = runtime.tokenize(head + rest, addSpecial: true)
            let spliced = Array(try runtime.evaluatePrompt(target, allowSplice: true).values)
            XCTAssertLessThan(runtime.lastPrefillCount, 8, "splice did not reuse the tail")
            runtime.reset()
            let fresh = Array(try runtime.evaluatePrompt(target).values)
            XCTAssertEqual(argmax(spliced), argmax(fresh), runtime.modelDescription)
            XCTAssertGreaterThanOrEqual(Set(top(spliced, 5)).intersection(top(fresh, 5)).count, 4,
                                        runtime.modelDescription)
        }
    }

    func testDecoderHealsAPartialWordAndIsDeterministic() throws {
        try eachModel { runtime in
            let text = "Before we sign, could you please doub"
            let first = try XCTUnwrap(CompletionDecoder.complete(text, model: runtime), runtime.modelDescription)
            let word = "doub" + (first.text.split(separator: " ").first.map(String.init) ?? "")
            XCTAssertTrue(word.hasPrefix("double") || word.hasPrefix("doubt"),
                          "\(runtime.modelDescription) healed to \(word)")
            // Same choices every time. Probabilities may differ in the 3rd decimal:
            // a cached prompt is computed in a different batch shape on the GPU.
            let second = try XCTUnwrap(CompletionDecoder.complete(text, model: runtime))
            XCTAssertEqual(first.text, second.text, "decoding must be deterministic")
            XCTAssertEqual(first.confidence, second.confidence, accuracy: 0.01)
        }
    }

    func testWordsThatFitReplaceASelectedWord() throws {
        try eachModel { runtime in
            let words = try CompletionDecoder.replacements(before: "Thanks a lot for the ", selected: "quick",
                                                           after: " turnaround on the contract.", model: runtime)
            XCTAssertFalse(words.isEmpty, runtime.modelDescription)
            XCTAssertFalse(words.contains { $0.text.lowercased() == "quick" })
            print("SYNONYMS \(runtime.modelDescription): \(words.map(\.text))")
        }
    }

    func testInvalidAdapterIsRejectedAndModelKeepsWorking() throws {
        try eachModel { runtime in
            let notAnAdapter = FileManager.default.temporaryDirectory.appendingPathComponent("not-an-adapter.gguf")
            try Data("GGUF but not really".utf8).write(to: notAnAdapter)
            defer { try? FileManager.default.removeItem(at: notAnAdapter) }
            XCTAssertThrowsError(try runtime.setAdapter(path: notAnAdapter.path))
            XCTAssertNil(runtime.adapterPath)
            XCTAssertNotNil(try CompletionDecoder.complete("Thanks for the update ", model: runtime))
            try runtime.setAdapter(path: nil)
        }
    }

    /// Opt-in: TABTYPE_TEST_ADAPTER=<lora.gguf> TABTYPE_TEST_ADAPTER_MODEL=<substring of model file>.
    func testAdapterChangesPredictionsAndClears() throws {
        let env = ProcessInfo.processInfo.environment
        guard let adapter = env["TABTYPE_TEST_ADAPTER"], let match = env["TABTYPE_TEST_ADAPTER_MODEL"],
              let path = Self.modelPaths.first(where: { $0.contains(match) }) else { throw XCTSkip("no adapter") }
        let runtime = try Self.runtimes[path] ?? LlamaRuntime(modelPath: path)
        Self.runtimes[path] = runtime
        let tokens = runtime.tokenize("Write a short poem about the sea.\n", addSpecial: true)
        runtime.reset()
        let base = Array(try runtime.evaluatePrompt(tokens).values)
        try runtime.setAdapter(path: adapter)
        XCTAssertEqual(runtime.adapterPath, adapter)
        let adapted = Array(try runtime.evaluatePrompt(tokens).values)
        let delta = zip(base, adapted).map { abs($0 - $1) }.max() ?? 0
        XCTAssertGreaterThan(delta, 0.05, "adapter had no effect")
        XCTAssertNotNil(try CompletionDecoder.complete("Thanks for the update ", model: runtime))
        try runtime.setAdapter(path: nil)
        let restored = Array(try runtime.evaluatePrompt(tokens).values)
        XCTAssertLessThan(zip(base, restored).map { abs($0 - $1) }.max() ?? 1, 0.1, "clearing didn't restore the base model")
        print("ADAPTER max logit change \(delta)")
    }

    func testInferenceEngineDropsSupersededRequests() async throws {
        guard let path = Self.modelPaths.first else { throw XCTSkip("no GGUF models in models/") }
        let engine = InferenceEngine()
        try await engine.load(modelPath: path)
        let stale = engine.beginRequest()
        let current = engine.beginRequest()
        let staleResult = try await engine.complete("Thanks for the update ", options: DecoderOptions(), requestID: stale)
        XCTAssertNil(staleResult)
        let currentResult = try await engine.complete("Thanks for the update ", options: DecoderOptions(), requestID: current)
        XCTAssertNotNil(currentResult)
        await engine.unload()
        let afterUnload = await engine.isReady
        XCTAssertFalse(afterUnload)
    }

    private func argmax(_ v: [Float]) -> Int { v.indices.max { v[$0] < v[$1] }! }
    private func top(_ v: [Float], _ k: Int) -> [Int] { Array(v.indices.sorted { v[$0] > v[$1] }.prefix(k)) }

    /// Largest logit difference among the fresh run's 20 most likely tokens.
    private func maxTopDifference(_ a: [Float], _ b: [Float]) -> Float {
        let top = b.indices.sorted { b[$0] > b[$1] }.prefix(20)
        return top.map { abs(a[$0] - b[$0]) }.max() ?? 0
    }
}
