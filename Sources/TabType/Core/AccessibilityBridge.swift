import AppKit
import ApplicationServices

/// Notification-based focus tracking: fires the handler (on the main run loop)
/// whenever the focused UI element changes within one app — the instant
/// alternative to noticing a focus change only on the next keystroke.
final class AXFocusObserver {
    private final class Box {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
    }

    private let box: Box
    private var observer: AXObserver?

    init?(pid: pid_t, handler: @escaping () -> Void) {
        box = Box(handler)
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue().handler()
        }
        var obs: AXObserver?
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return nil }
        let app = AXUIElementCreateApplication(pid)
        let result = AXObserverAddNotification(
            obs, app, kAXFocusedUIElementChangedNotification as CFString,
            Unmanaged.passUnretained(box).toOpaque())
        guard result == .success else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }
}

/// Thin wrappers over the macOS Accessibility (AX) API for reading the focused
/// text element, the text preceding the caret, and the caret's screen rectangle.
enum AccessibilityBridge {

    /// Whether TabType has been granted Accessibility permission.
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant Accessibility permission (opens the system dialog
    /// / directs them to System Settings).
    @discardableResult
    static func requestTrust() -> Bool {
        // Key value is "AXTrustedCheckOptionPrompt"; use the literal to avoid a
        // reference to the non-Sendable global CFString constant under Swift 6.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// The system-wide focused UI element, if any.
    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focused else { return nil }
        let element = focused as! AXUIElement
        // Bound AX round-trips so a stalled app can't beach-ball us.
        AXUIElementSetMessagingTimeout(element, 0.05)
        return element
    }

    /// Whether the element is a secure (password) text field — never autocomplete these.
    static func isSecureField(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if (roleRef as? String) == "AXSecureTextField" { return true }
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        return (subroleRef as? String) == "AXSecureTextField"
    }

    /// Keywords that mark a field as credential-adjacent. Matched case-insensitively
    /// against the field's placeholder, title, description, and label. Kept to
    /// unambiguous identity/auth terms — "name" or "address" alone are far too
    /// common in ordinary forms.
    private static let credentialFieldKeywords: [String] = [
        "email", "e-mail", "username", "user name", "user id", "userid",
        "login", "log in", "sign in", "signin", "account number", "iban",
        "phone", "mobile number", "otp", "one-time", "one time code",
        "verification code", "security code", "2fa", "passcode", "pin",
        "card number", "cvv", "cvc", "ssn", "social security", "passport",
    ]

    /// Whether the focused element looks like a credential/identity input (email,
    /// username, OTP, card number…). Secure fields are caught by `isSecureField`;
    /// this covers the plain-text half of login and payment forms, where
    /// autocompleting is at best noise and at worst leaks context. Reads only the
    /// element's own descriptive attributes — a handful of bounded AX round-trips.
    static func isCredentialField(_ element: AXUIElement) -> Bool {
        var labels: [String] = []
        for attr in [kAXPlaceholderValueAttribute, kAXTitleAttribute,
                     kAXDescriptionAttribute, kAXRoleDescriptionAttribute] {
            var ref: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
            if let s = ref as? String, !s.isEmpty { labels.append(s) }
        }
        // A visible label element associated with the field ("Email address").
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleUIElementAttribute as CFString, &titleRef)
        if let titleRef, CFGetTypeID(titleRef) == AXUIElementGetTypeID(),
           let s = stringValue(of: titleRef as! AXUIElement), !s.isEmpty {
            labels.append(s)
        }
        guard !labels.isEmpty else { return false }
        let haystack = labels.joined(separator: " ").lowercased()
        return credentialFieldKeywords.contains { haystack.contains($0) }
    }

    /// Title of the focused element's window ("#design — Acme — Slack").
    static func focusedWindowTitle() -> String? {
        guard let focused = focusedElement(), let window = ContextReader.windowOf(focused) else { return nil }
        return stringAttribute(kAXTitleAttribute as String, of: window)
    }

    /// The field's selection, when one is active: the selected text and the text
    /// before it (both UTF-16-correct).
    static func selection(of element: AXUIElement) -> (selected: String, before: String, after: String)? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.length > 0,
              let full = stringValue(of: element) else { return nil }
        let ns = full as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return nil }
        return (ns.substring(with: NSRange(location: range.location, length: range.length)),
                ns.substring(to: range.location),
                ns.substring(from: range.location + range.length))
    }

    /// A string attribute, or nil.
    static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        let s = (ref as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return s?.isEmpty == false ? s : nil
    }

    /// The URL of the web page containing `element`: AXURL on the element itself, or
    /// on its enclosing AXWebArea (where Chromium keeps it), or on the window.
    static func pageURL(of element: AXUIElement) -> URL? {
        var current: AXUIElement? = element
        for _ in 0..<40 {
            guard let el = current else { break }
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXURLAttribute as CFString, &ref) == .success {
                if let url = ref as? URL { return url }
                if let s = ref as? String, let url = URL(string: s) { return url }
            }
            if role(of: el) == (kAXWindowRole as String) { break }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parent) == .success,
                  let parent else { break }
            current = (parent as! AXUIElement)
        }
        return nil
    }

    /// The full string value of a text element.
    static func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard err == .success else { return nil }
        return value as? String
    }

    /// The caret position as a character offset. Uses the selected text range's
    /// location (caret == zero-length selection).
    static func caretOffset(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard err == .success, let value else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    /// Whether there's text after the caret (rough proxy for "mid-line": the caret
    /// isn't at the very end of the field's content).
    static func hasTextAfterCaret(of element: AXUIElement) -> Bool {
        guard let full = stringValue(of: element), let caret = caretOffset(of: element) else { return false }
        return caret < (full as NSString).length
    }

    /// Children of an element (kAXChildren), or [] when unavailable.
    static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }

    /// The element's AX role, or nil.
    static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    /// Whether the element is an EDITABLE text input. Selected-text-range alone is
    /// not enough — read-only static text and web areas expose it too (anything
    /// selectable does). Editability = a text-input role, or a settable value.
    static func isTextInput(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            let textRoles: Set<String> = [
                kAXTextFieldRole as String, kAXTextAreaRole as String,
                kAXComboBoxRole as String, "AXSearchField",
            ]
            if textRoles.contains(role) { return true }
        }
        var settable = DarwinBoolean(false)
        let err = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    /// True only with POSITIVE evidence that the caret sits at the very end of the
    /// field's text. Unreadable AX (common in Electron) returns false — callers use
    /// this to gate rendering that would overlap any text after the caret.
    static func caretConfirmedAtEnd(of element: AXUIElement) -> Bool {
        guard let full = stringValue(of: element), let caret = caretOffset(of: element) else { return false }
        return caret >= (full as NSString).length
    }

    /// Text immediately preceding the caret, capped at `maxChars`.
    /// Returns nil if AX text isn't available for this element.
    static func textBeforeCaret(of element: AXUIElement, maxChars: Int) -> String? {
        guard let full = stringValue(of: element) else { return nil }
        return String(split(full, caretUTF16: caretOffset(of: element)).before.suffix(maxChars))
    }

    /// Splits `text` at an AX caret offset. AX reports positions in UTF-16 code
    /// units, so slicing by Swift Characters drifts after emoji and combining marks.
    static func split(_ text: String, caretUTF16: Int?) -> (before: String, after: String) {
        let ns = text as NSString
        var caret = min(max(caretUTF16 ?? ns.length, 0), ns.length)
        // Never cut a surrogate pair / composed character in half.
        if caret > 0, caret < ns.length {
            caret = ns.rangeOfComposedCharacterSequence(at: caret).location
        }
        return (ns.substring(to: caret), ns.substring(from: caret))
    }

    /// Text immediately following the caret, capped at `maxChars` — lets the model see
    /// what it would be inserting in front of (true fill-in-the-middle) rather than
    /// only ever knowing what precedes the caret. Returns nil if AX text isn't
    /// available for this element.
    static func textAfterCaret(of element: AXUIElement, maxChars: Int) -> String? {
        guard let full = stringValue(of: element) else { return nil }
        return String(split(full, caretUTF16: caretOffset(of: element)).after.prefix(maxChars))
    }

    /// Screen rectangle (Quartz/top-left origin) of the caret, for overlay placement.
    /// Tries a ladder of strategies (mirrors cotabby/KeyType) and returns the first
    /// valid rect, else nil.
    ///
    /// Some apps (TextEdit included) can return a "zero-length bounds" rect that is
    /// implausibly far from the actual cursor — a known AX quirk. We compute the
    /// preceding-character rect as an anchor whenever possible and only trust the
    /// zero-length rect if it's close to that anchor's trailing edge; otherwise we
    /// prefer the anchor itself. This is what fixed the "wide gap" ghost-text bug.
    static func caretRect(of element: AXUIElement) -> CGRect? {
        guard let raw = rawCaretRect(of: element) else { return nil }
        guard let field = elementFrame(of: element) else { return raw }
        // A caret outside its own field (expanded by 20pt) is stale geometry.
        // (A zero-width caret is an "empty" rect to `intersects`, so test its centre.)
        guard field.insetBy(dx: -20, dy: -20).contains(CGPoint(x: raw.midX, y: raw.midY)) else { return nil }
        return snappedToSingleLineField(raw, field: field)
    }

    /// Single-line fields: when the field is shorter than two caret lines and the
    /// caret's middle falls outside it (an inflated or offset line box), centre the
    /// caret on the field vertically.
    static func snappedToSingleLineField(_ caret: CGRect, field: CGRect) -> CGRect {
        guard caret.height > 0, field.height > 2, field.height < caret.height * 2,
              caret.midY < field.minY || caret.midY > field.maxY else { return caret }
        return caret.offsetBy(dx: 0, dy: field.midY - caret.midY)
    }

    /// Two rects lie on the same visual line: tops and heights agree within 10%.
    static func sameLine(_ a: CGRect, _ b: CGRect) -> Bool {
        let h = max(a.height, b.height)
        return abs(a.minY - b.minY) <= max(1, 0.1 * h) && abs(a.height - b.height) <= max(1, 0.1 * h)
    }

    private static func rawCaretRect(of element: AXUIElement) -> CGRect? {
        guard let caret = caretOffset(of: element) else {
            if let r = textMarkerCaretRect(element), isValidCaretRect(r) { return r }
            return nil
        }

        let anchor: CGRect? = caret > 0
            ? boundsForRange(element, location: caret - 1, length: 1).map {
                CGRect(x: $0.maxX, y: $0.minY, width: 1, height: $0.height)
              }
            : nil

        // Web content (Electron/WebKit/Chromium) exposes AXTextMarker attributes even
        // when it also answers NSRange-based bounds queries — but its NSRange "bounds"
        // frequently reflect an inflated CSS line-box rather than the true glyph line,
        // which is exactly the zero-length-rect failure mode this function otherwise
        // guards against. For such content, prefer the anchor (a real character's
        // rendered position) outright rather than trusting agreement with it.
        let isWebContent = hasTextMarkerSupport(element)

        if let zero = boundsForRange(element, location: caret, length: 0),
           isValidCaretRect(zero) {
            if let anchor {
                if isWebContent {
                    return anchor
                }
                // Trust the zero-length rect only if it's near the anchor (same line,
                // close horizontally); otherwise the anchor is more reliable.
                if abs(zero.minX - anchor.maxX) <= 24, sameLine(zero, anchor) { return zero }
            } else {
                return zero
            }
        }

        // Prefer the anchor (bounds of the preceding character) when the zero-length
        // rect was missing or implausible.
        if let anchor, isValidCaretRect(anchor) { return anchor }

        // AXTextMarker path — WebKit/Chromium (Safari, Chrome, Electron) expose
        // caret geometry via text markers rather than NSRange.
        if let r = textMarkerCaretRect(element), isValidCaretRect(r) { return r }
        return nil
    }

    private static func boundsForRange(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
        guard location >= 0 else { return nil }
        var cfRange = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var boundsRef: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsRef)
        guard err == .success, let boundsRef else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// The field's text style at the caret, as the app reports it over AX.
    struct TextStyle {
        /// The app's font when its name or family resolves locally, else the system
        /// font at the reported size.
        var font: NSFont
        /// Whether `font` is the app's own face (false: only the size was known).
        var familyKnown: Bool
        /// The text colour, when reported.
        var color: NSColor?
    }

    /// The field's font and text colour at the caret, from the AX attributed string.
    /// Cross-process attributed strings carry `AXFont` (a dictionary of name, family
    /// and size) and `AXForegroundColor` (a CGColor) — never an `NSFont`. Reads the
    /// character before the caret (the text the ghost continues), else the one at it.
    static func textStyle(of element: AXUIElement, caret: Int) -> TextStyle? {
        if caret > 0, let style = textStyle(of: element, at: caret - 1) { return style }
        return textStyle(of: element, at: caret)
    }

    private static func textStyle(of element: AXUIElement, at location: Int) -> TextStyle? {
        guard location >= 0 else { return nil }
        var cfRange = CFRange(location: location, length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var attrRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXAttributedStringForRangeParameterizedAttribute as CFString,
            rangeValue, &attrRef) == .success,
            let attributed = attrRef as? NSAttributedString,
            attributed.length > 0 else { return nil }
        let attrs = attributed.attributes(at: attributed.length - 1, effectiveRange: nil)
        var color: NSColor?
        if let raw = attrs[NSAttributedString.Key("AXForegroundColor")],
           CFGetTypeID(raw as CFTypeRef) == CGColor.typeID {
            color = NSColor(cgColor: raw as! CGColor)
        }
        if let font = attrs[.font] as? NSFont {
            return TextStyle(font: font, familyKnown: true, color: color)
        }
        guard let info = attrs[NSAttributedString.Key("AXFont")] as? [String: Any],
              let size = (info["AXFontSize"] as? NSNumber)?.doubleValue,
              size >= 6, size <= 96 else { return nil }
        let name = info["AXFontName"] as? String
        let family = info["AXFontFamily"] as? String
        let bold = (info["AXFontBold"] as? NSNumber)?.boolValue == true
        return TextStyle(font: resolveFont(name: name, family: family, size: CGFloat(size), bold: bold),
                         familyKnown: fontResolves(name: name, family: family),
                         color: color)
    }

    /// The reported face if it's installed (or bundled), by PostScript name then
    /// family; otherwise the system font at the reported size.
    static func resolveFont(name: String?, family: String?, size: CGFloat, bold: Bool = false) -> NSFont {
        if let name, let font = NSFont(name: name, size: size) { return font }
        if let family,
           let font = NSFontManager.shared.font(withFamily: family, traits: bold ? .boldFontMask : [],
                                                weight: bold ? 9 : 5, size: size) {
            return font
        }
        return .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    private static func fontResolves(name: String?, family: String?) -> Bool {
        if let name, NSFont(name: name, size: 12) != nil { return true }
        if let family, NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12) != nil {
            return true
        }
        return false
    }

    /// Left edge of the text on the caret's line: the x of the first character of
    /// the caret's paragraph (wrapped lines of the ghost start there).
    static func paragraphLeftX(of element: AXUIElement, caret: Int) -> CGFloat? {
        guard caret > 0, let value = stringValue(of: element) else { return nil }
        let utf16 = value.utf16
        let end = min(caret, utf16.count)
        var start = end
        let newline = UInt16(UInt8(ascii: "\n"))
        while start > 0, utf16[utf16.index(utf16.startIndex, offsetBy: start - 1)] != newline { start -= 1 }
        guard start < end, let rect = boundsForRange(element, location: start, length: 1),
              rect.height > 2 else { return nil }
        return rect.minX
    }

    /// Whether this element exposes AXTextMarker attributes at all — a signal that
    /// it's WebKit/Chromium web content rather than a native AppKit text field, since
    /// only web content typically implements this API alongside NSRange-based bounds.
    private static func hasTextMarkerSupport(_ element: AXUIElement) -> Bool {
        var markerRange: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success
            && markerRange != nil
    }

    /// Caret rect via AXTextMarker attributes (WebKit/Chromium content editables).
    private static func textMarkerCaretRect(_ element: AXUIElement) -> CGRect? {
        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success,
            let markerRange else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXBoundsForTextMarkerRange" as CFString, markerRange, &boundsRef) == .success,
            let boundsRef else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { return nil }
        // A collapsed marker's bounds are a caret, not a run of text.
        guard rect.width <= 200 else { return nil }
        return rect
    }

    /// Reject bogus caret rectangles (zero-size, off-screen, or absurd) that some
    /// apps — notably Electron/web views like Slack — return. Better to show nothing
    /// than to draw ghost text in the wrong place.
    static func isValidCaretRect(_ rect: CGRect) -> Bool {
        guard rect.width >= 0, rect.height > 2, rect.height < 200 else { return false }
        guard rect.origin.x.isFinite, rect.origin.y.isFinite else { return false }
        // Must intersect some screen (AX uses a top-left global origin; compare in
        // that space by flipping each screen's frame).
        let point = CGPoint(x: rect.midX, y: rect.midY)
        let primaryHeight = NSScreen.primaryHeight
        for screen in NSScreen.screens {
            let f = screen.frame
            let topLeftFrame = CGRect(
                x: f.origin.x,
                y: primaryHeight - f.origin.y - f.height,
                width: f.width, height: f.height)
            if topLeftFrame.insetBy(dx: -20, dy: -20).contains(point) { return true }
        }
        return false
    }

    /// Bundle identifier of the frontmost application.
    static func frontmostBundleId() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Best-effort host of the URL for the focused browser tab (via `kAXURLAttribute`
    /// on the focused element or its window). Returns nil for non-browser contexts.
    /// Host of the frontmost page. Walks up to the enclosing web area (Chromium
    /// keeps AXURL there, not on the field or window). Called several times per
    /// keystroke, so the answer is cached per focused element for a second.
    static func frontmostURLHost() -> String? {
        guard let element = focusedElement() else { return nil }
        if let cached = hostCache, CFEqual(cached.element, element),
           Date().timeIntervalSince(cached.at) < 1 {
            return cached.host
        }
        let host = pageURL(of: element)?.host
        hostCache = (element, Date(), host)
        return host
    }
    nonisolated(unsafe) private static var hostCache: (element: AXUIElement, at: Date, host: String?)?

    private static func urlHost(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
              let value else { return nil }
        if let url = value as? URL { return url.host }
        if let s = value as? String, let url = URL(string: s) { return url.host }
        return nil
    }

    /// Chromium/Electron apps (Slack, VS Code, Discord, Chrome, Arc…) do not expose
    /// their web accessibility tree — including text values and caret bounds — until
    /// a client asks for it by setting `AXManualAccessibility` (and the older
    /// `AXEnhancedUserInterface`) on the application element. Call this once per app
    /// so `stringValue`/`caretRect` start returning real data there.
    static func enableEnhancedAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// Frame (top-left global origin) of an element, from AXPosition + AXSize.
    /// Used as a rough overlay anchor when precise caret bounds aren't available.
    static func elementFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        let rect = CGRect(origin: origin, size: size)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    /// Gets the frame of the window containing the currently focused element.
    static func focusedWindowFrame() -> CGRect? {
        guard let element = focusedElement() else { return nil }
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &winRef) == .success,
              let windowRef = winRef else { return nil }
        let windowElement = windowRef as! AXUIElement
        return elementFrame(of: windowElement)
    }
}
