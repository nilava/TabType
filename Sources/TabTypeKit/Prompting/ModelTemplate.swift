import Foundation

/// How a model wants its prompt framed.
///
/// - `base`: pretrained (non-chat) models simply continue a document.
/// - `chat`: instruct models get one user turn (instruction + context) and an
///   assistant turn that is **already opened with the author's typed text**, so the
///   model continues the author's own words instead of replying to them.
public struct ModelTemplate: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case base, chat }

    public var kind: Kind
    /// Text before the user turn's content (chat only).
    public var userPrefix: String
    /// Appended to the user content, e.g. a no-thinking switch (chat only).
    public var userSuffix: String
    /// Closes the user turn and opens the assistant turn (chat only). The typed
    /// text follows it directly.
    public var assistantPrefix: String
    /// Marker strings that must never appear inside content (stripped from screen
    /// text, clipboard and typed text so they can't break the framing).
    public var reservedMarkers: [String]

    public init(kind: Kind, userPrefix: String = "", userSuffix: String = "",
                assistantPrefix: String = "", reservedMarkers: [String] = []) {
        self.kind = kind
        self.userPrefix = userPrefix
        self.userSuffix = userSuffix
        self.assistantPrefix = assistantPrefix
        self.reservedMarkers = reservedMarkers
    }

    /// Base models continue raw text — but the prompt is tokenized with special
    /// tokens parsed, so control-token strings in captured content (an OCR'd chat
    /// transcript, a pasted prompt) would become real control tokens. Strip the
    /// common families' markers.
    public static let base = ModelTemplate(kind: .base, reservedMarkers: [
        "<|im_start|>", "<|im_end|>", "<|endoftext|>", "<think>", "</think>",
        "<start_of_turn>", "<end_of_turn>", "<bos>", "<eos>",
        "<|turn>", "<turn|>", "<|think|>", "<|channel>", "<channel|>",
        "<|start_header_id|>", "<|end_header_id|>", "<|eot_id|>", "<|begin_of_text|>",
        "<|user|>", "<|assistant|>", "<|end|>", "<|system|>",
    ])

    /// ChatML (Qwen instruct models without a thinking phase).
    public static let chatML = ModelTemplate(
        kind: .chat,
        userPrefix: "<|im_start|>user\n",
        assistantPrefix: "<|im_end|>\n<|im_start|>assistant\n",
        reservedMarkers: ["<|im_start|>", "<|im_end|>", "<|endoftext|>"])

    /// ChatML for hybrid-thinking Qwen3: thinking switched off and an empty
    /// thought block pre-filled so the answer starts immediately.
    public static let chatMLNoThink = ModelTemplate(
        kind: .chat,
        userPrefix: "<|im_start|>user\n",
        userSuffix: "\n/no_think",
        assistantPrefix: "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n",
        reservedMarkers: ["<|im_start|>", "<|im_end|>", "<|endoftext|>", "<think>", "</think>"])

    /// Gemma 2/3 turn markers.
    public static let gemma = ModelTemplate(
        kind: .chat,
        userPrefix: "<start_of_turn>user\n",
        assistantPrefix: "<end_of_turn>\n<start_of_turn>model\n",
        reservedMarkers: ["<start_of_turn>", "<end_of_turn>", "<bos>", "<eos>"])

    /// Gemma 4 turn markers (thinking stays off unless the system turn asks for it).
    public static let gemma4 = ModelTemplate(
        kind: .chat,
        userPrefix: "<|turn>user\n",
        assistantPrefix: "<turn|>\n<|turn>model\n",
        reservedMarkers: ["<|turn>", "<turn|>", "<|think|>", "<|channel>", "<channel|>", "<bos>", "<eos>"])

    /// Llama 3.x headers.
    public static let llama3 = ModelTemplate(
        kind: .chat,
        userPrefix: "<|start_header_id|>user<|end_header_id|>\n\n",
        assistantPrefix: "<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n",
        reservedMarkers: ["<|start_header_id|>", "<|end_header_id|>", "<|eot_id|>", "<|begin_of_text|>"])

    /// Phi-4 mini.
    public static let phi = ModelTemplate(
        kind: .chat,
        userPrefix: "<|user|>",
        assistantPrefix: "<|end|><|assistant|>",
        reservedMarkers: ["<|user|>", "<|assistant|>", "<|end|>", "<|system|>"])

    /// Picks a template for a model that isn't in the catalog (custom GGUFs), from
    /// its name and embedded chat template. Base GGUFs often embed a chat template
    /// too, so the name decides first. Unknown formats fall back to `.base`: plain
    /// continuation works acceptably even on chat models.
    public static func detect(modelName: String, chatTemplate: String?) -> ModelTemplate {
        let name = modelName.lowercased()
        let tokens = Set(name.split(whereSeparator: { "-_ .".contains($0) }).map(String.init))
        if tokens.contains("base") || tokens.contains("pt") || name.contains("pretrain") { return .base }
        guard let t = chatTemplate, !t.isEmpty else { return .base }
        let isInstruct = tokens.contains("instruct") || tokens.contains("it") || tokens.contains("chat")
        // Hybrid-thinking Qwen3 ships unmarked names ("Qwen3-4B") but is a chat model.
        let hybridThinking = t.contains("enable_thinking")
        guard isInstruct || hybridThinking else { return .base }
        if t.contains("<|im_start|>") { return hybridThinking ? .chatMLNoThink : .chatML }
        if t.contains("<|turn>") { return .gemma4 }
        if t.contains("<start_of_turn>") { return .gemma }
        if t.contains("<|start_header_id|>") { return .llama3 }
        if t.contains("<|assistant|>") { return .phi }
        return .base
    }

    /// Named templates, as referenced from the model catalog.
    public static func named(_ name: String) -> ModelTemplate? {
        switch name {
        case "base": return .base
        case "chatml": return .chatML
        case "chatml-nothink": return .chatMLNoThink
        case "gemma": return .gemma
        case "gemma4": return .gemma4
        case "llama3": return .llama3
        case "phi": return .phi
        default: return nil
        }
    }
}
