import XCTest
@testable import TabType

final class TrimmerAndTypoTests: XCTestCase {

    // MARK: - Engine.typoCheckToken

    func testMidWordPartialExtracted() {
        let r = Engine.typoCheckToken("okay te")
        XCTAssertEqual(r?.0, "te")
        XCTAssertEqual(r?.1, true)
    }

    func testCompletedWordAfterSpaceExtracted() {
        let r = Engine.typoCheckToken("please recieve ")
        XCTAssertEqual(r?.0, "recieve")
        XCTAssertEqual(r?.1, false)
    }

    func testPunctuationBoundaryReturnsNil() {
        XCTAssertNil(Engine.typoCheckToken("done,"))
    }

    // MARK: - Engine.stripPartialOverlap

    // MARK: - MacroEngine.couldMatch

    func testKeywordPrefixesStayAlive() {
        XCTAssertTrue(MacroEngine.couldMatch("d"))       // → date/day/dice/datetime
        XCTAssertTrue(MacroEngine.couldMatch("dat"))     // → date
        XCTAssertTrue(MacroEngine.couldMatch("random 5"))
    }

    func testExpressionsStayAlive() {
        XCTAssertTrue(MacroEngine.couldMatch("2+2"))
        XCTAssertTrue(MacroEngine.couldMatch("10km->"))
        XCTAssertTrue(MacroEngine.couldMatch("72"))
    }

    func testDeadQueriesGiveUp() {
        XCTAssertFalse(MacroEngine.couldMatch("xyz"))
        XCTAssertFalse(MacroEngine.couldMatch("hello there"))
    }

    // MARK: - Engine.trimSuffixOverlap

    func testDuplicatedPunctuationTrimmed() {
        XCTAssertEqual(Engine.trimSuffixOverlap("call later today?", afterCursor: "? thanks"),
                       "call later today")
    }

    func testDuplicatedPhraseTrimmed() {
        XCTAssertEqual(Engine.trimSuffixOverlap("we can ship it on Friday", afterCursor: "on Friday as planned"),
                       "we can ship it ")
    }

    func testCoincidentalShortLetterOverlapKept() {
        // Suggestion ends "e", after-cursor starts "e" — coincidence, not duplication.
        XCTAssertEqual(Engine.trimSuffixOverlap("see you there", afterCursor: "everyone"),
                       "see you there")
    }

    func testNoAfterCursorNoChange() {
        XCTAssertEqual(Engine.trimSuffixOverlap("hello world", afterCursor: "  "),
                       "hello world")
    }

    // MARK: - SymSpell.topCompletion

    private func makeSym() -> SymSpell {
        let sym = SymSpell()
        sym.load(contents: """
        unfortunately 900000
        unfortunate 200000
        the 5000000
        them 800000
        testing 400000
        test 600000
        rare 500
        """)
        return sym
    }

    func testTopCompletionPicksHighestFrequency() {
        XCTAssertEqual(makeSym().topCompletion(prefix: "unf"), "unfortunately")
    }

    func testTopCompletionNilForUnknownPrefix() {
        XCTAssertNil(makeSym().topCompletion(prefix: "xqz"))
    }

    func testTopCompletionNilWhenPrefixIsDominantWord() {
        // "the" (5M) is far more frequent than "them" (800k) — don't complete it.
        XCTAssertNil(makeSym().topCompletion(prefix: "the"))
    }

    func testTopCompletionNilForRareWords() {
        XCTAssertNil(makeSym().topCompletion(prefix: "rar"))
    }

    func testTopCompletionShortPrefixRejected() {
        XCTAssertNil(makeSym().topCompletion(prefix: "un"))
    }

    // MARK: - shouldPredict email gate

    func testEmailInProgressBlocksPrediction() {
        XCTAssertFalse(Engine.shouldPredict("my email is nilava.chowdhury@lodhagroup"))
        XCTAssertFalse(Engine.shouldPredict("contact me at someone@exa"))
    }

    func testMentionAndPlainTextStillPredict() {
        // A chat @mention has nothing before the "@" — allowed.
        XCTAssertTrue(Engine.shouldPredict("hey ping @nilava about"))
        // The email is a FINISHED earlier word — later prose predicts normally.
        XCTAssertTrue(Engine.shouldPredict("email me at x@y.com and then we"))
    }
}
