import XCTest
@testable import TabType

@MainActor
final class DiagnosticRetentionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDeleteDiagnosticsRemovesLegacyCapturesAndLeavesOtherFiles() throws {
        let root = try directory()
        let outside = try directory()
        let keep = outside.appendingPathComponent("keep.png")
        try Data([1]).write(to: keep)
        for name in ["tabtype.log", "tabtype.1.log", "unrelated.txt"] { try Data([1]).write(to: root.appendingPathComponent(name)) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("fit"), withDestinationURL: outside)
        try Log.clearFiles(in: root)
        try Log.clearFiles(in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("unrelated.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tabtype.log").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("fit").path))
    }

}
