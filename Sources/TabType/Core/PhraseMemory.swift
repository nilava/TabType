import Foundation
import TabTypeKit

/// Learns the user's own phrasing: maps 3-word prefixes from typing history to the
/// words that followed them. When the user types a phrase they've typed before,
/// the remembered continuation is suggested instantly — no model involved. This is
/// the "sounds like you" layer (Cotypist builds a suffix array for the same job):
/// your own past text is the best predictor of your recurring phrases — names,
/// sign-offs, jargon.
@MainActor
final class PhraseMemory {
    static let shared = PhraseMemory()

    /// trigram key (lowercased, space-joined) → next word (original casing) → count
    private var next: [String: [String: Int]] = [:]

    /// A continuation must have recurred this many times to be suggested —
    /// one-off phrasing is noise, repetition is signal.
    private let minCount = 2
    private let maxSuggestedWords = 6

    func rebuild(from entries: [String]) {
        next = [:]
        for entry in entries { ingest(entry) }
    }

    /// Fold one recorded snippet into the model.
    func ingest(_ text: String) {
        let text = SecretSanitizer.sanitize(text)
        let words = Self.tokenize(text)
        guard words.count >= 4 else { return }
        for i in 0...(words.count - 4) {
            let key = Self.key(Array(words[i...(i + 2)]))
            next[key, default: [:]][words[i + 3], default: 0] += 1
        }
    }

    /// The remembered continuation of the trailing 3 complete words, or nil.
    /// Walks the chain greedily while each step's top continuation recurred at
    /// least `minCount` times.
    func continuation(after input: String) -> String? {
        var words = Self.tokenize(input)
        guard words.count >= 3 else { return nil }
        words = Array(words.suffix(3))
        var out: [String] = []
        while out.count < maxSuggestedWords {
            let key = Self.key(words)
            guard let candidates = next[key],
                  let best = candidates.max(by: { $0.value < $1.value }),
                  best.value >= minCount else { break }
            out.append(best.key)
            words = Array(words.dropFirst()) + [best.key]
        }
        return out.isEmpty ? nil : out.joined(separator: " ")
    }

    /// The top-ranked next words after the trailing trigram (for word alternatives).
    func alternatives(after input: String, limit: Int = 2) -> [String] {
        let words = Self.tokenize(input)
        guard words.count >= 3 else { return [] }
        let key = Self.key(Array(words.suffix(3)))
        guard let candidates = next[key] else { return [] }
        return candidates.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    // MARK: - Tokenization

    nonisolated private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
    }

    nonisolated private static func key(_ words: [String]) -> String {
        words.map { $0.lowercased() }.joined(separator: " ")
    }
}
