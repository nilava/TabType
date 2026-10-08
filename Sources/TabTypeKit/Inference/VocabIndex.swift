import Foundation

public typealias TokenID = Int32

/// Precomputed view of a model's vocabulary: every token's raw UTF-8 bytes and
/// whether it may ever be generated, plus a first-byte index so constrained
/// decoding only scans tokens that can possibly match.
public final class VocabIndex: @unchecked Sendable {
    public let count: Int
    /// Raw bytes per token (a multi-byte character may span several tokens).
    public let pieces: [[UInt8]]
    /// Tokens that must never appear in a suggestion: control tokens, EOG markers,
    /// and tokens that render to nothing.
    public let blocked: [Bool]
    /// Tokens that end generation outright (EOS/EOT/end-of-turn).
    public let endOfGeneration: [Bool]
    /// Generable token ids grouped by their first byte.
    private let byFirstByte: [[TokenID]]

    public init(pieces: [[UInt8]], blocked: [Bool], endOfGeneration: [Bool]) {
        precondition(pieces.count == blocked.count && pieces.count == endOfGeneration.count)
        self.count = pieces.count
        self.pieces = pieces
        self.blocked = blocked
        self.endOfGeneration = endOfGeneration
        var buckets = [[TokenID]](repeating: [], count: 256)
        for (id, piece) in pieces.enumerated() where !blocked[id] {
            if let first = piece.first { buckets[Int(first)].append(TokenID(id)) }
        }
        self.byFirstByte = buckets
    }

    /// Tokens consistent with having to produce `required` next: the token's bytes
    /// either fit entirely inside `required` or start with all of it (and may
    /// continue past it). Empty when nothing matches.
    public func tokens(consistentWith required: ArraySlice<UInt8>) -> [TokenID] {
        guard let first = required.first else { return [] }
        return byFirstByte[Int(first)].filter { id in
            let piece = pieces[Int(id)]
            return piece.count <= required.count
                ? required.starts(with: piece)
                : piece.starts(with: required)
        }
    }

    public func startsWithWhitespace(_ id: TokenID) -> Bool {
        guard let b = pieces[Int(id)].first else { return false }
        return b == 0x20 || b == 0x0A || b == 0x09 || b == 0x0D
    }

    public func containsNewline(_ id: TokenID) -> Bool {
        pieces[Int(id)].contains(0x0A) || pieces[Int(id)].contains(0x0D)
    }
}
