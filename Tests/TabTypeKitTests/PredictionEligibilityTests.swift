import XCTest
@testable import TabTypeKit

final class PredictionEligibilityTests: XCTestCase {
    func testStaysQuietInsideURLsBeforeTheSlashesAreTyped() {
        for text in ["www.exa", "www.example.com/path", "WWW.EXAMPLE", "https:", "http:", "Hello\twww.exa"] {
            XCTAssertFalse(PredictionEligibility.shouldPredict(text), text)
        }
    }

    func testEmailAddressIsSuppressedImmediatelyAfterAt() {
        for text in ["alice@", "Please contact alex@", "alice@example.com"] {
            XCTAssertFalse(PredictionEligibility.shouldPredict(text), text)
        }
        XCTAssertTrue(PredictionEligibility.shouldPredict("Thanks @alex"))
    }

    func testOrdinaryWritingAndExistingQuietFieldsKeepTheirBehavior() {
        for text in ["We should meet ", "We use HTTP", "Notes:", "Happy", "Hello\nWe "] {
            XCTAssertTrue(PredictionEligibility.shouldPredict(text), text)
        }
        for text in ["", "x", "/", "@", "Hello\n", "https://example.com/pa"] {
            XCTAssertFalse(PredictionEligibility.shouldPredict(text), text)
        }
    }
}
