import XCTest
@testable import TabTypeKit

final class HealSplitTests: XCTestCase {
    func testBoundaryHealsTheSpace() {
        XCTAssertEqual(HealSplit.split("I'll take a look "), HealSplit(prompt: "I'll take a look", heal: [0x20]))
    }

    func testMidwordHealsSpacePlusPartial() {
        XCTAssertEqual(HealSplit.split("please doub"), HealSplit(prompt: "please", heal: Array(" doub".utf8)))
    }

    func testWordAtStartOfTextHasNoSpace() {
        XCTAssertEqual(HealSplit.split("Doub"), HealSplit(prompt: "", heal: Array("Doub".utf8)))
    }

    func testWordAfterNewlineKeepsNewlineInPrompt() {
        XCTAssertEqual(HealSplit.split("Hi,\nThan"), HealSplit(prompt: "Hi,\n", heal: Array("Than".utf8)))
    }

    func testNewlineEndingHasNothingToHeal() {
        XCTAssertEqual(HealSplit.split("Hi,\n"), HealSplit(prompt: "Hi,\n", heal: []))
    }

    func testPunctuationIsPartOfThePartial() {
        XCTAssertEqual(HealSplit.split("see e.g"), HealSplit(prompt: "see", heal: Array(" e.g".utf8)))
    }

    func testOverlongRunsAreNotHealed() {
        let url = "go to https://example.com/some/very/long/path"
        XCTAssertEqual(HealSplit.split(url), HealSplit(prompt: url, heal: []))
    }
}

final class VocabIndexTests: XCTestCase {
    func testConsistentTokensCoverBothDirections() {
        let vocab = VocabIndex(
            pieces: [" t", " th", " the", " there", " a", "the", "<eos>"].map { Array($0.utf8) },
            blocked: [false, false, false, false, false, false, true],
            endOfGeneration: [false, false, false, false, false, false, true])
        let ids = Set(vocab.tokens(consistentWith: Array(" the".utf8)[...]))
        // Inside the requirement (" t", " th") or extending it (" the", " there");
        // never a token with a different start or a blocked one.
        XCTAssertEqual(ids, [0, 1, 2, 3])
    }
}

final class CompletionDecoderTests: XCTestCase {
    private let pieces = ["<eos>", " ", " t", " th", " the", " ther", " there", "re",
                          " cat", " dog", " sat", " on", ".", "\n", "Hi", " you"]

    private func model(_ rules: [String: [String: Float]]) -> FakeModel {
        FakeModel(pieces: pieces, rules: rules)
    }

    func testBoundaryCompletesNextWordWithoutLeadingSpace() throws {
        let m = model(["Hi": [" there": 4, " the": 1]])
        let r = try XCTUnwrap(CompletionDecoder.complete("Hi ", model: m))
        XCTAssertEqual(r.text, "there")
        XCTAssertGreaterThan(r.confidence, 0.9)
    }

    func testMidwordCompletesTheTypedWord() throws {
        // Typed "Hi the": the decoder must regenerate " the" and may extend it.
        let m = model(["Hi": [" there": 4, " ther": 2, " the": 1]])
        let r = try XCTUnwrap(CompletionDecoder.complete("Hi the", model: m))
        XCTAssertEqual(r.text, "re")
    }

    func testDifferentTokenizationsOfOneWordMerge() throws {
        // " there" directly, or " the" + "re": same visible word, probabilities add.
        let m = model(["Hi": [" there": 2, " the": 2], "the": ["re": 10]])
        let r = try XCTUnwrap(CompletionDecoder.complete("Hi ", model: m))
        XCTAssertEqual(r.text, "there")
        XCTAssertGreaterThan(r.confidence, 0.95)
        XCTAssertTrue(r.alternatives.isEmpty)
    }

    func testExtendsWhileNextWordsAreLikely() throws {
        let rules: [String: [String: Float]] = [
            "on": [" the": 5], "the": [" cat": 3, " dog": 2],
            "cat": [" sat": 4, ".": 1], "sat": [" on": 5],
        ]
        var options = DecoderOptions()
        options.extensionThreshold = 0.3
        options.maxWords = 4
        let r = try XCTUnwrap(CompletionDecoder.complete("on ", model: model(rules), options: options))
        XCTAssertEqual(r.text, "the cat sat on")
        XCTAssertEqual(r.words.map(\.text), ["the", " cat", " sat", " on"])

        options.extensionThreshold = 0.8   // " cat" is only ~0.73 likely
        let short = try XCTUnwrap(CompletionDecoder.complete("on ", model: model(rules), options: options))
        XCTAssertEqual(short.text, "the")
        XCTAssertTrue(short.predictedTrailingSpace)
    }

    func testNeverOpensWithALineBreak() throws {
        let m = model(["Hey\n": ["\n": 5, "Hi": 2]])
        let r = try XCTUnwrap(CompletionDecoder.complete("Hey\n", model: m))
        XCTAssertEqual(r.text, "Hi")
    }

    func testStopsAtLineBreakAndEndOfText() throws {
        let m = model(["Hi": [" there": 5], "there": ["\n": 5]])
        var options = DecoderOptions()
        options.extensionThreshold = 0
        let r = try XCTUnwrap(CompletionDecoder.complete("Hi ", model: m, options: options))
        XCTAssertEqual(r.text, "there")
        XCTAssertFalse(r.predictedTrailingSpace)
    }

    func testAlternativesAreTheRunnerUpWords() throws {
        let m = model(["the": [" cat": 3, " dog": 2.5]])
        var options = DecoderOptions()
        options.extensionThreshold = 2   // first word only
        let r = try XCTUnwrap(CompletionDecoder.complete("Hi the ", model: m, options: options))
        XCTAssertEqual(r.text, "cat")
        XCTAssertEqual(r.alternatives.first?.text, "dog")
    }

    func testCandidateSequencesAreReleased() throws {
        let m = model(["Hi": [" there": 4, " the": 3, " ther": 2]])
        _ = try CompletionDecoder.complete("Hi ", model: m)
        XCTAssertEqual(m.liveCandidateSequences, [])
    }

    func testCancellationAbortsBetweenSteps() {
        let m = model(["Hi": [" there": 4]])
        XCTAssertThrowsError(try CompletionDecoder.complete("Hi ", model: m, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(m.liveCandidateSequences, [])
    }

    func testNothingLikelyMeansNoSuggestion() throws {
        // Only end-of-text is plausible after the prompt.
        let m = model([:])
        XCTAssertNil(try CompletionDecoder.complete("Done.\n", model: m))
    }
}

final class RetrievalHintTests: XCTestCase {
    private let pieces = ["<eos>", " cat", " dog", " d", "og", " sat", " on", " the"]

    func testHintWinsCloseCallsWithHonestConfidence() throws {
        let m = FakeModel(pieces: pieces, rules: ["the": [" cat": 3, " dog": 2.5], "dog": [" sat": 5], "cat": [" sat": 5]])
        var options = DecoderOptions()
        options.extensionThreshold = 2
        let plain = try XCTUnwrap(CompletionDecoder.complete("Hi the ", model: m, options: options))
        XCTAssertEqual(plain.text, "cat")
        XCTAssertFalse(plain.followsHint)

        options.hint = Array("dog sat".utf8)
        let hinted = try XCTUnwrap(CompletionDecoder.complete("Hi the ", model: m, options: options))
        XCTAssertEqual(hinted.text, "dog")
        XCTAssertTrue(hinted.followsHint)
        XCTAssertLessThan(hinted.confidence, 0.5, "reported confidence is the model's own, not boosted")
    }

    func testImplausibleHintIsIgnored() throws {
        let m = FakeModel(pieces: pieces, rules: ["the": [" cat": 6]])
        var options = DecoderOptions()
        options.hint = Array("dog".utf8)
        let r = try XCTUnwrap(CompletionDecoder.complete("Hi the ", model: m, options: options))
        XCTAssertEqual(r.text, "cat")
        XCTAssertFalse(r.followsHint)
    }

    func testHintIsFollowedAcrossTokens() throws {
        // " dog" isn't one token here: the hint path goes " d" + "og".
        let m = FakeModel(pieces: ["<eos>", " cat", " d", "og", " sat"],
                          rules: ["the": [" cat": 2.6, " d": 2.5], " d": ["og": 4], "og": [" sat": 5], "cat": [" sat": 5]])
        var options = DecoderOptions()
        options.extensionThreshold = 2
        options.hint = Array("dog".utf8)
        let r = try XCTUnwrap(CompletionDecoder.complete("Hi the ", model: m, options: options))
        XCTAssertEqual(r.text, "dog")
        XCTAssertTrue(r.followsHint)
        XCTAssertEqual(m.liveCandidateSequences, [])
    }
}

final class WordsThatFitTests: XCTestCase {
    func testOffersOtherFittingWordsWithoutTheSelectedOne() throws {
        let m = FakeModel(pieces: ["<eos>", " cat", " dog", " sat", " on"],
                          rules: ["the": [" cat": 3, " dog": 2.5, " sat": 1], "cat": [" sat": 5], "dog": [" sat": 5]])
        let words = try CompletionDecoder.wordsThatFit(after: "Hi the ", excluding: "cat", model: m)
        XCTAssertEqual(words.first?.text, "dog")
        XCTAssertFalse(words.contains { $0.text.lowercased() == "cat" })
        XCTAssertEqual(m.liveCandidateSequences, [])
    }
}

final class GenerationGateTests: XCTestCase {
    func testNewerRequestInvalidatesOlder() {
        let gate = GenerationGate()
        let first = gate.next()
        XCTAssertTrue(gate.isCurrent(first))
        let second = gate.next()
        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertTrue(gate.isCurrent(second))
    }
}
