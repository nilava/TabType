import AppKit

/// Detects and drives inline `:emoji:` and `/macro` commands from the keystroke
/// stream, previews results, and reports acceptance back to the Engine. While a
/// command is active, LLM ghost suggestions are suppressed.
@MainActor
final class InlineCommandController {
    enum Mode { case idle, emoji, macro }

    private(set) var mode: Mode = .idle
    private var query = ""
    private var lastChar: Character?
    /// Which char started the session ("/" or ":"), for verifying it still exists.
    private var triggerChar: Character = "/"
    /// Consecutive appended chars for which the query matched nothing and can no
    /// longer become a match — after 3, the session gives up instead of chasing.
    private var unmatchedStreak = 0
    /// Bumped on every state change so async trigger-verification callbacks can
    /// detect they're stale and no-op.
    private var generation = 0
    /// Ranked emoji candidates for the current query, and which one the user has
    /// selected via arrow keys (defaults to the top match). Reset whenever the query
    /// changes.
    private var candidates: [Emoji] = []
    private var selectedIndex = 0

    private let settings: AppSettings
    private let preview = CommandPreviewPanel()
    private let macroEngine = MacroEngine()

    init(settings: AppSettings) { self.settings = settings }

    var isActive: Bool { mode != .idle }

    /// Feed one typed edit. Returns true if a command is (now) active, so the Engine
    /// suppresses LLM suggestions. `caretRect` is resolved lazily for the preview.
    func handleEdit(chars: String, isDeletion: Bool, caretRect: () -> CGRect?) -> Bool {
        if isDeletion {
            guard mode != .idle else { lastChar = nil; return false }
            if query.isEmpty {
                cancel()                    // deleted the trigger itself
            } else {
                query.removeLast()
                refreshPreview(caretRect())
                // The keystroke counter desyncs on selection-deletes (one event,
                // many chars gone) — verify against the REAL field text once the
                // host has published, and cancel if the trigger+query is gone.
                verifyTriggerStillPresent()
            }
            lastChar = nil
            return isActive
        }

        guard let ch = chars.last, chars.count == 1 else { return isActive }

        if mode == .idle {
            if ch == ":" && settings.emojiEnabled {
                mode = .emoji; query = ""; triggerChar = ":"; generation += 1
                refreshPreview(caretRect()); lastChar = ch; return true
            }
            if ch == "/" && settings.macrosEnabled && isWordBoundary(lastChar) {
                mode = .macro; query = ""; triggerChar = "/"; generation += 1
                refreshPreview(caretRect()); lastChar = ch; return true
            }
            lastChar = ch
            return false
        }

        // Active.
        lastChar = ch
        switch mode {
        case .emoji:
            if ch == " " || ch == ":" { cancel(); return false }  // emoji names have no spaces
            query.append(ch)
        case .macro:
            query.append(ch)                                       // allow spaces / -> / digits
        case .idle:
            break
        }
        // Runaway guard.
        if query.count > 40 { cancel(); return false }
        refreshPreview(caretRect())
        // Give up once the query is clearly going nowhere — no match now and no
        // way to become one — instead of shadowing normal typing indefinitely.
        if queryIsDead() {
            unmatchedStreak += 1
            if unmatchedStreak >= 3 { cancel(); return false }
        } else {
            unmatchedStreak = 0
        }
        return true
    }

    /// True when the current query neither matches anything nor could still grow
    /// into a match (macro keyword prefixes and expressions stay alive).
    private func queryIsDead() -> Bool {
        switch mode {
        case .emoji:
            return query.count >= 3 && candidates.isEmpty
        case .macro:
            return !query.isEmpty
                && macroEngine.evaluate(query) == nil
                && !MacroEngine.couldMatch(query)
        case .idle:
            return false
        }
    }

    /// After a deletion, checks (post host-publish) that the field still ends with
    /// `trigger + query`; cancels the session when it doesn't (e.g. the "/" was
    /// removed via a selection-delete the keystroke counter couldn't track).
    private func verifyTriggerStillPresent() {
        let expectedGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            guard let self, self.isActive, self.generation == expectedGeneration else { return }
            guard let element = AccessibilityBridge.focusedElement(),
                  let before = AccessibilityBridge.textBeforeCaret(of: element, maxChars: 60)
            else { return }   // no AX view — keep the counter's verdict
            if !before.hasSuffix(String(self.triggerChar) + self.query) {
                self.cancel()
            }
        }
    }

    /// Try to accept the current command. Returns how many typed chars to delete
    /// (trigger + query) and the text to insert, or nil if there's nothing to accept.
    func accept() -> (deleteCount: Int, insert: String)? {
        guard mode != .idle else { return nil }
        let typedCount = 1 + query.count
        var result: String?
        switch mode {
        case .emoji:
            if candidates.indices.contains(selectedIndex) {
                let e = candidates[selectedIndex]
                EmojiUsageStore.shared.record(e.code)
                result = EmojiMatcher.shared.applyTone(e, SkinTone(rawValue: settings.emojiSkinTone) ?? .none)
            }
        case .macro:
            result = macroEngine.evaluate(query)
        case .idle:
            break
        }
        reset()
        guard let result else { return nil }
        return (typedCount, result)
    }

    func cancel() { reset() }

    /// Move the emoji-candidate selection by `delta` (wrapping), re-rendering the
    /// preview with the new one highlighted. Returns `false` (unhandled) when not in
    /// `.emoji` mode with candidates to choose among, so the caller falls back to
    /// normal navigation-key behavior instead.
    func moveSelection(by delta: Int, caretRect: () -> CGRect?) -> Bool {
        guard mode == .emoji, !candidates.isEmpty else { return false }
        selectedIndex = ((selectedIndex + delta) % candidates.count + candidates.count) % candidates.count
        preview.showEmojiCandidates(candidates, selectedIndex: selectedIndex, caretRect: caretRect())
        return true
    }

    // MARK: - Private

    private func isWordBoundary(_ c: Character?) -> Bool {
        guard let c else { return true }
        return c == " " || c == "\n" || c == "\t"
    }

    private func refreshPreview(_ caret: CGRect?) {
        switch mode {
        case .emoji:
            candidates = Array(EmojiMatcher.preferringGender(
                EmojiMatcher.shared.matches(for: query, limit: 18),
                gender: settings.emojiGender, includeNeutral: settings.emojiIncludeNeutral).prefix(6))
            selectedIndex = 0
            if query.isEmpty {
                preview.show(text: "type an emoji name…", caretRect: caret)
            } else if candidates.isEmpty {
                preview.show(text: "no match", caretRect: caret)
            } else {
                preview.showEmojiCandidates(candidates, selectedIndex: selectedIndex, caretRect: caret)
            }
        case .macro:
            if let r = macroEngine.evaluate(query) {
                preview.show(text: "= \(r)   ⇥", caretRect: caret)
            } else {
                preview.show(text: "/\(query)", caretRect: caret)
            }
        case .idle:
            preview.hide()
        }
    }

    private func reset() {
        mode = .idle
        query = ""
        candidates = []
        selectedIndex = 0
        unmatchedStreak = 0
        generation += 1
        preview.hide()
    }
}
