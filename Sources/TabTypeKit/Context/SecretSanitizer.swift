import Foundation

/// Removes credentials and other secrets from text before it is used as context or
/// written to the (encrypted) typing history. Everything runs on-device; this keeps
/// secrets that happen to be on screen or in the clipboard out of prompts, logs
/// and stored history altogether.
///
/// Rules are deliberately specific (known key formats, explicit `password=`
/// assignments, Luhn-valid card numbers…) so ordinary prose, numbers and code
/// survive untouched.
public enum SecretSanitizer {
    public static let placeholder = "[redacted]"

    private struct Rule {
        let regex: NSRegularExpression
        /// Capture group kept before the redaction (e.g. the "password: " label).
        let keepGroup: Int?
        init(_ pattern: String, keepGroup: Int? = nil, caseInsensitive: Bool = false) {
            regex = try! NSRegularExpression(pattern: pattern,
                                             options: caseInsensitive ? [.caseInsensitive] : [])
            self.keepGroup = keepGroup
        }
    }

    private static let rules: [Rule] = [
        // PEM private keys (multi-line).
        Rule(#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#),
        // JSON Web Tokens.
        Rule(#"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#),
        // Provider key formats.
        Rule(#"\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}"#),                 // OpenAI / Anthropic
        Rule(#"\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{16,}"#),          // Stripe
        Rule(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),                          // AWS access key id
        Rule(#"\bgh[pousr]_[A-Za-z0-9]{30,}"#),                           // GitHub
        Rule(#"\bgithub_pat_[A-Za-z0-9_]{40,}"#),
        Rule(#"\bglpat-[A-Za-z0-9_-]{20,}"#),                             // GitLab
        Rule(#"\bxox[abposr]-[A-Za-z0-9-]{10,}"#),                        // Slack
        Rule(#"\bAIza[0-9A-Za-z_-]{35}"#),                                // Google API
        Rule(#"\bhf_[A-Za-z0-9]{30,}"#),                                  // Hugging Face
        Rule(#"\bnpm_[A-Za-z0-9]{36}"#),
        // Authorization headers.
        Rule(#"(\b(?:Bearer|Basic)\s+)[A-Za-z0-9._~+/=-]{16,}"#, keepGroup: 1, caseInsensitive: true),
        // Signed-URL parameters and token-like query values.
        Rule(#"([?&](?:sig|signature|x-amz-signature|x-goog-signature|token|access_token|api_key|apikey|key|secret|password)=)[^&\s"'<>]{6,}"#,
             keepGroup: 1, caseInsensitive: true),
        // Explicit secret assignments: "password: hunter2", "API_KEY=...", "secret = '...'".
        Rule(#"(\b(?:password|passwd|passphrase|pwd|kennwort|mot de passe|contraseña|secret|client[_-]?secret|api[_-]?key|access[_-]?key|private[_-]?key|auth[_-]?token|access[_-]?token|refresh[_-]?token)\b["']?\s*[:=]\s*)(["']?)[^\s"',;]{4,}\2"#,
             keepGroup: 1, caseInsensitive: true),
        // Connection strings with inline credentials: scheme://user:pass@host
        Rule(#"(\b[a-z][a-z0-9+.-]*://[^\s:/@]+:)[^\s@/]{3,}(?=@)"#, keepGroup: 1, caseInsensitive: true),
        // IBAN.
        Rule(#"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){3,7}(?:[ ]?[A-Z0-9]{1,3})?\b"#),
    ]

    /// Card-number candidates; only Luhn-valid ones are redacted.
    private static let cardCandidate = try! NSRegularExpression(pattern: #"\b\d(?:[ -]?\d){12,18}\b"#)
    /// Long unbroken runs mixing letters and digits (random tokens, keys, hashes).
    private static let opaqueToken = try! NSRegularExpression(pattern: #"\b[A-Za-z0-9_\-+/]{32,}={0,2}\b"#)

    public static func sanitize(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for rule in rules {
            result = replace(rule.regex, in: result, keepGroup: rule.keepGroup)
        }
        result = replaceMatches(cardCandidate, in: result) { match in
            let digits = match.filter(\.isNumber)
            return (13...19).contains(digits.count) && luhnValid(digits) ? placeholder : nil
        }
        result = replaceMatches(opaqueToken, in: result) { match in
            looksRandom(match) ? placeholder : nil
        }
        return result
    }

    // MARK: Helpers

    private static func replace(_ regex: NSRegularExpression, in text: String, keepGroup: Int?) -> String {
        let ns = text as NSString
        var output = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if let g = keepGroup, m.range(at: g).location != NSNotFound {
                output += ns.substring(with: m.range(at: g))
            }
            output += placeholder
            last = m.range.location + m.range.length
        }
        output += ns.substring(from: last)
        return output
    }

    private static func replaceMatches(_ regex: NSRegularExpression, in text: String,
                                       _ transform: (String) -> String?) -> String {
        let ns = text as NSString
        var output = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let match = ns.substring(with: m.range)
            guard let replacement = transform(match) else { continue }
            output += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            output += replacement
            last = m.range.location + m.range.length
        }
        output += ns.substring(from: last)
        return output
    }

    static func luhnValid(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    /// Random-looking: mixes digits and letters (both cases or symbols) with high
    /// character variety. Long words, slugs and plain numbers don't qualify.
    static func looksRandom(_ token: String) -> Bool {
        let hasDigit = token.contains(where: \.isNumber)
        let hasLower = token.contains(where: \.isLowercase)
        let hasUpper = token.contains(where: \.isUppercase)
        guard hasDigit, hasLower || hasUpper else { return false }
        // Hex digests (git SHAs, checksums) are identifiers, not secrets, when they
        // are lower-case hex — keep them: they're common in technical writing.
        if token.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) { return false }
        let distinct = Set(token).count
        return distinct >= 16 && (hasLower && hasUpper || token.contains(where: { "+/_-".contains($0) }))
    }
}
