import XCTest
@testable import TabTypeKit

final class ScopedSuffixIndexTests: XCTestCase {
    private let documents: [ScopedSuffixIndex.Document] = [
        .init(bundleId: "personal", text: "I will meet you at seven tomorrow."),
        .init(bundleId: "work", text: "I will meet you at nine tomorrow."),
        .init(bundleId: "work", text: "I will meet you at nine tomorrow.")
    ]

    func testTheSamePrefixUsesTheCurrentAppsPhrasing() {
        let index = ScopedSuffixIndex(documents: documents)
        XCTAssertEqual(index.continuation(after: "I will meet you ", bundleId: "personal", scope: .currentApp)?.text, "at seven tomorrow.")
        XCTAssertEqual(index.continuation(after: "I will meet you ", bundleId: "work", scope: .currentApp)?.text, "at nine tomorrow.")
    }

    func testNewAppsDoNotFallBackToAnotherAppsWriting() {
        let index = ScopedSuffixIndex(documents: documents)
        XCTAssertNil(index.continuation(after: "I will meet you ", bundleId: "new", scope: .currentApp))
        XCTAssertEqual(index.continuation(after: "I will meet you ", bundleId: "new", scope: .allApps)?.text, "at nine tomorrow.")
    }

    func testEmptyHistoryHasNoHintInEitherScope() {
        let index = ScopedSuffixIndex(documents: [])
        XCTAssertTrue(index.isEmpty)
        for scope in PersonalizationScope.allCases {
            XCTAssertNil(index.continuation(after: "I will meet you ", bundleId: "new", scope: scope))
        }
    }
}
