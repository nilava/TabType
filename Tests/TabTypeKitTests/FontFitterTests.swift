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
