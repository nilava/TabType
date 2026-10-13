import XCTest
@testable import TabTypeKit

final class SuffixIndexTests: XCTestCase {
    private let history = [
        "Thanks for the update, I'll take a look at it after lunch.",
        "Sounds good, I'll take a look at it tomorrow morning.",
        "I'll take a look at the logs and get back to you.",
        "Best regards,\nNilava Chowdhury",
        "Kind regards,\nNilava Chowdhury",
    ]

    func testFindsTheMostCommonContinuation() throws {
        let index = SuffixIndex(documents: history)
        let hint = try XCTUnwrap(index.continuation(after: "ok, I'll take a look "))
        XCTAssertEqual(hint.text, "at it after lunch.")
        XCTAssertEqual(hint.support, 3, "three past occurrences continue with \"at\"")
    }

    func testMatchingIgnoresCaseAndWhitespaceButKeepsOriginalCasing() throws {
        let index = SuffixIndex(documents: history)
        let hint = try XCTUnwrap(index.continuation(after: "Thanks!\n\nbest   REGARDS,\n"))
        XCTAssertEqual(hint.text, "Nilava Chowdhury")
    }

    func testCompletesAPartialWord() throws {
        let index = SuffixIndex(documents: history)
        let hint = try XCTUnwrap(index.continuation(after: "Best regards, Nil"))
        XCTAssertEqual(hint.text, "ava Chowdhury")
    }

    func testPrefersTheLongestMatchingTail() throws {
        let index = SuffixIndex(documents: history)
        // "a look at it" alone would favour "after"/"tomorrow"; the longer tail
        // "a look at the" pins it to the logs sentence.
        let hint = try XCTUnwrap(index.continuation(after: "let me take a look at the "))
        XCTAssertTrue(hint.text.hasPrefix("logs"), hint.text)
    }

    func testNoMatchOrTooShort() {
        let index = SuffixIndex(documents: history)
        XCTAssertNil(index.continuation(after: "completely unrelated words here "))
        XCTAssertNil(index.continuation(after: "I'll "), "below the minimum match length")
        XCTAssertNil(SuffixIndex(documents: []).continuation(after: "I'll take a look "))
    }

    func testDocumentsDontRunIntoEachOther() throws {
        let index = SuffixIndex(documents: ["first note ends here", "second note starts"])
        XCTAssertNil(index.continuation(after: "first note ends here "), "nothing follows in that document")
    }

    func testBuildsLargeIndexQuickly() {
        let docs = (0..<4000).map { "Message number \($0) about the quarterly planning and the budget review \($0 % 17)." }
        let start = Date()
        let index = SuffixIndex(documents: docs)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertNotNil(index.continuation(after: "about the quarterly "))
    }
}

final class NGramBoosterTests: XCTestCase {
    private let history = [
        "Sounds good to me, thanks!",
        "Sounds good to me, let's ship it.",
        "Best regards, Runakash",
        "Best regards, Runakash",
        "Looking forward to hearing from you.",
        "Looking forward to catching up soon.",
    ]

    func testShortContextBoundaryContinuation() throws {
        // "Best " is only 5 chars (below SuffixIndex's 10-char minimum),
        // so NGramBooster handles the short-context continuation when support >= minUnigramSupport,
        // or 2-word context "Sounds good " with support >= 2.
        let booster = NGramBooster(documents: history)
        let hint = try XCTUnwrap(booster.continuation(after: "Sounds good "))
        XCTAssertTrue(hint.text.hasPrefix("to me,"), hint.text)
        XCTAssertEqual(hint.support, 2)
    }

    func testMidWordInlineCompletion() throws {
        // "Best reg" is 8 chars (< 10 chars for SuffixIndex); NGramBooster completes "ards, Runakash".
        let booster = NGramBooster(documents: history)
        let hint = try XCTUnwrap(booster.continuation(after: "Best reg"))
        XCTAssertEqual(hint.text, "ards, Runakash")
        XCTAssertEqual(hint.support, 2)
    }
}
