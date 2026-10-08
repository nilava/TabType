import Foundation

/// Terminals get suggestions only inside an AI agent's prompt (Claude Code,
/// Codex, Gemini CLI…), never at a shell prompt — like Cotypist, which hides
/// completions in terminals when no agent prompt is detected.
enum TerminalPrompt {
    /// Box-drawing characters agent TUIs frame their input with.
    private static let borders: Set<Character> = ["│", "┃", "║", "|"]
    /// Prompt markers that open the input line inside the box.
    private static let boxedMarkers: [String] = ["> ", "❯ ", "› "]
    /// Markers agent CLIs use without a box (Codex-style gutters).
    private static let bareMarkers: [String] = ["› ", "▌ "]

    /// What the author typed into an agent prompt, given the terminal text before
    /// the caret; nil when the caret isn't in one.
    static func input(before text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let line = lines.last else { return nil }
        let earlier = lines.dropLast().suffix(6)

        // Boxed prompt: "│ > text", with the box's top border (╭───) just above.
        var rest = Substring(line)
        rest = rest.drop(while: { $0 == " " })
        if let first = rest.first, borders.contains(first) {
            let inner = rest.dropFirst().drop(while: { $0 == " " })
            let boxAbove = earlier.contains { $0.contains("╭") || $0.contains("┌") || $0.contains("─") }
            for marker in boxedMarkers where inner.hasPrefix(marker) && boxAbove {
                return String(inner.dropFirst(marker.count))
            }
            return nil
        }
        // Unboxed agent gutter: "› text" / "▌ text" at the start of the line.
        for marker in bareMarkers where rest.hasPrefix(marker) {
            return String(rest.dropFirst(marker.count))
        }
        return nil
    }
}
