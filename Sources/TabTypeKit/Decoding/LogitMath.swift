import Accelerate
import Foundation

/// Log-probability helpers over raw logits. Full-vocabulary passes use Accelerate
/// (vocabularies reach 262k entries); restricted passes touch only the given ids.
public enum LogitMath {
    /// log Σ exp(logit) over the whole vocabulary, skipping blocked tokens (nil:
    /// include everything, so end-of-text mass lowers every other probability).
    public static func logSumExp(_ logits: Logits, blocked: [Bool]?, scratch: inout [Float]) -> Float {
        let values = logits.values
        let n = values.count
        if scratch.count < n { scratch = [Float](repeating: 0, count: n) }
        var maxValue: Float = 0
        vDSP_maxv(values.baseAddress!, 1, &maxValue, vDSP_Length(n))
        // scratch = exp(values - max)
        var negMax = -maxValue
        scratch.withUnsafeMutableBufferPointer { out in
            vDSP_vsadd(values.baseAddress!, 1, &negMax, out.baseAddress!, 1, vDSP_Length(n))
            var count = Int32(n)
            vvexpf(out.baseAddress!, out.baseAddress!, &count)
        }
        var sum: Float = 0
        vDSP_sve(scratch, 1, &sum, vDSP_Length(n))
        // Blocked tokens (control/EOG markers) are rare; subtract their mass.
        if let blocked {
            for i in 0..<n where blocked[i] { sum -= scratch[i] }
        }
        return maxValue + log(max(sum, .leastNormalMagnitude))
    }

    /// log Σ exp(logit) over just `ids`.
    public static func logSumExp(_ logits: Logits, over ids: [TokenID]) -> Float {
        guard !ids.isEmpty else { return -.infinity }
        var maxValue = -Float.infinity
        for id in ids { maxValue = max(maxValue, logits.values[Int(id)]) }
        var sum: Float = 0
        for id in ids { sum += exp(logits.values[Int(id)] - maxValue) }
        return maxValue + log(sum)
    }

    /// The `k` highest-logit tokens among `candidates` (or the whole unblocked
    /// vocabulary when nil), best first.
    public static func topK(_ logits: Logits, k: Int, candidates: [TokenID]?, blocked: [Bool]) -> [TokenID] {
        guard k > 0 else { return [] }
        var best: [(TokenID, Float)] = []
        best.reserveCapacity(k + 1)
        func consider(_ id: Int) {
            let v = logits.values[id]
            if best.count == k, let last = best.last, v <= last.1 { return }
            let insertAt = best.firstIndex { v > $0.1 } ?? best.count
            best.insert((TokenID(id), v), at: insertAt)
            if best.count > k { best.removeLast() }
        }
        if let candidates {
            for id in candidates { consider(Int(id)) }
        } else {
            for id in 0..<logits.values.count where !blocked[id] { consider(id) }
        }
        return best.map(\.0)
    }
}
