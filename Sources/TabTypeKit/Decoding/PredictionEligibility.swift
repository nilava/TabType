import Foundation

/// Content-only eligibility shared by app scheduling and offline evaluation.
/// This does not replace foreground-field or permission authorization.
public enum PredictionEligibility {
    public static func shouldPredict(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        
        // Wait for at least 1 word on the current line before predicting (or a very long first word).
        let currentLine = input.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        let lineTrimmed = currentLine.trimmingCharacters(in: .whitespaces)
        let completedWord = currentLine.last?.isWhitespace == true && !lineTrimmed.isEmpty
        guard completedWord || lineTrimmed.contains(where: { $0.isWhitespace }) || lineTrimmed.count >= 3 else { return false }
        if let last = input.last, "/@".contains(last) { return false }
        if let lastWord = input.split(whereSeparator: \.isWhitespace).last {
            if lastWord.contains("://") { return false }
            let lower = lastWord.lowercased()
            if lower.hasPrefix("www.") || lower.hasPrefix("https:") || lower.hasPrefix("http:") { return false }
            // Typing an email address (content-based backstop for credential
            // fields the AX label check can't identify): "x@y" mid-word. A chat
            // @mention has nothing before the "@" and stays allowed.
            if let at = lastWord.firstIndex(of: "@"), at != lastWord.startIndex,
               lastWord.index(after: at) != lastWord.endIndex {
                return false
            }
        }
        return true
    }
}
