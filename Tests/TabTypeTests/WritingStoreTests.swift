import XCTest
@testable import TabType

@MainActor
final class WritingStoreTests: XCTestCase {
    func testOnlyAcceptedSessionsAreHighSignal() throws {
        // A store written before acceptance was tracked still decodes (accepted = nil).
        let json = #"""
        [{"key":"msg:1","bundleId":"a","text":"legacy text from before","updated":0},
         {"key":"msg:2","bundleId":"a","text":"typed without accepting","updated":1,"accepted":false},
         {"key":"msg:3","bundleId":"a","text":"accepted a suggestion here","updated":2,"accepted":true}]
        """#
        let docs = try JSONDecoder().decode([WritingStore.Document].self, from: Data(json.utf8))
        XCTAssertEqual(docs.count, 3)
        XCTAssertEqual(WritingStore.highSignal(docs).map(\.key), ["msg:3"])
    }
}
