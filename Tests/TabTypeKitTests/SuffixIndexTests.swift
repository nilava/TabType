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

    func testChoosesTheFrequentPhraseWithinTheWinningFirstWord() throws {
        let index = SuffixIndex(documents: [
            "We can meet at eight tomorrow.",
            "We can meet at seven tomorrow.",
            "We can meet at seven tomorrow.",
        ])
        let hint = try XCTUnwrap(index.continuation(after: "We can meet "))
        XCTAssertEqual(hint.text, "at seven tomorrow.")
        XCTAssertEqual(hint.support, 3, "First-word support still counts all three occurrences of at")
    }

    func testLongTailDoesNotReturnPartOfTheAlreadyTypedText() throws {
        let prefix = String(repeating: "x", count: 20) + " " + String(repeating: "y", count: 50) + " "
        let index = SuffixIndex(documents: [prefix + "tomorrow morning"])
        let hint = try XCTUnwrap(index.continuation(after: prefix))
        XCTAssertEqual(hint.text, "tomorrow morning")
    }

    func testLongUnicodeTailNeverStartsInsideAUTF8Character() throws {
        let prefix = String(repeating: "é", count: 20) + " " + String(repeating: "界", count: 18) + " "
        let index = SuffixIndex(documents: [prefix + "tomorrow morning"])
        let hint = try XCTUnwrap(index.continuation(after: prefix))
        XCTAssertEqual(hint.text, "tomorrow morning")
        XCTAssertFalse(hint.text.contains("\u{FFFD}"))
    }

    func testBuildsLargeIndexQuickly() {
        let docs = (0..<4000).map { "Message number \($0) about the quarterly planning and the budget review \($0 % 17)." }
        let start = Date()
        let index = SuffixIndex(documents: docs)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertNotNil(index.continuation(after: "about the quarterly "))
    }
}
