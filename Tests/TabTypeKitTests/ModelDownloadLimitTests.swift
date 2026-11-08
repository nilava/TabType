import CryptoKit
import XCTest
@testable import TabTypeKit

private final class DownloadProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status: Int; var headers: [String: String]; var body: Data }
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var replies: [URL: Reply] = [:]
        var ranges: [URL: String] = [:]
        func install(_ reply: Reply, at url: URL) { lock.withLock { replies[url] = reply } }
        func reply(for request: URLRequest) -> Reply? {
            lock.withLock {
                guard let url = request.url else { return nil }
                ranges[url] = request.value(forHTTPHeaderField: "Range") ?? "none"
                return replies[url]
            }
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let reply = Self.state.reply(for: request), let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ModelDownloadLimitTests: XCTestCase {
    private func fixture(body: Data, expected: Int64? = nil, status: Int = 200,
                         headers: [String: String] = [:], complete: Data? = nil) throws
        -> (ModelCatalog.Entry, ModelStore, ModelDownloader) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DownloadProtocol.self]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
        let url = URL(string: "https://\(UUID().uuidString).example/model")!
        DownloadProtocol.state.install(.init(status: status, headers: headers, body: body), at: url)
        let hash = SHA256.hash(data: complete ?? body).map { String(format: "%02x", $0) }.joined()
        let entry = ModelCatalog.Entry(id: "test", name: "test", summary: "", template: "base", url: url,
            fileName: "model.gguf", sizeBytes: expected ?? Int64(body.count), sha256: hash,
            license: "", licenseURL: nil, requiresTermsNotice: false, minimumRAMGB: 0,
            showThreshold: nil, extensionThreshold: nil)
        return (entry, ModelStore(directory: root), ModelDownloader(session: session))
    }

    private func rejects(_ expectedError: ModelDownloadError, entry: ModelCatalog.Entry,
                         store: ModelStore, downloader: ModelDownloader) async throws {
        do { _ = try await downloader.download(entry, into: store); XCTFail("unsafe response accepted") }
        catch let error as ModelDownloadError { XCTAssertEqual(error, expectedError) }
        XCTAssertFalse(store.isInstalled(entry))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try store.partialURL(for: entry).path))
    }

    func testChunkedOversizedBodyStopsAtQuota() async throws {
        let (e, s, d) = try fixture(body: Data(repeating: 65, count: 2 << 20), expected: 1024)
        try await rejects(.responseTooLarge(expected: 1024), entry: e, store: s, downloader: d)
    }
    func testOversizedContentLengthIsRejected() async throws {
        let (e, s, d) = try fixture(body: Data([1, 2]), expected: 2, headers: ["Content-Length": "9999999"])
        try await rejects(.responseTooLarge(expected: 2), entry: e, store: s, downloader: d)
    }
    func testValidFullDownloadAndChecksum() async throws {
        let body = Data("ordinary model bytes".utf8)
        let (e, s, d) = try fixture(body: body)
        let result = try await d.download(e, into: s)
        XCTAssertEqual(try Data(contentsOf: result), body)
    }
    func testValidResumeAndIgnoredRangeBothWork() async throws {
        let full = Data("0123456789".utf8)
        for resume in [true, false] {
            let (e, s, d) = try fixture(body: resume ? full.suffix(6) : full, expected: 10,
                status: resume ? 206 : 200, headers: resume ? ["Content-Range": "bytes 4-9/10"] : [:], complete: full)
            try FileManager.default.createDirectory(at: s.directory, withIntermediateDirectories: true)
            try full.prefix(4).write(to: s.partialURL(for: e))
            let result = try await d.download(e, into: s)
            XCTAssertEqual(try Data(contentsOf: result), full)
            XCTAssertEqual(DownloadProtocol.state.lock.withLock { DownloadProtocol.state.ranges[e.url] }, "bytes=4-")
        }
    }
    func testInconsistentResumeRejected() async throws {
        let (e, s, d) = try fixture(body: Data("wrong".utf8), expected: 10, status: 206,
                                   headers: ["Content-Range": "bytes 0-4/10"])
        try FileManager.default.createDirectory(at: s.directory, withIntermediateDirectories: true)
        try Data([1, 2]).write(to: s.partialURL(for: e))
        try await rejects(.invalidRange, entry: e, store: s, downloader: d)
    }
    func testOversizedExistingPartialRejected() async throws {
        let (e, s, d) = try fixture(body: Data([1, 2]))
        try FileManager.default.createDirectory(at: s.directory, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 100).write(to: s.partialURL(for: e))
        try await rejects(.responseTooLarge(expected: 2), entry: e, store: s, downloader: d)
    }
    func testNonpositiveCatalogSizeRejected() async throws {
        let (e, s, d) = try fixture(body: Data([1]), expected: 0)
        try await rejects(.invalidSize, entry: e, store: s, downloader: d)
    }
}
