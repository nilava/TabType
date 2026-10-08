import CoreGraphics
import ImageIO
import XCTest
@testable import TabTypeKit

/// Replays dumped real-app strips (TABTYPE_FIT_STRIP=<png> TABTYPE_FIT_TEXT=<line> TABTYPE_FIT_CROP=<0..1 left crop>
/// TABTYPE_FIT_SIZE=<pt, family-only fit>).
final class RealStripReplayTests: XCTestCase {
    func testReplay() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TABTYPE_FIT_STRIP"], let text = env["TABTYPE_FIT_TEXT"] else { throw XCTSkip("no strip") }
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        var image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let crop = Double(env["TABTYPE_FIT_CROP"] ?? "0") ?? 0
        let caretX = Double(image.width) - 4 * 2   // strip ends 4pt right of the caret, scale 2
        let left = Int(Double(image.width) * crop)
        image = try XCTUnwrap(image.cropping(to: CGRect(x: left, y: 0, width: image.width - left, height: image.height)))
        _ = BundledFonts.families
        let fit = FontFitter.fit(strip: try XCTUnwrap(InkStrip(image: image)), text: text,
                                 caretX: caretX - Double(left), scale: 2, expectedSize: 18 * 0.78,
                                 knownSize: env["TABTYPE_FIT_SIZE"].flatMap(Double.init))
        print("REPLAY crop \(crop): \(fit.map { "\($0.family) \($0.pointSize)pt conf \(String(format: "%.3f", $0.confidence)) vertical \(String(format: "%.3f", $0.verticalConfidence)) baseline \($0.baselineFromTop)" } ?? "nil")")
    }
}
