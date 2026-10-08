import Foundation

/// Splits text-to-continue into a prompt that ends on a natural token boundary and
/// the bytes the model must regenerate before anything counts as a suggestion.
///
/// Tokenizers fold the space before a word into that word's token (" proposal"), so
/// a prompt ending in "… the " or "… the propo" ends on a token the model rarely saw
/// in training and predicts badly. Instead the prompt stops before the space, and
/// decoding is constrained to reproduce " " / " propo" first; whatever follows is
/// the suggestion.
public struct HealSplit: Equatable, Sendable {
    /// Text to tokenize as the prompt.
    public var prompt: String
    /// Bytes the generated text must start with (may be empty: no constraint).
    public var heal: [UInt8]

    public init(prompt: String, heal: [UInt8]) {
        self.prompt = prompt
        self.heal = heal
    }

    /// Longest partial word that is healed; longer runs (URLs, hashes) are left in
    /// the prompt — constraining on them buys nothing.
    public static let maxHealCharacters = 24

    public static func split(_ text: String) -> HealSplit {
        guard let last = text.last else { return HealSplit(prompt: text, heal: []) }
        // After a newline or tab the next token starts the line; nothing to heal.
        if last == "\n" || last == "\r" || last == "\t" { return HealSplit(prompt: text, heal: []) }

        if last == " " {
            // Boundary: heal the single space; extra spaces stay in the prompt.
            let prompt = String(text.dropLast())
            return HealSplit(prompt: prompt, heal: [0x20])
        }

        // Inside a word: the trailing run of non-whitespace characters.
        var start = text.endIndex
        while start > text.startIndex, !text[text.index(before: start)].isWhitespace {
            start = text.index(before: start)
        }
        let partial = text[start...]
        guard partial.count <= maxHealCharacters else { return HealSplit(prompt: text, heal: []) }

        // Fold exactly one preceding space into the heal, like the tokenizer does.
        if start > text.startIndex, text[text.index(before: start)] == " " {
            let spaceIndex = text.index(before: start)
            return HealSplit(prompt: String(text[..<spaceIndex]), heal: Array(" \(partial)".utf8))
        }
        return HealSplit(prompt: String(text[..<start]), heal: Array(partial.utf8))
    }
}
