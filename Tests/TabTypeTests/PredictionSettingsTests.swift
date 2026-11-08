import XCTest
import TabTypeKit
@testable import TabType

@MainActor
final class PredictionSettingsTests: XCTestCase {
    private func settings() -> AppSettings {
        let name = "TabTypeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let overrides = AppPolicyStore.userOverrides
        let verbose = Log.shared.verbose
        addTeardownBlock { @MainActor in
            defaults.removePersistentDomain(forName: name)
            AppPolicyStore.userOverrides = overrides
            Log.shared.verbose = verbose
        }
        return AppSettings(defaults: defaults)
    }

    func testStylePersistsAndUnknownPreferenceUsesBalanced() {
        let name = "TabTypeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let overrides = AppPolicyStore.userOverrides
        let verbose = Log.shared.verbose
        defer {
            defaults.removePersistentDomain(forName: name)
            AppPolicyStore.userOverrides = overrides
            Log.shared.verbose = verbose
        }
        XCTAssertEqual(AppSettings(defaults: defaults).predictionStyle, .balanced)
        AppSettings(defaults: defaults).predictionStyle = .careful
        XCTAssertEqual(AppSettings(defaults: defaults).predictionStyle, .careful)
        defaults.set("future-style", forKey: "predictionStyle")
        XCTAssertEqual(AppSettings(defaults: defaults).predictionStyle, .balanced)
    }

    func testOldAndUnknownSyncValuesPreservePrivacySettings() throws {
        let settings = settings()
        settings.predictionStyle = .careful
        settings.collectTypingHistory = false
        settings.personalizationScope = .currentApp
        var disabled = AppOverride()
        disabled.enabled = false
        disabled.predictionStyle = "future-style"
        settings.appOverrides = ["test.app": disabled]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings.syncSnapshot)) as? [String: Any])
        object.removeValue(forKey: "predictionStyle")
        object.removeValue(forKey: "personalizationScope")
        let legacy = try JSONDecoder().decode(SyncedSettings.self, from: JSONSerialization.data(withJSONObject: object))
        settings.apply(legacy)
        XCTAssertEqual(settings.predictionStyle, .careful)
        XCTAssertFalse(settings.collectTypingHistory)
        XCTAssertEqual(settings.personalizationScope, .currentApp)
        XCTAssertEqual(settings.appOverrides["test.app"]?.enabled, false)
        object["predictionStyle"] = "future-style"
        object["personalizationScope"] = "future-scope"
        settings.personalizationScope = .allApps
        settings.apply(try JSONDecoder().decode(SyncedSettings.self, from: JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(settings.predictionStyle, .careful)
        XCTAssertEqual(settings.personalizationScope, .currentApp)
        XCTAssertFalse(AppPolicyStore.policy(forBundleId: "test.app").isEnabled)
    }

    func testScopeDefaultsToCurrentAppAndSyncRoundTripPreservesExplicitChoice() throws {
        let settings = settings()
        XCTAssertEqual(settings.personalizationScope, .currentApp)
        settings.personalizationScope = .allApps
        let synced = try JSONDecoder().decode(SyncedSettings.self, from: JSONEncoder().encode(settings.syncSnapshot))
        settings.personalizationScope = .currentApp
        settings.apply(synced)
        XCTAssertEqual(settings.personalizationScope, .allApps)
    }

    func testAppAndWebsiteStylesResolveWithoutLosingAnExplicitDisable() throws {
        let previous = AppPolicyStore.userOverrides
        defer { AppPolicyStore.userOverrides = previous }
        let app = try JSONDecoder().decode(AppOverride.self, from: Data(#"{"enabled":false,"improveCompatibility":false,"customInstructions":"","predictionStyle":"future-style"}"#.utf8))
        AppPolicyStore.userOverrides = ["test.app": app]
        XCTAssertFalse(AppPolicyStore.policy(forBundleId: "test.app").isEnabled)
        XCTAssertNil(AppPolicyStore.policy(forBundleId: "test.app").predictionStyle)
        var base = AppOverride(); base.predictionStyle = "careful"
        var domain = AppOverride(); domain.predictionStyle = "frequent"
        AppPolicyStore.userOverrides = ["com.apple.Safari": base, "domain:example.com": domain]
        XCTAssertEqual(AppPolicyStore.policy(forBundleId: "com.apple.Safari").predictionStyle, .careful)
        XCTAssertEqual(AppPolicyStore.policy(forBundleId: "com.apple.Safari", host: "sub.example.com").predictionStyle, .frequent)
    }
}
