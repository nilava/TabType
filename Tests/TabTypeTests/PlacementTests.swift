import XCTest
import AppKit
@testable import TabType

final class PlacementTests: XCTestCase {

    // MARK: - Font from AX

    func testInstalledFaceResolvesByName() {
        let font = AccessibilityBridge.resolveFont(name: "Georgia", family: "Georgia", size: 18)
        XCTAssertEqual(font.familyName, "Georgia")
        XCTAssertEqual(font.pointSize, 18)
    }

    func testFamilyUsedWhenNameUnknown() {
        let font = AccessibilityBridge.resolveFont(name: "NoSuchFont-Regular", family: "Menlo", size: 11)
        XCTAssertEqual(font.familyName, "Menlo")
    }

    func testSizeOnlyFallsBackToSystemFontAtThatSize() {
        // Chromium sometimes reports only AXFontSize.
        let font = AccessibilityBridge.resolveFont(name: nil, family: nil, size: 15)
        XCTAssertEqual(font.pointSize, 15)
        XCTAssertEqual(font.familyName, NSFont.systemFont(ofSize: 15).familyName)
    }

    // MARK: - Caret geometry

    func testSameLineIsRelativeToLineHeight() {
        let a = CGRect(x: 10, y: 100, width: 1, height: 20)
        XCTAssertTrue(AccessibilityBridge.sameLine(a, CGRect(x: 40, y: 101, width: 0, height: 20)))
        XCTAssertFalse(AccessibilityBridge.sameLine(a, CGRect(x: 40, y: 104, width: 0, height: 20)))
        XCTAssertFalse(AccessibilityBridge.sameLine(a, CGRect(x: 40, y: 100, width: 0, height: 30)))
    }

    func testSingleLineFieldSnapsStrayCaret() {
        let field = CGRect(x: 0, y: 100, width: 300, height: 24)
        let caret = CGRect(x: 50, y: 130, width: 1, height: 18)   // mid 139, below the field
        let snapped = AccessibilityBridge.snappedToSingleLineField(caret, field: field)
        XCTAssertEqual(snapped.midY, field.midY, accuracy: 0.001)
        XCTAssertEqual(snapped.minX, caret.minX)
    }

    func testCaretInsideFieldOrTallFieldIsLeftAlone() {
        let caret = CGRect(x: 50, y: 103, width: 1, height: 18)
        let single = CGRect(x: 0, y: 100, width: 300, height: 24)
        XCTAssertEqual(AccessibilityBridge.snappedToSingleLineField(caret, field: single), caret)
        let tall = CGRect(x: 0, y: 0, width: 300, height: 400)
        let outside = CGRect(x: 50, y: 500, width: 1, height: 18)
        XCTAssertEqual(AccessibilityBridge.snappedToSingleLineField(outside, field: tall), outside)
    }

    // MARK: - Ghost layout

    func testDefaultBaselineCentresGlyphBox() {
        let font = NSFont.systemFont(ofSize: 14)
        let caret = CGRect(x: 0, y: 100, width: 1, height: 30)   // inflated CSS line box
        let glyphBox = font.ascender + abs(font.descender)
        let baseline = SuggestionOverlay.defaultBaseline(caret: caret, font: font)
        XCTAssertEqual(baseline - font.ascender - 100, (30 - glyphBox) / 2, accuracy: 0.001)
    }

    @MainActor
    func testGhostViewHasNoHorizontalPaddingAndReportsBaseline() {
        let view = GhostTextView(frame: .zero)
        let font = NSFont.systemFont(ofSize: 14)
        let laid = view.configure(text: "hello world", font: font, color: .black, width: 400,
                                  firstLineIndent: 0, maxLines: 1)
        XCTAssertEqual(laid.firstBaseline, font.ascender, accuracy: 1.0)
        XCTAssertGreaterThan(laid.height, 10)
    }

    @MainActor
    func testGhostViewWrapsWithIndentAndCapsLines() {
        let view = GhostTextView(frame: .zero)
        let font = NSFont.systemFont(ofSize: 14)
        let text = String(repeating: "word ", count: 60)
        let one = view.configure(text: text, font: font, color: .black, width: 200,
                                 firstLineIndent: 120, maxLines: 1)
        let three = view.configure(text: text, font: font, color: .black, width: 200,
                                   firstLineIndent: 120, maxLines: 3)
        XCTAssertEqual(three.height, one.height * 3, accuracy: 2)
    }
}
