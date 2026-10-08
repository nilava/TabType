import CoreGraphics
import CoreText
import Foundation

/// Open-licence fonts shipped with TabType so ghost text can match apps that use
/// them (Lato in Slack, Inter/Roboto/Open Sans across web apps…).
public enum BundledFonts {
    /// Registers the bundled fonts for this process once; returns their families.
    public static let families: [String] = {
        guard let dir = Bundle.module.url(forResource: "Fonts", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        var families: [String] = []
        for url in files where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] {
                for d in descriptors {
                    if let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String,
                       !families.contains(family) {
                        families.append(family)
                    }
                }
            }
        }
        return families.sorted()
    }()
}

public struct RGB: Equatable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    public var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }
}

/// A screenshot strip reduced to per-pixel "ink" (distance from the background),
/// plus the sampled background and text colours.
public struct InkStrip {
    public let width: Int
    public let height: Int
    /// 0…1 per pixel, row-major from the top.
    public let ink: [Float]
    public let background: RGB
    public let inkColor: RGB

    public init?(image: CGImage) {
        let w = image.width, h = image.height
        guard w >= 8, h >= 6 else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Transparent pixels carry no screen content (a capture can leave holes
        // where excluded windows sat) — they are background, never ink.
        let opaque = (0..<(w * h)).map { rgba[$0 * 4 + 3] >= 128 }
        var lum = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let o = i * 4
            lum[i] = (0.299 * Float(rgba[o]) + 0.587 * Float(rgba[o + 1]) + 0.114 * Float(rgba[o + 2])) / 255
        }
        let opaqueLum = (0..<(w * h)).filter { opaque[$0] }.map { lum[$0] }.sorted()
        guard opaqueLum.count >= w * h / 4 else { return nil }
        let bg = opaqueLum[opaqueLum.count / 2]
        for i in 0..<(w * h) where !opaque[i] { lum[i] = bg }
        let distance = lum.map { abs($0 - bg) }
        // Ink scale: what full-strength text looks like here (95th percentile of
        // clearly-not-background pixels), so faint and bold text both map to ~1.
        let strong = distance.filter { $0 > 0.05 }.sorted()
        let scale = max(strong.isEmpty ? 0.15 : strong[Int(Double(strong.count - 1) * 0.95)], 0.15)
        ink = distance.map { $0 < 0.04 ? 0 : min(1, $0 / scale) }

        func meanColor(where predicate: (Int) -> Bool) -> RGB? {
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for i in 0..<(w * h) where opaque[i] && predicate(i) {
                r += Double(rgba[i * 4]); g += Double(rgba[i * 4 + 1]); b += Double(rgba[i * 4 + 2]); n += 1
            }
            return n > 0 ? RGB(r: r / n / 255, g: g / n / 255, b: b / n / 255) : nil
        }
        let inkMap = ink
        background = meanColor { distance[$0] < 0.03 } ?? RGB(r: Double(bg), g: Double(bg), b: Double(bg))
        inkColor = meanColor { inkMap[$0] > 0.75 } ?? RGB(r: 1 - Double(bg), g: 1 - Double(bg), b: 1 - Double(bg))
        width = w
        height = h
    }

    private init(width: Int, height: Int, ink: [Float], background: RGB, inkColor: RGB) {
        self.width = width
        self.height = height
        self.ink = ink
        self.background = background
        self.inkColor = inkColor
    }

    /// 2×2 box-filtered copy at half resolution.
    func halved() -> InkStrip {
        let w = width / 2, h = height / 2
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (2 * y) * width + 2 * x
                out[y * w + x] = (ink[i] + ink[i + 1] + ink[i + width] + ink[i + width + 1]) / 4
            }
        }
        return InkStrip(width: w, height: h, ink: out, background: background, inkColor: inkColor)
    }

    var columnProfile: [Float] {
        var p = [Float](repeating: 0, count: width)
        for y in 0..<height { for x in 0..<width { p[x] += ink[y * width + x] } }
        return p
    }

    var rowProfile: [Float] {
        var p = [Float](repeating: 0, count: height)
        for y in 0..<height { for x in 0..<width { p[y] += ink[y * width + x] } }
        return p
    }
}

/// Which font, size and baseline reproduce the text left of the caret.
public struct FontFit: Equatable, Sendable {
    public var family: String
    public var pointSize: Double
    /// Baseline position in the strip, in pixels from its top edge.
    public var baselineFromTop: Double
    /// 1 − normalized profile error: ~0.9+ is a convincing match.
    public var confidence: Double
    /// How well the vertical (row) ink profile matched alone: baseline and size can
    /// be trusted from this even when the exact family isn't available.
    public var verticalConfidence: Double
    public var inkColor: RGB
    public var background: RGB
    public var isDarkBackground: Bool { background.luminance < 0.5 }
}

public enum FontFitter {
    /// The system UI font's family name, as CoreText reports it.
    public static var systemFamily: String {
        let font = CTFontCreateUIFontForLanguage(.system, 12, nil)!
        return CTFontCopyFamilyName(font) as String
    }

    /// Default candidates: the system font, common macOS fonts, and the bundled ones.
    public static var defaultCandidates: [String] {
        [systemFamily, "Helvetica Neue", "Helvetica", "Arial", "Georgia", "Times New Roman", "Menlo", "SF Mono"]
            + BundledFonts.families
    }

    /// - Parameters:
    ///   - strip: screenshot of the line around and left of the caret.
    ///   - text: the line's text immediately before the caret (only its visible tail
    ///     matters; longer is fine).
    ///   - caretX: caret position in strip pixels.
    ///   - scale: strip pixels per point (backing scale).
    ///   - expectedSize: rough size in points (from the caret height) to centre the search.
    ///   - knownSize: the exact size when the app reports it (Chromium reports the
    ///     size but not the family) — only the family is searched.
    public static func fit(strip: InkStrip, text: String, caretX: Double, scale: Double,
                           candidates: [String] = defaultCandidates,
                           expectedSize: Double, knownSize: Double? = nil) -> FontFit? {
        let line = String(text.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
        // Keep trailing spaces: the caret sits after them, so they advance the
        // rendered text exactly as on screen.
        let trimmed = line.replacingOccurrences(of: #"[\r\n]+$"#, with: "", options: .regularExpression)
        guard trimmed.trimmingCharacters(in: .whitespaces).count >= 4 else { return nil }

        struct Trial { var family: String; var size: Double; var score: Double; var baseline: Double; var rowError: Double }

        /// Scores one font/size against a strip prepared at a given resolution.
        struct Level {
            let strip: InkStrip
            let caretX: Double
            let scale: Double
            let columns: [Float]
            let rows: [Float]
            let left: Int
            let right: Int
            init?(_ strip: InkStrip, caretX: Double, scale: Double) {
                self.strip = strip
                self.caretX = caretX
                self.scale = scale
                columns = strip.columnProfile
                rows = strip.rowProfile
                // Stop just short of the caret: the blinking caret bar is ink too.
                right = min(strip.width - 1, Int((caretX - scale * 1.5).rounded()))
                // Score only where the observed text is: from its left ink edge to the caret.
                guard let l = columns.firstIndex(where: { $0 > 0.3 }), right - l >= 12 else { return nil }
                left = l
            }
        }

        guard let fine = Level(strip, caretX: caretX, scale: scale) else { return nil }
        // Coarse pass at ~1 px per point (4× fewer pixels) to shortlist candidates.
        var coarseStrip = strip, coarseCaret = caretX, coarseScale = scale
        while coarseScale >= 1.75 {
            coarseStrip = coarseStrip.halved()
            coarseCaret /= 2
            coarseScale /= 2
        }
        let coarse = Level(coarseStrip, caretX: coarseCaret, scale: coarseScale) ?? fine

        func evaluate(_ family: String, _ size: Double, at level: Level) -> Trial? {
            guard let r = score(family: family, size: size, text: trimmed, strip: level.strip,
                                caretX: level.caretX, scale: level.scale, observedColumns: level.columns,
                                observedRows: level.rows, left: level.left, right: level.right) else { return nil }
            return Trial(family: family, size: size, score: r.score, baseline: r.baseline * scale / level.scale,
                         rowError: r.rowError)
        }

        let available = candidates.filter { fontExists($0) }
        let low = knownSize ?? max(7, (expectedSize * 0.55).rounded(.down))
        let high = knownSize ?? min(48, (expectedSize * 1.15).rounded(.up))
        var shortlist: [Trial] = []
        for family in available {
            for size in stride(from: low, through: high, by: 1) {
                if let t = evaluate(family, size, at: coarse) { shortlist.append(t) }
            }
        }
        // Full resolution decides between the coarse leaders, in quarter points.
        var finals: [Trial] = []
        var seen = Set<String>()
        // Shortlist by FAMILY (each family's best coarse size) — otherwise one
        // look-alike family's neighbouring sizes crowd out the rest.
        var bestPerFamily: [String: Trial] = [:]
        for t in shortlist where t.score < (bestPerFamily[t.family]?.score ?? .infinity) { bestPerFamily[t.family] = t }
        // At 1 px/pt similar sans-serifs blur together, so keep six families — and
        // always the system font, which most native apps use.
        var leaders = Array(bestPerFamily.values.sorted(by: { $0.score < $1.score }).prefix(6))
        if let system = bestPerFamily[systemFamily], !leaders.contains(where: { $0.family == systemFamily }) {
            leaders.append(system)
        }
        for leader in leaders {
            let sizes = knownSize.map { [$0] } ?? Array(stride(from: leader.size - 1, through: leader.size + 1, by: 0.25))
            for size in sizes {
                let key = "\(leader.family)|\(size)"
                guard seen.insert(key).inserted, let t = evaluate(leader.family, size, at: fine) else { continue }
                finals.append(t)
            }
        }
        guard let best = finals.min(by: { $0.score < $1.score }) else { return nil }
        return FontFit(family: best.family, pointSize: best.size, baselineFromTop: best.baseline,
                       confidence: max(0, 1 - best.score), verticalConfidence: max(0, 1 - best.rowError),
                       inkColor: strip.inkColor, background: strip.background)
    }

    // MARK: Scoring

    private static func score(family: String, size: Double, text: String, strip: InkStrip, caretX: Double,
                              scale: Double, observedColumns: [Float], observedRows: [Float],
                              left: Int, right: Int) -> (score: Double, baseline: Double, rowError: Double)? {
        let w = strip.width, h = strip.height
        let font = makeFont(family, pixelSize: size * scale)
        // Render with the baseline mid-strip, then slide the row profile into place.
        let probeBaseline = Double(h) * 0.7
        guard let probe = render(text, font: font, width: w, height: h, rightX: caretX, baselineFromTop: probeBaseline)
        else { return nil }
        let renderedRows = rowProfile(probe, w, h)
        var bestShift = 0, bestCorrelation = -Float.infinity
        for shift in -(h / 2)...(h / 2) {
            var c: Float = 0
            for y in 0..<h {
                let src = y - shift
                if src >= 0, src < h { c += observedRows[y] * renderedRows[src] }
            }
            if c > bestCorrelation { bestCorrelation = c; bestShift = shift }
        }
        let baseline = probeBaseline + Double(bestShift)
        // Shifting text vertically doesn't change its column profile (unless it
        // clips), so the probe render serves both measurements.
        let renderedColumns = columnProfile(probe, w, h)
        var rowsPlaced = [Float](repeating: 0, count: h)
        for y in 0..<h where y - bestShift >= 0 && y - bestShift < h { rowsPlaced[y] = renderedRows[y - bestShift] }

        // Allow a few pixels of horizontal slack (caret gap, rounding).
        var bestColumnError = Double.infinity
        for dx in -4...4 {
            let e = normalizedError(observedColumns, renderedColumns, range: left...right, shift: dx)
            bestColumnError = min(bestColumnError, e)
        }
        let rowError = normalizedError(observedRows, rowsPlaced, range: 0...(h - 1), shift: 0)
        return ((bestColumnError * 0.75 + rowError * 0.25), baseline, rowError)
    }

    /// ‖a/|a| − b/|b|‖ / √2 over `range` (b shifted by `shift`): 0 = same shape, 1 = disjoint.
    private static func normalizedError(_ a: [Float], _ b: [Float], range: ClosedRange<Int>, shift: Int) -> Double {
        var aa: Double = 0, bb: Double = 0, ab: Double = 0
        for i in range {
            let j = i - shift
            let av = Double(a[i])
            let bv = (j >= 0 && j < b.count) ? Double(b[j]) : 0
            aa += av * av; bb += bv * bv; ab += av * bv
        }
        guard aa > 0, bb > 0 else { return 1 }
        let cosine = ab / (aa.squareRoot() * bb.squareRoot())
        return (max(0, 2 - 2 * cosine)).squareRoot() / 2.0.squareRoot()
    }

    // MARK: Rendering

    static func fontExists(_ family: String) -> Bool {
        let font = makeFont(family, pixelSize: 12)
        return (CTFontCopyFamilyName(font) as String).caseInsensitiveCompare(family) == .orderedSame
    }

    static func makeFont(_ family: String, pixelSize: Double) -> CTFont {
        if family == systemFamily {
            return CTFontCreateUIFontForLanguage(.system, CGFloat(pixelSize), nil)!
        }
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: family,
            kCTFontTraitsAttribute: [kCTFontWeightTrait: 0.0],
        ] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, CGFloat(pixelSize), nil)
    }

    /// Grayscale coverage (0…1) of `text` drawn right-aligned at `rightX`.
    static func render(_ text: String, font: CTFont, width: Int, height: Int, rightX: Double,
                       baselineFromTop: Double) -> [Float]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSmoothFonts(false)
        ctx.setFillColor(gray: 1, alpha: 1)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        // Full advance, trailing spaces included: the caret sits after them.
        let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: rightX - advance, y: Double(height) - baselineFromTop)
        CTLineDraw(line, ctx)
        return pixels.map { Float($0) / 255 }
    }

    private static func columnProfile(_ p: [Float], _ w: Int, _ h: Int) -> [Float] {
        var c = [Float](repeating: 0, count: w)
        for y in 0..<h { for x in 0..<w { c[x] += p[y * w + x] } }
        return c
    }

    private static func rowProfile(_ p: [Float], _ w: Int, _ h: Int) -> [Float] {
        var r = [Float](repeating: 0, count: h)
        for y in 0..<h { for x in 0..<w { r[y] += p[y * w + x] } }
        return r
    }
}
