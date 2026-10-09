import Foundation

/// Loads per-language SymSpell dictionaries (in the background) and offers
/// conservative autocorrections that preserve the original word's casing.
/// Only the languages actually used are indexed in memory (small LRU).
final class SpellChecker: @unchecked Sendable {
    static let shared = SpellChecker()

    /// Languages we ship a frequency dictionary for.
    static let supported: [String] = [
        "en", "es", "fr", "de", "it", "pt",       // Western
        "hi", "bn", "ta", "te", "ml", "ur",       // Indian
    ]
    static func displayName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    private let queue = DispatchQueue(label: "app.tabtype.spell", qos: .utility)
    private var loaded: [String: SymSpell] = [:]       // language -> index
    private var lru: [String] = []                     // most-recent last
    /// Building an index takes seconds: it runs here, never on `queue`, so a
    /// check made meanwhile fails open instead of stalling a suggestion.
    private let loadQueue = DispatchQueue(label: "app.tabtype.spell.load", qos: .utility)
    private var loading = Set<String>()                // on `queue`
    private let maxLoaded = 2

    private init() {}

    /// Kick off a background index build for `language` (idempotent).
    func loadIfNeeded(language: String) {
        let lang = normalized(language)
        queue.async { [weak self] in _ = self?.ensureLoaded(lang) }
    }

    /// A confident correction for `word` in `language`, on the main actor, or nil.
    func correct(_ word: String, language: String,
                 then completion: @escaping @MainActor (String?) -> Void) {
        let lang = normalized(language)
        queue.async { [weak self] in
            guard let self else { return }
            let sym = self.ensureLoaded(lang)
            guard let sym, sym.isReady,
                  word.count >= 3, word.allSatisfy({ $0.isLetter }),
                  let fixed = sym.bestSuggestion(word),
                  fixed.lowercased() != word.lowercased() else {
                Task { @MainActor in completion(nil) }
                return
            }
            let result = Self.applyCase(of: word, to: fixed)
            Task { @MainActor in completion(result) }
        }
    }

    /// Whether `partial + fragment` is a known word or a prefix of one, for the given
    /// language. Falls open (true) if no dictionary is loaded/ready. Used as a
    /// mid-word sanity check on model suggestions — cheap, since it runs once per
    /// suggestion (not per keystroke).
    ///
    /// Also checks English as a second pass when the configured language rejects a
    /// fragment: `autocorrectLanguage` defaults from the system locale, which often
    /// doesn't match the language actually being typed (e.g. a non-English system
    /// locale with the user typing English) — without this, the guard would reject
    /// nearly everything typed in a different language than the configured one.
    func isPlausibleContinuation(partial: String, fragment: String, language: String) async -> Bool {
        let lang = normalized(language)
        if await checkPlausible(partial: partial, fragment: fragment, lang: lang) { return true }
        guard lang != "en" else { return false }
        return await checkPlausible(partial: partial, fragment: fragment, lang: "en")
    }

    /// Whether the token before the caret looks like a typo, used to skip suggesting
    /// entirely (a completion of a misspelling is never what the user wants).
    /// `isPartial` = the caret is mid-word: a typo means the partial can never become
    /// a word. Otherwise the word is complete: a typo means it's not in the dictionary
    /// but a near-neighbor is. Fails open (false) when no dictionary is ready, the
    /// token is too short, or contains non-letters (names, code, numbers). Like
    /// `isPlausibleContinuation`, also accepts English as a second-pass language.
    func isLikelyTypo(word: String, isPartial: Bool, language: String) async -> Bool {
        guard word.count >= 3, word.allSatisfy({ $0.isLetter }) else { return false }
        let lang = normalized(language)
        if !(await checkTypo(word: word, isPartial: isPartial, lang: lang)) { return false }
        guard lang != "en" else { return true }
        return await checkTypo(word: word, isPartial: isPartial, lang: "en")
    }

    /// Instant dictionary word completion for the partial word being typed —
    /// zero-latency mid-word ghosts while the LLM works on phrase continuations.
    /// Returns the FULL completed word (typed casing applied), or nil.
    func completion(for prefix: String, language: String) async -> String? {
        guard prefix.count >= 3, prefix.allSatisfy({ $0.isLetter }) else { return nil }
        let lang = normalized(language)
        if let word = await dictCompletion(prefix: prefix, lang: lang) { return word }
        guard lang != "en" else { return nil }
        return await dictCompletion(prefix: prefix, lang: "en")
    }

    private func dictCompletion(prefix: String, lang: String) async -> String? {
        await withCheckedContinuation { cont in
            queue.async { [weak self] in
                guard let self, let sym = self.ensureLoaded(lang), sym.isReady,
                      let word = sym.topCompletion(prefix: prefix) else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: Self.applyCase(of: prefix, to: word))
            }
        }
    }

    private func checkTypo(word: String, isPartial: Bool, lang: String) async -> Bool {
        await withCheckedContinuation { cont in
            queue.async { [weak self] in
                guard let self, let sym = self.ensureLoaded(lang), sym.isReady else {
                    cont.resume(returning: false)   // fail open — no dictionary, don't block
                    return
                }
                if isPartial {
                    cont.resume(returning: !sym.isKnownOrPrefix(word.lowercased()))
                } else {
                    cont.resume(returning: sym.bestSuggestion(word) != nil)
                }
            }
        }
    }

    private func checkPlausible(partial: String, fragment: String, lang: String) async -> Bool {
        await withCheckedContinuation { cont in
            queue.async { [weak self] in
                guard let self, let sym = self.ensureLoaded(lang), sym.isReady else {
                    cont.resume(returning: true)   // fail open — no dictionary, don't block
                    return
                }
                cont.resume(returning: sym.isKnownOrPrefix(partial + fragment))
            }
        }
    }

    // MARK: - Private (all on `queue`)

    private func normalized(_ language: String) -> String {
        let code = language.lowercased()
        return Self.supported.contains(code) ? code : "en"
    }

    /// The language's index, or nil while it's built in the background.
    private func ensureLoaded(_ lang: String) -> SymSpell? {
        if let s = loaded[lang] {
            touch(lang)
            return s
        }
        guard !loading.contains(lang) else { return nil }
        loading.insert(lang)
        loadQueue.async { [weak self] in
            let sym = Self.build(lang)
            self?.queue.async {
                self?.loading.remove(lang)
                if let sym { self?.store(lang, sym) }
            }
        }
        return nil
    }

    private static func build(_ lang: String) -> SymSpell? {
        let urls = [
            Bundle.module.url(forResource: "frequency_dictionary_\(lang)", withExtension: "txt"),
            Bundle.main.url(forResource: "frequency_dictionary_\(lang)", withExtension: "txt"),
        ]
        for case let url? in urls {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let sym = SymSpell(maxEditDistance: 2, prefixLength: 7)
                sym.load(contents: text)
                Log.shared.info("SpellChecker ready [\(lang)]")
                return sym
            }
        }
        Log.shared.info("SpellChecker: dictionary not found for \(lang)")
        return nil
    }

    private func store(_ lang: String, _ sym: SymSpell) {
        loaded[lang] = sym
        touch(lang)
        while lru.count > maxLoaded {
            let evict = lru.removeFirst()
            loaded[evict] = nil
        }
    }

    private func touch(_ lang: String) {
        lru.removeAll { $0 == lang }
        lru.append(lang)
    }

    private static func applyCase(of original: String, to corrected: String) -> String {
        if original == original.uppercased() { return corrected.uppercased() }
        if let f = original.first, f.isUppercase { return corrected.capitalized }
        return corrected
    }
}
