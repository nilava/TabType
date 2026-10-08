import AppKit
import ImageIO
import TabTypeKit
import UniformTypeIdentifiers

/// Measured appearance of the text in a field: which font, size and colours it
/// renders with, and where its baseline sits relative to the caret rect. Fitted
/// once per field from a screenshot (see `FontFitter`) and reused for every ghost.
@MainActor
final class FieldFitCache {
    static let shared = FieldFitCache()

    struct Fit {
        let font: NSFont
        /// Text baseline minus caret-rect top, in points — reusable on any line.
        let baselineOffset: CGFloat
        let textColor: NSColor
        let backgroundColor: NSColor
        let confidence: Double
        /// False when no available font matched the field's (custom app fonts):
        /// size, baseline and colours are measured, the family is the system font.
        let familyMatched: Bool
        let created: Date
    }

    /// Family match needed to use the fitted font itself.
    static let minimumConfidence = 0.8
    /// Vertical match needed to use the measured size/baseline/colours with the
    /// system font when the family can't be matched.
    static let minimumVerticalConfidence = 0.8

    private var fits: [String: Fit] = [:]
    private var inFlight: Set<String> = []

    /// Cached or freshly measured fit for the field at `caret`. nil when the text
    /// can't be measured (no screen permission, too little text, low confidence).
    /// `knownSize`: the size the app reported over AX — only the family is fitted.
    func fit(caret: CGRect, fieldFrame: CGRect?, key: String, lineText: String, verbose: Bool,
             knownSize: CGFloat? = nil) async -> Fit? {
        if let cached = fits[key], Date().timeIntervalSince(cached.created) < 600 { return cached }
        guard !inFlight.contains(key), CGPreflightScreenCaptureAccess() else { return nil }
        let line = String(lineText.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
        guard line.trimmingCharacters(in: .whitespaces).count >= 6 else { return nil }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        // The strip: up to 360pt of the line left of the caret, never past the
        // input box's left edge (its border and whatever is beside it — sidebars,
        // other panes — would pollute the fit), a little taller than the caret so
        // ascenders/descenders are inside but neighbouring lines mostly aren't.
        var leftLimit: CGFloat = 2
        if let field = fieldFrame, field.width >= 60, field.minX < caret.minX, field.maxX + 8 >= caret.minX {
            leftLimit = field.minX + 6
        }
        let width = min(360, max(0, caret.minX - leftLimit))
        let pad = caret.height * 0.2
        let stripRect = CGRect(x: caret.minX - width, y: caret.minY - pad,
                               width: width + 4, height: caret.height + 2 * pad)
        guard width >= 40, let shot = await GhostAppearanceProbe.captureScaled(rect: stripRect) else { return nil }

        _ = BundledFonts.families   // make bundled fonts resolvable
        let caretX = (caret.minX - stripRect.minX) * shot.scale
        let expected = Double(caret.height) * 0.78
        let start = Date()
        let image = shot.image
        let scale = shot.scale
        let result = await Task.detached(priority: .userInitiated) { () -> FontFit? in
            guard let strip = InkStrip(image: image) else { return nil }
            return FontFitter.fit(strip: strip, text: line, caretX: caretX, scale: scale, expectedSize: expected,
                                  knownSize: knownSize.map(Double.init))
        }.value
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        if verbose { Self.dump(image, key: key) }

        guard let result else {
            Log.shared.debug("placement: fit gave no result (\(ms)ms)")
            return nil
        }
        Log.shared.debug("placement: fit\(knownSize == nil ? "" : " (family only)") \(result.family) \(String(format: "%.2f", result.pointSize))pt conf \(String(format: "%.2f", result.confidence)) vertical \(String(format: "%.2f", result.verticalConfidence)) baseline +\(String(format: "%.1f", result.baselineFromTop / scale))pt (\(ms)ms)")
        let familyMatched = result.confidence >= Self.minimumConfidence
        guard familyMatched || result.verticalConfidence >= Self.minimumVerticalConfidence else { return nil }
        let font = familyMatched ? Self.font(result) : NSFont.systemFont(ofSize: CGFloat(result.pointSize))
        guard let font else { return nil }
        let baselineGlobal = stripRect.minY + CGFloat(result.baselineFromTop / scale)
        let fit = Fit(font: font, baselineOffset: baselineGlobal - caret.minY,
                      textColor: Self.color(result.inkColor), backgroundColor: Self.color(result.background),
                      confidence: result.confidence, familyMatched: familyMatched, created: Date())
        fits[key] = fit
        return fit
    }

    /// The cached fit, if fresh — no measuring.
    func cached(key: String) -> Fit? {
        guard let fit = fits[key], Date().timeIntervalSince(fit.created) < 600 else { return nil }
        return fit
    }

    func invalidate() { fits.removeAll() }

    private static func font(_ fit: FontFit) -> NSFont? {
        let size = CGFloat(fit.pointSize)
        if fit.family == FontFitter.systemFamily { return NSFont.systemFont(ofSize: size) }
        return NSFontManager.shared.font(withFamily: fit.family, traits: [], weight: 5, size: size)
    }

    private static func color(_ c: RGB) -> NSColor {
        NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    /// Verbose mode: keep the captured strips for diagnosing placement.
    private static func dump(_ image: CGImage, key: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TabType/fit")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(Int(Date().timeIntervalSince1970))-\(abs(key.hashValue) % 100_000).png"
        guard let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
