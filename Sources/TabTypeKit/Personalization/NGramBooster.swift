import Foundation

/// Word-level N-gram personalization booster.
/// Complements `SuffixIndex` (which requires >= 10 characters of exact suffix match)
/// by learning 1-to-3 word n-gram transitions and inline mid-word completions from
/// the author's writing history.
public final class NGramBooster: @unchecked Sendable {
    public struct Config: Sendable, Equatable {
        /// Maximum n-gram context order (number of preceding words).
        public var maxOrder: Int = 3
        /// Minimum occurrences required for a 2+ word context n-gram hit.
        public var minSupport: Int = 2
        /// Minimum occurrences required for a 1-word context n-gram hit.
        public var minUnigramSupport: Int = 3
        /// Minimum partial-word prefix length for inline mid-word n-gram completion.
        public var minInlinePrefix: Int = 2

        public init(
            maxOrder: Int = 3,
            minSupport: Int = 2,
            minUnigramSupport: Int = 3,
            minInlinePrefix: Int = 2
        ) {
            self.maxOrder = max(1, maxOrder)
            self.minSupport = max(1, minSupport)
            self.minUnigramSupport = max(1, minUnigramSupport)
            self.minInlinePrefix = max(1, minInlinePrefix)
        }
    }

    private struct Candidate: Sendable {
        var firstWordLower: String
        var continuation: String
        var count: Int
    }

    public let config: Config
    /// Keyed by lowercased space-joined context words (1...maxOrder words).
    private let table: [String: [Candidate]]
    public let ngramCount: Int

    public var isEmpty: Bool { table.isEmpty }

    public init(documents: [String], config: Config = Config(), maxContinuationWords: Int = 3) {
        self.config = config
        var rawCounts: [String: [String: (count: Int, continuation: String)]] = [:]

        for doc in documents {
            let words = Self.tokenizeWords(doc)
            guard words.count >= 2 else { continue }
            let lowers = words.map { $0.lowercased() }

            for i in 1..<words.count {
                let contEnd = min(words.count, i + maxContinuationWords)
                let continuation = words[i..<contEnd].joined(separator: " ")
                let firstLower = lowers[i]
                guard !firstLower.isEmpty else { continue }

                let maxCtx = min(config.maxOrder, i)
                for order in 1...maxCtx {
                    let ctxKey = lowers[(i - order)..<i].joined(separator: " ")
                    var bucket = rawCounts[ctxKey] ?? [:]
                    if let existing = bucket[firstLower] {
                        // Keep the longer/more informative continuation phrasing seen most recently
                        let chosen = continuation.count >= existing.continuation.count ? continuation : existing.continuation
                        bucket[firstLower] = (existing.count + 1, chosen)
                    } else {
                        bucket[firstLower] = (1, continuation)
                    }
                    rawCounts[ctxKey] = bucket
                }
            }
        }

        var compiled: [String: [Candidate]] = [:]
        var total = 0
        for (ctxKey, bucket) in rawCounts {
            let sorted = bucket.map { (firstLower, val) in
                Candidate(firstWordLower: firstLower, continuation: val.continuation, count: val.count)
            }.sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.continuation.count > $1.continuation.count
            }
            compiled[ctxKey] = sorted
            total += sorted.count
        }
        self.table = compiled
        self.ngramCount = total
    }

    /// Queries the n-gram table for a continuation after `typed`.
    /// Handles both word-boundary contexts (trailing whitespace) and mid-word inline contexts.
    public func continuation(after typed: String) -> RetrievalHint? {
        guard !table.isEmpty, !typed.isEmpty else { return nil }
        let endsWithSpace = typed.last?.isWhitespace == true
        let words = Self.tokenizeWords(typed)
        guard !words.isEmpty else { return nil }

        if endsWithSpace {
            let maxCtx = min(config.maxOrder, words.count)
            for order in stride(from: maxCtx, through: 1, by: -1) {
                let slice = words[(words.count - order)...]
                let key = slice.map { $0.lowercased() }.joined(separator: " ")
                let requiredSupport = order == 1 ? config.minUnigramSupport : config.minSupport
                if let candidates = table[key],
                   let best = candidates.first,
                   best.count >= requiredSupport {
                    let matchedChars = slice.joined(separator: " ").count + 1
                    return RetrievalHint(
                        text: best.continuation,
                        matchedCharacters: matchedChars,
                        support: best.count
                    )
                }
            }
            return nil
        } else {
            // Inline mid-word mode: the last token in `words` is a partial word prefix.
            guard let partial = words.last, partial.count >= config.minInlinePrefix else { return nil }
            let partialLower = partial.lowercased()
            let preceding = words.dropLast()
            guard !preceding.isEmpty else { return nil }

            let maxCtx = min(config.maxOrder, preceding.count)
            for order in stride(from: maxCtx, through: 1, by: -1) {
                let slice = preceding[(preceding.count - order)...]
                let key = slice.map { $0.lowercased() }.joined(separator: " ")
                let requiredSupport = config.minSupport
                guard let candidates = table[key] else { continue }
                if let best = candidates.first(where: {
                    $0.count >= requiredSupport
                        && $0.firstWordLower.hasPrefix(partialLower)
                        && $0.firstWordLower.count > partialLower.count
                }) {
                    let remainder = String(best.continuation.dropFirst(partial.count))
                    guard !remainder.isEmpty else { continue }
                    let matchedChars = slice.joined(separator: " ").count + 1 + partial.count
                    return RetrievalHint(
                        text: remainder,
                        matchedCharacters: matchedChars,
                        support: best.count
                    )
                }
            }
            return nil
        }
    }

    private static func tokenizeWords(_ text: String) -> [String] {
        text.split { $0.isWhitespace }.map(String.init).filter { !$0.isEmpty }
    }
}
