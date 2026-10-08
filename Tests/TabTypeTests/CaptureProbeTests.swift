import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import TabType

/// Manual: TABTYPE_CAPTURE_RECT="x,y,w,h" TABTYPE_CAPTURE_OUT=<png> — writes what
/// `captureScaled` sees for that rect (top-left global points).
final class CaptureProbeTests: XCTestCase {
    func testCaptureRect() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["TABTYPE_CAPTURE_RECT"], let out = env["TABTYPE_CAPTURE_OUT"] else { throw XCTSkip("manual") }
        let v = spec.split(separator: ",").compactMap { Double($0) }
        let captured = await GhostAppearanceProbe.captureScaled(rect: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
        let shot = try XCTUnwrap(captured)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, shot.image, nil)
        CGImageDestinationFinalize(dest)
    }
}
