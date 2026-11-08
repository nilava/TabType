import XCTest
@testable import TabType

@MainActor
final class MacOSPredictionPreferenceTests: XCTestCase {
    func testUnusedFeatureDoesNotChangeExistingSystemPreference() throws {
        let suite = "TabTypePredictionTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var current: Bool? = false
        var writes = 0
        let preference = MacOSPredictionPreference(defaults: defaults, read: { current }, write: { current = $0; writes += 1 })
        preference.apply(disabled: false)
        XCTAssertEqual(current, false)
        XCTAssertEqual(writes, 0)
    }

    func testReleaseRestoresOriginalChoiceAcrossRelaunch() throws {
        for original: Bool? in [nil, false, true] {
            let suite = "TabTypePredictionTest-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var current = original
            MacOSPredictionPreference(defaults: defaults, read: { current }, write: { current = $0 }).apply(disabled: true)
            XCTAssertEqual(current, false)
            MacOSPredictionPreference(defaults: defaults, read: { current }, write: { current = $0 }).apply(disabled: true)
            MacOSPredictionPreference(defaults: defaults, read: { current }, write: { current = $0 }).apply(disabled: false)
            XCTAssertEqual(current, original)
        }
    }

    func testReleasePreservesLaterManualChoice() throws {
        let suite = "TabTypePredictionTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var current: Bool? = nil
        let preference = MacOSPredictionPreference(defaults: defaults, read: { current }, write: { current = $0 })
        preference.apply(disabled: true)
        current = true
        preference.apply(disabled: false)
        XCTAssertEqual(current, true)
    }
}
