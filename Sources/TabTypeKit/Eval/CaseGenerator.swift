import Foundation

/// Cuts corpus entries into evaluation cases at word boundaries and inside words.
/// Deterministic for a given seed so runs stay comparable across builds.
public struct CaseGenerator: Sendable {
    public var boundaryPerEntry: Int
    public var midwordPerEntry: Int
    /// How much of the real continuation to keep as ground truth.
    public var truthChars: Int
    public var seed: UInt64

    public init(boundaryPerEntry: Int = 4, midwordPerEntry: Int = 2,
                truthChars: Int = 80, seed: UInt64 = 42) {
        self.boundaryPerEntry = boundaryPerEntry
        self.midwordPerEntry = midwordPerEntry
        self.truthChars = truthChars
        self.seed = seed
    }

    public func cases(from corpus: [CorpusEntry]) -> [EvalCase] {
        var rng = SplitMix64(seed: seed)
        var out: [EvalCase] = []
        for (entryIndex, entry) in corpus.enumerated() {
            let text = Array(entry.text)
            var boundaries: [Int] = []
            var midwords: [Int] = []
            var wordsSeen = 0
            var i = 0
            while i < text.count {
                // Word starts at i.
                if !text[i].isWhitespace, i == 0 || text[i - 1].isWhitespace {
                    var end = i
                    while end < text.count, !text[end].isWhitespace { end += 1 }
                    let letters = text[i..<end].prefix { $0.isLetter }.count
                    // Caret right before a word, once at least one word was typed.
                    if wordsSeen >= 1 { boundaries.append(i) }
                    // Caret 1…n-2 letters into a word of 4+ letters.
                    if letters >= 4 {
                        for k in 1...(letters - 2) { midwords.append(i + k) }
                    }
                    wordsSeen += 1
                    i = end
                } else {
                    i += 1
                }
            }
            func emit(_ positions: [Int], _ n: Int, _ kind: SplitKind) {
                for pos in rng.sample(positions, count: n).sorted() {
                    let truth = String(text[pos...].prefix(truthChars))
                    guard !truth.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    out.append(EvalCase(
                        id: "\(entryIndex)-\(kind.rawValue)-\(pos)",
                        category: entry.category, app: entry.app, kind: kind,
                        context: entry.context, prefix: String(text[..<pos]), truth: truth))
                }
            }
            emit(boundaries, boundaryPerEntry, .boundary)
            emit(midwords, midwordPerEntry, .midword)
        }
        return out
    }
}

/// Small deterministic PRNG (SplitMix64) — `SystemRandomNumberGenerator` can't be
/// seeded, and case sets must be reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func sample<T>(_ items: [T], count: Int) -> [T] {
        guard items.count > count else { return items }
        var pool = items
        var picked: [T] = []
        for _ in 0..<count {
            let j = Int(next() % UInt64(pool.count))
            picked.append(pool.remove(at: j))
        }
        return picked
    }
}
