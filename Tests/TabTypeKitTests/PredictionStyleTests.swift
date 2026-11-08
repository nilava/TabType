import XCTest
@testable import TabTypeKit

final class PredictionStyleTests: XCTestCase {
    func testBalancedPreservesBoundaryMidwordAndRepeatedPhraseDecisions() {
        let style = PredictionStyle.balanced
        XCTAssertLessThan(0.1, style.threshold(base: 0.2, midword: false))
        XCTAssertGreaterThan(0.1, style.threshold(base: 0.2, midword: true))
        XCTAssertLessThan(0.1, style.threshold(base: 0.2, midword: false, followsHint: true, hintSupport: 1))
        XCTAssertGreaterThan(0.1, style.threshold(base: 0.2, midword: false, followsHint: true, hintSupport: 2))
    }

    func testOnlyLettersAndNumbersUseTheMidwordGate() {
        for prefix in ["a caf", "café", "version 2"] { XCTAssertTrue(PredictionStyle.isMidword(prefix)) }
        for prefix in ["", "hello ", "hello\n", "hello."] { XCTAssertFalse(PredictionStyle.isMidword(prefix)) }
    }

    func testWeakWordStopsTheWholeTail() {
        let words = [WordScore(text: "today", probability: 0.7), WordScore(text: " after", probability: 0.2),
                     WordScore(text: " lunch", probability: 0.03), WordScore(text: " together", probability: 0.9)]
        XCTAssertEqual(ScoredPhrase.prefix(words, extensionThreshold: 0.05).map(\.text), ["today", " after"])
        XCTAssertEqual(ScoredPhrase.prefix([], extensionThreshold: 0), [])
    }
}

final class EvalReplayTests: XCTestCase {
    private func makeRun(extensionThreshold: String = "0") -> EvalRun {
        let suggestion = "today after lunch together"
        let result = CaseResult(id: "0-boundary-10", category: "chat", kind: .boundary,
            suggestion: suggestion, truth: suggestion, score: EvalScorer.score(suggestion: suggestion, truth: suggestion),
            latencyMs: 123, confidence: 0.16,
            words: [WordScore(text: "today", probability: 0.16), WordScore(text: " after", probability: 0.07),
                    WordScore(text: " lunch", probability: 0.03), WordScore(text: " together", probability: 0.9)],
            followsHint: false, hintSupport: 0, midword: false)
        return EvalRun(backend: "fixture", model: "fixture", summary: EvalSummary(results: [result]),
                       results: [result], configuration: ["extensionThreshold": extensionThreshold])
    }

    func testProfilesRescoreTheActualVisiblePhraseAndKeepOriginalLatency() throws {
        let raw = makeRun()
        let careful = try EvalRunner.replay(raw, style: .careful, baseThreshold: 0.2)
        let balanced = try EvalRunner.replay(raw, style: .balanced, baseThreshold: 0.2)
        let frequent = try EvalRunner.replay(raw, style: .frequent, baseThreshold: 0.2)
        XCTAssertEqual(careful.results[0].suggestion, "")
        XCTAssertEqual(balanced.results[0].suggestion, "today after")
        XCTAssertEqual(frequent.results[0].suggestion, "today after lunch together")
        XCTAssertEqual(balanced.results[0].score.acceptedChars, "today after".count)
        XCTAssertEqual(careful.results[0].latencyMs, 123)
        XCTAssertEqual(balanced.configuration?["latencySource"], "original inference run")
    }

    func testRejectsMissingOrPreviouslyTruncatedWordScores() {
        XCTAssertThrowsError(try EvalRunner.replay(makeRun(extensionThreshold: "0.05"), style: .balanced, baseThreshold: 0.2))
        var legacy = makeRun()
        legacy.results[0].words = nil
        XCTAssertThrowsError(try EvalRunner.replay(legacy, style: .balanced, baseThreshold: 0.2))
    }

    func testOlderResultJSONStillDecodes() throws {
        let json = #"{"id":"old","category":"chat","kind":"boundary","suggestion":"there","truth":"there today","score":{"shown":true,"firstChunkCorrect":true,"acceptedChunks":1,"acceptedChars":5,"shownChunks":1},"latencyMs":12,"confidence":0.9}"#
        let result = try JSONDecoder().decode(CaseResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.suggestion, "there")
        XCTAssertNil(result.words)
        XCTAssertNil(result.midword)
    }
}
