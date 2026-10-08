import Foundation
import llama

public enum LlamaError: Error, CustomStringConvertible {
    case modelLoad(String)
    case contextInit(String)
    case decode(Int32)
    case contextFull
    case adapterLoad(String)

    public var description: String {
        switch self {
        case .modelLoad(let path): return "failed to load model at \(path)"
        case .contextInit(let path): return "failed to create a context for \(path)"
        case .decode(let code): return "llama_decode failed (\(code))"
        case .contextFull: return "prompt does not fit in the context window"
        case .adapterLoad(let path): return "couldn't apply the adapter at \(path) (not a LoRA adapter for this model?)"
        }
    }
}

/// Owner of one llama.cpp model + context, implementing `TokenModel`.
///
/// KV layout: sequence 0 holds the current prompt. `evaluatePrompt` reuses its
/// longest common token prefix. Callers that know a span was dropped from the
/// middle of the prompt because the window slid can opt into splicing the cache
/// (shift instead of recompute) on models that support position shifting. Candidate sequences 1…n are forked from
/// sequence 0 and share its cells (unified KV cache).
///
/// Not thread-safe: all use must be serialized (see `InferenceEngine`).
public final class LlamaRuntime: TokenModel, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var contextLength: Int = 4096
        public var batchSize: Int = 512
        public var maxSequences: Int = 8
        public init() {}
    }

    public let modelPath: String
    public let vocab: VocabIndex
    public let maxSequences: Int
    public let contextLength: Int
    /// Whether removing a middle span of the prompt can be done by shifting the
    /// remaining cache (false for sliding-window models such as Gemma).
    public let supportsSplice: Bool
    /// Tokens currently held in sequence 0, in position order.
    public private(set) var cachedTokens: [TokenID] = []
    /// Prompt tokens actually computed by the last `evaluatePrompt` (for telemetry).
    public private(set) var lastPrefillCount = 0

    private let model: OpaquePointer
    private let context: OpaquePointer
    private var adapter: OpaquePointer?
    /// The LoRA adapter currently applied, if any.
    public private(set) var adapterPath: String?
    private let vocabPointer: OpaquePointer
    private var batch: llama_batch
    private let batchCapacity: Int

    private static let backendReady: Void = {
        // llama.cpp logs every tensor at load; the app has its own log. Must be set
        // before backend init, which already logs device details.
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    public init(modelPath: String, configuration: Configuration = Configuration()) throws {
        _ = Self.backendReady
        self.modelPath = modelPath

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = -1   // everything on Metal
        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaError.modelLoad(modelPath)
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(configuration.contextLength)
        contextParams.n_batch = UInt32(configuration.batchSize)
        contextParams.n_ubatch = UInt32(configuration.batchSize)
        contextParams.n_seq_max = UInt32(configuration.maxSequences)
        contextParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        // Candidates fork the prompt: a unified cache makes that a cell-sharing
        // operation instead of a copy.
        contextParams.kv_unified = true
        // Sliding-window models (Gemma) can only trim their cache for prefix reuse
        // when the SWA cache is kept at full size.
        contextParams.swa_full = true
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LlamaError.contextInit(modelPath)
        }

        self.model = model
        self.context = context
        self.vocabPointer = llama_model_get_vocab(model)
        self.maxSequences = configuration.maxSequences
        self.contextLength = Int(llama_n_ctx(context))
        self.batchCapacity = configuration.batchSize
        self.batch = llama_batch_init(Int32(max(configuration.batchSize, configuration.maxSequences)),
                                      0, Int32(configuration.maxSequences))
        self.supportsSplice = llama_memory_can_shift(llama_get_memory(context))
            && llama_model_n_swa(model) == 0
        self.vocab = Self.buildVocab(vocabPointer)
    }

    deinit {
        if let adapter { llama_adapter_lora_free(adapter) }
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    private static func buildVocab(_ vocab: OpaquePointer) -> VocabIndex {
        let n = Int(llama_vocab_n_tokens(vocab))
        var pieces = [[UInt8]](repeating: [], count: n)
        var blocked = [Bool](repeating: false, count: n)
        var eog = [Bool](repeating: false, count: n)
        var buffer = [CChar](repeating: 0, count: 256)
        for i in 0..<n {
            let id = llama_token(i)
            let length = llama_token_to_piece(vocab, id, &buffer, Int32(buffer.count), 0, false)
            if length > 0 {
                pieces[i] = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
            }
            eog[i] = llama_vocab_is_eog(vocab, id)
            blocked[i] = eog[i] || llama_vocab_is_control(vocab, id) || length <= 0
        }
        return VocabIndex(pieces: pieces, blocked: blocked, endOfGeneration: eog)
    }

    // MARK: Adapters

    /// Apply a LoRA adapter (e.g. one tuned on the author's writing) at `scale`, or
    /// clear it with nil. The prompt cache is dropped: its states were computed
    /// without the adapter.
    public func setAdapter(path: String?, scale: Float = 1) throws {
        guard let path else {
            _ = llama_set_adapters_lora(context, nil, 0, nil)
            if let adapter { llama_adapter_lora_free(adapter) }
            adapter = nil
            adapterPath = nil
            reset()
            return
        }
        guard let loaded = llama_adapter_lora_init(model, path) else { throw LlamaError.adapterLoad(path) }
        var adapters: [OpaquePointer?] = [loaded]
        var scales: [Float] = [scale]
        guard llama_set_adapters_lora(context, &adapters, 1, &scales) == 0 else {
            llama_adapter_lora_free(loaded)
            throw LlamaError.adapterLoad(path)
        }
        if let adapter { llama_adapter_lora_free(adapter) }
        adapter = loaded
        adapterPath = path
        reset()
    }

    // MARK: Model info

    public var addsBOS: Bool { llama_vocab_get_add_bos(vocabPointer) }

    public var modelDescription: String {
        var buffer = [CChar](repeating: 0, count: 256)
        let n = llama_model_desc(model, &buffer, buffer.count)
        return n > 0 ? String(cString: buffer) : URL(fileURLWithPath: modelPath).lastPathComponent
    }

    public func metadata(_ key: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 512)
        let n = llama_model_meta_val_str(model, key, &buffer, buffer.count)
        return n >= 0 ? String(cString: buffer) : nil
    }

    // MARK: Tokens

    public func tokenize(_ text: String, addSpecial: Bool) -> [TokenID] {
        tokenize(text, addSpecial: addSpecial, parseSpecial: true)
    }

    public func tokenize(_ text: String, addSpecial: Bool, parseSpecial: Bool) -> [TokenID] {
        let byteCount = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(byteCount) + 8)
        var count = text.withCString {
            llama_tokenize(vocabPointer, $0, byteCount, &tokens, Int32(tokens.count), addSpecial, parseSpecial)
        }
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = text.withCString {
                llama_tokenize(vocabPointer, $0, byteCount, &tokens, Int32(tokens.count), addSpecial, parseSpecial)
            }
        }
        return Array(tokens.prefix(Int(max(0, count))))
    }

    public func detokenize(_ tokens: [TokenID]) -> String {
        String(decoding: tokens.flatMap { vocab.pieces[Int($0)] }, as: UTF8.self)
    }

    // MARK: TokenModel

    public func evaluatePrompt(_ tokens: [TokenID]) throws -> Logits {
        try evaluatePrompt(tokens, allowSplice: false)
    }

    /// - Parameter allowSplice: reuse the cached tail after a removed middle span by
    ///   shifting it. Approximate: the kept tokens' cached states were computed while
    ///   attending to the removed span. Fine for old text scrolling out of the
    ///   window; wrong when context *changed* (the old context would stay baked in).
    public func evaluatePrompt(_ tokens: [TokenID], allowSplice: Bool) throws -> Logits {
        precondition(!tokens.isEmpty, "evaluatePrompt needs at least one token")
        guard tokens.count < contextLength else { throw LlamaError.contextFull }
        // Candidate sequences never outlive a request, but make sure.
        for seq in 1..<maxSequences { drop(sequence: seq) }

        var common = commonPrefix(cachedTokens, tokens)
        if common < cachedTokens.count, allowSplice, supportsSplice {
            common = splice(from: common, toMatch: tokens)
        }
        if common < cachedTokens.count {
            if !llama_memory_seq_rm(memory, 0, Int32(common), -1) {
                llama_memory_clear(memory, true)
                common = 0
            }
            cachedTokens.removeSubrange(common...)
        }
        let suffix = Array(tokens[common...])
        lastPrefillCount = suffix.count
        try decodePrompt(suffix, startPosition: common)
        return Logits(UnsafeBufferPointer(start: llama_get_logits_ith(context, -1), count: vocab.count))
    }

    public func fork(to sequence: Int) {
        precondition(sequence > 0 && sequence < maxSequences)
        llama_memory_seq_rm(memory, Int32(sequence), -1, -1)
        llama_memory_seq_cp(memory, 0, Int32(sequence), -1, -1)
    }

    public func decode(_ entries: [BatchEntry]) throws -> [Logits] {
        guard !entries.isEmpty else { return [] }
        precondition(entries.count <= batchCapacity)
        batch.n_tokens = Int32(entries.count)
        for (i, entry) in entries.enumerated() {
            batch.token[i] = entry.token
            batch.pos[i] = Int32(entry.position)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = Int32(entry.sequence)
            batch.logits[i] = 1
        }
        let status = llama_decode(context, batch)
        guard status == 0 else { throw LlamaError.decode(status) }
        return (0..<entries.count).map {
            Logits(UnsafeBufferPointer(start: llama_get_logits_ith(context, Int32($0)), count: vocab.count))
        }
    }

    public func drop(sequence: Int) {
        guard sequence > 0 else { return }
        llama_memory_seq_rm(memory, Int32(sequence), -1, -1)
    }

    /// Drop everything, including the cached prompt.
    public func reset() {
        llama_memory_clear(memory, true)
        cachedTokens.removeAll()
    }

    // MARK: Internals

    private var memory: llama_memory_t { llama_get_memory(context) }

    private func commonPrefix(_ a: [TokenID], _ b: [TokenID]) -> Int {
        var i = 0
        let limit = min(a.count, b.count - 1)   // always leave ≥1 token to feed
        while i < limit, a[i] == b[i] { i += 1 }
        return i
    }

    /// If `tokens` continues as if a span right after `common` had been deleted from
    /// the cache (`cached = head + removed + rest`, `tokens = head + rest + …`),
    /// remove that span and shift the rest left. Returns the new common prefix.
    private func splice(from common: Int, toMatch tokens: [TokenID]) -> Int {
        let probe = 16
        guard tokens.count - common > probe else { return common }
        let needle = Array(tokens[common..<(common + probe)])
        var start = common + 1
        while start + probe <= cachedTokens.count {
            if Array(cachedTokens[start..<(start + probe)]) == needle {
                let removed = start - common
                guard llama_memory_seq_rm(memory, 0, Int32(common), Int32(start)) else { return common }
                llama_memory_seq_add(memory, 0, Int32(start), -1, Int32(-removed))
                cachedTokens.removeSubrange(common..<start)
                return commonPrefix(cachedTokens, tokens)
            }
            start += 1
        }
        return common
    }

    private func decodePrompt(_ tokens: [TokenID], startPosition: Int) throws {
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
}
