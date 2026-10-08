import Foundation
@testable import TabTypeKit

/// Scripted `TokenModel` for decoder tests. Named pieces are the generable
/// vocabulary; every prompt is tokenized as raw bytes (blocked byte tokens), and
/// the next-token logits are chosen by the longest matching suffix rule over the
/// sequence's text so far.
final class FakeModel: TokenModel {
    let vocab: VocabIndex
    let maxSequences = 8
    private let names: [String]
    private let byteBase: Int
    private let rules: [(suffix: String, logits: [String: Float])]
    private let defaultLogits: [String: Float]
    private(set) var sequenceText: [Int: String] = [:]
    private var buffers: [UnsafeMutableBufferPointer<Float>] = []

    /// Sequences other than 0 still holding state.
    var liveCandidateSequences: [Int] { sequenceText.keys.filter { $0 > 0 }.sorted() }

    init(pieces: [String], endOfGeneration: Set<String> = ["<eos>"],
         rules: [String: [String: Float]], defaultLogits: [String: Float] = ["<eos>": 5]) {
        names = pieces
        byteBase = pieces.count
        var allPieces = pieces.map { Array($0.utf8) }
        var blocked = pieces.map { endOfGeneration.contains($0) }
        var eog = blocked
        for b in 0..<256 {
            allPieces.append([UInt8(b)])
            blocked.append(true)
            eog.append(false)
        }
        vocab = VocabIndex(pieces: allPieces, blocked: blocked, endOfGeneration: eog)
        self.rules = rules.map { ($0.key, $0.value) }.sorted { $0.0.count > $1.0.count }
        self.defaultLogits = defaultLogits
    }

    deinit { buffers.forEach { $0.deallocate() } }

    func tokenize(_ text: String, addSpecial: Bool) -> [TokenID] {
        text.utf8.map { TokenID(byteBase + Int($0)) }
    }

    func evaluatePrompt(_ tokens: [TokenID]) throws -> Logits {
        let text = String(decoding: tokens.flatMap { vocab.pieces[Int($0)] }, as: UTF8.self)
        sequenceText[0] = text
        releaseBuffers()
        return logits(for: text)
    }

    func fork(to sequence: Int) { sequenceText[sequence] = sequenceText[0] }

    func decode(_ entries: [BatchEntry]) throws -> [Logits] {
        releaseBuffers()
        return entries.map { entry in
            let piece = String(decoding: vocab.pieces[Int(entry.token)], as: UTF8.self)
            sequenceText[entry.sequence, default: ""] += piece
            return logits(for: sequenceText[entry.sequence]!)
        }
    }

    func drop(sequence: Int) { if sequence > 0 { sequenceText[sequence] = nil } }

    private func logits(for text: String) -> Logits {
        let table = rules.first { text.hasSuffix($0.suffix) }?.logits ?? defaultLogits
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: vocab.count)
        buffer.initialize(repeating: -20)
        for (piece, value) in table {
            if let id = names.firstIndex(of: piece) { buffer[id] = value }
        }
        buffers.append(buffer)
        return Logits(UnsafeBufferPointer(buffer))
    }

    private func releaseBuffers() {
        buffers.forEach { $0.deallocate() }
        buffers.removeAll()
    }
}
