import XCTest
@testable import TabType

final class EchoAndCleanerTests: XCTestCase {

    // MARK: - OCRCleaner

    func testTwoWordChromeLinesDropped() {
        let out = OCRCleaner.clean([
            "Commit changes", "TabType main", "Fable 5",
            "this is a real sentence of prose text here and it keeps going",
        ])
        XCTAssertFalse(out.contains("Commit changes"))
        XCTAssertFalse(out.contains("TabType main"))
        XCTAssertFalse(out.contains("Fable 5"))
        XCTAssertTrue(out.contains("real sentence of prose"))
    }

    func testShortPunctuatedFragmentSurvives() {
        let out = OCRCleaner.clean([
            "Sounds good.",
            "we should be able to ship the new build by Friday afternoon",
        ])
        XCTAssertTrue(out.contains("Sounds good."))
    }

    func testNearDuplicateFragmentsSuppressed() {
        let out = OCRCleaner.suppressNearDuplicates([
            "Sync-up meeti",
            "Sync-up meeting (Sprint statu",
            "Sync-up meeting (Sprint status review)",
            "completely different content here",
        ])
        XCTAssertEqual(out, ["Sync-up meeting (Sprint status review)",
                             "completely different content here"])
    }

    func testDistinctLinesAllKept() {
        let lines = ["the quick brown fox jumps", "over the lazy dog today"]
        XCTAssertEqual(OCRCleaner.suppressNearDuplicates(lines), lines)
    }
}
