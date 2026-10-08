import XCTest
@testable import TabType

final class ContextSnapshotTests: XCTestCase {
    func testCaretSplitUsesUTF16Offsets() {
        // "👍🏽" is 4 UTF-16 units but 1 Character; AX reports UTF-16 offsets.
        let text = "ok 👍🏽 then more"
        let caret = ("ok 👍🏽 then" as NSString).length
        let parts = AccessibilityBridge.split(text, caretUTF16: caret)
        XCTAssertEqual(parts.before, "ok 👍🏽 then")
        XCTAssertEqual(parts.after, " more")
    }

    func testCaretSplitNeverBreaksAComposedCharacter() {
        let text = "a👍🏽b"
        let parts = AccessibilityBridge.split(text, caretUTF16: 2)   // inside the emoji
        XCTAssertEqual(parts.before + parts.after, text)
        XCTAssertTrue(parts.before == "a" || parts.before == "a👍🏽")
    }

    func testCaretSplitClampsAndDefaultsToEnd() {
        XCTAssertEqual(AccessibilityBridge.split("abc", caretUTF16: nil).before, "abc")
        XCTAssertEqual(AccessibilityBridge.split("abc", caretUTF16: 99).after, "")
        XCTAssertEqual(AccessibilityBridge.split("abc", caretUTF16: -3).before, "")
    }

    func testStableTitleDropsUnreadCountsAndMarkers() {
        XCTAssertEqual(ScreenContextProvider.stableTitle("(3) #design — Acme — Slack"), "#design — Acme — Slack")
        XCTAssertEqual(ScreenContextProvider.stableTitle("• Notes.txt"), "Notes.txt")
        XCTAssertEqual(ScreenContextProvider.stableTitle("Inbox (12)"), "Inbox")
        XCTAssertEqual(ScreenContextProvider.stableTitle("  "), nil)
        XCTAssertEqual(ScreenContextProvider.stableTitle("#general — Acme — Slack"), "#general — Acme — Slack")
    }
}
