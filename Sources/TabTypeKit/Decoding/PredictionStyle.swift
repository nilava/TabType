import Foundation

/// Confidence/phrase-length preferences, shared by the app and offline evaluator.
/// Balanced preserves the existing app's word-boundary and midword gates.
public enum PredictionStyle: String, Codable, CaseIterable, Sendable {
    case careful, balanced, frequent

    public var extensionThreshold: Double {
        switch self {
        case .careful: return 0.15
        case .balanced: return 0.05
        case .frequent: return 0.025
        }
    }

    public func threshold(base: Double, midword: Bool,
                          followsHint: Bool = false, hintSupport: Int = 0,
                          repeatedPhraseFactor: Double = 0.5) -> Double {
        let factor: Double
        switch self {
        case .careful: factor = midword ? 0.5 : 1
        case .balanced: factor = midword ? 0.4 : 0.75
        case .frequent: factor = midword ? 0.25 : 0.5
        }
        let repeated = followsHint && hintSupport >= 2 ? repeatedPhraseFactor : 1
        return base * factor * repeated
    }

    public static func isMidword(_ prefix: String) -> Bool {
        prefix.last.map { $0.isLetter || $0.isNumber } ?? false
    }
}

/// Keep a contiguous confident tail; never skip a weak word to show later words.
public enum ScoredPhrase {
    public static func prefix(_ words: [WordScore], extensionThreshold: Double) -> [WordScore] {
        guard let first = words.first else { return [] }
        var kept = [first]
        for word in words.dropFirst() {
            guard word.probability >= extensionThreshold else { break }
            kept.append(word)
        }
        return kept
    }
}
