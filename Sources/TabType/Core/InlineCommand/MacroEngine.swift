import Foundation

/// Evaluates inline `/` macros to a replacement string. All offline / local.
/// Examples: `/date`, `/time`, `/now`, `/uuid`, `/dice`, `/random 100`,
/// `10km->mi`, `2+2*3`.
struct MacroEngine {
    /// Injected for determinism in tests.
    var now: () -> Date = Date.init
    var randomInt: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }

    /// Returns the evaluated result, or nil if the query isn't a recognized macro.
    func evaluate(_ query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        return date(q) ?? random(q) ?? unitConversion(q) ?? arithmetic(q)
    }

    /// Every fixed command keyword `evaluate` recognizes (expressions like
    /// arithmetic/unit conversions are matched structurally instead).
    static let keywords: [String] = [
        "date", "today", "time", "now", "datetime", "day", "iso",
        "uuid", "dice", "roll", "coin", "random",
    ]

    /// Whether `query` could still grow into a valid macro — used to decide when the
    /// inline-command session should give up. True when the query is a prefix of a
    /// known keyword, or looks like a growing expression (contains a digit or an
    /// arithmetic/conversion operator).
    static func couldMatch(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        if keywords.contains(where: { $0.hasPrefix(q) || q.hasPrefix($0) }) { return true }
        return q.contains(where: { $0.isNumber }) || q.contains(where: { "+-*/()->.".contains($0) })
    }

    // MARK: Date / time
    private func date(_ q: String) -> String? {
        let f = DateFormatter()
        switch q.lowercased() {
        case "date", "today":
            f.dateStyle = .long; f.timeStyle = .none
        case "time":
            f.dateStyle = .none; f.timeStyle = .short
        case "now", "datetime":
            f.dateStyle = .long; f.timeStyle = .short
        case "day":
            f.dateFormat = "EEEE"
        case "iso":
            let iso = ISO8601DateFormatter()
            return iso.string(from: now())
        default:
            return nil
        }
        return f.string(from: now())
    }

    // MARK: Random
    private func random(_ q: String) -> String? {
        let lower = q.lowercased()
        if lower == "uuid" { return UUID().uuidString }
        if lower == "dice" || lower == "roll" { return String(randomInt(1...6)) }
        if lower == "coin" { return randomInt(0...1) == 0 ? "Heads" : "Tails" }
        if lower.hasPrefix("random") {
            let rest = lower.dropFirst("random".count).trimmingCharacters(in: .whitespaces)
            let bound = Int(rest) ?? 100
            return String(randomInt(0...max(1, bound)))
        }
        return nil
    }

    // MARK: Unit conversion  e.g. "10 km -> mi", "72f->c"
    private func unitConversion(_ q: String) -> String? {
        let parts = q.lowercased().components(separatedBy: "->")
        guard parts.count == 2 else { return nil }
        let lhs = parts[0].trimmingCharacters(in: .whitespaces)
        let target = parts[1].trimmingCharacters(in: .whitespaces)

        // Split leading number from the source unit ("10km" / "10 km" / "72.5 f").
        var numStr = ""
        var i = lhs.startIndex
        while i < lhs.endIndex, lhs[i].isNumber || lhs[i] == "." || lhs[i] == "-" {
            numStr.append(lhs[i]); i = lhs.index(after: i)
        }
        guard let value = Double(numStr) else { return nil }
        let from = String(lhs[i...]).trimmingCharacters(in: .whitespaces)

        if let result = Self.convert(value, from: from, to: target),
           let number = formatNumber(result, places: 2) {
            return "\(number) \(target)"
        }
        return nil
    }

    private func formatNumber(_ n: Double, places: Int) -> String? {
        guard n.isFinite else { return nil }
        let scale = pow(10.0, Double(places))
        let rounded = abs(n) <= Double.greatestFiniteMagnitude / scale
            ? (n * scale).rounded() / scale : n
        if let integer = Int(exactly: rounded) { return String(integer) }
        return String(rounded)
    }

    /// Base-unit conversion tables (length, mass, temperature).
    private static let lengthToMeters: [String: Double] = [
        "mm": 0.001, "cm": 0.01, "m": 1, "km": 1000,
        "in": 0.0254, "inch": 0.0254, "ft": 0.3048, "yd": 0.9144, "mi": 1609.344,
    ]
    private static let massToGrams: [String: Double] = [
        "mg": 0.001, "g": 1, "kg": 1000, "oz": 28.3495, "lb": 453.592,
    ]

    private static func convert(_ value: Double, from: String, to: String) -> Double? {
        if let a = lengthToMeters[from], let b = lengthToMeters[to] { return value * a / b }
        if let a = massToGrams[from], let b = massToGrams[to] { return value * a / b }
        // Temperature
        switch (from, to) {
        case ("c", "f"): return value * 9 / 5 + 32
        case ("f", "c"): return (value - 32) * 5 / 9
        case ("c", "k"): return value + 273.15
        case ("k", "c"): return value - 273.15
        default: return nil
        }
    }

    // MARK: Arithmetic  e.g. "2+2*3", "(1+2)*3"
    private func arithmetic(_ q: String) -> String? {
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/() ")
        guard q.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              q.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")) != nil,
              q.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/")) != nil else {
            return nil
        }
        var parser = ArithmeticParser(q)
        guard let d = parser.evaluate() else { return nil }
        return formatNumber(d, places: 6)
    }
}

/// A tiny, crash-free recursive-descent evaluator for +,-,*,/ with parentheses.
private struct ArithmeticParser {
    private let chars: [Character]
    private var pos = 0
    init(_ s: String) { chars = Array(s.filter { !$0.isWhitespace }) }

    mutating func evaluate() -> Double? {
        let v = parseExpr()
        return pos == chars.count ? v : nil   // reject trailing junk
    }

    private mutating func peek() -> Character? { pos < chars.count ? chars[pos] : nil }

    private mutating func parseExpr() -> Double? {
        guard var value = parseTerm() else { return nil }
        while let op = peek(), op == "+" || op == "-" {
            pos += 1
            guard let rhs = parseTerm() else { return nil }
            value = op == "+" ? value + rhs : value - rhs
        }
        return value
    }

    private mutating func parseTerm() -> Double? {
        guard var value = parseFactor() else { return nil }
        while let op = peek(), op == "*" || op == "/" {
            pos += 1
            guard let rhs = parseFactor() else { return nil }
            if op == "/" { if rhs == 0 { return nil }; value /= rhs } else { value *= rhs }
        }
        return value
    }

    private mutating func parseFactor() -> Double? {
        if peek() == "(" {
            pos += 1
            let v = parseExpr()
            guard peek() == ")" else { return nil }
            pos += 1
            return v
        }
        if peek() == "-" { pos += 1; return parseFactor().map { -$0 } }
        var num = ""
        while let c = peek(), c.isNumber || c == "." { num.append(c); pos += 1 }
        return Double(num)
    }
}
