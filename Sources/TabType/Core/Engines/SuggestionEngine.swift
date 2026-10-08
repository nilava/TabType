import Foundation

/// A request to complete text at the caret.
struct CompletionRequest {
    /// Text immediately before the caret (the thing to continue).
    var beforeCursor: String
    /// Text after the caret, sent as fill-in-the-middle context (see `PromptBuilder`).
    var afterCursor: String
    /// Remembered on-screen context (OCR of other windows), may be empty.
    var screenContext: String
    /// Clipboard text, if the user opted in (may be empty).
    var clipboard: String = ""
    /// Short persona preface from personalization settings (may be empty).
    var persona: String = ""
    /// Recent (prefix, accepted-completion) pairs from the user's own history,
    /// rendered as extra few-shot examples in the system prompt.
    var personalExamples: [TypingHistoryStore.AcceptPair] = []
    /// Samples of the author's recent writing (across apps) — voice + topics
    /// context, rendered as `<recently_written_by_author>` in the prompt.
    var previousWriting: [String] = []
    /// The author's last few COMMITTED messages in this app (chat fields empty on
    /// send) — the freshest statement of intent; rendered just before the input.
    var recentMessages: [String] = []
    /// The document's opening lines (long-form apps only, when the caret window
    /// doesn't reach the start) — anchors the topic; rendered as
    /// `<document_start>`, the most stable section in the prompt.
    var documentStart: String = ""
    /// Freshest snippet from the PREVIOUS app/site (≤60s old) — rendered as an
    /// explicitly labeled `<from_previous_app>` block so cross-app context is
    /// background, never mistaken for the current topic.
    var previousAppName: String = ""
    var previousAppContext: String = ""
    /// Whether `screenContext` is a chat conversation (AX transcript) — adds a
    /// "newest last" recency hint for the model.
    var screenIsConversation: Bool = false
    /// Speculative request: generated mid-burst and PARKED for instant serving on
    /// the next pause; its result is never presented directly.
    var speculative: Bool = false
    /// Character budget for screen-memory context in the prompt (chat/messaging apps
    /// get a larger one so more transcript survives — see `AppPolicy.screenContextCap`).
    var screenContextBudget: Int = 700
    /// Frontmost app name, author name and raw custom instructions — the v2 prompt
    /// assembler frames these itself (v1 uses the pre-rendered `persona`).
    var appName: String = ""
    var windowTitle: String = ""
    var fieldPlaceholder: String = ""
    var authorName: String = ""
    var customInstructions: String = ""
    /// Display cap on the suggestion.
    var maxWords: Int
    /// Generation cap.
    var maxTokens: Int
    var temperature: Double
}

/// A pluggable text-completion backend (Apple Intelligence, local MLX, …).
@MainActor
protocol SuggestionEngine: AnyObject {
    var displayName: String { get }
    /// Whether this engine can currently produce completions.
    var isReady: Bool { get }
    /// Produce a trimmed, ready-to-show suggestion, or nil.
    func complete(_ request: CompletionRequest) async -> String?
    /// Invalidate any in-flight result (cooperative; must not tear down GPU work).
    func cancelInFlight()
    /// Fires with a suggestion that finished after its original caller already gave up
    /// (e.g. a coalesced retry the local engine ran once it was free). `Engine` re-runs
    /// the normal post-processing/staleness checks before showing it. Engines without a
    /// coalescing mechanism (e.g. Apple Intelligence) simply never call this.
    var onLateSuggestion: ((String, CompletionRequest) -> Void)? { get set }
}
