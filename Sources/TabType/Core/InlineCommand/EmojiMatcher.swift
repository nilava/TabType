import Foundation

struct Emoji: Decodable, Hashable {
    let code: String
    let char: String
    let keywords: [String]
    /// Whether this emoji supports a skin-tone modifier ("st" in the data).
    var supportsSkinTone: Bool = false

    enum CodingKeys: String, CodingKey { case code, char, keywords, st }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        char = try c.decode(String.self, forKey: .char)
        keywords = (try? c.decode([String].self, forKey: .keywords)) ?? []
        supportsSkinTone = (try? c.decode(Bool.self, forKey: .st)) ?? false
    }
}

/// Skin-tone modifiers (Unicode). `.none` leaves the emoji as-is.
enum SkinTone: String, CaseIterable {
    case none, light, mediumLight, medium, mediumDark, dark
    var modifier: String? {
        switch self {
        case .none: return nil
        case .light: return "\u{1F3FB}"
        case .mediumLight: return "\u{1F3FC}"
        case .medium: return "\u{1F3FD}"
        case .mediumDark: return "\u{1F3FE}"
        case .dark: return "\u{1F3FF}"
        }
    }
    var label: String {
        switch self {
        case .none: return "Default 👋"
        case .light: return "Light 👋🏻"
        case .mediumLight: return "Medium-Light 👋🏼"
        case .medium: return "Medium 👋🏽"
        case .mediumDark: return "Medium-Dark 👋🏾"
        case .dark: return "Dark 👋🏿"
        }
    }
}

/// Loads the bundled emoji dataset and ranks matches for a `:query` prefix.
@MainActor
final class EmojiMatcher {
    static let shared = EmojiMatcher()

    private(set) var all: [Emoji] = []

    private init() {
        load()
    }

    private func load() {
        // Try the SPM resource bundle first, then the app bundle.
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "emoji", withExtension: "json"),
            Bundle.main.url(forResource: "emoji", withExtension: "json"),
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url),
               let list = try? JSONDecoder().decode([Emoji].self, from: data) {
                all = list
                break
            }
        }
        Log.shared.info("EmojiMatcher loaded \(all.count) emoji")
    }

    /// Apply the preferred skin tone to an emoji's character when it supports one.
    /// Only applied to single-scalar base emoji to avoid mangling ZWJ sequences.
    func applyTone(_ emoji: Emoji, _ tone: SkinTone) -> String {
        guard emoji.supportsSkinTone, let mod = tone.modifier,
              emoji.char.unicodeScalars.count == 1 else { return emoji.char }
        return emoji.char + mod
    }

    /// Ranked matches for `query` (text after the `:`), best first.
    func matches(for query: String, limit: Int = 8) -> [Emoji] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }

        let recents = EmojiUsageStore.shared.recentCodes

        func score(_ e: Emoji) -> Int? {
            let code = e.code.lowercased()
            var best: Int? = nil
            func consider(_ v: Int) { if best == nil || v < best! { best = v } }
            if code == q { consider(0) }
            else if code.hasPrefix(q) { consider(1) }
            else if code.contains(q) { consider(2) }
            if e.keywords.contains(where: { $0.lowercased() == q }) { consider(2) }
            if e.keywords.contains(where: { $0.lowercased().hasPrefix(q) }) { consider(3) }
            if best == nil, q.count >= 3, Self.fuzzy(q, code) { consider(4) }
            return best
        }

        return all.compactMap { e -> (Emoji, Int)? in
            score(e).map { (e, $0) }
        }
        .sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            // Tie-break: recents first, then shorter code, then alphabetical.
            let ra = recents.firstIndex(of: a.0.code) ?? Int.max
            let rb = recents.firstIndex(of: b.0.code) ?? Int.max
            if ra != rb { return ra < rb }
            if a.0.code.count != b.0.code.count { return a.0.code.count < b.0.code.count }
            return a.0.code < b.0.code
        }
        .prefix(limit)
        .map(\.0)
    }

    /// Gendered variants of one emoji ("ok_person" / "ok_man" / "ok_woman") are
    /// reordered by the preferred gender; the neutral one is kept only when
    /// wanted. A family stays where its best-ranked member was.
    nonisolated static func preferringGender(_ ranked: [Emoji], gender: String, includeNeutral: Bool) -> [Emoji] {
        guard gender != "any" else { return ranked }
        func split(_ e: Emoji) -> (family: String, gender: String)? {
            let tokens = e.code.split(separator: "_").map(String.init)
            let map = ["man": "man", "men": "man", "woman": "woman", "women": "woman",
                       "person": "neutral", "people": "neutral"]
            guard let g = tokens.compactMap({ map[$0] }).first else { return nil }
            let family = tokens.filter { map[$0] == nil }.joined(separator: "_")
            return family.isEmpty ? nil : (family, g)
        }
        var out: [Emoji] = []
        var done = Set<String>()
        for e in ranked {
            guard let s = split(e) else { out.append(e); continue }
            guard done.insert(s.family).inserted else { continue }
            let members = ranked.filter { split($0)?.family == s.family }
            let rank: (Emoji) -> Int = { m in
                let g = split(m)!.gender
                return g == gender ? 0 : (g == "neutral" ? 1 : 2)
            }
            let hasPreferred = members.contains { rank($0) == 0 }
            out += members.sorted { rank($0) < rank($1) }.filter {
                !(rank($0) == 1 && !includeNeutral && hasPreferred && gender != "neutral")
            }
        }
        return out
    }

    /// Cheap fuzzy: bounded Levenshtein ≤ 2 against the code.
    private static func fuzzy(_ q: String, _ code: String) -> Bool {
        let a = Array(q), b = Array(code)
        if abs(a.count - b.count) > 2 { return false }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = cur
        }
        return prev[b.count] <= 2
    }
}
