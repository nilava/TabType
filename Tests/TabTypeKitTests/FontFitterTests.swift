import CoreGraphics
import CoreText
import XCTest
@testable import TabTypeKit

/// Renders known text into a "screenshot" and checks the fitter recovers the font,
/// size, baseline and colours.
final class FontFitterTests: XCTestCase {
    private let scale = 2.0

    /// RGB screenshot strip: `text` right-aligned at `caretX` px, baseline at
    /// `baseline` px from the top.
    private func screenshot(_ text: String, family: String, size: Double, width: Int = 640, height: Int = 80,
                            caretX: Double = 600, baseline: Double = 52,
                            ink: RGB, background: RGB) -> CGImage {
        let font = FontFitter.makeFont(family, pixelSize: size * scale)
        let coverage = FontFitter.render(text, font: font, width: width, height: height,
                                         rightX: caretX, baselineFromTop: baseline)!
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let a = Double(coverage[i])
            rgba[i * 4] = UInt8(((ink.r * a + background.r * (1 - a)) * 255).rounded())
            rgba[i * 4 + 1] = UInt8(((ink.g * a + background.g * (1 - a)) * 255).rounded())
            rgba[i * 4 + 2] = UInt8(((ink.b * a + background.b * (1 - a)) * 255).rounded())
            rgba[i * 4 + 3] = 255
        }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private let lightBG = RGB(r: 0.97, g: 0.97, b: 0.96)
    private let darkInk = RGB(r: 0.12, g: 0.12, b: 0.13)

    func testBundledFontsRegister() {
        for family in ["Lato", "Inter", "Roboto", "Open Sans"] {
            XCTAssertTrue(BundledFonts.families.contains(family), "\(family) not registered: \(BundledFonts.families)")
            XCTAssertTrue(FontFitter.fontExists(family), family)
        }
    }

    func testRecoversLatoAtSlackSize() throws {
        _ = BundledFonts.families
        let text = "Sure, I'll take a look right after"
        let image = screenshot(text, family: "Lato", size: 15, ink: darkInk, background: lightBG)
        let fit = try XCTUnwrap(FontFitter.fit(strip: XCTUnwrap(InkStrip(image: image)), text: text,
                                               caretX: 600, scale: scale, expectedSize: 15))
        XCTAssertEqual(fit.family, "Lato")
        XCTAssertEqual(fit.pointSize, 15, accuracy: 0.5)
        XCTAssertEqual(fit.baselineFromTop, 52, accuracy: 2)
        XCTAssertGreaterThan(fit.confidence, 0.85)
        XCTAssertEqual(fit.inkColor.luminance, darkInk.luminance, accuracy: 0.08)
        XCTAssertFalse(fit.isDarkBackground)
    }

    /// Just typed a space: the caret sits one space-advance right of the ink.
    func testCaretAfterTypedSpaceAligns() throws {
        let font = FontFitter.makeFont("Georgia", pixelSize: 18 * scale)
        let space = CTLineGetTypographicBounds(
            CTLineCreateWithAttributedString(NSAttributedString(string: " ", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font])), nil, nil, nil)
        let image = screenshot("for sending the report over. I will take a look", family: "Georgia", size: 18,
                               caretX: 600 - space, ink: darkInk, background: .init(r: 1, g: 1, b: 1))
        let fit = try XCTUnwrap(FontFitter.fit(strip: XCTUnwrap(InkStrip(image: image)),
                                               text: "Thanks for sending the report over. I will take a look ",
                                               caretX: 600, scale: scale, expectedSize: 16, knownSize: 18))
        XCTAssertEqual(fit.family, "Georgia")
        XCTAssertGreaterThan(fit.confidence, 0.85)
    }

    /// Transparent capture pixels (holes left by excluded windows) are not ink.
    func testTransparentPixelsAreBackground() throws {
        let text = "Sure, I'll take a look right after"
        let image = screenshot(text, family: "Lato", size: 15, ink: darkInk, background: lightBG)
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for y in 0..<h { for x in 610..<w { for c in 0..<4 { rgba[(y * w + x) * 4 + c] = 0 } } }
        let holed = ctx.makeImage()!
        let strip = try XCTUnwrap(InkStrip(image: holed))
        XCTAssertEqual(strip.columnProfile[620], 0)
        XCTAssertEqual(strip.background.luminance, lightBG.luminance, accuracy: 0.02)
    }

    func testRecoversSystemFontOnDarkBackground() throws {
        let text = "Thanks for the quick turnaround on this"
        let system = FontFitter.systemFamily
        let image = screenshot(text, family: system, size: 13, baseline: 46,
                               ink: RGB(r: 0.92, g: 0.92, b: 0.93), background: RGB(r: 0.13, g: 0.13, b: 0.14))
        let fit = try XCTUnwrap(FontFitter.fit(strip: XCTUnwrap(InkStrip(image: image)), text: text,
                                               caretX: 600, scale: scale, expectedSize: 14))
        XCTAssertEqual(fit.family, system)
        XCTAssertEqual(fit.pointSize, 13, accuracy: 0.5)
        XCTAssertEqual(fit.baselineFromTop, 46, accuracy: 2)
        XCTAssertTrue(fit.isDarkBackground)
    }

    func testDistinguishesSimilarSansSerifs() throws {
        _ = BundledFonts.families
        let text = "The quarterly planning session is on Monday"
        for family in ["Inter", "Roboto", "Open Sans"] {
            let image = screenshot(text, family: family, size: 14, ink: darkInk, background: lightBG)
            let fit = try XCTUnwrap(FontFitter.fit(strip: XCTUnwrap(InkStrip(image: image)), text: text,
                                                   caretX: 600, scale: scale, expectedSize: 15))
            XCTAssertEqual(fit.family, family)
            XCTAssertEqual(fit.pointSize, 14, accuracy: 0.5, family)
        }
    }

    func testTextCroppedByTheStripStillFits() throws {
        _ = BundledFonts.families
        // A long line: only its tail is inside the 640px strip.
        let text = "This line is much longer than the captured strip, so only the end of it is visible here"
        let image = screenshot(text, family: "Roboto", size: 15, ink: darkInk, background: lightBG)
        let fit = try XCTUnwrap(FontFitter.fit(strip: XCTUnwrap(InkStrip(image: image)), text: text,
                                               caretX: 600, scale: scale, expectedSize: 16))
        XCTAssertEqual(fit.family, "Roboto")
        XCTAssertEqual(fit.pointSize, 15, accuracy: 0.5)
    }

    func testTooLittleTextGivesNoFit() throws {
        let image = screenshot("Hi", family: FontFitter.systemFamily, size: 14, ink: darkInk, background: lightBG)
        XCTAssertNil(FontFitter.fit(strip: try XCTUnwrap(InkStrip(image: image)), text: "Hi",
                                    caretX: 600, scale: scale, expectedSize: 14))
    }
}
