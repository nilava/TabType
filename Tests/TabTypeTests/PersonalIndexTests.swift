import XCTest
import TabTypeKit
@testable import TabType

@MainActor
final class PersonalIndexTests: XCTestCase {
    private func store() throws -> WritingStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return WritingStore(directory: root)
    }

    private func waitForIndex(_ index: PersonalIndex) async throws {
        for _ in 0..<200 {
            if index.index != nil { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Synthetic writing index did not rebuild")
    }

    func testEffectivePerAppOffBlocksReuseEvenWithAnExistingIndex() async throws {
        let store = try store()
        store.record("I will meet you at seven tomorrow.", bundleId: "test", fieldKey: nil, kind: .message)
        let index = PersonalIndex(store: store, rebuildDelay: 0)
        index.start()
        try await waitForIndex(index)
        XCTAssertNotNil(index.hint(after: "I will meet you ", bundleId: "test", scope: .currentApp, enabled: true))
        for scope in PersonalizationScope.allCases {
            XCTAssertNil(index.hint(after: "I will meet you ", bundleId: "test", scope: scope, enabled: false))
        }
    }

    func testEraseImmediatelyRevokesBothScopesAndOldRebuildsCannotRestoreThem() async throws {
        let store = try store()
        store.record("I will meet you at seven tomorrow.", bundleId: "test", fieldKey: nil, kind: .message)
        let index = PersonalIndex(store: store, rebuildDelay: 0)
        index.start()
        try await waitForIndex(index)
        store.record("An unrelated newly written message starts another rebuild.", bundleId: "other", fieldKey: nil, kind: .message)
        store.eraseAll()
        XCTAssertNil(index.index)
        store.record("Our fresh sentence begins after deletion.", bundleId: "test", fieldKey: nil, kind: .message)
        try await waitForIndex(index)
        for scope in PersonalizationScope.allCases {
            XCTAssertNil(index.hint(after: "I will meet you ", bundleId: "test", scope: scope, enabled: true))
            XCTAssertNotNil(index.hint(after: "Our fresh sentence ", bundleId: "test", scope: scope, enabled: true))
        }
    }

    func testIdenticalMessagesInDifferentAppsKeepBothOrigins() throws {
        let store = try store()
        let text = "I will meet you at seven tomorrow."
        store.record(text, bundleId: "one", fieldKey: nil, kind: .message)
        store.record(text, bundleId: "two", fieldKey: nil, kind: .message)
        store.record(text, bundleId: "two", fieldKey: nil, kind: .message)
        XCTAssertEqual(store.allDocuments.map(\.bundleId), ["one", "two"])
    }
}
