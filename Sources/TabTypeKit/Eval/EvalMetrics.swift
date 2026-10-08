import Foundation

/// How useful one suggestion was, judged against what the author actually typed.
public struct CaseScore: Codable, Sendable, Equatable {
    /// A non-empty suggestion was produced.
    public var shown: Bool
    /// The first Tab-accept chunk matched what the author typed next.
    public var firstChunkCorrect: Bool
    /// Characters the author would have accepted pressing Tab word by word, stopping
    /// at the first chunk that diverges from what they really typed.
    public var acceptedChars: Int
    /// Number of chunks accepted that way.
    public var acceptedChunks: Int
}

public enum EvalScorer {
    /// Splits text into the chunks one Tab press accepts: leading whitespace plus the
    /// following run of non-whitespace ("word," / " the" / "\n" stays attached).
    public static func chunks(_ text: String) -> [Substring] {
        var result: [Substring] = []
        var i = text.startIndex
        while i < text.endIndex {
            let start = i
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            while i < text.endIndex, !text[i].isWhitespace { i = text.index(after: i) }
            result.append(text[start..<i])
        }
        return result
    }

    public static func score(suggestion: String, truth: String) -> CaseScore {
        let shown = !suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard shown else {
            return CaseScore(shown: false, firstChunkCorrect: false, acceptedChars: 0, acceptedChunks: 0)
        }
        var remaining = Substring(truth)
        var chars = 0
        var count = 0
        for chunk in chunks(suggestion) {
            guard remaining.hasPrefix(chunk) else { break }
            // A chunk that is a strict prefix of a longer truth word ("pro" vs
            // "proposal") still counts — the author would accept it and keep typing.
            remaining = remaining.dropFirst(chunk.count)
            chars += chunk.count
            count += 1
        }
        return CaseScore(shown: true, firstChunkCorrect: count > 0,
                         acceptedChars: chars, acceptedChunks: count)
    }
}

/// Aggregate quality numbers for a run (or a slice of it).
public struct EvalSummary: Codable, Sendable, Equatable {
    public var cases: Int
    public var shown: Int
    public var firstChunkCorrect: Int
    public var acceptedChars: Int
    /// Fraction of cases where something was shown.
    public var showRate: Double
    /// Of the shown suggestions, the fraction whose first chunk was right.
    public var precision: Double
    /// Of all cases, the fraction with a correct first chunk.
    public var recall: Double
    /// Of all cases, the fraction where a WRONG suggestion was shown.
    public var wrongShowRate: Double
    /// Mean characters accepted per case (the "keystrokes saved" headline).
    public var acceptedCharsPerCase: Double
    public var latencyP50Ms: Double
    public var latencyP95Ms: Double
    public var byKind: [String: Slice]
    public var byCategory: [String: Slice]

    public struct Slice: Codable, Sendable, Equatable {
        public var cases: Int
        public var precision: Double
        public var recall: Double
        public var acceptedCharsPerCase: Double
    }

    public init(results: [CaseResult]) {
        func slice(_ rs: [CaseResult]) -> Slice {
            let shown = rs.filter(\.score.shown).count
            let correct = rs.filter(\.score.firstChunkCorrect).count
            let chars = rs.reduce(0) { $0 + $1.score.acceptedChars }
            return Slice(cases: rs.count,
                         precision: shown == 0 ? 0 : Double(correct) / Double(shown),
                         recall: rs.isEmpty ? 0 : Double(correct) / Double(rs.count),
                         acceptedCharsPerCase: rs.isEmpty ? 0 : Double(chars) / Double(rs.count))
        }
        cases = results.count
        shown = results.filter(\.score.shown).count
        firstChunkCorrect = results.filter(\.score.firstChunkCorrect).count
        acceptedChars = results.reduce(0) { $0 + $1.score.acceptedChars }
        let n = Double(max(cases, 1))
        showRate = Double(shown) / n
        precision = shown == 0 ? 0 : Double(firstChunkCorrect) / Double(shown)
        recall = Double(firstChunkCorrect) / n
        wrongShowRate = Double(shown - firstChunkCorrect) / n
        acceptedCharsPerCase = Double(acceptedChars) / n
        let latencies = results.map(\.latencyMs).sorted()
        func pct(_ p: Double) -> Double {
            guard !latencies.isEmpty else { return 0 }
            return latencies[min(latencies.count - 1, Int(Double(latencies.count - 1) * p + 0.5))]
        }
        latencyP50Ms = pct(0.5)
        latencyP95Ms = pct(0.95)
        byKind = Dictionary(grouping: results, by: { $0.kind.rawValue }).mapValues(slice)
        byCategory = Dictionary(grouping: results, by: \.category).mapValues(slice)
    }
}

public enum EvalReport {
    /// Human-readable summary, optionally side by side with a baseline run.
    public static func render(_ run: EvalRun, baseline: EvalRun? = nil) -> String {
        let s = run.summary
        let b = baseline?.summary
        func pct(_ v: Double) -> String { String(format: "%5.1f%%", v * 100) }
        func num(_ v: Double) -> String { String(format: "%6.2f", v) }
        func ms(_ v: Double) -> String { String(format: "%6.0fms", v) }
        func row(_ name: String, _ cur: String, _ base: String?) -> String {
            let padded = name.padding(toLength: 26, withPad: " ", startingAt: 0)
            return base.map { "\(padded)\(cur)   (baseline \($0))" } ?? "\(padded)\(cur)"
        }
        var lines = ["\(run.backend) · \(run.model) · \(s.cases) cases"]
        if let baseline { lines.append("baseline: \(baseline.backend) · \(baseline.model)") }
        lines.append(row("accepted chars / case", num(s.acceptedCharsPerCase), b.map { num($0.acceptedCharsPerCase) }))
        lines.append(row("next-word recall", pct(s.recall), b.map { pct($0.recall) }))
        lines.append(row("precision (when shown)", pct(s.precision), b.map { pct($0.precision) }))
        lines.append(row("show rate", pct(s.showRate), b.map { pct($0.showRate) }))
        lines.append(row("wrong-show rate", pct(s.wrongShowRate), b.map { pct($0.wrongShowRate) }))
        lines.append(row("latency p50", ms(s.latencyP50Ms), b.map { ms($0.latencyP50Ms) }))
        lines.append(row("latency p95", ms(s.latencyP95Ms), b.map { ms($0.latencyP95Ms) }))
        for (title, dict, bdict) in [("kind", s.byKind, b?.byKind), ("category", s.byCategory, b?.byCategory)] {
            for key in dict.keys.sorted() {
                let v = dict[key]!
                let cur = "recall \(pct(v.recall)) · prec \(pct(v.precision)) · chars \(num(v.acceptedCharsPerCase)) (n=\(v.cases))"
                let base = bdict?[key].map { "recall \(pct($0.recall)) · chars \(num($0.acceptedCharsPerCase))" }
                lines.append(row("  \(title)=\(key)", cur, base))
            }
        }
        return lines.joined(separator: "\n")
    }
}
