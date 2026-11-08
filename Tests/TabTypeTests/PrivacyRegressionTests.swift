import XCTest
@testable import TabType

@MainActor
final class PrivacyRegressionTests: XCTestCase {
    func testWebsiteRuleNormalizesURLsAndNumericAliases() {
        for input in ["private.example.com:8443", "https://PRIVATE.example.com:8443/account?q=1", "private.example.com."] {
            XCTAssertEqual(WebsiteRule.host(from: input), "private.example.com", input)
        }
        XCTAssertEqual(WebsiteRule.host(from: "http://127.1:8080/"), "127.0.0.1")
        XCTAssertEqual(WebsiteRule.host(from: "http://2130706433/"), "127.0.0.1")
        XCTAssertEqual(WebsiteRule.host(from: "https://[0:0:0:0:0:0:0:1]:8443/"), "::1")
        XCTAssertTrue(WebsiteRule.matches(host: "sub.private.example.com", rule: "https://private.example.com:8443/"))
        XCTAssertFalse(WebsiteRule.matches(host: "private.example.com.evil.test", rule: "private.example.com"))
    }

    func testInvalidExclusionsFailClosedInsteadOfDisappearing() {
        for input in ["", "https://user:secret@example.com", "file:///private", "*.example.com", "example.com:99999", "not a host"] {
            XCTAssertNil(WebsiteRule.host(from: input), input)
        }
        XCTAssertFalse(ContentAccessPolicy.allows(
            enabled: true, appEnabled: true, domainEnabled: true,
            host: "private.example.com", disabledDomains: ["*.example.com"],
            isBrowser: true, secure: false, credential: false))
    }

    func testLegacyDomainOverrideAliasesHonorDenialAndSpecificity() {
        let previous = AppPolicyStore.userOverrides
        defer { AppPolicyStore.userOverrides = previous }
        var denied = AppOverride()
        denied.enabled = false
        var allowed = AppOverride()
        allowed.enabled = true
        AppPolicyStore.userOverrides = [
            "domain:private.example.com:8443": denied,
            "domain:private.example.com": allowed,
            "domain:sub.private.example.com": allowed,
        ]
        XCTAssertFalse(AppPolicyStore.policy(forBundleId: "test.browser", host: "private.example.com").isEnabled)
        XCTAssertTrue(AppPolicyStore.policy(forBundleId: "test.browser", host: "sub.private.example.com").isEnabled)
    }

    func testPersistedPortExclusionDeniesItsHost() {
        XCTAssertFalse(ContentAccessPolicy.allows(
            enabled: true, appEnabled: true, domainEnabled: true,
            host: "private.example.com", disabledDomains: ["private.example.com:8443"],
            isBrowser: true, secure: false, credential: false))
    }

    func testUnrelatedHostAndBareHostControl() {
        XCTAssertTrue(ContentAccessPolicy.allows(
            enabled: true, appEnabled: true, domainEnabled: true,
            host: "public.example.net", disabledDomains: ["private.example.com"],
            isBrowser: true, secure: false, credential: false))
        XCTAssertFalse(ContentAccessPolicy.allows(
            enabled: true, appEnabled: true, domainEnabled: true,
            host: "private.example.com", disabledDomains: ["private.example.com"],
            isBrowser: true, secure: false, credential: false))
    }
}
