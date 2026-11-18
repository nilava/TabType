import Foundation

/// A word from the author's own writing that may come next, as the visible text
/// after the caret ("le" finishing "doub", "Priya" after "Hi "), with the logit
/// bias (nats) its first token gets in the decoder.
public struct BiasTarget: Equatable, Sendable {
    public var text: [UInt8]
    public var bias: Float
    public init(text: [UInt8], bias: Float) {
        self.text = text
        self.bias = bias
    }
}

/// Word and 2–3 word phrase counts from the author's accepted writing: which words
/// they use (names, projects, sign-offs) and what they write after one or two words.
public struct PersonalVocabulary: Sendable {
    /// Lowercased word → count.
    private var counts: [String: Int] = [:]
    /// Lowercased word → the casing the author last used.
    private var display: [String: String] = [:]
    /// Lowercased "w1" or "w1 w2" → next lowercased word → count.
    private var next: [String: [String: Int]] = [:]

    /// The bias range, in nats: a tie-breaker, never enough to force a word in.
    public static let biasRange: ClosedRange<Float> = 0.1...0.8

    public var isEmpty: Bool { counts.isEmpty }

    public init(documents: [String]) {
        for doc in documents {
            var previous: [String] = []
            for raw in doc.split(whereSeparator: \.isWhitespace) {
                let word = Self.core(raw)
                guard !word.isEmpty else { previous = []; continue }
                let key = word.lowercased()
                counts[key, default: 0] += 1
                display[key] = word
                if let p = previous.last { next[p, default: [:]][key, default: 0] += 1 }
                if previous.count == 2 { next[previous.joined(separator: " "), default: [:]][key, default: 0] += 1 }
                previous = Array((previous + [key]).suffix(2))
                // A sentence ends: the next word doesn't follow this one.
                if let last = raw.last, ".!?".contains(last) { previous = [] }
            }
        }
    }

    /// Words that may come right after `typed`, strongest first, with a weight in
    /// (0, 1]: what followed the last two / last word before (trigrams count
    /// double), and, mid-word, the author's recurring words that finish it.
    public func continuations(after typed: String, limit: Int = 8) -> [(text: String, weight: Double)] {
        guard !counts.isEmpty else { return [] }
        let words = typed.split(whereSeparator: \.isWhitespace)
        let midWord = typed.last.map { !$0.isWhitespace } ?? false
        let partial = midWord ? Self.core(words.last ?? "").lowercased() : ""
        // A partial with punctuation inside it ("e.g", a URL) isn't a word to finish.
        if midWord, partial.isEmpty || partial.count != (words.last?.count ?? 0) { return [] }
        let context = (midWord ? words.dropLast() : words[...]).suffix(2)
        // A sentence end before the caret breaks the chain, like in the counts.
        let chain = context.last.map { ".!?".contains($0.last!) } == true ? [] : context.map { Self.core($0).lowercased() }

        var score: [String: Double] = [:]
        if chain.count == 2, let after = next[chain.joined(separator: " ")] {
            for (w, n) in after { score[w, default: 0] += Double(2 * n) }
        }
        if let last = chain.last, let after = next[last] {
            for (w, n) in after { score[w, default: 0] += Double(n) }
        }
        if !partial.isEmpty {
            score = score.filter { $0.key.count > partial.count && $0.key.hasPrefix(partial) }
            // Recurring words of the author's own that finish the partial (names,
            // project terms) — only ones used at least twice.
            for (w, n) in counts where n >= 2 && w.count > partial.count && w.hasPrefix(partial) {
                score[w, default: 0] += Double(n) / 2
            }
        }
        guard let top = score.values.max(), top > 0 else { return [] }
        return score.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { (w: String, s: Double) -> (text: String, weight: Double) in
                let shown: String = display[w] ?? w
                // Mid-word, only the rest of the word is new; the typed casing stays.
                let text: String = partial.isEmpty ? shown : String(shown.dropFirst(partial.count))
                return (text, log1p(s) / log1p(top))
            }
    }

    /// Decoder bias targets for `typed` at `strength` (0 = off, 1 = strongest):
    /// each word's bias is `strength × (0.1 + 0.7 × weight)`, clamped to
    /// `biasRange`'s top. Off does no work at all.
    public func biasTargets(after typed: String, strength: Double) -> [BiasTarget] {
        guard strength > 0 else { return [] }
        return continuations(after: typed).map { c in
            BiasTarget(text: Array(c.text.utf8), bias: Self.bias(weight: c.weight, strength: strength))
        }
    }

    public static func bias(weight: Double, strength: Double) -> Float {
        let s = min(max(strength, 0), 1), w = min(max(weight, 0), 1)
        return min(Float(s * (0.1 + 0.7 * w)), biasRange.upperBound)
    }

    /// The word without surrounding punctuation ("Thanks," → "Thanks").
    static func core<S: StringProtocol>(_ raw: S) -> String {
        String(raw).trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }
}

/// Short samples of how the author writes in one app, for the prompt.
public enum StyleExemplars {
    /// Up to `count` distinct recent texts written in `app`, newest first, each
    /// cut to its first `maxCharacters` at a word boundary. `documents` are
    /// oldest first. Deterministic for a given store, so the prompt prefix stays
    /// cached across keystrokes.
    public static func pick(from documents: [(app: String, text: String)], app: String,
                            count: Int = 2, maxCharacters: Int = 160) -> [String] {
        var picked: [String] = []
        for doc in documents.reversed() where doc.app == app {
            var text = doc.text.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if text.count > maxCharacters {
                text = String(text.prefix(maxCharacters))
                if let space = text.lastIndex(of: " ") { text = String(text[..<space]) }
            }
            guard !text.isEmpty, !picked.contains(text) else { continue }
            picked.append(text)
            if picked.count == count { break }
        }
        return picked
    }
}
