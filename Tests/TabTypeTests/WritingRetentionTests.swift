import CryptoKit
import XCTest
@testable import TabType

@MainActor
final class WritingRetentionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testEraseCannotBeReversedByStaleOrLegacyPeer() throws {
        let root = try directory()
        let store = WritingStore(directory: root)
        store.record("Old writing that should never return after erasing.", bundleId: "test", fieldKey: nil, kind: .message)
        let old = store.allDocuments
        var synced = false
        store.onSyncNeeded = { synced = true }
        try Data("legacy".utf8).write(to: root.appendingPathComponent("typing-history.enc"))
        try Data("pending".utf8).write(to: root.appendingPathComponent("import-writing.jsonl"))
        try store.eraseAll()
        XCTAssertTrue(synced)
        XCTAssertNotNil(store.erasedBefore)
        XCTAssertEqual(store.documentCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("typing-history.enc").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("import-writing.jsonl").path))
        store.merge(old)
        XCTAssertEqual(store.documentCount, 0)
        let reloaded = WritingStore(directory: root)
        reloaded.merge(old)
        XCTAssertEqual(reloaded.documentCount, 0)
        XCTAssertEqual(reloaded.erasedBefore, store.erasedBefore)
        // A stale peer can rewrite a draft after the erase; it must adopt the erase first.
        var rewritten = old[0]
        rewritten.updated = Date().addingTimeInterval(10)
        reloaded.merge([rewritten])
        XCTAssertEqual(reloaded.documentCount, 0)
    }

    func testOfflineEditedCopyCannotReturnAfterPeerAdoptsDeletion() throws {
        let a = WritingStore(directory: try directory())
        let b = WritingStore(directory: try directory())
        a.record("An old private draft that must remain erased.", bundleId: "test", fieldKey: "draft", kind: .field)
        b.merge(a.allDocuments)
        try a.eraseAll()
        b.record("An old private draft that must remain erased. Minor offline edit.", bundleId: "test", fieldKey: "draft", kind: .field)
        b.merge([], erasedBefore: a.erasedBefore)
        a.merge(b.allDocuments, erasedBefore: b.erasedBefore)
        XCTAssertEqual(b.documentCount, 0)
        XCTAssertEqual(a.documentCount, 0)
    }

    func testDeletionPropagatesAndNewWritingStillMerges() throws {
        let a = WritingStore(directory: try directory())
        let b = WritingStore(directory: try directory())
        a.record("A harmless original sentence to learn from.", bundleId: "test", fieldKey: nil, kind: .message)
        b.merge(a.allDocuments)
        XCTAssertEqual(b.documentCount, 1)
        try a.eraseAll()
        b.merge([], erasedBefore: a.erasedBefore)
        XCTAssertEqual(b.documentCount, 0)
        b.record("A newly written sentence after the deletion.", bundleId: "test", fieldKey: nil, kind: .message)
        a.merge(b.allDocuments, erasedBefore: b.erasedBefore)
        XCTAssertEqual(a.texts, b.texts)
        XCTAssertEqual(a.documentCount, 1)
    }

    func testLegacyEncryptedArrayStillLoads() throws {
        let root = try directory()
        let keyData = Data(repeating: 7, count: 32)
        try keyData.write(to: root.appendingPathComponent("history.key"))
        let docs = [WritingStore.Document(key: "legacy", bundleId: "test", text: "Existing legitimate writing is preserved.", updated: Date())]
        let box = try AES.GCM.seal(JSONEncoder().encode(docs), using: SymmetricKey(data: keyData))
        try box.combined!.write(to: root.appendingPathComponent("writing.enc"))
        let store = WritingStore(directory: root)
        XCTAssertEqual(store.allDocuments, docs)
    }

}
