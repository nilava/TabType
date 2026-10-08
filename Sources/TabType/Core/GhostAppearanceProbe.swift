import AppKit
import ScreenCaptureKit

/// Samples the pixels around the caret to match ghost text to the field's real
/// appearance (like Cotypist's "use screenshots to improve suggestion appearance").
/// Determines the text (foreground) colour and background, and derives a dimmed
/// ghost colour that blends. Throttled + cached so it never blocks typing.
@MainActor
final class GhostAppearanceProbe: ObservableObject {
    static let shared = GhostAppearanceProbe()

    struct Appearance {
        var ghostColor: NSColor
        var textColor: NSColor
        var backgroundColor: NSColor
        var isDark: Bool
    }

    private var cached: Appearance?
    private var lastProbe = Date.distantPast
    private var probing = false
    private let minInterval: TimeInterval = 1.0

    private init() {}

    /// The most recent probed appearance (may be nil until the first probe lands).
    var current: Appearance? { cached }

    /// Kick a probe of the caret line if stale. Non-blocking; updates `cached`.
    func refresh(caretRect: CGRect) {
        guard CGPreflightScreenCaptureAccess(), !probing,
              Date().timeIntervalSince(lastProbe) > minInterval,
              caretRect.width.isFinite, caretRect.height > 1 else { return }
        probing = true
        lastProbe = Date()

        // Sample a strip to the LEFT of the caret (where existing text sits).
        let h = min(max(caretRect.height, 10), 60)
        let sample = CGRect(x: max(0, caretRect.minX - 220), y: caretRect.minY,
                            width: 220, height: h)

        Task.detached(priority: .utility) {
            let appearance = await GhostAppearanceProbe.sample(rect: sample)
            await MainActor.run {
                self.probing = false
                if let appearance { self.cached = appearance }
            }
        }
    }

    /// Whether the given screen strip (Quartz top-left global) contains text-like
    /// pixels — i.e. anything contrasting with the background. Used as a final
    /// occupancy check before drawing inline ghost text there: if pixels say the
    /// spot is occupied, the caller must not paint there, regardless of what the
    /// (sometimes lying) AX caret geometry claims. nil = couldn't sample
    /// (no permission / capture failure) — caller decides the default.
    ///
    nonisolated static func hasTextPixels(in rect: CGRect) async -> Bool? {
        guard rect.width >= 8, rect.height >= 6 else {
            Log.shared.debug("occupancy: strip \(rect) too small — nil")
            return nil
        }
        guard CGPreflightScreenCaptureAccess() else {
            Log.shared.debug("occupancy: no screen-capture permission — nil")
            return nil
        }
        guard let image = await capture(rect: rect) else {
            Log.shared.debug("occupancy: capture failed for \(rect) — nil")
            return nil
        }
        guard let spread = contrastSpread(image) else {
            Log.shared.debug("occupancy: analysis failed — nil")
            return nil
        }
        Log.shared.debug("occupancy: strip=\(rect) contrast=\(String(format: "%.3f", spread)) -> \(spread > 0.12 ? "OCCUPIED" : "free")")
        return spread > 0.12
    }

    struct InkBand {
        var top: CGFloat        // ascent line of the tallest glyph sampled
        var bottom: CGFloat     // descender bottom
        /// Estimated text BASELINE: the row where per-row ink density collapses
        /// (below the baseline only sparse descenders remain). Glyph-mix
        /// independent — the stable anchor for aligning ghost text.
        var baseline: CGFloat
    }

    /// The vertical band of screen rows (in global top-left points) that contain
    /// glyph ink within `rect` — sampled from the REAL text left of the caret so
    /// the ghost can align to where the text actually renders, instead of trusting
    /// the (padded, app-dependent) AX line box. nil when the strip is empty or
    /// capture fails.
    nonisolated static func inkBand(in rect: CGRect) async -> InkBand? {
        guard rect.width >= 20, rect.height >= 8,
              CGPreflightScreenCaptureAccess(),
              let image = await capture(rect: rect),
              let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        let bpr = image.bytesPerRow, bpp = image.bitsPerPixel / 8
        guard bpp >= 3, image.width > 0, image.height > 0 else { return nil }

        // Background = modal colour of the whole strip.
        var counts: [UInt32: Int] = [:]
        let stepX = max(1, image.width / 120)
        func lum(_ o: Int) -> Double {
            0.299 * Double(ptr[o]) / 255 + 0.587 * Double(ptr[o + 1]) / 255 + 0.114 * Double(ptr[o + 2]) / 255
        }
        /// Transparent (a hole where one of our own windows sat): no content.
        func hole(_ o: Int) -> Bool {
            bpp >= 4 && ptr[o] == 0 && ptr[o + 1] == 0 && ptr[o + 2] == 0 && ptr[o + 3] == 0
        }
        for y in stride(from: 0, to: image.height, by: max(1, image.height / 24)) {
            for x in stride(from: 0, to: image.width, by: stepX) {
                let o = y * bpr + x * bpp
                if hole(o) { continue }
                let r = Double(ptr[o]) / 255, g = Double(ptr[o + 1]) / 255, b = Double(ptr[o + 2]) / 255
                counts[(UInt32(r * 7) << 6) | (UInt32(g * 7) << 3) | UInt32(b * 7), default: 0] += 1
            }
        }
        guard let bgKey = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let bgLum = 0.299 * Double((bgKey >> 6) & 7) / 7 + 0.587 * Double((bgKey >> 3) & 7) / 7
            + 0.114 * Double(bgKey & 7) / 7

        // Per-row ink density (count of contrasting sampled pixels).
        var density = [Int](repeating: 0, count: image.height)
        for y in 0..<image.height {
            for x in stride(from: 0, to: image.width, by: stepX)
            where !hole(y * bpr + x * bpp) && abs(lum(y * bpr + x * bpp) - bgLum) > 0.18 {
                density[y] += 1
            }
        }
        guard let maxDensity = density.max(), maxDensity >= 3 else { return nil }
        guard let firstInk = density.firstIndex(where: { $0 > 0 }),
              let lastInk = density.lastIndex(where: { $0 > 0 }),
              lastInk > firstInk + 3 else { return nil }
        // Baseline = last reasonably-dense row. Descender rows (below baseline)
        // carry only a few glyphs' worth of ink; the x-height body is dense.
        let threshold = max(2, Int(Double(maxDensity) * 0.30))
        let baselineRow = density.lastIndex(where: { $0 >= threshold }) ?? lastInk

        let scale = CGFloat(image.height) / rect.height
        return InkBand(top: rect.minY + CGFloat(firstInk) / scale,
                       bottom: rect.minY + CGFloat(lastInk + 1) / scale,
                       baseline: rect.minY + CGFloat(baselineRow + 1) / scale)
    }

    // MARK: - Sampling

    nonisolated private static func sample(rect: CGRect) async -> Appearance? {
        guard let image = await capture(rect: rect) else { return nil }
        return analyze(image)
    }

    nonisolated private static func capture(rect: CGRect) async -> CGImage? {
        await captureScaled(rect: rect)?.image
    }

    /// Screenshot of `rect` (top-left global points) at the display's real pixel
    /// scale, with TabType's own windows excluded so the ghost never sees itself.
    nonisolated static func captureScaled(rect: CGRect) async -> (image: CGImage, scale: Double)? {
        guard let content = await ShareableContentCache.shared.content() else { return nil }
        guard let display = content.displays.first(where: { displayRectTopLeft($0).intersects(rect) })
                ?? content.displays.first else { return nil }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let scale = pixelScale(of: display)
        let config = SCStreamConfiguration()
        // sourceRect is in points, top-left origin relative to the display.
        // ScreenCaptureKit rounds a fractional source rect outward to whole points
        // and then aspect-fits it into width×height, squeezing the content and
        // leaving transparent columns. So capture the whole-point rect at exactly
        // `scale`, then crop back to the requested rect.
        let local = CGRect(x: rect.minX - display.frame.minX,
                           y: rect.minY - displayRectTopLeft(display).minY,
                           width: rect.width, height: rect.height)
        let integral = local.integral
        config.sourceRect = integral
        config.width = max(1, Int((integral.width * scale).rounded()))
        config.height = max(1, Int((integral.height * scale).rounded()))
        config.showsCursor = false
        guard let full = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        else { return nil }
        let crop = CGRect(x: ((local.minX - integral.minX) * scale).rounded(),
                          y: ((local.minY - integral.minY) * scale).rounded(),
                          width: (local.width * scale).rounded(),
                          height: (local.height * scale).rounded())
        guard let image = full.cropping(to: crop) else { return nil }
        return (image, scale)
    }

    /// Backing scale of a display (2 on Retina, 1 on most external monitors).
    nonisolated private static func pixelScale(of display: SCDisplay) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(display.displayID), display.width > 0 else { return 2 }
        return max(1, Double(mode.pixelWidth) / Double(display.width))
    }

    /// Max luminance distance of any sampled pixel from the modal (background)
    /// colour — ~0 for an empty strip, high when glyphs are present.
    nonisolated private static func contrastSpread(_ image: CGImage) -> Double? {
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        let bpr = image.bytesPerRow
        let bpp = image.bitsPerPixel / 8
        guard bpp >= 3 else { return nil }
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }

        var lums: [Double] = []
        let stepX = max(1, w / 60), stepY = max(1, h / 20)
        for y in stride(from: 0, to: h, by: stepY) {
            for x in stride(from: 0, to: w, by: stepX) {
                let o = y * bpr + x * bpp
                // All-zero = transparent: a hole where an excluded (our own)
                // window sat — no screen content, not dark text.
                if bpp >= 4, ptr[o] == 0, ptr[o + 1] == 0, ptr[o + 2] == 0, ptr[o + 3] == 0 { continue }
                let r = Double(ptr[o]) / 255, g = Double(ptr[o + 1]) / 255, b = Double(ptr[o + 2]) / 255
                lums.append(0.299 * r + 0.587 * g + 0.114 * b)
            }
        }
        guard !lums.isEmpty else { return nil }
        // Background = MEDIAN sampled luminance. (The previous modal-colour
        // approach reconstructed the background from a truncated 3-bit bucket —
        // a dark grey of lum ~0.13 truncated to bucket 0 = pure black, so every
        // background pixel read as ~0.13 "contrast" and dark input bars were
        // permanently OCCUPIED.) Glyph ink is sparse in the strip, so the median
        // is background; text pixels then stand out by their real contrast.
        let sorted = lums.sorted()
        let bgLum = sorted[sorted.count / 2]
        return lums.map { abs($0 - bgLum) }.max()
    }

    /// Convert an SCDisplay frame to Quartz top-left global coords.
    nonisolated private static func displayRectTopLeft(_ d: SCDisplay) -> CGRect {
        // SCDisplay.frame is already in the top-left global space used by AX rects.
        d.frame
    }

    /// Estimate background (modal colour) and foreground (most-contrasting) from the
    /// image, then blend a dimmed ghost colour.
    nonisolated private static func analyze(_ image: CGImage) -> Appearance? {
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        let bpr = image.bytesPerRow
        let bpp = image.bitsPerPixel / 8
        guard bpp >= 3 else { return nil }
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }

        // Histogram of coarse-quantised colours to find the background (most common).
        var counts: [UInt32: Int] = [:]
        func rgba(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let o = y * bpr + x * bpp
            return (Double(ptr[o]) / 255, Double(ptr[o + 1]) / 255, Double(ptr[o + 2]) / 255)
        }
        let stepX = max(1, w / 60), stepY = max(1, h / 20)
        var samples: [(Double, Double, Double)] = []
        for y in stride(from: 0, to: h, by: stepY) {
            for x in stride(from: 0, to: w, by: stepX) {
                let (r, g, b) = rgba(x, y)
                samples.append((r, g, b))
                let key = (UInt32(r * 7) << 6) | (UInt32(g * 7) << 3) | UInt32(b * 7)
                counts[key, default: 0] += 1
            }
        }
        guard let bgKey = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        // Exact background: the MEAN of the actual pixels in the modal bucket. The
        // bucket centre is quantised to 8 levels/channel — up to ~9% off, which
        // reads as a visibly mismatched backdrop in mirror mode.
        var bgSum = (0.0, 0.0, 0.0)
        var bgCount = 0
        for s in samples {
            let key = (UInt32(s.0 * 7) << 6) | (UInt32(s.1 * 7) << 3) | UInt32(s.2 * 7)
            if key == bgKey {
                bgSum.0 += s.0; bgSum.1 += s.1; bgSum.2 += s.2
                bgCount += 1
            }
        }
        guard bgCount > 0 else { return nil }
        let bg = (bgSum.0 / Double(bgCount), bgSum.1 / Double(bgCount), bgSum.2 / Double(bgCount))

        // Foreground = the sampled pixel with the greatest luminance distance from bg.
        func lum(_ c: (Double, Double, Double)) -> Double { 0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2 }
        let bgLum = lum(bg)
        var fg = bg
        var maxDist = 0.0
        for s in samples {
            let d = abs(lum(s) - bgLum)
            if d > maxDist { maxDist = d; fg = s }
        }
        // If there's basically no text in the strip, bail (keep previous/ default).
        guard maxDist > 0.12 else { return nil }

        let isDark = bgLum < 0.5
        // Ghost = the real foreground color at reduced alpha (applied by the caller
        // via `settings.ghostOpacity`), NOT blended toward the background in RGB
        // space — that crushes saturation/chroma and reads as flat gray instead of a
        // dimmed version of the actual ink color.
        return Appearance(
            ghostColor: NSColor(srgbRed: fg.0, green: fg.1, blue: fg.2, alpha: 1),
            textColor: NSColor(srgbRed: fg.0, green: fg.1, blue: fg.2, alpha: 1),
            backgroundColor: NSColor(srgbRed: bg.0, green: bg.1, blue: bg.2, alpha: 1),
            isDark: isDark)
    }
}

/// `SCShareableContent` enumerates every window on screen — too slow to repeat for
/// each probe. Displays and our own app rarely change, so a few seconds is fine.
/// (A lock, not an actor: `SCShareableContent` isn't Sendable.)
final class ShareableContentCache: @unchecked Sendable {
    static let shared = ShareableContentCache()
    private let lock = NSLock()
    private var cached: (content: SCShareableContent, at: Date)?

    func content() async -> SCShareableContent? {
        if let hit = lock.withLock({ cached.flatMap { Date().timeIntervalSince($0.at) < 5 ? $0.content : nil } }) {
            return hit
        }
        guard let fresh = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return nil }
        lock.withLock { cached = (fresh, Date()) }
        return fresh
    }
}
