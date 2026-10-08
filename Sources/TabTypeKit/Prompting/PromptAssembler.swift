import Foundation

/// Everything known about the writing situation at the caret.
public struct PromptContext: Sendable, Equatable {
    /// The field's text before the caret — what gets continued.
    public var typedText: String
    public var appName: String?
    public var windowTitle: String?
    /// The field's placeholder ("Message Priya") — often names the recipient.
    public var fieldPlaceholder: String?
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
                fieldPlaceholder: String? = nil, authorName: String? = nil,
                customInstructions: String? = nil, screenText: String? = nil,
                isConversation: Bool = false, clipboard: String? = nil) {
        self.typedText = typedText
        self.appName = appName
        self.windowTitle = windowTitle
        self.fieldPlaceholder = fieldPlaceholder
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
    /// Sectioned layout: token caps per section and for the whole prompt. When
    /// the sections together exceed `promptTokens`, context sections give up
    /// tokens in proportion to their size; the typed text keeps its share.
    public var promptTokens = 1024
    public var typedTokens = 512
    public var screenTokens = 384
    public var clipboardTokens = 96
    public var notesTokens = 128
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
    /// Base models only: open the document with a one-line "where am I" header
    /// (app — window title — field placeholder).
    public var situationHeader: Bool
    /// Base models: each part of the prompt in its own delimited section with a
    /// token budget (Cotypist's prompt structure), instead of plain paragraphs.
    /// Off by default: with our own delimiters it measured worse on seed-v1
    /// (recall 58.3 → 55.7%); kept for experiments (`tabtype-eval --sections`).
    public var sections: Bool
    /// Tokens in a string (the model's tokenizer); nil estimates from UTF-8 bytes.
    public var tokenCount: (@Sendable (String) -> Int)?

    public init(template: ModelTemplate, budgets: PromptBudgets = PromptBudgets(),
                situationHeader: Bool = false, sections: Bool = false,
                tokenCount: (@Sendable (String) -> Int)? = nil) {
        self.template = template
        self.budgets = budgets
        self.situationHeader = situationHeader
        self.sections = sections
        self.tokenCount = tokenCount
    }

    public func assemble(_ context: PromptContext) -> String {
        switch template.kind {
        case .base: return sections ? assembleSections(context) : assembleBase(context)
        case .chat: return assembleChat(context)
        }
    }

    // MARK: Base models: continue a document

    private func assembleBase(_ c: PromptContext) -> String {
        var parts: [String] = []
        if situationHeader, let header = situation(c) { parts.append(header) }
        if let notes = clean(c.customInstructions, limit: budgets.customInstructions) {
            parts.append("Notes about the writer: \(notes)")
        }
        let typed = typedText(c)
        let screen = screenText(c)
        // Only a real transcript ("Name: message" lines) gets the author's turn as
        // its next line; on screen text read by OCR that framing measured worse
        // (author's own writing: chat recall 31.8 → 33.4% without it).
        if let screen, c.isConversation, Self.looksLikeTranscript(screen) {
            // The author's reply is the next line of the conversation.
            return join(parts + [screen + "\n" + speaker(c) + ": " + typed])
        }
        let clip = clean(c.clipboard, limit: budgets.clipboard)
        if let screen { parts.append(screen) }
        if let clip { parts.append("Copied text: \(clip)") }
        return join(parts + [typed])
    }

    // MARK: Base models: delimited, token-budgeted sections

    /// `<situation>`, `<writer>`, `<clipboard>` and `<screen>` (or `<conversation>`)
    /// sections, stable to volatile, then the typed text in an open `<text>` (or as
    /// the next conversation line) so the model continues it.
    private func assembleSections(_ c: PromptContext) -> String {
        func tokens(_ s: String) -> Int { tokenCount?(s) ?? (s.utf8.count + 3) / 4 }
        /// The part of `s` that fits in `limit` tokens, from its end or its start.
        func fit(_ s: String, _ limit: Int, keepEnd: Bool) -> String {
            guard limit > 0 else { return "" }
            var text = s
            var n = tokens(text)
            while n > limit, !text.isEmpty {
                let keep = max(1, Int(Double(text.count) * Double(limit) / Double(n) * 0.95))
                text = keepEnd ? String(text.suffix(keep)) : String(text.prefix(keep))
                n = tokens(text)
            }
            if keepEnd, text.count < s.count, let space = text.firstIndex(where: \.isWhitespace) {
                text = String(text[text.index(after: space)...])   // start on a word
            }
            return text
        }

        let typed = fit(strip(c.typedText), budgets.typedTokens, keepEnd: true)
        var notes = clean(c.customInstructions, limit: .max).map { fit($0, budgets.notesTokens, keepEnd: false) }
        var clip = clean(c.clipboard, limit: .max).map { fit($0, budgets.clipboardTokens, keepEnd: false) }
        var screen: String? = c.screenText.map { fit(strip($0).trimmingCharacters(in: .whitespacesAndNewlines),
                                                     budgets.screenTokens, keepEnd: true) }
        let header = situationHeader ? situation(c) : nil

        // Over the whole-prompt budget: context sections shrink in proportion
        // to their size (newest screen text and the start of notes survive).
        let fixed = tokens(typed) + (header.map(tokens) ?? 0) + 24
        let flexible = [notes, clip, screen].map { $0.map(tokens) ?? 0 }
        let available = max(0, budgets.promptTokens - fixed)
        let total = flexible.reduce(0, +)
        if total > available, total > 0 {
            let ratio = Double(available) / Double(total)
            notes = notes.map { fit($0, Int(Double(flexible[0]) * ratio), keepEnd: false) }
            clip = clip.map { fit($0, Int(Double(flexible[1]) * ratio), keepEnd: false) }
            screen = screen.map { fit($0, Int(Double(flexible[2]) * ratio), keepEnd: true) }
        }

        var parts: [String] = []
        if let header { parts.append("<situation>\(header)</situation>") }
        if let notes, !notes.isEmpty { parts.append("<writer>\(notes)</writer>") }
        if let clip, !clip.isEmpty { parts.append("<clipboard>\(clip)</clipboard>") }
        if let screen, !screen.isEmpty {
            if c.isConversation {
                // The author's reply is the next line of the conversation.
                parts.append("<conversation>\n\(screen)\n\(speaker(c)): \(typed)")
                return parts.joined(separator: "\n")
            }
            parts.append("<screen>\n\(screen)\n</screen>")
        }
        parts.append("<text>\n\(typed)")
        return parts.joined(separator: "\n")
    }

    /// Most lines read "Speaker: message".
    static func looksLikeTranscript(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return false }
        let labelled = lines.filter { $0.range(of: #"^[^:\n]{1,32}: \S"#, options: .regularExpression) != nil }
        return Double(labelled.count) >= Double(lines.count) * 0.5
    }

    // MARK: Chat models: instruction in the user turn, typed text pre-filled

    private func assembleChat(_ c: PromptContext) -> String {
        var user: [String] = []
        let whereText = situation(c).map { " in \($0)" } ?? ""
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

    /// "Slack — #design-review — Message #design-review": app, window title and the
    /// field placeholder, skipping parts that repeat what's already there.
    private func situation(_ c: PromptContext) -> String? {
        var parts: [String] = []
        for value in [c.appName, c.windowTitle, c.fieldPlaceholder] {
            guard let v = value.map(strip)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty,
                  !parts.contains(where: { $0.localizedCaseInsensitiveContains(v) || v.localizedCaseInsensitiveContains($0) })
            else { continue }
            parts.append(String(v.prefix(80)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

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
