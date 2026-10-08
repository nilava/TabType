import AppKit

/// A borderless, non-activating overlay window that shows the suggestion either as
/// dimmed inline "ghost text" at the caret (when precise caret bounds are known) or
/// as a floating pill anchored to the focused window (HUD fallback for Electron /
/// Catalyst apps that don't expose caret bounds). It never takes focus or intercepts
/// mouse events.
@MainActor
final class SuggestionOverlay {

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let background = NSVisualEffectView()
    /// Solid backdrop + caret replica for mirror mode (see `showMirror`).
    private let mirrorBackdrop = NSView()
    private let caretBar = NSView()

    init() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false

        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        mirrorBackdrop.wantsLayer = true
        mirrorBackdrop.layer?.cornerRadius = 3
        mirrorBackdrop.isHidden = true
        caretBar.wantsLayer = true
        caretBar.isHidden = true

        let container = NSView()
        container.addSubview(mirrorBackdrop)
        container.addSubview(background)
        container.addSubview(label)
        container.addSubview(caretBar)
        panel.contentView = container
        self.panel = panel
    }

    // MARK: Inline ghost text (native apps with caret bounds)

    /// Show `text` as dimmed ghost text just right of the caret. `caretRect` is in
    /// Quartz/AX global coordinates (top-left origin). `color`, when provided (from the
    /// screenshot appearance probe), makes the ghost blend with the field's real text.
    ///
    /// Vertically CENTERS the label in the caret rect. For native fields the caret box
    /// hugs the glyphs, so centering ≈ baseline alignment; for web/Electron fields the
    /// caret box is an inflated CSS line box whose real text sits centered — bottom-
    /// aligning into it (the old behavior) pushed the ghost visibly too low.
    /// Returns false when there isn't room for even a couple of characters between
    /// the caret and the right limit — the caller should fall back to the HUD pill.
    ///
    /// When `fieldRect` (the focused text input's frame, AX top-left global) is
    /// provided and sane, the ghost WRAPS like real text: line 1 starts at the caret
    /// (via firstLineHeadIndent), wrapped lines start at the box's left edge, and
    /// nothing draws below the box's bottom.
    @discardableResult
    func showInline(text: String, at caretRect: CGRect, font: NSFont, opacity: Double,
                    color: NSColor? = nil, maxRightX: CGFloat? = nil,
                    fieldRect: CGRect? = nil) -> Bool {
        guard let panel, !text.isEmpty else { hide(); return true }
        background.isHidden = true
        // A previous mirror presentation's opaque backdrop and fake caret must not
        // linger under a plain inline ghost.
        mirrorBackdrop.isHidden = true
        caretBar.isHidden = true

        let ghostColor = (color ?? NSColor.secondaryLabelColor).withAlphaComponent(opacity)
        let padding: CGFloat = 1   // tight against the typed word, like the real text

        if let field = fieldRect, Self.isSaneFieldRect(field, caretRect: caretRect) {
            return showWrapped(text: text, caretRect: caretRect, fieldRect: field,
                               font: font, color: ghostColor, maxRightX: maxRightX,
                               padding: padding, panel: panel)
        }

        // Legacy single-line path (no reliable field rect).
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.stringValue = text
        label.font = font
        // Apply the user's ghost-opacity setting uniformly — whether the color came
        // from the screenshot probe or the neutral-gray fallback — so the Settings
        // slider always has a consistent, visible effect.
        label.textColor = ghostColor
        label.sizeToFit()
        var size = label.intrinsicContentSize

        // Clamp to the window's right edge: a long suggestion must truncate with an
        // ellipsis (lineBreakMode is .byTruncatingTail) instead of overflowing the
        // field. Real text would wrap; ghost text can't, so it truncates.
        if let maxRightX {
            let available = maxRightX - (caretRect.maxX + padding)
            if available < 30 { hide(); return false }
            if available < size.width { size.width = available }
        }

        // The panel is sized exactly to the label; no extra vertical stretch.
        let panelHeight = size.height
        label.frame = CGRect(x: 0, y: 0, width: size.width, height: panelHeight)

        let verticalNudge = caretRect.height > 0
            ? (caretRect.height - panelHeight) / 2
            : 0

        let flippedY = NSScreen.primaryHeight - (caretRect.minY + verticalNudge + panelHeight)
        let origin = CGPoint(x: caretRect.maxX + padding, y: flippedY)
        panel.setFrame(CGRect(origin: origin,
                              size: CGSize(width: size.width + padding, height: panelHeight)),
                       display: true)
        panel.orderFrontRegardless()
        return true
    }

    /// A field rect is usable for wrapping only when it plausibly IS the input box
    /// (Electron sometimes reports degenerate or content-sized frames).
    private static func isSaneFieldRect(_ field: CGRect, caretRect: CGRect) -> Bool {
        guard field.width.isFinite, field.height.isFinite,
              field.width >= 60, field.width <= 2400,
              field.height >= 10, field.height <= 2000 else { return false }
        // The caret must sit inside (or very near) the field.
        return field.insetBy(dx: -8, dy: -8).contains(CGPoint(x: caretRect.midX, y: caretRect.midY))
    }

    /// Cotypist-style wrapping ghost. Line 1 flows from the caret; wrapped lines
    /// start at the field's left edge; lines are capped so nothing draws below the
    /// field's bottom, with tail truncation on the last visible line.
    private func showWrapped(text: String, caretRect: CGRect, fieldRect: CGRect,
                             font: NSFont, color: NSColor, maxRightX: CGFloat?,
                             padding: CGFloat, panel: NSPanel) -> Bool {
        let inset: CGFloat = 4
        var wrapWidth = min(fieldRect.width - inset * 2, 700)
        if let maxRightX { wrapWidth = min(wrapWidth, maxRightX - (fieldRect.minX + inset)) }
        let firstLineIndent = max(0, caretRect.maxX + padding - (fieldRect.minX + inset))
        // Not enough room for even a couple of characters on the caret's line.
        guard wrapWidth - firstLineIndent >= 30 else { hide(); return false }

        let lineHeight = max(caretRect.height, font.ascender + abs(font.descender) + font.leading)
        let linesBelow = max(1, Int((fieldRect.maxY - caretRect.minY) / lineHeight))
        let maxLines = min(3, linesBelow)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.firstLineHeadIndent = firstLineIndent
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ])

        label.maximumNumberOfLines = maxLines
        label.lineBreakMode = .byTruncatingTail   // applies to the final visible line
        label.attributedStringValue = attributed
        label.preferredMaxLayoutWidth = wrapWidth
        var height = label.sizeThatFits(NSSize(width: wrapWidth, height: .greatestFiniteMagnitude)).height
        height = min(height, CGFloat(maxLines) * lineHeight)
        label.frame = CGRect(x: 0, y: 0, width: wrapWidth, height: height)

        // Vertically center line 1 on the caret's line box (same nudge as the
        // single-line path), extending downward for wrapped lines.
        let verticalNudge = (caretRect.height - lineHeight) / 2
        let flippedY = NSScreen.primaryHeight - (caretRect.minY + verticalNudge + height)
        let origin = CGPoint(x: fieldRect.minX + inset, y: flippedY)
        panel.setFrame(CGRect(origin: origin, size: CGSize(width: wrapWidth, height: height)),
                       display: true)
        panel.orderFrontRegardless()
        return true
    }

    // MARK: HUD pill (Electron / Catalyst fallback)

    /// Show `text` as a floating pill with a Tab hint, anchored near the bottom of
    /// `windowRect` (Quartz/AX top-left global coords) or the main screen.
    func showHUD(text: String, windowRect: CGRect?) {
        guard let panel, !text.isEmpty else { hide(); return }
        background.isHidden = false

        label.stringValue = "\(text)   ⇥ Tab"
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.sizeToFit()
        let textSize = label.intrinsicContentSize
        let hPad: CGFloat = 14, vPad: CGFloat = 8
        let w = textSize.width + hPad * 2
        let h = textSize.height + vPad * 2

        background.frame = CGRect(x: 0, y: 0, width: w, height: h)
        label.frame = CGRect(x: hPad, y: vPad, width: textSize.width, height: textSize.height)

        // Anchor bottom-center of the window (or main screen), converted to AppKit.
        let primaryH = NSScreen.primaryHeight
        let anchorX: CGFloat
        let anchorTopLeftY: CGFloat
        if let r = windowRect, r.width > 0 {
            anchorX = r.midX - w / 2
            anchorTopLeftY = r.maxY - h - 12   // just inside the window bottom
        } else if let screen = NSScreen.main {
            anchorX = screen.frame.midX - w / 2
            anchorTopLeftY = primaryH - (screen.frame.origin.y + 120)
        } else {
            anchorX = 100; anchorTopLeftY = 100
        }
        let flippedY = primaryH - (anchorTopLeftY + h)
        panel.setFrame(CGRect(x: anchorX, y: flippedY, width: w, height: h), display: true)
        panel.orderFrontRegardless()
    }

    /// Small floating bubble just ABOVE the caret's line — used for mid-line
    /// suggestions, where an inline ghost would paint over the text after the
    /// caret. `caretRect` is Quartz/AX top-left global.
    func showBubble(text: String, above caretRect: CGRect) {
        guard let panel, !text.isEmpty else { hide(); return }
        background.isHidden = false

        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.stringValue = text
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.sizeToFit()
        let textSize = label.intrinsicContentSize
        let hPad: CGFloat = 10, vPad: CGFloat = 5
        let w = min(textSize.width, 420) + hPad * 2
        let h = textSize.height + vPad * 2

        background.frame = CGRect(x: 0, y: 0, width: w, height: h)
        label.frame = CGRect(x: hPad, y: vPad, width: w - hPad * 2, height: textSize.height)

        // Bottom edge ~4pt above the caret line, left-aligned to the caret,
        // clamped on-screen.
        var x = caretRect.maxX + 2
        if let screen = NSScreen.main { x = min(x, screen.frame.maxX - w - 8) }
        let topLeftY = caretRect.minY - h - 4
        let flippedY = NSScreen.primaryHeight - (topLeftY + h)
        panel.setFrame(CGRect(x: max(8, x), y: flippedY, width: w, height: h), display: true)
        panel.orderFrontRegardless()
    }

    /// Text-mirror mode (Cotypist's `textMirroring`): COVER the tail of the field
    /// with a backdrop in the field's own background colour, and re-render the
    /// typed tail + suggestion ourselves as ONE text run — alignment between them
    /// is exact by construction, and any sub-pixel mismatch with the app's own
    /// rendering hides under the backdrop. A caret replica separates the runs
    /// (the app's real caret is covered).
    ///
    /// `caretRect` is Quartz/AX top-left global; `baseline` the probed text
    /// baseline (global y); colours from the appearance probe.
    func showMirror(typedTail: String, suggestion: String, caretRect: CGRect,
                    baseline: CGFloat, font: NSFont, textColor: NSColor,
                    backgroundColor: NSColor, ghostOpacity: Double,
                    maxRightX: CGFloat?) {
        guard let panel, !suggestion.isEmpty else { hide(); return }
        background.isHidden = true

        let ghostColor = textColor.withAlphaComponent(ghostOpacity)

        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(string: typedTail, attributes: [
            .font: font, .foregroundColor: textColor,
        ]))
        attributed.append(NSAttributedString(string: suggestion, attributes: [
            .font: font, .foregroundColor: ghostColor,
        ]))

        let tailWidth = ceil((typedTail as NSString).size(withAttributes: [.font: font]).width)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.attributedStringValue = attributed
        label.sizeToFit()
        var textWidth = label.intrinsicContentSize.width

        let hPad: CGFloat = 3, vPad: CGFloat = 2
        // The tail/ghost boundary must land exactly at the caret's x.
        let panelX = caretRect.maxX - tailWidth - hPad
        var width = textWidth + hPad * 2
        if let maxRightX {
            let available = maxRightX - panelX
            if available < tailWidth + 30 { hide(); return }
            if width > available { width = available; textWidth = available - hPad * 2 }
        }

        let lineBox = font.ascender + abs(font.descender) + font.leading
        let panelH = lineBox + vPad * 2
        // Label baseline (ascender below its top) sits on the probed baseline.
        let panelTopGlobal = (baseline - font.ascender) - vPad

        // Layout within the panel (AppKit bottom-left origin).
        mirrorBackdrop.isHidden = false
        // A hair of translucency lets any residual colour mismatch blend into the
        // field instead of reading as a hard-edged rectangle.
        mirrorBackdrop.layer?.backgroundColor = backgroundColor.withAlphaComponent(0.98).cgColor
        mirrorBackdrop.frame = CGRect(x: 0, y: 0, width: width, height: panelH)
        label.frame = CGRect(x: hPad, y: vPad, width: textWidth, height: lineBox)
        // Caret replica at the tail/ghost boundary, like a real insertion point.
        caretBar.isHidden = false
        caretBar.layer?.backgroundColor = textColor.cgColor
        caretBar.frame = CGRect(x: hPad + tailWidth, y: vPad + 1,
                                width: 1.5, height: lineBox - 2)

        let flippedY = NSScreen.primaryHeight - (panelTopGlobal + panelH)
        panel.setFrame(CGRect(x: panelX, y: flippedY, width: width, height: panelH),
                       display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        label.stringValue = ""
        mirrorBackdrop.isHidden = true
        caretBar.isHidden = true
    }

    var isVisible: Bool { panel?.isVisible ?? false }
}
