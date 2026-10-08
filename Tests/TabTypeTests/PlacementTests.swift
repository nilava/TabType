import XCTest
import CryptoKit
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

final class SettleTests: XCTestCase {
    func testCaretMovedByTypedCharacter() {
        let before = CGRect(x: 100, y: 50, width: 1, height: 18)
        XCTAssertTrue(Engine.caretMoved(before.offsetBy(dx: 7, dy: 0), from: before))
        XCTAssertTrue(Engine.caretMoved(CGRect(x: 10, y: 70, width: 1, height: 18), from: before))   // wrapped
        XCTAssertFalse(Engine.caretMoved(before.offsetBy(dx: 0.2, dy: 0), from: before))
    }

    func testSameCaretNeedsPositionAndHeight() {
        let a = CGRect(x: 100, y: 50, width: 1, height: 18)
        XCTAssertTrue(Engine.sameCaret(a, a.offsetBy(dx: 0.3, dy: 0)))
        XCTAssertFalse(Engine.sameCaret(a, CGRect(x: 100, y: 50, width: 1, height: 22)))
    }
}

final class SpliceTests: XCTestCase {
    func testTypedAheadIntoSuggestion() {
        XCTAssertEqual(Engine.splice(" at it", requested: "take a look", current: "take a look a"), "t it")
        XCTAssertEqual(Engine.splice("ing the report", requested: "I am send", current: "I am sending "), "the report")
    }

    func testDivergentDeletedOrUsedUp() {
        XCTAssertNil(Engine.splice(" at it", requested: "take a look", current: "take a look o"))
        XCTAssertNil(Engine.splice(" at it", requested: "take a look", current: "take a loo"))
        XCTAssertNil(Engine.splice(" at", requested: "take a look", current: "take a look at"))
        XCTAssertNil(Engine.splice(" at", requested: "take a look", current: "take a look"))
    }
}

final class FieldSizeGateTests: XCTestCase {
    func testChatComposersPassSearchBoxesDont() {
        XCTAssertTrue(Engine.fieldIsLargeEnough(CGRect(x: 0, y: 0, width: 626, height: 20)))   // one-line composer
        XCTAssertTrue(Engine.fieldIsLargeEnough(CGRect(x: 0, y: 0, width: 200, height: 40)))   // small text area
        XCTAssertFalse(Engine.fieldIsLargeEnough(CGRect(x: 0, y: 0, width: 220, height: 22)))  // search box
        XCTAssertFalse(Engine.fieldIsLargeEnough(CGRect(x: 0, y: 0, width: 60, height: 60)))   // tiny
        XCTAssertTrue(Engine.fieldIsLargeEnough(CGRect(x: 0, y: 0, width: 1, height: 18)))     // hidden input
    }
}

final class HiddenInputTests: XCTestCase {
    func testHiddenTextareaFrameIsTheCaret() {
        let field = CGRect(x: 412, y: 300, width: 1, height: 18)
        XCTAssertEqual(AccessibilityBridge.hiddenInputCaret(field), CGRect(x: 412, y: 300, width: 1, height: 18))
        XCTAssertNil(AccessibilityBridge.hiddenInputCaret(CGRect(x: 70, y: 1080, width: 1, height: 1)))
    }

    func testReportedCaretMustAgreeWithTheHiddenInput() {
        let field = CGRect(x: 412, y: 300, width: 1, height: 18)
        XCTAssertTrue(AccessibilityBridge.hiddenInputAgrees(CGRect(x: 411, y: 300, width: 1, height: 18), field))
        XCTAssertFalse(AccessibilityBridge.hiddenInputAgrees(CGRect(x: 80, y: 300, width: 1, height: 18), field))
    }
}

final class TerminalPromptTests: XCTestCase {
    func testClaudeCodeStyleBox() {
        let screen = "● Done.\n\n╭──────────────────────────────╮\n│ > can you also fix the tes"
        XCTAssertEqual(TerminalPrompt.input(before: screen), "can you also fix the tes")
    }

    func testCodexGutter() {
        XCTAssertEqual(TerminalPrompt.input(before: "some output\n› refactor the parser so"), "refactor the parser so")
    }

    func testShellPromptsAreNotAgents() {
        XCTAssertNil(TerminalPrompt.input(before: "nilava@mac TabType % git sta"))
        XCTAssertNil(TerminalPrompt.input(before: "$ ls -la"))
        // A ">" continuation line without a box isn't an agent prompt.
        XCTAssertNil(TerminalPrompt.input(before: "echo \"hi\n> there"))
    }
}

final class InsertionWorkaroundTests: XCTestCase {
    func testStraightQuotesAndNonBreakingSpaces() {
        var o = InsertionOptions()
        XCTAssertEqual(TextInserter.transformed("it\u{2019}s \u{201C}ok\u{201D}", options: o), "it\u{2019}s \u{201C}ok\u{201D}")
        o.straightQuotes = true
        XCTAssertEqual(TextInserter.transformed("it\u{2019}s \u{201C}ok\u{201D}", options: o), "it's \"ok\"")
        o.nonBreakingSpaces = true
        XCTAssertEqual(TextInserter.transformed("at it", options: o), "at\u{00A0}it")
    }
}

final class EmojiGenderTests: XCTestCase {
    private func emoji(_ code: String) -> Emoji {
        try! JSONDecoder().decode(Emoji.self, from: Data("{\"code\":\"\(code)\",\"char\":\"x\"}".utf8))
    }

    func testPreferredGenderFirstNeutralOptional() {
        let ranked = ["ok_person", "ok_man", "ok_woman", "ok_hand"].map(emoji)
        XCTAssertEqual(EmojiMatcher.preferringGender(ranked, gender: "woman", includeNeutral: true).map(\.code),
                       ["ok_woman", "ok_person", "ok_man", "ok_hand"])
        XCTAssertEqual(EmojiMatcher.preferringGender(ranked, gender: "man", includeNeutral: false).map(\.code),
                       ["ok_man", "ok_woman", "ok_hand"])
        XCTAssertEqual(EmojiMatcher.preferringGender(ranked, gender: "any", includeNeutral: false).map(\.code),
                       ranked.map(\.code))
    }
}

final class UpdaterTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(Updater.isNewer("2.1.0", than: "2.0.0"))
        XCTAssertTrue(Updater.isNewer("1.10.0", than: "1.9.2"))
        XCTAssertFalse(Updater.isNewer("2.0.0", than: "2.0.0"))
        XCTAssertFalse(Updater.isNewer("2.0", than: "2.0.1"))
        XCTAssertTrue(Updater.isNewer("2.1.0-beta", than: "2.0.9"))
    }

    func testChecksumFromReleaseNotes() {
        let notes = "Install…\n\n**SHA-256** `9509A310CE630535FCCF24B5341A454C3FB7760B58AFC5440867B7AA686D7BB5`\n"
        XCTAssertEqual(Updater.sha256(inNotes: notes), "9509a310ce630535fccf24b5341a454c3fb7760b58afc5440867b7aa686d7bb5")
        XCTAssertNil(Updater.sha256(inNotes: "no checksum here"))
    }
}

final class SyncCryptoTests: XCTestCase {
    func testPassphraseKeyIsDeterministicPerSalt() throws {
        let salt = Data(repeating: 7, count: 16)
        let a = try SyncManager.key(passphrase: "correct horse battery", salt: salt)
        let b = try SyncManager.key(passphrase: "correct horse battery", salt: salt)
        let c = try SyncManager.key(passphrase: "correct horse battery", salt: Data(repeating: 8, count: 16))
        let d = try SyncManager.key(passphrase: "another passphrase", salt: salt)
        let raw: (SymmetricKey) -> Data = { $0.withUnsafeBytes { Data($0) } }
        XCTAssertEqual(raw(a), raw(b))
        XCTAssertNotEqual(raw(a), raw(c))
        XCTAssertNotEqual(raw(a), raw(d))
        // A payload sealed on one Mac opens on another with the same passphrase only.
        let sealed = try AES.GCM.seal(Data("hello".utf8), using: a).combined!
        XCTAssertEqual(try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: b), Data("hello".utf8))
        XCTAssertThrowsError(try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: d))
    }
}
