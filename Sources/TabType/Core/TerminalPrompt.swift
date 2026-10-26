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
    /// Markers that count only under a horizontal rule (current Claude Code and
    /// Hermes draw "────" above "❯ text"); a bare "❯ " is also a common shell prompt.
    private static let ruledMarkers: [String] = ["❯ ", "> "]
    /// What tmux draws between side-by-side panes (pane-border-lines single).
    private static let paneBorders: Set<Character> = ["│", "┼", "├", "┤", "┬", "┴"]

    /// A separator line: at least 10 "─"/"━", starting or ending with one. Hermes
    /// titles its rule with the last prompt ("──── i want you to… ─").
    private static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let isDash: (Character) -> Bool = { $0 == "─" || $0 == "━" }
        guard let first = trimmed.first, let last = trimmed.last, isDash(first) || isDash(last) else { return false }
        return trimmed.filter(isDash).count >= 10
    }

    /// The conversation above the prompt line, as context for the model: rule lines
    /// and blank lines dropped, trailing padding trimmed, the last `cap` characters.
    static func conversation(before text: String, cap: Int = 1500) -> String {
        var lines = rows(text).lines
        // The prompt rows are the input, not context: OpenCode's "┃" block, or the
        // marker row plus the rows it wrapped onto.
        if let last = lines.last, isOpenCodeRow(last) {
            while let row = lines.last, isOpenCodeRow(row) { lines.removeLast() }
        } else {
            while lines.count >= 2, let row = lines.last, isContinuation(row) { lines.removeLast() }
            if !lines.isEmpty { lines.removeLast() }
        }
        let kept = lines.map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !isRule($0) }
        return String(kept.joined(separator: "\n").suffix(cap))
    }

    /// What the author typed into an agent prompt, given the terminal text before
    /// the caret; nil when the caret isn't in one.
    static func input(before text: String) -> String? {
        var (lines, trailing) = rows(text)
        if let typed = openCodeInput(lines) { return typed + trailing }
        // A long prompt wraps onto rows indented by two spaces (Claude Code, Hermes).
        var wrapped: [String] = []
        while wrapped.count < 12, lines.count >= 2, let row = lines.last, isContinuation(row) {
            wrapped.insert(String(row.dropFirst(2)), at: 0)
            lines.removeLast()
        }
        guard let head = promptInput(lines) else { return nil }
        return ([head] + wrapped).joined(separator: " ") + trailing
    }

    /// The terminal text as rows ending at the caret, normalized for matching.
    private static func rows(_ text: String) -> (lines: [String], trailing: String) {
        // Claude Code writes "❯\u{00A0}" (no-break space) — match it like a plain space.
        var lines = text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Terminal.app drops a row's trailing spaces, so right after Space the caret
        // reads as the start of the next, empty row.
        var trailing = ""
        if lines.count >= 2, lines[lines.count - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
            trailing = " "
        }
        return (cropToPane(lines), trailing)
    }

    /// tmux side-by-side panes: Terminal reports whole screen rows, so every row
    /// holds all panes with "│" between them. Keep only the caret's pane — the
    /// columns between the borders that run unbroken through the rows above it.
    static func cropToPane(_ lines: [String]) -> [String] {
        let grid = lines.map { Array($0) }
        guard grid.count >= 4, let caretRow = grid.last else { return lines }
        // Rows straight above the caret with a pane border at column `c`.
        func borderRun(_ c: Int) -> Int {
            var run = 0
            for row in grid.dropLast().reversed() {
                guard row.count > c, paneBorders.contains(row[c]) else { break }
                run += 1
            }
            return run
        }
        // Left edge: a border in the caret row itself. From column 10 on, so an
        // agent's own box ("│ > …" at the margin) never counts as a pane.
        let start = stride(from: caretRow.count - 1, through: 10, by: -1)
            .first { paneBorders.contains(caretRow[$0]) && borderRun($0) >= 3 }
        // Right edge: the next border right of the caret (the caret row stops there).
        let widest = grid.map(\.count).max() ?? 0
        let end = (max(caretRow.count, (start ?? -1) + 1)..<max(widest, caretRow.count)).first { borderRun($0) >= 3 }
        guard start != nil || end != nil else { return lines }
        let from = (start ?? -1) + 1
        return grid.enumerated().map { index, row in
            let isCaret = index == grid.count - 1
            let to = isCaret ? row.count : min(end ?? row.count, row.count)
            guard from < to else { return "" }
            let cell = String(row[from..<to])
            return isCaret ? cell : cell.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        }
    }

    private static func isContinuation(_ row: String) -> Bool {
        guard row.hasPrefix("  "), let third = row.dropFirst(2).first, third != " " else { return false }
        return !borders.contains(third) && !isRule(row)
    }

    private static func isOpenCodeRow(_ row: String) -> Bool {
        row.drop(while: { $0 == " " }).first == "┃"
    }

    /// OpenCode (and its fork Kilo CLI): no marker — input rows are "┃  text" under
    /// a padding row that holds only "┃". Wrapped input adds more "┃  text" rows.
    private static func openCodeInput(_ lines: [String]) -> String? {
        var pieces: [String] = []
        for line in lines.reversed().prefix(13) {
            let row = line.drop(while: { $0 == " " })
            guard row.first == "┃" else { return nil }
            let body = row.dropFirst()
            if body.allSatisfy({ $0 == " " }) { return pieces.isEmpty ? nil : pieces.joined(separator: " ") }
            guard body.hasPrefix("  ") else { return nil }
            pieces.insert(String(body.dropFirst(2)), at: 0)
        }
        return nil
    }

    /// The input on the prompt row (the last of `lines`), nil when it isn't one.
    private static func promptInput(_ lines: [String]) -> String? {
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
        // Ruled prompt: "────" on the nearest non-empty line above, then "❯ text".
        let ruleAbove = earlier.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(isRule) ?? false
        for marker in ruledMarkers where ruleAbove && rest.hasPrefix(marker) {
            return String(rest.dropFirst(marker.count))
        }
        return nil
    }
}
