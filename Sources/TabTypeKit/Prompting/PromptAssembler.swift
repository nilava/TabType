import Foundation

/// Everything known about the writing situation at the caret.
public struct PromptContext: Sendable, Equatable {
    /// The field's text before the caret — what gets continued.
    public var typedText: String
    public var appName: String?
    public var windowTitle: String?
    /// The writer's name (e.g. from the Mac account) — used as their speaker label
    /// in conversations and as "about me" context.
    public var authorName: String?
    /// Global + per-app custom instructions from settings.
    public var customInstructions: String?
    /// What's on screen around the field (AX transcript or OCR), newest last.
    public var screenText: String?
    /// `screenText` is a conversation with `Name: message` lines.
    public var isConversation: Bool
    public var clipboard: String?

    public init(typedText: String, appName: String? = nil, windowTitle: String? = nil,
                authorName: String? = nil, customInstructions: String? = nil,
                screenText: String? = nil, isConversation: Bool = false, clipboard: String? = nil) {
        self.typedText = typedText
        self.appName = appName
        self.windowTitle = windowTitle
        self.authorName = authorName
        self.customInstructions = customInstructions
        self.screenText = screenText
        self.isConversation = isConversation
        self.clipboard = clipboard
    }
}

/// Character budgets per prompt section. The typed text keeps its most recent
/// characters; screen text keeps its newest lines.
public struct PromptBudgets: Sendable, Equatable {
    public var typedText = 2000
    public var screenText = 1500
    public var clipboard = 400
    public var customInstructions = 600
    public init() {}
}

/// Builds the text the decoder continues. The result always ends with the typed
/// text, so token healing applies to exactly what the author typed.
///
/// Section order is stable → volatile (instructions and app first, screen text
/// next, typed text last) so consecutive keystrokes reuse the cached prompt and a
/// screen-context refresh only recomputes the tail.
public struct PromptAssembler: Sendable {
    public var template: ModelTemplate
    public var budgets: PromptBudgets

    public init(template: ModelTemplate, budgets: PromptBudgets = PromptBudgets()) {
        self.template = template
        self.budgets = budgets
    }

    public func assemble(_ context: PromptContext) -> String {
        switch template.kind {
        case .base: return assembleBase(context)
        case .chat: return assembleChat(context)
        }
    }

    // MARK: Base models: continue a document

    private func assembleBase(_ c: PromptContext) -> String {
        var parts: [String] = []
        if let notes = clean(c.customInstructions, limit: budgets.customInstructions) {
            parts.append("Notes about the writer: \(notes)")
        }
        let typed = typedText(c)
        if let screen = screenText(c) {
            if c.isConversation {
                // The author's reply is the next line of the conversation.
                return join(parts + [screen + "\n" + speaker(c) + ": " + typed])
            }
            parts.append(screen)
        }
        if let clip = clean(c.clipboard, limit: budgets.clipboard) {
            parts.append("Copied text: \(clip)")
        }
        return join(parts + [typed])
    }

    // MARK: Chat models: instruction in the user turn, typed text pre-filled

    private func assembleChat(_ c: PromptContext) -> String {
        var user: [String] = []
        let place = [c.appName, c.windowTitle].compactMap { $0?.isEmpty == false ? $0 : nil }
        let whereText = place.isEmpty ? "" : " in \(place.joined(separator: " — "))"
        user.append("I'm typing a text\(whereText). Continue it exactly where it stops, as I would write it: "
                    + "same language, tone and formatting. Write only the continuation of my text — "
                    + "never answer it, comment on it, or address me.")
        if let name = c.authorName, !name.isEmpty { user.append("My name is \(name).") }
        if let notes = clean(c.customInstructions, limit: budgets.customInstructions) {
            user.append("About me and how I write: \(notes)")
        }
        if let screen = screenText(c) {
            let label = c.isConversation ? "The conversation so far (newest last; I am \(speaker(c))):"
                                         : "What's on my screen:"
            user.append("\(label)\n\(screen)")
        }
        if let clip = clean(c.clipboard, limit: budgets.clipboard) {
            user.append("Text I just copied:\n\(clip)")
        }
        return template.userPrefix + user.joined(separator: "\n\n") + template.userSuffix
            + template.assistantPrefix + typedText(c)
    }

    // MARK: Sections

    private func speaker(_ c: PromptContext) -> String {
        let first = c.authorName?.split(separator: " ").first.map(String.init)
        return (first?.isEmpty == false ? first : nil) ?? "Me"
    }

    private func typedText(_ c: PromptContext) -> String {
        let full = strip(c.typedText)
        guard full.count > budgets.typedText else { return full }
        let cut = full.index(full.endIndex, offsetBy: -budgets.typedText)
        var text = full[cut...]
        // Start at a word boundary so the prompt doesn't open mid-word.
        if !full[full.index(before: cut)].isWhitespace, let space = text.firstIndex(where: { $0.isWhitespace }) {
            text = text[text.index(after: space)...]
        }
        return String(text)
    }

    private func screenText(_ c: PromptContext) -> String? {
        guard var text = c.screenText.map(strip)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        if text.count > budgets.screenText {
            // Keep the newest lines.
            text = String(text.suffix(budgets.screenText))
            if let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        }
        return text.isEmpty ? nil : text
    }

    private func clean(_ value: String?, limit: Int) -> String? {
        guard let v = value.map(strip)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
            return nil
        }
        return v.count > limit ? String(v.prefix(limit)) : v
    }

    /// Removes the template's reserved markers from untrusted content.
    private func strip(_ text: String) -> String {
        template.reservedMarkers.reduce(text) { $0.replacingOccurrences(of: $1, with: "") }
    }

    private func join(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
