import Foundation

/// Logits for one decoded position. Only valid until the next call that decodes
/// on the same model — consume them immediately.
public struct Logits {
    public let values: UnsafeBufferPointer<Float>
    public init(_ values: UnsafeBufferPointer<Float>) { self.values = values }
}

/// One token to decode as part of a multi-sequence batch.
public struct BatchEntry: Equatable {
    public var token: TokenID
    public var position: Int
    public var sequence: Int
    public init(token: TokenID, position: Int, sequence: Int) {
        self.token = token
        self.position = position
        self.sequence = sequence
    }
}

/// What the decoder needs from a language model. `LlamaRuntime` implements it for
/// real; tests use a scripted fake.
///
/// Sequence 0 always holds the prompt. Candidate sequences are forked from it,
/// extended independently, and dropped when the request finishes.
public protocol TokenModel: AnyObject {
    var vocab: VocabIndex { get }
    /// Maximum number of KV sequences (prompt + candidates).
    var maxSequences: Int { get }
    func tokenize(_ text: String, addSpecial: Bool) -> [TokenID]
    /// Make sequence 0 hold exactly `tokens` (reusing what's cached) and return the
    /// logits after the last one.
    func evaluatePrompt(_ tokens: [TokenID]) throws -> Logits
    /// Copy sequence 0's cached prompt into `sequence`.
    func fork(to sequence: Int)
    /// Decode one token per entry in a single batch; returns logits per entry.
    func decode(_ entries: [BatchEntry]) throws -> [Logits]
    /// Remove a candidate sequence from the cache.
    func drop(sequence: Int)
}
