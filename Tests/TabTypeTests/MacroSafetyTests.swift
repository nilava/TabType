import XCTest
@testable import TabType

@MainActor
final class MacroSafetyTests: XCTestCase {
    func testLargeMacrosDoNotTrapAndOrdinaryResultsRemain() {
        let macro = MacroEngine()
        XCTAssertNotNil(macro.evaluate("9999999999999999999+0"))
        XCTAssertNotNil(macro.evaluate("9999999999999999999km->mm"))
        XCTAssertNil(macro.evaluate("1/0"))
        XCTAssertEqual(macro.evaluate("2+2*3"), "8")
        XCTAssertEqual(macro.evaluate("10km->mi"), "6.21 mi")
        XCTAssertNil(macro.evaluate(String(repeating: "9", count: 400) + "+0"))
    }
}
