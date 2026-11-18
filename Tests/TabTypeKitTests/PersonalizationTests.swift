import XCTest
@testable import TabTypeKit

final class PersonalVocabularyTests: XCTestCase {
    private let vocabulary = PersonalVocabulary(documents: [
        "Thanks for the update, Priya. I'll push the fix to staging.",
        "Thanks for the review. Priya, can you check the gate pass flow?",
        "Thanks for the heads up! Cheers, Nilava",
        "Talk to Zubin tomorrow.",
    ])

    func testBigramsAndTrigramsPredictTheNextWord() {
        let next = vocabulary.continuations(after: "Thanks for ")
        XCTAssertEqual(next.first?.text, "the")
        XCTAssertEqual(next.first?.weight, 1)
    }

    func testMidWordFinishesARecurringWordInTheAuthorsCasing() {
        let next = vocabulary.continuations(after: "Hi pri")
        XCTAssertEqual(next.map(\.text), ["ya"], "rest of the word only; the typed casing is kept by the caller")
    }

    func testWordsUsedOnceAreNotCompletedOutOfContext() {
        XCTAssertTrue(vocabulary.continuations(after: "Ask Zu").isEmpty)
    }

    func testSentenceEndBreaksTheChain() {
        // "staging." ends a sentence; "Thanks" after it in the next doc is not "staging → thanks".
        XCTAssertTrue(vocabulary.continuations(after: "push it to staging. ").isEmpty)
    }

    func testPunctuationIsStrippedFromWords() {
        XCTAssertEqual(vocabulary.continuations(after: "the update, ").first?.text, "Priya")
    }

    func testPartialWithInnerPunctuationIsNotAWord() {
        XCTAssertTrue(vocabulary.continuations(after: "see e.g").isEmpty)
    }

    func testOffDoesNoWork() {
        XCTAssertTrue(vocabulary.biasTargets(after: "Thanks for ", strength: 0).isEmpty)
        XCTAssertTrue(PersonalVocabulary(documents: []).biasTargets(after: "Thanks for ", strength: 1).isEmpty)
    }

    func testBiasIsBoundedAndScales() {
        XCTAssertEqual(PersonalVocabulary.bias(weight: 1, strength: 1), 0.8, accuracy: 1e-6)
        XCTAssertEqual(PersonalVocabulary.bias(weight: 0, strength: 1), 0.1, accuracy: 1e-6)
        XCTAssertEqual(PersonalVocabulary.bias(weight: 7, strength: 9), 0.8, accuracy: 1e-6, "clamped")
        XCTAssertEqual(PersonalVocabulary.bias(weight: 1, strength: -1), 0)
        XCTAssertLessThan(PersonalVocabulary.bias(weight: 1, strength: 0.33),
                          PersonalVocabulary.bias(weight: 1, strength: 0.66))
        let targets = vocabulary.biasTargets(after: "Thanks for ", strength: 1)
        XCTAssertEqual(targets.first, BiasTarget(text: Array("the".utf8), bias: 0.8))
        XCTAssertTrue(targets.allSatisfy { PersonalVocabulary.biasRange.contains($0.bias) })
    }
}

final class PersonalBiasDecoderTests: XCTestCase {
    private let pieces = ["<eos>", " ", " c", " ca", " cat", " d", " do", " dog", " sat", "Hi", "."]

    private func complete(_ text: String, _ rules: [String: [String: Float]], bias: [String: Float]) throws -> CompletionResult {
        var options = DecoderOptions()
        options.biasTargets = bias.map { BiasTarget(text: Array($0.key.utf8), bias: $0.value) }
        options.maxWords = 1
        return try XCTUnwrap(CompletionDecoder.complete(text, model: FakeModel(pieces: pieces, rules: rules), options: options))
    }

    func testBiasBreaksACloseCallWithHonestConfidence() throws {
        let rules: [String: [String: Float]] = ["Hi": [" cat": 2.0, " dog": 1.9, " sat": 1.0]]
        XCTAssertEqual(try complete("Hi ", rules, bias: [:]).text, "cat")
        let biased = try complete("Hi ", rules, bias: ["dog": 0.5])
        XCTAssertEqual(biased.text, "dog")
        XCTAssertLessThan(biased.confidence, 0.5, "reported confidence is the model's own")
        XCTAssertTrue(biased.personalWordWon)
        let agreeing = try complete("Hi ", rules, bias: ["cat": 0.5])
        XCTAssertTrue(agreeing.followsPersonalWord)
        XCTAssertFalse(agreeing.personalWordWon, "it was on top anyway")
    }

    func testBiasNeverOverridesAConfidentModel() throws {
        let rules: [String: [String: Float]] = ["Hi": [" cat": 8, " dog": 5.5]]
        XCTAssertEqual(try complete("Hi ", rules, bias: ["dog": 0.8]).text, "cat")
    }

    func testBiasIgnoresImplausibleWords() throws {
        // " dog" is ~3.5 nats below the best: outside the tie-break window.
        let rules: [String: [String: Float]] = ["Hi": [" cat": 3, " sat": 3, " dog": -0.5]]
        XCTAssertNotEqual(try complete("Hi ", rules, bias: ["dog": 0.8]).text, "dog")
    }

    func testBiasRespectsTokenHealingMidWord() throws {
        // Typed "Hi d": only tokens that reproduce " d" are candidates; the bias
        // finishes the partial word, never swaps in a word that doesn't fit it.
        let rules: [String: [String: Float]] = ["Hi": [" cat": 6, " do": 2.0, " dog": 1.9]]
        XCTAssertEqual(try complete("Hi d", rules, bias: ["og": 0.5, "at": 0.8]).text, "og")
    }

    func testOverlargeBiasIsClamped() throws {
        // A caller passing a huge bias still only gets 0.8 nats: " dog" is 1 nat behind.
        let rules: [String: [String: Float]] = ["Hi": [" cat": 2.0, " dog": 1.0, " sat": 1.0]]
        XCTAssertEqual(try complete("Hi ", rules, bias: ["dog": 50]).text, "cat")
    }
}

final class StyleExemplarTests: XCTestCase {
    func testPicksRecentDistinctTextsFromTheSameAppOnly() {
        let docs: [(app: String, text: String)] = [
            ("com.tinyspeck.slackmacgap", "oldest slack"),
            ("com.apple.mail", "Dear Ramesh, please find attached"),
            ("com.tinyspeck.slackmacgap", "yo pushed it 🚀"),
            ("com.tinyspeck.slackmacgap", "lgtm, merging"),
            ("com.tinyspeck.slackmacgap", "lgtm, merging"),
        ]
        XCTAssertEqual(StyleExemplars.pick(from: docs, app: "com.tinyspeck.slackmacgap"), ["lgtm, merging", "yo pushed it 🚀"])
        XCTAssertEqual(StyleExemplars.pick(from: docs, app: "com.apple.mail"), ["Dear Ramesh, please find attached"])
        XCTAssertTrue(StyleExemplars.pick(from: docs, app: "com.apple.Notes").isEmpty)
    }

    func testLongTextsAreCutAtAWordAndFlattened() {
        let text = "Hi team,\n" + String(repeating: "word ", count: 60)
        let picked = StyleExemplars.pick(from: [("a", text)], app: "a", maxCharacters: 40)
        XCTAssertEqual(picked.count, 1)
        XCTAssertLessThanOrEqual(picked[0].count, 40)
        XCTAssertFalse(picked[0].contains("\n"))
        XCTAssertTrue(picked[0].hasSuffix("word"))
    }
}

final class StylePromptTests: XCTestCase {
    private func context(_ exemplars: [String]) -> PromptContext {
        PromptContext(typedText: "Sure, I'll ", appName: "Slack", screenText: "Priya: can you check it?",
                      styleExemplars: exemplars)
    }

    func testNoExemplarsLeavesThePromptUnchanged() {
        for sections in [false, true] {
            let assembler = PromptAssembler(template: .base, sections: sections)
            let without = PromptContext(typedText: "Sure, I'll ", appName: "Slack", screenText: "Priya: can you check it?")
            XCTAssertEqual(assembler.assemble(context([])), assembler.assemble(without))
        }
    }

    func testPlainLayoutPutsExemplarsBeforeContextAndEndsWithTypedText() {
        let prompt = PromptAssembler(template: .base).assemble(context(["lgtm, merging", "yo pushed it"]))
        XCTAssertEqual(prompt, "Earlier, the writer wrote here:\nlgtm, merging\nyo pushed it\n\nPriya: can you check it?\n\nSure, I'll ")
    }

    func testSectionsLayoutHasAnExamplesSection() {
        let prompt = PromptAssembler(template: .base, sections: true).assemble(context(["lgtm, merging"]))
        XCTAssertEqual(prompt, "<examples>\nlgtm, merging\n</examples>\n<screen>\nPriya: can you check it?\n</screen>\n<text>\nSure, I'll ")
    }

    func testExemplarsStayWithinTheirTokenBudget() {
        // One token per word: three long exemplars share 80 tokens, at most two used.
        let words: @Sendable (String) -> Int = { $0.split(whereSeparator: \.isWhitespace).count }
        let long = String(repeating: "casual words here ", count: 40)
        for sections in [false, true] {
            let assembler = PromptAssembler(template: .base, sections: sections, tokenCount: words)
            let prompt = assembler.assemble(context([long, long + "b", long + "c"]))
            let plain = assembler.assemble(context([]))
            XCTAssertLessThanOrEqual(words(prompt) - words(plain), assembler.budgets.exemplarTokens + 8)
            XCTAssertFalse(prompt.contains("c\n"), "a third exemplar is never used")
            XCTAssertTrue(prompt.hasSuffix("Sure, I'll "))
        }
    }
}
