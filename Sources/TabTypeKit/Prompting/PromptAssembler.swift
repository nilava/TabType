import Foundation

/// Everything known about the writing situation at the caret.
public struct PromptContext: Sendable, Equatable {
    /// The field's text before the caret — what gets continued.
    public var typedText: String
    /// The field's text immediately after the caret (when editing mid-line or mid-document).
    public var afterText: String?
    public var appName: String?
    public var windowTitle: String?
    /// Browser domain/host when typing in a web browser.
    public var domain: String?
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
    /// Recent examples of the user's writing from `WritingStore`.
    public var recentWritingExamples: [String]?
    public var clipboard: String?
    /// Whether to include system environment metadata (15-minute bucketed date/time
    /// and preferred OS locales).
    public var includeSystemEnvironment: Bool
    /// Optional explicit timestamp override (bucketed to 15-minute intervals).
    public var timestamp: Date?
    /// Optional explicit preferred locales override.
    public var systemLocales: [String]?

    public init(typedText: String, afterText: String? = nil, appName: String? = nil,
                windowTitle: String? = nil, domain: String? = nil,
                fieldPlaceholder: String? = nil, authorName: String? = nil,
                customInstructions: String? = nil, screenText: String? = nil,
                isConversation: Bool = false, recentWritingExamples: [String]? = nil,
                clipboard: String? = nil, includeSystemEnvironment: Bool = false,
                timestamp: Date? = nil, systemLocales: [String]? = nil) {
        self.typedText = typedText
        self.afterText = afterText
        self.appName = appName
        self.windowTitle = windowTitle
        self.domain = domain
        self.fieldPlaceholder = fieldPlaceholder
        self.authorName = authorName
        self.customInstructions = customInstructions
        self.screenText = screenText
        self.isConversation = isConversation
        self.recentWritingExamples = recentWritingExamples
        self.clipboard = clipboard
        self.includeSystemEnvironment = includeSystemEnvironment
        self.timestamp = timestamp
        self.systemLocales = systemLocales
    }
}

/// Character and token budgets per prompt section. The typed text keeps its most
/// recent characters/tokens; screen text keeps its newest lines.
public struct PromptBudgets: Sendable, Equatable {
    public var typedText = 2000
    public var afterText = 400
    public var screenText = 1500
    public var clipboard = 400
    public var customInstructions = 600
    /// Sectioned layout: token caps per section and for the whole prompt. When
    /// the sections together exceed `promptTokens`, context sections give up
    /// tokens in proportion to their size; the typed text keeps its share.
    public var promptTokens = 1800
    public var typedTokens = 360
    public var afterTokens = 192
    public var screenTokens = 576
    public var writingExamplesTokens = 384
    public var clipboardTokens = 288
    public var notesTokens = 960
    public var nearBeforeTokens = 64
    public var nearAfterTokens = 48
    public init() {}
}

/// Builds the text the decoder continues. The result always ends with the typed
/// text, so token healing applies to exactly what the author typed.
///
/// Section order is stable → volatile (instructions and app first, screen text
/// next, typed text last) so consecutive keystrokes reuse the cached prompt and a
/// screen-context refresh only recomputes the tail.
public struct PromptAssembler: Sendable {
    /// Ellipsis marker attached to truncated prompt sections.
    public static let truncationMarker = "…"

    /// Instruction appended to the user turn when using sectioned prompts with chat models.
    public static let sectionedChatInstruction =
        "Continue the draft below naturally from the cursor position, matching my tone, language, and style. Output only the continuation without commentary or placeholders."

    public var template: ModelTemplate
    public var budgets: PromptBudgets
    /// Base models only: open the document with a one-line "where am I" header
    /// (app — window title — field placeholder).
    public var situationHeader: Bool
    /// Structured prose sections with per-section token budgets and mid-line cursor
    /// splitting, shared across `.base` and `.chat` models when enabled.
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
        if sections {
            return assembleSections(context)
        }
        switch template.kind {
        case .base: return assembleBase(context)
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

    // MARK: Natural-prose sectioned layout & mid-line cursor split

    /// Assembles natural-prose context sections ordered from stable to volatile,
    /// with mid-line split layout when text follows the cursor so the model attends
    /// to post-cursor text before continuing the active draft.
    private func assembleSections(_ c: PromptContext) -> String {
        func tokens(_ s: String) -> Int { tokenCount?(s) ?? (s.utf8.count + 3) / 4 }
        /// Truncates `s` to `limit` tokens, adding `truncationMarker` at the cut end.
        func fit(_ s: String, _ limit: Int, keepEnd: Bool, markTruncation: Bool = true) -> String {
            guard limit > 0 else { return "" }
            var text = s
            var n = tokens(text)
            let wasTruncated = n > limit
            while n > limit, !text.isEmpty {
                let keep = max(1, Int(Double(text.count) * Double(limit) / Double(n) * 0.95))
                text = keepEnd ? String(text.suffix(keep)) : String(text.prefix(keep))
                n = tokens(text)
            }
            if keepEnd, text.count < s.count, let space = text.firstIndex(where: \.isWhitespace) {
                text = String(text[text.index(after: space)...])   // start on a word
            }
            if markTruncation, wasTruncated, text.count < s.count, !text.isEmpty {
                text = keepEnd ? (Self.truncationMarker + text) : (text + Self.truncationMarker)
            }
            return text
        }

        func cleanMarked(_ value: String?, limit: Int) -> String? {
            guard let v = value.map(strip)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
                return nil
            }
            guard v.count > limit else { return v }
            return String(v.prefix(limit)) + Self.truncationMarker
        }

        let typed = fit(strip(c.typedText), budgets.typedTokens, keepEnd: true)
        var notes = clean(c.customInstructions, limit: budgets.notesTokens).map {
            fit($0, budgets.notesTokens, keepEnd: false)
        }
        var clip = clean(c.clipboard, limit: .max).map { fit($0, budgets.clipboardTokens, keepEnd: false) }
        var after = clean(c.afterText, limit: .max).map { fit($0, budgets.afterTokens, keepEnd: false) }
        var screen: String? = c.screenText.flatMap { raw in
            let trimmed = strip(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return fit(trimmed, budgets.screenTokens, keepEnd: true)
        }
        let joinedExamples = (c.recentWritingExamples ?? [])
            .map { strip($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        var examples: String? = joinedExamples.isEmpty
            ? nil
            : fit(joinedExamples, budgets.writingExamplesTokens, keepEnd: false)

        // Over the whole-prompt budget: context sections shrink in proportion
        // to their size (newest screen text and the start of notes survive).
        let fixed = tokens(typed) + 64
        let flexible = [notes, screen, examples, clip, after].map { $0.map(tokens) ?? 0 }
        let available = max(0, budgets.promptTokens - fixed)
        let total = flexible.reduce(0, +)
        if total > available, total > 0 {
            let ratio = Double(available) / Double(total)
            notes = notes.map { fit($0, Int(Double(flexible[0]) * ratio), keepEnd: false) }
            screen = screen.map { fit($0, Int(Double(flexible[1]) * ratio), keepEnd: true) }
            examples = examples.map { fit($0, Int(Double(flexible[2]) * ratio), keepEnd: false) }
            clip = clip.map { fit($0, Int(Double(flexible[3]) * ratio), keepEnd: false) }
            after = after.map { fit($0, Int(Double(flexible[4]) * ratio), keepEnd: false) }
        }

        var envLines: [String] = []
        if c.includeSystemEnvironment || c.timestamp != nil {
            let rawDate = c.timestamp ?? Date()
            envLines.append(Self.formatRoundedDateLine(rawDate))
        }
        if let locales = c.systemLocales ?? (c.includeSystemEnvironment ? Locale.preferredLanguages : nil),
           !locales.isEmpty {
            envLines.append("System locales: " + locales.joined(separator: ", "))
        }
        let appRaw = clean(c.appName, limit: 100)
        let fieldRaw = clean(c.fieldPlaceholder, limit: .max)
        if let name = cleanMarked(c.authorName, limit: 100) {
            envLines.append("Author: \(name)")
        }
        if let app = cleanMarked(c.appName, limit: 100) {
            envLines.append("Application: \(app)")
        }
        if let winRaw = clean(c.windowTitle, limit: .max),
           winRaw != appRaw, winRaw != fieldRaw,
           let win = cleanMarked(c.windowTitle, limit: 100) {
            envLines.append("Window: \(win)")
        }
        if let domRaw = clean(c.domain, limit: .max),
           domRaw != fieldRaw,
           let dom = cleanMarked(c.domain, limit: 100) {
            envLines.append("Website: \(dom)")
        }
        if let field = cleanMarked(c.fieldPlaceholder, limit: 100) {
            envLines.append("Field: \(field)")
        } else if envLines.isEmpty, situationHeader, let header = situation(c) {
            envLines.append("Application: \(header)")
        }

        var contextSections: [String] = []
        let hasAnyContext = !envLines.isEmpty
            || (notes?.isEmpty == false)
            || (screen?.isEmpty == false)
            || (examples?.isEmpty == false)
            || (clip?.isEmpty == false)
            || (after?.isEmpty == false)

        if hasAnyContext || template.kind == .chat {
            var preamble = "Background context for the text I'm writing:"
            if !envLines.isEmpty {
                preamble += "\n\n" + envLines.joined(separator: "\n")
            }
            contextSections.append(preamble)
        }
        if let notes, !notes.isEmpty {
            contextSections.append("Writing preferences: \(notes)")
        }
        if let screen, !screen.isEmpty {
            contextSections.append("Visible text on screen:\n\(screen)")
        }
        if let examples, !examples.isEmpty {
            contextSections.append("Past writing samples from me:\n\(examples)")
        }
        if let clip, !clip.isEmpty {
            contextSections.append("Copied to clipboard:\n\(clip)")
        }

        // Mid-line cursor split: when text follows the cursor and `typed` exceeds
        // `nearBeforeTokens`, split `typed` around a sentence/word boundary into
        // `farBefore` + `nearBefore` so both `farBefore` and `nearAfter` sit in the
        // stable prefix and decoding continues seamlessly from `nearBefore`.
        let nearBeforeBudget = budgets.nearBeforeTokens
        let finalTyped: String
        let isMidLineSplit: Bool
        if let after, !after.isEmpty {
            if tokens(typed) > nearBeforeBudget,
               let (farBefore, nearBefore) = Self.splitMidLine(typed, nearTokens: nearBeforeBudget, tokens: tokens) {
                let nearAfter = fit(after, budgets.nearAfterTokens, keepEnd: false)
                contextSections.append("Earlier text in this draft:\n\(farBefore)")
                contextSections.append("Text following the cursor:\n\(nearAfter)")
                finalTyped = nearBefore
                isMidLineSplit = true
            } else {
                contextSections.append("Text following the cursor:\n\(after)")
                finalTyped = typed
                isMidLineSplit = false
            }
        } else {
            finalTyped = typed
            isMidLineSplit = false
        }

        switch template.kind {
        case .base:
            guard hasAnyContext else { return finalTyped }
            let leadIn = isMidLineSplit
                ? "Current line being edited:\n\n"
                : "Current draft:\n\n"
            contextSections.append(leadIn + finalTyped)
            return contextSections.joined(separator: "\n\n")

        case .chat:
            contextSections.append(Self.sectionedChatInstruction)
            let userTurn = contextSections.joined(separator: "\n\n")
            let assistantLeadIn = isMidLineSplit
                ? "Current section to continue:\n"
                : "Draft to continue:\n"
            return template.userPrefix + userTurn + template.userSuffix
                + template.assistantPrefix + assistantLeadIn + finalTyped
        }
    }

    /// Formats the current date and time bucketed to 15-minute intervals (`900` seconds)
    /// so the prompt prefix stays stable across minute ticks for KV cache reuse.
    public static func formatRoundedDateLine(_ date: Date) -> String {
        let interval: TimeInterval = 900.0
        let rounded = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / interval) * interval)
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        return "Current date and time: \(dateFormatter.string(from: rounded)), \(timeFormatter.string(from: rounded))"
    }

    /// Splits `typed` into `(farBefore, nearBefore)` where `nearBefore` is at most
    /// `nearTokens` tokens and starts after a sentence/line/word boundary.
    private static func splitMidLine(_ typed: String, nearTokens: Int, tokens: (String) -> Int) -> (String, String)? {
        let approxChars = max(80, nearTokens * 4)
        guard typed.count > approxChars else { return nil }
        let rawCut = typed.index(typed.endIndex, offsetBy: -approxChars)
        let searchEnd = typed.index(typed.endIndex, offsetBy: -min(32, typed.count / 2))
        guard rawCut < searchEnd else { return nil }
        let window = typed[rawCut..<searchEnd]
        let splitIdx: String.Index
        if let punct = window.lastIndex(where: { ".!?\n".contains($0) }) {
            var next = typed.index(after: punct)
            while next < typed.endIndex, typed[next] == " " { next = typed.index(after: next) }
            splitIdx = next
        } else if let ws = window.firstIndex(where: \.isWhitespace) {
            splitIdx = typed.index(after: ws)
        } else {
            return nil
        }
        let farBefore = String(typed[..<splitIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        let nearBefore = String(typed[splitIdx...])
        guard !farBefore.isEmpty, !nearBefore.isEmpty, tokens(nearBefore) <= nearTokens + 16 else { return nil }
        return (farBefore, nearBefore)
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
        if let after = clean(c.afterText, limit: budgets.afterText) {
            user.append("Text immediately after my cursor (bridge smoothly into it without repeating it):\n\(after)")
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
