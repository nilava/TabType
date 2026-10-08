import XCTest
@testable import TabTypeKit

final class SecretSanitizerTests: XCTestCase {
    private func s(_ text: String) -> String { SecretSanitizer.sanitize(text) }
    private let r = SecretSanitizer.placeholder

    func testProviderKeys() {
        XCTAssertEqual(s("key sk-proj-abcdEFGH1234ijklMNOP5678qrst done"), "key \(r) done")
        XCTAssertEqual(s("export AWS=AKIAIOSFODNN7EXAMPLE"), "export AWS=\(r)")
        XCTAssertEqual(s("token ghp_0123456789abcdefghijABCDEFGHIJ0123456789"), "token \(r)")
        XCTAssertEqual(s("slack xoxb-1234567890-abcdefghij"), "slack \(r)")
        XCTAssertEqual(s("AIzaSyA1234567890abcdefghijklmnopqrstuv"), r)
        XCTAssertEqual(s("stripe sk_live_51H8abcdefghijklmnop"), "stripe \(r)")
    }

    func testJWTAndBearer() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        XCTAssertEqual(s("Authorization: Bearer \(jwt)"), "Authorization: Bearer \(r)")
        XCTAssertEqual(s("token \(jwt)"), "token \(r)")
    }

    func testPasswordAssignmentsKeepTheLabel() {
        XCTAssertEqual(s("password: hunter2!x"), "password: \(r)")
        XCTAssertEqual(s("API_KEY=abc123xyz"), "API_KEY=\(r)")
        XCTAssertEqual(s(#"{"client_secret": "s3cr3tvalue"}"#), #"{"client_secret": \#(r)}"#)
        XCTAssertEqual(s("Kennwort: Sommer2024"), "Kennwort: \(r)")
    }

    func testURLsLoseOnlyTheirSecrets() {
        XCTAssertEqual(s("https://bucket.s3.amazonaws.com/f.pdf?X-Amz-Signature=abcdef123456&x=1"),
                       "https://bucket.s3.amazonaws.com/f.pdf?X-Amz-Signature=\(r)&x=1")
        XCTAssertEqual(s("postgres://admin:Pa55word@db.internal:5432/app"),
                       "postgres://admin:\(r)@db.internal:5432/app")
        XCTAssertEqual(s("see https://example.com/docs/getting-started"), "see https://example.com/docs/getting-started")
    }

    func testPrivateKeyBlock() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEow\nabc\n-----END RSA PRIVATE KEY-----"
        XCTAssertEqual(s("before\n\(pem)\nafter"), "before\n\(r)\nafter")
    }

    func testCardNumbersOnlyWhenLuhnValid() {
        XCTAssertEqual(s("card 4242 4242 4242 4242 exp"), "card \(r) exp")
        XCTAssertEqual(s("order 1234 5678 9012 3456 shipped"), "order 1234 5678 9012 3456 shipped")
    }

    func testIBAN() {
        XCTAssertEqual(s("pay to DE89 3704 0044 0532 0130 00 please"), "pay to \(r) please")
    }

    func testRandomTokensButNotOrdinaryText() {
        XCTAssertEqual(s("id Zx9Qp2Lm8Rt5Vw3Yb7Nc1Kd4Hf6Gj0Sa"), "id \(r)")
        // Ordinary long words, slugs, hex digests and numbers survive.
        let keep = [
            "internationalization-and-localization-guidelines-document",
            "commit 3f786850e387550fdab836ed7e6dc881de23001b fixed it",
            "invoice 4471 is overdue by 15 days",
            "The quarterly planning session is on Monday at 10am in the large room.",
            "Thanks for the PR #2276, merging it now.",
        ]
        for text in keep { XCTAssertEqual(s(text), text) }
    }

    func testOrdinaryProseIsUntouched() {
        let prose = "Hi Ramesh,\n\nThank you for sending the proposed terms. My password manager keeps nagging me, ha."
        XCTAssertEqual(s(prose), prose)
    }
}
