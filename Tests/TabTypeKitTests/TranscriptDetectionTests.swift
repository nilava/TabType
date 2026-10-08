import XCTest
@testable import TabTypeKit

final class TranscriptDetectionTests: XCTestCase {
    func testLabelledLinesAreATranscript() {
        XCTAssertTrue(PromptAssembler.looksLikeTranscript("Priya: the dashboard is ready\nPriya: can you look?"))
        XCTAssertFalse(PromptAssembler.looksLikeTranscript("Anchoring fixed the recall loss\nRan 4 commands\nType / for commands"))
    }
}
