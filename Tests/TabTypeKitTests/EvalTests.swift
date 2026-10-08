import XCTest
@testable import TabTypeKit

final class EvalScorerTests: XCTestCase {
    func testChunksKeepLeadingWhitespaceAndPunctuation() {
        XCTAssertEqual(EvalScorer.chunks("look at it, then"), ["look", " at", " it,", " then"])
        XCTAssertEqual(EvalScorer.chunks(" next"), [" next"])
        XCTAssertEqual(EvalScorer.chunks(""), [])
    }

    func testFullMatchAcceptsEveryChunk() {
        let s = EvalScorer.score(suggestion: "after lunch", truth: "after lunch and leave")
        XCTAssertTrue(s.firstChunkCorrect)
        XCTAssertEqual(s.acceptedChunks, 2)
        XCTAssertEqual(s.acceptedChars, 11)
    }

    func testStopsAtFirstDivergingChunk() {
        let s = EvalScorer.score(suggestion: "after dinner today", truth: "after lunch and leave")
        XCTAssertEqual(s.acceptedChunks, 1)
        XCTAssertEqual(s.acceptedChars, 5)
    }

    func testMidwordCompletionCounts() {
        let s = EvalScorer.score(suggestion: "le check them?", truth: "le check them? Thanks")
        XCTAssertEqual(s.acceptedChars, 14)
    }

    func testWrongFirstChunkScoresZeroButCountsAsShown() {
        let s = EvalScorer.score(suggestion: "ble check", truth: "le check")
        XCTAssertTrue(s.shown)
        XCTAssertFalse(s.firstChunkCorrect)
        XCTAssertEqual(s.acceptedChars, 0)
    }

    func testEmptySuggestionIsNotShown() {
        let s = EvalScorer.score(suggestion: "  ", truth: "anything")
        XCTAssertFalse(s.shown)
    }

    func testSummaryRates() {
        func result(_ suggestion: String, _ truth: String, _ kind: SplitKind = .boundary) -> CaseResult {
            CaseResult(id: UUID().uuidString, category: "chat", kind: kind, suggestion: suggestion,
                       truth: truth, score: EvalScorer.score(suggestion: suggestion, truth: truth),
                       latencyMs: 10)
        }
        let summary = EvalSummary(results: [
            result("after", "after lunch"),   // correct
            result("before", "after lunch"),  // wrong show
            result("", "after lunch"),        // not shown
            result("le", "le check", .midword),
        ])
        XCTAssertEqual(summary.cases, 4)
        XCTAssertEqual(summary.shown, 3)
        XCTAssertEqual(summary.firstChunkCorrect, 2)
        XCTAssertEqual(summary.recall, 0.5, accuracy: 1e-9)
        XCTAssertEqual(summary.precision, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(summary.wrongShowRate, 0.25, accuracy: 1e-9)
        XCTAssertEqual(summary.byKind["midword"]?.cases, 1)
    }
}

final class CaseGeneratorTests: XCTestCase {
    private let corpus = [
        CorpusEntry(category: "chat", app: "Slack", context: "Priya: ready?",
                    text: "Sure, I'll take a look right after lunch and leave comments on the document."),
        CorpusEntry(category: "email", text: "Thank you for sending the proposed terms for the renewal."),
    ]

    func testDeterministicForSeed() {
        let a = CaseGenerator(seed: 7).cases(from: corpus)
        let b = CaseGenerator(seed: 7).cases(from: corpus)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, CaseGenerator(seed: 8).cases(from: corpus))
    }

    func testPrefixPlusTruthReconstructsTheText() {
        for c in CaseGenerator(truthChars: 500).cases(from: corpus) {
            let source = corpus.first { $0.category == c.category }!.text
            XCTAssertEqual(c.prefix + c.truth, source, "case \(c.id)")
        }
    }

    func testSplitKindsLandWhereTheySay() {
        for c in CaseGenerator().cases(from: corpus) {
            switch c.kind {
            case .boundary:
                XCTAssertEqual(c.prefix.last, " ", "boundary case \(c.id) should end after a space")
                XCTAssertFalse(c.truth.first!.isWhitespace)
            case .midword:
                XCTAssertTrue(c.prefix.last!.isLetter, "midword case \(c.id)")
                XCTAssertTrue(c.truth.first!.isLetter)
            }
        }
    }

    func testCarriesContextAndCategory() {
        let c = CaseGenerator().cases(from: corpus).first { $0.category == "chat" }!
        XCTAssertEqual(c.context, "Priya: ready?")
        XCTAssertEqual(c.app, "Slack")
    }
}
