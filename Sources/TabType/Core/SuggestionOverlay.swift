import AppKit

/// Draws the ghost run with its own text system: no cell insets, no line-fragment
/// padding, so x and baseline land exactly where they're computed. Line 1 starts at
/// `firstLineIndent`; wrapped lines at 0; the last visible line truncates.
final class GhostTextView: NSView {
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }

    /// Lays out `text` in `width`; returns the used height and line 1's baseline
    /// (from the top).
    func configure(text: String, font: NSFont, color: NSColor, width: CGFloat,
                   firstLineIndent: CGFloat, maxLines: Int) -> (height: CGFloat, firstBaseline: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.firstLineHeadIndent = firstLineIndent
        paragraph.headIndent = 0
        storage.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ]))
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        container.maximumNumberOfLines = maxLines
        container.lineBreakMode = .byTruncatingTail
        let glyphs = layout.glyphRange(for: container)
        let used = layout.usedRect(for: container)
        var baseline = font.ascender
        if glyphs.length > 0 {
            let fragment = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            baseline = fragment.minY + layout.location(forGlyphAt: 0).y
        }
        needsDisplay = true
        return (ceil(used.maxY), baseline)
    }

    override func draw(_ dirtyRect: NSRect) {
        let glyphs = layout.glyphRange(for: container)
        layout.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }
}

/// A borderless, non-activating overlay window that shows the suggestion either as
/// dimmed inline "ghost text" at the caret (when precise caret bounds are known) or
/// as a floating pill anchored to the focused window (HUD fallback for Electron /
/// Catalyst apps that don't expose caret bounds). It never takes focus or intercepts
/// mouse events.
@MainActor
final class SuggestionOverlay {

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    /// The inline ghost (the HUD and bubble use `label`).
    private let ghost = GhostTextView(frame: .zero)
    private let background = NSVisualEffectView()

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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        // Never part of anyone's AX tree (our own hit-tests included).
        panel.setAccessibilityElement(false)

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


        let container = NSView()
        container.addSubview(background)
        container.addSubview(label)
        container.addSubview(ghost)
        ghost.isHidden = true
        panel.contentView = container
        self.panel = panel
    }

    // MARK: Inline ghost text (native apps with caret bounds)

    /// Where a line of `font` text puts its baseline inside a caret line box
    /// (top-left global): the glyph box centred in the line box. Matches CSS
    /// half-leading in web views and is within a point for native text views.
    nonisolated static func defaultBaseline(caret: CGRect, font: NSFont) -> CGFloat {
        let glyphBox = font.ascender + abs(font.descender)
        return caret.minY + (caret.height - glyphBox) / 2 + font.ascender
    }

    /// Show `text` as ghost text continuing from the caret. `caretRect` is AX
    /// top-left global; `baseline` (same space) pins the text's baseline, else it's
    /// derived from the caret box. `color` is the field's text colour when known —
    /// the ghost is that colour at `opacity`.
    ///
    /// With a sane `fieldRect` the ghost WRAPS like real text: line 1 from the
    /// caret, wrapped lines from `leftX` (the paragraph's left edge), never below
    /// the field. Returns false when there's no room for a couple of characters —
    /// the caller falls back to the HUD pill.
    @discardableResult
    func showInline(text: String, at caretRect: CGRect, font: NSFont, opacity: Double,
                    color: NSColor? = nil, maxRightX: CGFloat? = nil,
                    fieldRect: CGRect? = nil, leftX: CGFloat? = nil,
                    baseline: CGFloat? = nil) -> Bool {
        guard let panel, !text.isEmpty else { hide(); return true }
        lastInline = InlinePlacement(caretRect: caretRect, font: font, opacity: opacity, color: color,
                                     maxRightX: maxRightX, fieldRect: fieldRect, leftX: leftX,
                                     baseline: baseline)
        background.isHidden = true
        label.isHidden = true

        let ghostColor = (color ?? NSColor.secondaryLabelColor).withAlphaComponent(opacity)
        let baselineY = baseline ?? Self.defaultBaseline(caret: caretRect, font: font)
        let caretX = caretRect.maxX + 1   // tight against the typed word, like real text

        let originX: CGFloat
        let width: CGFloat
        let indent: CGFloat
        let maxLines: Int
        if let field = fieldRect, Self.isSaneFieldRect(field, caretRect: caretRect) {
            let left = min(leftX ?? field.minX + 4, caretX)
            let rightInset = max(4, left - field.minX)
            var right = field.maxX - rightInset
            if let maxRightX { right = min(right, maxRightX) }
            width = min(right - left, 900)
            indent = caretX - left
            guard width - indent >= 30 else { hide(); return false }
            let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
            let linesBelow = max(1, Int((field.maxY - caretRect.minY) / lineHeight))
            maxLines = min(3, linesBelow)
            originX = left
        } else {
            let natural = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
            let available = (maxRightX ?? .greatestFiniteMagnitude) - caretX
            guard available >= 30 else { hide(); return false }
            width = min(natural, available)
            indent = 0
            maxLines = 1
            originX = caretX
        }

        let laid = ghost.configure(text: text, font: font, color: ghostColor, width: width,
                                   firstLineIndent: indent, maxLines: maxLines)
        ghost.frame = CGRect(x: 0, y: 0, width: width, height: laid.height)
        ghost.isHidden = false
        let top = baselineY - laid.firstBaseline
        let flippedY = NSScreen.primaryHeight - (top + laid.height)
        panel.setFrame(CGRect(x: originX, y: flippedY, width: width, height: laid.height),
                       display: true)
        panel.orderFrontRegardless()
        return true
    }

    /// Everything the last inline ghost was placed with.
    private struct InlinePlacement {
        var caretRect: CGRect
        var font: NSFont
        var opacity: Double
        var color: NSColor?
        var maxRightX: CGFloat?
        var fieldRect: CGRect?
        var leftX: CGFloat?
        var baseline: CGFloat?
    }
    private var lastInline: InlinePlacement?

    /// The user typed (or we inserted) `typed`, the head of the ghost: show
    /// `remainder` where real text now ends — the caret moved by `typed`'s width in
    /// the ghost's own font, which is the field's. Instant; no AX round trip.
    /// False when there's no inline ghost to move or it would leave its line.
    @discardableResult
    func advance(typed: String, remainder: String) -> Bool {
        guard isVisible, ghost.isHidden == false, var placed = lastInline, !remainder.isEmpty,
              !typed.contains("\n") else { return false }
        let width = (typed as NSString).size(withAttributes: [.font: placed.font]).width
        placed.caretRect = placed.caretRect.offsetBy(dx: width, dy: 0)
        if let right = placed.maxRightX ?? placed.fieldRect?.maxX, placed.caretRect.maxX + 30 > right {
            return false   // the typed text wrapped — let the settled caret decide
        }
        return showInline(text: remainder, at: placed.caretRect, font: placed.font, opacity: placed.opacity,
                          color: placed.color, maxRightX: placed.maxRightX, fieldRect: placed.fieldRect,
                          leftX: placed.leftX, baseline: placed.baseline)
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

    // MARK: HUD pill (Electron / Catalyst fallback)

    /// Show `text` as a floating pill with a Tab hint, anchored near the bottom of
    /// `windowRect` (Quartz/AX top-left global coords) or the main screen.
    func showHUD(text: String, windowRect: CGRect?) {
        guard let panel, !text.isEmpty else { hide(); return }
        background.isHidden = false
        label.isHidden = false
        ghost.isHidden = true

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
        label.isHidden = false
        ghost.isHidden = true

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

    func hide() {
        lastInline = nil
        panel?.orderOut(nil)
        label.stringValue = ""
    }

    var isVisible: Bool { panel?.isVisible ?? false }
}
