import Foundation
import llama

public enum LlamaError: Error, CustomStringConvertible {
    case modelLoad(String)
    case contextInit(String)
    case decode(Int32)

    public var description: String {
        switch self {
        case .modelLoad(let path): return "failed to load model at \(path)"
        case .contextInit(let path): return "failed to create a context for \(path)"
        case .decode(let code): return "llama_decode failed (\(code))"
        }
    }
}

/// Thin owner of one llama.cpp model + context. Sequence 0 of the KV cache holds the
/// current prompt; `evaluate` reuses its longest common token prefix so only the
/// changed tail is prefilled.
///
/// Not thread-safe: callers must serialize all use (the app routes it through one
/// actor, the eval CLI is sequential).
public final class LlamaRuntime: @unchecked Sendable {
    public let modelPath: String
    public let vocabSize: Int
    /// Tokens currently held in sequence 0, in position order.
    public private(set) var cachedTokens: [llama_token] = []

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private var batch: llama_batch
    private let batchCapacity: Int

    private static let backendReady: Void = {
        // llama.cpp logs every tensor at load; the app has its own log. Must be set
        // before backend init, which already logs device details.
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    public init(modelPath: String, contextLength: Int = 4096, batchSize: Int = 512,
                maxSequences: Int = 1) throws {
        _ = Self.backendReady
        self.modelPath = modelPath

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = -1   // everything on Metal
        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaError.modelLoad(modelPath)
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextLength)
        contextParams.n_batch = UInt32(batchSize)
        contextParams.n_ubatch = UInt32(batchSize)
        contextParams.n_seq_max = UInt32(maxSequences)
        contextParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        // Sliding-window models (Gemma) can only trim their KV cache for prefix
        // reuse when the SWA cache is kept at full size.
        contextParams.swa_full = true
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LlamaError.contextInit(modelPath)
        }

        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.vocabSize = Int(llama_vocab_n_tokens(vocab))
        self.batchCapacity = batchSize
        self.batch = llama_batch_init(Int32(batchSize), 0, Int32(maxSequences))
    }

    deinit {
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    // MARK: Vocabulary

    public var addsBOS: Bool { llama_vocab_get_add_bos(vocab) }

    public func tokenize(_ text: String, addSpecial: Bool, parseSpecial: Bool = true) -> [llama_token] {
        let byteCount = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(byteCount) + 8)
        var count = text.withCString {
            llama_tokenize(vocab, $0, byteCount, &tokens, Int32(tokens.count), addSpecial, parseSpecial)
        }
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = text.withCString {
                llama_tokenize(vocab, $0, byteCount, &tokens, Int32(tokens.count), addSpecial, parseSpecial)
            }
        }
        return Array(tokens.prefix(Int(max(0, count))))
    }

    /// Raw UTF-8 bytes of one token. A multi-byte character can span tokens, so
    /// callers accumulate bytes and decode once.
    public func pieceBytes(_ token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(0, count))).map { UInt8(bitPattern: $0) }
    }

    public func isEndOfGeneration(_ token: llama_token) -> Bool { llama_vocab_is_eog(vocab, token) }
    public func isControl(_ token: llama_token) -> Bool { llama_vocab_is_control(vocab, token) }

    // MARK: Evaluation

    /// Make sequence 0 hold exactly `tokens` and return the logits after the last one.
    /// Reuses the longest common prefix with what's cached; on any failure the cache
    /// is cleared and rebuilt.
    public func evaluate(_ tokens: [llama_token]) throws -> UnsafeMutablePointer<Float> {
        precondition(!tokens.isEmpty, "evaluate needs at least one token")
        let memory = llama_get_memory(context)
        var common = 0
        let maxCommon = min(cachedTokens.count, tokens.count - 1)   // always feed ≥1 token
        while common < maxCommon, cachedTokens[common] == tokens[common] { common += 1 }
        if common < cachedTokens.count {
            if !llama_memory_seq_rm(memory, 0, Int32(common), -1) {
                llama_memory_clear(memory, true)
                common = 0
            }
            cachedTokens.removeSubrange(common...)
        }
        try decode(Array(tokens[common...]), startPosition: common)
        return llama_get_logits_ith(context, -1)
    }

    /// Append one token to sequence 0 and return the logits after it.
    public func append(_ token: llama_token) throws -> UnsafeMutablePointer<Float> {
        try decode([token], startPosition: cachedTokens.count)
        return llama_get_logits_ith(context, -1)
    }

    /// Drop everything in sequence 0 after the first `count` tokens.
    public func truncate(to count: Int) {
        guard count < cachedTokens.count else { return }
        if llama_memory_seq_rm(llama_get_memory(context), 0, Int32(count), -1) {
            cachedTokens.removeSubrange(count...)
        } else {
            reset()
        }
    }

    public func reset() {
        llama_memory_clear(llama_get_memory(context), true)
        cachedTokens.removeAll()
    }

    private func decode(_ tokens: [llama_token], startPosition: Int) throws {
        var offset = 0
        while offset < tokens.count {
            let n = min(batchCapacity, tokens.count - offset)
            batch.n_tokens = Int32(n)
            for i in 0..<n {
                let global = offset + i
                batch.token[i] = tokens[global]
                batch.pos[i] = Int32(startPosition + global)
                batch.n_seq_id[i] = 1
                batch.seq_id[i]![0] = 0
                batch.logits[i] = global == tokens.count - 1 ? 1 : 0
            }
            let status = llama_decode(context, batch)
            guard status == 0 else {
                reset()
                throw LlamaError.decode(status)
            }
            cachedTokens.append(contentsOf: tokens[offset..<(offset + n)])
            offset += n
        }
    }

    // MARK: Logit helpers

    public func argmax(_ logits: UnsafeMutablePointer<Float>) -> llama_token {
        var best = 0
        var bestValue = -Float.infinity
        for i in 0..<vocabSize where logits[i] > bestValue {
            bestValue = logits[i]
            best = i
        }
        return llama_token(best)
    }
}
