import XCTest
import AppKit
@testable import TabType

/// Manual: TABTYPE_TRANSCRIPT_APP=<app name> — prints what the transcript
/// extractor reads from that app's focused window (the context a chat gets).
final class TranscriptProbeTests: XCTestCase {
    func testDumpTranscript() throws {
        guard let name = ProcessInfo.processInfo.environment["TABTYPE_TRANSCRIPT_APP"] else { throw XCTSkip("manual") }
        let app = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0.localizedName == name })
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AccessibilityBridge.enableEnhancedAccessibility(pid: app.processIdentifier)
        var window: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window), .success)
        var focused: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused)
        var field = focused.map { $0 as! AXUIElement }
        if field.flatMap({ AccessibilityBridge.role(of: $0) }) != kAXTextAreaRole as String {
            // Not frontmost: find the composer (last text area in the window).
            var queue = [window as! AXUIElement], found: AXUIElement?, visits = 0
            while !queue.isEmpty, visits < 8000 {
                let e = queue.removeFirst(); visits += 1
                if AccessibilityBridge.role(of: e) == kAXTextAreaRole as String { found = e }
                queue += AccessibilityBridge.children(of: e)
            }
            field = found
        }
        print("FIELD role=\(field.flatMap { AccessibilityBridge.role(of: $0) } ?? "nil") frame=\(String(describing: field.flatMap { AccessibilityBridge.elementFrame(of: $0) })) window=\(String(describing: AccessibilityBridge.elementFrame(of: window as! AXUIElement)))")
        let text = TranscriptExtractor.extract(windowElement: window as! AXUIElement, excludingSubtreeOf: field,
                                               columnFrame: field.flatMap { AccessibilityBridge.elementFrame(of: $0) },
                                               budget: 1400)
        print("TRANSCRIPT_BEGIN\n\(text ?? "nil")\nTRANSCRIPT_END")
    }
}
