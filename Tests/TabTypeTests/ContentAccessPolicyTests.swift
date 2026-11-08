import XCTest
@testable import TabType

@MainActor
final class ContentAccessPolicyTests: XCTestCase {
    private func allowed(enabled: Bool = true, app: Bool = true, domain: Bool = true,
                         host: String? = "chat.example.com", excluded: Set<String> = [],
                         browser: Bool = true, secure: Bool = false, credential: Bool = false) -> Bool {
        ContentAccessPolicy.allows(enabled: enabled, appEnabled: app, domainEnabled: domain,
                                   host: host, disabledDomains: excluded, isBrowser: browser,
                                   secure: secure, credential: credential)
    }

    func testHardDenialsAndCredentialFieldsOverrideEnabledContext() {
        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed(enabled: false))
        XCTAssertFalse(allowed(app: false))
        XCTAssertFalse(allowed(domain: false))
        XCTAssertFalse(allowed(secure: true))
        XCTAssertFalse(allowed(credential: true))
    }

    func testDomainExclusionsHandleSubdomainsAndUnresolvedBrowsers() {
        XCTAssertFalse(allowed(excluded: ["EXAMPLE.COM"]))
        XCTAssertFalse(allowed(host: "chat.example.com.", excluded: ["example.com"]))
        XCTAssertFalse(allowed(host: nil, excluded: ["example.com"]))
        XCTAssertTrue(allowed(host: "notexample.com", excluded: ["example.com"]))
        XCTAssertTrue(allowed(host: nil, excluded: ["example.com"], browser: false))
    }

    func testMostSpecificDomainRuleWinsRegardlessOfDictionaryOrder() {
        let saved = AppPolicyStore.userOverrides
        defer { AppPolicyStore.userOverrides = saved }
        for reverse in [false, true] {
            let rules: [(String, AppOverride)] = [
                ("domain:example.com", AppOverride(enabled: true)),
                ("domain:private.example.com", AppOverride(enabled: false)),
            ]
            AppPolicyStore.userOverrides = Dictionary(uniqueKeysWithValues: reverse ? rules.reversed() : rules)
            XCTAssertFalse(AppPolicyStore.policy(forBundleId: "com.apple.Safari", host: "private.example.com").isEnabled)
        }
    }

    func testDeniedKeystrokeNeverReachesContentOrNavigationCallbacks() throws {
        let monitor = KeystrokeMonitor()
        var edits = 0
        var controls = 0
        monitor.shouldObserveInput = { false }
        monitor.onEdit = { _, _, _, _ in edits += 1 }
        monitor.handleControlKey = { _, _ in controls += 1; return .notControl }
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        XCTAssertNotNil(monitor.handle(type: .keyDown, event: event))
        XCTAssertEqual(edits, 0)
        XCTAssertEqual(controls, 0)
        monitor.shouldObserveInput = { true }
        XCTAssertNotNil(monitor.handle(type: .keyDown, event: event))
        XCTAssertEqual(edits, 1)
        XCTAssertEqual(controls, 1)
    }

    func testMissingAuthorizedWindowDoesNotStartScreenCapture() async {
        let capture = await ScreenContextProvider.captureFocusedWindow(
            pid: nil, fieldText: "", cropMode: .caretCropped, caretRect: nil, windowFrame: nil)
        XCTAssertNil(capture)
    }

    func testOnlyAnUnambiguousFocusedWindowCanBeCaptured() {
        let frame = CGRect(x: 10, y: 20, width: 600, height: 400)
        XCTAssertEqual(ContentAccessPolicy.windowIndex(pid: 42, frame: frame, windows: [(42, frame)]), 0)
        XCTAssertNil(ContentAccessPolicy.windowIndex(pid: 42, frame: frame, windows: [(43, frame)]))
        XCTAssertNil(ContentAccessPolicy.windowIndex(pid: 42, frame: frame, windows: [(42, frame), (42, frame)]))
        XCTAssertNil(ContentAccessPolicy.windowIndex(pid: 42, frame: frame, windows: [(42, frame.offsetBy(dx: 50, dy: 0))]))
    }
}
