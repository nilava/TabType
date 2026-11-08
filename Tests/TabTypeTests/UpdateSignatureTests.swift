import XCTest
@testable import TabType

final class UpdateSignatureTests: XCTestCase {
    func testIdentityRequiresTheSameCertificateAndCodeIdentifier() {
        let original = UpdateSignatureVerifier.Identity(identifier: "app.tabtype.TabType", certificate: Data([1, 2, 3]))
        XCTAssertEqual(original, .init(identifier: "app.tabtype.TabType", certificate: Data([1, 2, 3])))
        XCTAssertNotEqual(original, .init(identifier: "app.tabtype.TabType", certificate: Data([4, 5, 6])))
        XCTAssertNotEqual(original, .init(identifier: "different.app", certificate: Data([1, 2, 3])))
    }

    func testUnsignedAndAdHocCodeCannotAuthorizeAnUpdate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let unsigned = root.appendingPathComponent("unsigned")
        try Data("not signed code".utf8).write(to: unsigned)
        XCTAssertThrowsError(try UpdateSignatureVerifier.identity(at: unsigned))

        let adhoc = root.appendingPathComponent("adhoc")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: adhoc)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--identifier", "app.tabtype.TabType", adhoc.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)
        XCTAssertThrowsError(try UpdateSignatureVerifier.identity(at: adhoc))
        XCTAssertThrowsError(try UpdateSignatureVerifier.verifyUpdate(at: adhoc, replacing: adhoc))
    }

    func testCertificateSignedFixtures() throws {
        guard let folder = ProcessInfo.processInfo.environment["TABTYPE_SIGNING_FIXTURES"] else {
            throw XCTSkip("Run Scripts/test-update-signatures.sh for real certificate and universal-binary fixtures")
        }
        let root = URL(fileURLWithPath: folder)
        let installed = root.appendingPathComponent("installed")
        XCTAssertNoThrow(try UpdateSignatureVerifier.verifyUpdate(at: root.appendingPathComponent("genuine"), replacing: installed))
        for name in ["same-name-different-key", "different-identifier", "tampered", "mixed-signers"] {
            XCTAssertThrowsError(try UpdateSignatureVerifier.verifyUpdate(at: root.appendingPathComponent(name), replacing: installed), name)
        }
    }
}
