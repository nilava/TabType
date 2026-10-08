import XCTest
@testable import TabTypeKit

final class CatalogRefreshTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    }

    func testUnreachableRemoteFallsBackToBundled() async throws {
        let catalog = await ModelCatalog.latest(remote: URL(string: "http://127.0.0.1:9/models.json")!, cacheURL: nil)
        XCTAssertEqual(catalog, try ModelCatalog.bundled())
    }

    func testUnreachableRemoteUsesNewerCachedCopy() async throws {
        var newer = try ModelCatalog.bundled()
        newer.version += 1
        newer.recommendations = [.init(minimumRAMGB: 8, modelID: newer.models[0].id)]
        let cache = tempURL()
        defer { try? FileManager.default.removeItem(at: cache) }
        try JSONEncoder().encode(newer).write(to: cache)
        let catalog = await ModelCatalog.latest(remote: URL(string: "http://127.0.0.1:9/models.json")!, cacheURL: cache)
        XCTAssertEqual(catalog, newer)
    }

    func testOlderCachedCopyIsIgnored() async throws {
        var older = try ModelCatalog.bundled()
        older.version -= 1
        let cache = tempURL()
        defer { try? FileManager.default.removeItem(at: cache) }
        try JSONEncoder().encode(older).write(to: cache)
        let catalog = await ModelCatalog.latest(remote: URL(string: "http://127.0.0.1:9/models.json")!, cacheURL: cache)
        XCTAssertEqual(catalog, try ModelCatalog.bundled())
    }
}

/// Real HTTP downloads — opt in with TABTYPE_NETWORK_TESTS=1.
final class ModelDownloaderNetworkTests: XCTestCase {
    private let entry = ModelCatalog.Entry(
        id: "readme", name: "readme", summary: "", template: "base",
        url: URL(string: "https://huggingface.co/mradermacher/Qwen3-0.6B-Base-i1-GGUF/resolve/main/README.md")!,
        fileName: "README.md", sizeBytes: 5335,
        sha256: "2b17a4d42394a4f71bfa1728e9868700840aa7ec3f024ac9e79cff33963da372",
        license: "", licenseURL: nil, requiresTermsNotice: false, minimumRAMGB: 0,
        showThreshold: nil, extensionThreshold: nil)

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TABTYPE_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("set TABTYPE_NETWORK_TESTS=1 to run network tests")
        }
    }

    func testDownloadsVerifiesAndResumes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModelStore(directory: dir)
        let downloader = ModelDownloader()

        let url = try await downloader.download(entry, into: store)
        XCTAssertTrue(store.isInstalled(entry))
        let full = try Data(contentsOf: url)

        // Simulate an interrupted transfer: half the file left as .part.
        try FileManager.default.removeItem(at: url)
        try full.prefix(2000).write(to: url.appendingPathExtension("part"))
        _ = try await downloader.download(entry, into: store)
        XCTAssertEqual(try Data(contentsOf: url), full, "resumed download must equal the full file")
    }

    func testChecksumMismatchIsRejected() async throws {
        var bad = entry
        bad.sha256 = String(repeating: "0", count: 64)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try await ModelDownloader().download(bad, into: ModelStore(directory: dir))
            XCTFail("expected checksum mismatch")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .checksumMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("README.md").path))
    }
}
