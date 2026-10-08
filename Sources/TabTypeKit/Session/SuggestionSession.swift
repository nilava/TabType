import Foundation

/// The lifecycle of the ghost suggestion in one field, as a small state model with
/// a method per event. The app's `Engine` asks it what to do and performs the
/// effects (presenting, inserting, scheduling). Keeping the rules here makes them
/// testable without Accessibility or windows.
///
/// Rules it owns:
/// - type-through: typing exactly what the ghost predicts shrinks it in place;
/// - accepting by word leaves a *protected remainder* that no new prediction may
///   replace until it's used up, typed over, or cleared;
/// - a result generated for older input is never shown;
/// - a result that just repeats the text accepted a moment ago is dropped.
public struct SuggestionSession: Sendable {
    public struct Ghost: Equatable, Sendable {
        public var text: String
        /// The un-accepted tail of a suggestion being accepted word by word.
        public var isRemainder: Bool
    }

    public struct AcceptOptions: Equatable, Sendable {
        public var includeTrailingPunctuation: Bool
        public var includeTrailingSpace: Bool
        public init(includeTrailingPunctuation: Bool = false, includeTrailingSpace: Bool = false) {
            self.includeTrailingPunctuation = includeTrailingPunctuation
            self.includeTrailingSpace = includeTrailingSpace
        }
    }

    /// What to do with a finished prediction.
    public enum Verdict: Equatable, Sendable {
        case present
        /// Generated for older input: drop it; `rekick` asks for a fresh prediction.
        case stale(rekick: Bool)
        /// A remainder is being accepted — don't replace it.
        case held
        /// Just regenerates what was accepted a moment ago.
        case repeatOfAccepted
        case empty
    }

    public private(set) var ghost: Ghost?
    private var lastAccepted: (text: String, at: Date)?

    public init() {}

    public var text: String? { ghost?.text }
    public var isProtectingRemainder: Bool { ghost?.isRemainder == true }

    /// Show `text` as the ghost. A new suggestion never replaces a protected
    /// remainder (returns false); re-presenting the ghost (`isNew: false`) keeps
    /// its role.
    @discardableResult
    public mutating func register(_ text: String, isNew: Bool) -> Bool {
        if isNew {
            if isProtectingRemainder { return false }
            ghost = Ghost(text: text, isRemainder: false)
        } else {
            ghost = Ghost(text: text, isRemainder: ghost?.isRemainder ?? false)
        }
        return true
    }

    /// The user typed `chars`. Returns the shrunken ghost when they typed exactly its
    /// start (type-through), else clears it and returns nil.
    public mutating func typeThrough(_ chars: String) -> String? {
        if let ghost, !chars.isEmpty, ghost.text.hasPrefix(chars), ghost.text.count > chars.count {
            let rest = String(ghost.text.dropFirst(chars.count))
            self.ghost = Ghost(text: rest, isRemainder: ghost.isRemainder)
            return rest
        }
        ghost = nil
        return nil
    }

    /// Accept a word (or everything). Returns the text to insert, or nil when there's
    /// no ghost. The rest stays as a protected remainder.
    public mutating func accept(whole: Bool, options: AcceptOptions, now: Date = Date()) -> (insert: String, remainder: String)? {
        guard let ghost, !ghost.text.isEmpty else { return nil }
        let (insert, remainder) = whole ? (ghost.text, "") : Self.splitFirstWord(ghost.text, options: options)
        self.ghost = remainder.isEmpty ? nil : Ghost(text: remainder, isRemainder: true)
        lastAccepted = (insert, now)
        return (insert, remainder)
    }

    /// Decide what to do with a prediction made for `requestedInput` when the field
    /// now holds `currentInput`.
    public func evaluate(_ suggestion: String, requestedInput: String, currentInput: String,
                         now: Date = Date()) -> Verdict {
        guard !suggestion.isEmpty else { return .empty }
        if requestedInput != currentInput { return .stale(rekick: !isProtectingRemainder) }
        if isProtectingRemainder { return .held }
        if let accepted = lastAccepted, now.timeIntervalSince(accepted.at) < 3,
           suggestion.trimmingCharacters(in: .whitespaces) == accepted.text.trimmingCharacters(in: .whitespaces) {
            return .repeatOfAccepted
        }
        return .present
    }

    /// Escape, focus change, caret moved, field emptied, or any non-matching edit.
    public mutating func clear() { ghost = nil }

    // MARK: Word split

    /// First Tab-chunk of `text`: leading spaces + word (+ one space), with trailing
    /// punctuation and the space held back in the remainder unless the options keep
    /// them. "look? then" → ("look", "? then").
    public static func splitFirstWord(_ text: String, options: AcceptOptions) -> (String, String) {
        var i = text.startIndex
        while i < text.endIndex, text[i] == " " { i = text.index(after: i) }
        while i < text.endIndex, text[i] != " " { i = text.index(after: i) }
        var space = ""
        if i < text.endIndex, text[i] == " " {
            space = " "
            i = text.index(after: i)
        }
        var word = String(text[..<i])
        let rest = String(text[i...])
        if !space.isEmpty { word.removeLast() }

        var punctuation = ""
        if !options.includeTrailingPunctuation {
            while let last = word.last, last.isPunctuation || last == "?" || last == "!",
                  word.trimmingCharacters(in: .whitespaces).count > 1 {
                punctuation = String(last) + punctuation
                word.removeLast()
            }
        }
        if !punctuation.isEmpty { return (word, punctuation + space + rest) }
        if options.includeTrailingSpace { return (word + space, rest) }
        return (word, space + rest)
    }
}
