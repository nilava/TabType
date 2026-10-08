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
        return caret < full.count
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
        return caret >= full.count
    }

    /// Text immediately preceding the caret, capped at `maxChars`.
    /// Returns nil if AX text isn't available for this element.
    static func textBeforeCaret(of element: AXUIElement, maxChars: Int) -> String? {
        guard let full = stringValue(of: element) else { return nil }
        let caret = caretOffset(of: element) ?? full.count
        let clampedCaret = min(max(caret, 0), full.count)
        let chars = Array(full)
        let start = max(0, clampedCaret - maxChars)
        return String(chars[start ..< clampedCaret])
    }

    /// Text immediately following the caret, capped at `maxChars` — lets the model see
    /// what it would be inserting in front of (true fill-in-the-middle) rather than
    /// only ever knowing what precedes the caret. Returns nil if AX text isn't
    /// available for this element.
    static func textAfterCaret(of element: AXUIElement, maxChars: Int) -> String? {
        guard let full = stringValue(of: element) else { return nil }
        let caret = caretOffset(of: element) ?? full.count
        let chars = Array(full)
        let clampedCaret = min(max(caret, 0), chars.count)
        let end = min(chars.count, clampedCaret + maxChars)
        guard clampedCaret < end else { return "" }
        return String(chars[clampedCaret ..< end])
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
                let dx = abs(zero.minX - anchor.maxX)
                let dy = abs(zero.minY - anchor.minY)
                if dx <= 24, dy <= 6 { return zero }
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

    /// The field's actual font at the caret, read from the AX attributed string.
    /// Lets the ghost text match the field's font family and size exactly. Tries the
    /// preceding character first, then the character at/after the caret (helps an
    /// empty field or a caret at position 0, and gives web content a second chance —
    /// some WebKit/Chromium implementations only answer for certain ranges).
    static func fontAtCaret(of element: AXUIElement, caret: Int) -> NSFont? {
        if let font = font(of: element, at: max(0, caret - 1)) { return font }
        return font(of: element, at: caret)
    }

    private static func font(of element: AXUIElement, at location: Int) -> NSFont? {
        var cfRange = CFRange(location: location, length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var attrRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXAttributedStringForRangeParameterizedAttribute as CFString,
            rangeValue, &attrRef) == .success, let attrRef else { return nil }
        let attributed = attrRef as! NSAttributedString
        guard attributed.length > 0 else { return nil }
        return attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
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
        return rect
    }

    /// Reject bogus caret rectangles (zero-size, off-screen, or absurd) that some
    /// apps — notably Electron/web views like Slack — return. Better to show nothing
    /// than to draw ghost text in the wrong place.
    static func isValidCaretRect(_ rect: CGRect) -> Bool {
        guard rect.width >= 0, rect.height > 1, rect.height < 200 else { return false }
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
    static func frontmostURLHost() -> String? {
        guard let element = focusedElement() else { return nil }
        if let h = urlHost(of: element) { return h }
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &winRef) == .success,
           let winRef {
            return urlHost(of: winRef as! AXUIElement)
        }
        return nil
    }

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
