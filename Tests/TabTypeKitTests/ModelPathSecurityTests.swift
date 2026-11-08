import XCTest
@testable import TabTypeKit

final class ModelPathSecurityTests: XCTestCase {
    private func entry(_ name: String, size: Int64 = 7) -> ModelCatalog.Entry {
        .init(id: "test", name: "Test", summary: "", template: "base",
              url: URL(string: "https://example.invalid/model")!, fileName: name,
              sizeBytes: size, sha256: nil, license: "", licenseURL: nil,
              requiresTermsNotice: false, minimumRAMGB: 0,
              showThreshold: nil, extensionThreshold: nil)
    }

    private func fixture() throws -> (URL, ModelStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let models = root.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (root, ModelStore(directory: models))
    }

    func testTraversalAndNonBasenamesAreRejectedAtEveryConsumer() async throws {
        let (root, store) = try fixture()
        let outside = root.appendingPathComponent("outside.txt")
        try Data("private".utf8).write(to: outside)
        for name in ["../outside.txt", outside.path, "sub/../../outside.txt", "..\\outside.txt", "", ".", "..", "bad\u{0}name"] {
            let model = entry(name)
            XCTAssertThrowsError(try store.url(for: model), name)
            XCTAssertThrowsError(try store.partialURL(for: model), name)
            XCTAssertFalse(store.isInstalled(model), name)
            XCTAssertThrowsError(try store.delete(model), name)
            do {
                _ = try await ModelDownloader().download(model, into: store)
                XCTFail("download accepted \(name)")
            } catch {
                XCTAssertEqual(error as? ModelDownloadError, .unsafeFileName)
            }
            XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "private")
        }
    }

    func testDestinationAndPartialSymlinksIncludingDanglingLinksAreRejected() async throws {
        for partial in [false, true] {
            for dangling in [false, true] {
                let (root, store) = try fixture()
                let outside = root.appendingPathComponent("outside.txt")
                if !dangling { try Data("private".utf8).write(to: outside) }
                let name = "model.gguf"
                let link = store.directory.appendingPathComponent(name + (partial ? ".part" : ""))
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
                let model = entry(name)
                XCTAssertThrowsError(try store.partialURL(for: model))
                do {
                    _ = try await ModelDownloader().download(model, into: store)
                    XCTFail("download accepted symlink")
                } catch {
                    XCTAssertEqual(error as? ModelDownloadError, .unsafeFileName)
                }
                if !partial {
                    XCTAssertFalse(store.isInstalled(model))
                    XCTAssertThrowsError(try store.delete(model))
                    XCTAssertTrue(store.customModels(excluding: .init(version: 1, models: [], recommendations: [])).isEmpty)
                }
                if dangling {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
                } else {
                    XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "private")
                }
            }
        }
    }

    func testRegularPartialDownloadStillFinishesAndCanBeDeleted() async throws {
        let (_, store) = try fixture()
        let model = entry("model.Q4_K_M.gguf")
        let partial = try store.partialURL(for: model)
        // A complete partial needs no network; exercise the real finalization path.
        try Data("payload".utf8).write(to: partial)
        let destination = try await ModelDownloader().download(model, into: store)
        XCTAssertEqual(destination, try store.url(for: model))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "payload")
        XCTAssertTrue(store.isInstalled(model))
        try store.delete(model)
        XCTAssertFalse(store.isInstalled(model))
    }

    func testInstalledModelDoesNotTouchAnUnusedPartialPath() async throws {
        let (root, store) = try fixture()
        let model = entry("installed.gguf")
        let destination = try store.url(for: model)
        try Data("payload".utf8).write(to: destination)
        let outside = root.appendingPathComponent("private.txt")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: destination.appendingPathExtension("part"), withDestinationURL: outside)
        let installed = try await ModelDownloader().download(model, into: store)
        XCTAssertEqual(installed, destination)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "private")
    }

    func testDirectoriesAreNotModelsAndLiteralPercentNamesStayInsideFolder() throws {
        let (_, store) = try fixture()
        try FileManager.default.createDirectory(at: store.directory.appendingPathComponent("folder.gguf"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.url(for: entry("folder.gguf")))
        let literal = try store.url(for: entry("%2e%2e%2fmodel.gguf"))
        XCTAssertEqual(literal.lastPathComponent, "%2e%2e%2fmodel.gguf")
        XCTAssertEqual(literal.deletingLastPathComponent(), store.directory.resolvingSymlinksInPath())
        // Existing downloader tests use README.md; safe basenames need no GGUF suffix.
        XCTAssertEqual(try store.url(for: entry("README.md")).lastPathComponent, "README.md")
    }

    func testFirstInstallCanUseAMissingDirectoryWithoutADirectoryURLHint() throws {
        let (root, _) = try fixture()
        let missing = URL(fileURLWithPath: root.path + "/new-models")
        let store = ModelStore(directory: missing)
        XCTAssertNoThrow(try store.url(for: entry("model.gguf")))
        XCTAssertNoThrow(try store.partialURL(for: entry("model.gguf")))
        XCTAssertFalse(store.isInstalled(entry("model.gguf")))
        XCTAssertThrowsError(try store.url(for: entry("../outside.txt")))
    }
}
