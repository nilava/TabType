import Foundation

/// A request to complete text at the caret — what `LlamaEngine` turns into a
/// prompt (see `PromptAssembler`).
struct CompletionRequest {
    /// Text before the caret (the thing to continue).
    var beforeCursor: String
    /// Text after the caret (used to avoid duplicating what already follows).
    var afterCursor: String
    /// What's on screen around the field (AX transcript or OCR), may be empty.
    var screenContext: String
    /// Clipboard text, if the user opted in (may be empty).
    var clipboard: String = ""
    /// The document's opening lines when the caret window doesn't reach the start.
    var documentStart: String = ""
    /// `screenContext` is a conversation (`Name: message` lines, newest last).
    var screenIsConversation: Bool = false
    /// Generated mid-burst and PARKED for instant serving on the next pause; never
    /// presented directly.
    var speculative: Bool = false
    /// Cap on suggested words.
    var maxWords: Int
    /// Warm-up request: only prefill the prompt, produce nothing.
    var warmUpOnly: Bool = false
    var appName: String = ""
    var windowTitle: String = ""
    var fieldPlaceholder: String = ""
    var authorName: String = ""
    /// Writing style + global + per-app custom instructions.
    var customInstructions: String = ""
    /// Per-app opt-in to learning from writing (overrides a global "off").
    var learnsFromWriting: Bool = false
}
