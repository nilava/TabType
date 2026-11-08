import Foundation

/// What the author wrote after the same words before.
public struct RetrievalHint: Equatable, Sendable {
    /// Continuation in the author's own casing, starting right after the typed
    /// text (may begin with a space, or finish a partial word).
    public var text: String
    /// Length of the typed tail that matched, in characters.
    public var matchedCharacters: Int
    /// How many past occurrences agree on this continuation's first word.
    public var support: Int
}

/// Suffix array over the author's own writing. Answers "after these words, what did
/// I write before?" in microseconds, for any typed tail (mid-word included).
/// Matching is case-insensitive and whitespace-normalized; continuations come back
/// in the original casing.
public final class SuffixIndex: @unchecked Sendable {
    private let text: [UInt8]      // normalized, original casing; documents joined by 0x01
    private let lower: [UInt8]     // ASCII-lowercased copy, same length
    private let suffixes: [Int32]
    private static let separator: UInt8 = 0x01
    /// Comparisons look at most this many bytes; queries are shorter.
    private static let compareLength = 64

    public var isEmpty: Bool { suffixes.isEmpty }
    public var byteCount: Int { text.count }

    public init(documents: [String]) {
        var bytes: [UInt8] = []
        for doc in documents {
            let normalized = Self.normalize(doc)
            guard normalized.count >= 4 else { continue }
            bytes += normalized
            bytes.append(Self.separator)
        }
        text = bytes
        lower = bytes.map(Self.asciiLower)
        let lowerCopy = lower
        var order = (0..<bytes.count).filter { bytes[$0] != Self.separator }.map(Int32.init)
        lowerCopy.withUnsafeBufferPointer { buf in
            let n = buf.count
            order.sort { a, b in
                let ia = Int(a), ib = Int(b)
                let la = min(Self.compareLength, n - ia), lb = min(Self.compareLength, n - ib)
                let c = memcmp(buf.baseAddress! + ia, buf.baseAddress! + ib, min(la, lb))
                return c != 0 ? c < 0 : la < lb
            }
        }
        suffixes = order
    }

    /// The most common continuation after the longest matching tail of `typed`
    /// (tails start at a word boundary and are at least `minimumMatch` UTF-8 bytes).
    public func continuation(after typed: String, minimumMatch: Int = 10, maxWords: Int = 4) -> RetrievalHint? {
        guard !suffixes.isEmpty else { return nil }
        let query = Self.normalize(typed).map(Self.asciiLower)
        guard query.count >= minimumMatch else { return nil }
        // Candidate tail lengths: longest first, each starting right after a space.
        var starts: [Int] = []
        for i in stride(from: query.count - minimumMatch, through: 0, by: -1)
        where i == 0 || query[i - 1] == 0x20 {
            starts.append(i)
            if query.count - i >= 60 { break }
        }
        for start in starts.reversed() {   // longest tail first
            // The match must end exactly at the caret. Truncating the right side
            // would return part of the already typed tail (or half a UTF-8 scalar).
            let pattern = Array(query[start...])
            guard pattern.count <= Self.compareLength else { continue }
            let range = matches(pattern)
            guard !range.isEmpty else { continue }
            var firstWords: [String: Int] = [:]
            var phrases: [String: (count: Int, text: String)] = [:]
            for i in range {
                let end = Int(suffixes[i]) + pattern.count
                guard let cont = continuationText(from: end, maxWords: maxWords), !cont.isEmpty else { continue }
                firstWords[firstWordKey(cont), default: 0] += 1
                let key = cont.lowercased()
                let entry = phrases[key] ?? (0, cont)
                phrases[key] = (entry.count + 1, min(entry.text, cont))
            }
            // Preserve the most common next word, then choose its most frequent
            // full continuation instead of the first suffix-array occurrence.
            // Lexical ties are stable across process hash seeds and input order.
            if let first = firstWords.max(by: {
                $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value
            }), let best = phrases.filter({ firstWordKey($0.value.text) == first.key }).max(by: {
                $0.value.count == $1.value.count ? $0.key > $1.key : $0.value.count < $1.value.count
            }) {
                return RetrievalHint(text: best.value.text,
                    matchedCharacters: String(decoding: pattern, as: UTF8.self).count, support: first.value)
            }
        }
        return nil
    }

    // MARK: Internals

    /// Suffix-array positions whose suffix starts with `pattern`.
    private func matches(_ pattern: [UInt8]) -> Range<Int> {
        func compare(_ s: Int) -> Int {   // suffix vs pattern, over the pattern's length
            let pos = Int(suffixes[s])
            for k in 0..<pattern.count {
                guard pos + k < lower.count else { return -1 }
                let a = lower[pos + k], b = pattern[k]
                if a != b { return a < b ? -1 : 1 }
            }
            return 0
        }
        var lo = 0, hi = suffixes.count
        while lo < hi { let mid = (lo + hi) / 2; if compare(mid) < 0 { lo = mid + 1 } else { hi = mid } }
        let first = lo
        hi = suffixes.count
        while lo < hi { let mid = (lo + hi) / 2; if compare(mid) <= 0 { lo = mid + 1 } else { hi = mid } }
        return first..<lo
    }

    private func continuationText(from start: Int, maxWords: Int) -> String? {
        var end = start
        var words = 0
        var inWord = false
        while end < text.count, text[end] != Self.separator {
            let isSpace = text[end] == 0x20
            if isSpace, inWord {
                words += 1
                if words >= maxWords { break }
            }
            inWord = !isSpace
            end += 1
        }
        guard end > start else { return nil }
        return String(decoding: text[start..<end], as: UTF8.self)
    }

    private func firstWordKey(_ s: String) -> String {
        let trimmed = s.drop(while: { $0 == " " })
        let word = trimmed.prefix(while: { $0 != " " })
        return (s.hasPrefix(" ") ? " " : "") + word.lowercased()
    }

    static func normalize(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count)
        var lastSpace = true
        for b in s.utf8 {
            if b == 0x20 || b == 0x0A || b == 0x09 || b == 0x0D {
                if !lastSpace { out.append(0x20) }
                lastSpace = true
            } else if b != separator {
                out.append(b)
                lastSpace = false
            }
        }
        // Keep a trailing space: "take a look " must continue with the next word.
        if let last = s.utf8.last, last == 0x20 || last == 0x0A, out.last != 0x20 { out.append(0x20) }
        return out
    }

    static func asciiLower(_ b: UInt8) -> UInt8 { (b >= 65 && b <= 90) ? b + 32 : b }
}
