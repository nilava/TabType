import Foundation

/// Strips the chat-UI noise that makes transcript captures jitter between
/// otherwise-identical snapshots — standalone timestamps, edit markers,
/// message counts, presence/typing lines. Inline message content stays intact.
/// Two goals:
/// (1) the stored snapshot stays byte-identical between real messages, so the
/// prompt's `<on_screen>` block stops invalidating the KV cache on every
/// capture; (2) the model sees conversation, not UI chrome.
enum TranscriptNormalizer {

    /// Lines that are pure UI noise — dropped entirely.
    nonisolated private static let noiseLine: NSRegularExpression = {
        let patterns = [
            #"^\s*\d{1,2}:\d{2}(\s?[AP]M)?\s*$"#,                       // bare clock time
            #"^\s*(Today|Yesterday)( at \d{1,2}:\d{2}(\s?[AP]M)?)?\s*$"#,
            #"^\s*(a few seconds|a minute|\d+\s?(second|minute|hour|day|week)s?)\s+ago\s*$"#,
            #"^\s*\(edited\)\s*$"#,
            #"^\s*\d+\s*(new )?(message|reply|repl(y|ies))s?\s*$"#,     // "3 new messages"
            #"^\s*.{0,40}\bis typing(…|\.{3})?\s*$"#,                   // "X is typing…"
            #"^\s*(Active now|Online|Away|last seen .{0,30})\s*$"#,     // presence
            #"^\s*(Seen|Delivered|Read)( by .{0,40})?\s*$"#,            // receipts
        ]
        return try! NSRegularExpression(pattern: patterns.joined(separator: "|"),
                                        options: [.caseInsensitive])
    }()

    nonisolated static func normalize(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).compactMap { line -> String? in
            let range = NSRange(line.startIndex..., in: line)
            // A sender-labelled line is message content even when its body says
            // "is typing" or "Delivered". Never rewrite dates/times inside prose:
            // those can be the exact facts the completion must use.
            let labelled = line.range(of: #"^\s*[^:\n]{1,32}: \S"#, options: .regularExpression) != nil
            if !labelled, noiseLine.firstMatch(in: line, range: range) != nil { return nil }
            let cleaned = line.replacingOccurrences(of: #"\s{2,}"#, with: " ",
                                                   options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? nil : cleaned
        }
        return lines.joined(separator: "\n")
    }

    /// Whether `new` is a meaningful change over `old`: a real new message always
    /// changes the (normalized) tail; scroll/timestamp jitter doesn't. Lengths
    /// within ±10% with an identical tail ⇒ same conversation state.
    nonisolated static func isMeaningfulChange(old: String, new: String, tailChars: Int = 240) -> Bool {
        guard !old.isEmpty else { return !new.isEmpty }
        if String(old.suffix(tailChars)) != String(new.suffix(tailChars)) { return true }
        let ratio = Double(new.count) / Double(max(1, old.count))
        return ratio < 0.9 || ratio > 1.1
    }
}
