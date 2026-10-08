import XCTest
@testable import TabTypeKit

final class SuggestionSessionTests: XCTestCase {
    private let defaults = SuggestionSession.AcceptOptions()

    func testWordSplitHoldsBackSpaceAndPunctuation() {
        typealias S = SuggestionSession
        XCTAssertEqual(S.splitFirstWord("at it later", options: defaults).0, "at")
        XCTAssertEqual(S.splitFirstWord("at it later", options: defaults).1, " it later")
        XCTAssertEqual(S.splitFirstWord("look? then", options: defaults).0, "look")
        XCTAssertEqual(S.splitFirstWord("look? then", options: defaults).1, "? then")
        XCTAssertEqual(S.splitFirstWord(" the dashboard", options: defaults).0, " the")
        let keep = SuggestionSession.AcceptOptions(includeTrailingPunctuation: true, includeTrailingSpace: true)
        XCTAssertEqual(S.splitFirstWord("look? then", options: keep).0, "look? ")
        XCTAssertEqual(S.splitFirstWord("look? then", options: keep).1, "then")
        // A lone punctuation "word" is still accepted.
        XCTAssertEqual(S.splitFirstWord("? ok", options: defaults).0, "?")
    }

    func testTabThroughASuggestionWordByWord() {
        var s = SuggestionSession()
        s.register("at it later", isNew: true)
        XCTAssertEqual(s.accept(whole: false, options: defaults)?.insert, "at")
        XCTAssertEqual(s.text, " it later")
        XCTAssertTrue(s.isProtectingRemainder)
        XCTAssertEqual(s.accept(whole: false, options: defaults)?.insert, " it")
        XCTAssertEqual(s.accept(whole: false, options: defaults)?.insert, " later")
        XCTAssertNil(s.ghost, "exhausted")
        XCTAssertNil(s.accept(whole: false, options: defaults))
    }

    func testRemainderIsNotReplacedByNewPredictions() {
        var s = SuggestionSession()
        s.register("at it later", isNew: true)
        _ = s.accept(whole: false, options: defaults)
        XCTAssertFalse(s.register("something else", isNew: true))
        XCTAssertEqual(s.text, " it later")
        XCTAssertEqual(s.evaluate("something else", requestedInput: "x", currentInput: "x"), .held)
        // A re-present of the remainder itself is fine and keeps it protected.
        XCTAssertTrue(s.register(" it later", isNew: false))
        XCTAssertTrue(s.isProtectingRemainder)
    }

    func testStaleResultsAreDroppedAndRekickedOnlyWhenNotHolding() {
        var s = SuggestionSession()
        XCTAssertEqual(s.evaluate("at", requestedInput: "look ", currentInput: "look a"), .stale(rekick: true))
        s.register("at it", isNew: true)
        _ = s.accept(whole: false, options: defaults)
        XCTAssertEqual(s.evaluate("at", requestedInput: "look ", currentInput: "look at"), .stale(rekick: false))
    }

    func testRepeatOfJustAcceptedTextIsDropped() {
        var s = SuggestionSession()
        let t0 = Date()
        s.register("at", isNew: true)
        _ = s.accept(whole: true, options: defaults, now: t0)
        XCTAssertEqual(s.evaluate(" at", requestedInput: "a", currentInput: "a", now: t0.addingTimeInterval(1)),
                       .repeatOfAccepted)
        XCTAssertEqual(s.evaluate("at", requestedInput: "a", currentInput: "a", now: t0.addingTimeInterval(5)), .present)
    }

    func testTypeThroughShrinksAndKeepsRole() {
        var s = SuggestionSession()
        s.register("at it", isNew: true)
        _ = s.accept(whole: false, options: defaults)   // remainder " it"
        XCTAssertEqual(s.typeThrough(" "), "it")
        XCTAssertTrue(s.isProtectingRemainder)
        XCTAssertNil(s.typeThrough("x"), "a non-matching key clears the ghost")
        XCTAssertNil(s.ghost)
    }

    func testTypingTheWholeGhostClearsIt() {
        var s = SuggestionSession()
        s.register("at", isNew: true)
        XCTAssertNil(s.typeThrough("at"))
        XCTAssertNil(s.ghost)
    }

    func testClearReleasesTheHold() {
        var s = SuggestionSession()
        s.register("at it", isNew: true)
        _ = s.accept(whole: false, options: defaults)
        s.clear()
        XCTAssertTrue(s.register("new", isNew: true))
        XCTAssertEqual(s.evaluate("new", requestedInput: "a", currentInput: "a"), .present)
    }
}
