import AppKit

/// Word alternatives (Cotypist's Pro feature): with a suggestion visible, a
/// shortcut opens a numbered list of alternative NEXT WORDS below the caret —
/// digit keys insert one. Candidates come from the current suggestion, the
/// personal phrase memory, the dictionary, and one higher-temperature model
/// regeneration that streams in when ready.
@MainActor
final class AlternativesController {
    private let panel = CommandPreviewPanel()
    private(set) var candidates: [String] = []
    private(set) var isActive = false
    /// Bumped on show/hide so late async candidates can detect staleness.
    private var generation = 0

    /// Present the panel with initial candidates (deduped, capped at 4).
    func show(candidates initial: [String], caretRect: CGRect?) {
        candidates = Self.dedup(initial)
        guard !candidates.isEmpty else { return }
        isActive = true
        generation += 1
        render(caretRect: caretRect)
    }

    /// Merge a late-arriving candidate (e.g. the high-temperature regeneration).
    func addCandidate(_ word: String, forGeneration gen: Int, caretRect: CGRect?) {
        guard isActive, gen == generation else { return }
        // The first real candidate replaces the "…" loading placeholder.
        candidates = Self.dedup(candidates.filter { $0 != Self.placeholder } + [word])
        render(caretRect: caretRect)
    }

    var currentGeneration: Int { generation }

    /// The candidate for a pressed digit key (1-based), if any.
    func candidate(at index: Int) -> String? {
        guard isActive, index >= 1, index <= candidates.count,
              candidates[index - 1] != Self.placeholder else { return nil }
        return candidates[index - 1]
    }

    func hide() {
        isActive = false
        generation += 1
        candidates = []
        panel.hide()
    }

    private func render(caretRect: CGRect?) {
        let line = candidates.enumerated()
            .map { "\($0.offset + 1) \($0.element)" }
            .joined(separator: "    ")
        panel.show(text: line, caretRect: caretRect)
    }

    static let placeholder = "…"

    private static func dedup(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.compactMap { w in
            let t = w.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { return nil }
            return t
        }.prefix(4).map { $0 }
    }
}
