import XCTest
@testable import TabType

final class TranscriptNormalizerTests: XCTestCase {

    func testPreservesMeetingTimesAndRelativeTimingInsideMessages() {
        let lines = [
            "Avery: Please meet me at 6:30 PM by the library.",
            "The train leaves Today at 2:40 PM from platform four.",
            "I sent the revised link 2 minutes ago, after the meeting.",
            "Yesterday at 9:15 AM was the start, not the deadline."
        ]
        for line in lines { XCTAssertEqual(TranscriptNormalizer.normalize(line), line) }
    }

    func testSpeakerLabelProtectsMessagesThatResembleStatusText() {
        for line in ["Avery: Morgan is typing…", "Morgan: Delivered", "Avery: Active now"] {
            XCTAssertEqual(TranscriptNormalizer.normalize(line), line)
        }
    }

    func testStripsNoiseLinesKeepsMessages() {
        let raw = """
        Nilava
        2 minutes ago
        the deploy finished, all services green
        3:15 PM
        Priya is typing…
        Active now
        Seen by Priya
        great — can you share the dashboard link?
        """
        let out = TranscriptNormalizer.normalize(raw)
        XCTAssertTrue(out.contains("deploy finished"))
        XCTAssertTrue(out.contains("dashboard link"))
        XCTAssertFalse(out.contains("is typing"))
        XCTAssertFalse(out.contains("Active now"))
        XCTAssertFalse(out.contains("3:15 PM"))
        XCTAssertFalse(out.contains("Seen by"))
    }

    func testPreservesAmbiguousInlineMetadataButDropsStandaloneMarkers() {
        let text = "sounds good (edited) Today at 9:41 AM let's ship it"
        XCTAssertEqual(TranscriptNormalizer.normalize(text), text)
        XCTAssertEqual(TranscriptNormalizer.normalize("2 minutes ago\n(edited)\n" + text), text)
    }

    func testJitterIsNotMeaningfulChange() {
        let old = "alice: shipping tonight\nbob: sounds good, see you tomorrow at standup"
        // Same conversation, one extra noise-free char shuffle earlier on — same tail.
        let new = "alice: shipping tonight!\nbob: sounds good, see you tomorrow at standup"
        XCTAssertFalse(TranscriptNormalizer.isMeaningfulChange(old: old, new: new, tailChars: 40))
    }

    func testNewMessageIsMeaningfulChange() {
        let old = "alice: shipping tonight\nbob: sounds good"
        let new = old + "\nalice: actually let's wait for the tests"
        XCTAssertTrue(TranscriptNormalizer.isMeaningfulChange(old: old, new: new))
    }

    func testLargeLengthSwingIsMeaningful() {
        let old = String(repeating: "conversation text ", count: 50) + "same tail here"
        let new = "same tail here"   // window collapsed — big shrink, same tail
        XCTAssertTrue(TranscriptNormalizer.isMeaningfulChange(old: old, new: new, tailChars: 14))
    }
}
