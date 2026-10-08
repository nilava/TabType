import AppKit
import CoreGraphics

/// Inserts accepted suggestion text into the frontmost app by synthesizing
/// keyboard events carrying the Unicode string. This avoids touching the
/// pasteboard, so the user's clipboard is never disturbed.
enum TextInserter {

    /// Marker written to each synthesized event's user-data field so our own
    /// `CGEventTap` can recognize and ignore events we injected (otherwise
    /// accepting a suggestion would look like the user typing it).
    static let injectedMarker: Int64 = 0x7AB7_79E5

    /// The text as it will reach the field, after the app's text workarounds.
    static func transformed(_ text: String, options: InsertionOptions) -> String {
        var t = text
        if options.straightQuotes {
            t = t.replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
                .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
        }
        if options.nonBreakingSpaces { t = t.replacingOccurrences(of: " ", with: "\u{00A0}") }
        return t
    }

    /// Insert accepted text in the frontmost app, honouring its insertion
    /// workarounds (`AppPolicy.insertion`).
    @MainActor
    static func insert(_ text: String, policy: AppPolicy) {
        let o = policy.insertion
        let t = transformed(text, options: o)
        guard !t.isEmpty else { return }
        switch o.chunkSize {
        case .some(0):
            paste(t, matchStyle: o.pasteMatchStyle, backspaceAfter: o.backspaceAfterPaste)
        case .some(-1):
            // First word typed, the rest pasted.
            let firstEnd = t.drop(while: { $0 == " " || $0 == "\u{00A0}" })
                .firstIndex(where: { $0 == " " || $0 == "\u{00A0}" }) ?? t.endIndex
            type(String(t[..<firstEnd]), chunk: 16, spaceKeys: o.spaceKeyEvents)
            let rest = String(t[firstEnd...])
            if !rest.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                    paste(rest, matchStyle: o.pasteMatchStyle, backspaceAfter: o.backspaceAfterPaste)
                }
            }
        case let n? where n >= 1:
            type(t, chunk: n, spaceKeys: o.spaceKeyEvents)
        default:
            if resolve(policy.insertionStrategy, for: t) == .paste {
                paste(t, matchStyle: o.pasteMatchStyle, backspaceAfter: o.backspaceAfterPaste)
            } else {
                type(t, chunk: 16, spaceKeys: o.spaceKeyEvents)
            }
        }
    }

    /// Insert `text` using the strategy chosen for the app + payload.
    @MainActor
    static func insert(_ text: String, strategy: InsertionStrategy) {
        guard !text.isEmpty else { return }
        let resolved = resolve(strategy, for: text)
        switch resolved {
        case .paste: paste(text)
        default: insert(text)
        }
    }

    /// Resolve `.auto` to a concrete strategy: paste for multiline or long text
    /// (keystroke injection is slow/unreliable there), keystroke otherwise.
    private static func resolve(_ strategy: InsertionStrategy, for text: String) -> InsertionStrategy {
        switch strategy {
        case .keystroke: return .keystroke
        case .paste: return .paste
        case .auto:
            if text.contains("\n") || text.count >= 80 { return .paste }
            return .keystroke
        }
    }

    /// Clipboard-paste strategy: snapshot the pasteboard, write the text, synthesize
    /// ⌘V, then restore the user's clipboard shortly after.
    @MainActor
    private static func paste(_ text: String, matchStyle: Bool = false, backspaceAfter: Bool = false) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let d = item.data(forType: type) { dict[type] = d } }
            return dict
        } ?? []

        pb.clearContents()
        pb.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyV: CGKeyCode = 0x09
        let flags: CGEventFlags = matchStyle ? [.maskCommand, .maskShift, .maskAlternate] : .maskCommand
        if let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyV, keyDown: true) {
            down.flags = flags
            down.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
            down.post(tap: .cgSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyV, keyDown: false) {
            up.flags = flags
            up.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
            up.post(tap: .cgSessionEventTap)
        }
        if backspaceAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { backspace(count: 1) }
        }

        // Restore the user's clipboard after the paste has been consumed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            pb.clearContents()
            for item in saved {
                let pbItem = NSPasteboardItem()
                for (type, data) in item { pbItem.setData(data, forType: type) }
                pb.writeObjects([pbItem])
            }
        }
    }

    /// Delete `count` characters before the caret via synthesized Backspace presses.
    static func backspace(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let deleteKey: CGKeyCode = 0x33   // Backspace
        for _ in 0..<count {
            if let down = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: true) {
                down.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
                down.post(tap: .cgSessionEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: false) {
                up.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
                up.post(tap: .cgSessionEventTap)
            }
        }
    }

    /// Type `text` in chunks of `chunk` UTF-16 units; with `spaceKeys`, spaces
    /// go as real Space key presses.
    static func type(_ text: String, chunk: Int, spaceKeys: Bool) {
        guard spaceKeys else { return typeChunks(text, chunk: chunk) }
        let source = CGEventSource(stateID: .combinedSessionState)
        var run = ""
        for ch in text {
            if ch == " " {
                typeChunks(run, chunk: chunk); run = ""
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0x31, keyDown: down) else { continue }
                    e.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
                    e.post(tap: .cgSessionEventTap)
                }
            } else {
                run.append(ch)
            }
        }
        typeChunks(run, chunk: chunk)
    }

    /// Type `text` into the focused field via synthesized key events (clipboard-free).
    static func insert(_ text: String) { typeChunks(text, chunk: 16) }

    private static func typeChunks(_ text: String, chunk: Int) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)

        // A single keyDown/keyUp pair carrying the whole string works for most
        // apps; some apps prefer per-character events, so chunk defensively.
        for scalarChunk in text.chunkedByUTF16(maxUnits: max(1, chunk)) {
            let utf16 = Array(scalarChunk.utf16)

            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                down.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
                down.post(tap: .cgSessionEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                up.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
                up.post(tap: .cgSessionEventTap)
            }
        }
    }

    /// Split the accepted suggestion for word-by-word acceptance: returns the first
    /// word (including any leading whitespace and the trailing space) and the rest.
    static func firstWord(of suggestion: String) -> (accepted: String, remainder: String) {
        var idx = suggestion.startIndex
        // Keep leading whitespace with the first word.
        while idx < suggestion.endIndex, suggestion[idx] == " " {
            idx = suggestion.index(after: idx)
        }
        // Consume the word.
        while idx < suggestion.endIndex, suggestion[idx] != " " {
            idx = suggestion.index(after: idx)
        }
        // Include one trailing space if present.
        if idx < suggestion.endIndex, suggestion[idx] == " " {
            idx = suggestion.index(after: idx)
        }
        let accepted = String(suggestion[suggestion.startIndex ..< idx])
        let remainder = String(suggestion[idx...])
        return (accepted, remainder)
    }
}

private extension String {
    /// Split into substrings whose UTF-16 length is at most `maxUnits`.
    func chunkedByUTF16(maxUnits: Int) -> [String] {
        guard utf16.count > maxUnits else { return [self] }
        var result: [String] = []
        var chunk = ""
        for ch in self {
            if chunk.utf16.count + ch.utf16.count > maxUnits {
                result.append(chunk)
                chunk = ""
            }
            chunk.append(ch)
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
}
