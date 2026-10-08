import AppKit
import ApplicationServices

/// Reads the text context for a prediction: the current input (text before the caret
/// in the focused field, or the keystroke buffer as a fallback) and the text after
/// the caret. Prompt assembly — including screen context — happens in `PromptBuilder`.
enum ContextReader {

    struct Result {
        /// Dedup key: has the effective model input (screen context + typed input)
        /// changed since the last prediction? Never sent to the model itself.
        var dedupKey: String
        /// Just the text before the caret (the thing to continue).
        var input: String
        /// Text immediately after the caret, if the AX element exposes it (true
        /// fill-in-the-middle context — may be empty if the caret is at the end, or if
        /// AX text isn't available).
        var afterCursor: String
        /// The focused text element, if found (for caret positioning).
        var focused: AXUIElement?
        /// The focused window, if found (for HUD fallback positioning).
        var window: AXUIElement?
        /// Whether any typed input was present (avoid predicting on empty).
        var hasInput: Bool
        /// The document's opening lines when the caret window didn't reach the
        /// start (long-form apps) — empty otherwise.
        var documentStart: String = ""
        /// The focused window's title ("#design — Acme — Slack", a document name…).
        var windowTitle: String = ""
        /// The field's placeholder ("Message Priya", "Reply…"), when it has one.
        var placeholder: String = ""
    }

    /// - fallbackBuffer: keystroke buffer used when AX text isn't available.
    /// - screenContext: remembered on-screen text (may be empty).
    /// - inputChars: cap on how much of the current input (before the caret) to send.
    /// - afterChars: cap on how much text after the caret to send, for fill-in-the-middle.
    /// - wantsDocumentHead: long-form apps — also grab the document's first lines
    ///   when the caret window is a mid-document slice (topic anchoring).
    static func gather(fallbackBuffer: String,
                       screenContext: String,
                       inputChars: Int,
                       afterChars: Int = 300,
                       wantsDocumentHead: Bool = false) -> Result {
        let focused = AccessibilityBridge.focusedElement()
        let window = focused.flatMap { windowOf($0) }

        // One read of the field's value + caret per keystroke; everything else is
        // derived from it.
        let full = focused.flatMap { AccessibilityBridge.stringValue(of: $0) }
        let parts = full.map { AccessibilityBridge.split($0, caretUTF16: focused.flatMap(AccessibilityBridge.caretOffset)) }

        var input = ""
        if let before = parts?.before, !before.isEmpty {
            input = String(before.suffix(inputChars))
        } else {
            input = String(fallbackBuffer.suffix(inputChars))
        }

        // Long-form: if the field holds more text than the caret window shows,
        // the document's opening (title/intro) anchors what this is ABOUT.
        var documentStart = ""
        if wantsDocumentHead, let full, input.count >= inputChars, full.count > inputChars {
            let head = String(full.prefix(300))
            // Don't duplicate: only useful when the head isn't already inside the window.
            if !input.hasPrefix(head) { documentStart = head }
        }

        let afterCursor = parts.map { String($0.after.prefix(afterChars)) } ?? ""
        let windowTitle = window.flatMap { AccessibilityBridge.stringAttribute(kAXTitleAttribute as String, of: $0) } ?? ""
        let placeholder = focused.flatMap {
            AccessibilityBridge.stringAttribute(kAXPlaceholderValueAttribute as String, of: $0)
        } ?? ""

        let dedupKey = screenContext.isEmpty ? input : "\(screenContext.hashValue)|\(input)"

        return Result(dedupKey: dedupKey, input: input, afterCursor: afterCursor,
                      focused: focused, window: window,
                      hasInput: !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      documentStart: documentStart, windowTitle: windowTitle, placeholder: placeholder)
    }

    /// Frame of the window enclosing `element`, if resolvable.
    static func windowRect(of element: AXUIElement) -> CGRect? {
        windowOf(element).flatMap { AccessibilityBridge.elementFrame(of: $0) }
    }

    /// Walk up to the enclosing window element.
    static func windowOf(_ element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value) == .success,
           let value {
            return (value as! AXUIElement)
        }
        var current = element
        for _ in 0..<25 {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parentRef else { return nil }
            let parent = parentRef as! AXUIElement
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(parent, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == (kAXWindowRole as String) { return parent }
            current = parent
        }
        return nil
    }
}
